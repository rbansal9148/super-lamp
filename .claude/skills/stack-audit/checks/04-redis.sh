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
  # Per-instance threshold via REDIS_HIT_RATE_WARN_<container_name>; falls back
  # to REDIS_HIT_RATE_WARN. Lower thresholds are set in thresholds.sh for
  # content-metadata caches whose baseline is intrinsically below 70%.
  if [ -n "$hits" ] && [ -n "$miss" ] && [ "$((hits + miss))" -gt 1000 ]; then
    rate=$((100 * hits / (hits + miss)))
    threshold_var="REDIS_HIT_RATE_WARN_${r}"
    threshold="${!threshold_var:-$REDIS_HIT_RATE_WARN}"
    if [ "$rate" -lt "$threshold" ]; then
      echo "MED|redis/$r|hit rate ${rate}% (warn <${threshold}%) — investigate TTLs or key cardinality|docker exec $r $CLI --scan | awk -F: '{print \$1\":\"\$2}' | sort | uniq -c | sort -rn"
    fi
  fi

  # Must have maxmemory + LRU
  if [ "$REDIS_MUST_HAVE_MAXMEMORY" = "true" ] && [ "$maxmem" = "0" ]; then
    echo "HIGH|redis/$r|maxmemory unbounded — OOM risk|add --maxmemory and --maxmemory-policy allkeys-lru to redis command in compose"
  fi
  if [ "$REDIS_MUST_HAVE_LRU_POLICY" = "true" ] && [ "$policy" != "allkeys-lru" ] && [ "$policy" != "volatile-lru" ]; then
    echo "MED|redis/$r|eviction policy is '$policy' (expected allkeys-lru) — keys never expire on memory pressure|add --maxmemory-policy allkeys-lru"
  fi

  # No-TTL key leak (sample at most 5000 keys for speed).
  # Batch the TTL lookups through a single piped redis-cli invocation — one
  # `docker exec` per key (the previous shape) is thousands of round-trips and
  # blows deep-mode wall-clock past the per-check budget.
  if [ "$MODE" = "deep" ]; then
    keys=$(docker exec "$r" "$CLI" --scan COUNT 1000 2>/dev/null | head -5000)
    no_ttl=0
    if [ -n "$keys" ]; then
      no_ttl=$(printf 'TTL %s\n' $keys | docker exec -i "$r" "$CLI" 2>/dev/null \
                 | awk '$0=="-1"{n++} END{print n+0}')
    fi
    if [ "$no_ttl" -ge "$REDIS_NO_TTL_KEYS_WARN" ]; then
      echo "MED|redis/$r|$no_ttl keys with no TTL (warn ≥${REDIS_NO_TTL_KEYS_WARN}) — slow leak|disable metrics-key accumulation in the upstream app"
    fi
  fi
done
