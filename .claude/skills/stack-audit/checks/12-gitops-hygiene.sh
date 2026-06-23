#!/bin/bash
# GitOps hygiene (k8s) — two at-rest faults ArgoCD's OutOfSync alarm does NOT cover, because
# the cluster is perfectly in-sync with a manifest tree that is itself wrong:
#
#  (a) Dangling IngressRoute — a Traefik IngressRoute whose target Service does not exist.
#      Every request to that hostname 502s, forever, with no alarm: pod-not-ready needs a pod,
#      scrape-target-down needs a scrape target, ArgoCD is Synced (the IngressRoute IS the
#      desired state). HIGH.
#  (b) Sealed-secrets key rotation — the controller rotates its sealing key (default 30d),
#      KEEPING the old keys and adding a new active one. After a rotation, a key backup taken
#      before it no longer covers secrets sealed with the new key. RESTORE.md §0: "If that key
#      is lost, every committed secret is permanently undecryptable." >1 active key = rotation
#      has happened = the off-cluster key backup must be refreshed. HIGH.
#
# Both are live reads (kubectl), so this lives with the checks but is config-at-rest in spirit:
# the fault is a standing misconfiguration, not a transient runtime event.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"
SS_NS="${SEALED_SECRETS_NS:-kube-system}"
SS_LABEL="${SEALED_SECRETS_KEY_LABEL:-sealedsecrets.bitnami.com/sealed-secrets-key}"

command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/12-gitops-hygiene|kubectl not on PATH — GitOps-hygiene audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/12-gitops-hygiene|cannot reach cluster — GitOps-hygiene check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }

# ── (a) dangling IngressRoute → absent Service ──
for ns in $OWNED; do
  kubectl -n "$ns" get ingressroute -o json 2>/dev/null \
    | jq -r --arg ns "$ns" '.items[] | .metadata.name as $ir | (.spec.routes[]?.services[]?.name // empty) | [$ns,$ir,.] | @tsv' 2>/dev/null \
  | sort -u \
  | while IFS=$'\t' read -r rns ir svc; do
      [ -n "$svc" ] || continue
      kubectl -n "$rns" get service "$svc" >/dev/null 2>&1 \
        || echo "HIGH|ingress/dangling|IngressRoute $rns/$ir routes to Service '$svc' which does not exist — every request to its host 502s, no alarm covers it|recreate the missing Service, or delete the IngressRoute: kubectl -n $rns delete ingressroute $ir"
    done
done

# ── (b) sealed-secrets key rotation → stale key backup ──
KEYS=$(kubectl -n "$SS_NS" get secret -l "$SS_LABEL" -o json 2>/dev/null | jq -r '.items | length' 2>/dev/null)
if [ -n "$KEYS" ] && [ "$KEYS" -gt 1 ] 2>/dev/null; then
  echo "HIGH|gitops/sealing-key|sealed-secrets controller has $KEYS active sealing keys — a rotation occurred, so any key backup predating it no longer covers secrets sealed with the newest key (RESTORE.md §0)|re-backup ALL keys: kubectl -n $SS_NS get secret -l $SS_LABEL -o yaml > sealed-secrets-keys.backup.yaml (store off-cluster)"
fi
