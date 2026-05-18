#!/bin/bash
# Docker socket mounts must be :ro unless the service legitimately manages
# containers (portainer/dockge/arcane/watchtower) or uses actions (dozzle).
# Anything else with RW socket is an unnecessary container-escape surface.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Services that REQUIRE write access to docker.sock.
NEEDS_RW="portainer dockge arcane watchtower dozzle"

for cf in /opt/docker/apps/*/compose.yaml; do
  svc=$(basename "$(dirname "$cf")")
  # Find sock mount line; ignore if no mount declared
  grep -nE '/var/run/docker\.sock' "$cf" 2>/dev/null | while read -r line; do
    lineno=${line%%:*}
    rest=${line#*:}
    # Already :ro? skip
    echo "$rest" | grep -qE ':ro["'"'"']?\s*$' && continue
    # In opt-out list? skip
    echo " $NEEDS_RW " | grep -q " $svc " && continue
    echo "HIGH|security|$svc mounts /var/run/docker.sock RW ($cf:$lineno) — container escape surface|append ':ro' to the docker.sock mount in $cf"
  done
done
