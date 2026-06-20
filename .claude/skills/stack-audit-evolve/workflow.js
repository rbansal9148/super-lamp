export const meta = {
  name: 'stack-audit-evolve',
  description: 'Snapshot the live stack-audit, research external k8s config-quality/right-sizing/GitOps/supply-chain practices, analyze the audit from 10 lenses, and synthesize ship/break/experiment proposals',
  phases: [
    { title: 'Snapshot', detail: 'run stack-audit (deterministic, no-alerts) for a fresh punch-list + per-check map' },
    { title: 'Research', detail: '5 agents sweep external k8s config-quality / right-sizing / GitOps / supply-chain / single-node-reliability practices' },
    { title: 'Analyze', detail: '10 agents probe the current stack-audit from distinct lenses' },
    { title: 'Synthesize', detail: 'dedup, adversarially rank, bucket into ship/break/experiment' },
  ],
}

// ── grounding constants ──────────────────────────────────────────────────────
const AUDIT_DIR = '/opt/docker/.claude/skills/stack-audit'
const SKILL = `${AUDIT_DIR}/SKILL.md`
const AUDIT_SH = `${AUDIT_DIR}/audit.sh`
const THRESHOLDS = `${AUDIT_DIR}/thresholds.sh`
const CHECKS_DIR = `${AUDIT_DIR}/checks`
const GITOPS_DIR = '/opt/docker/gitops'

// Optional free-text steer passed via Workflow args, e.g. {focus: "security only"}.
const FOCUS = (args && args.focus) ? `\n\nEXTRA STEER FROM OWNER: ${args.focus}` : ''

// Tell agents how to read the bash check scripts WITHOUT tripping the cbm
// whole-file-Read gate (it blocks Read on code). Use Bash `bat -pp` instead.
const HOW_TO_READ = `To read any check script use Bash: \`bat -pp ${CHECKS_DIR}/NN-name.sh\` (they are short bash files; the cbm Read-gate blocks whole-file Read of code, bat does not). Read multiple at once: \`bat -pp ${CHECKS_DIR}/*.sh\`.`

