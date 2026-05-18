#!/bin/bash
# Postgres deep patterns: blocking locks, index bloat candidates, slow-query logging, sequence exhaustion.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

PG_CONTAINERS=$(docker ps --format '{{.Names}}' | grep '_postgres$' | sort)

for pg in $PG_CONTAINERS; do
  user=$(docker exec "$pg" printenv POSTGRES_USER 2>/dev/null)
  db=$(docker exec "$pg" printenv POSTGRES_DB 2>/dev/null)
  [ -z "$user" ] || [ -z "$db" ] && continue
  PSQL="docker exec $pg psql -U $user -d $db -At -c"

  # 1. Blocking sessions — lock held > threshold
  blocking=$($PSQL "
    SELECT count(*) FROM pg_stat_activity
    WHERE wait_event_type='Lock'
      AND age(now(), xact_start) > interval '${BLOCKING_LOCK_SECONDS_WARN} seconds';" 2>/dev/null)
  if [ -n "$blocking" ] && [ "$blocking" -gt 0 ]; then
    echo "HIGH|postgres/$pg|$blocking sessions blocked >${BLOCKING_LOCK_SECONDS_WARN}s on locks|docker exec $pg psql -U $user -d $db -c \"SELECT pid,wait_event,query FROM pg_stat_activity WHERE wait_event_type='Lock';\""
  fi

  # 2. Index bloat candidates — large + low scans
  if [ "$MODE" = "deep" ]; then
    $PSQL "
      SELECT indexrelname, ROUND(pg_relation_size(indexrelid)/1024/1024)::int AS mb, idx_scan,
             CASE WHEN idx_scan>0 THEN ROUND((pg_relation_size(indexrelid)::numeric/idx_scan/1024/1024)::numeric,2) ELSE NULL END AS mb_per_scan
      FROM pg_stat_user_indexes
      WHERE pg_relation_size(indexrelid) > ${INDEX_BLOAT_MB_WARN}*1024*1024
        AND idx_scan > 0
        AND (pg_relation_size(indexrelid)::numeric/idx_scan/1024/1024) > ${INDEX_BLOAT_SCAN_RATIO_MAX};" 2>/dev/null | \
      awk -F'|' -v db="$pg" '{printf "MED|postgres/%s|index %s is %sMB with only %s scans (%s MB/scan) — bloat candidate|docker exec %s psql -U postgres -c \"REINDEX INDEX CONCURRENTLY %s;\"\n", db, $1, $2, $3, $4, db, $1}'
  fi

  # 3. log_min_duration_statement — recommend enabling for visibility
  log_min=$($PSQL "SHOW log_min_duration_statement;" 2>/dev/null | head -1)
  if [ "$log_min" = "-1" ]; then
    echo "LOW|postgres/$pg|log_min_duration_statement disabled — no slow-query log|add -c log_min_duration_statement=${LOG_MIN_DURATION_MS_RECOMMEND} to postgres command"
  fi

  # 4. Sequence exhaustion (>80% of max int)
  if [ "$MODE" = "deep" ]; then
    $PSQL "
      SELECT c.relname, ROUND(100.0*s.last_value::numeric/2147483647,0)::int AS pct
      FROM pg_class c JOIN pg_sequences s ON s.sequencename = c.relname
      WHERE c.relkind = 'S' AND s.last_value > 1717986918;" 2>/dev/null | \
      awk -F'|' -v db="$pg" '{printf "CRIT|postgres/%s|sequence %s at %s%% of int32 max — schema change needed|ALTER SEQUENCE %s AS bigint\n", db, $1, $2, $1}'
  fi
done
