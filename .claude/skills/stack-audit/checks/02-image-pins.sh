#!/bin/bash
# Image-pin drift (k8s). This stack pins images by @sha256 digest (e.g. KSM in
# manifests/observability/kube-state-metrics.yaml) so a restart can't silently pull a
# breaking change — the exact failure the crashloop alarm exists to catch AFTER the
# fact. This catches it BEFORE: a running container whose image carries NO digest (a
# bare/mutable tag, or :latest) can mutate under you on the next pull. Static, no
# metric → audit-only. Scoped to owned namespaces; third-party operators we can't repin.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || exit 0
OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"

for ns in $OWNED; do
  kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase=="Running") | .metadata.name as $p
    | (.spec.containers[], (.spec.initContainers // [])[])
    | [$p, .name, .image] | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r pod cn img; do
      case "$img" in
        *@sha256:*) : ;;                                        # pinned — good
        *:latest|*:latest@*) echo "MED|image/pin|$ns/$pod ($cn) runs :latest — non-reproducible, next pull may break it|pin to a @sha256 digest in its manifest" ;;
        *:*) echo "LOW|image/pin|$ns/$pod ($cn) image '$img' has a mutable tag, no @sha256 digest — pin for reproducibility|append @sha256:<digest> in its manifest" ;;
        *)   echo "MED|image/pin|$ns/$pod ($cn) image '$img' has no tag (implicit :latest)|pin to a @sha256 digest in its manifest" ;;
      esac
    done
done
