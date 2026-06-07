#!/bin/bash
# Stack audit — main orchestrator (k8s / k3s + ArgoCD).
# Runs all checks under checks/, aggregates findings, prints a prioritized punch list.
#
# Finding format (pipe-separated):
#   SEVERITY|DOMAIN|FINDING|FIX_COMMAND
#
# SEVERITY ∈ {CRIT,HIGH,MED,LOW,OK}; FIX_COMMAND is a literal command the operator can run.
#
# Scope note: this audits CONFIG/SIZING quality that has no continuous metric (resource
# allocation, image pinning, probe presence, PVC reclaim). Runtime failure classes
# (crashloop, OOMKilled, disk-full, pod-not-ready, cert-expiry, ArgoCD drift) are
# continuous Grafana alarms now — see gitops/manifests/observability/alerts/ — NOT audit
# checks, so they are intentionally absent here.

set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_DIR="$SKILL_DIR/checks"
THRESHOLDS="$SKILL_DIR/thresholds.sh"

# Parse args
MODE="quick"
OUTPUT="md"
ONLY=""
SUMMARY=0
for a in "$@"; do
  case "$a" in
    --deep) MODE="deep" ;;
    --quick) MODE="quick" ;;
    --json) OUTPUT="json" ;;
    --summary) SUMMARY=1 ;;
    --only=*) ONLY="${a#--only=}" ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--quick|--deep] [--json|--summary] [--only=01-resource-allocation,02-image-pins]

Modes:
  --quick   (default) read-only fast checks
  --deep    larger per-check timeout for slower cluster round-trips

Output:
  --json     machine-readable
  --summary  just severity counts, one line
  (default)  markdown punch list

Filtering:
  --only=NAME[,NAME]   only run these check scripts (by filename stem)

Suppression:
  Add a regex per line to $SKILL_DIR/.audit-ignore to mute known-acceptable findings.
  Format matches against the raw 'SEVERITY|DOMAIN|FINDING' line.
EOF
      exit 0
      ;;
  esac
done

export MODE OUTPUT
# shellcheck source=thresholds.sh
. "$THRESHOLDS"

# Run all checks under checks/, collecting their pipe-delimited findings.
TMP=$(mktemp)
trap "rm -f $TMP" EXIT

# Per-check wall-clock budget — larger in deep mode (see thresholds.sh).
CHECK_BUDGET="$CHECK_TIMEOUT_SECS"
[ "$MODE" = "deep" ] && CHECK_BUDGET="$CHECK_TIMEOUT_SECS_DEEP"

scripts=$(find "$CHECKS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
for s in $scripts; do
  stem=$(basename "$s" .sh)
  if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$stem,"; then
    continue
  fi
  # Bound every check by CHECK_BUDGET. Capturing into a var (not a direct
  # >>append) keeps the write atomic: a check killed mid-run contributes only
  # what it had fully emitted, never a torn line. On timeout (rc 124) we emit a
  # visible marker so a dropped check is deterministic and obvious, not silent.
  out=$(timeout "$CHECK_BUDGET" bash "$s" 2>/dev/null); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >> "$TMP"
  if [ "$rc" = 124 ]; then
    echo "LOW|audit/$stem|check exceeded ${CHECK_BUDGET}s and was killed — its findings are incomplete this run|profile checks/$stem.sh; bound slow queries/commands" >> "$TMP"
  fi
done

# Apply suppression list (regex per line in .audit-ignore)
IGNORE_FILE="$SKILL_DIR/.audit-ignore"
if [ -f "$IGNORE_FILE" ]; then
  FILTERED=$(mktemp)
  trap "rm -f $TMP $FILTERED" EXIT
  grep -vE -f <(grep -vE '^[[:space:]]*(#|$)' "$IGNORE_FILE") "$TMP" > "$FILTERED" || true
  mv "$FILTERED" "$TMP"
fi

# Deterministic finding order. Checks emit in their own internal order — many
# iterate `kubectl get pods`, whose ordering reshuffles after any pod recreate.
# A stable, locale-pinned sort here makes two audits of an unchanged system
# byte-identical in line order, so a diff surfaces only substantive changes
# (new/cleared findings, changed live values) rather than reordered lines.
# Severity grouping in the renderer is unaffected — it re-buckets via grep.
LC_ALL=C sort -o "$TMP" "$TMP"

# Summary mode — single line
if [ "$SUMMARY" = "1" ]; then
  crit=$(grep -c "^CRIT|" "$TMP" 2>/dev/null | head -1); crit=${crit:-0}
  high=$(grep -c "^HIGH|" "$TMP" 2>/dev/null | head -1); high=${high:-0}
  med=$(grep -c "^MED|" "$TMP" 2>/dev/null | head -1); med=${med:-0}
  low=$(grep -c "^LOW|" "$TMP" 2>/dev/null | head -1); low=${low:-0}
  echo "🔴 $crit  🟠 $high  🟡 $med  🟢 $low  (mode=$MODE)"
  exit 0
fi

# Render
case "$OUTPUT" in
  json)
    awk -F'|' 'BEGIN{print "["} NR>1{print ","} {gsub(/"/,"\\\"",$3); gsub(/"/,"\\\"",$4); printf "{\"severity\":\"%s\",\"domain\":\"%s\",\"finding\":\"%s\",\"fix\":\"%s\"}",$1,$2,$3,$4} END{print "]"}' "$TMP"
    ;;
  md|*)
    echo "# Stack Audit ($(date -u +%FT%TZ))"
    echo "Mode: $MODE"
    echo ""
    for sev in CRIT HIGH MED LOW OK; do
      count=$(grep -c "^${sev}|" "$TMP" 2>/dev/null | head -1)
      count=${count:-0}
      [ "$count" = "0" ] && continue
      case "$sev" in
        CRIT) icon="🔴 Critical" ;;
        HIGH) icon="🟠 High" ;;
        MED)  icon="🟡 Medium" ;;
        LOW)  icon="🟢 Low" ;;
        OK)   icon="✅ Verified healthy" ;;
      esac
      echo ""
      echo "## $icon ($count)"
      grep "^${sev}|" "$TMP" | while IFS='|' read sev domain finding fix; do
        echo "- **[$domain]** $finding"
        [ -n "$fix" ] && echo "  - fix: \`$fix\`"
      done
    done
    ;;
esac
