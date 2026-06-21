#!/usr/bin/env bash
# Seal the `immich-backup-secrets` SealedSecret WITHOUT plaintext ever touching git or chat.
# Run this LOCALLY (you need kubeseal + reachable kube context). It builds the Secret in
# memory, pipes it straight to kubeseal, and writes ONLY the encrypted SealedSecret to the
# immich manifests dir for you to commit. ArgoCD then unseals it into Secret
# `immich-backup-secrets` (namespace apps), which 03-backup.yaml consumes.
#
# Required env:
#   B2_BUCKET     the bucket you created in B2 EU-Central (with Object Lock enabled at creation)
#   B2_ENDPOINT   the bucket's S3 endpoint, e.g. s3.eu-central-003.backblazeb2.com  (no scheme)
#   B2_KEY_ID     the Application Key keyID (scoped to that bucket)
#   B2_APP_KEY    the Application Key secret
# Optional env:
#   RESTIC_PASSWORD   if unset, a strong one is generated and PRINTED ONCE. SAVE IT OFF-CLUSTER
#                     (beside the SealedSecrets key in RESTORE.md §0) — losing it makes every
#                     backup permanently unrecoverable.
#
# Usage:
#   B2_BUCKET=immich-backup B2_ENDPOINT=s3.eu-central-003.backblazeb2.com \
#   B2_KEY_ID=... B2_APP_KEY=... ./gitops/scripts/seal-immich-backup-secret.sh
set -euo pipefail

: "${B2_BUCKET:?set B2_BUCKET}"
: "${B2_ENDPOINT:?set B2_ENDPOINT (host only, e.g. s3.eu-central-003.backblazeb2.com)}"
: "${B2_KEY_ID:?set B2_KEY_ID}"
: "${B2_APP_KEY:?set B2_APP_KEY}"

for bin in kubectl kubeseal; do command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin" >&2; exit 1; }; done

OUT="$(cd "$(dirname "$0")/../manifests/immich" && pwd)/03-backup-secret.sealedsecret.yaml"

if [ -z "${RESTIC_PASSWORD:-}" ]; then
  RESTIC_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
  echo "================================================================="
  echo ">>> GENERATED restic repo password — SAVE THIS OFF-CLUSTER NOW:"
  echo ">>>   ${RESTIC_PASSWORD}"
  echo ">>> (store it beside the SealedSecrets key from RESTORE.md §0;"
  echo ">>>  without it the backups are unrecoverable.)"
  echo "================================================================="
fi

# restic S3 backend → B2 (S3-compatible). The S3 endpoint (not the b2: native backend) is
# what supports Object Lock, which is why we target it.
kubectl create secret generic immich-backup-secrets -n apps \
  --dry-run=client -o yaml \
  --from-literal=RESTIC_REPOSITORY="s3:https://${B2_ENDPOINT}/${B2_BUCKET}" \
  --from-literal=RESTIC_PASSWORD="${RESTIC_PASSWORD}" \
  --from-literal=AWS_ACCESS_KEY_ID="${B2_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${B2_APP_KEY}" \
| kubeseal --format yaml \
    --controller-namespace kube-system \
    --controller-name sealed-secrets-controller \
> "${OUT}"

echo ">>> wrote ${OUT}"
echo ">>> commit it; ArgoCD will unseal it into Secret immich-backup-secrets (ns apps)."
echo ">>> then: kubectl -n apps create job --from=cronjob/immich-backup immich-backup-manual   # to test the first run"
