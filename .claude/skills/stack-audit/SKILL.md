---
name: stack-audit
description: Run a deterministic config/sizing audit of this k3s + ArgoCD self-hosted stack (apps + observability namespaces). Surfaces the failure classes that have NO continuous metric — memory over/under-allocation, unpinned images, missing probes, Delete-reclaim PVCs — as a prioritized punch list (Critical / High / Medium / Low) with exact kubectl/manifest fixes. Runtime failures (crashloop, OOM, disk-full, pod-not-ready, cert-expiry, ArgoCD drift) are continuous Grafana alarms, not part of this audit.
when_to_use:
  - User asks to "audit", "check the stack", "find problems", "what's wrong", "resource allocation", "right-size"
  - After a wave of manifest changes (verify sizing/pinning/probes didn't regress)
  - Routine periodic config-hygiene check
---

# Stack Audit Skill (k8s edition)

A deterministic, code-driven audit of the k3s cluster managed from `/opt/docker/gitops`.
Single repeatable command → prioritized punch list. No LLM judgement in the default path;
the bash checks encode the rules, so results are reproducible run-to-run.

## Scope — read this first

This stack migrated from Docker Compose to **k3s + ArgoCD** (Jun 2026). The audit was
rewritten accordingly. Its job is now narrow and deliberate:

**The audit covers CONFIG/SIZING quality that has no continuous metric** — things that are
only wrong "at rest" and are surfaced by inspecting desired/observed state at a point in
time. **Runtime failure classes are continuous Grafana → ntfy alarms, NOT audit checks.**
They were intentionally *removed* from the audit because an alarm that fires the moment a
thing breaks strictly dominates a check you have to remember to run.

| Failure class | Where it lives now |
|---|---|
| Container crash-looping | alarm `pod-crashlooping` |
| Container OOMKilled | alarm `pod-oomkilled` |
| Node filesystem >85% | alarm `node-disk-full` |
| Scrape target down | alarm `scrape-target-down` |
| Pod not Ready / Pending / ImagePullBackOff | alarm `pod-not-ready` |
| TLS cert expiring <14d | alarm `cert-expiring-soon` |
| ArgoCD app OutOfSync / Degraded | alarms `argocd-out-of-sync`, `argocd-degraded` |

All alarm rules: `gitops/manifests/observability/alerts/platform-alerts.yaml`.
Scrape config feeding them: `gitops/manifests/observability/servicemonitors/`
(kube-state-metrics, cert-manager, argocd, traefik). If you're tempted to add a runtime
check here, add an alarm instead — and if the metric isn't scraped, add a ServiceMonitor.

## How to invoke

```bash
bash /opt/docker/.claude/skills/stack-audit/audit.sh            # quick (default) + live alert posture
bash /opt/docker/.claude/skills/stack-audit/audit.sh --deep     # larger per-check timeout
bash /opt/docker/.claude/skills/stack-audit/audit.sh --json     # machine-readable (no posture section)
bash /opt/docker/.claude/skills/stack-audit/audit.sh --summary  # one-line severity counts
bash /opt/docker/.claude/skills/stack-audit/audit.sh --no-alerts # suppress posture (pure deterministic, CI)
bash /opt/docker/.claude/skills/stack-audit/audit.sh --only=01-resource-allocation
```

**The deterministic punch list is the report; present it as-is.** If a finding looks
wrong, **fix the check script** so the next run is right — don't override it case-by-case
in your response.

**The default run also appends a live `## 📟 Runtime alert posture` section** below the
punch list (Grafana firing-now + fired-in-last-7d). This part is deliberately LIVE, not
deterministic — it reports the existing alarms' state (it does NOT re-evaluate runtime
conditions, which would duplicate the alarms). The high-value half is the firing history:
ntfy.sh's free tier retains none, so auto-resolved firings are otherwise invisible. It is
read-only via a least-privilege Grafana Viewer token (SealedSecret
`observability/stack-audit-grafana-token`) over an in-cluster port-forward (Grafana sits
behind Authelia 2FA at the edge), and graceful-skips with a note if unreachable. Pass
`--no-alerts` for byte-reproducible, credential-free output (CI / diffing). The punch list
itself is unaffected by this section either way — see below.

