#!/bin/bash
# AIOStreams v2.30 removed a bunch of env vars: DEFAULT_<SVC>_API_KEY,
# FORCED_<SVC>_API_KEY, FORCE_<ADDON>_HOSTNAME/PORT/PROTOCOL,
# ALLOWED_REGEX_PATTERNS*, WHITELISTED_REGEX_*, LOG_CACHE_STATS_INTERVAL,
# PTT_PORT, PTT_SOCKET, FORCE_PUBLIC_PROXY_*. They no longer do anything;
# the canonical replacement is DEFAULT_SERVICE_CREDENTIALS /
# FORCED_SERVICE_CREDENTIALS (single env with multi-line entries) or
# STREAM_URL_MAPPINGS (for URL rewrites).
#
# Additionally: ANIME_DB_*_REFRESH_INTERVAL was reinterpreted from
# milliseconds to seconds in v2.30. Old ms-scale values get clamped to
# ~24.8 days and fire-on-startup — caught at runtime as "task interval
# exceeds 32-bit signed integer limit" warnings.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Only relevant on aiostreams >= v2.30
docker ps --format '{{.Names}} {{.Image}}' | grep '^aiostreams ' | grep -qE 'v2\.(3[0-9]|[4-9][0-9])' || exit 0

env_files="/opt/docker/apps/aiostreams/.env /opt/docker/apps/aiostreams/config.env"

# Deprecated key patterns (non-comment lines with a value)
hits=$(grep -hE '^(DEFAULT_|FORCED_)[A-Z]+_(API_KEY|PASSWORD|USERNAME|CLIENT_ID|CLIENT_SECRET|ENCODED_TOKEN)=.+' \
         $env_files 2>/dev/null | grep -v '^#' | grep -vE '=$' | wc -l)

if [ "$hits" -gt 0 ]; then
  echo "MED|env/aiostreams|$hits deprecated DEFAULT_/FORCED_<service>_<cred> env vars set — v2.30 ignores these|migrate to DEFAULT_SERVICE_CREDENTIALS / FORCED_SERVICE_CREDENTIALS (one 'serviceId.credentialId=value' per line); see docs.aiostreams.viren070.me/migrations/v2.30/"
fi

# Anime-DB interval unit check (values > 1e7 are almost certainly ms-era).
bad_interval=$(grep -hE '^ANIME_DB_[A-Z_]+_REFRESH_INTERVAL=[0-9]+' $env_files 2>/dev/null \
                | awk -F= '$2+0 > 10000000 {print}' | wc -l)
if [ "$bad_interval" -gt 0 ]; then
  echo "HIGH|env/aiostreams|$bad_interval ANIME_DB_*_REFRESH_INTERVAL values look like ms — v2.30 treats them as seconds (clamped to ~24.8d and fires immediately)|divide values by 1000: 86400000 → 86400 (daily), 604800000 → 604800 (weekly)"
fi

# Other v2.30-removed envs
for v in ALLOWED_REGEX_PATTERNS WHITELISTED_REGEX_PATTERNS LOG_CACHE_STATS_INTERVAL PTT_PORT PTT_SOCKET FORCE_PUBLIC_PROXY_HOST FORCE_PUBLIC_PROXY_PORT FORCE_PUBLIC_PROXY_PROTOCOL; do
  if grep -hE "^${v}=." $env_files 2>/dev/null | grep -qv '^#'; then
    echo "LOW|env/aiostreams|deprecated env $v set — v2.30 ignores|see migration guide for replacement"
  fi
done
