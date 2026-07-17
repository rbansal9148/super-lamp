# super-lamp — k3s + ArgoCD GitOps homelab

Single-node k3s cluster (Oracle arm64 VM, `instance-20260315-2004`) running a self-hosted app
stack, managed entirely by ArgoCD from this repo. Everything is declarative under `gitops/`;
changes ship by commit → push → ArgoCD sync. Domain `my-blue-car.work` (Cloudflare-proxied →
origin `161.118.165.53`).

## ⚠ The root README.md and compose.yaml are LEGACY — do not trust them

This repo began as a Docker-Compose VPS template (`Viren070/docker-compose-vps-template`) and was
migrated to k3s. `README.md` still describes the old Compose workflow; `compose.yaml` is a graveyard
of commented-out `# MIGRATED to k3s` services. **The live system is k3s + ArgoCD, not Docker
Compose** — ignore `docker compose` instructions. The source of truth is `gitops/`.

## Stack

- **Cluster**: k3s (single node, arm64), Traefik ingress (built-in), containerd.
- **GitOps**: ArgoCD, app-of-apps — see `gitops/CLAUDE.md`.
- **Mesh**: linkerd (auto-injected in the `apps` namespace; meshed→meshed uses proxy port 4143).
- **Secrets**: Bitnami SealedSecrets (controller in `kube-system`); plaintext is never committed.
- **DNS/TLS**: cert-manager (LE DNS-01 via Cloudflare) + a single proxied `*.my-blue-car.work`
  wildcard record. **external-dns was removed 2026-07-11** (its traefik source silently emitted zero
  endpoints); DNS is the wildcard only — see `gitops/RESTORE.md §3`.
- **Auth**: Authelia forward-auth; `*.my-blue-car.work → two_factor` gates hosts by default.
- **Observability**: VictoriaMetrics + VictoriaLogs + Grafana + OTel — see `gitops/manifests/observability/CLAUDE.md`.

## Structure

- `gitops/` — the entire declarative cluster; **all real work happens here.**
  - `bootstrap/` — the three ArgoCD root objects (`kubectl apply -f gitops/bootstrap/`).
  - `apps/` — one ArgoCD `Application` per app (app-of-apps auto-registers them).
  - `manifests/<app>/` — the k8s YAML per app. **Per-app conventions live in each file's header
    comment**, not in a per-dir CLAUDE.md (that's why there isn't one under every app).
- `tools/image-currency/` — Rust CLI auditing the `tag@sha256:` image pins (own CLAUDE.md).
- `scripts/validate-gitops.sh` — offline yq + kubeconform.
- `docs/` — `adr/0001-observability-stack.md`, `observability-primer.md`.

## Commands

```bash
just                                 # list recipes
just validate [path]                 # yq + kubeconform (same gate as pre-commit); default path=gitops
just seal-key <ns> <secret> <key>    # seal ONE value into a strict-scoped SealedSecret (hidden prompt, never an arg)
just fetch-cert                      # fetch the SealedSecrets public cert for offline sealing
pre-commit run --all-files           # validate-gitops + gitleaks
cargo run --release --manifest-path tools/image-currency/Cargo.toml   # image-digest currency report
```

## Conventions

- **Images pinned `tag@sha256:…`** — never bare tags; `tools/image-currency` audits/updates them.
- **SealedSecrets only** — seal with `just seal-key` (strict scope). `.secrets/` is gitignored for
  staging plaintext before sealing.
- **Pre-commit is the gate** — `validate-gitops` (yq + kubeconform) + `gitleaks`. Don't bypass.
- **Custom app images are side-loaded** into containerd (no registry), `imagePullPolicy: Never`;
  e.g. `auto-verbal-score` rebuilds via `gitops/scripts/update-avs.sh`.
- Deep operational history (incidents, gotchas) lives in codebase-memory and the YAML header comments.

<!-- init-deep: generated 2026-07-17 from sha=ec8aa5d -->
