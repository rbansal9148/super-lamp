#!/bin/bash
# VPN coverage — services that touch public trackers / DHT / scrapers MUST
# route through gluetun. Codified knowledge: this list is the source of truth
# for "what needs to be behind the VPN on this stack".
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Services that MUST be behind gluetun. Exception: bitmagnet has its own
# bitmagnet_vpn so it doesn't need the main gluetun network.
MUST_TUNNEL="comet prowlarr zilean mediafusion jackett jackettio flaresolverr aiostreams"

# Services with their own VPN sidecar — exempt from main-gluetun check.
HAS_OWN_VPN="bitmagnet"

for svc in $MUST_TUNNEL; do
  cf="/opt/docker/apps/$svc/compose.yaml"
  [ -f "$cf" ] || continue
  # Check container is actually running (skip if profile-disabled)
  docker ps --format '{{.Names}}' | grep -qx "$svc" || continue
  # Inspect runtime network mode
  netmode=$(docker inspect "$svc" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)
  case "$netmode" in
    container:gluetun*|service:gluetun) continue ;;
  esac
  # Distinguish "declared but drifted" from "not declared at all".
  # Exclude commented-out declarations.
  if grep -qE '^\s*network_mode:\s*"?(container:gluetun|service:gluetun)' "$cf"; then
    echo "HIGH|network|$svc compose has gluetun network_mode but runtime shows $netmode — drift|docker compose --profile all up -d $svc"
  else
    echo "HIGH|network|$svc touches public trackers but is not behind gluetun (network_mode=$netmode) — IP leak risk|uncomment/add 'network_mode: \"container:gluetun\"' in apps/$svc/compose.yaml; remove direct traefik labels (route via gost)"
  fi
done