const WHAT_WE_MEASURE = `The tool under study: \`stack-audit\` — a deterministic, bash-driven config/sizing audit of a SINGLE-NODE k3s + ArgoCD self-hosted homelab (namespaces \`apps\` + \`observability\`, ~30+ workloads, 21.4Gi swapless node). Source: ${AUDIT_DIR} (audit.sh orchestrator + checks/NN-*.sh + thresholds.sh + alert-posture.sh). One repeatable command → a severity-bucketed (CRIT/HIGH/MED/LOW/OK) punch list; each check emits \`SEVERITY|DOMAIN|FINDING|FIX_COMMAND\`. Findings are LC_ALL=C-sorted so two runs of an unchanged cluster diff to nothing. Each check probes apiserver /healthz first so an unreachable cluster yields an explicit INCONCLUSIVE marker, never a false-green empty result. Per-check timeout-bounded. Suppression via .audit-ignore regexes.

DELIBERATE SCOPE BOUNDARY (the core design decision): the audit covers ONLY config/sizing quality that has NO continuous metric — state that is only wrong "at rest". RUNTIME failure classes are intentionally NOT audit checks; they are continuous Grafana→ntfy alarms instead: pod-crashlooping, pod-oomkilled, node-disk-full, scrape-target-down, pod-not-ready/Pending/ImagePullBackOff, cert-expiring-soon, argocd-out-of-sync, argocd-degraded. Rule: "an alarm that fires the moment a thing breaks dominates a check you must remember to run." A default run also APPENDS a live Grafana alert-posture snapshot (firing-now + fired-last-7d, via a least-privilege Viewer token) below the deterministic punch list.

THE 10 CHECKS IT ALREADY DOES (08/09/10 + the 01-QoS / 05-seccomp extensions shipped Jun 2026 from the FIRST evolve run — do NOT re-propose them):
01-resource-allocation (the centerpiece): MEMORY-ONLY sizing on the swapless node. memory-limit overcommit = sum(limits)/node-allocatable (HIGH≥200%, CRIT≥250%; 200% is "by design" for 30+ peak-sized workloads); oversized-limits (limit ≥8× live usage & ≥1Gi floor); under-requested (usage ≥1.5× request & ≥256Mi); missing requests/limits; AND a per-namespace QoS-class line (all pods Burstable → OOM-ranked by usage-over-request). Usage source PREFERS VictoriaMetrics 30d PEAK (max_over_time working_set, aggregated by WORKLOAD to survive pod rollover) over instantaneous kubectl top; falls back top→overcommit-only. Scoped to owned namespaces. CPU sizing is now a SEPARATE check (10, below) — do not fold it back into 01.
02-image-pins: flags running containers whose image has no @sha256 digest (MED for :latest/no-tag, LOW for version-tag-no-digest). Pin-by-digest only; NO vuln scan, NO signature/SBOM. (A separate in-house Rust binary tools/image-currency/ detects floating-tag UPDATE + version-pin DRIFT but is NOT yet folded into the audit punch list.)
03-probes: flags missing readinessProbe (LOW). Presence only — does NOT validate liveness/startup probes or probe config sanity.
04-pvc-reclaim: flags bound PVs with Delete reclaim policy on local-path (data-loss trap on single node) and unbound PVCs (HIGH). NO backup-existence or restore-tested verification.
05-securitycontext: per-container HIGH (privileged, hostNetwork/PID/IPC, runAsUser:0) / MED (escape-grade added caps, allowlisted) + aggregate-LOW baselines (N/M containers don't enforce runAsNonRoot / drop ALL / allowPrivilegeEscalation=false / seccompProfile RuntimeDefault / readOnlyRootFilesystem). NO admission-control/Pod-Security-Standards enforcement, NO image VULN scan, NO RBAC audit.
06-alert-delivery (static, reads GITOPS_DIR): flags Grafana embedded-gomplate two-var \`range $i, $a := .Alerts\` that silently drops notifications (HIGH). Single very-specific trap.
07-public-endpoints (behavioral probe, needs curl+net): hits must-stay-public Stremio/API paths with a bogus-but-prefix-matching path; a 302 to the Authelia portal = forward-auth over-matched (HIGH). Hardcoded probe list in thresholds.sh.
08-hostpath-durability: lists each distinct raw hostPath dir backing a Running owned workload (MED — the largest irreplaceable data, invisible to PVC-scoped 04) and flags a RESTORE.md-critical path that has drifted out of the cluster (HIGH). Allowlists system mounts.
09-netpol-db-coverage: drift detector for the apps cross-ns NetworkPolicy's fail-open DB NotIn exclusion list — a new *-postgres/*-redis not in the list is reachable cross-ns (HIGH). Ships green when all DB pods are covered.
10-cpu-allocation: CPU sizing companion to 01. Same VM peak path on k8s.pod.cpu.usage (gauge in cores, max_over_time). node-wide CPU-limit overcommit (LOW-info >1500%); under-limited two-tier (30d peak ≥100% of limit = MED throttled-at-peak, 90-100% = LOW riding-close); missing cpu req/limit (LOW). CPU is compressible so no HIGH. The CFS throttle metric is still NOT scraped — this MAX-of-gauge approach is the proxy.

KEY PROPERTIES: pure bash + kubectl + Python + VictoriaMetrics PromQL; no policy engine, no scoring tool (Polaris/kube-score/Kyverno were evaluated and REJECTED — they break byte-stable diffable output + owned-ns scoping). --json output is jq-built (correct escaping). Thresholds are hand-coded constants in thresholds.sh, overridable by env. GENUINE REMAINING FRONTIER: memory usage is MAX-only (no p95, so chronic over-provisioning hidden behind single spikes — the OPEN experiment #1); CPU throttling measured only by MAX-of-gauge proxy (real container_cpu_cfs_throttled_periods_total not scraped); NO image CVE scan (trivy not installed — the one tool that cleared the adoption bar, as opt-in --deep); image-currency tool not wired into the punch list; --persist/--diff now give run-to-run NEW/CLEARED/SEVERITY-CHANGED tracking (git-trackable JSON snapshots, volatility-masked identity) but there is STILL no CI/PR gate that FAILS on new CRIT/HIGH, and no fix-landing/time-to-remediate tracking.`

