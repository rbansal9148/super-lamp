#!/bin/bash
# Redis per-instance: hit rate, eviction policy, mem cap, leak keys.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

REDIS_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -E '_redis$' | sort)

for r in $REDIS_CONTAINERS; do
  # Try redis-cli, fall back to valkey-cli
  CLI=$(docker exec "$r" sh -c 'command -v redis-cli || command -v valkey-cli' 2>/dev/null | head -1)
  [ -z "$CLI" ] && continue

  stats=$(docker exec "$r" "$CLI" INFO stats 2>/dev/null)
  mem=$(docker exec "$r" "$CLI" INFO memory 2>/dev/null)
  policy=$(docker exec "$r" "$CLI" CONFIG GET maxmemory-policy 2>/dev/null | tail -1)
  maxmem=$(docker exec "$r" "$CLI" CONFIG GET maxmemory 2>/dev/null | tail -1)

  hits=$(echo "$stats" | awk -F: '/keyspace_hits:/{gsub(/\r/,"");print $2}')
  miss=$(echo "$stats" | awk -F: '/keyspace_misses:/{gsub(/\r/,"");print $2}')
  evicted=$(echo "$stats" | awk -F: '/evicted_keys:/{gsub(/\r/,"");print $2}')
  used=$(echo "$mem" | awk -F: '/used_memory:/{gsub(/\r/,"");print $2}' | head -1)

  # Hit rate (only meaningful with enough samples).
  # Skip allowlist for workloads with intrinsically low repeat rate (per-search
  # unique queries on a stremio addon backend — every torrent hash is mostly
  # unique, so cache hit rate is inherently low and not actionable).
  if [ -n "$hits" ] && [ -n "$miss" ] && [ "$((hits + miss))" -gt 1000 ] \
     && ! echo " $REDIS_HIT_RATE_ALLOW_LOW " | grep -q " $r "; then
    rate=$((100 * hits / (hits + miss)))
    if [ "$rate" -lt "$REDIS_HIT_RATE_WARN" ]; then
      echo "MED|redis/$r|hit rate ${rate}% (warn <${REDIS_HIT_RATE_WARN}%) — investigate TTLs or key cardinality|docker exec $r $CLI --scan | awk -F: '{print \$1\":\"\$2}' | sort | uniq -c | sort -rn"
    fi
  fi

  # Must have maxmemory + LRU
  if [ "$REDIS_MUST_HAVE_MAXMEMORY" = "true" ] && [ "$maxmem" = "0" ]; then
    echo "HIGH|redis/$r|maxmemory unbounded — OOM risk|add --maxmemory and --maxmemory-policy allkeys-lru to redis command in compose"
  fi
  if [ "$REDIS_MUST_HAVE_LRU_POLICY" = "true" ] && [ "$policy" != "allkeys-lru" ] && [ "$policy" != "volatile-lru" ]; then
    echo "MED|redis/$r|eviction policy is '$policy' (expected allkeys-lru) — keys never expire on memory pressure|add --maxmemory-policy allkeys-lru"
  fi

  # No-TTL key leak (sample at most 5000 keys for speed)
  if [ "$MODE" = "deep" ]; then
    no_ttl=$(docker exec "$r" "$CLI" --scan COUNT 5000 2>/dev/null | head -5000 | while read k; do
      ttl=$(docker exec "$r" "$CLI" TTL "$k" 2>/dev/null)
      [ "$ttl" = "-1" ] && echo x
    done | wc -l)
    if [ "$no_ttl" -ge "$REDIS_NO_TTL_KEYS_WARN" ]; then
      echo "MED|redis/$r|$no_ttl keys with no TTL (warn ≥${REDIS_NO_TTL_KEYS_WARN}) — slow leak|disable metrics-key accumulation in the upstream app"
    fi
  fi
done
