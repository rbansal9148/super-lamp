# Observability primer — concepts, whys, and gotchas

Companion to [ADR 0001](./adr/0001-observability-stack.md). That ADR records *what*
we chose (VictoriaMetrics + VictoriaLogs + OpenTelemetry Collector + Grafana +
ArgoCD); this primer explains the *mental models* behind those choices. The whys
matter more than the syntax — syntax you look up, but the wrong mental model costs
days.

Read each section as **concept → why it's built that way → the gotcha that bites**.

---

## 1. Time-series metrics — the foundation

**Concept.** A metric is not a number; it's a *named stream of (timestamp, value)
samples* identified by its **label set**. `http_requests_total{router="plex",
code="200"}` and `http_requests_total{router="plex", code="500"}` are **two distinct
time series** despite the shared name. A TSDB (VictoriaMetrics) stores these streams
compressed and queries across them.

**Why this design.** Labels are dimensions you slice by *at query time* — you don't
pre-aggregate. "Error rate for Plex over the last hour" is a *query*, not a pre-built
counter. This is what lets one Traefik metric answer a hundred questions.

**The gotcha that dominates everything: cardinality.** The number of *unique label
combinations* is what kills metrics systems — not sample count, not disk. Each unique
combination is a separate series the TSDB indexes and holds in memory. Put a
high-variance value in a label — `user_id`, `request_id`, `session`, a URL path with
IDs — and you get a **cardinality explosion**: millions of series, OOM, query
timeouts. Rule: *labels are for bounded, low-variance dimensions* (status code,
method, route name, service). Unbounded data belongs in **logs**, not metric labels.
This one mistake causes more metrics outages than all others combined.

**Counter vs gauge vs histogram — and why it matters.**
- **Counter** — monotonically increasing (total requests). Never graph the raw value;
  graph `rate()` of it. Resets to 0 on restart, and `rate()` is built to detect that.
- **Gauge** — goes up and down (memory in use, queue depth). Graph directly.
- **Histogram** — bucketed observations (request durations). The *only* way to get
  **p50/p95/p99 latency**. You cannot compute a percentile from an average — averages
  hide the tail. Percentiles need the distribution, which buckets preserve.

**Pull vs push.** Prometheus-lineage systems **pull** (scrape a `/metrics` endpoint on
an interval): the monitoring system controls cadence, distinguishes "down" from
"silent," and targets need not know where to send. OTLP **pushes**. Our stack does
both (scrape app `/metrics` via the Collector, push OTLP to VM) — which is why the
temporality gotcha exists.

**The temporality gotcha (`deltatocumulative`).** A counter can be **cumulative**
(running total since start — Prometheus model) or **delta** (amount since last report
— some OTLP sources). VM only understands cumulative. If an OTLP source emits delta
and you don't convert, VM ingests garbage *silently* — no error, wrong rates. Hence
the `deltatocumulative` processor is mandatory and easy to forget.

---

## 2. PromQL — the query mental model

**Concept.** Two value types: an **instant vector** (one value per series, *now*) and
a **range vector** (a window of samples per series, e.g. `[5m]`). Functions consume
one and produce the other.

**The why behind the most common pattern.** `rate(http_requests_total[5m])`: take 5
min of samples, compute per-second average rate of increase, handle counter resets.
You almost never want the raw counter — you want its rate. Then
`sum by (router) (rate(...))` aggregates away labels you don't care about.

**Gotchas:**
- **`rate()` vs `irate()`** — `rate` averages over the whole window (smooth; for
  alerting/dashboards); `irate` uses only the last two points (spiky; for fast
  debugging). Mixing them gives misleading graphs.
- **Range too short** — `rate(...[1m])` at a 30s scrape interval has ~2 points; one
  missed scrape → gaps. Rule of thumb: range ≥ 4× scrape interval.
- **Percentiles from histograms** — `histogram_quantile(0.99, sum by (le)
  (rate(bucket[5m])))`. Must `rate()` the buckets first and preserve the `le` label.
  Get it wrong and your "p99" is silently meaningless.

---

## 3. OpenTelemetry & the Collector — the vendor-neutral layer

**Concept.** OpenTelemetry is two things: a **data model + wire protocol (OTLP)** for
three signals (metrics, logs, traces), and a **Collector** that receives, processes,
and exports. The Collector is a pipeline engine:

```
receivers → processors → exporters
(otlp,        (batch,            (otlphttp →
 prometheus,   deltatocumulative,  VM / VictoriaLogs)
 filelog)      memory_limiter,
               resource, filter)
```

**Why vendor-neutral matters (our reason for choosing it).** Instrumentation and
collection are decoupled from the backend. Swap VM for anything that speaks OTLP and
you change one exporter line — never re-instrument apps or re-plumb agents. That's the
lock-in hedge; the cost was the two-tier topology below.