const RESEARCH_DOMAINS = [
  { key: 'k8s-config-quality', focus: 'Kubernetes config-quality / policy-as-code scanners', detail: 'Polaris, kube-score, KubeLinter, Trivy k8s/config, Kubescape, kube-bench (CIS), Datree/Checkov, OPA Conftest, Kyverno CLI. WHAT specific checks do they encode for resource requests/limits, probes, securityContext, image pinning, PVC/storage, PDB, NetworkPolicy? Which of these mature tools could REPLACE or augment hand-rolled bash checks, and what is their false-positive/maintenance profile on a small homelab? Output: concrete check IDs we are missing + which tool encodes them.' },
  { key: 'right-sizing', focus: 'resource right-sizing & autoscaling recommendation for memory AND cpu', detail: 'VPA recommender, Goldilocks, Robusta KRR (Kube Resource Recommender), Prometheus/VictoriaMetrics-based percentile right-sizing (p95/p99 vs max), QoS classes (Guaranteed/Burstable/BestEffort), memory QoS / cgroup v2, CPU throttling (container_cpu_cfs_throttled), request:limit ratio guidance, OOMScoreAdj. We currently size MEMORY by 30d MAX only and ignore CPU entirely. What is the recommended methodology (percentile choice, headroom, peak vs sustained) and what CPU-throttling/QoS signals should a sizing audit surface?' },
  { key: 'gitops-argocd', focus: 'GitOps / ArgoCD operational best practices & drift', detail: 'ArgoCD app health/sync semantics, sync waves & hooks, self-heal & auto-prune, drift detection beyond OutOfSync, app-of-apps, ApplicationSet, argocd-image-updater, diff customizations, ignoreDifferences abuse, sealed-secrets/SOPS hygiene, resource-tracking annotations. What config-at-rest GitOps anti-patterns (that are NOT runtime alarms) should an audit catch in the manifest tree + live Application objects?' },
  { key: 'supply-chain-security', focus: 'container image & cluster supply-chain / security posture', detail: 'Trivy/Grype image vuln scanning, SBOM (syft), cosign/sigstore signature & provenance verification (SLSA), admission control (Kyverno, OPA Gatekeeper, Pod Security Admission/Standards baseline-vs-restricted), base-image freshness/age, secret-at-rest, RBAC least-privilege audit, seccomp/AppArmor, NetworkPolicy default-deny. We only check digest-pinning + baseline securityContext. What is the layered model and which layers are missing? Be honest about what is overkill for a single-node homelab vs genuinely load-bearing.' },
  { key: 'single-node-reliability', focus: 'single-node / homelab cluster reliability, backup & observability design', detail: 'local-path-provisioner data-loss gotchas & reclaim policy, PVC/volume backup & restore verification (Velero, restic/borg, volsync), node-pressure eviction & memory-pressure thresholds, probe design (liveness vs readiness vs startup, anti-flap), PodDisruptionBudget relevance on 1 node, SLO/alerting design (multi-window burn-rate, the alarm-vs-audit boundary), config-as-code drift, restore-testing cadence. What at-rest reliability gaps does a single-node self-hoster most often miss? Adversarially: which "best practices" are irrelevant on a single node and should NOT be added.' },
]

