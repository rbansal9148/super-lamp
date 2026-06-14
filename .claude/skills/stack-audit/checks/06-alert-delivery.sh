#!/bin/bash
# Grafana alert-NOTIFICATION deliverability (static, desired-state).
#
# Why this is an audit check and not an alarm: the failure is that ALERTS FIRE BUT
# NEVER ARRIVE. The component that would page you about a broken notifier is the
# notifier itself — chicken-and-egg, so there is no continuous metric that catches it.
# It only shows as an ERROR line buried in Grafana's own log. Pure config-at-rest with
# no time series → it lives here.
#
# The concrete trap (hit Jun 2026): Grafana's EMBEDDED gomplate rejects the
# two-variable range form `{{ range $i, $a := .Alerts }}` inside tmpl.Inline with
# "template: <inline>:1: unexpected ',' in range", so every notification routed through
# that contact point was dropped ("Notify for alerts failed", retried every 5m,
# delivered never). Standalone gomplate accepts it; Grafana's bundled one does not.
# Single-variable range over a stdlib slice is the safe form.
#
# Check: in any manifest that defines a gomplate-based Grafana contact point (contains
# `tmpl.Inline`), flag a two-variable range — it will silently break delivery.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
GITOPS_DIR="${GITOPS_DIR:-/opt/docker/gitops}"
command -v rg >/dev/null 2>&1 || { echo "LOG|audit/06-alert-delivery|ripgrep (rg) not found — skipped|install ripgrep" | sed 's/^LOG/LOW/'; exit 0; }
[ -d "$GITOPS_DIR" ] || { echo "LOW|audit/06-alert-delivery|GITOPS_DIR $GITOPS_DIR not found — static alert-template check skipped|set GITOPS_DIR to the gitops tree"; exit 0; }

# Files that template a Grafana contact-point payload via gomplate.
mapfile -t files < <(rg -l --glob '*.y*ml' 'tmpl\.Inline' "$GITOPS_DIR" 2>/dev/null | LC_ALL=C sort)
[ "${#files[@]}" -eq 0 ] && exit 0

# Two embedded-gomplate-incompatible constructs, each of which SILENTLY DROPS every
# notification routed through the contact point (both hit in prod):
#   1. two-variable range  {{ range $x, $y := … }}  → "unexpected ',' in range"  (Jun 9 2026)
#   2. variable assignment {{ $n := … }} / {{ $n = … }} → "unexpected ':=' in command" (Jun 14 2026)
# Standalone gomplate accepts both; Grafana's bundled one rejects both. The safe form caps
# alerts with a count branch + literal-bound stdlib slice — NO $-vars at all.
TWOVAR='range[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*,[[:space:]]*\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:='
ASSIGN='\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:?='
SAFE='{{ if gt (len .Alerts) 8 }}{{ range (slice .Alerts 0 8) }}…{{ end }}{{ else }}{{ range .Alerts }}…{{ end }}{{ end }}'
is_comment() { case "${1#"${1%%[![:space:]]*}"}" in '#'*) return 0 ;; *) return 1 ;; esac; }
for f in "${files[@]}"; do
  rel="${f#"$GITOPS_DIR"/}"
  # (1) two-variable range. Skip YAML comment lines so a warning comment isn't self-flagged.
  rg -n "$TWOVAR" "$f" 2>/dev/null | while IFS=: read -r ln content; do
    is_comment "$content" && continue
    echo "HIGH|observability/alert-delivery|$rel:$ln uses a two-variable gomplate range ({{ range \$x, \$y := … }}) in a Grafana contact-point template — the embedded gomplate rejects it (\"unexpected ',' in range\"), so EVERY alert routed here is silently dropped|rewrite without \$-vars: $SAFE"
  done
  # (2) variable assignment (:= or =). Skip comments AND two-var-range lines (whose `$y :=`
  # would double-report the same root cause).
  rg -n "$ASSIGN" "$f" 2>/dev/null | while IFS=: read -r ln content; do
    is_comment "$content" && continue
    printf '%s' "$content" | rg -q "$TWOVAR" && continue
    echo "HIGH|observability/alert-delivery|$rel:$ln uses gomplate variable assignment (\$x := / \$x =) in a Grafana contact-point template — the embedded gomplate rejects it (\"unexpected ':=' in command\"), so EVERY alert routed here is silently dropped|rewrite without \$-vars: $SAFE"
  done
done
