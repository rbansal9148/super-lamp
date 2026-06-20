#!/bin/bash
# NetworkPolicy DB-coverage drift (k8s). The apps-allow-trusted-cross-ns policy lets
# observability/kube-system reach apps pods, EXCEPT a hand-maintained NotIn exclusion list
# of database pods. That list FAILS OPEN: a new *-postgres/*-redis added without editing the
# policy is silently reachable cross-namespace. The manifest itself asks for this check
# (00-apps-namespace-isolation.yaml: "A stack-audit check flagging uncovered DB pods is a
# good follow-up"). Config-at-rest, owned-ns scoped, deterministic → audit-only.
#
#   HIGH  a DB pod (by app label) NOT in the policy's NotIn exclusion list — reachable cross-ns
#
# Ships GREEN when every DB pod is excluded (the healthy steady state); it is a DRIFT detector.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/09-netpol-db-coverage|kubectl not on PATH — netpol audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "LOW|audit/09-netpol-db-coverage|jq not on PATH — netpol audit skipped|install jq"; exit 0; }
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/09-netpol-db-coverage|cannot reach cluster — netpol check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }

NS="${NETPOL_DB_NS:-apps}"
POLICY="${NETPOL_DB_NAME:-apps-allow-trusted-cross-ns}"
PATTERN="${NETPOL_DB_LABEL_PATTERN:-postgres|redis|valkey|mariadb|mysql|mongo}"

pol=$(kubectl get netpol "$POLICY" -n "$NS" -o json 2>/dev/null)
if [ -z "$pol" ]; then
  echo "LOW|audit/09-netpol-db-coverage|netpol $POLICY not found in ns $NS — cross-ns DB-isolation policy missing or renamed, result is INCONCLUSIVE|verify the policy name (NETPOL_DB_NAME) / that cross-ns isolation still exists"
  exit 0
fi

# The exclusion list: values of any NotIn matchExpression on the policy's podSelector.
excluded=$(printf '%s' "$pol" | jq -r '
  [.spec.podSelector.matchExpressions[]? | select(.operator=="NotIn") | .values[]?] | .[]' 2>/dev/null \
  | LC_ALL=C sort -u)

# DB pods in the namespace, keyed by their `app` label (the selector key the policy matches on).
db_pods=$(kubectl get pods -n "$NS" -o json 2>/dev/null | jq -r '
  .items[] | select(.status.phase=="Running")
  | (.metadata.labels.app // empty)' 2>/dev/null \
  | grep -Ei "($PATTERN)" | LC_ALL=C sort -u)

for app in $db_pods; do
  if ! printf '%s\n' "$excluded" | grep -qxF "$app"; then
    echo "HIGH|security/netpol-db|$NS DB pod '$app' is NOT in $POLICY's NotIn exclusion list — reachable from trusted cross-namespace sources (policy fails OPEN)|add '$app' to the NotIn values in gitops/manifests/network-policies/00-apps-namespace-isolation.yaml"
  fi
done