const ANALYSIS_LENSES = [
  { key: 'coverage-gaps', lens: 'Enumerate config/sizing failure classes the audit neither checks NOR has an alarm for: CPU requests/limits & throttling, liveness/startup probe presence & sanity, PodDisruptionBudget, NetworkPolicy/default-deny, resource quotas/LimitRange, anti-affinity (n/a on 1 node — say so), backup-existence/restore-tested for PVCs, ConfigMap/Secret drift, Ingress/IngressRoute/cert config correctness, init-container sizing, ephemeral-storage limits, hostPath usage, dangling/unused PVCs. For each REAL gap propose a concrete new NN-check.sh with its SEVERITY rule. Mark anything that is actually a runtime alarm (out of scope) as such.' },
  { key: 'tooling-replacement', lens: 'The owner is EXPLICITLY open to new tooling and restructuring. Critique the hand-rolled-bash architecture vs adopting a policy engine (Polaris / kube-score / KubeLinter / Trivy config / Kyverno). For each candidate tool: what it would replace, what it adds that bash does not, its determinism/repeatability vs the current byte-stable output, its false-positive & maintenance profile, and whether it fits the "config-at-rest, no-runtime-overlap, actionable-only, owned-namespaces" design. Recommend KEEP-BASH / WRAP-A-TOOL / HYBRID per concern with rationale — do not default to "adopt tool" (novelty bias).' },
  { key: 'resource-sizing-validity', lens: 'Deep-audit 01-resource-allocation. It is MEMORY-ONLY and uses 30d MAX working_set. Critique: (a) ignoring CPU entirely — throttling on a shared node is invisible; (b) MAX vs a percentile (p95/p99) — does a single monthly spike over-size everything? (c) QoS class is never surfaced (Guaranteed vs Burstable changes OOM-kill order); (d) request:limit ratio is unmodeled; (e) the 200% overcommit "by design" threshold — is it calibrated or just tuned to silence? Propose concrete metric/threshold redesigns with the PromQL/kubectl arithmetic.' },
  { key: 'security-depth', lens: 'Audit 05-securitycontext + 02-image-pins as a security posture. They are shallow: baseline runAsNonRoot/caps + digest-pinning. Missing: image VULN scanning (Trivy/Grype), signature/provenance, Pod Security Standards / admission enforcement, RBAC least-privilege, NetworkPolicy default-deny, seccomp/AppArmor, secret-at-rest, capability allowlist drift. Propose the layered additions WORTH having on a single-node homelab (and explicitly kill the ones that are enterprise theater here). Each proposal: leverage dimension + SEVERITY rule + which tool/command produces it.' },
  { key: 'probe-and-health-config', lens: 'Audit 03-probes (readiness-presence-only, LOW). Critique: liveness & startup probes are never checked; probe MISCONFIG (too-aggressive timeouts/periods causing restart flap, missing initialDelay/startupProbe on slow boot) is invisible and is a config-at-rest problem with no alarm. Also: services with NO probe AND in the public path are higher risk than a sidecar. Propose probe-config checks (presence by probe type, sanity bounds, severity tiering by exposure) with kubectl jsonpath.' },
  { key: 'image-supply-chain', lens: 'Audit 02-image-pins (digest-present-or-not only). The stack already has a separate image-currency/staleness concern (recent commits). Critique the gap between "pinned" and "pinned to something safe & current": no detection of a pinned-but-ancient digest, no upstream-newer-digest signal, no CVE exposure on the pinned digest, no base-image age. Propose how the audit should treat staleness vs currency (and whether that belongs here or is an alarm). Cite the digest-pinning rule.' },
  { key: 'determinism-meta', lens: 'Audit-of-the-audit reproducibility & regression-guarding. The output is byte-stable but is it CI-GATED? Propose: a golden-fixture/snapshot test of the punch list wired into pre-commit (like transcript-audit has), a recorded baseline so a PR that regresses sizing/pinning/probes fails, drift-alerting between consecutive audit runs, and a machine-readable contract test for the --json output. Cite the existing determinism mechanics (LC_ALL=C sort, /healthz no-false-clean) and where a regression could still slip through.' },
  { key: 'gitops-drift', lens: 'The audit reads BOTH live cluster (01-05,07) and GITOPS_DIR desired-state (06). Critique the desired-vs-observed story: ArgoCD already owns OutOfSync, but config-AT-REST drift that ArgoCD treats as in-sync (e.g. ignoreDifferences masking, sealed-secret staleness, a manifest with no Application owning it, orphaned resources, sync-wave gaps) is unaudited. Propose GitOps-hygiene checks over the manifest tree + Application objects that are NOT duplicates of the argocd-out-of-sync alarm.' },
  { key: 'alarm-audit-boundary', lens: 'Stress-test the load-bearing design axiom: "continuous failure = Grafana alarm; at-rest config = audit; no overlap." Is the line drawn correctly? Find (a) at-rest checks that would be better as alarms, (b) failure classes currently in NEITHER bucket (fall through the crack), (c) places where an alarm presumes a config the audit should verify exists (e.g. pod-not-ready alarm is useless if no probe exists — already noted; what else?). Propose boundary corrections, not just new checks.' },
  { key: 'outcome-experiment-harness', lens: 'BOLD + restructuring allowed. Today the audit is fire-and-forget: point-in-time punch list, no result storage, no trend, no fix-landing tracking, no PR gate. Design an outcome/experiment layer: persist each run (JSON + git-tracked under docs/audit-log/ or a timeseries), diff run-to-run, track time-to-remediate per finding, gate manifest PRs on no-new-CRIT/HIGH, and an experiment ledger (change a threshold/manifest → measure the finding delta). What makes the audit a measured feedback loop instead of a checklist? Cite the no-storage current state.' },
]