**Why two Collectors (the topology cost).** The two jobs have incompatible deployment
shapes:
- **DaemonSet** (one pod per node) — node-local work: reading container log files
  (`filelog` receiver), host metrics. Must be on every node.
- **StatefulSet + Target Allocator** — scraping `/metrics` endpoints. The Target
  Allocator shards scrape targets across collector replicas (so no single collector
  scrapes everything) and needs stable identity → statefulset.

**Gotchas:**
- **`batch` processor is not optional** — without it, one export call per data point.
- **`memory_limiter` processor** — a Collector under ingestion pressure OOMs and loses
  data; the limiter sheds load instead. Add it in production.
- **Semantic conventions** — OTel standardizes attribute names (`http.request.method`,
  `service.name`). Use them; custom attribute names break convention-based dashboards.

---

## 4. Service discovery & ServiceMonitor — why the indirection

**Concept.** In K8s, pods come and go with random IPs; you can't hardcode targets. A
**ServiceMonitor** is a CRD that declares: "scrape any Service matching these labels,
on this port, at this path/interval." A controller turns that into concrete targets
continuously.

**Why this abstraction.** It decouples "what to scrape" (owned by the app, lives next
to it) from "the monitoring system" (owned by platform). Add a service with a
ServiceMonitor and it's scraped automatically — no central config edit. The single
most important operational ergonomic in K8s monitoring.

**Why the Target Allocator exists (our stack).** The OTel Collector's prometheus
receiver can read ServiceMonitors, but with multiple replicas for HA, *each* would
scrape *all* targets — duplicate data, wasted load. The Target Allocator distributes
targets across replicas (consistent-hashing) so each is scraped once. The OTel answer
to scaling scraping horizontally.

**Gotcha.** The ServiceMonitor/PodMonitor **CRDs must be installed even without
Prometheus running** — the Target Allocator consumes the *CRD shape*, not Prometheus
itself. Forget to install them standalone and your ServiceMonitors are inert YAML.

---

## 5. Logs aggregation — the label-index philosophy

**Concept.** Loki/VictoriaLogs index **labels** (stream metadata: `service`,
`namespace`, `level`), *not* full log text. You select streams via labels, then grep
within. The opposite of Elasticsearch, which full-text-indexes everything.

**Why.** Full-text indexing is expensive (CPU, disk, RAM — Elastic's whole cost
profile). Label-indexing is cheap to ingest and store; you trade fast arbitrary-text
search for cheap storage + "narrow by labels, then scan." For a homelab, the correct
trade.

**Gotchas:**
- **Cardinality, again** — a high-variance log *label* (not field) blows up the stream
  index. Keep labels bounded; put variable stuff in the log line.
- **Structured logging pays off** — JSON lines let you filter on fields without regex;
  unstructured logs force `|~ "regex"` scans.
- **Retention is mandatory, not default** — VictoriaLogs makes `retentionPeriod` a
  *required* field so you can't footgun yourself. Given the 148 MB-accesslog history,
  the schema is protecting you.
- **Don't ship everything** — 100 chatty containers bury signal and cost storage. Drop
  noise at the collector.

---

## 6. Grafana & alerting — the model people get wrong

**Concept.** Grafana is a *query frontend* over datasources (VM, VictoriaLogs).
Dashboards are JSON; **provision them from git** — don't click-build in the UI (those
changes live in Grafana's DB and vanish on redeploy: the classic "where did my
dashboard go").

**Unified alerting model — three separate objects, often conflated:**
- **Alert rule** — query + condition + duration (`for: 5m`), evaluated on a schedule.
- **Notification policy** — routing tree: which alerts → which contact point,
  grouping, timing.
- **Contact point** — the delivery target (our `ntfy`).

**Gotchas:**
- **The `for:` duration** — `for: 5m` means the condition must hold *continuously* for
  5 min before firing. Your anti-flapping control. Too short → spam on blips; too long
  → slow to notice outages. The most important tuning knob.
- **Pending vs Firing** — "pending" = condition tripped but `for:` not yet satisfied.
  Not a notification yet; don't panic at pending.
- **Alert on symptoms, not causes** — alert on "Plex returns 5xx" (user-visible), not
  "CPU 80%" (often harmless). Cause-based alerts are the main source of alert fatigue.
- **`NoData` handling** — decide explicitly what "query returned nothing" means. A down
  exporter returns no data; treating NoData as OK creates a blind spot exactly when
  something is broken.

---

## 7. GitOps & ArgoCD — declarative reconciliation

**Concept.** The git repo is the **desired state**. A controller in the cluster
continuously compares desired (git) vs actual (live) and reconciles. You never
`kubectl apply` by hand; you `git push` and the controller converges. A *control
loop*, not a deploy script.

