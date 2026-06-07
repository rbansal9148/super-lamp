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
bash /opt/docker/.claude/skills/stack-audit/audit.sh            # quick (default)
bash /opt/docker/.claude/skills/stack-audit/audit.sh --deep     # larger per-check timeout
bash /opt/docker/.claude/skills/stack-audit/audit.sh --json     # machine-readable
bash /opt/docker/.claude/skills/stack-audit/audit.sh --summary  # one-line severity counts
bash /opt/docker/.claude/skills/stack-audit/audit.sh --only=01-resource-allocation
```

**Default path is purely deterministic.** Run `bash audit.sh`, present the output as-is.
If a finding looks wrong, **fix the check script** so the next run is right — don't
override it case-by-case in your response.

Reproducibility mechanics (`audit.sh` / `thresholds.sh`):
- **Stable ordering** — findings `LC_ALL=C sort`ed before render; `kubectl` output order
  (pods reshuffle on recreate) never reorders the punch list. Two audits of an unchanged
  cluster diff to nothing but the timestamp header.
- **Bounded completion** — every check wrapped in `timeout CHECK_TIMEOUT_SECS` (default 20,
  60 in `--deep`). A check that exceeds it is killed and replaced by a visible
  `LOW|audit/<check>|...` marker, so a hung api-server can't wedge the run.

Each check in `checks/` is independent and emits:

```
SEVERITY|DOMAIN|FINDING|FIX_COMMAND      # SEVERITY ∈ {CRIT,HIGH,MED,LOW,OK}
```

## What's checked

### 01-resource-allocation.sh — the centerpiece
Single **swapless** k3s node, so memory is the scarce, non-compressible resource: if pods
burst toward their limits at once the node OOMs. Reports the sizing problems that are NOT
alarm-shaped (over-provisioning never "fires"; the OOM consequence is already alarmed):
- **memory-limit overcommit** — `sum(limits) / node allocatable`. HIGH ≥150%, CRIT ≥250%.
  (Node-wide: every namespace contributes to OOM risk.)
- **oversized limits** — limit ≥ `MEM_LIMIT_OVERSIZE_RATIO`× live usage and ≥ floor →
  reclaimable headroom that's inflating the overcommit number.
- **under-requested** — live usage ≥ `MEM_REQUEST_UNDER_RATIO`× request → the scheduler
  undercounts real demand (e.g. a pod requesting 1Gi but using 2.3Gi).
- **missing requests / limits** — best-effort/unbounded containers on a shared node.

Sizing findings are scoped to `RESOURCE_OWNED_NAMESPACES` (default `apps observability`) —
flagging third-party Helm installs (argocd, cert-manager, kube-system) is un-actionable
noise. Overcommit is the one node-wide signal. Uses `kubectl top` for live usage; if
metrics-server is down it skips the usage-relative findings (still reports overcommit).

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

## Thresholds (`thresholds.sh`)

| Threshold | Default | Used by |
|---|---|---|
| `RESOURCE_OWNED_NAMESPACES` | `apps observability` | sizing/probe/image scope |
| `MEM_LIMIT_OVERCOMMIT_PCT_WARN` | 150 | overcommit HIGH |
| `MEM_LIMIT_OVERCOMMIT_PCT_CRIT` | 250 | overcommit CRIT |
| `MEM_LIMIT_OVERSIZE_RATIO` | 8 | oversized limit |
| `MEM_LIMIT_OVERSIZE_FLOOR_MI` | 1024 | oversized limit floor |
| `MEM_REQUEST_UNDER_RATIO` | 1.5 | under-request |
| `MEM_REQUEST_UNDER_FLOOR_MI` | 256 | under-request floor |
| `CHECK_TIMEOUT_SECS` / `_DEEP` | 20 / 60 | per-check budget |

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
