#!/bin/bash
# Cross-cutting: TLS expiry, orphan data dirs, specific known upstream bugs.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# 1. TLS cert days-to-expiry (read traefik acme.json)
ACME=/opt/docker/data/traefik/acme.json
if [ -f "$ACME" ] && command -v openssl >/dev/null 2>&1; then
  # Smallest days-until-expiry across all certs in acme.json
  min_days=$(sudo grep -oE '"NotAfter":"[^"]+"' "$ACME" 2>/dev/null | \
    sed 's/"NotAfter":"//;s/"$//' | \
    while read d; do
      [ -z "$d" ] && continue
      ts=$(date -d "$d" +%s 2>/dev/null) || continue
      now=$(date +%s)
      echo $(( (ts - now) / 86400 ))
    done | sort -n | head -1)
  if [ -n "$min_days" ]; then
    if [ "$min_days" -le 7 ]; then
      echo "CRIT|tls|cert expires in ${min_days} days|verify Cloudflare DNS challenge working; check traefik logs for ACME errors"
    elif [ "$min_days" -le 21 ]; then
      echo "MED|tls|cert expires in ${min_days} days — Let's Encrypt renewal window approaching|monitor traefik logs"
    fi
  fi
fi

# 2. Orphan data dirs — services with data on disk but no running container
if [ -d /opt/docker/data ]; then
  for dir in /opt/docker/data/*/; do
    name=$(basename "$dir")
    # Skip if in expected allowlist
    if echo " $EXPECTED_DATA_DIRS " | grep -q " $name "; then
      continue
    fi
    # Skip if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${name}$\|^${name}_"; then
      continue
    fi
    size=$(sudo du -shx "$dir" 2>/dev/null | awk '{print $1}')
    echo "LOW|storage|orphan data dir /opt/docker/data/$name (${size}) — service not running|review and delete if no longer needed: sudo rm -rf '$dir'"
  done
fi

# 3. StremThru mylist deserialization bug (known upstream issue with TorBox API)
if docker ps --format '{{.Names}}' | grep -q '^stremthru$'; then
  cnt=$(docker logs --since 1h stremthru 2>&1 | grep -c 'cannot unmarshal array into Go struct field response\[.*torbox.Torrent\].data' || echo 0)
  if [ "$cnt" -gt 0 ]; then
    echo "HIGH|stremthru|TorBox /mylist API response can't be parsed ($cnt times in last hour) — known upstream bug v0.101.5|file issue at github.com/MunifTanjim/stremthru/issues; affects playback path latency"
  fi
fi

# 4. Pinned image staleness — has upstream :latest moved beyond our pinned digest?
declare -A pinned_repos=(
  [comet]="g0ldyy/comet"
  [stremthru]="muniftanjim/stremthru"
  [prowlarr]="ghcr.io/hotio/prowlarr"
  [bitmagnet]="ghcr.io/bitmagnet-io/bitmagnet"
  [zilean]="ipromknight/zilean"
)
for svc in "${!pinned_repos[@]}"; do
  docker ps --format '{{.Names}}' | grep -q "^${svc}$" || continue
  img=$(docker inspect "$svc" --format '{{.Config.Image}}' 2>/dev/null)
  echo "$img" | grep -q '@sha256:' || continue
  pinned_sha=$(echo "$img" | grep -oE 'sha256:[a-f0-9]+')
  # Compare to local :latest if pulled; if no local :latest, skip (avoid network in audit).
  # Use RepoDigests (manifest sha) — NOT .Id (config-blob hash). They're different hashes;
  # comparing Id to pinned_sha would always mismatch and fire spuriously.
  latest_digest=$(docker image inspect "${pinned_repos[$svc]}:latest" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | grep -oE 'sha256:[a-f0-9]+' | head -1)
  [ -z "$latest_digest" ] && continue
  [ "$pinned_sha" = "$latest_digest" ] && continue
  # Use Created timestamps (ISO 8601 sorts lexically) to know which is newer.
  # If pinned is newer or equal, the pin is intentional — stay silent.
  pinned_created=$(docker image inspect "$img" --format '{{.Created}}' 2>/dev/null)
  latest_created=$(docker image inspect "${pinned_repos[$svc]}:latest" --format '{{.Created}}' 2>/dev/null)
  [ -z "$latest_created" ] && continue
  [ -z "$pinned_created" ] && continue
  if [[ "$pinned_created" < "$latest_created" ]]; then
    echo "LOW|containers|$svc is pinned at $(echo $pinned_sha | head -c 19)... but local :latest is newer ($(echo $latest_digest | head -c 19)...)|review changelog; docker compose up -d --pull always after updating compose.yaml"
  fi
done
