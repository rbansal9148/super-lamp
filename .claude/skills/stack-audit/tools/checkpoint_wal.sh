#!/bin/bash
# checkpoint_wal.sh — force CHECKPOINT on every running postgres instance so
# accumulated WAL segments can be recycled. Read-only-ish; safe on busy DBs
# (CHECKPOINT may briefly add I/O load).
#
# Reports pg_wal size before/after.
#
# Flags:
#   --dry-run    report sizes only, don't checkpoint
#   --only=...   restrict to specific *_postgres container names

set -uo pipefail
DRY=0
ONLY=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --only=*) ONLY="${a#--only=}" ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  esac
done

in_list() { case ",$2," in *",$1,"*) return 0;; esac; return 1; }

mapfile -t PG < <(docker ps --filter 'name=_postgres' --format '{{.Names}}')

printf "%-30s %-10s %-10s\n" "container" "wal_before" "wal_after"
printf "%-30s %-10s %-10s\n" "---------" "----------" "---------"

# Some compose setups use PGDATA=/var/lib/postgresql/data/pgdata, others leave it
# at the default /var/lib/postgresql/data. Probe both before giving up.
wal_path_of() {
  local c="$1"
  # Try common locations first, then fall back to find.
  for p in /var/lib/postgresql/data/pgdata/pg_wal /var/lib/postgresql/data/pg_wal; do
    if docker exec "$c" test -d "$p" 2>/dev/null; then echo "$p"; return; fi
  done
  # Some postgres images (Bitnami-style, 18-alpine variants) use a
  # /var/lib/postgresql/<major>/<subdir>/pg_wal layout.
  docker exec "$c" find /var/lib/postgresql -maxdepth 4 -name pg_wal -type d 2>/dev/null | head -1
}
wal_size() {
  docker exec "$1" du -sh "$2" 2>/dev/null | awk '{print $1}'
}

for c in "${PG[@]}"; do
  if [ -n "$ONLY" ] && ! in_list "$c" "$ONLY"; then continue; fi
  wal=$(wal_path_of "$c")
  if [ -z "$wal" ]; then
    printf "%-30s %-10s %-10s\n" "$c" "n/a" "n/a (no pg_wal found)"
    continue
  fi
  before=$(wal_size "$c" "$wal")
  if [ "$DRY" -eq 1 ]; then
    printf "%-30s %-10s %-10s\n" "$c" "$before" "DRY"
    continue
  fi
  user="${c%_postgres}"
  docker exec "$c" psql -U "$user" -d "$user" -c "CHECKPOINT;" >/dev/null 2>&1 || true
  sleep 2
  after=$(wal_size "$c" "$wal")
  printf "%-30s %-10s %-10s\n" "$c" "$before" "${after:-?}"
done
