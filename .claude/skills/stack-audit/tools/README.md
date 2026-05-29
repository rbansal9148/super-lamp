# Tools

Deterministic, idempotent fixers that complement the read-only checks in `checks/`. Each tool maps to a recurring class of audit finding and ships with a `--dry-run` flag so it can be previewed before any mutation.

## Fixer registry

| Tool                       | Fix class                                              | Notes                                              |
| -------------------------- | ------------------------------------------------------ | -------------------------------------------------- |
| `split_env.py`             | Split one `.env` into secrets + config                 | Compose-substitution-aware; weak-secret report     |
| `sweep_split.sh`           | Apply `split_env.py` across all `apps/*/.env`          | Idempotent; restarts only currently-running apps   |
| `secure_envs.sh`           | `chmod 600` + `git rm --cached` every `.env`           | Combined hygiene; commit & rotate after            |
| `vacuum_stale.sh`          | Vacuum bloated/never-autovacuumed tables               | Thresholds: `--dead-pct=10 --days=7`               |
| `checkpoint_wal.sh`        | Force `CHECKPOINT` to recycle pg_wal segments          | Reports size before/after per postgres             |
| `rotate_pg_password.sh`    | Atomic postgres password rotation across all consumers | ALTER USER + sync every `apps/*/.env` reference    |
| `lock_public_ports.sh`     | Comment out `ports:` on Traefik-fronted services       | Skip-list for traefik/gluetun/plex/cloudflare-ddns |
| `add_logging.sh`           | Add `json-file 10m × 3` to services missing logging    | Inserts after `restart:`                           |
| `prune_docker.sh`          | Safe `docker image prune` + builder prune              | `--aggressive` adds `-a` (removes all unused)      |
| `all.sh`                   | Run every fixer in the recommended order               | `--dry-run`, `--only=`, `--skip=`, `--halt-on-error` |
| `recreate_dependents.sh`   | Recreate containers whose `network_mode: container:X` target was replaced | catches the gost-after-gluetun-recreate footgun |
| `refresh_image_pins.sh`    | Move drifted `@sha256` image pins forward to the tag's current digest (check 42) | pinned-only; same tag, never a version bump; edits files, never restarts |

## Test suite

`tools/test/run.sh` runs golden-file regression tests against `split_env.py`. Each fixture in `tools/test/fixtures/` pins a behavior the splitter must preserve forever:

| Fixture                       | Behavior pinned                                         |
| ----------------------------- | ------------------------------------------------------- |
| `01-basic`                    | baseline classification + `RPDB_API_KEY_VALIDITY_CACHE_TTL` is NOT a secret |
| `02-compose-substitution`     | `${VAR}` references in compose.yaml stay in `.env` even if they look config-shaped |
| `03-uri-with-credentials`     | credentialed URIs are SECRET even with bland key names  |
| `04-idempotent-resplit`       | re-splitting an already-split file is a no-op           |

Regenerate goldens (only after manual inspection):

```bash
bash tools/test/run.sh --update
```

## Library helpers (`tools/lib/`)

- `preflight.sh` — `preflight_default`, `preflight_containers c1 c2 …`, `preflight_pg_extension c db ext`. Tools source this and call before mutating state.
- `lock.sh` — `acquire_lock /tmp/<name>.lock`. Non-blocking advisory lock; exits 3 if held.
- `audit_log.sh` — `audit_log_emit <rc>` appends one JSONL line to `audit.log` (set `AUDIT_TOOL`, `AUDIT_DRY_RUN`, `AUDIT_CHANGED`, `AUDIT_RESTARTED`, `AUDIT_NOTE` env vars first).

## Conventions every fixer follows

- **Idempotent.** Re-running is safe and changes nothing if the system is already correct.
- **Dry-run by default-able.** Every script accepts `--dry-run` and emits a "WOULD …" plan.
- **No `.bak` files.** Backups would re-leak the secrets we're trying to protect; rely on git for history.
- **No surprise restarts.** Container recreate only happens when (a) the tool's purpose requires it AND (b) the target container is already running. Stopped services are left stopped.
- **Skip-list of intentional exceptions.** When a generic rule would damage a service that's intentionally configured (e.g. `traefik` *should* publish 80/443), the skip-list is at the top of the script and overridable via `--skip=`/`--add-skip=`.

## split_env.py

Splits a Docker-style `.env` file into:

- `secrets.env` — chmod 600, gitignored, holds secrets only
- `config.env`  — chmod 644, tracked in git, holds non-secret configuration

### Classification rule (deterministic)

A KV line is classified **SECRET** if either:

1. **Key name** matches `SECRET_KEY_REGEX`:
   `PASSWORD | SECRET | TOKEN | API[_-]?KEY | ACCESS_KEY | PRIVATE_KEY | JWT | CIPHER | ENCRYPTION_KEY | CREDENTIAL | CLIENT_SECRET | CLIENT_ID | SESSION_KEY | AUTH_KEY`
2. **Value** contains a credentialed URI: `://user:pass@host`

