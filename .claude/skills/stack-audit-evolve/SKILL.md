---
name: stack-audit-evolve
description: Evolve the stack-audit tool itself — a meta-audit that researches external Kubernetes config-quality / right-sizing / GitOps / supply-chain / single-node-reliability practices and analyzes the current stack-audit from 10 lenses, then synthesizes a ranked plan of new checks to add, breaking redesigns, new tooling to adopt (or reject), and experiments to run. Use when the user says "improve the stack-audit", "evolve the audit", "what should the audit check next", "meta-audit", "audit the auditor", "find improvements/experiments for stack-audit", "are we missing checks", or wants to expand what stack-audit covers. Spawns a multi-agent Workflow (snapshot → 5 research + 10 analysis fan-out → adversarial synthesis); invoking this skill IS the opt-in to that orchestration. Token-heavy (~16 agents) — run intentionally (e.g. after a wave of manifest/check changes, or on a monthly cadence), not casually. Default outcome is "add nothing" — survivors must clear a leverage dimension AND survive the adversarial kill pass.
when_to_use:
  - "Improve / evolve the stack-audit", "audit the auditor", "meta-audit"
  - "What checks should we add next", "what are we blind to", "find improvements and experiments"
  - The owner is considering new tooling (Polaris/kube-score/Trivy/Kyverno/KRR...) or restructuring the audit
  - Monthly cadence (chain with /schedule), the same way audit-evolve / trendshift-mine run
---

# stack-audit-evolve — meta-audit to improve the auditor

`stack-audit` answers "is the cluster's config/sizing wrong at rest?".
This skill answers the level up: **"is `stack-audit` checking the right things,
and what should it check next — with new tooling if that wins?"** It is the
deliberate, expensive, evidence-first way to grow the audit — not a casual command.

It complements, does not replace, the `stack-audit` skill:
- `stack-audit` = run the existing 7 checks, get the punch list, fix findings.
- `stack-audit-evolve` = decide what NEW checks / redesigns / tooling / experiments the audit needs.

This is the exact sibling of the `audit-evolve` skill (which evolves
`transcript-audit`); same shape, retargeted at the k8s config audit.

## When to use

- "Improve / evolve the stack-audit", "audit the auditor", "meta-audit".
- "What checks should we add", "what are we blind to", "find improvements + experiments".
- The owner is weighing **new tooling** (a policy engine, a right-sizer, a scanner)
  or **restructuring** the bash architecture.
- After shipping several manifest/check changes — to design the next coverage layer.
- Monthly cadence (chain with `/schedule`).

## When NOT to use

- You just want today's findings → use `stack-audit`, not this.
- A specific, already-scoped check to add → edit `checks/NN-*.sh` directly; this
  skill is for *discovery*, and its fan-out cost isn't justified for one known check.
- Casually / repeatedly — ~16 agents per run. Intentional cadence only.

## How it works

The skill launches a bundled Workflow. **Invoking this skill is the explicit
opt-in to multi-agent orchestration** — launch it without re-asking:

```
Workflow({ scriptPath: "/opt/docker/.claude/skills/stack-audit-evolve/workflow.js" })
```

Optional steer (free text woven into every agent prompt), e.g. focus a run:

```
Workflow({ scriptPath: "/opt/docker/.claude/skills/stack-audit-evolve/workflow.js",
           args: { focus: "resource right-sizing and CPU only" } })
```

Phases (see `meta.phases` in the script):

1. **Snapshot** — one agent runs `stack-audit --no-alerts` + `--summary` and skims
   the 7 check scripts, distilling the live punch list + per-check map into fresh
   context. The run is never frozen to a stale snapshot.
2. **Research (5 agents, parallel)** — external practices, one domain each:
   k8s config-quality scanners (Polaris/kube-score/KubeLinter/Trivy/Kyverno/CIS),
   resource right-sizing (VPA/Goldilocks/KRR, percentile vs max, CPU throttling/QoS),
   GitOps/ArgoCD drift hygiene, supply-chain/security posture (vuln scan, signatures,
   PSS/admission, RBAC, NetworkPolicy), single-node reliability/backup/observability.
   Each must cite real fetched source URLs and tag homelab-fit honestly.
3. **Analyze (10 agents, parallel)** — the current audit from 10 lenses:
   coverage-gaps, tooling-replacement, resource-sizing-validity, security-depth,
   probe-and-health-config, image-supply-chain, determinism-meta, gitops-drift,
   alarm-audit-boundary, outcome-experiment-harness. Each reads the check scripts +
   thresholds + SKILL.md for ground truth (via `bat -pp`, not Read — cbm gate).
4. **Synthesize (1 agent, high effort)** — dedup across all 15, run the adversarial
   kill pass (≥30% killed), bucket survivors into **ship_now** (additive checks with
   command sketches + NN-name + severity rule), **restructure** (breaking redesigns
   with rationale + risk), **new_tooling** (adopt/wrap-hybrid/reject per tool),
   **experiments** (hypothesis + design + target metric), and **top3_priorities**.

The workflow returns structured JSON; relay the buckets + top-3 to the user.

## Discipline (carried even if the script is edited)

Same house rules as `grounded-recommendations.md` and `rigorous-analysis.md`:

- **Evidence or it dies.** Every proposed check cites a §-check, a threshold/bash
  line, a cluster fact, or a fetched URL. "Would be nice to check X" with no
  grounding is killed in synthesis.
- **Adversarial kill is mandatory.** Synthesis must kill ≥30% of raw candidates.
  A run that proposes everything and kills nothing is a failed run.
- **Default outcome is "add nothing".** A check survives only if it clears a
  leverage dimension {oom-risk, data-loss, security, availability, cost-efficiency}
  AND would change a real operator action. Coverage for its own sake is not a reason.
- **Respect the design axioms** (the synthesis prompt enforces these):
  - **Config-at-rest only.** Runtime failure = Grafana alarm, not an audit check.
    Anything that wants a time series is out of scope (route it to an alarm).
  - **Single-node reality.** PDB / anti-affinity / multi-replica HA are mostly
    irrelevant — flagging them is enterprise theater, killed by default.
  - **Actionable-only, owned-namespaces.** Third-party Helm noise is excluded.
  - **Deterministic, byte-stable output.** New checks must sort their iteration
    and carry no wall-clock in the finding text.
- **New tooling defaults to reject.** A scanner/policy-engine is adopted only if it
  replaces real bash maintenance or adds a load-bearing axis — never for novelty.
  The maintenance + false-positive cost must beat the hand-rolled check it displaces.
- **Breaking is allowed, not free.** The owner accepts restructuring, but every
  `restructure` item carries its risk so the trade is visible.

## Maintaining the script

`workflow.js` hardcodes `WHAT_WE_MEASURE` (a prose summary of the current 7 checks +
scope boundary). When a check is added/removed or the scope boundary moves, update
that constant so the research agents don't re-propose what already exists. The
analysis agents read the check scripts directly (via `bat -pp`), so they stay current
automatically; only the research agents rely on the prose summary.

Iterate on the workflow with `Write`/`Edit` on `workflow.js`, then re-launch via the
same `scriptPath`. The skill lives in-repo at
`/opt/docker/.claude/skills/stack-audit-evolve/` next to `stack-audit` so both are
version-controlled with the cluster they audit.

## Bedrock principle

**The audit earns each check the same way a hook does: evidence first, adversarial
kill second, ship third.** A run that returns one well-grounded new check (or one
"reject this tool, keep the bash") and a long killed list succeeded. A run that
returns ten checks and kills nothing failed — the fan-out became a brainstorm, not
an audit.
