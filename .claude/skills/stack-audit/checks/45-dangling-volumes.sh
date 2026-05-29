#!/bin/bash
# Dangling Docker volumes — anonymous volumes referenced by no container, left
# behind by failed/rolled-back compose operations and container removals. They
# silently tie up space under /var/lib/docker/volumes. Distinct from check 15
# (dangling IMAGES) and 36 (orphan data DIRS under /opt/docker/data).
#
# The `dangling=true` filter excludes every named/in-use volume, so this never
# flags a volume that's attached to a (running or stopped) container.
#
# No FIX_TOOL: `prune_docker.sh` deliberately does NOT touch volumes (volume
# removal is data deletion). The fix command is given explicitly so it's a
# conscious choice, not an auto-applied one.
#
# Tunables (thresholds.sh): DANGLING_VOLUME_WARN / DANGLING_VOLUME_HIGH.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
: "${DANGLING_VOLUME_WARN:=5}"
: "${DANGLING_VOLUME_HIGH:=20}"

command -v docker >/dev/null 2>&1 || exit 0
count="$(docker volume ls --filter dangling=true --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')"
case "$count" in ''|*[!0-9]*) exit 0 ;; esac

if   [ "$count" -ge "$DANGLING_VOLUME_HIGH" ]; then
  echo "MED|storage|$count dangling Docker volumes (anonymous, unreferenced) tying up disk|review then reclaim: docker volume ls -f dangling=true; docker volume prune -f"
elif [ "$count" -ge "$DANGLING_VOLUME_WARN" ]; then
  echo "LOW|storage|$count dangling Docker volumes (anonymous, unreferenced)|review then reclaim: docker volume ls -f dangling=true; docker volume prune -f"
fi