Reproducibility mechanics (`audit.sh` / `thresholds.sh`):
- **Stable ordering** — findings `LC_ALL=C sort`ed before render; `kubectl` output order
  (pods reshuffle on recreate) never reorders the punch list. Two `--no-alerts` audits of an
  unchanged cluster diff to nothing but the timestamp header. (The default run's appended
  alert-posture section is live and intentionally varies; it sits below the punch list and
  changes nothing above it.)
- **Bounded completion** — every check wrapped in `timeout CHECK_TIMEOUT_SECS` (default 20,
  60 in `--deep`). A check that exceeds it is killed and replaced by a visible
  `LOW|audit/<check>|...` marker, so a hung api-server can't wedge the run.
- **No false-clean** — every cluster-reading check probes `/healthz`
  (`kubectl get --raw='/healthz' --request-timeout=5s`) before iterating; an unreachable
  cluster or absent `kubectl` yields an explicit `LOW|audit/<check>|… INCONCLUSIVE (not
  clean)` marker instead of an empty pipe that renders identical to a healthy result.
  Likewise 07 emits a per-probe `… UNKNOWN` marker on each individual curl/DNS failure
  (not just when *all* probes fail). So an empty severity bucket provably means "checked
  and clean," never "couldn't check" — the output no longer flips green with cluster/network
  reachability. (Before Jun 2026: 02/03/04/05 swallowed unreachable-cluster errors with
  `2>/dev/null` → zero findings → byte-identical to healthy. Found by the 10-lens analysis.)

Each check in `checks/` is independent and emits:

```
SEVERITY|DOMAIN|FINDING|FIX_COMMAND      # SEVERITY ∈ {CRIT,HIGH,MED,LOW,OK}
```

## What's checked

### 01-resource-allocation.sh — the centerpiece
Single **swapless** k3s node, so memory is the scarce, non-compressible resource: if pods
burst toward their limits at once the node OOMs. Reports the sizing problems that are NOT
alarm-shaped (over-provisioning never "fires"; the OOM consequence is already alarmed):
- **memory-limit overcommit** — `sum(limits) / node allocatable`. HIGH ≥200%, CRIT ≥250%.
  (Node-wide: every namespace contributes to OOM risk.)
- **oversized limits** — limit ≥ `MEM_LIMIT_OVERSIZE_RATIO`× live usage and ≥ floor →
  reclaimable headroom that's inflating the overcommit number.
- **under-requested** — live usage ≥ `MEM_REQUEST_UNDER_RATIO`× request → the scheduler
  undercounts real demand (e.g. a pod requesting 1Gi but using 2.3Gi).
- **missing requests / limits** — best-effort/unbounded containers on a shared node.

Sizing findings are scoped to `RESOURCE_OWNED_NAMESPACES` (default `apps observability`) —
flagging third-party Helm installs (argocd, cert-manager, kube-system) is un-actionable
noise. Overcommit is the one node-wide signal. For usage, prefers **VM peak**
(`max_over_time(k8s.pod.memory.working_set[VM_PEAK_WINDOW])`, default 30d) over
instantaneous `kubectl top` — spiky pods idle low between bursts, so `top` under-reports
and the sizing checks false-positive. VM is reached via the apiserver service-proxy (works
wherever kubectl does). Falls back to `kubectl top`, then to overcommit-only, if VM is
unreachable. Peak is aggregated by **workload**, not per pod, so a spike on a pod that has
since been replaced still counts: the node collector's k8sattributes processor stamps
`k8s.deployment.name`, and the check folds historical samples onto the same workload key by
pod-name derivation until the label fills the window. (This closed the zilean rollover
blind-spot — an ~800Mi import burst on a since-replaced pod that a per-pod peak missed.) Set
`USE_VM_PEAK=0` to revert to instantaneous top.

