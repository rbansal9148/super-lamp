#!/bin/bash
# Resource allocation audit (k8s). The cluster is a SINGLE swapless k3s node, so
# memory is the scarce, non-compressible resource: if pods burst toward their limits
# at once the node OOM-kills. This check surfaces the SIZING-QUALITY findings that are
# NOT alarm-shaped (over-provisioning never "fires" — nothing is wrong right now; the
# OOM consequence is already covered by the pod-oomkilled alarm). It reports:
#   1. node-wide memory-limit overcommit ratio   (sum of limits vs allocatable)
#   2. grossly oversized limits                   (limit >> peak usage → wasted headroom)
#   3. under-requested pods                        (usage >> request → scheduler is blind)
#   4. containers missing requests/limits          (best-effort/unbounded on a shared node)
#
# Sizing findings (2,3,4) are scoped to namespaces the operator OWNS (apps,
# observability) — flagging third-party Helm installs (argocd, cert-manager, kube-system)
# is noise the operator can't fix without upstream values. Overcommit (1) is node-wide
# because every pod contributes to the OOM risk regardless of who ships it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

command -v kubectl >/dev/null 2>&1 || { echo "LOW|resource/alloc|kubectl not on PATH — resource audit skipped|install kubectl / check KUBECONFIG"; exit 0; }

# Whole-cluster JSON is far larger than ARG_MAX, so stage it in temp files and pass
# the (short) paths — passing the JSON itself as an env var fails "Argument list too long".
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
kubectl get pods -A -o json 2>/dev/null > "$TMPD/pods.json" || { echo "LOW|resource/alloc|cannot reach cluster (kubectl get pods failed)|check KUBECONFIG / cluster reachability"; exit 0; }
[ -s "$TMPD/pods.json" ] || { echo "LOW|resource/alloc|cannot reach cluster (kubectl get pods failed)|check KUBECONFIG / cluster reachability"; exit 0; }
kubectl get nodes -o json 2>/dev/null > "$TMPD/nodes.json"

# Per-workload memory usage for the sizing checks. Prefer VM PEAK (max working_set over a
# lookback window) over instantaneous `kubectl top`: spiky pods idle low between bursts,
# so top under-reports and the checks false-positive (zilean ~114Mi idle vs ~800Mi peak).
# VM is reached via the apiserver service-proxy → works wherever kubectl does, no
# ClusterIP routing / port-forward / exec. Fall back to `kubectl top`, then to
# overcommit-only (usage-relative findings skipped), if VM is unreachable.
# Peak is folded onto the owning WORKLOAD (k8sattributes k8s.deployment.name, with pod-name
# derivation as the bridge until the label fills the window) so a pre-rollover spike on a
# since-replaced pod still counts — this is what closed the zilean rollover blind-spot.
USAGE_SRC="none"
if [ "${USE_VM_PEAK:-1}" = "1" ] && command -v jq >/dev/null 2>&1; then
  _q="max_over_time({__name__=\"${VM_PEAK_METRIC:-k8s.pod.memory.working_set}\"}[${VM_PEAK_WINDOW:-30d}])"
  _enc=$(jq -rn --arg q "$_q" '$q|@uri' 2>/dev/null)
  if [ -n "$_enc" ]; then
    kubectl get --raw "/api/v1/namespaces/${VM_NAMESPACE:-observability}/services/${VM_SERVICE:-vmsingle-obs}:${VM_PORT:-8428}/proxy/api/v1/query?query=${_enc}" 2>/dev/null > "$TMPD/vm_peak.json" || true
    if [ -s "$TMPD/vm_peak.json" ] && jq -e '.status=="success" and (.data.result|length>0)' "$TMPD/vm_peak.json" >/dev/null 2>&1; then
      USAGE_SRC="vm-peak"
    fi
  fi
fi
if [ "$USAGE_SRC" = "none" ]; then
  kubectl top pods -A --no-headers 2>/dev/null > "$TMPD/top.txt"   # fallback: instantaneous (or empty if metrics-server down)
  [ -s "$TMPD/top.txt" ] && USAGE_SRC="kubectl-top"
fi

TMPD="$TMPD" USAGE_SRC="$USAGE_SRC" python3 - <<'PY'
import json, os, re

