#!/bin/bash
# prune_docker.sh — safe Docker housekeeping:
#   1. Remove dangling images (untagged, not referenced).
#   2. Remove the build cache.
# Skips: `docker system prune --all` (which would remove ALL unused images,
# including ones for stopped containers) — too aggressive for this stack.
#
# Flags:
#   --dry-run   show what WOULD be freed without removing
#   --aggressive  also runs `docker image prune -a` (CAREFUL: removes images
#                 not currently used by any container, including ones for
#                 stopped/disabled services you may want to revive later)

set -uo pipefail
DRY=0
AGGR=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --aggressive) AGGR=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  esac
done

if [ "$DRY" -eq 1 ]; then
  echo "=== docker system df ==="
  docker system df
  exit 0
fi

echo "=== before ==="
docker system df | tail -5
echo "=== prune dangling images ==="
docker image prune -f
echo "=== prune build cache ==="
docker builder prune -f 2>/dev/null || true
if [ "$AGGR" -eq 1 ]; then
  echo "=== AGGRESSIVE: prune unused images ==="
  docker image prune -a -f
fi
echo "=== after ==="
docker system df | tail -5