### 02-image-pins.sh
This stack pins images by `@sha256` digest so a restart can't silently pull a breaking
change (the crashloop alarm catches that *after* the fact; this is the *before*). Flags
running containers (owned namespaces) whose image has **no digest**: MED for `:latest` /
no-tag (genuinely mutable), LOW for a version tag without a digest.

### 03-probes.sh
Without a `readinessProbe`, a Service routes to a pod the instant its process starts —
before it can serve — and keeps routing to a wedged-but-running pod (the paperless
`ALLOWED_HOSTS` class: up, but every request 4xx/5xxs). The `pod-not-ready` alarm only
fires if a probe *exists* to report not-ready, so probe presence itself stays an audit
check. LOW (some trivial sidecars legitimately don't need one).

### 04-pvc-reclaim.sh
The ADR's #1 failure mode is silent disk-fill on Delete-reclaim local-path PVCs; on a
single node a Delete-reclaim volume is also a data-loss trap (delete/prune the PVC → data
gone). The operator mitigated this with a custom `local-path-retain` StorageClass for DB
volumes, but the **default** `local-path` SC is still Delete. Reads each bound PV's actual
reclaim policy (what governs data fate) and flags `Delete`; also flags any PVC stuck
unbound (HIGH). Healthy state = silent.

### 05-securitycontext.sh
Pod securityContext hardening. Calibrated to avoid noise: genuine escape/root risks are
flagged per-container at **HIGH** (`privileged: true`, `hostNetwork/PID/IPC`, explicit
`runAsUser: 0`) / **MED** (escape-grade added caps — `SYS_ADMIN`, `NET_RAW`, … —
allowlisted per container via `SECCTX_ADDED_CAPS_ALLOW`, default `gluetun` for its VPN
tunnel); the broad baseline gap (most images run with the default context) is reported as
a few **aggregate LOW** lines per namespace (`N/M containers don't enforce runAsNonRoot /
drop ALL caps / set allowPrivilegeEscalation=false`) rather than ~70 per-container lines
that would drown the signal. Remediating the baseline is per-image work (some break as
non-root), hence LOW not a per-container nag.

### 06-alert-delivery.sh — silent notification breakage
Static, reads `$GITOPS_DIR`, not the cluster. The failure it guards is **alerts that fire
but never arrive**: the component that would page you about a broken notifier *is* the
notifier, so no metric catches it — it only surfaces as an ERROR buried in Grafana's log.
The concrete trap (Jun 2026): Grafana's **embedded** gomplate rejects the two-variable
range `{{ range $i, $a := .Alerts }}` inside `tmpl.Inline` with `unexpected ',' in range`,
so every notification through that contact point was dropped and retried-then-discarded
every 5m. (Standalone gomplate accepts it; the bundled one does not.) Flags any two-var
range in a file that defines a gomplate contact-point template (`tmpl.Inline`) at **HIGH**;
the fix is single-var range over a stdlib `slice`. Skips YAML comment lines so a warning
comment isn't self-flagged. Healthy state = silent.

### 07-public-endpoints.sh — client endpoint hidden behind SSO
Behavioral probe (needs `curl` + network; degrades to one LOW if offline). Some services
serve **non-browser clients** (Stremio addons, plain APIs) whose entrypoints must stay
reachable without an interactive Authelia session. When a forward-auth middleware
over-matches and swallows such a path, the service stays Running/Ready and every dashboard
is green — but the client gets a 302 to the login portal (HTML) instead of its payload
(the paperless-`ALLOWED_HOSTS` class: up, but every real request fails). Jun 2026:
aiostreams `/api/v1/debrid/playback` got gated → players received the login page →
"unrecognized format". Each `$PUBLIC_ENDPOINT_PROBES` entry is hit with a
**bogus-but-prefix-matching path** so it tests the *routing decision* (is auth applied to
this prefix?) without a valid signed URL; a redirect to `$AUTH_PORTAL_HOST` is flagged
**HIGH**. Could graduate to a blackbox-exporter alarm once one exists.

### 08-hostpath-durability.sh — the data-loss gap 04 can't see
04 is PVC-scoped, but the *largest irreplaceable data* on this stack lives on raw
**hostPath** dirs (immich library, prowlarr/bitmagnet/calibre/stremthru DBs) — no PV
lifecycle, no reclaim policy, no StorageClass guard. An ArgoCD prune or a renamed path
orphans the bytes silently and nothing PVC-shaped notices. Lists each distinct hostPath
dir backing a Running owned workload (**MED** — "confirm it's in the off-node backup set"),
skipping system mounts via `HOSTPATH_ALLOW` (the node collector's read-only `/var/log/pods`
etc. are not data). Cross-checks `HOSTPATH_CRITICAL` (the RESTORE.md set): a critical path
**not** mounted by any Running pod is the silent-orphan case → **HIGH**. Ships with the MED
inventory always present (the hostPath dirs are real) and no HIGH while nothing has drifted.

### 09-netpol-db-coverage.sh — fail-open NetworkPolicy drift
`apps-allow-trusted-cross-ns` lets observability/kube-system reach apps pods *except* a
hand-maintained `NotIn` list of DB pods. That list **fails open**: a new `*-postgres` /
`*-redis` added without editing the policy is silently reachable cross-namespace. The
manifest itself requests this check. Derives DB pods by `app` label
(`NETPOL_DB_LABEL_PATTERN`), compares against the policy's live `NotIn` values, and flags
any uncovered DB pod **HIGH**. A pure **drift detector** — ships green when every DB pod is
excluded (the healthy steady state).

### 10-cpu-allocation.sh — CPU sizing (companion to 01)
01 is memory-only because memory is the non-compressible scarce resource. CPU is
**compressible** — over-limit means CFS throttling (latency), not an OOM kill — and the
throttle metric isn't scraped, so "limit set too low vs sustained 30d-peak demand" is a
sizing-at-rest fact that lands in neither the audit nor an alarm. Uses the **same VM peak
path as 01** but on `k8s.pod.cpu.usage` (an OTLP utilization gauge in **cores** →
`max_over_time` directly, no `rate()`). Reports: node-wide CPU-limit overcommit (LOW-info,
only above `CPU_LIMIT_OVERCOMMIT_PCT_INFO`=1500% — a high ratio is normal for compressible
CPU); **under-limited** workloads two-tier by what the 30d-MAX gauge proves — a reading
**≥100%** of limit means throttling demonstrably occurred at peak (**MED**), **90–100%** is
riding close and may throttle on an unsampled burst (**LOW**); and missing CPU
request/limit (LOW). No HIGH — the worst case is latency, never an outage. Falls back to
overcommit+missing only if VM is unreachable (an instantaneous core reading is meaningless
for sizing, so there's no `kubectl top` fallback). *Shipped from the evolve run's CPU
experiment: 2 MED + 4 LOW on the live cluster — actionable, not noise.*

### 01/05 extensions (Jun 2026)
- **01** now emits a per-namespace **QoS line** (`resource/qos`, LOW): every owned pod is
  `Burstable`, so under the memory overcommit the kernel OOM-ranks them by
  usage-over-request — which makes finding 3 ("raise request") concretely about OOM
  survival rank, not abstract sizing.
- **05** gained two aggregate-LOW baselines matching the existing `runAsNonRoot`/`drop-ALL`
  pattern: **`seccompProfile`** (RuntimeDefault, container- or pod-level) and
  **`readOnlyRootFilesystem`**. These turn 05 into a same-run drift detector for the two
  restricted-PSS controls it previously ignored.

## Thresholds (`thresholds.sh`)

| Threshold | Default | Used by |
|---|---|---|
| `RESOURCE_OWNED_NAMESPACES` | `apps observability` | sizing/probe/image scope |
| `MEM_LIMIT_OVERCOMMIT_PCT_WARN` | 200 | overcommit HIGH (raised 150→200 Jun 2026; see thresholds.sh) |
| `MEM_LIMIT_OVERCOMMIT_PCT_CRIT` | 250 | overcommit CRIT |
| `MEM_LIMIT_OVERSIZE_RATIO` | 8 | oversized limit |
| `MEM_LIMIT_OVERSIZE_FLOOR_MI` | 1024 | oversized limit floor |
| `MEM_REQUEST_UNDER_RATIO` | 1.5 | under-request |
| `MEM_REQUEST_UNDER_FLOOR_MI` | 256 | under-request floor |
| `CHECK_TIMEOUT_SECS` / `_DEEP` | 20 / 60 | per-check budget |
| `IMAGE_PIN_SKIP_CONTAINERS` | `linkerd-proxy linkerd-init` | mesh-injected sidecars skipped by 02 (not manifest-controlled) |
| `GITOPS_DIR` | `/opt/docker/gitops` | desired-state tree for 06 |
| `AUTH_PORTAL_HOST` | `auth.my-blue-car.work` | 07 gating discriminator |
| `PUBLIC_ENDPOINT_PROBES` | aiostreams playback, comet manifest | 07 must-be-public probe list |
| `PUBLIC_ENDPOINT_PROBE_TIMEOUT` | 10 | 07 per-probe curl timeout (s) |
| `HOSTPATH_ALLOW` | `^/var/(log\|lib)/\|^/run/\|…` | 08 system-mount skip regex (not data) |
| `HOSTPATH_CRITICAL` | prowlarr/bitmagnet/immich/calibre/stremthru | 08 RESTORE.md drift set (HIGH if unmounted) |
| `NETPOL_DB_NAME` | `apps-allow-trusted-cross-ns` | 09 policy whose NotIn list is checked |
| `NETPOL_DB_LABEL_PATTERN` | `postgres\|redis\|valkey\|…` | 09 DB-pod `app`-label matcher |
| `CPU_LIMIT_OVERCOMMIT_PCT_INFO` | 1500 | 10 CPU-overcommit LOW-info gate |
| `CPU_UNDERLIMIT_PEAK_RATIO` | 0.9 | 10 under-limit trigger (peak ≥ ratio×limit) |
| `CPU_UNDERLIMIT_MAX_LIMIT_M` | 2000 | 10 only flag limits below this (millicores) |

Override any of them inline: `MEM_LIMIT_OVERCOMMIT_PCT_WARN=120 bash audit.sh`.

## Severity rules
- **CRIT** — data-loss risk, or memory overcommit that can OOM the whole node.
- **HIGH** — workload can't run (unbound PVC), or near-OOM node overcommit.
- **MED** — mis-sized requests/limits, missing limits, `:latest` images, Delete-reclaim PVC.
- **LOW** — version-tag-no-digest, missing readinessProbe, informational.

## Suppression
Add a regex per line to `.audit-ignore` (matched against the raw `SEVERITY|DOMAIN|FINDING`
line) to mute known-acceptable findings — e.g. the observability operators' un-pinnable
sidecar images.

## Extending the audit
Drop a new `NN-name.sh` into `checks/`. It must source `../thresholds.sh`, degrade
gracefully when `kubectl` is absent/unreachable (emit a single `LOW|audit/...` and exit 0),
and emit `SEVERITY|DOMAIN|FINDING|FIX_COMMAND` lines. Keep it deterministic: no wall-clock
in the finding text, sort any list you iterate. **Before adding a runtime/metric check, ask
whether it should be a Grafana alarm instead** (see Scope) — the audit is for state that
has no time series.

## Design rationale
1. **One namespace-aware check per concern**, severity = measurement vs threshold, not LLM
   judgement.
2. **Alarms own runtime; the audit owns config/sizing.** No overlap, by construction.
3. **Actionable-only.** Findings scoped to manifests the operator can actually edit;
   un-fixable third-party noise is excluded or suppressible.
