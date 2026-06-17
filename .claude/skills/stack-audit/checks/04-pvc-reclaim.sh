#!/bin/bash
# PVC durability (k8s). The ADR's #1 documented failure mode is silent disk-fill on
# Delete-reclaim local-path PVCs — and on this single node a Delete-reclaim volume is
# also a data-loss trap: delete the PVC (or let ArgoCD prune it) and the backing data is
# gone, no detach-and-reattach. The operator mitigated this with a custom
# `local-path-retain` StorageClass for DB volumes, but the DEFAULT `local-path` SC is
# still Delete — so a new PVC that forgets the SC silently lands on Delete-reclaim.
# This check reads each bound PV's ACTUAL reclaim policy (what governs data fate, not the
# SC name) and flags Delete, plus any PVC stuck unbound. Static, no metric → audit-only.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/04-pvc-reclaim|kubectl not on PATH — PVC durability audit skipped|install kubectl / check KUBECONFIG"; exit 0; }

# Reachability gate: an unreachable cluster otherwise makes `kubectl get pvc` fail → exit 0
# with zero findings, indistinguishable from "all PVCs healthy + Retain". Mark inconclusive.
PVC_JSON=$(kubectl get pvc -A -o json 2>/dev/null) || { echo "LOW|audit/04-pvc-reclaim|cannot reach cluster — PVC durability check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }
# map: pv-name -> reclaimPolicy
declare -A RECLAIM
while IFS=$'\t' read -r pv pol; do RECLAIM["$pv"]="$pol"; done < <(
  kubectl get pv -o json 2>/dev/null | jq -r '.items[] | [.metadata.name, .spec.persistentVolumeReclaimPolicy] | @tsv'
)

echo "$PVC_JSON" | jq -r '.items[] | [.metadata.namespace, .metadata.name, .status.phase, (.spec.volumeName // "-")] | @tsv' \
| while IFS=$'\t' read -r ns name phase pv; do
    if [ "$phase" != "Bound" ]; then
      echo "HIGH|storage/pvc|$ns/$name is $phase (not Bound) — workload can't mount its volume|kubectl describe pvc -n $ns $name"
      continue
    fi
    pol="${RECLAIM[$pv]:-}"
    if [ "$pol" = "Delete" ]; then
      echo "MED|storage/reclaim|$ns/$name → PV $pv is reclaimPolicy=Delete — deleting/pruning the PVC destroys the data (no swap, single node)|kubectl patch pv $pv -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}'; move to the local-path-retain StorageClass"
    fi
  done