def workload_key(pod_name):
    # Collapse a pod name onto its owning WORKLOAD so peak usage aggregates across
    # rollovers (a restart mints a new pod name; a pre-rollover spike on the old name
    # is invisible to a per-pod peak — the zilean blind-spot). StatefulSet pods end in
    # -<ordinal>; Deployment/ReplicaSet pods end in -<rs-hash>-<pod-hash>. This mirrors
    # how the k8sattributes processor derives the workload name from the owner ref, so
    # label-tagged (new) and name-derived (historical) samples land on the same key.
    m = re.match(r'^(.*)-\d{1,3}$', pod_name)             # StatefulSet: foo-0
    if m: return m.group(1)
    m = re.match(r'^(.*)-[a-z0-9]+-[a-z0-9]+$', pod_name)  # Deployment/RS: foo-<rs>-<pod>
    if m: return m.group(1)
    return pod_name

_d = os.environ["TMPD"]
def _read(f):
    try:
        with open(os.path.join(_d, f)) as fh: return fh.read()
    except Exception: return ""

def envf(name, default):
    try: return float(os.environ.get(name, default))
    except Exception: return float(default)

OWNED_NS          = set((os.environ.get("RESOURCE_OWNED_NAMESPACES") or "apps observability").split())
OVERCOMMIT_WARN   = envf("MEM_LIMIT_OVERCOMMIT_PCT_WARN", 150)
OVERCOMMIT_CRIT   = envf("MEM_LIMIT_OVERCOMMIT_PCT_CRIT", 250)
OVERSIZE_RATIO    = envf("MEM_LIMIT_OVERSIZE_RATIO", 8)
OVERSIZE_FLOOR_MI = envf("MEM_LIMIT_OVERSIZE_FLOOR_MI", 1024)
UNDERREQ_RATIO    = envf("MEM_REQUEST_UNDER_RATIO", 1.5)
UNDERREQ_FLOOR_MI = envf("MEM_REQUEST_UNDER_FLOOR_MI", 256)

def parse_mem(s):
    if s is None: return None
    s = str(s).strip()
    if s in ("", "0"): return 0.0
    units = {"Ki":1/1024,"Mi":1,"Gi":1024,"Ti":1024*1024,
             "K":1000/1024/1024,"M":1000*1000/1024/1024,"G":1000*1000*1000/1024/1024}
    for u,f in units.items():
        if s.endswith(u):
            try: return float(s[:-len(u)])*f
            except ValueError: return None
    try: return float(s)/1024/1024
    except ValueError: return None

pods  = json.loads(_read("pods.json")  or "{}").get("items", [])
nodes = json.loads(_read("nodes.json") or "{}").get("items", [])

# per-pod memory usage (Mi): VM peak (max working_set over the window) if available,
# else instantaneous `kubectl top`. usage_label flows into the finding text so it's
# honest about which it is.
usage = {}   # (ns, workload) -> peak Mi, max across all pods that ever backed the workload
usage_src = os.environ.get("USAGE_SRC", "none")
if usage_src == "vm-peak":
    vm = json.loads(_read("vm_peak.json") or "{}")
    for r in vm.get("data", {}).get("result", []):
        m = r.get("metric", {})
        ns, name = m.get("k8s.namespace.name"), m.get("k8s.pod.name")
        if not ns or not name: continue
        # Authoritative workload label (k8sattributes processor) once it accumulates;
        # until then derive from the pod name so historical pre-rollover pods aggregate
        # onto the same workload key.
        wl = (m.get("k8s.deployment.name") or m.get("k8s.statefulset.name")
              or m.get("k8s.daemonset.name") or workload_key(name))
        try: mi = float(r.get("value", [None, None])[1]) / 1024 / 1024   # OTLP bytes → Mi
        except (TypeError, ValueError, IndexError): continue
        if mi > usage.get((ns, wl), 0.0): usage[(ns, wl)] = mi
    usage_label = f"{os.environ.get('VM_PEAK_WINDOW', '30d')} workload-peak"
