#!/bin/bash
# Resource allocation audit (k8s). The cluster is a SINGLE swapless k3s node, so
# memory is the scarce, non-compressible resource: if pods burst toward their limits
# at once the node OOM-kills. This check surfaces the SIZING-QUALITY findings that are
# NOT alarm-shaped (over-provisioning never "fires" — nothing is wrong right now; the
# OOM consequence is already covered by the pod-oomkilled alarm). It reports:
#   1. node-wide memory-limit overcommit ratio   (sum of limits vs allocatable)
#   2. grossly oversized limits                   (limit >> live usage → wasted headroom)
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
kubectl top pods -A --no-headers 2>/dev/null > "$TMPD/top.txt"   # may be empty if metrics-server down

TMPD="$TMPD" python3 - <<'PY'
import json, os

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

# live per-pod memory usage (Mi) from `kubectl top`
usage = {}
for line in (_read("top.txt")).splitlines():
    p = line.split()
    if len(p) >= 4:
        ns, name, _cpu, mem = p[0], p[1], p[2], p[3]
        m = parse_mem(mem)
        if m is not None: usage[(ns, name)] = m

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
for pod in pods:
    ns   = pod.get("metadata", {}).get("namespace", "")
    name = pod.get("metadata", {}).get("name", "")
    if ns not in OWNED_NS: continue
    if pod.get("status", {}).get("phase") != "Running": continue
    containers = pod.get("spec", {}).get("containers", [])
    sum_req = sum((parse_mem((c.get("resources", {}).get("requests") or {}).get("memory")) or 0.0) for c in containers)
    sum_lim = sum((parse_mem((c.get("resources", {}).get("limits")   or {}).get("memory")) or 0.0) for c in containers)
    live    = usage.get((ns, name))

    # 4. missing requests / limits (per container)
    for c in containers:
        r = (c.get("resources", {}).get("requests") or {}).get("memory")
        l = (c.get("resources", {}).get("limits")   or {}).get("memory")
        cn = c.get("name", "?")
        if r is None:
            print(f"MED|resource/missing-request|{ns}/{name} container {cn} has NO memory request — scheduler can't account for it, schedules blind|set resources.requests.memory in its manifest")
        if l is None:
            print(f"MED|resource/missing-limit|{ns}/{name} container {cn} has NO memory limit — can balloon and OOM neighbours on the shared node|set resources.limits.memory in its manifest")

    if live is None: continue
    # 2. oversized limit
    if sum_lim >= OVERSIZE_FLOOR_MI and sum_lim >= OVERSIZE_RATIO * max(live, 1):
        print(f"LOW|resource/oversized-limit|{ns}/{name} memory limit {fmt(sum_lim)} is {sum_lim/max(live,1):.0f}× live usage {fmt(live)} — reclaim headroom, lowers overcommit|right-size limits.memory toward ~2× steady-state in its manifest")
    # 3. under-requested
    if sum_req > 0 and live >= UNDERREQ_FLOOR_MI and live >= UNDERREQ_RATIO * sum_req:
        print(f"MED|resource/under-request|{ns}/{name} uses {fmt(live)} but requests only {fmt(sum_req)} ({live/sum_req:.1f}× over request) — scheduler undercounts real demand|raise requests.memory toward observed usage in its manifest")
PY
