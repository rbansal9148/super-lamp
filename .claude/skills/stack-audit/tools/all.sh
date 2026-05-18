#!/bin/bash
# all.sh — run every fixer in the recommended order. Each tool keeps its own
# idempotence guarantees, so re-running this is a no-op on a clean stack.
#
# Order matches SKILL.md's "Typical post-audit flow":
#   1. secure_envs       — env hygiene (chmod 600, git untrack)
#   2. sweep_split       — split secrets/config across every apps/<svc>/.env
#   3. add_logging       — json-file 10m × 3 on every service missing it
#   4. vacuum_stale      — vacuum bloated/never-autovacuumed tables
#   5. checkpoint_wal    — recycle pg_wal segments
#   6. prune_docker      — remove dangling images + build cache
#   7. lock_public_ports — comment out ports: on Traefik-fronted services
#
# Flags:
#   --dry-run        propagate --dry-run to every tool
#   --only=A,B       restrict to these fixer names (no .sh suffix)
#   --skip=A,B       run all except these
#   --halt-on-error  stop the sequence at the first non-zero exit (default: continue)

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
TOOLS_DIR="$SKILL_DIR/tools"

DRY=""
ONLY=""
SKIP=""
HALT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY="--dry-run" ;;
    --only=*) ONLY="${a#--only=}" ;;
    --skip=*) SKIP="${a#--skip=}" ;;
    --halt-on-error) HALT=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

. "$TOOLS_DIR/lib/audit_log.sh"
. "$TOOLS_DIR/lib/preflight.sh"
preflight_default

in_list() { case ",$2," in *",$1,"*) return 0;; esac; return 1; }

FIXERS=(
  secure_envs
  sweep_split
  add_logging
  vacuum_stale
  checkpoint_wal
  prune_docker
  lock_public_ports
  recreate_dependents
)

OVERALL=0
RESULTS=()
TS_START=$(date -u +%s)

for f in "${FIXERS[@]}"; do
  if [ -n "$ONLY" ] && ! in_list "$f" "$ONLY"; then continue; fi
  if [ -n "$SKIP" ] && in_list "$f" "$SKIP"; then continue; fi
  script="$TOOLS_DIR/$f.sh"
  [ -x "$script" ] || { echo "[all] missing $script"; OVERALL=1; continue; }

  printf "\n=== %s%s ===\n" "$f" "${DRY:+ $DRY}"
  if bash "$script" $DRY; then
    rc=0
  else
    rc=$?
  fi
  RESULTS+=("$f:$rc")
  AUDIT_TOOL="all.sh" AUDIT_ARGS="$f $DRY" AUDIT_DRY_RUN="$([ -n "$DRY" ] && echo 1 || echo 0)" \
    audit_log_emit "$rc"
  if [ "$rc" -ne 0 ]; then
    OVERALL=1
    [ "$HALT" -eq 1 ] && { echo "[all] HALTING due to $f exit=$rc"; break; }
  fi
done

DUR=$(( $(date -u +%s) - TS_START ))
printf "\n=== summary (%ds) ===\n" "$DUR"
printf "%s\n" "${RESULTS[@]}"
exit "$OVERALL"