else:
    for line in (_read("top.txt")).splitlines():
        p = line.split()
        if len(p) >= 4:
            ns, name, _cpu, mem = p[0], p[1], p[2], p[3]
            m = parse_mem(mem)
            if m is not None:
                wl = workload_key(name)
                if m > usage.get((ns, wl), 0.0): usage[(ns, wl)] = m
    usage_label = "live usage"

def fmt(mi):
    return f"{mi/1024:.1f}Gi" if mi >= 1024 else f"{int(mi)}Mi"

# ── 1. node-wide memory-limit overcommit ──
alloc_mi = 0.0
for n in nodes:
    alloc_mi += parse_mem(n.get("status", {}).get("allocatable", {}).get("memory")) or 0.0
sum_limit_mi = 0.0
for pod in pods:
    if pod.get("status", {}).get("phase") not in ("Running", "Pending"): continue
    for c in pod.get("spec", {}).get("containers", []):
        sum_limit_mi += parse_mem((c.get("resources", {}).get("limits") or {}).get("memory")) or 0.0
if alloc_mi > 0 and sum_limit_mi > 0:
    pct = sum_limit_mi / alloc_mi * 100
    if pct >= OVERCOMMIT_CRIT:
        print(f"CRIT|resource/overcommit|memory limits sum to {pct:.0f}% of node allocatable ({fmt(sum_limit_mi)} / {fmt(alloc_mi)}) on a single swapless node — concurrent bursts OOM the node|kubectl top node; trim oversized limits below")
    elif pct >= OVERCOMMIT_WARN:
        print(f"HIGH|resource/overcommit|memory limits sum to {pct:.0f}% of node allocatable ({fmt(sum_limit_mi)} / {fmt(alloc_mi)}) — no swap safety net|kubectl top node; trim oversized limits below")

# ── 2/3/4. per-pod sizing, owned namespaces only ──
seen_wl = set()   # findings 2/3 are workload-scoped (peak aggregates all replicas) → emit once
for pod in pods:
    ns   = pod.get("metadata", {}).get("namespace", "")
    name = pod.get("metadata", {}).get("name", "")
    if ns not in OWNED_NS: continue
    if pod.get("status", {}).get("phase") != "Running": continue
    containers = pod.get("spec", {}).get("containers", [])
    sum_req = sum((parse_mem((c.get("resources", {}).get("requests") or {}).get("memory")) or 0.0) for c in containers)
    sum_lim = sum((parse_mem((c.get("resources", {}).get("limits")   or {}).get("memory")) or 0.0) for c in containers)
    wl   = workload_key(name)
    live = usage.get((ns, wl))

    # 4. missing requests / limits (per container) — per-pod, not workload-deduped
    for c in containers:
        r = (c.get("resources", {}).get("requests") or {}).get("memory")
        l = (c.get("resources", {}).get("limits")   or {}).get("memory")
        cn = c.get("name", "?")
        if r is None:
            print(f"MED|resource/missing-request|{ns}/{name} container {cn} has NO memory request — scheduler can't account for it, schedules blind|set resources.requests.memory in its manifest")
        if l is None:
            print(f"MED|resource/missing-limit|{ns}/{name} container {cn} has NO memory limit — can balloon and OOM neighbours on the shared node|set resources.limits.memory in its manifest")

    if live is None or (ns, wl) in seen_wl: continue
    seen_wl.add((ns, wl))
    # 2. oversized limit
    if sum_lim >= OVERSIZE_FLOOR_MI and sum_lim >= OVERSIZE_RATIO * max(live, 1):
        print(f"LOW|resource/oversized-limit|{ns}/{wl} memory limit {fmt(sum_lim)} is {sum_lim/max(live,1):.0f}× {usage_label} {fmt(live)} — reclaim headroom, lowers overcommit|right-size limits.memory toward ~2× steady-state in its manifest")
    # 3. under-requested
    if sum_req > 0 and live >= UNDERREQ_FLOOR_MI and live >= UNDERREQ_RATIO * sum_req:
        print(f"MED|resource/under-request|{ns}/{wl} {usage_label} {fmt(live)} vs request {fmt(sum_req)} ({live/sum_req:.1f}× over request) — scheduler undercounts real demand|raise requests.memory toward observed usage in its manifest")
PY
