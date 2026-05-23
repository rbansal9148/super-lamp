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

**Default path is purely deterministic.** Run `bash audit.sh` and present the output as-is. No LLM judgement, no parallel agents, no editorial layer — the bash checks already encode the rules. This makes audit results reproducible run-to-run and free of model variance.

If a finding looks wrong, **fix the check script** (so the next run produces the right answer) rather than overriding it case-by-case in your response.

### Discovery mode (opt-in only — `--discover` or "expand the audit")

Use the 10-POV agent dispatch **only** when the user explicitly asks to *expand check coverage* — phrases like "what is the audit missing?", "find new bug classes", "do analysis 10 times". Do not run it as part of a routine audit; it's a development workflow for the skill itself, not part of the audit output.

When in discovery mode, the agents' job is to **propose new check scripts**, not produce findings. The deliverable from each agent is a concrete bash/python detection snippet that can drop into `checks/`. Findings the agents surface incidentally should be promoted into the next bash check, not reported directly — that's the principle that keeps the skill deterministic over time.

Lenses (use one per agent, dispatch all 10 in a single message via `Agent` tool with `subagent_type: Explore`):

| # | Lens | What it should propose a check for |
|---|------|-----------|
| 1 | Security | weak creds, exposed ports, missing authelia, RW docker.sock |
| 2 | Performance | missing mem_limit/cpus, healthcheck thrash, log unbounded |
| 3 | Reliability/DR | missing healthchecks, no backups, no restart policy |
| 4 | Config hygiene | inconsistent TZ/PUID, duplicate keys, `:latest` tags |
| 5 | Networking | services that should be behind gluetun, DNS leaks |
| 6 | Observability | log rotation, missing metrics, blind spots |
| 7 | Supply chain | image age, EOL versions, watchtower scope |
| 8 | Data integrity | postgres tuning, redis persistence, missing checksums |
| 9 | Architecture/sprawl | overlapping services (subjective — usually NOT codifiable) |
| 10 | Storage/cost | bloat, orphan dirs, log runaways |

#### Bug-class reference for agent briefings

Use this exact paragraph (verbatim or summarized) in each agent prompt so they share context:

> **The bitmagnet_vpn bug class**: A service can run for weeks with a latent config bug. The container holds the env from its last successful start; the compose file has since drifted. The bug only surfaces on the next recreate. Example: `apps/bitmagnet/compose.yaml` loaded `gluetun/.env` but not `gluetun/config.env` after the env-split refactor — `VPN_TYPE=wireguard` (in config.env) was missing from the rendered config, but the running container still had it from before the split. The recreate dropped the var, defaulted to OpenVPN, and crashed.

**Filter false positives before adopting:** subagents often have buggy path resolution, hardcoded assumptions (`/data/docker` vs `/opt/docker/data`), or treat intentional patterns (`environment:` block overriding env_file) as bugs. Verify each proposed check produces ≥1 true positive and 0 false positives on the current state before adding it to `checks/`.

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
- **Restart loops are uptime-aware**: HIGH while uptime < `RESTART_LOOP_UPTIME_MIN` (default 30m), auto-downgraded to LOW once the container has survived past that boundary (loop appears resolved).
- **Healthcheck interval too long on critical services** (check 28): catches services that have a healthcheck but with `interval ≥ 120s`, which delays hung-state detection.

### Pass 3: Postgres (per DB)
Connects to each `*_postgres` container and reports:
- `heap_hit_pct` and `idx_hit_pct` (target ≥95%)
- Dead-tuple ratio per table (warn if >10%)
- Idle connections older than 30 min
- Top 3 slow queries from `pg_stat_statements` (deep mode)
- Unused indexes (0 scans + >50MB)
- Last autovacuum recency
- DB size growth vs prior snapshot
- **Autovacuum rate** (check 31): per-table dead-tuple accumulation rate; warns when `dead_tup / hours_since_last_autovacuum ≥ DEAD_TUP_RATE_PER_HOUR_WARN` (default 10000), even before `dead_pct` crosses the absolute threshold.

### Pass 4: Redis (per instance)
- Hit rate, evicted_keys, used/max memory
- maxmemory policy must be `allkeys-lru` (not `noeviction`)
- Count of keys with no TTL (leak indicator)
- **Eviction rate** (check 30): per-instance evicted_keys/min over uptime; warns at `REDIS_EVICTION_PER_MIN_WARN` (default 30). Hit-rate alone misses this signal.

