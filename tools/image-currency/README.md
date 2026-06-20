# image-currency

Digest-currency checker / applier / health gate for the GitOps image pins under
`gitops/manifests`.

Every image is pinned `tag@sha256:…`. This tool resolves each tag's **current** upstream
digest and compares:

| Tag class | digest moved → | action |
|---|---|---|
| floating (`:latest`/`:nightly`/`:dev`/…) | `UPDATE` | `--apply` rewrites it in-file |
| version pin (`:18.4`, `:v2.7.5`) | `⚠ DRIFT` (tag re-pushed) | `--repin-drift` to re-pin (never automatic) |
| any | resolve failed | `ERROR` (never counted as current) |

Registry access uses the generic `Www-Authenticate` challenge flow — no per-registry
special-casing (ghcr.io / docker.io / registry.k8s.io all work).

## Why not argocd-image-updater / Renovate

Both auto-commit + auto-sync, removing the human review gate that caught the authelia
`/data`-ownership crashloop and the stremthru nested-pgdata clobber. This tool reports by
default and mutates only on explicit `--apply` / `--repin-drift`.

## Build

```sh
cargo build --release            # → target/release/image-currency
cargo test                       # ref-parsing unit tests
```

## Usage

```sh
image-currency                               # report only (read-only)
image-currency --apply                        # rewrite floating UPDATEs
image-currency --repin-drift                   # also re-pin version-tag DRIFT
image-currency --apply --commit --sync --health   # full pipeline
image-currency --health                       # synthetic smoke test of owned workloads
image-currency --exit-code                    # CI: exit 10 update / 20 drift / 1 health-fail
```

Run from anywhere in the repo (repo root is found via `git rev-parse`). The `--sync` /
`--health` paths require `kubectl`; everything else is offline-capable except the registry
lookups.
