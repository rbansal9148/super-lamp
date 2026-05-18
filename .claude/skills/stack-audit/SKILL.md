---
name: stack-audit
description: Run a deterministic health and performance audit of this Docker streaming stack (AIOStreams + Comet + MediaFusion + StremThru + Bitmagnet + Zilean + Prowlarr + Aiometadata + gluetun + traefik + authelia). Produces a prioritized punch list of findings (Critical / High / Medium / Low) with exact fix commands.
when_to_use:
  - User asks to "audit", "check the stack", "find problems", "what's wrong", "improvements?", "research more"
  - User reports timeouts, slowness, or errors
  - After non-trivial config changes (verify nothing regressed)
  - Routine weekly health check
---

# Stack Audit Skill

A deterministic, code-driven audit of the streaming stack at `/opt/docker`. Designed to replace ad-hoc back-and-forth investigation with a single repeatable command that emits a prioritized punch list.

## How to invoke

```bash
bash /opt/docker/.claude/skills/stack-audit/audit.sh           # quick mode (default, ~30s)
bash /opt/docker/.claude/skills/stack-audit/audit.sh --deep    # include pg_stat_statements, slow query analysis (~2 min)
bash /opt/docker/.claude/skills/stack-audit/audit.sh --json    # machine-readable output
```

### When you (the model) are running `/stack-audit`

Always run the deterministic bash audit first — it's fast and ~zero token cost. Then, **for a full audit**, also dispatch the 10-POV multi-agent pass below. The two are complementary: the bash audit catches codified issues with high precision; the agents discover unknown-unknowns and propose new check scripts.

Skip the multi-agent pass for narrow asks ("check disk space", "is bitmagnet healthy") — only run it when the user wants a thorough audit ("audit", "full audit", "what's wrong with the stack", "improvements?", "research more").

#### The 10 POVs to dispatch in parallel

Use the `Agent` tool with `subagent_type: Explore`, `run_in_background: true`, and dispatch all 10 in a single message. Each prompt must:
1. Brief the agent on the bitmagnet_vpn bug class (see "Bug-class reference" below) so it understands the kind of latent issue we're hunting.
2. Assign one of the 10 lenses below.
3. Demand concrete file:line findings in /opt/docker NOW (not hypothetical).
4. Demand a deterministic detection snippet suitable for `checks/`.
5. Cap output at ~350 words.

| # | Lens | Looks for |
|---|------|-----------|
| 1 | Security | weak creds, exposed ports, missing authelia, root containers, RW docker.sock |
| 2 | Performance | missing mem_limit/cpus, healthcheck thrash, duplicate workloads, unbounded logs |
| 3 | Reliability/DR | missing healthchecks, no backups, no restart policy, broken depends_on |
| 4 | Config hygiene | inconsistent TZ/PUID, dead blocks, duplicate keys, `:latest` tags |
| 5 | Networking | services that should be behind gluetun, DNS leaks, proxy chain breakage |
| 6 | Observability | log rotation gaps, missing metrics, beszel/uptime-kuma blind spots |
| 7 | Supply chain | image age, EOL versions, abandoned upstreams, watchtower scope |
| 8 | Data integrity | postgres tuning, redis persistence, mixed pg majors, missing checksums |
| 9 | Architecture/sprawl | overlapping services, kill candidates, consolidation opportunities |
| 10 | Storage/cost | postgres bloat, orphan data dirs, log file runaways, docker overlay size |

#### Bug-class reference for agent briefings

Use this exact paragraph (verbatim or summarized) in each agent prompt so they share context:

> **The bitmagnet_vpn bug class**: A service can run for weeks with a latent config bug. The container holds the env from its last successful start; the compose file has since drifted. The bug only surfaces on the next recreate. Example: `apps/bitmagnet/compose.yaml` loaded `gluetun/.env` but not `gluetun/config.env` after the env-split refactor — `VPN_TYPE=wireguard` (in config.env) was missing from the rendered config, but the running container still had it from before the split. The recreate dropped the var, defaulted to OpenVPN, and crashed.

When consolidating agent findings, **filter false positives** before adopting checks: subagents often have buggy path resolution, wrong env-var assumptions, or hardcode values that aren't true on this host. Cross-verify before promoting a finding to a check script.

