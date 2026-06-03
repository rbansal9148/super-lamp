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

> Alerting (ntfy) needs NO secret here: Grafana's contact point posts to a hosted
> ntfy.sh webhook on a random, unauthenticated topic (the topic name is the access
> control). The former `grafana-ntfy` SealedSecret held the self-hosted ntfy bearer
> token and was removed when ntfy moved to ntfy.sh.

Commit the `grafana-admin.sealedsecret.yaml` file in this directory. It syncs at wave 0
(the SealedSecret CRD ships with the controller); ArgoCD retry covers the brief window
before the controller decrypts it into the Secret that Grafana (wave 1) consumes.

> The raw `kubectl create secret ... --dry-run` output is NOT committed — it is piped
> straight into `kubeseal`. Only the sealed form lands in git.
