# GitOps — observability stack

ArgoCD app-of-apps implementing [ADR 0001](../docs/adr/0001-observability-stack.md):
**OTel Collector → VictoriaMetrics + VictoriaLogs → Grafana → ntfy**, reconciled by
ArgoCD with sync-wave ordering. Target: **k3s**, **Traefik** ingress, **Sealed Secrets**.

See the [observability primer](../docs/observability-primer.md) for the concepts.

## Layout

```
gitops/
  bootstrap/
    root-app.yaml              # app-of-apps root → apps/observability/ (recurse)
    sealed-secrets.yaml        # Sealed Secrets controller (wave -2)
  apps/observability/
    namespace.yaml             # wave -1
    prometheus-operator-crds.yaml  # wave 0  Application (ServiceMonitor/PodMonitor CRDs, standalone)
    otel-operator.yaml         # wave 0  Application (helm)
    vm-operator.yaml           # wave 0  Application (helm)
    vm-single.yaml             # wave 1  VMSingle CR  (retentionPeriod 3mo, local-path PVC)
    victoria-logs.yaml         # wave 1  VLogs CR     (retentionPeriod 1mo, local-path PVC)
    otel-collectors.yaml       # wave 1  RBAC + StatefulSet/TA collector + DaemonSet collector
    grafana.yaml               # wave 1  Application (helm) — datasources + alerting → ntfy
    ingressroutes.yaml         # wave 2  Traefik IngressRoute (Grafana only) + cert-manager Certificate
    servicemonitors/traefik.yaml   # wave 2  enable Traefik metrics (HelmChartConfig) + ServiceMonitor
    alerts/alerts.yaml         # wave 2  sample symptom alert + alerting docs
    secrets/README.md          # kubeseal recipe for grafana-admin (ntfy.sh needs no secret)
```

## Pinned chart versions (latest stable, 2026-05-30)

| Chart | Version | App |
|---|---|---|
| sealed-secrets | 2.18.6 | 0.37.0 |
| prometheus-operator-crds | 29.0.0 | v0.91.0 |
| opentelemetry-operator | 0.114.1 | 0.152.0 |
| victoria-metrics-operator | 0.63.1 | v0.70.1 |
| grafana | 10.5.15 | 12.3.1 |

Refresh with: `helm repo add … && helm search repo <chart> --versions | head`.

## Prerequisites

1. **k3s** with its bundled Traefik + `local-path` StorageClass (defaults).
2. **ArgoCD** installed in the `argocd` namespace; repo credentials registered for this
   (private) repo.
3. **cert-manager** + a `ClusterIssuer` named `letsencrypt-prod` (for the Grafana TLS
   `Certificate`). Adjust the issuer name in `ingressroutes.yaml` if yours differs.
4. **kubeseal** CLI locally (to generate the SealedSecrets — see `secrets/README.md`).

## Bootstrap

```bash
# 1. seal the secrets first (controller must be reachable)
kubectl apply -f gitops/bootstrap/sealed-secrets.yaml
#    … then follow secrets/README.md to produce the two *.sealedsecret.yaml and commit them
# 2. apply the root app — ArgoCD reconciles everything else
kubectl apply -f gitops/bootstrap/root-app.yaml
```

## Ordering (why sync-waves are load-bearing — primer §7)

`-2` controller → `-1` namespace → `0` operators + CRDs → `1` CRs (VMSingle/VLogs/
collectors/Grafana) → `2` ServiceMonitors/IngressRoutes/alerts. ArgoCD waits for each
wave's resources (including child Applications) to report Healthy before the next, so
operators/CRDs exist before any CR of their kind. The root app's `retry` (5×, backoff)
absorbs the brief operator-Healthy → CR-apply races.

## ADR guardrails enforced here

1. **Retention caps from day one** — `retentionPeriod` set on both VMSingle (3mo) and
   VLogs (1mo); VLogs schema *requires* it.
2. **Don't ship everything** — the DaemonSet collector has a documented drop-point;
   add a `filter` processor before going wide.
3. **No plaintext secrets** — Sealed Secrets; raw secrets never committed.
4. **prune/selfHeal away from data** — data PVCs are operator-created (not git-tracked,
   so never pruned) and CRs set `removePvcAfterDelete: false`.

## Security notes

- **Only Grafana is exposed** (it authenticates). vmui / VictoriaLogs UI have no auth and
  are intentionally internal — reach them via `kubectl port-forward`. Expose only behind an
  Authelia forward-auth Middleware (commented stub in `ingressroutes.yaml`).
- Domain-based addressing throughout (`*.my-blue-car.work`), no hardcoded ClusterIPs/NodePorts.

## Not yet included (deliberate scope)

- **kube-state-metrics** (k8s object state) — add as a Deployment + ServiceMonitor when wanted.
- **HPA / KEDA** for Tier-A workloads — see ADR D7 / forks F3–F4; design is decided, not deployed.
- **ntfy itself** — treated as existing infra (ADR keeps it); only the Grafana contact point is wired.