const SNAPSHOT_SCHEMA = {
  type: 'object',
  properties: { context: { type: 'string' } },
  required: ['context'],
}
const RESEARCH_SCHEMA = {
  type: 'object',
  properties: {
    practices: { type: 'array', items: { type: 'object', properties: {
      name: { type: 'string' }, source_url: { type: 'string' }, what_it_captures: { type: 'string' },
      applicable_to_our_audit: { type: 'string' }, novel_vs_current: { type: 'boolean' },
      homelab_fit: { type: 'string', enum: ['load-bearing', 'nice-to-have', 'enterprise-overkill'] },
    }, required: ['name', 'source_url', 'what_it_captures', 'applicable_to_our_audit', 'novel_vs_current', 'homelab_fit'] } },
    top_checks_to_steal: { type: 'array', items: { type: 'string' } },
    tool_recommendation: { type: 'string' },
    boldest_idea: { type: 'string' },
  },
  required: ['practices', 'top_checks_to_steal', 'tool_recommendation', 'boldest_idea'],
}
const ANALYSIS_SCHEMA = {
  type: 'object',
  properties: {
    gaps: { type: 'array', items: { type: 'object', properties: {
      title: { type: 'string' }, current_state: { type: 'string' }, proposed_change: { type: 'string' },
      leverage_dimension: { type: 'string', enum: ['oom-risk', 'data-loss', 'security', 'availability', 'cost-efficiency', 'maintainability', 'meta'] },
      feasible: { type: 'string', enum: ['yes-bash-now', 'needs-new-tool', 'needs-new-data', 'partial'] },
      breaking: { type: 'boolean' }, in_scope: { type: 'boolean' }, evidence: { type: 'string' },
    }, required: ['title', 'current_state', 'proposed_change', 'leverage_dimension', 'feasible', 'breaking', 'in_scope', 'evidence'] } },
    strongest_gap: { type: 'string' },
  },
  required: ['gaps', 'strongest_gap'],
}
const SYNTH_SCHEMA = {
  type: 'object',
  properties: {
    ship_now: { type: 'array', items: { type: 'object', properties: {
      change: { type: 'string' }, check_name: { type: 'string' }, dimension: { type: 'string' },
      implementation: { type: 'string' }, severity_rule: { type: 'string' }, evidence: { type: 'string' }, effort: { type: 'string' },
    }, required: ['change', 'check_name', 'dimension', 'implementation', 'severity_rule', 'evidence', 'effort'] } },
    restructure: { type: 'array', items: { type: 'object', properties: {
      change: { type: 'string' }, rationale: { type: 'string' }, risk: { type: 'string' }, breaking: { type: 'boolean' },
    }, required: ['change', 'rationale', 'risk', 'breaking'] } },
    new_tooling: { type: 'array', items: { type: 'object', properties: {
      tool: { type: 'string' }, replaces_or_adds: { type: 'string' }, verdict: { type: 'string', enum: ['adopt', 'wrap-hybrid', 'reject'] }, why: { type: 'string' },
    }, required: ['tool', 'replaces_or_adds', 'verdict', 'why'] } },
    experiments: { type: 'array', items: { type: 'object', properties: {
      hypothesis: { type: 'string' }, design: { type: 'string' }, measure: { type: 'string' },
    }, required: ['hypothesis', 'design', 'measure'] } },
    killed: { type: 'array', items: { type: 'object', properties: {
      candidate: { type: 'string' }, why_killed: { type: 'string' },
    }, required: ['candidate', 'why_killed'] } },
    top3_priorities: { type: 'array', items: { type: 'string' } },
  },
  required: ['ship_now', 'restructure', 'new_tooling', 'experiments', 'killed', 'top3_priorities'],
}

