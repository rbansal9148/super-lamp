#!/bin/bash
# Container-level: restart loops, OOM, healthchecks, log sizes, mem limits, image pinning.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Restart loops + OOM
docker ps -a --format '{{.Names}}' | while read c; do
  rc=$(docker inspect --format '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)
  oom=$(docker inspect --format '{{.State.OOMKilled}}' "$c" 2>/dev/null || echo false)
  if [ "$oom" = "true" ]; then
    echo "CRIT|containers|$c was OOM-killed|docker logs --tail=100 $c; check mem_limit in compose"
  fi
  if [ "$rc" -ge "$RESTART_COUNT_WARN" ] 2>/dev/null; then
    # Distinguish an active loop from a healed one by checking current uptime.
    # Docker doesn't track restart history, so we proxy: long uptime => loop has stopped.
    started=$(docker inspect --format '{{.State.StartedAt}}' "$c" 2>/dev/null)
    up_min=0
    if [ -n "$started" ]; then
      up_min=$(( ( $(date -u +%s) - $(date -u -d "$started" +%s 2>/dev/null || echo 0) ) / 60 ))
    fi
    if [ "$up_min" -ge "$RESTART_LOOP_UPTIME_MIN" ] 2>/dev/null; then
      echo "LOW|containers|$c has $rc historical restarts but has been up ${up_min}m (loop appears resolved)|no action; cumulative count clears on container recreate"
    else
      echo "HIGH|containers|$c has $rc restarts (warn ≥${RESTART_COUNT_WARN}), uptime ${up_min}m (loop active)|docker logs --tail=50 $c; investigate root cause"
    fi
  fi
done

# Healthcheck presence (for services that should have one)
should_have_healthcheck="bitmagnet comet mediafusion stremthru aiostreams aiometadata prowlarr zilean traefik gluetun authelia"
for c in $should_have_healthcheck; do
  if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    has=$(docker inspect --format '{{if .State.Health}}HAS{{else}}NONE{{end}}' "$c" 2>/dev/null)
    if [ "$has" = "NONE" ]; then
      echo "MED|containers|$c lacks healthcheck — orchestrator can't detect hung state|add healthcheck to apps/$c/compose.yaml"
    fi
  fi
done

# Container log file sizes (uncapped logs eat disk)
docker ps --format '{{.Names}}' | while read c; do
  log=$(docker inspect --format '{{.LogPath}}' "$c" 2>/dev/null)
  if [ -n "$log" ] && [ -f "$log" ]; then
    mb=$(( $(sudo stat -c '%s' "$log" 2>/dev/null || echo 0) / 1024 / 1024 ))
    if [ "$mb" -ge "$CONTAINER_LOG_MB_CRIT" ]; then
      echo "CRIT|containers|$c log file ${mb}MB (crit ≥${CONTAINER_LOG_MB_CRIT})|sudo truncate -s 0 $log; investigate verbose logging"
    elif [ "$mb" -ge "$CONTAINER_LOG_MB_WARN" ]; then
      echo "MED|containers|$c log file ${mb}MB (warn ≥${CONTAINER_LOG_MB_WARN})|sudo truncate -s 0 $log; lower log level in $c"
    fi
  fi
done

# Memory usage vs cap (for containers with explicit mem_limit)
docker ps --format '{{.Names}}' | while read c; do
  cap=$(docker inspect --format '{{.HostConfig.Memory}}' "$c" 2>/dev/null)
  [ "$cap" = "0" ] && continue
  used=$(docker stats --no-stream --format '{{.MemUsage}}' "$c" 2>/dev/null | awk -F'/' '{print $1}' | sed 's/[^0-9.]//g')
  pct=$(docker stats --no-stream --format '{{.MemPerc}}' "$c" 2>/dev/null | tr -d '%')
  [ -z "$pct" ] && continue
  pct_int=$(printf '%.0f' "$pct")
  if [ "$pct_int" -ge "$MEM_PCT_OF_CAP_CRIT" ] 2>/dev/null; then
    echo "CRIT|containers|$c memory ${pct}% of cap (crit ≥${MEM_PCT_OF_CAP_CRIT})|raise mem_limit in apps/$c/compose.yaml"
  elif [ "$pct_int" -ge "$MEM_PCT_OF_CAP_WARN" ] 2>/dev/null; then
    echo "HIGH|containers|$c memory ${pct}% of cap (warn ≥${MEM_PCT_OF_CAP_WARN})|raise mem_limit in apps/$c/compose.yaml"
  fi
done

# Mem_limit absence on big services
big_services="bitmagnet bitmagnet_postgres comet mediafusion aiostreams stremthru stremthru_postgres"
for c in $big_services; do
  docker ps --format '{{.Names}}' | grep -q "^${c}$" || continue
  cap=$(docker inspect --format '{{.HostConfig.Memory}}' "$c" 2>/dev/null)
  if [ "$cap" = "0" ]; then
    echo "MED|containers|$c has no mem_limit — one runaway can OOM the host|add mem_limit to apps/${c%%_*}/compose.yaml"
  fi
done

# Image pinning for streaming addons (avoid :latest drift)
pinned_required="comet stremthru prowlarr bitmagnet zilean"
for c in $pinned_required; do
  docker ps --format '{{.Names}}' | grep -q "^${c}$" || continue
  img=$(docker inspect --format '{{.Config.Image}}' "$c" 2>/dev/null)
  if echo "$img" | grep -qE ':latest$|^[^@]*$'; then
    echo "LOW|containers|$c image not pinned by digest ($img) — risk of silent breakage on pull|update apps/$c/compose.yaml with @sha256"
  fi
done
