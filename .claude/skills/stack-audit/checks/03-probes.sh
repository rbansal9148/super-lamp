#!/bin/bash
# Readiness-probe presence (k8s). Without a readinessProbe, a Service routes traffic to
# a pod the moment its process starts — before the app can actually serve — and keeps
# routing to a wedged-but-running pod. This is the paperless ALLOWED_HOSTS class of bug:
# the container is "up" but every request 4xx/5xxs, and nothing in k8s notices because
# Running != Ready only matters if a probe defines Ready. The pod-not-ready ALARM only
# fires if a probe EXISTS to report not-ready, so probe-presence itself stays an audit
# check. Scoped to owned app workloads; LOW because some trivial sidecars don't need one.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/03-probes|kubectl not on PATH — readinessProbe audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
# Reachability gate: an unreachable cluster otherwise yields an empty pipe → zero findings,
# indistinguishable from "every pod has a probe". Emit an inconclusive marker (mirrors 01).
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/03-probes|cannot reach cluster — readinessProbe check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }
OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"

for ns in $OWNED; do
  kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase=="Running") | .metadata.name as $p
    | .spec.containers[]
    | select(has("readinessProbe") | not)
    | [$p, .name] | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r pod cn; do
      echo "LOW|workload/probe|$ns/$pod container $cn has no readinessProbe — Service may route to a not-yet-ready or wedged pod|add a readinessProbe (httpGet/tcpSocket) in its manifest"
    done

  # ── livenessProbe on PUBLIC-PATH workloads (MED) ──
  # A readinessProbe that passes on a wedged-but-listening process (http:/ on a 200-but-broken
  # app) keeps the pod in the Service endpoints forever — the pod-not-ready alarm never fires
  # because Ready stays true. For an INTERNET-EXPOSED app (an IngressRoute fronts it) that is a
  # silent outage with no alarm. We check only the PRIMARY container (name == the pod's `app`
  # label) so sidecars (gluetun/linkerd) aren't flagged — they restart with the pod anyway.
  # Convention: an IngressRoute's name == the app label it fronts.
  exposed=$(kubectl get ingressroute -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort -u | paste -sd, -)
  [ -n "$exposed" ] || continue
  kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" --arg exposed "$exposed" '
    ($exposed | split(",")) as $pub
    | .items[] | select(.status.phase=="Running")
    | .metadata.labels.app as $app | .metadata.name as $p
    | select($app != null and ($pub | index($app)))
    | .spec.containers[] | select(.name == $app) | select(has("livenessProbe") | not)
    | "MED|workload/liveness|\($ns)/\($p) public-facing container \(.name) (IngressRoute present) has no livenessProbe — a wedged-but-Ready process stays in the Service endpoints with no alarm covering it|add a livenessProbe (reusing the readiness endpoint is fine)"' 2>/dev/null
done
