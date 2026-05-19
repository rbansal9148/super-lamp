#!/bin/bash
# Postgres config tuning — flag instances that didn't override defaults.
# Default shared_buffers is 128MB, work_mem 4MB; safe-not-fast on a stack
# this size.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Tiny DBs that genuinely don't need tuning — opt out.
SKIP="tandoor zipline plausible"

for cf in /opt/docker/apps/*/compose.yaml; do
  app=$(basename "$(dirname "$cf")")
  echo " $SKIP " | grep -q " $app " && continue
  # Find each postgres service in this file
  grep -nE '^\s+image:\s+postgres' "$cf" 2>/dev/null | while read -r line; do
    lineno=${line%%:*}
    # Find the service-name header above this line (2-space indent)
    svc=$(awk -v L=$lineno 'NR<L && /^  [A-Za-z0-9_-]+:\s*$/ {gsub(/[: ]/,"",$0); s=$0} END{print s}' "$cf")
    # Skip prune sidecars — they don't host a database, they just run psql
    case "$svc" in *_prune|*_history_prune) continue ;; esac
    # Look ahead 60 lines for `command:` with `shared_buffers`
    has_tuning=$(sed -n "${lineno},$((lineno+60))p" "$cf" | grep -cE 'shared_buffers=' || true)
    if [ "$has_tuning" = "0" ]; then
      echo "MED|postgres|$svc ($app) uses default shared_buffers (128MB) — set explicit tuning|add 'command: [\"postgres\", \"-c\", \"shared_buffers=256MB\", \"-c\", \"work_mem=16MB\"]' to $cf"
    fi
  done
done
