#!/bin/bash
# Stack audit — main orchestrator.
# Runs all checks, aggregates findings, prints prioritized punch list.
#
# Finding format (pipe-separated):
#   SEVERITY|DOMAIN|FINDING|FIX_COMMAND|FIX_TOOL
#
# - FIX_COMMAND: literal shell command the user can run (legacy field).
# - FIX_TOOL:    optional. Name of a tools/ script (no .sh suffix) whose
#                idempotent invocation resolves this class of finding. Empty
#                if there is no automated fixer.
#
# Run `audit.sh --fix` to preview-then-apply every fixer hinted in findings.

set -u
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_DIR="$SKILL_DIR/checks"
TOOLS_DIR="$SKILL_DIR/tools"
THRESHOLDS="$SKILL_DIR/thresholds.sh"

# Parse args
MODE="quick"
OUTPUT="md"
ONLY=""
SUMMARY=0
FIX=0
APPLY=0
for a in "$@"; do
  case "$a" in
    --deep) MODE="deep" ;;
    --quick) MODE="quick" ;;
    --json) OUTPUT="json" ;;
    --summary) SUMMARY=1 ;;
    --only=*) ONLY="${a#--only=}" ;;
    --fix) FIX=1 ;;
    --apply) APPLY=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--quick|--deep] [--json|--summary] [--only=01-system,03-postgres]
          [--fix [--apply]]

Modes:
  --quick   (default) read-only fast checks, ~30s
  --deep    includes pg_stat_statements analysis, ~2 min

Output:
  --json     machine-readable
  --summary  just severity counts, one line
  (default)  markdown punch list

Filtering:
  --only=NAME[,NAME]   only run these check scripts (by filename stem)

Suppression:
  Add a regex per line to $SKILL_DIR/.audit-ignore to mute known-acceptable findings.
  Format matches against the raw 'SEVERITY|DOMAIN|FINDING' line.

Apply fixes:
  --fix       compute the set of fixers hinted by current findings and
              dry-run each one. Does NOT mutate anything.
  --fix --apply
              same, then actually run each fixer for real. Prints the audit
              again afterwards so you can verify findings dropped.
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

scripts=$(find "$CHECKS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
for s in $scripts; do
  stem=$(basename "$s" .sh)
  if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$stem,"; then
    continue
  fi
  # Bound every check by CHECK_TIMEOUT_SECS. Capturing into a var (not a direct
  # >>append) keeps the write atomic: a check killed mid-run contributes only
  # what it had fully emitted, never a torn line. On timeout (rc 124) we emit a
  # visible marker so a dropped check is deterministic and obvious, not silent.
  out=$(timeout "$CHECK_TIMEOUT_SECS" bash "$s" 2>/dev/null); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >> "$TMP"
  if [ "$rc" = 124 ]; then
    echo "LOW|audit/$stem|check exceeded ${CHECK_TIMEOUT_SECS}s and was killed — its findings are incomplete this run|profile checks/$stem.sh; bound slow queries/commands" >> "$TMP"
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
# iterate `docker ps`, whose ordering reshuffles after any container recreate.
# A stable, locale-pinned sort here makes two audits of an unchanged system
# byte-identical in line order, so a diff surfaces only substantive changes
# (new/cleared findings, changed live values) rather than reordered lines.
# Severity grouping in the renderer is unaffected — it re-buckets via grep.
LC_ALL=C sort -o "$TMP" "$TMP"

# --fix mode: extract distinct FIX_TOOL hints from findings, run each.
#
# Tools listed here are NOT auto-invokable by --fix because they require
# per-finding arguments (e.g. rotate_pg_password needs a service name).
SKIP_AUTO_FIX="rotate_pg_password"

if [ "$FIX" = "1" ]; then
  # The FIX_TOOL is always the LAST pipe-separated field on its line. We use
  # $NF rather than $5 because FIX_COMMAND can itself contain pipes (e.g.
  # `sudo du -shx ... | sort -h | tail`), and a tool name must match
  # ^[a-z_]+$ — that filter discards anything that's actually a shell snippet.
  fix_tools=$(awk -F'|' 'NF>=5 && $NF ~ /^[a-z_]+$/ {print $NF}' "$TMP" | sort -u)
  # Drop ones we know we cannot auto-invoke.
  for skip in $SKIP_AUTO_FIX; do
    fix_tools=$(echo "$fix_tools" | grep -vx "$skip" || true)
  done
  if [ -z "$fix_tools" ]; then
    echo "No findings have a known fixer hint. (FIX_TOOL field empty.)"
    exit 0
  fi
  echo "## Plan (dry-run)"
  for t in $fix_tools; do
    script="$TOOLS_DIR/$t.sh"
    if [ ! -x "$script" ]; then
      echo "- $t: SKIP (no such tool at $script)"
      continue
    fi
    echo "- $t:"
    bash "$script" --dry-run 2>&1 | sed 's/^/    /' || true
  done
  if [ "$APPLY" != "1" ]; then
    echo
    echo "Re-run with: $0 --fix --apply  to execute."
    exit 0
  fi
  echo
  echo "## Applying"
  for t in $fix_tools; do
    script="$TOOLS_DIR/$t.sh"
    [ -x "$script" ] || continue
    echo "--- $t ---"
    bash "$script" || echo "  $t exited non-zero"
  done
  echo
  echo "## Re-audit after fixes"
  exec "$0" --quick --summary
fi

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
    awk -F'|' 'BEGIN{print "["} NR>1{print ","} {gsub(/"/,"\\\"",$3); gsub(/"/,"\\\"",$4); gsub(/"/,"\\\"",$5); printf "{\"severity\":\"%s\",\"domain\":\"%s\",\"finding\":\"%s\",\"fix\":\"%s\",\"fix_tool\":\"%s\"}",$1,$2,$3,$4,$5} END{print "]"}' "$TMP"
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
      grep "^${sev}|" "$TMP" | while IFS='|' read sev domain finding fix fix_tool; do
        echo "- **[$domain]** $finding"
        [ -n "$fix" ] && echo "  - fix: \`$fix\`"
        [ -n "$fix_tool" ] && echo "  - apply: \`bash tools/$fix_tool.sh\`"
      done
    done
    # Footer: hint to use --fix if any fix_tools are present
    if awk -F'|' 'NF>=5 && $NF ~ /^[a-z_]+$/' "$TMP" | head -1 | grep -q .; then
      echo ""
      echo "---"
      echo "_Tip: run \`bash audit.sh --fix\` to preview, then \`--fix --apply\` to execute._"
    fi
    ;;
esac
