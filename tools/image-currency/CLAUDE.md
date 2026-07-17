# image-currency

Rust CLI that checks (and optionally applies) the `tag@sha256:…` image-digest pins across
`gitops/manifests`. Resolves each tag's current upstream digest and reports drift.

## Stack

- Language: Rust 2021. Deps: clap, reqwest (blocking, rustls-tls), serde_json, regex, anyhow, walkdir.
- Binary: `image-currency` (`src/main.rs`).

## Behavior

| Tag class | digest moved → | action |
|---|---|---|
| floating (`:latest`/`:dev`/…) | `UPDATE` | `--apply` rewrites in-file |
| version pin (`:18.4`, `:v2.7.5`) | `⚠ DRIFT` (tag re-pushed) | `--repin-drift` only (never automatic) |
| any | resolve failed | `ERROR` (never counted as current) |

Registry auth uses the generic `Www-Authenticate` challenge flow — no per-registry special-casing
(ghcr.io / docker.io / registry.k8s.io all work).

`--resolve <ref>` is a one-off lookup (report-only, no mutation): prints the current digest **and**
the `org.opencontainers.image.version` label for any `repo:tag` or `repo:tag@sha256:…`. Passing a
`@sha256:` pin resolves *by that digest*, reading the version a floating digest already carries
(walks index → arch manifest → config blob). Used to pin a new semver tag correctly, or to see
which upstream version a `:latest`/`:nightly` digest bump actually moved to. **Not** a semver
auto-bumper — registry `tags/list` is unordered/paginated on Docker-official repos, and semver
bumps need the manual breaking-change gate below.

## Design intent (don't "fix" this)

**Report-by-default; mutate only on an explicit flag.** Deliberately NOT argocd-image-updater /
Renovate: those auto-commit + auto-sync, removing the human review gate that caught real crashloops
(authelia `/data` ownership, stremthru nested pgdata). Keep the read-only default.

## Commands

```bash
cargo build --release        # → target/release/image-currency
cargo test                   # ref-parsing unit tests
image-currency               # report only (read-only)
image-currency --apply       # rewrite floating UPDATEs
image-currency --repin-drift # re-pin drifted version tags
image-currency --resolve ghcr.io/immich-app/immich-server:v3.0.3   # digest + version for a tag
image-currency --resolve postgres:18.4@sha256:32ca0af8…            # version behind a pinned digest
```

<!-- init-deep: generated 2026-07-17 from sha=ec8aa5d -->
