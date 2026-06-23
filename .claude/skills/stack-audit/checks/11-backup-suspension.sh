#!/bin/bash
# Backup-CronJob suspension (k8s). A suspended backup CronJob = the scheduled off-node
# backup is NOT running — and NOTHING else catches it. Checks 01-10 never read
# .spec.suspend; the Grafana alarms watch firing/failing runtime, but a SUSPENDED CronJob
# spawns no Jobs and no pods, so there is nothing to fire on; and alert-posture.sh's
# Failed-Jobs section only matches Jobs with a .status.conditions[type=Failed] — again,
# zero Jobs from a suspended CronJob. So the state is invisible across the whole stack.
#
# This bit the cluster on 2026-06-21: immich-backup (the ONLY off-node backup of the
# irreplaceable immich library+DB — RESTORE.md §1) was suspended after a Backblaze
# cap-exceeded failure, and would have silently stayed off indefinitely. HIGH because a
# paused sole backup is a data-loss-in-progress state, not a warning. Deliberate,
# acknowledged pauses are muted via .audit-ignore (a regex on the finding line) — that is
# the explicit "I know, it's intentional" record, not a silent blind spot.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"
PAT="${BACKUP_CRONJOB_PATTERN:-backup|restic|dump|borg|velero}"

command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/11-backup-suspension|kubectl not on PATH — backup-suspension audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
# Reachability gate: an unreachable cluster otherwise makes every `kubectl get cronjob`
# fail silently → zero findings, byte-identical to "no suspended backups". Mark inconclusive.
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/11-backup-suspension|cannot reach cluster — backup-suspension check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }

for ns in $OWNED; do
  kubectl -n "$ns" get cronjob -o json 2>/dev/null | jq -r --arg pat "$PAT" '
    .items[]
    | select(.spec.suspend == true)
    | select(.metadata.name | test($pat; "i"))
    | "HIGH|storage/backup-suspended|\(.metadata.namespace)/\(.metadata.name) CronJob is SUSPENDED — scheduled backups are NOT running (last success: \(.status.lastSuccessfulTime // "never"))|fix the cause and set spec.suspend: false; or add a .audit-ignore regex if the pause is deliberate"'
done