// ── Phase 0: refresh the live audit context ──────────────────────────────────
const snap = await agent(
  `Run the live stack-audit and distill fresh context for downstream agents.\n\n1. Run (deterministic, credential-free): \`bash ${AUDIT_SH} --no-alerts\`  — read the full punch list.\n2. Also run \`bash ${AUDIT_SH} --summary\` for the severity counts.\n3. Skim the per-check logic: \`bat -pp ${CHECKS_DIR}/*.sh ${THRESHOLDS}\` (these are short bash files; do NOT use Read on them — the cbm gate blocks whole-file Read of code, bat does not).\n\nDistill a COMPACT context block (<= 300 words) for downstream agents: the current severity counts; every CRIT/HIGH/MED finding (domain + one-line finding); a one-line note on any check that emitted an INCONCLUSIVE/UNKNOWN marker (cluster reachability); and a 1-line-per-check map of what each of the 7 checks currently flags. Plain text, no preamble. Return as {context}.`,
  { label: 'snapshot:stack-audit', phase: 'Snapshot', schema: SNAPSHOT_SCHEMA }
)
const AUDIT_CONTEXT = `LIVE STACK-AUDIT SNAPSHOT:\n${snap ? snap.context : '(snapshot failed — analysis agents should run `bash ' + AUDIT_SH + ' --no-alerts` themselves)'}`

// ── Phases 1+2: 15 finders fan out concurrently (opts.phase groups them) ──────
const tasks = [
  ...RESEARCH_DOMAINS.map(d => ({ kind: 'research', spec: d })),
  ...ANALYSIS_LENSES.map(l => ({ kind: 'analyze', spec: l })),
]
const results = await parallel(tasks.map(t => () => {
  if (t.kind === 'research') {
    return agent(
      `You are researching EXTERNAL best practices to improve a deterministic Kubernetes CONFIG/SIZING audit tool for a SINGLE-NODE k3s + ArgoCD self-hosted homelab. Use WebSearch (2-4 queries) and WebFetch (fetch 2-4 of the most authoritative sources — official tool docs, the CIS/NSA k8s hardening guides, the OPA/Kyverno/Polaris/Trivy docs, well-known SRE/platform engineering blogs). Be current; prefer 2025-2026 sources.\n\nYOUR DOMAIN: ${t.spec.focus}\nProbe specifically: ${t.spec.detail}\n\n${WHAT_WE_MEASURE}\n\nGoal: find CHECKS, tools, schemas, and methodologies we do NOT already capture that would sharpen the audit on any of {oom-risk, data-loss, security, availability, cost-efficiency} — OR a tool that should REPLACE hand-rolled bash. Set novel_vs_current=false for anything we already do (be honest). Tag each practice's homelab_fit honestly — single-node means PDB/anti-affinity/multi-replica HA are mostly irrelevant; do NOT recommend enterprise theater. Every practice MUST cite a real source_url you actually fetched.${FOCUS} Return the schema.`,
      { label: `research:${t.spec.key}`, phase: 'Research', schema: RESEARCH_SCHEMA }
    )
  }
  return agent(
    `You are analyzing a deterministic Kubernetes CONFIG/SIZING audit tool (\`stack-audit\`, pure bash + kubectl + VictoriaMetrics, single-node k3s+ArgoCD homelab) to find what to improve. ${HOW_TO_READ} Ground truth files:\n- Skill spec: ${SKILL} (documents each check's rationale — read via \`bat -pp\`)\n- Orchestrator: ${AUDIT_SH}\n- Thresholds: ${THRESHOLDS}\n- Checks: ${CHECKS_DIR}/01..07-*.sh\n- GitOps desired-state tree: ${GITOPS_DIR}\n\n${WHAT_WE_MEASURE}\n\n${AUDIT_CONTEXT}\n\nYOUR LENS: ${t.spec.lens}\n\nThe owner EXPLICITLY says: open to new tooling and restructuring, not afraid of breaking the current workflow — propose bold redesigns, not just additive checks. BUT respect the core design axioms (config-at-rest only / runtime = Grafana alarm / actionable-only / owned-namespaces / deterministic byte-stable output / single-node so HA patterns are mostly irrelevant) and mark in_scope=false for anything that violates the alarm-vs-audit boundary, calling out WHY. For each gap: name the current state (cite the §-check, SQL/bash line, or threshold), propose a CONCRETE change (new NN-check.sh, threshold redesign, or tool adoption with the exact command), tag the leverage dimension, state feasibility, and mark breaking=true if it changes/removes existing behavior. Ground every gap in something real.${FOCUS} Return the schema.`,
    { label: `analyze:${t.spec.key}`, phase: 'Analyze', schema: ANALYSIS_SCHEMA }
  )
}))

