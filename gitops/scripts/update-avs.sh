#!/usr/bin/env bash
# update-avs.sh — rebuild the side-loaded auto-verbal-score image from the latest app-repo
# commit, import it into k3s containerd, bump the pinned tag in the gitops manifest, commit.
#
# WHY this is manual: the image has no registry — it lives only in this node's containerd
# (Deployment uses imagePullPolicy: Never). A new app commit is therefore invisible to the
# cluster until this runs. The image tag IS the app commit SHA; bumping it in the manifest is
# the signal ArgoCD acts on to roll the Deployment (reusing a tag = no diff = no rollout).
#
# Idempotent: if the manifest already pins the latest SHA, it no-ops.
#
# Usage:  gitops/scripts/update-avs.sh [--push]
#   (no arg)  build + import + bump + commit, then STOP for review
#   --push    also `git push` (ArgoCD then rolls the pod to the new SHA)
#
# Requires: podman, passwordless sudo for `k3s ctr`, sd, an SSH key for the app repo.
set -euo pipefail

APP_REPO="git@github.com:rbansal9148/auto-verbal-score.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MANIFEST="$REPO_ROOT/gitops/manifests/auto-verbal-score/01-avs.yaml"
DOCKERFILE="$SCRIPT_DIR/avs.Dockerfile"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "==> clone latest $APP_REPO"
git clone -q --depth 1 "$APP_REPO" "$WORK/src"
SHA="$(git -C "$WORK/src" rev-parse --short HEAD)"
IMAGE="localhost/auto-verbal-score:$SHA"
CURRENT="$(grep -oP 'auto-verbal-score:\K\S+' "$MANIFEST" | head -1)"
echo "    deployed=$CURRENT  latest=$SHA"
[ "$CURRENT" = "$SHA" ] && { echo "==> already at $SHA — nothing to do"; exit 0; }

echo "==> build $IMAGE (arm64, hardened non-root)"
cp "$DOCKERFILE" "$WORK/src/Dockerfile.k8s"
podman build -q -f "$WORK/src/Dockerfile.k8s" -t "$IMAGE" "$WORK/src" >/dev/null

echo "==> import into k3s containerd (k8s.io namespace)"
podman save "$IMAGE" -o "$WORK/img.tar"
sudo k3s ctr images import "$WORK/img.tar" >/dev/null
echo "    imported $IMAGE"

echo "==> bump manifest $CURRENT -> $SHA"
sd "auto-verbal-score:$CURRENT" "auto-verbal-score:$SHA" "$MANIFEST"
git -C "$REPO_ROOT" add "$MANIFEST"
git -C "$REPO_ROOT" commit -q -m "chore(auto-verbal-score): bump image $CURRENT -> $SHA"

if [ "${1:-}" = "--push" ]; then
  git -C "$REPO_ROOT" push origin main
  echo "==> pushed — ArgoCD will roll the Deployment to $SHA"
else
  echo "==> committed (not pushed). Review, then: git -C $REPO_ROOT push origin main"
fi
