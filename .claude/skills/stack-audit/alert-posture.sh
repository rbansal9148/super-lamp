#!/bin/bash
# Runtime alert POSTURE — live, read-only snapshot of Grafana unified alerting.
#
# DELIBERATELY NOT a check under checks/: the rest of the audit is static
# desired-state config hygiene that is byte-deterministic run-to-run. This reads
# LIVE alert state, which is time-varying, so it is rendered as its own clearly
# timestamped section AFTER the punch list and is opt-in via `audit.sh --alerts`.
# The default `audit.sh` stays credential-free and reproducible.
#
# It does NOT re-evaluate any runtime condition (that would duplicate the ~23
# Grafana alarm rules and contradict the skill's "an alarm dominates a check you
# have to remember to run" design rule). It only REPORTS the alarms' state:
#   1. Firing now              — GET /api/prometheus/grafana/api/v1/rules
#   2. Fired in last N days    — GET /api/annotations?type=alert  (Grafana's own
#      alert state history; the value here is that ntfy.sh's free tier retains NO
#      history, so "what fired and auto-resolved while I wasn't looking" is
#      otherwise invisible).
#
# Auth: a least-privilege Grafana service-account (Viewer) token, stored as the
# SealedSecret observability/stack-audit-grafana-token (key: token). Grafana sits
# behind Authelia 2FA at the edge, so we reach it in-cluster via a short-lived
# port-forward to the Service, never the public ingress.
set -u

NS="${GRAFANA_NS:-observability}"
SECRET="${GRAFANA_TOKEN_SECRET:-stack-audit-grafana-token}"
SVC="${GRAFANA_SVC:-grafana}"
LPORT="${GRAFANA_PF_PORT:-33731}"
DAYS="${ALERT_HISTORY_DAYS:-7}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

note() { echo "_Alert posture skipped: $1._"; }

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { note "$bin not found"; exit 0; }
done

TOK=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$TOK" ] || { note "secret $NS/$SECRET not present (commit the SealedSecret and let ArgoCD unseal it)"; exit 0; }

kubectl -n "$NS" port-forward "svc/$SVC" "$LPORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null' EXIT
ready=0
for _ in $(seq 1 30); do
  curl -fsS "http://localhost:$LPORT/api/health" >/dev/null 2>&1 && { ready=1; break; }
  sleep 0.3
done
[ "$ready" = 1 ] || { note "could not reach Grafana via port-forward (svc/$SVC -n $NS)"; exit 0; }

API="http://localhost:$LPORT"
RULES=$(curl -fsS -H "Authorization: Bearer $TOK" "$API/api/prometheus/grafana/api/v1/rules" 2>/dev/null)
NOW=$(date +%s%3N); FROM=$(( NOW - DAYS*86400*1000 ))
ANN=$(curl -fsS -H "Authorization: Bearer $TOK" "$API/api/annotations?type=alert&from=$FROM&to=$NOW&limit=500" 2>/dev/null)

echo "## 📟 Runtime alert posture (live snapshot, $(date -u +%FT%TZ))"
echo ""
echo "_Source: Grafana unified alerting, read-only. Detection lives in the alarm rules; this reports their STATE only and is NOT part of the deterministic punch list above._"
echo ""

echo "### Firing now"
if [ -z "$RULES" ]; then
  echo "- ⚠ could not read rules endpoint"
else
  fcount=$(printf '%s' "$RULES" | jq -r '[.data.groups[].rules[]|select(.state=="firing")]|length' 2>/dev/null)
  if [ "${fcount:-0}" = 0 ]; then
    echo "- ✅ none"
  else
    printf '%s' "$RULES" | jq -r '
      .data.groups[].rules[]
      | select(.state=="firing")
      | "- 🔴 **\(.name)** (severity=\(.labels.severity // "?"), active=\((.alerts // [])|length))"' 2>/dev/null
  fi
fi
echo ""

echo "### OutOfSync apps — why (live diagnosis)"
# Enriches the OutOfSync alarm's state with the *reason*: the alarm reports an app
# is not Synced; this reports WHY (the ArgoCD ComparisonError/SyncError message —
# e.g. a chart repoURL that 404s after an upstream move). Reads via the local
# kubeconfig (same creds used above for the secret/port-forward), NOT the Grafana
# token. Live & non-deterministic by design — that's why it lives here, not in a
# deterministic checks/ check.
APPS=$(kubectl -n "$ARGOCD_NS" get applications -o json 2>/dev/null)
if [ -z "$APPS" ]; then
  echo "- ⚠ could not read ArgoCD applications (kubectl -n $ARGOCD_NS get applications)"
else
  diag=$(printf '%s' "$APPS" | jq -r '
    [ .items[] | select((.status.sync.status // "") != "Synced") ]
    | sort_by(.metadata.name)
    | .[]
    | ((.status.conditions // []) | map(select(.type|test("Error";"i"))) | .[0].message // "") as $msg
    | "- 🔴 **\(.metadata.name)** sync=\(.status.sync.status // "?") health=\(.status.health.status // "?")"
      + (if $msg != "" then "\n    ↳ \($msg | gsub("\\s+";" ") | .[0:300])" else "" end)' 2>/dev/null)
  if [ -z "$diag" ]; then
    echo "- ✅ all apps Synced"
  else
    printf '%s\n' "$diag"
  fi
fi
echo ""

echo "### Fired in last ${DAYS}d (transitions into Alerting)"
if [ -z "$ANN" ]; then
  echo "- ⚠ could not read annotations endpoint"
else
  hist=$(printf '%s' "$ANN" | jq -r '
    [ .[] | select((.newState // "") | startswith("Alerting")) ]
    | group_by(.alertName)
    | map({name: .[0].alertName, n: length, last: (max_by(.time).time/1000|floor|todate)})
    | sort_by(-.n)
    | .[] | "- **\(.name)** — \(.n)× (last \(.last))"' 2>/dev/null)
  if [ -z "$hist" ]; then
    echo "- ✅ none"
  else
    printf '%s\n' "$hist"
  fi
fi
