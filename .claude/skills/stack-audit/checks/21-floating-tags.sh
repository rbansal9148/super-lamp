#!/bin/bash
# Floating tags on RUNNING containers — recreate would silently change the image.
# (Already-pinned-by-digest images are exempt; only flag floating tags.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | while read -r ctr; do
  cfg_img=$(docker inspect "$ctr" --format '{{.Config.Image}}' 2>/dev/null)
  case "$cfg_img" in
    *@sha256:*) continue ;;  # already pinned by digest
    *:latest|*:edge|*:nightly|*:main|*:master|*:dev|*:rolling)
      cur_id=$(docker inspect "$ctr" --format '{{.Image}}' 2>/dev/null)
      short=${cur_id##sha256:}; short=${short:0:12}
      echo "MED|images|$ctr runs floating tag $cfg_img — recreate may pull a new digest silently (current image id: $short)|pin '$cfg_img' to @sha256:$short in the relevant apps/<svc>/compose.yaml"
      ;;
  esac
done
