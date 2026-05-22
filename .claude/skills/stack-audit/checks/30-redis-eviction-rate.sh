#!/bin/bash
# Existing 04-redis.sh tracks hit rate. This catches the parallel signal:
# eviction rate. A cache that's evicting 30+ keys/min is too small for the
# working set (or has unbounded key cardinality) and produces a slow drift
# of cache misses that hit-rate alone may not surface clearly.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${REDIS_EVICTION_PER_MIN_WARN:=30}"
: "${REDIS_EVICTION_PER_MIN_CRIT:=300}"

for r in $(docker ps --format '{{.Names}}' | grep '_redis$'); do
  ev=$(docker exec "$r" sh -c 'redis-cli INFO stats 2>/dev/null || valkey-cli INFO stats 2>/dev/null' \
        | grep '^evicted_keys:' | tr -d '\r' | cut -d: -f2)
  up=$(docker exec "$r" sh -c 'redis-cli INFO server 2>/dev/null || valkey-cli INFO server 2>/dev/null' \
        | grep '^uptime_in_seconds:' | tr -d '\r' | cut -d: -f2)
  [ -z "$ev" ] || [ -z "$up" ] && continue
  [ "$up" -lt 600 ] && continue                       # need 10min uptime for stable rate
  [ "$ev" = "0" ] && continue
  rate_min=$(awk -v e="$ev" -v u="$up" 'BEGIN{printf "%.0f", e*60/u}')
  if [ "$rate_min" -ge "$REDIS_EVICTION_PER_MIN_CRIT" ] 2>/dev/null; then
    echo "HIGH|redis/$r|eviction rate ${rate_min}/min (${ev} total over $(( up/3600 ))h) — cache too small or key cardinality unbounded|raise maxmemory in apps/${r%_redis}/compose.yaml; investigate key namespace"
  elif [ "$rate_min" -ge "$REDIS_EVICTION_PER_MIN_WARN" ] 2>/dev/null; then
    echo "MED|redis/$r|eviction rate ${rate_min}/min (${ev} total over $(( up/3600 ))h) — working set exceeds maxmemory|raise maxmemory or audit TTL/key namespace"
  fi
done