### Pass 5: Streaming layer
- AIOStreams: histogram of `Returning N streams and M errors` over last N min
- Comet: response time p50/p95 from access logs, background-scraper status
- MediaFusion: scheduler disabled flag, slow-scraper duration warnings
- StremThru: mylist-parse errors, broken-pipe count, TorBox API latency
- AIOmetadata: app-level cache hit rate (from log), TMDB fetch failure rate
- Bitmagnet: DHT ingest rate (last 4 hours), must be ≤ prune rate
- Zilean: search_torrents_meta p95 latency
- **Stuck-job / poison-input detection** (check 32): generalizes the parse-torrent fix — flags `comet.background_scraper_items` with `consecutive_failures ≥ 5` aged >24h, `mediafusion.jobs` exhausted past `max_attempts`, and `stremthru.job_log` with repeated failures.
- **Stremthru stream orphans** (check 29): `torrent_stream` rows with no matching `torrent_info` (the schema lacks the FK, so cleanup is manual).
- **AIOStreams TorBox account cluster signal** (check 33): when ≥3 distinct `_TB`-suffixed addons time out in the same hour, or TorBox Search Zod-parse-errors accumulate, surfaces the "TorBox API account broken" hypothesis (rate-limit cap=0, sub lapsed, key revoked) rather than per-addon noise. Source-side fixes don't help — universal failure point is the TorBox checkcached step.
- **Prowlarr indexer health** (check 34): per-indexer fail-rate and avg response time via Prowlarr's `/api/v1/indexerstats`; flags 100%-failure indexers (waste slots) and slow ones (>5s avg WARN, >30s HIGH — a single 30s+ indexer blocks the whole concurrent search batch past timeout). Filters out already-disabled indexers (their cumulative stats are historical, not actionable).
- **Postgres slow-query parameter dump** (check 35): any postgres with `log_min_duration_statement` set but missing `log_parameter_max_length=0` will dump bytea values as multi-MB hex strings per slow statement. Bounded by log rotation, but eats the rotation budget fast.
- **AIOStreams v2.30 deprecated env** (check 37): catches `DEFAULT_/FORCED_<SVC>_*` (replaced by `SERVICE_CREDENTIALS`), `FORCE_PUBLIC_PROXY_*`, `PTT_*`, `LOG_CACHE_STATS_INTERVAL`. Also flags `ANIME_DB_*_REFRESH_INTERVAL` values that look like ms (>1e7) — v2.30 reinterpreted these as seconds; old values get clamped to ~24.8 days and fire immediately on startup.

### Cross-cutting
- VPN: gluetun egress IP must match `EXPECTED_VPN_REGION` (default SG)
- Public-port exposure (5432, 8191, etc — security failure)
- Traefik log level (DEBUG = noise; should be WARN/INFO)
- Authelia coverage on all Traefik routes
- StremThru tunnel route map (TorBox should bypass, others via gost)
- Orphan data dirs under `/opt/docker/data/` for stopped services
- **Dormant data dirs** (check 36): directories under `/opt/docker/data/<svc>/` whose service is NOT in any running container — likely a service that got commented out of the main `compose.yaml` but whose data dir was never reclaimed (this stack had 10.9GB of orphan immich data after the service was disabled). HIGH at ≥5GB, MED ≥100MB.

### Pass 6: Config-drift (the "bitmagnet_vpn class")
A service can run for weeks with a latent config bug — its env was set correctly at last start, but the compose file has since drifted (env_file split, var renamed, etc.). The container keeps the old env in memory and only crashes on recreate. These checks catch the bug *before* the recreate:

- **17-env-file-completeness.sh** — services with `env_file: - .env` whose sibling `config.env` exists but isn't loaded (or vice versa). Covers the exact bitmagnet→gluetun pattern (cross-service env_file imports loading one half of a split).
- **18-undefined-var-refs.sh** — `${VAR}` referenced in compose.yaml with no default and no definition reachable through env_file chain or top-level .env.
- **19-env-duplicate-keys.sh** — same KEY defined twice in one .env file (later wins silently); same KEY in both .env and config.env with different values.
- **20-config-drift.sh** — diff each running container's env against what `docker compose config` would render *right now*. If compose declares a var the container doesn't have, the next recreate would set it — and that may expose a latent failure.
- **21-floating-tags.sh** — running containers whose image is a floating tag (`:latest`, `:edge`, etc.). Recreate would pull a new digest silently; pin to the current image id.
- **22-vpn-coverage.sh** — services that should route via gluetun but don't.
- **23-docker-socket-mode.sh** — read/write mounts of `/var/run/docker.sock` that should be read-only.
- **24-postgres-tuning.sh** — wrong shared_buffers / work_mem heuristics relative to mem_limit.
- **25-config-env-secrets.sh** — secret-shaped values that slipped into the committed `config.env` half of the env split (inverse of `tools/split_env.py`).
- **26-tz-consistency.sh** — TZ values that disagree with the top-level `/opt/docker/.env` pin (or no pin at all when 1+ service hardcodes a TZ).
- **27-env-shadowing.sh** — same KEY defined in both `env_file:` and `environment:` (compose silently overrides); skips the safe `KEY=${KEY}` pass-through pattern.

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
| `RESTART_LOOP_UPTIME_MIN` | 30 |
| `REDIS_EVICTION_PER_MIN_WARN` | 30 |
| `DEAD_TUP_RATE_PER_HOUR_WARN` | 10000 |
| `STUCK_JOB_WARN_COUNT` | 10 |
| `PROWLARR_INDEXER_FAIL_RATE_WARN` | 50 |
| `PROWLARR_INDEXER_AVG_MS_WARN` | 5000 |
| `PROWLARR_INDEXER_AVG_MS_HIGH` | 30000 |
| `DORMANT_DATA_MB_WARN` | 100 |
| `DORMANT_DATA_MB_HIGH` | 5000 |
| `STREMTHRU_STREAM_ORPHANS_WARN` | 1000 |
| `HEALTHCHECK_INTERVAL_WARN_SEC` | 120 |

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
