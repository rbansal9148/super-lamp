## PURPOSE

Observability for the self-hosted streaming platform (~124 Docker-Compose apps on a
single host behind Traefik + Authelia + Let's Encrypt), scoped to the TARGET Kubernetes
architecture because a k3s migration is imminent. Closes the one structural gap: no
time-series metrics backend and no aggregated, retained logs (Traefik runs accesslog but
exposes NO Prometheus metrics). Full record: docs/adr/0001-observability-stack.md.
Existing tools KEPT: beszel (retire at k8s), uptime-kuma, dozzle, crowdsec, ntfy.

## STACK

Metrics: VictoriaMetrics single-node (VMSingle CR) via VM Operator. Logs: VictoriaLogs
(VLogs CR), required retentionPeriod. Collection: OpenTelemetry Collector (-contrib image)
— vendor-neutral. Dashboards/alerting: Grafana unified alerting → ntfy contact point.
Delivery: ArgoCD app-of-apps + sync waves; VM Operator + OTel Operator + standalone
prometheus-operator-crds. Target distro: k3s (storageClassName local-path; bundled Traefik).
Ingress: Traefik IngressRoute CRD. Secrets: Sealed Secrets. Manifests live in gitops/
(README has bootstrap + pinned chart versions). Pinned (2026-05-30): sealed-secrets 2.18.6,
prometheus-operator-crds 29.0.0, opentelemetry-operator 0.114.1 (collector 0.152.0),
victoria-metrics-operator 0.63.1, grafana 10.5.15.

## ARCHITECTURE

Two-tier OTel topology (NOT one agent): StatefulSet collector + Target Allocator
(targetAllocator.prometheusCR.enabled — shards ServiceMonitor/PodMonitor scrape targets)
pushes OTLP metrics to VM; DaemonSet collector (filelog + hostmetrics + kubeletstats)
pushes OTLP logs to VictoriaLogs and metrics to VM. VM does NOT scrape
(disable_prometheus_converter); OTel TA consumes the Prometheus CRDs. OTLP paths:
vmsingle-obs.observability.svc:8428/opentelemetry/v1/metrics and
vlogs-obs.observability.svc:9428/insert/opentelemetry/v1/logs (service naming
vmsingle-<name>/vlogs-<name>). Sync-wave order (load-bearing): -2 sealed-secrets, -1 ns,
0 operators+CRDs, 1 CRs (VM/VLogs/collectors/Grafana), 2 ServiceMonitors/IngressRoute/alerts
— CRDs must exist before any CR of their kind. ClusterRole observability-otel binds
scrape-collector + scrape-targetallocator + node-collector SAs. Traefik metrics enabled on
k3s via HelmChartConfig (helm.cattle.io/v1) in kube-system.

## PATTERNS

GitOps: git is desired state, ArgoCD reconciles + corrects drift; never kubectl apply by
hand. App-of-apps from one root Application. Declarative+reconciled is the through-line
(ServiceMonitors, CRs, ArgoCD all converge to declared state). Domain-based addressing on
*.my-blue-car.work, no hardcoded ClusterIPs/NodePorts. Provision Grafana dashboards/
datasources/alerting from git (never click-build). Alert on symptoms not causes. Workload
scaling model (D7, 5 tiers): only Tier-A pure request resolvers (stremthru/comet/aiostreams)
are HPA-capable; Tier-B resolvers+worker, Tier-C stateful singletons (the ~100 volume
mounters), Tier-D datastores (29 postgres/15 redis), Tier-E singleton-by-protocol (gluetun/
traefik/authelia) scale vertically or stay fixed. Scale-to-zero > scale-out for this homelab.

## TRADEOFFS

deltatocumulative processor MANDATORY (VM rejects delta temporality; silent metric loss if
omitted). Two-tier OTel = more to operate than a single Alloy DaemonSet (price of the
vendor-neutral lock-in hedge). VM/VictoriaLogs smaller communities than Prometheus/Loki
(mitigated by PromQL/CRD/Loki-API compatibility). IngressRoute locks to Traefik CRD
(accepted — portability hedge is at the metrics/collector layer, not ingress). Cardinality
(not throughput) is the obs scaling budget — autoscaling/HPA pod-label churn accumulates
stale series (primer §8); drop pod/instance labels where aggregate suffices. Single-node VM
is ~1000x under its cluster threshold — vertical scaling + retention caps, cluster-VM is the
escape hatch (fork F1). Open forks: F1 Prometheus-vs-VM, F2 Flux-vs-ArgoCD, F3 KEDA-vs-HPA,
F4 split Tier-B web/worker.

## PHILOSOPHY

Choose components identical pre/post-migration so k8s cutover is a redeploy, not a
re-architecture. Mandatory guardrails (this host has unbounded-storage scars — 148MB
Traefik accesslog): (1) retention caps from day one — VMSingle 3mo, VLogs 1mo,
retentionPeriod schema-required on VLogs; (2) don't ship all 100+ services' logs — drop
noise at the collector; (3) secrets never in plaintext git — Sealed Secrets; (4) prune/
selfHeal scoped away from PVCs — data PVCs operator-created (untracked, never pruned) +
removePvcAfterDelete:false. Validate before deploy: scripts/validate-gitops.sh (yq +
kubeconform -strict, 18/18 valid 0 skipped); real server dry-run deferred until cluster
exists (kubeadm kubeconfig 10.0.0.79 is STALE/unreachable, real target is k3s). Status:
manifests generated/validated/committed (9ab4e00), NOT deployed.