#!/bin/bash
# Existing 03-postgres flags dead_pct at thresholds. This catches the
# upstream signal: a hot table accumulating dead tuples faster than
# autovacuum is keeping up with, even before % crosses the warn line.
# Rate = current n_dead_tup / hours since last autovacuum. Only tables
# with > 50k dead + > 6h since AV are considered (avoid mid-AV noise).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${DEAD_TUP_RATE_PER_HOUR_WARN:=10000}"
: "${DEAD_TUP_RATE_PER_HOUR_CRIT:=50000}"

for pg in $(docker ps --format '{{.Names}}' | grep '_postgres$'); do
  user=$(docker exec "$pg" printenv POSTGRES_USER 2>/dev/null)
  db=$(docker exec "$pg" printenv POSTGRES_DB 2>/dev/null)
  [ -z "$user" ] || [ -z "$db" ] && continue
  docker exec "$pg" psql -U "$user" -d "$db" -At -F'|' -c "
SELECT relname,
       n_dead_tup,
       ROUND((EXTRACT(EPOCH FROM (now() - last_autovacuum))/3600)::numeric, 1) AS h_since_av,
       ROUND(n_dead_tup::numeric / GREATEST(EXTRACT(EPOCH FROM (now() - last_autovacuum))/3600, 1), 0)::int AS rate_per_hr
FROM pg_stat_user_tables
WHERE n_dead_tup > 50000
  AND last_autovacuum < now() - interval '6 hours'
ORDER BY rate_per_hr DESC LIMIT 10;" 2>/dev/null \
  | while IFS='|' read -r tbl dead h_since rate; do
      [ -z "$rate" ] && continue
      if [ "$rate" -ge "$DEAD_TUP_RATE_PER_HOUR_CRIT" ] 2>/dev/null; then
        sev=HIGH; lbl=crit
      elif [ "$rate" -ge "$DEAD_TUP_RATE_PER_HOUR_WARN" ] 2>/dev/null; then
        sev=MED; lbl=warn
      else
        continue
      fi
      echo "$sev|postgres/$pg|$tbl dead-tup rate ${rate}/hr (${dead} dead, last autovac ${h_since}h ago, ${lbl} ≥${DEAD_TUP_RATE_PER_HOUR_WARN}/hr) — autovac may not keep up|docker exec $pg psql -U $user -d $db -c \"VACUUM ANALYZE $tbl;\""
    done
done