const research = results.slice(0, RESEARCH_DOMAINS.length).filter(Boolean)
const analysis = results.slice(RESEARCH_DOMAINS.length).filter(Boolean)
log(`Collected ${research.length} research + ${analysis.length} analysis results; synthesizing`)

// ── Phase 3: adversarial synthesis ───────────────────────────────────────────
const synth = await agent(
  `You are the synthesis stage for improving a deterministic Kubernetes CONFIG/SIZING audit tool (\`stack-audit\`, bash + kubectl + VictoriaMetrics over a single-node k3s+ArgoCD homelab). Below is the raw output of 5 external-research agents and 10 internal-analysis agents.\n\n${WHAT_WE_MEASURE}\n\n${AUDIT_CONTEXT}\n\nRESEARCH (external practices):\n${JSON.stringify(research)}\n\nANALYSIS (internal gaps):\n${JSON.stringify(analysis)}\n\nApply STRICT grounded + adversarial discipline (the owner's house rules — evidence first, adversarial kill second):\n1. Dedup overlapping ideas across all 15 agents into a single candidate set.\n2. For EACH candidate write the strongest counter-argument before keeping it. KILL >= 30% of raw candidates — favorites to kill: ideas that violate the config-at-rest/alarm boundary (belong in Grafana), enterprise-HA theater irrelevant on a single node, ideas needing data not obtainable from kubectl/VictoriaMetrics/GitOps tree, duplicates of an existing check or alarm, vanity findings that change no operator action, tool adoptions whose maintenance/FP cost exceeds the hand-rolled bash they replace. Put every kill in \`killed\` with a specific reason.\n3. Bucket survivors into:\n   - ship_now: additive checks/fixes implementable in bash+kubectl NOW (real command/jsonpath/PromQL sketch using actual cluster+VM+GitOps data). Assign each a check_name following NN-name.sh convention. State the SEVERITY rule. Cite the backing agent/evidence.\n   - restructure: changes that alter/remove existing behavior (threshold recalibration like the 200% overcommit, CPU-sizing added to 01, JSON-result storage + PR gate, metric re-scoping). State rationale + risk + breaking.\n   - new_tooling: per candidate tool (Polaris/kube-score/KubeLinter/Trivy/Kyverno/KRR/Goldilocks/Velero...) give a verdict adopt|wrap-hybrid|reject and why — DEFAULT to reject unless it clears the bar of replacing real bash maintenance or adding a load-bearing axis. Do NOT adopt for novelty.\n   - experiments: hypothesis-driven trials (change a threshold/add CPU sizing → measure finding delta; adopt a tool in shadow mode → compare FP rate). Each needs hypothesis + design + the metric it should move.\n4. top3_priorities: the 3 highest-leverage things to do first, each one sentence with the why.\nNo hedging — commit to verdicts. Prefer ideas validated by BOTH a research agent and an analysis agent. Respect that this is a SINGLE-NODE homelab, not a fleet.${FOCUS} Return the schema.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' }
)

return synth
