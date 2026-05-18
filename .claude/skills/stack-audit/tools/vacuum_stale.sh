#!/bin/bash
# vacuum_stale.sh — find postgres tables that need maintenance and run
# VACUUM (ANALYZE) on them.
#
# A table is "stale" if EITHER:
#   - dead_tup / (live_tup + dead_tup) >= DEAD_PCT_THRESHOLD (default 10), OR
#   - last_autovacuum is NULL or older than DAYS_THRESHOLD (default 7)
#
# Considers every container ending in `_postgres` and uses
# `docker exec <c> psql -U <user>` (Unix-socket trust auth) to query.
# The user/db is derived from the container name (strips the `_postgres` suffix).
#
# Flags:
#   --dry-run                   list candidates, don't vacuum
#   --dead-pct=N                override DEAD_PCT_THRESHOLD (default 10)
#   --days=N                    override DAYS_THRESHOLD (default 7)
#   --only=db1,db2              limit to specific *_postgres containers

set -uo pipefail
DRY=0
DEAD_PCT=10
DAYS=7
ONLY=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --dead-pct=*) DEAD_PCT="${a#--dead-pct=}" ;;
    --days=*) DAYS="${a#--days=}" ;;
    --only=*) ONLY="${a#--only=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

in_list() { case ",$2," in *",$1,"*) return 0;; esac; return 1; }

mapfile -t PG_CONTAINERS < <(docker ps --filter 'name=_postgres' --format '{{.Names}}')

for c in "${PG_CONTAINERS[@]}"; do
  if [ -n "$ONLY" ] && ! in_list "$c" "$ONLY"; then continue; fi
  user="${c%_postgres}"
  db="$user"

  # Discover candidates — emit schema and table as separate fields so we can
  # safely quote each identifier (handles mixed-case names like "ImdbFiles").
  candidates=$(docker exec "$c" psql -U "$user" -d "$db" -At -F'|' -c "
    SELECT schemaname,
           relname,
           round(100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0), 1),
           COALESCE(extract(epoch FROM (now()-last_autovacuum))::int/86400, 9999)
      FROM pg_stat_user_tables
     WHERE n_live_tup > 1000
       AND ( 100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0) >= $DEAD_PCT
             OR last_autovacuum IS NULL
             OR last_autovacuum < now() - INTERVAL '$DAYS days' )
     ORDER BY n_dead_tup DESC;
  " 2>/dev/null) || { echo "[$c] query failed (extension/auth?); skipping"; continue; }

  if [ -z "$candidates" ]; then
    echo "[$c] no stale tables (dead_pct ≥ $DEAD_PCT% OR last_autovac > $DAYS d)"
    continue
  fi

  while IFS='|' read -r schema tbl pct days_old; do
    [ -z "$tbl" ] && continue
    qualified="\"$schema\".\"$tbl\""
    if [ "$DRY" -eq 1 ]; then
      echo "  WOULD VACUUM: $c $qualified  (dead=${pct}%, autovac_age=${days_old}d)"
    else
      echo "  VACUUM ANALYZE $qualified on $c  (dead=${pct}%, autovac_age=${days_old}d)"
      docker exec "$c" psql -U "$user" -d "$db" -c "VACUUM (ANALYZE) $qualified;" >/dev/null 2>&1 \
        && echo "    OK" || echo "    FAILED"
    fi
  done <<<"$candidates"
done
