#!/bin/bash
# Surface Prowlarr indexers with bad health (100% query failure OR avg
# response time > N seconds). A single 80s+ indexer is a guaranteed source
# of aiostreams Prowlarr timeouts under concurrent queries: one slow lane
# blocks the whole batch. 100%-failure indexers waste request slots with
# zero return.
#
# Requires the BUILTIN_PROWLARR_API_KEY env var, which aiostreams already
# uses; we read it from the aiostreams .env file rather than hardcoding.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${PROWLARR_INDEXER_FAIL_RATE_WARN:=50}"     # %
: "${PROWLARR_INDEXER_AVG_MS_WARN:=5000}"
: "${PROWLARR_INDEXER_AVG_MS_HIGH:=30000}"
: "${PROWLARR_MIN_QUERIES_FOR_STATS:=5}"

docker ps --format '{{.Names}}' | grep -q '^prowlarr$' || exit 0

# Pull API key from aiostreams env (the canonical place; falls back to env file)
key=$(grep -E '^BUILTIN_PROWLARR_API_KEY=' /opt/docker/apps/aiostreams/.env 2>/dev/null | cut -d= -f2-)
[ -z "$key" ] && exit 0   # can't query without key; not actionable

stats=$(docker run --rm --network aio_network curlimages/curl:latest -s --max-time 5 \
  'http://prowlarr:9696/api/v1/indexerstats' \
  -H "X-Api-Key: $key" 2>/dev/null)
indexers=$(docker run --rm --network aio_network curlimages/curl:latest -s --max-time 5 \
  'http://prowlarr:9696/api/v1/indexer' \
  -H "X-Api-Key: $key" 2>/dev/null)

[ -z "$stats" ] || [ -z "$indexers" ] && exit 0

python3 - <<PY
import json
try:
    d = json.loads('''$stats''')
    enabled = {i['name'] for i in json.loads('''$indexers''') if i.get('enable')}
except Exception:
    exit(0)
for s in d.get('indexers', []):
    name = s.get('indexerName','?')
    # Skip already-disabled indexers — stats are cumulative; their bad numbers
    # are historical, not actionable.
    if name not in enabled:
        continue
    q = s.get('numberOfQueries',0)
    f = s.get('numberOfFailedQueries',0)
    avg = s.get('averageResponseTime',0)
    if q < ${PROWLARR_MIN_QUERIES_FOR_STATS}:
        continue
    rate = (f * 100 / q) if q else 0
    # Failure-rate signal
    if rate >= 100:
        print(f"HIGH|streaming/prowlarr|indexer '{name}' has 100% failure ({f}/{q}) — wasting request slots|disable via Prowlarr API: PUT /api/v1/indexer/<id> with enable=false")
    elif rate >= ${PROWLARR_INDEXER_FAIL_RATE_WARN}:
        print(f"MED|streaming/prowlarr|indexer '{name}' fails {rate:.0f}% ({f}/{q}) — degrades concurrent search latency|investigate; consider disable")
    # Latency signal
    if avg >= ${PROWLARR_INDEXER_AVG_MS_HIGH}:
        print(f"HIGH|streaming/prowlarr|indexer '{name}' averages {avg}ms — single slow lane blocks parallel aiostreams searches past timeout|disable via Prowlarr API or lower its priority")
    elif avg >= ${PROWLARR_INDEXER_AVG_MS_WARN}:
        print(f"MED|streaming/prowlarr|indexer '{name}' averages {avg}ms (>5s) — at risk of timing out under load|monitor; consider lowering priority")
PY
