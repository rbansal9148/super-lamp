#!/bin/bash
# recreate_dependents.sh — find every running container whose
# `network_mode: container:<id>` references a container that no longer
# exists (target was recreated, depender wasn't), then `docker compose up
# -d --force-recreate <depender>` to rejoin the live namespace.
#
# This is the deterministic fix for the gost-after-gluetun-recreate footgun:
# whenever a "service:X" target is recreated, every container in compose
# using `network_mode: service:X` (or `container:X`) must follow.
#
# Idempotent: a depender on a healthy target is left alone.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
. "$SKILL_DIR/tools/lib/preflight.sh"
preflight_default
ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

stale_dependers=()
docker ps -q | while read -r cid; do
  name=$(docker inspect "$cid" -f '{{.Name}}' 2>/dev/null | sed 's,^/,,')
  netmode=$(docker inspect "$cid" -f '{{.HostConfig.NetworkMode}}' 2>/dev/null)
  case "$netmode" in
    container:*)
      target="${netmode#container:}"
      state=$(docker inspect "$target" -f '{{.State.Status}}' 2>/dev/null || true)
      if [ -z "$state" ] || [ "$state" != "running" ]; then
        echo "  stale: $name (target ${target:0:12} state='${state:-MISSING}')"
        if [ "$DRY" -eq 1 ]; then
          echo "    WOULD: docker compose up -d --force-recreate $name"
        else
          (cd "$ROOT" && docker compose up -d --force-recreate "$name" >/dev/null 2>&1 \
            && echo "    recreated $name" \
            || echo "    WARN: failed to recreate $name")
        fi
      fi
      ;;
  esac
done
