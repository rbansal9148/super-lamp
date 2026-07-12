# observability — metrics, logs, dashboards, alerts

VictoriaMetrics (metrics) + VictoriaLogs (logs) + Grafana + OTel collectors, in the `observability`
namespace. Owned by the **`observability-resources`** ArgoCD app (`path: gitops/manifests/observability`)
— refresh THAT app after editing here, not `observability`:
`kubectl -n argocd annotate application observability-resources argocd.argoproj.io/refresh=hard --overwrite`.

## Data plane

- **VictoriaMetrics**: `vmsingle-obs.observability:8429` (PromQL). Grafana datasource uid **`victoriametrics`** (type `prometheus`).
- **VictoriaLogs**: `vlsingle-obs.observability:9428` (LogsQL). Datasource uid **`victorialogs`** (type `victoriametrics-logs-datasource`).
- **Scrape**: OTel collector + Target Allocator (`otel-collectors.yaml`) select **all** ServiceMonitors.
  To scrape a new target, add a `ServiceMonitor` under `servicemonitors/`.

## Grafana provisioning (sidecar, label-driven)

- **Dashboards** → ConfigMap labeled `grafana_dashboard: "1"`, dashboard JSON under `data`, in `dashboards/`.
- **Alerts** → ConfigMap labeled `grafana_alert: "1"`, Grafana provisioning YAML under `data`, in `alerts/`.
  Threshold model = an `__expr__` datasource condition (`type: threshold`); route to the existing ntfy
  contact point / `platform` folder. Ground thresholds on measured baselines (query VM first).
- The sidecar reloads via `POST /api/admin/provisioning/alerting/reload` (200 OK = loaded).

## LogsQL gotcha

For cluster-wide error sweeps use the **field-filter** form `k8s.container.name:X i(error)`, NOT the
bare-word aggregate `error OR ERROR | stats by (…)` — the latter mis-attributes counts wildly
(verified 2026-07-11: reported 1.18M "errors" for a container with 0 actual matches).

<!-- init-deep: generated 2026-07-12 from sha=d99636d -->
