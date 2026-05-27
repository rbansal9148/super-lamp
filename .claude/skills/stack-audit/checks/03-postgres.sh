#!/bin/bash
# Postgres per-DB: cache hit, dead tuples, idle conns, unused indexes, slow queries.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

PG_CONTAINERS=$(docker ps --format '{{.Names}}' | grep '_postgres$' | sort)

for pg in $PG_CONTAINERS; do
  user=$(docker exec "$pg" printenv POSTGRES_USER 2>/dev/null)
  db=$(docker exec "$pg" printenv POSTGRES_DB 2>/dev/null)
  [ -z "$user" ] || [ -z "$db" ] && continue
  PSQL="docker exec $pg psql -U $user -d $db -At -c"

  # Context: DB size + postgres uptime (used to suppress noise)
  db_mb=$($PSQL "SELECT (pg_database_size('$db')/1024/1024)::int;" 2>/dev/null)
  up_min=$($PSQL "SELECT EXTRACT(EPOCH FROM (now()-pg_postmaster_start_time()))::int/60;" 2>/dev/null)

  # 1. Cache hit ratios — only material on non-tiny DBs and after warmup
  heap=$($PSQL "SELECT COALESCE(ROUND(100*sum(heap_blks_hit)::numeric/NULLIF(sum(heap_blks_hit+heap_blks_read),0),0)::int, 100) FROM pg_statio_user_tables;" 2>/dev/null)
  idx=$($PSQL "SELECT COALESCE(ROUND(100*sum(idx_blks_hit)::numeric/NULLIF(sum(idx_blks_hit+idx_blks_read),0),0)::int, 100) FROM pg_statio_user_indexes;" 2>/dev/null)

  small_db=0; warming=0
  [ -n "$db_mb" ] && [ "$db_mb" -lt "$HEAP_HIT_DB_MIN_MB" ] && small_db=1
  [ -n "$up_min" ] && [ "$up_min" -lt "$HEAP_HIT_WARMUP_MIN" ] && warming=1

  if [ -n "$heap" ]; then
    if [ "$small_db" = "1" ]; then
      :  # suppress — tiny DB
    elif [ "$heap" -lt "$HEAP_HIT_CRIT" ]; then
      if [ "$warming" = "1" ]; then
        echo "LOW|postgres/$pg|heap_hit ${heap}% but postgres only up ${up_min}min — cache still warming|wait ${HEAP_HIT_WARMUP_MIN}min; or pg_prewarm hot tables"
      else
        echo "CRIT|postgres/$pg|heap_hit ${heap}% (crit <${HEAP_HIT_CRIT}%) — most reads going to disk|raise shared_buffers in apps/${pg%%_*}/compose.yaml"
      fi
    elif [ "$heap" -lt "$HEAP_HIT_WARN" ]; then
      if [ "$warming" = "1" ]; then
        echo "LOW|postgres/$pg|heap_hit ${heap}% but postgres only up ${up_min}min — cache still warming|wait; or pg_prewarm"
      else
        echo "HIGH|postgres/$pg|heap_hit ${heap}% (warn <${HEAP_HIT_WARN}%)|raise shared_buffers; or use pg_prewarm extension"
      fi
    fi
  fi
  if [ -n "$idx" ] && [ "$idx" -lt "$IDX_HIT_WARN" ] && [ "$small_db" = "0" ] && [ "$warming" = "0" ]; then
    echo "MED|postgres/$pg|idx_hit ${idx}% (warn <${IDX_HIT_WARN}%)|raise shared_buffers; check for missing/unused indexes"
  fi

  # 2. Dead tuple ratio per top table.
  # Skip tables vacuumed (auto OR manual) in last 24h: pg_stat_user_tables.n_dead_tup
  # is an incremental counter that only resets on a vacuum that actually removes
  # tuples. After a recent vacuum, a non-zero stat almost always means the
  # rows aren't yet removable (xmin horizon) — not real bloat. Suppressing
  # the finding is the right move; autovac will reconcile when conditions allow.
  $PSQL "SELECT relname, ROUND(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),0)::int AS pct, last_autovacuum FROM pg_stat_user_tables WHERE n_live_tup+n_dead_tup>1000 AND ROUND(100.0*n_dead_tup/NULLIF(n_live_tup+n_dead_tup,0),0) >= $DEAD_TUP_PCT_WARN AND (GREATEST(COALESCE(last_vacuum,'epoch'), COALESCE(last_autovacuum,'epoch')) < now() - interval '24 hours') ORDER BY pct DESC LIMIT 5;" 2>/dev/null | \
    awk -F'|' -v db="$pg" -v cw="$DEAD_TUP_PCT_CRIT" -v ww="$DEAD_TUP_PCT_WARN" '
    $2+0 >= cw { printf "CRIT|postgres/%s|table %s has %s%% dead tuples (crit ≥%s%%)|docker exec %s psql -U postgres -c \"VACUUM ANALYZE %s;\"|vacuum_stale\n", db, $1, $2, cw, db, $1; next }
    $2+0 >= ww { printf "MED|postgres/%s|table %s has %s%% dead tuples (warn ≥%s%%) last_autovacuum=%s|VACUUM ANALYZE %s|vacuum_stale\n", db, $1, $2, ww, $3, $1 }'

  # 3. Idle connections > N min
  idle_old=$($PSQL "SELECT count(*) FROM pg_stat_activity WHERE state='idle' AND backend_type='client backend' AND age(now(),state_change) > interval '${IDLE_CONN_MAX_MIN} minutes';" 2>/dev/null)
  if [ -n "$idle_old" ] && [ "$idle_old" -gt 0 ]; then
    echo "LOW|postgres/$pg|$idle_old idle connections >${IDLE_CONN_MAX_MIN}min — pool leak indicator|add idle_session_timeout=900000 to apps/${pg%%_*}/compose.yaml postgres command"
  fi

  # 4. Unused indexes (deep mode)
  if [ "$MODE" = "deep" ]; then
    $PSQL "SELECT indexrelname, ROUND(pg_relation_size(indexrelid)/1024/1024)::int FROM pg_stat_user_indexes WHERE idx_scan = 0 AND pg_relation_size(indexrelid) > ${UNUSED_INDEX_MIN_MB}*1024*1024 ORDER BY pg_relation_size(indexrelid) DESC LIMIT 5;" 2>/dev/null | \
      awk -F'|' -v db="$pg" '{printf "LOW|postgres/%s|unused index %s (%sMB, 0 scans)|consider DROP INDEX CONCURRENTLY %s after confirming no rare path uses it\n", db, $1, $2, $1}'
  fi

  # 5. Slow queries (deep mode)
  if [ "$MODE" = "deep" ]; then
    has_pgss=$($PSQL "SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null)
    if [ "$has_pgss" = "1" ]; then
      $PSQL "SELECT ROUND(mean_exec_time)::int, calls, left(query,80) FROM pg_stat_statements WHERE calls>10 AND mean_exec_time > ${SLOW_QUERY_MEAN_MS_WARN} ORDER BY mean_exec_time DESC LIMIT 3;" 2>/dev/null | \
        awk -F'|' -v db="$pg" -v cw="$SLOW_QUERY_MEAN_MS_CRIT" -v ww="$SLOW_QUERY_MEAN_MS_WARN" '
        $1+0 >= cw { printf "HIGH|postgres/%s|slow query %sms mean ×%s: %s|investigate query plan; EXPLAIN ANALYZE\n", db, $1, $2, $3; next }
        $1+0 >= ww { printf "MED|postgres/%s|slow query %sms mean ×%s: %s|EXPLAIN ANALYZE; consider index\n", db, $1, $2, $3 }'
    fi
  fi
done
