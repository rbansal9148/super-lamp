# k3s-overrides — custom HelmChartConfigs under GitOps

k3s installs some components (Traefik, CoreDNS, …) via its own `HelmChart` CRs and
applies any manifest dropped in `/var/lib/rancher/k3s/server/manifests/` on the server
node. Customisations to those components are expressed as `HelmChartConfig` objects.

By default those live **only on the host** — invisible to git and prone to silent
drift (the live object can be `kubectl`-edited beyond what the host file says, and a
k3s restart then reverts it). This directory brings the **custom** ones under ArgoCD so
they are reviewed, versioned, and self-healed.

## What belongs here

- ✅ **Custom** `HelmChartConfig` overrides you authored (currently: `traefik`).
- ❌ **k3s-bundled** manifests (`coredns.yaml`, `local-storage.yaml`, `ccm.yaml`,
  `metrics-server/`, `runtimes.yaml`, `rolebindings.yaml`). k3s **owns and overwrites
  these on every upgrade** — mirroring them into git means fighting k3s forever. Leave
  them on the host.

## How it works

ArgoCD app `apps/k3s-overrides.yaml` syncs this dir to `kube-system`. k3s's
helm-controller watches `HelmChartConfig` objects **regardless of who created them**, so
an ArgoCD-owned HCC patches the Traefik chart exactly as the host addon did. Change flow
is now pure GitOps: edit here → commit → ArgoCD applies the HCC → helm-controller re-runs
the chart → Traefik pod rolls.

## One-time cutover (done 2026-06-14)

The Traefik HCC was created by k3s from the host file
`/var/lib/rancher/k3s/server/manifests/traefik-ports.yaml`, so the live object carried
`objectset.rio.cattle.io/*` annotations. Naively deleting the host file would make k3s
garbage-collect the HCC → Traefik briefly re-renders to chart defaults (real-IP / headers
/ ports revert) → ingress flap. The flap-free cutover, in order:

```sh
# 1. Let ArgoCD adopt the object and apply the +resources change first.
kubectl -n argocd annotate applications.argoproj.io/k3s-overrides \
  argocd.argoproj.io/refresh=hard --overwrite
#    (wait until `kubectl -n kube-system get helmchartconfig traefik` shows ArgoCD-synced)

# 2. Orphan the HCC from k3s's addon so deleting the host file won't GC it.
kubectl -n kube-system annotate helmchartconfig traefik \
  objectset.rio.cattle.io/id- objectset.rio.cattle.io/owner-gvk- \
  objectset.rio.cattle.io/owner-name- objectset.rio.cattle.io/owner-namespace-

# 3. Remove the host file (a backup was kept as traefik-ports.yaml.bak-20260614).
sudo rm /var/lib/rancher/k3s/server/manifests/traefik-ports.yaml
```

After this, ArgoCD is the sole owner; k3s no longer manages the object. Restore path if
ever needed: re-create the host file from `traefik-helmchartconfig.yaml` here.
