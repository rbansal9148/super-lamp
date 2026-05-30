#!/usr/bin/env bash
# validate-gitops.sh — offline + (optional) server-side validation of the GitOps
# manifests under gitops/. Substitute for `kubectl apply --dry-run=server` when no
# cluster is reachable (see docs/adr/0001-observability-stack.md).
#
# Two layers:
#   1. yq        — YAML grammar (every doc, incl. multi-doc files).
#   2. kubeconform — schema validation against k8s OpenAPI + CRD schemas
#                    (VictoriaMetrics / OpenTelemetry / Traefik / cert-manager /
#                     Prometheus-operator / ArgoCD) from the datreeio CRDs-catalog.
#
# If kubectl is installed AND the current-context cluster is reachable, it also runs
# a real server-side dry-run (the authoritative check — needs the CRDs installed).
#
# Usage:  scripts/validate-gitops.sh [path]      (default: gitops/)
# Tools are installed on demand into "$(go env GOPATH)/bin"; idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$ROOT/gitops}"
GOBIN="$(go env GOPATH 2>/dev/null)/bin"
export PATH="$GOBIN:$PATH"

# Pin the k8s API version kubeconform validates native kinds against (k3s line).
KUBE_VERSION="${KUBE_VERSION:-1.31.0}"
CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need_tool() {  # need_tool <bin> <go-install-path>
  local bin="$1" pkg="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  command -v go >/dev/null 2>&1 || die "$bin missing and 'go' not on PATH to install it"
  log "installing $bin ($pkg)…"
  go install "$pkg" >/dev/null 2>&1 || die "failed to install $bin"
}

need_tool yq         github.com/mikefarah/yq/v4@latest
need_tool kubeconform github.com/yannh/kubeconform/cmd/kubeconform@latest

mapfile -t FILES < <(find "$TARGET" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[ "${#FILES[@]}" -gt 0 ] || die "no YAML under $TARGET"
log "validating ${#FILES[@]} files under ${TARGET#"$ROOT"/}"

# ── Layer 1: YAML grammar ──────────────────────────────────────────────────────
log "yq grammar check"
for f in "${FILES[@]}"; do
  yq -e 'true' "$f" >/dev/null 2>&1 || die "YAML parse error: $f"
done
# embedded Helm values blocks are YAML-in-a-string — validate them too
for f in "${FILES[@]}"; do
  vals="$(yq -r 'select(.kind=="Application") | .spec.source.helm.values // ""' "$f" 2>/dev/null || true)"
  [ -z "$vals" ] && continue
  echo "$vals" | yq -e 'true' >/dev/null 2>&1 || die "embedded helm values invalid: $f"
done
log "grammar OK (outer docs + embedded helm values)"

# ── Layer 2: kubeconform schema validation ─────────────────────────────────────
log "kubeconform (k8s $KUBE_VERSION + CRD catalog; missing CRD schemas are skipped)"
kubeconform \
  -strict \
  -ignore-missing-schemas \
  -kubernetes-version "$KUBE_VERSION" \
  -schema-location default \
  -schema-location "$CRD_CATALOG" \
  -summary -verbose \
  "${FILES[@]}" || die "kubeconform reported schema errors"

# ── Layer 3 (optional): real server-side dry-run ───────────────────────────────
if command -v kubectl >/dev/null 2>&1; then
  srv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  hostport="${srv#*://}"; host="${hostport%%:*}"; port="${hostport##*:}"
  if [ -n "$host" ] && timeout 5 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    log "cluster reachable ($srv) — server-side dry-run"
    kubectl apply --dry-run=server -f "$TARGET" --recursive \
      || warn "server dry-run errors (expected if operator CRDs aren't installed yet)"
  else
    warn "kubectl present but cluster unreachable ($srv) — skipping server dry-run"
  fi
else
  warn "kubectl not installed — skipping server-side dry-run (offline checks only)"
fi

log "done"
