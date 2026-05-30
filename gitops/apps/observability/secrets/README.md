# Secrets (Sealed Secrets)

ADR guardrail 3: secrets never sit in plaintext git. The controller is installed by
`gitops/bootstrap/sealed-secrets.yaml`. You generate `SealedSecret` resources locally
with `kubeseal` and commit the *encrypted* output here — only the in-cluster controller
can decrypt them into real `Secret`s.

Prereq: `kubeseal` CLI + the controller running (`kube-system/sealed-secrets-controller`).

## 1. Grafana admin (consumed by grafana.yaml → `existingSecret: grafana-admin`)

```bash
kubectl create secret generic grafana-admin \
  --namespace observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
           --format yaml \
> grafana-admin.sealedsecret.yaml
```

## 2. ntfy token (consumed by grafana.yaml → `envFromSecret: grafana-ntfy`, key `NTFY_TOKEN`)

```bash
kubectl create secret generic grafana-ntfy \
  --namespace observability \
  --from-literal=NTFY_TOKEN="Bearer tk_your_ntfy_token" \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
           --format yaml \
> grafana-ntfy.sealedsecret.yaml
```

Commit the two `*.sealedsecret.yaml` files in this directory. They sync at wave 0
(the SealedSecret CRD ships with the controller); ArgoCD retry covers the brief window
before the controller decrypts them into Secrets that Grafana (wave 1) consumes.

> The raw `kubectl create secret ... --dry-run` output is NOT committed — it is piped
> straight into `kubeseal`. Only the sealed form lands in git.