A KV line is **NEVER SECRET** if the key matches `NEVER_SECRET_REGEX` (overrides #1 above):

| Suffix             | Meaning                                  |
| ------------------ | ---------------------------------------- |
| `*_CACHE_TTL`      | duration (TTL, not a key)                |
| `*_TIMEOUT`        | timeout duration                         |
| `*_INTERVAL*`      | scheduled interval                       |
| `*_VALIDITY*`      | validity period                          |
| `*_ENABLED`        | boolean flag                             |
| `*_DISABLED`       | boolean flag                             |
| `*_BASE_URL`       | URL without creds                        |
| `*_URL`            | generic URL (credentialed ones still caught by VALUE rule) |
| `*_REDIRECT_URI`   | OAuth redirect (public)                  |
| `*_HOSTNAME`       | DNS name                                 |
| `*_PATH`, `*_PORT` | location indicators                      |
| `*_LIMIT`, `*_SIZE`, `*_COUNT`, `*_RATIO`, `*_THRESHOLD` | numeric tuning |
| `X_AUTHELIA_CONFIG_KEYS` | Authelia config namespace          |

Everything else is **CONFIG**.

### Weak-value detection (advisory)

If `--weak-report PATH` is given, secret values matching weak/placeholder patterns are flagged:

- Literals: `password`, `admin`, `admin123`, `change_me`, `secret`, `test`, `demo`, `default`, empty string
- Patterns: `^x+$` (e.g. `XXXXXX...`), `^changeme_*`, `^your_*`

Each flagged line is appended as `<env_path>\t<KEY>\t<VALUE>`.

### Usage

```bash
./tools/split_env.py /opt/docker/apps/foo/.env \
  /tmp/foo.secrets.env /tmp/foo.config.env \
  --weak-report /tmp/weak.tsv
```

## sweep_split.sh

Driver that iterates `apps/*/.env` under `${DOCKER_ROOT:-/opt/docker}`, runs the splitter, mutates the matching `compose.yaml`, and recreates only currently-running containers.

### compose.yaml mutation (idempotent)

For each `apps/<svc>/compose.yaml`:

1. Find the **first** `env_file:` block.
2. Within its list items, find the first `- .env`.
3. If `- config.env` is already present in the same block → no change.
4. Else: insert `- config.env` immediately after `- .env`, preserving indentation.

Subsequent `env_file:` blocks (e.g. `bitmagnet`'s second block referencing `gluetun/.env`) are NOT touched.

### Container recreate rule

Only services with a currently-running container are recreated (via `docker compose up -d <svc>`). Stopped services are left stopped — the sweep never starts something that wasn't running.

### Flags

| Flag                       | Effect                                                                |
| -------------------------- | --------------------------------------------------------------------- |
| `--dry-run`                | classify only; report counts without writing files                    |
| `--no-restart`             | skip container recreate (CI / staged rollout)                         |
| `--only=svc1,svc2`         | restrict to specific services                                         |
| `--weak-report=PATH`       | accumulate weak/placeholder findings across the whole sweep           |

### Safety properties

- No `.env.bak` files are ever written (they would re-leak secrets).
- Splitter writes to a temp file; the original is replaced atomically via `mv`.
- A service already split (`config.env` exists AND `compose.yaml` already references it) is skipped, so re-running the sweep is a no-op.
- If `docker compose up -d <svc>` fails (e.g. service not in any active profile), the sweep logs a warning and keeps going.

### Typical run

```bash
# Preview what would change
bash tools/sweep_split.sh --dry-run

# Apply with weak-secret report
bash tools/sweep_split.sh --weak-report=/tmp/weak.tsv
```

## Patterns learned (and codified above)

Things this skill discovered the hard way and now handles automatically:

| Symptom we hit                                  | Codified in                                        |
| ----------------------------------------------- | -------------------------------------------------- |
| `RPDB_API_KEY_VALIDITY_CACHE_TTL` misclassified as secret because name contains `API_KEY` | `NEVER_SECRET_REGEX` (`*_CACHE_TTL`, `*_VALIDITY*`) |
| `.env.bak` backups during refactor leaked secrets onto disk | `sweep_split.sh` never writes `.env.bak`           |
| `bitmagnet/compose.yaml` has TWO `env_file:` blocks (its own + gluetun's) — second one must not be touched | `mutate_compose()` only edits the FIRST block      |
| Re-running the sweep duplicated `- config.env` lines | mutate checks for existing `config.env` line before inserting |
| Recreating containers that were intentionally stopped | `is_running()` check before `docker compose up -d` |
| Compose `env_file:` order — later overrides earlier | We always put `.env` first, `config.env` after, so secrets win on conflict |
| Weak/default passwords (`password`, `admin123`, `CHANGE_ME`) lurking in .env after rotation push | `--weak-report` flag flags them on every sweep   |
| `gost` silently routed traffic into a dangling namespace after `gluetun` was force-recreated (Docker stores `network_mode: service:X` as `container:<id>` at depender's startup; recreating X leaves the depender pinned to a dead id) | `checks/16-stale-netns.sh` flags it as CRIT; `tools/recreate_dependents.sh` rejoins the live namespace |
