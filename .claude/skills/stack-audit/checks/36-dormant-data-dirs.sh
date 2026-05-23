#!/bin/bash
# Data directories under /opt/docker/data/ whose service is NOT in any
# running container — likely a service that was commented out of the main
# compose.yaml but whose data dir was never reclaimed. Example: this stack
# carried 10.9GB of orphan immich data after the service was disabled.
#
# Skips trivially-small dirs (<100MB) to avoid noise from in-flight or
# transient temp dirs.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${DORMANT_DATA_MB_WARN:=100}"
: "${DORMANT_DATA_MB_HIGH:=5000}"
# Space-separated names to skip — intentionally-kept data for currently-disabled services.
: "${DORMANT_DATA_IGNORE:=immich}"

[ -d /opt/docker/data ] || exit 0

running=$(docker ps --format '{{.Names}}')

for d in /opt/docker/data/*/; do
  name=$(basename "$d")
  # If the service name (or service_<anything>) is running, skip
  if echo "$running" | grep -qE "^${name}(\$|_)"; then
    continue
  fi
  # Skip names explicitly allowlisted as intentionally-kept dormant data.
  case " $DORMANT_DATA_IGNORE " in *" $name "*) continue;; esac
  sz=$(du -sm "$d" 2>/dev/null | awk '{print $1}')
  [ -z "$sz" ] && continue
  if [ "$sz" -ge "$DORMANT_DATA_MB_HIGH" ]; then
    echo "MED|storage|/opt/docker/data/${name} is ${sz}MB but no '${name}' container is running — orphan data|verify service is intended dormant; if so: sudo rm -rf /opt/docker/data/${name} (after backup if applicable)"
  elif [ "$sz" -ge "$DORMANT_DATA_MB_WARN" ]; then
    echo "LOW|storage|/opt/docker/data/${name} is ${sz}MB but no '${name}' container is running|confirm intentionally dormant; consider reclaiming with: sudo rm -rf /opt/docker/data/${name}"
  fi
done
