#!/bin/bash
# Stale container-network-namespace check.
#
# When container A uses `network_mode: service:B` (or `container:B`), Docker
# resolves that to `container:<B's id>` at A's creation time. If B is later
# recreated (new id), A's stored reference becomes stale: A's packets enter
# a dangling/disappearing namespace, manifesting as "connection refused" from
# other containers and silent traffic loss.
#
# This check finds every running container whose NetworkMode is
# `container:<id>` and verifies the referenced id still belongs to a running
# container. If the target id is GONE (recreated) or NOT RUNNING (stopped),
# we emit a CRIT.

set -u

# Map container_id → name for nicer messages.
declare -A NAME_BY_ID
while IFS=$'\t' read -r id name; do
  NAME_BY_ID["$id"]="$name"
done < <(docker ps -a --format '{{.ID}}	{{.Names}}' --no-trunc)

# For each RUNNING container, inspect its NetworkMode.
docker ps -q | while read -r cid; do
  full_id=$(docker inspect "$cid" -f '{{.Id}}' 2>/dev/null)
  name=$(docker inspect "$cid" -f '{{.Name}}' 2>/dev/null | sed 's,^/,,')
  netmode=$(docker inspect "$cid" -f '{{.HostConfig.NetworkMode}}' 2>/dev/null)
  case "$netmode" in
    container:*)
      target="${netmode#container:}"
      # Lookup target's status. Try id first; if not found, possibly a name.
      target_state=$(docker inspect "$target" -f '{{.State.Status}}' 2>/dev/null) || target_state=""
      target_name="${NAME_BY_ID[$target]:-$target}"
      target_short=$(printf '%s' "$target" | cut -c1-12)
      if [ -z "$target_state" ]; then
        # Referenced container does not exist — usually means the depender's
        # target was recreated and the depender wasn't restarted alongside.
        echo "CRIT|network|$name has network_mode container:${target_short}… but that container no longer exists (recreated without restarting $name)|docker compose up -d --force-recreate $name|recreate_dependents"
      elif [ "$target_state" != "running" ]; then
        echo "HIGH|network|$name has network_mode container:${target_short}… (target=${target_name}) which is in state '$target_state'|docker compose up -d $target_name $name|recreate_dependents"
      fi
      ;;
  esac
done
