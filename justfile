# GitOps ergonomics — seal secrets + validate manifests.
# Thin wrappers over the kubeseal / validate ceremony so the 5 fixed flags
# (--scope strict, --namespace, --name, --controller-namespace, --controller-name)
# aren't retyped (and mistyped) by hand each time. Run `just` for the list.
#
# Secret values are NEVER passed as recipe arguments — args land in shell history
# and `ps`. `seal-key` reads the value from a silent prompt (or a pipe) instead.

set shell := ["bash", "-cu"]

# SealedSecrets controller location (override via env if it ever moves):
controller_ns   := env_var_or_default("SEALED_CONTROLLER_NS", "kube-system")
controller_name := env_var_or_default("SEALED_CONTROLLER_NAME", "sealed-secrets-controller")

# Show available recipes.
default:
    @just --list

# Pass a sub-path to scope it; default is the whole tree.

# Validate GitOps manifests (yq + kubeconform) — same gate as the pre-commit hook.
validate path="gitops":
    bash scripts/validate-gitops.sh {{path}}

# Reads the value from a hidden prompt (or stdin) — never an arg — and prints the
# `    key: <ciphertext>` line to paste under spec.encryptedData.
#   just seal-key apps comet-secrets POSTGRES_PASSWORD

# Seal one value into an existing strict-scoped SealedSecret.
seal-key ns secret key:
    @printf 'value for %s/%s key %s (hidden): ' '{{ns}}' '{{secret}}' '{{key}}' >&2; \
      read -rs val; echo >&2; \
      printf '%s' "$val" \
      | kubeseal --raw --scope strict --namespace '{{ns}}' --name '{{secret}}' \
                 --controller-namespace '{{controller_ns}}' --controller-name '{{controller_name}}' \
      | { printf '    {{key}}: '; cat; echo; }

# Public cert is safe to keep/commit; `kubeseal --raw --cert <file>` then seals offline.

# Fetch the controller's public cert for offline sealing.
fetch-cert out="sealed-secrets-pub.pem":
    kubeseal --controller-namespace '{{controller_ns}}' --controller-name '{{controller_name}}' \
             --fetch-cert > '{{out}}'
    @echo "wrote {{out}} (public cert — safe to commit)" >&2
