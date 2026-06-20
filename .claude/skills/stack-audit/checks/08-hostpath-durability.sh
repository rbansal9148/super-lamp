#!/bin/bash
# hostPath durability (k8s). The data-loss check 04 inspects PVCs — but the LARGEST
# irreplaceable data on this stack lives on raw hostPath dirs (immich library, prowlarr /
# bitmagnet / calibre / stremthru DBs), which have NO PV lifecycle, reclaim policy, or
# StorageClass guard at all. An ArgoCD prune or a renamed path orphans the bytes silently;
# nothing in 04 (PVC-scoped) can see it. This is config-at-rest data-loss risk → audit-only.
#
#   MED   each distinct hostPath dir backing a Running owned workload (confirm it's backed up)
#   HIGH  a RESTORE.md-critical path that is NOT currently mounted anywhere (drifted / renamed)
#
# System mounts (the node collector's read-only /var/log/pods etc.) are allowlisted —
# they are not data, and flagging them is permanent noise.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/08-hostpath-durability|kubectl not on PATH — hostPath audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "LOW|audit/08-hostpath-durability|jq not on PATH — hostPath audit skipped|install jq"; exit 0; }
# Reachability gate (mirrors 02/03/05): an unreachable cluster otherwise yields an empty
# pipe → zero findings, indistinguishable from "no hostPath data anywhere".
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/08-hostpath-durability|cannot reach cluster — hostPath check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }

OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"

# Collect every (path<TAB>ns/pod) hostPath mount across owned namespaces, drop allowlisted
# system mounts, dedup by PATH (one finding per distinct dir), sort for byte-stability.
mounts=$(
  for ns in $OWNED; do
    kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r --arg ns "$ns" '
      .items[] | select(.status.phase=="Running") | .metadata.name as $p
      | .spec.volumes[]? | select(.hostPath)
      | "\(.hostPath.path)\t\($ns)/\($p)"' 2>/dev/null
  done | grep -Ev "$HOSTPATH_ALLOW" | LC_ALL=C sort -u
)

# MED per distinct hostPath dir (first owning pod shown; the path is the dedup key).
printf '%s\n' "$mounts" | awk -F'\t' 'NF>=2 && !seen[$1]++' | while IFS=$'\t' read -r path owner; do
  [ -z "$path" ] && continue
  echo "MED|storage/hostpath|$path — node-local hostPath ($owner), no PV lifecycle/reclaim guard; an ArgoCD prune or path rename orphans the data|confirm $path is in the off-node backup set (see gitops/RESTORE.md); consider migrating to a local-path-retain PVC"
done

# HIGH for a declared-critical path that has drifted out of the live cluster (renamed,
# unmounted, or workload removed) — exactly the silent-orphan case RESTORE.md warns about.
mounted_paths=$(printf '%s\n' "$mounts" | cut -f1)
for crit in $HOSTPATH_CRITICAL; do
  if ! printf '%s\n' "$mounted_paths" | grep -qxF "$crit"; then
    echo "HIGH|storage/hostpath-drift|RESTORE.md-critical path $crit is NOT mounted by any Running owned pod — renamed, unmounted, or its workload was removed|verify the data still exists on-node and the workload still mounts it; update RESTORE.md if intentionally retired"
  fi
done