**Why fundamentally different from CI/CD push.** Traditional CI pushes *to* the
cluster (cluster passive, creds in CI). GitOps **pulls** — the cluster reconciles
itself from git (no external system holds cluster creds). Plus **drift correction**:
hand-edit a live resource and the controller reverts it to match git. Git is not just
where you deploy from — it's continuously enforced truth.

**Sync waves (load-bearing).** ArgoCD applies resources in waves (`sync-wave`
annotation). Hard ordering constraint: **a CRD must exist before a CR of that kind,
and an operator must run before its CRs.** Apply a `VLogs` CR before the VM Operator's
CRD is registered → `no matches for kind "VLogs"` → failed sync. Hence wave 0 =
operators + CRDs, wave 1 = CRs, wave 2 = dashboards/alerts.

**App-of-apps.** One root `Application` whose job is to create *other* Applications —
bootstrap an entire stack from a single root, manage it as a unit. Scales to
**ApplicationSet** (templating across dirs/clusters) later.

**Gotchas:**
- **`prune: true` is a loaded gun near PVCs** — remove a manifest from git and ArgoCD
  deletes the live resource. A refactor that accidentally drops a PVC manifest deletes
  your retention data. Scope automated sync away from stateful resources.
- **`selfHeal: true`** — reverts manual changes. Great for config drift; infuriating
  when ArgoCD keeps undoing your mid-debug `kubectl edit`. Know it's on.
- **Sync status ≠ Health status** — "Synced" = live matches git; "Healthy" = actually
  working. A Deployment can be Synced (correct spec) but Unhealthy (crashlooping).
  Watch both.
- **Secrets can't sit in git** — the central GitOps tension. Plaintext secrets in git
  is a breach. Solutions encrypt *before* commit (SOPS, Sealed Secrets) or reference an
  external store (External Secrets Operator). Day-one work, not later.

---

## 8. Autoscaling & cardinality — where §1's villain meets the cluster

**Concept.** Cardinality (§1, §5) is usually framed as a *labelling* mistake — put
`user_id` in a label, explode the series count. But on K8s there's a second source that
isn't a mistake at all: **the platform manufactures churn for you.** Every pod carries
its own identity labels (`pod`, `instance`, often a ReplicaSet hash). A Deployment that
scales 1→N multiplies that workload's series by N *while N pods live*; an HPA that scales
up and back down leaves the old pods' series as **stale-but-indexed** entries for the rest
of the retention window. The label set is perfectly bounded at any instant — the *churn
over time* is what accumulates.

**Why it bites here specifically.** Vertical-pod restarts, rolling deploys, and HPA
flapping all mint new pod identities. A workload that reschedules a few times an hour can,
over a multi-week retention window, leave thousands of dead series indexed — none of them
a labelling bug, all of them RAM. This is the operational form of ADR 0001's **D7**: only
Tier-A (autoscaled) workloads generate it, and it scales with replica *count × churn rate*,
not with request volume. VM single-node has the headroom (~1000× under its line), but
active-series is the budget that closes first, not samples/sec.

**Gotchas:**
- **Drop per-pod labels where the aggregate is what you query.** If you only ever look at
  a workload's metrics summed across replicas (`sum by (service) (...)`), the `pod` /
  `instance` labels are pure churn — drop or relabel them at the Collector for Tier-A
  Deployments. Keep them only where you genuinely debug per-pod.
- **`histogram_quantile` over churning pods inflates the bucket count** — every pod
  contributes its own `le`-labelled series; relabel before the buckets fan out, not after.
- **Alert on active-series growth, not just disk.** Disk fills slowly and visibly; series
  count climbs quietly and OOMs the TSDB first. A `vm_rows` / active-series panel + a `for:`
  threshold is the early-warning that catches a churn regression before it pages you as an
  outage.
- **Scale-to-zero is the cardinality-friendly direction.** A workload idled to zero stops
  minting new series; the existing ones age out under retention. The §D7 "scale-to-zero
  over scale-out" lean is also the lower-cardinality lean — they reinforce.

---

## The cross-cutting themes, distilled

1. **Cardinality is the recurring villain** — in metric labels *and* log labels.
   Bounded dimensions in labels, unbounded data in the payload. This avoids ~80% of
   observability outages.
2. **Retention is opt-in discipline, not a default** — this host has the scar (148 MB
   unbounded accesslog) to prove it. Cap everything at deploy.
3. **Symptoms over causes for alerts** — or you drown in noise and start ignoring pages.
4. **Declarative + reconciled is the through-line** — ServiceMonitors, CRs, and ArgoCD
   are all "declare desired state, let a controller converge." Once that clicks, the
   whole stack is one pattern repeated.

---

<sub>Primer written 2026-05-30. Companion to ADR 0001. Conceptual reference — update as
the stack evolves; not a decision record.</sub>
