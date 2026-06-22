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
OWNED_NS="${RESOURCE_OWNED_NAMESPACES:-apps observability}"
VL_DS_UID="${VL_DATASOURCE_UID:-victorialogs}"     # Grafana datasource uid for VictoriaLogs
LOG_WINDOW="${LOG_POSTURE_WINDOW:-30m}"            # lookback for the error/timeout log posture

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
echo ""

# ── Failed Jobs / CronJobs (gap: no dedicated alarm) ──────────────────────────
# Added 2026-06-22 after a cap-exceeded immich-backup Job failed silently: its ONLY
# signal was the generic Pod-not-Ready alarm, which auto-resolves once the failed pods
# age out (failedJobsHistoryLimit), so a chronically-failing nightly backup is invisible
# between runs. A Job with a Failed condition is a durable, unambiguous signal. Live
# kubectl over owned namespaces (same creds as the OutOfSync diagnosis above).
# The durable fix is a kube_job_failed Grafana alarm; this reports it until that exists.
echo "### Failed Jobs (no dedicated alarm yet)"
JFAIL=""
for ns in $OWNED_NS; do
  j=$(kubectl -n "$ns" get jobs -o json 2>/dev/null | jq -r --arg ns "$ns" '
    .items[]
    | select((.status.conditions // []) | any((.type=="Failed") and (.status=="True")))
    | ((.status.conditions // []) | map(select(.type=="Failed")) | .[0]) as $c
    | "- 🔴 **\($ns)/\(.metadata.name)** — \($c.reason // "Failed"): \(($c.message // "") | gsub("\\s+";" ") | .[0:160]) (failed=\(.status.failed // 0))"' 2>/dev/null)
  [ -n "$j" ] && JFAIL="$JFAIL$j"$'\n'
done
if [ -z "$JFAIL" ]; then echo "- ✅ none"; else printf '%s' "$JFAIL"; fi
echo ""

# ── Error/timeout log posture + upstream classification ───────────────────────
# Top error/timeout-emitting pods from VictoriaLogs over $LOG_WINDOW, each tagged
# upstream-vs-internal. Rationale: high-volume "errors" are often upstream/expected
# (debrid 429s, external 5xx, addon timeouts) and NOT cluster faults — tagging them
# stops real internal errors from drowning in that noise. Two stats queries (total +
# upstream-pattern) joined locally — O(2) calls, not O(pods). Reuses the live Grafana
# port-forward + token; graceful-skips if VictoriaLogs is unreachable.
echo "### Error/timeout log posture (last $LOG_WINDOW, top emitters)"
NS_FILTER=$(for n in $OWNED_NS; do printf 'k8s.namespace.name:%s OR ' "$n"; done | sed 's/ OR $//')
ERRPAT='"error" OR "ERROR" OR "timeout" OR "timed out" OR "fatal" OR "panic" OR "exception"'
UPPAT='"429" OR "rate limit" OR "Too Many Requests" OR "502" OR "503" OR "upstream" OR "timed out" OR "timeout" OR "aborted" OR "ECONNREFUSED" OR "EAI_AGAIN"'
vlq() { curl -fsS -H "Authorization: Bearer $TOK" --data-urlencode "query=$1" \
  "$API/api/datasources/proxy/uid/$VL_DS_UID/select/logsql/query" 2>/dev/null; }
TOTAL=$(vlq "_time:$LOG_WINDOW ($NS_FILTER) ($ERRPAT) | stats by (k8s.pod.name) count() as cnt | sort by (cnt desc) | limit 12")
if [ -z "$TOTAL" ]; then
  echo "- ⚠ could not query VictoriaLogs (datasource uid=$VL_DS_UID) — skipped"
elif [ "$(printf '%s' "$TOTAL" | jq -s 'length' 2>/dev/null)" = 0 ]; then
  echo "- ✅ no error/timeout log lines in the window"
else
  UPS=$(vlq "_time:$LOG_WINDOW ($NS_FILTER) ($ERRPAT) ($UPPAT) | stats by (k8s.pod.name) count() as up | sort by (up desc) | limit 50")
  # build "pod up" map, then classify each top emitter by the upstream ratio
  printf '%s' "$TOTAL" | jq -r '"\(.cnt)\t\(.["k8s.pod.name"])"' 2>/dev/null | while IFS=$'\t' read -r cnt pod; do
    up=$(printf '%s' "$UPS" | jq -r --arg p "$pod" 'select(.["k8s.pod.name"]==$p) | .up' 2>/dev/null | head -1); up=${up:-0}
    ratio=$(awk "BEGIN{ if($cnt>0) printf \"%.2f\", $up/$cnt; else print 0 }")
    if awk "BEGIN{exit !($ratio>=0.8)}"; then tag="⬆ upstream/expected"; else tag="🔎 mixed/internal — investigate"; fi
    printf -- "- **%s** — %s err/timeout (%s upstream, %s) %s\n" "$pod" "$cnt" "$up" "$ratio" "$tag"
  done
fi
