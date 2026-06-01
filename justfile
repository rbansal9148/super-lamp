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

# Validate the GitOps manifests (yq grammar + kubeconform schema) — the same gate
# the pre-commit hook runs. Pass a sub-path to scope it; default is the whole tree.
validate path="gitops":
    bash scripts/validate-gitops.sh {{path}}

# Seal ONE value for an existing strict-scoped SealedSecret and print the
# `    key: <ciphertext>` line to paste under spec.encryptedData. The value is read
# from a hidden prompt (or stdin if piped) — never from an argument.
#
#   just seal-key apps comet-secrets POSTGRES_PASSWORD
seal-key ns secret key:
    @printf 'value for %s/%s key %s (hidden): ' '{{ns}}' '{{secret}}' '{{key}}' >&2; \
      read -rs val; echo >&2; \
      printf '%s' "$val" \
      | kubeseal --raw --scope strict --namespace '{{ns}}' --name '{{secret}}' \
                 --controller-namespace '{{controller_ns}}' --controller-name '{{controller_name}}' \
      | { printf '    {{key}}: '; cat; echo; }

# Fetch the controller's PUBLIC cert (safe to keep/commit) so `kubeseal --raw --cert
# <file>` can seal offline, without cluster access.
fetch-cert out="sealed-secrets-pub.pem":
    kubeseal --controller-namespace '{{controller_ns}}' --controller-name '{{controller_name}}' \
             --fetch-cert > '{{out}}'
    @echo "wrote {{out}} (public cert — safe to commit)" >&2
