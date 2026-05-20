#!/bin/bash
# VPN coverage — services that touch public trackers / DHT / scrapers must
# route through gluetun. Two valid patterns on this stack:
#
#   A. Network-namespace tunnel: `network_mode: "container:gluetun"`. All
#      traffic exits via gluetun; service ports must be republished on
#      the gluetun container (see bitmagnet_vpn for reference).
#
#   B. Outbound HTTP proxy: HTTP_PROXY / HTTPS_PROXY / PROXY_URL /
#      <APP>_PROXY_URL env pointing to http://gluetun:8080 (gost sidecar).
#      Service stays on the default Docker network, inbound works via
#      Traefik unchanged, only egress is tunneled. Works for HTTP apps
#      that respect proxy env vars (e.g., python `requests`, node).
#
# This check flags services that do NEITHER. If they do A or B, pass.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Services that MUST tunnel egress. Exclude bitmagnet (has its own VPN).
MUST_TUNNEL="comet prowlarr zilean mediafusion jackett jackettio flaresolverr aiostreams"

for svc in $MUST_TUNNEL; do
  cf="/opt/docker/apps/$svc/compose.yaml"
  [ -f "$cf" ] || continue
  docker ps --format '{{.Names}}' | grep -qx "$svc" || continue

  # Pattern A: runtime network is gluetun (container:gluetun-id)
  netmode=$(docker inspect "$svc" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)
  case "$netmode" in
    container:gluetun*|service:gluetun) continue ;;
  esac

  # Pattern B: any env var ending in PROXY / PROXY_URL pointing to gluetun
  has_proxy=$(docker inspect "$svc" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -iE '^[A-Z_]*PROXY(_URL)?=.*gluetun' | head -1)
  if [ -n "$has_proxy" ]; then
    # Pass — service has at least partial egress tunneling.
    # (Some apps with foo_PROXY_URL only tunnel one subsystem; spot-check at
    # the app level if drift is suspected.)
    continue
  fi

  echo "HIGH|network|$svc touches public trackers but neither tunnels via gluetun network_mode nor sets HTTP_PROXY=gluetun:8080 — IP leak risk|set HTTP_PROXY=http://gluetun:8080 in apps/$svc/config.env (preferred) or add network_mode: container:gluetun to apps/$svc/compose.yaml (requires republishing ports on gluetun)"
done
