# ADR 0001 — Observability stack for the streaming platform

- **Status:** Accepted
- **Date:** 2026-05-30
- **Deciders:** rubal.bansal
- **Context commit:** `44f9235` (compose-era repo, pre-Kubernetes)
- **Supersedes:** —

---

## Context

The platform runs ~100+ self-hosted services on a single Docker host behind Traefik
(`apps/traefik/compose.yaml`), fronted by Authelia, with Let's Encrypt TLS. An
observability layer already exists and partially covers the need:

| Concern | Tool today | Verdict |
|---|---|---|
| Host + container resource metrics | `beszel` + `beszel_agent` | Keep on compose; **retire at K8s migration** (does not fit the cluster model) |
| Uptime / blackbox + status page | `uptime-kuma` | Keep — do not duplicate with blackbox_exporter |
| Live container logs | `dozzle` | Keep — realtime glance; complements (not replaced by) aggregated logs |
| Security / WAF events | `crowdsec` (Traefik + sshd logs) | Keep |
| Network / ISP bandwidth | `speedtest-tracker` | Keep |
| Notification delivery | `ntfy`, `apprise`, `notifiarr` | Keep — `ntfy` becomes the unified alert sink |

**The single structural gap:** no time-series metrics backend and no aggregated,
searchable, retained logs. Traefik is the chokepoint every HTTP service passes
through, yet `apps/traefik/compose.yaml:21-34` enables `--accesslog=true` but **no
Prometheus metrics endpoint** — nothing captures request rate, latency percentiles,
or 4xx/5xx per router. `beszel` structurally cannot see application/proxy-level
signals.

**Decisive constraint:** a migration to Kubernetes is imminent (weeks). This makes
"build the full stack on compose now" a build-and-teardown waste. The decision is
therefore scoped to the **target K8s architecture**, with only zero-throwaway,
fully-portable work done in the compose interim.

## Decision drivers

- Single host now → Kubernetes in weeks. Choose components identical pre- and
  post-migration so the cutover is a redeploy, not a re-architecture.
- Homelab scale: ~100 services, on the order of a few thousand samples/sec — three
  orders of magnitude below where heavyweight TSDB topologies are warranted.
- This host has a documented history of **unbounded-storage pain** (Traefik
  accesslog grew to 148 MB unbounded, per the comment at
  `apps/traefik/compose.yaml:31`). Retention discipline is mandatory from day one.
- Avoid collector-layer vendor lock-in (operator preference).
- Operability while ramping on Kubernetes favours visible, debuggable tooling.

---

## Decisions

### D1 — Metrics backend: **VictoriaMetrics** (not Prometheus / Mimir / managed)

Single-node VictoriaMetrics, deployed via the VictoriaMetrics Operator on K8s.

