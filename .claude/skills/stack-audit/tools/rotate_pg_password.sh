#!/bin/bash
# rotate_pg_password.sh — atomically rotate a postgres user's password.
#
# Steps:
#   1. Generate a fresh 48-char hex password (or use --password).
#   2. Find the OLD password by reading the current value from the canonical
#      .env/compose.yaml of the target service. If --old is provided, use that.
#   3. Run ALTER USER on the postgres container (live; doesn't kick existing
#      sessions, but new auth uses the new pw).
#   4. Replace every literal OLD-password occurrence under /opt/docker/apps/
#      AND /opt/docker/.env so all consumers stay in sync (handles cases like
#      stremthru.env's STREMTHRU_INTEGRATION_BITMAGNET_DATABASE_URI which holds
#      bitmagnet's password).
#   5. `docker compose up -d` every service whose files changed AND is running.
#
# Usage:
#   rotate_pg_password.sh <service> [--password <new>] [--old <old>]
#                                   [--dry-run] [--no-restart]
#   service: a postgres container basename without "_postgres" (e.g. "bitmagnet")
#
# Safety:
#   - Refuses to run if OLD password is empty or shorter than 4 chars
#     (heuristic to avoid clobbering unrelated strings).
#   - Refuses to run if OLD password matches a common-word regex like
#     '^password$' AND --confirm-weak isn't given (still possible; just nudges).
#   - --dry-run prints the file change-set without modifying anything.

set -uo pipefail
ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0
NORESTART=0
NEW=""
OLD=""
CONFIRM_WEAK=0
SVC=""

for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-restart) NORESTART=1 ;;
    --password) shift; NEW="${1:-}" ;;
    --password=*) NEW="${a#--password=}" ;;
    --old) shift; OLD="${1:-}" ;;
    --old=*) OLD="${a#--old=}" ;;
    --confirm-weak) CONFIRM_WEAK=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) ;;
    *) SVC="$a" ;;
  esac
done

if [ -z "$SVC" ]; then
  echo "usage: $0 <service> [--password X] [--old Y] [--dry-run] [--no-restart]" >&2
  exit 2
fi

PG_CONT="${SVC}_postgres"
if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONT"; then
  echo "error: container $PG_CONT not running" >&2; exit 1
fi

# Find OLD password if not supplied.
if [ -z "$OLD" ]; then
  # Prefer apps/<svc>/.env DATABASE_URI; fallback to POSTGRES_PASSWORD in env or compose.
  if [ -f "$ROOT/apps/$SVC/.env" ]; then
    OLD=$(grep -E "^(POSTGRES_PASSWORD|DATABASE_URI|.*_DATABASE_URI)=" "$ROOT/apps/$SVC/.env" \
          | head -1 | sed -E 's|^[^=]+=||; s|.*://[^:/]+:([^@]+)@.*|\1|; s|^"||; s|"$||')
  fi
  if [ -z "$OLD" ] && [ -f "$ROOT/apps/$SVC/compose.yaml" ]; then
    OLD=$(grep -E "POSTGRES_PASSWORD" "$ROOT/apps/$SVC/compose.yaml" | head -1 \
          | sed -E 's|.*POSTGRES_PASSWORD[ :=-]+||; s|"||g; s|[ ]*$||')
  fi
fi

if [ -z "$OLD" ] || [ "${#OLD}" -lt 4 ]; then
  echo "error: could not locate OLD password for $SVC (got '$OLD')" >&2; exit 1
fi
if echo "$OLD" | grep -qiE '^(password|admin|admin123|postgres|root|changeme)$' && [ "$CONFIRM_WEAK" -eq 0 ]; then
  echo "warn: OLD password '$OLD' is a common literal; pass --confirm-weak to rotate anyway" >&2
  exit 1
fi

if [ -z "$NEW" ]; then
  NEW=$(openssl rand -hex 24)
fi

# Find files containing OLD pw under apps/ and root .env
mapfile -t HITS < <(grep -rlF "$OLD" "$ROOT/apps" "$ROOT/.env" 2>/dev/null | sort -u)
if [ "${#HITS[@]}" -eq 0 ]; then
  echo "warn: no files reference OLD password literal — already rotated?" >&2
fi

echo "=== rotate $SVC postgres password ==="
echo "  container: $PG_CONT"
echo "  files to update: ${#HITS[@]}"
for f in "${HITS[@]}"; do echo "    - $f"; done
echo "  new pw: ${NEW:0:6}…${NEW: -4}  (full pw: $NEW)"

if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN: would ALTER USER $SVC and update files."
  exit 0
fi

# ALTER USER on the postgres container (live).
docker exec "$PG_CONT" psql -U "$SVC" -d "$SVC" \
  -c "ALTER USER $SVC WITH PASSWORD '$NEW';" >/dev/null \
  || { echo "ALTER USER failed"; exit 1; }
echo "  ALTER USER ok"

# Rewrite each file: replace OLD with NEW (literal, no regex special chars
# in either side are expected for hex/typical generated pws; we use python
# str.replace for safety).
for f in "${HITS[@]}"; do
  python3 - "$f" "$OLD" "$NEW" <<'PY'
import sys, pathlib
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
P = pathlib.Path(p)
text = P.read_text()
new_text = text.replace(old, new)
if new_text != text:
    P.write_text(new_text)
    print(f"  updated {p}")
PY
done

if [ "$NORESTART" -eq 1 ]; then
  echo "skipped restart (--no-restart)"; exit 0
fi

# Restart consumers: dedupe service names from file paths.
mapfile -t TO_RESTART < <(printf '%s\n' "${HITS[@]}" | sed -nE 's|.*/apps/([^/]+)/.*|\1|p' | sort -u)
for s in "${TO_RESTART[@]}"; do
  if docker ps --format '{{.Names}}' | grep -qx "$s" \
       || docker ps --format '{{.Names}}' | grep -qx "${s}_prune" \
       || docker ps --format '{{.Names}}' | grep -qx "${s}_postgres"; then
    (cd "$ROOT" && docker compose up -d "$s" >/dev/null 2>&1 \
       && echo "  restarted: $s" \
       || echo "  WARN: restart failed for $s")
  fi
done
