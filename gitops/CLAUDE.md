# gitops — the declarative cluster (ArgoCD-managed)

Everything here is reconciled by ArgoCD from `git@github.com:rbansal9148/super-lamp.git` (branch
`main`). Change = commit + push; ArgoCD syncs. Bootstrap the whole cluster with
`kubectl apply -f gitops/bootstrap/`.

## App-of-apps topology

- `bootstrap/root-app.yaml` → syncs `gitops/apps/observability/` (recurse) → the observability child
  apps, incl. **`observability-resources`** which owns `gitops/manifests/observability`.
- `bootstrap/apps-root.yaml` → syncs `gitops/apps/` (recurse, **excludes `observability/**`**) →
  every other app CR (cert-manager + the ~21 streaming/infra apps).
- `bootstrap/sealed-secrets.yaml` → the SealedSecrets controller (sync-wave -2, before any Secret).

## Adding an app

1. `gitops/manifests/<app>/` — the k8s YAML. Put app-specific rationale in the file **header
   comment** (the repo convention).
2. `gitops/apps/<app>.yaml` — an ArgoCD `Application` (copy an existing one: `destination.namespace:
   apps`, `path: gitops/manifests/<app>`, `directory.recurse: true`). `apps-root` auto-registers it —
   no manual `kubectl apply`.

## Gotchas

- **Per-app Application CRs have NO cascade finalizer** (only `apps-root`/`root-app` do). Deleting an
  app CR — or `git rm`-ing its file so `apps-root` prunes it — **orphans its live workloads** instead
  of deleting them; you must `kubectl delete` the leftover namespace + cluster-scoped RBAC by hand.
  (Verified 2026-07-11 removing external-dns.)
- Apps land in the **`apps`** namespace (auto-meshed by linkerd). Isolation is enforced — see
  `manifests/network-policies/CLAUDE.md`.
- `syncPolicy: automated {prune, selfHeal}` — a hand-edited live resource is reverted. **Edit git, not
  the cluster.**

## Ops

```bash
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite   # force re-sync
kubectl -n argocd get applications                                                          # sync/health
```

<!-- init-deep: generated 2026-07-11 from sha=edc1d16 -->
