# network-policies — apps / argocd namespace isolation

Enforced by kube-router (k3s's built-in NetworkPolicy controller — **no Cilium/Calico**). The model
is default-deny + explicit allows on the `apps` namespace. **Read each file's header comment before
editing** — the full rationale (and past incidents) lives there.

## Files

- `00-namespace.yaml` — the `apps` namespace (`linkerd.io/inject: enabled`).
- `00-apps-namespace-isolation.yaml` — default-deny **ingress** + allows (intra-ns; trusted cross-ns
  from kube-system/Traefik + observability to **non-DB** pods).
- `01-apps-egress-isolation.yaml` — default-deny **egress** + allows (DNS, linkerd CP, intra-ns,
  kube-apiserver, internet-except-cluster/metadata).
- `02-db-metrics-ingress.yaml` — lets observability scrape the DB exporter sidecars.
- `20-argocd-isolation.yaml` — argocd namespace.

## Load-bearing gotchas (breaking these fails silently → outage or open hole)

- **linkerd port 4143**: meshed→meshed traffic has its target port replaced with the proxy inbound
  port **4143**. A policy allowing traffic to a meshed pod MUST allow 4143, not just the app port —
  allowing only 9187/9121 → scrape target DOWN / 504. See `02-db-metrics-ingress.yaml` header.
- **The DB list is duplicated**: `00-apps-namespace-isolation.yaml` (the `app NotIn […]`
  trusted-cross-ns selector) and `02-db-metrics-ingress.yaml` (the `app In […]` metrics selector).
  **A new `*-postgres`/`*-redis` must be added to BOTH** — miss one and its exporter scrape fails
  closed, or the data tier becomes reachable from infra namespaces.
- Egress default-deny **fails closed**: a new app needing an un-listed destination is an outage until
  you add the allow.

<!-- init-deep: generated 2026-07-11 from sha=f3d182c -->
