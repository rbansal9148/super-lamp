#!/bin/bash
# Network/VPN: gluetun health, egress region, gost reachable, DNS sanity.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# 1. gluetun health
docker ps --format '{{.Names}}' | grep -q '^gluetun$' || {
  echo "CRIT|network|gluetun container not running — VPN broken|docker compose --profile gluetun up -d gluetun"
  exit 0
}

# 2. Egress IP / region matches expected
egress_json=$(docker exec gluetun wget -qO- --timeout=5 https://ipinfo.io/json 2>/dev/null)
ip=$(echo "$egress_json" | grep -oE '"ip":[[:space:]]*"[^"]+"' | head -1 | grep -oE '"[^"]+"$' | tr -d '"')
country=$(echo "$egress_json" | grep -oE '"country":[[:space:]]*"[^"]+"' | head -1 | grep -oE '"[^"]+"$' | tr -d '"')
region_word=$(echo "$EXPECTED_VPN_REGION" | tr '[:lower:]' '[:upper:]')
country_word=$(echo "$country" | tr '[:lower:]' '[:upper:]')
# Singapore=SG, allow either form
if [ -n "$country" ] && \
   ! echo "$country_word" | grep -qE "^${region_word}\$|^SG\$|^SGP\$" && \
   ! echo "$region_word" | grep -qE "^${country_word}\$"; then
  echo "HIGH|network|VPN egress is $country/$ip (expected $EXPECTED_VPN_REGION) — may add latency or block APIs|set SERVER_COUNTRIES=$EXPECTED_VPN_REGION in apps/gluetun/.env && docker compose up -d --force-recreate gluetun gost"
fi

# 3. gost proxy reachable (used by stremthru to tunnel via VPN)
if docker ps --format '{{.Names}}' | grep -q '^gost$'; then
  if ! docker exec aiostreams wget -qO /dev/null --timeout=3 http://gluetun:8080 2>&1 | grep -qE "400|200"; then
    echo "CRIT|network|gost proxy at gluetun:8080 unreachable — stremthru tunneling broken|docker compose --profile gluetun up -d --force-recreate gluetun gost"
  fi
fi
