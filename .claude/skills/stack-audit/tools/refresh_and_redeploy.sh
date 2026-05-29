#!/bin/bash
# refresh_and_redeploy.sh — unattended "catch up the drifted pins" job.
#
# 1. Runs refresh_image_pins.sh to move every resolvable @sha256 pin forward.
# 2. Recreates ONLY the project-aio services that are currently running AND
#    whose declared pin (after step 1) no longer matches their running image
#    digest. Stopped / profile-gated / not-included services are never started.
# 3. Verifies health of each recreated service and logs everything.
#
# Designed to survive Docker Hub's anonymous rate limit: a run that can't
# resolve every pin is a safe partial — it applies what it can and leaves the
# rest. In --managed mode it reschedules itself every 6h until either all pins
# resolve (fixer reports 0 unresolved) or MAX_ATTEMPTS is reached, then removes
# its own crontab entry.
#
# Flags:
#   --dry-run     report what would change; mutate nothing, recreate nothing.
#   --managed     self-scheduling mode: maintain/remove the recurring cron entry
#                 based on completion. (Used by the installed cron line only.)
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # cron-safe
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
ROOT="${DOCKER_ROOT:-/opt/docker}"
COMPOSE_FILE="$ROOT/compose.yaml"
PROJECT="aio"
LOG="$SKILL_DIR/refresh_and_redeploy.log"
STATE="$SKILL_DIR/.refresh_and_redeploy.attempts"
MAX_ATTEMPTS=6
CRON_TAG="# stack-audit:refresh_and_redeploy"

DRY=0; MANAGED=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --managed) MANAGED=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

remove_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  ( crontab -l 2>/dev/null | grep -vF "$CRON_TAG" ) | crontab - 2>/dev/null || true
  rm -f "$STATE"
  log "managed: removed self cron entry"
}

log "=== refresh_and_redeploy start (dry=$DRY managed=$MANAGED) ==="

# 1. Refresh pins (capture the fixer's unresolved count from its summary line).
fixer="$SKILL_DIR/tools/refresh_image_pins.sh"
if [ "$DRY" = 1 ]; then
  out="$(bash "$fixer" --dry-run 2>&1)"
else
  out="$(bash "$fixer" 2>&1)"
fi
printf '%s\n' "$out" | tee -a "$LOG" >/dev/null
unresolved="$(printf '%s\n' "$out" | sed -n 's/.*, \([0-9]\+\) unresolved\..*/\1/p' | tail -1)"
unresolved="${unresolved:-unknown}"
log "fixer: $(printf '%s\n' "$out" | grep -E 'Refreshed|DRY-RUN' | tail -1)  (unresolved=$unresolved)"

# 2. Compare declared pin vs running digest for each RUNNING aio service.
cfg="$(mktemp)"
if ! docker compose -f "$COMPOSE_FILE" config --format json > "$cfg" 2>>"$LOG"; then
  log "WARN: 'docker compose config' failed — skipping redeploy this run"
  rm -f "$cfg"
else
  running="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
             --format '{{.Label "com.docker.compose.service"}}' | sort -u)"
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    declared="$(jq -r --arg s "$svc" '.services[$s].image // empty' "$cfg")"
    case "$declared" in *@sha256:*) : ;; *) continue ;; esac
    decl_dig="${declared##*@}"
    run_dig="$(docker inspect "$svc" --format '{{.Image}}' 2>/dev/null)"
    [ "$decl_dig" = "$run_dig" ] && continue
    log "DRIFT $svc: running ${run_dig:0:19}… -> declared ${decl_dig:0:19}…"
    if [ "$DRY" = 1 ]; then log "  (dry-run: would recreate $svc)"; continue; fi
    if docker compose -f "$COMPOSE_FILE" up -d "$svc" >>"$LOG" 2>&1; then
      for i in $(seq 1 30); do
        st="$(docker inspect "$svc" --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' 2>/dev/null)"
        case "$st" in running/healthy|running/nohealth) break ;; esac
        sleep 3
      done
      log "  recreated $svc -> ${st:-unknown}"
    else
      log "  ERROR: recreate $svc failed (see log) — left on previous image"
    fi
  done <<< "$running"
  rm -f "$cfg"
fi

# 3. Managed-mode self-scheduling.
if [ "$MANAGED" = 1 ] && [ "$DRY" = 0 ]; then
  attempts="$(cat "$STATE" 2>/dev/null || echo 0)"; attempts=$((attempts+1))
  echo "$attempts" > "$STATE"
  if [ "$unresolved" = "0" ]; then
    log "managed: all pins resolved — done after $attempts attempt(s)"
    remove_cron
  elif [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "managed: gave up after $attempts attempts (unresolved=$unresolved) — removing cron"
    remove_cron
  else
    log "managed: $unresolved still unresolved (attempt $attempts/$MAX_ATTEMPTS) — will retry next window"
  fi
fi

log "=== refresh_and_redeploy end ==="
