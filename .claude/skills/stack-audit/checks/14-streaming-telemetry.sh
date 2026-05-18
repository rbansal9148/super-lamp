#!/bin/bash
# Streaming telemetry: per-addon contribution, AIOStreams cache-bypass rate.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | grep -q '^aiostreams$' || exit 0

# 1. Per-addon contribution (top N requests in recent log)
data=$(docker logs --since 1h aiostreams 2>&1)
echo "$data" | grep -qE "Found .* error streams from" || exit 0

# Per-addon error counts in last hour
echo "$data" | grep -oE "Found [0-9]+ error streams from [A-Za-z0-9 ]+ errorStreams=[A-Za-z0-9 ]+" | \
  sed -E 's/.*errorStreams=//' | sort | uniq -c | sort -rn | head -3 | while read cnt addon; do
    [ -z "$cnt" ] && continue
    [ "$cnt" -ge 5 ] 2>/dev/null && \
      echo "MED|streaming/aiostreams|addon '$addon' produced $cnt error-stream batches in last hour|consider disabling or moving to background-only in AIOStreams UI"
  done

# 2. Cache-bypass rate (cacheKey=undefined indicates request not cacheable)
total=$(echo "$data" | grep -c "Handling stream request" || echo 0)
undef=$(echo "$data" | grep -c "cacheKey=undefined" || echo 0)
if [ "$total" -gt 10 ]; then
  pct=$(( 100 * undef / (total * 8) ))  # ~8 fetches per request avg
  if [ "$pct" -gt 80 ]; then
    echo "LOW|streaming/aiostreams|~${pct}% of upstream addon calls bypass cache (cacheKey=undefined)|verify STREAM_CACHE_TTL, MANIFEST_CACHE_TTL are set in aiostreams .env"
  fi
fi

# 3. Comet "useCachedResultsOnly" recommendation when DEBRID_CACHE_TTL is high
debrid_ttl=$(grep '^DEBRID_CACHE_TTL=' /opt/docker/apps/comet/.env 2>/dev/null | cut -d= -f2 | awk '{print $1}')
if [ -n "$debrid_ttl" ] && [ "$debrid_ttl" -ge 86400 ]; then
  echo "LOW|streaming/comet|DEBRID_CACHE_TTL=${debrid_ttl}s (≥1d) — once warmed, AIOStreams could set Comet preset useCachedResultsOnly=true for faster cold queries|UI toggle"
fi