- VM's own guidance: use single-node below ~1M datapoints/sec; it "scales
  vertically… significantly easier to operate than cluster"
  ([cluster wiki](https://github.com/victoriametrics/victoriametrics/wiki/Cluster-VictoriaMetrics)).
  We are ~1000× under that line.
- A user case study reports VM "significantly outperformed Prometheus in CPU and
  RAM… required only a third of the storage"
  ([DFKI case study](https://github.com/victoriametrics/victoriametrics/blob/master/docs/victoriametrics/CaseStudies.md)).
  Treated as **directional**, not a contract — it is a testimonial, not a controlled benchmark.
- PromQL-compatible, so dashboards and alert rules port unchanged.

**Accepted downside (ecosystem gravity):** Prometheus is the K8s default; runbooks
and community Q&A skew Prometheus. VM's CRD/PromQL compatibility neutralises most of
this, but operational folklore does not. **Open fork F1** below.

### D2 — Logs backend: **VictoriaLogs** (not Loki / Elastic / managed)

- Single binary, lighter than Loki for one host; same vendor as VM.
- First-class operator CRD (`VLogs`) with a **required `retentionPeriod`** field
  ([operator API](https://github.com/victoriametrics/operator/blob/master/docs/api.md))
  — retention is enforced by the schema, not optional.
- Accepts OTLP and the Loki push API, so the collector ships to it unmodified.
- **Lowest-lock-in decision in this ADR**: swapping to Loki later is a near-identical
  collector config change. Not worth deep deliberation.

### D3 — Collection: **OpenTelemetry Collector** (not Grafana Alloy / Promtail / Fluent Bit)

Chosen for vendor-neutrality — the collection layer survives a future backend swap
without re-plumbing. Concrete consequences:

- **ServiceMonitor discovery is preserved** via the OTel Operator's **Target
  Allocator** (`targetAllocator.prometheusCR.enabled: true`), which discovers
  `ServiceMonitor`/`PodMonitor` CRDs and feeds the prometheus receiver
  ([otel-allocator README](https://github.com/open-telemetry/opentelemetry-operator/blob/main/cmd/otel-allocator/README.md)).
  The Prometheus-Operator CRDs must be installed standalone (Prometheus itself is not required).
- **VM/VictoriaLogs ingest OTLP natively** — Collector `otlphttp` exporter points at
  `:8428/opentelemetry/v1/metrics` and `:9428/insert/opentelemetry/v1/logs`
  ([VM OTel guide](https://github.com/victoriametrics/victoriametrics/blob/master/docs/guides/getting-started-with-opentelemetry/README.md)).
- **Mandatory processor:** VM rejects delta temporality — the metrics pipeline must
  include `deltatocumulative` (or emit cumulative). Omitting it silently drops metrics.
- **Topology cost (accepted):** OTel on K8s is a **two-tier** deployment, not one agent —
  - a **StatefulSet** Collector + Target Allocator for Prometheus-CR scraping (TA
    requires statefulset mode to shard targets across replicas);
  - a **DaemonSet** Collector for node-local logs (`filelog` receiver) + host metrics.
  More moving parts than a single Alloy DaemonSet; this is the price of the lock-in hedge.

`Promtail` rejected: maintenance mode, superseded by Alloy.

### D4 — Packaging & delivery: **ArgoCD (app-of-apps + sync waves)** over Helm; VM Operator

- GitOps: git is the source of truth; ArgoCD reconciles cluster state continuously
  and corrects drift.
- ArgoCD over Flux for the **UI** — while ramping on K8s, the sync/health/diff view
  collapses the "why isn't this syncing" debug loop from `kubectl` archaeology to a
  glance. **Open fork F2** below.
- VM Operator converts Prometheus-Operator CRDs (`ServiceMonitor`, `PodMonitor`,
  `PrometheusRule`, `Probe`, `AlertmanagerConfig`) into native VM scrape objects
  ([operator/integrations/prometheus.md](https://github.com/victoriametrics/operator/blob/master/docs/integrations/prometheus.md)),
  so we author the standard CRDs regardless of backend.

### D5 — Alerting: **consolidate onto Grafana unified alerting → `ntfy`**

Recreate the `uptime-kuma` and `beszel` alert intents as Grafana / `VMRule` alert
rules, contact point = the existing `ntfy`. No new notifier; collapse the current
kuma + beszel + crowdsec + 3-notifier fragmentation onto infrastructure already run.

### D6 — Explicitly NOT adopted

- **cAdvisor / node-exporter on compose** — redundant with `beszel`. (On K8s, the
  equivalents return as standard scrape sources; that is a migration concern, not a today concern.)
- **blackbox_exporter** — `uptime-kuma` already owns synthetic probes + status page.
- **Tempo / Jaeger (tracing)** — no owned, instrumented services; zero spans to collect.
- **Managed SaaS (Datadog / Grafana Cloud)** — per-host / volume pricing is wrong for
  a self-hosted 100-service host. (Pricing not independently verified; revisit if assumptions change.)
- **A compose-era telemetry backend** — imminent K8s migration makes it build-and-teardown waste.

### D7 — Workload & observability scaling model (decide-now, deploy-later)

Grounded in the current fleet: **124 apps, 100 mount persistent volumes, only 3 carry any
`deploy:`/replicas stanza** — this was built as singletons. The "stateless" Stremio resolvers
each ship a **private datastore** (aiostreams→postgres+redis, comet→postgres,
mediafusion→postgres+redis, stremthru→redis, zilean→postgres, prowlarr→postgres); across the
stack: 29 postgres, 15 redis, 4 valkey, 3 mariadb, 2 mongo, 2 clickhouse, 1 mysql. So the app
tier is ~124 singleton processes each 1:1 with a private DB.

**The scaling discriminator is single-writer / leader-only background work — not "has a
volume."** Externalising the DB to Postgres does not make an app replicable if it runs
schedulers, file management, or sync loops that assume one instance.

| Tier | What | K8s object | Scaling |
|---|---|---|---|
| **A — pure request resolvers** | stremthru, comet, aiostreams, proxy-shaped addons | `Deployment` | **Horizontal (HPA-capable).** No durable local state, no leader job. The *only* tier where scale-out is real. |
| **B — resolvers + ingestion worker** | zilean (DMM scraper), mediafusion, prowlarr sync | `Deployment` replicas:1, or split web/worker | Request path replicable; the **background worker is leader-only**. Scale only by splitting web from worker (worker stays 1). |
| **C — stateful management apps** | the \*arr stack, immich, bitmagnet, media managers (the ~100 volume-mounters) | `StatefulSet` / replicas:1 | **Vertical only.** Single-writer logic + RWO PVC (no multi-attach). `replicas: 2` corrupts state. |
| **D — datastores** | the 29 postgres / 15 redis / … | `StatefulSet`, RWO PVC | **Vertical**, or each engine's own primitive (Postgres streaming replicas + PgBouncer; Redis already capped `maxmemory allkeys-lru`). Never plain `replicas: N`. |
| **E — singleton-by-protocol** | gluetun, traefik, authelia | special | gluetun **must** stay 1 (N replicas = N tunnels); traefik 1–2; authelia scales only with a shared session store, else sticky. |

**Of 124 services, a single-digit handful (Tier A) are genuine horizontal-scale candidates.**
Everything else is vertical or fixed-at-1.

**Highest-leverage direction for this profile is scale-to-*zero*, not scale-out.** Workload is
~1000× under VM's single-node line (drivers above); HPA solves a problem this host does not
have, while most of the 124 services sit idle holding RAM 24/7. Scale-to-zero (KEDA
`http-add-on` / request-activated proxy) reclaims that — **Tier A only**, accepting a 1–3 s
cold-start stall on the first call after idle. Tier C cannot (slow start, loses warm cache).

**App scaling pressures the obs stack through cardinality, not throughput.** Each pod carries
its own `pod`/`instance` label, so a Deployment going 1→N N×'s its series and HPA churn
accumulates churned series across the retention window — *this* is VictoriaMetrics' RAM budget,
not sample rate. Consequent design rules:

1. **HPA on Tier A only, gated on `metrics-server`** — not part of the VM stack; absent, HPA
   silently no-ops. CPU trigger by default; RPS via `prometheus-adapter`/KEDA-VM as an upgrade.
2. **Cardinality governance becomes a first-class cap** alongside the retention cap (guardrail 1
   below): drop high-churn labels (`pod`, `instance`) at the collector where per-Service
   aggregate suffices; alert on VM active-series growth.
3. **VM/VLogs stay single-node** — scaling = vertical + retention; the only horizontal lever is
   collector-tier TA sharding (D3), and only when target/node count demands it. Cluster-VM is
   the named escape hatch (**F1**), not a scaling decision.

**Killed as premature (revisit when Tier-A HPA actually ramps):** PgBouncer across the 29
Postgres (connection exhaustion only bites when replicas × pool-size > `max_connections`;
pre-decided, not pre-deployed); VM cluster mode / vmagent remote-write sharding (~1000×
premature — that is fork F1).

---

## Target architecture

```
              ┌────────────────────────── Kubernetes ──────────────────────────┐
              │                                                                 │
 services ──► │  ServiceMonitor / PodMonitor CRs                                │
 (Traefik,    │            │                                                    │
  exporters)  │            ▼                                                    │
              │  OTel Collector (StatefulSet) + Target Allocator ──┐            │
              │                                                    │ OTLP       │
 node logs ──►│  OTel Collector (DaemonSet, filelog) ──────────────┤            │
              │                                                    ▼            │
              │                         VictoriaMetrics ◄── /opentelemetry/...  │
              │                         VictoriaLogs    ◄── /insert/opentelemetry│
              │                              │                                  │
              │                              ▼                                  │
              │                          Grafana ──── unified alerting ──► ntfy │
              │                                                                 │
              │   All reconciled by ArgoCD (app-of-apps, sync waves)            │
              └─────────────────────────────────────────────────────────────────┘
```

### GitOps repo layout (app-of-apps)

```
gitops/
  apps/observability/            # root app-of-apps Application
    otel-operator.yaml           # wave 0  — Application → helm chart
    vm-operator.yaml             # wave 0  — Application → helm chart
    prometheus-operator-crds.yaml# wave 0  — ServiceMonitor/PodMonitor CRDs (standalone)
    vm-single.yaml               # wave 1  — VMSingle CR (retentionPeriod set)
    victoria-logs.yaml           # wave 1  — VLogs CR (retentionPeriod set)
    otel-collectors.yaml         # wave 1  — StatefulSet+TA and DaemonSet collectors
    grafana.yaml                 # wave 1  — helm chart + provisioned dashboards
    servicemonitors/             # wave 2  — ServiceMonitor CRs (traefik + exporters)
    alerts/                      # wave 2  — VMRule / Grafana alert rules → ntfy
```

**Sync-wave ordering is load-bearing**, not cosmetic: operators + CRDs (wave 0) must
be fully applied before any custom resource that uses them (wave 1), or CRs fail with
"no matches for kind." Dashboards/alerts (wave 2) follow.

---

## Consequences

### Positive
- Component choice is identical pre/post-migration; the cutover is a redeploy.
- Standard Prometheus-Operator CRDs authored once, consumed by either VM Operator or
  the OTel Target Allocator — backend and collector are both swappable.
- Portable assets (Grafana dashboards, alert rules) carry over 100%.
- Lightest backend footprint for the scale (~<1 GB RAM target for VM+VLogs+Grafana+collectors).

### Negative / accepted risk
- OTel two-tier collector topology is more to operate than a single agent.
- VM/VictoriaLogs have smaller communities than Prometheus/Loki (mitigated by CRD/PromQL/Loki-API compatibility).
- `deltatocumulative` is a mandatory, easy-to-forget processor.

### Mandatory guardrails (this host's history demands them)
1. **Retention caps from day one.** `VMSingle` and `VLogs` `retentionPeriod` set at
   deploy. The 148 MB unbounded-accesslog incident (`apps/traefik/compose.yaml:31`)
   is the precedent; unbounded telemetry storage is a known failure mode here.
2. **Do not ship all 100+ services' logs.** Use collector relabel/drop rules; ingest
   only what will be queried (Traefik, gluetun, the DBs, stremthru, the arrs).
3. **Secrets never in plaintext git.** `ntfy` token, Grafana admin, TLS → Sealed
   Secrets / External Secrets Operator / SOPS. The #1 GitOps day-one mistake.
4. **`prune` + `selfHeal` scoped away from PVCs.** Auto-heal config: good. Auto-prune
   a PVC during a refactor: deletes retention data. Keep PVCs out of the automated-sync blast radius.

---

## Open forks (decide when the cluster takes shape)

- **F1 — Prometheus (kube-prometheus-stack) over VictoriaMetrics** *if* ecosystem
  familiarity outweighs RAM/disk for the team. Migration manifests are ~80% identical
  either way; the ServiceMonitor authoring is unchanged.
- **F2 — Flux over ArgoCD** *if* footprint / CLI-purity / native-SOPS matters more
  than the UI. Same Helm charts underneath; not a lock-in.
- **F3 — KEDA over plain HPA** *only if* scale-to-zero of idle addons (D7) or
  queue/event triggers are wanted. Otherwise HPA v2 is fewer moving parts.
- **F4 — Split Tier-B web/worker** *only if* a resolver's request path saturates
  while its scraper sits idle. Measure before splitting.

## Inputs still needed to generate manifests

1. **Distro** — k3s / vanilla / managed (drives storage class, ingress defaults).
2. **Ingress on K8s** — does Traefik remain the ingress (golden-signal dashboard
   targets Traefik), or switch to ingress-nginx / Gateway API?
3. **Secret backend** — Sealed Secrets vs External Secrets Operator vs SOPS.

---

<sub>ADR generated 2026-05-30 against commit `44f9235`. Edited 2026-05-30: added D7 (workload & obs scaling model) and forks F3–F4. Decisions D1–D7 accepted; forks F1–F4 open.</sub>
