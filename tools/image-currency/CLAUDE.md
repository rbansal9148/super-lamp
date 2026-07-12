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
```

<!-- init-deep: generated 2026-07-12 from sha=d99636d -->