Each check script in `checks/` runs independently and emits findings in this format:

```
SEVERITY|DOMAIN|FINDING|FIX_COMMAND
```

Where `SEVERITY ∈ {CRIT, HIGH, MED, LOW, OK}`. The main `audit.sh` aggregates, sorts, and prints.

## What's checked (5-pass methodology, all codified)

### Pass 1: System
- Disk usage (`df -h /`)
- Memory + swap (`free -h`)
- Load average (`/proc/loadavg`)
- CPU steal time (VPS noisy-neighbor signal)
- Container restart count + OOM flag
- Healthcheck presence

### Pass 2: Containers
- Running vs stopped / restart loops (e.g., redlib OAuth 403)
- mem_limit set on big services (bitmagnet_postgres, mediafusion, comet, aiostreams)
- Log file size per container (cap should bound them)
- Image pinning: streaming addons should be `@sha256` not `:latest`

### Pass 3: Postgres (per DB)
Connects to each `*_postgres` container and reports:
- `heap_hit_pct` and `idx_hit_pct` (target ≥95%)
- Dead-tuple ratio per table (warn if >10%)
- Idle connections older than 30 min
- Top 3 slow queries from `pg_stat_statements` (deep mode)
- Unused indexes (0 scans + >50MB)
- Last autovacuum recency
- DB size growth vs prior snapshot

### Pass 4: Redis (per instance)
- Hit rate, evicted_keys, used/max memory
- maxmemory policy must be `allkeys-lru` (not `noeviction`)
- Count of keys with no TTL (leak indicator)

### Pass 5: Streaming layer
- AIOStreams: histogram of `Returning N streams and M errors` over last N min
- Comet: response time p50/p95 from access logs, background-scraper status
- MediaFusion: scheduler disabled flag, slow-scraper duration warnings
- StremThru: mylist-parse errors, broken-pipe count, TorBox API latency
- AIOmetadata: app-level cache hit rate (from log), TMDB fetch failure rate
- Bitmagnet: DHT ingest rate (last 4 hours), must be ≤ prune rate
- Zilean: search_torrents_meta p95 latency

### Cross-cutting
- VPN: gluetun egress IP must match `EXPECTED_VPN_REGION` (default SG)
- Public-port exposure (5432, 8191, etc — security failure)
- Traefik log level (DEBUG = noise; should be WARN/INFO)
- Authelia coverage on all Traefik routes
- StremThru tunnel route map (TorBox should bypass, others via gost)
- Orphan data dirs under `/opt/docker/data/` for stopped services

### Pass 6: Config-drift (the "bitmagnet_vpn class")
A service can run for weeks with a latent config bug — its env was set correctly at last start, but the compose file has since drifted (env_file split, var renamed, etc.). The container keeps the old env in memory and only crashes on recreate. These checks catch the bug *before* the recreate:

- **17-env-file-completeness.sh** — services with `env_file: - .env` whose sibling `config.env` exists but isn't loaded (or vice versa). Covers the exact bitmagnet→gluetun pattern (cross-service env_file imports loading one half of a split).
- **18-undefined-var-refs.sh** — `${VAR}` referenced in compose.yaml with no default and no definition reachable through env_file chain or top-level .env.
- **19-env-duplicate-keys.sh** — same KEY defined twice in one .env file (later wins silently); same KEY in both .env and config.env with different values.
- **20-config-drift.sh** — diff each running container's env against what `docker compose config` would render *right now*. If compose declares a var the container doesn't have, the next recreate would set it — and that may expose a latent failure.
- **21-floating-tags.sh** — running containers whose image is a floating tag (`:latest`, `:edge`, etc.). Recreate would pull a new digest silently; pin to the current image id.

## Thresholds (deterministic — see `thresholds.sh`)

All limits live in `thresholds.sh` so they're tunable. Examples:

| Threshold | Default |
|---|---|
| `HEAP_HIT_GOOD` | 95 |
| `HEAP_HIT_WARN` | 80 |
| `IDLE_CONN_MAX_MIN` | 30 |
| `DEAD_TUP_PCT_WARN` | 10 |
| `LOG_MB_WARN` | 50 |
| `DISK_USED_PCT_WARN` | 80 |
| `EXPECTED_VPN_REGION` | "Singapore" |
| `DHT_INGEST_VS_PRUNE_MAX_RATIO` | 0.8 |
| `AIOSTREAMS_ERROR_RATE_PCT_WARN` | 30 |
| `CONTAINER_LOG_MB_WARN` | 50 |

## Severity rules

- **CRIT**: security exposure, data-loss risk, container OOM-killed, swap full
- **HIGH**: user-visible slowness (heap_hit<50, error_rate>30%), VPN wrong region, broken proxy chain
- **MED**: bloat, suboptimal config, log noise
- **LOW**: informational

## Fixers (tools/)

Deterministic, idempotent tools that *apply* the fixes the audit recommends. Each accepts `--dry-run` and never restarts a container that wasn't already running. Full registry + rules in `tools/README.md`.

| Tool                        | What it does                                                       |
| --------------------------- | ------------------------------------------------------------------ |
| `tools/split_env.py`        | Split one `.env` → secrets + config (compose-substitution-aware)   |
| `tools/sweep_split.sh`      | Apply the split across every `apps/<svc>/.env`                     |
| `tools/secure_envs.sh`      | `chmod 600` + `git rm --cached` every `.env`                       |
| `tools/vacuum_stale.sh`     | Vacuum tables exceeding dead-tuple % or autovacuum age thresholds  |
| `tools/checkpoint_wal.sh`   | Force `CHECKPOINT` to recycle pg_wal across all postgres instances |
| `tools/rotate_pg_password.sh` | Atomic postgres password rotation (ALTER USER + URI sync + recreate) |
| `tools/lock_public_ports.sh` | Comment out `ports:` on Traefik-fronted services                  |
| `tools/add_logging.sh`      | Add `json-file 10m × 3` log rotation to services missing it        |
| `tools/prune_docker.sh`     | Safe Docker housekeeping (dangling images + build cache)           |

Typical post-audit flow — one command:
```bash
bash tools/all.sh --dry-run     # preview every fixer in the recommended order
bash tools/all.sh               # apply
```

Or run a single fixer manually (e.g. `bash tools/secure_envs.sh`). All are idempotent.

## Audit → fix loop

`audit.sh` findings now carry an optional `FIX_TOOL` hint (5th pipe-separated field). Run:

```bash
bash audit.sh --fix             # group findings by their FIX_TOOL, dry-run each
bash audit.sh --fix --apply     # then actually run them; reprints --summary after
```

Each tool's results are appended to `audit.log` (JSONL) for an audit trail of who-changed-what-when.

## Tests

`tools/test/run.sh` runs golden-file tests against `split_env.py`. 4 fixtures pin the rules the splitter must preserve (compose-substitution awareness, credentialed-URI detection, `*_VALIDITY_CACHE_TTL`-style false-positive, idempotent re-split).

## Output

A sorted, deduped Markdown punch list with exact fix commands. Example:

```markdown
## 🔴 Critical (2)
- [security] mediafusion_postgres exposes 5432 publicly
  fix: remove `ports: ["5432:5432"]` from apps/mediafusion/compose.yaml
- [storage] disk usage 92% — running out of space
  fix: investigate /opt/docker/data large dirs

## 🟠 High (3)
...
```

## 5-pass design rationale (how this skill was built)

1. **Structure**: split by domain (system / containers / postgres / redis / streaming / security / network / storage / bitmagnet / stremthru). Each domain = one check script.
2. **Per-service**: codify the *specific* metrics that surfaced real issues in the original investigation (e.g., `heap_hit=9%` on stremthru, `mylist` unmarshal in stremthru logs).
3. **Strict thresholds**: replace fuzzy "looks high" with numbers in `thresholds.sh`. Severity is a function of measurement vs threshold, not LLM judgement.
4. **Action commands**: every finding ships with a `FIX_COMMAND` that's safe to copy-paste or run via Bash tool.
5. **Quick vs deep modes**: default mode is read-only and ~30s. Deep mode unlocks pg_stat_statements analysis (acceptable cost when explicitly requested).
