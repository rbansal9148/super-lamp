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
ALERTS=1
PERSIST=0
DIFF=0
UPDATES=0
for a in "$@"; do
  case "$a" in
    --deep) MODE="deep" ;;
    --quick) MODE="quick" ;;
    --json) OUTPUT="json" ;;
    --summary) SUMMARY=1 ;;
    --alerts) ALERTS=1 ;;
    --no-alerts) ALERTS=0 ;;
    --persist) PERSIST=1 ;;
    --diff) DIFF=1 ;;
    --updates) UPDATES=1 ;;
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

Live data:
  (default)    a LIVE Grafana alert-posture snapshot (firing now + fired in last N
               days) is appended AFTER the deterministic punch list. Read-only; uses
               the SealedSecret observability/stack-audit-grafana-token, and
               graceful-skips with a note if the token/Grafana is unreachable.
  --no-alerts  suppress that section — pure deterministic, credential-free output
               (use for CI / scripted diffing).
  --updates    append a LIVE image-drift sweep: floating tags (:latest/:nightly/…)
               whose upstream digest has moved past the pinned @sha256. Off by
               default — makes outbound registry calls (~1-2s/image). Complements
               the deterministic 02-image-pins.sh (which only checks THAT images
               are pinned). Semver tags are out of scope (see image-drift.sh).

History / feedback loop:
  --diff       append a "Change vs last persisted run" section (NEW / CLEARED /
               SEVERITY-CHANGED) comparing this run to audit-log/latest.json by a
               volatility-stripped stable identity. Read-only — does not write.
  --persist    write the current findings to audit-log/latest.json (the --diff
               baseline) + a git-trackable audit-log/<UTC-date>.json snapshot.
               Combine with --diff to diff-then-advance the baseline in one run.

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

# ── result persistence + run-to-run diff (opt-in; --persist / --diff) ─────────
# The byte-stable sort above was engineered so "a diff surfaces only substantive changes",
# but every run's findings die with $TMP (mktemp+trap). Persistence turns the audit from
# fire-and-forget into a feedback loop: --persist writes a git-trackable JSON snapshot;
# --diff classifies this run against the last one (NEW / CLEARED / SEVERITY-CHANGED) by a
# volatility-stripped stable identity (see audit-diff.py), so a rolled-over pod name or a
# drifted count reads as CHANGED, not churn. Computed here (pre-render) so it works under
# --json/--summary too; when BOTH flags are set we diff against the OLD baseline FIRST, then
# advance it. The core deterministic punch list above is untouched — a plain run is unchanged.
PERSIST_DIR="$SKILL_DIR/audit-log"
DIFF_SECTION=""
if [ "$DIFF" = "1" ] || [ "$PERSIST" = "1" ]; then
  CUR_JSON=$(mktemp)
  jq -Rn '[inputs | split("|") | {severity:.[0], domain:.[1], finding:.[2], fix:(.[3:]|join("|"))}]' "$TMP" > "$CUR_JSON" 2>/dev/null
  if [ "$DIFF" = "1" ]; then
    if [ -f "$PERSIST_DIR/latest.json" ]; then
      _d=$(python3 "$SKILL_DIR/audit-diff.py" "$PERSIST_DIR/latest.json" "$CUR_JSON" 2>/dev/null)
      case "$_d" in
        __NO_BASELINE__|"") DIFF_SECTION=$'## 🔁 Change vs last persisted run\nBaseline unreadable — re-seed with `--persist`.' ;;
        _NOCHANGE_)         DIFF_SECTION=$'## 🔁 Change vs last persisted run\nNo change since the last persisted run.' ;;
        *)                  DIFF_SECTION="$_d" ;;
      esac
    else
      DIFF_SECTION=$'## 🔁 Change vs last persisted run\nNo baseline yet at `audit-log/latest.json` — run `--persist` once to seed it.'
    fi
  fi
  if [ "$PERSIST" = "1" ]; then
    mkdir -p "$PERSIST_DIR"
    cp "$CUR_JSON" "$PERSIST_DIR/latest.json"
    cp "$CUR_JSON" "$PERSIST_DIR/$(date -u +%F).json"
  fi
  rm -f "$CUR_JSON"
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
    # jq owns ALL string escaping (backslash, quote, control chars, unicode) by construction.
    # The old hand-rolled awk escaped only `"` — correct for every finding emitted today
    # (verified: 04's `… '{"spec":…}'` Retain fix round-trips valid), but it would silently
    # emit invalid JSON the day a fix command carries a literal backslash. jq removes that
    # latent footgun; `.[3:]|join("|")` also re-joins any literal `|` in the fix command
    # instead of truncating at the 4th field (awk's $4 dropped the tail).
    jq -Rn '[inputs | split("|") | {severity:.[0], domain:.[1], finding:.[2], fix:(.[3:]|join("|"))}]' "$TMP"
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
    # Opt-in run-to-run diff, between the punch list and the live posture.
    if [ -n "$DIFF_SECTION" ]; then
      echo ""
      printf '%s\n' "$DIFF_SECTION"
    fi
    # Opt-in LIVE alert-posture snapshot, appended AFTER the deterministic punch
    # list so it never affects the reproducible/diffable section above.
    if [ "$ALERTS" = "1" ]; then
      echo ""
      bash "$SKILL_DIR/alert-posture.sh"
    fi
    # Opt-in LIVE image-drift sweep (--updates). After the posture; network-bound, so
    # off by default. Markdown-only (like alerts) — not emitted under --json/--summary.
    if [ "$UPDATES" = "1" ]; then
      echo ""
      bash "$SKILL_DIR/image-drift.sh"
    fi
    ;;
esac
