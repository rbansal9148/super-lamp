#!/bin/bash
# CPU allocation audit (k8s). Companion to 01 (memory). CPU is COMPRESSIBLE — over-limit
# means CFS throttling (added latency), not an OOM kill — so this check is deliberately
# gentler than 01. It exists because the throttle metric is NOT scraped on this cluster, so
# "limit set too low vs sustained 30d-peak demand" is the one CPU sizing-at-rest fact that
# falls in NEITHER the audit nor a Grafana alarm. Reports:
#   a. node-wide CPU-limit overcommit         (LOW-info only above a high ratio — normal for CPU)
#   b. under-limited workloads                 (30d peak rides the limit → likely throttling)  MED
#   c. containers missing CPU requests/limits  (unbounded CPU on a shared node)                 LOW
#
# Sizing source is the SAME VM peak path as 01 (apiserver service-proxy → VictoriaMetrics),
# but the metric is k8s.pod.cpu.usage — an OTLP utilization GAUGE in CORES, so max_over_time
# is taken directly (no rate(), unlike a counter). Falls back to overcommit-only if VM is
# unreachable (no instantaneous CPU fallback — a point-in-time core reading is meaningless
# for sizing). Scoped to owned namespaces for b/c; overcommit (a) is node-wide.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|resource/cpu|kubectl not on PATH — CPU audit skipped|install kubectl / check KUBECONFIG"; exit 0; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
kubectl get pods -A -o json 2>/dev/null > "$TMPD/pods.json" || { echo "LOW|resource/cpu|cannot reach cluster (kubectl get pods failed)|check KUBECONFIG / cluster reachability"; exit 0; }
[ -s "$TMPD/pods.json" ] || { echo "LOW|resource/cpu|cannot reach cluster (kubectl get pods failed)|check KUBECONFIG / cluster reachability"; exit 0; }
kubectl get nodes -o json 2>/dev/null > "$TMPD/nodes.json"

# CPU 30d peak per pod (cores) via the same VM service-proxy path 01 uses.
USAGE_SRC="none"
if [ "${USE_VM_PEAK:-1}" = "1" ] && command -v jq >/dev/null 2>&1; then
  _q="max_over_time({__name__=\"${CPU_VM_METRIC:-k8s.pod.cpu.usage}\"}[${VM_PEAK_WINDOW:-30d}])"
  _enc=$(jq -rn --arg q "$_q" '$q|@uri' 2>/dev/null)
  if [ -n "$_enc" ]; then
    kubectl get --raw "/api/v1/namespaces/${VM_NAMESPACE:-observability}/services/${VM_SERVICE:-vmsingle-obs}:${VM_PORT:-8428}/proxy/api/v1/query?query=${_enc}" 2>/dev/null > "$TMPD/vm_cpu.json" || true
    if [ -s "$TMPD/vm_cpu.json" ] && jq -e '.status=="success" and (.data.result|length>0)' "$TMPD/vm_cpu.json" >/dev/null 2>&1; then
      USAGE_SRC="vm-peak"
    fi
  fi
fi
# p95 companion — separates SUSTAINED throttling (p95 rides the limit) from a one-off burst
# (only MAX touches it). Only meaningful with the VM peak source.
if [ "$USAGE_SRC" = "vm-peak" ]; then
  _q95="quantile_over_time(0.95,{__name__=\"${CPU_VM_METRIC:-k8s.pod.cpu.usage}\"}[${VM_PEAK_WINDOW:-30d}])"
  _enc95=$(jq -rn --arg q "$_q95" '$q|@uri' 2>/dev/null)
  [ -n "$_enc95" ] && kubectl get --raw "/api/v1/namespaces/${VM_NAMESPACE:-observability}/services/${VM_SERVICE:-vmsingle-obs}:${VM_PORT:-8428}/proxy/api/v1/query?query=${_enc95}" 2>/dev/null > "$TMPD/vm_cpu_p95.json" || true
fi

TMPD="$TMPD" USAGE_SRC="$USAGE_SRC" python3 - <<'PY'
import json, os, re

def workload_key(pod_name):
    # Same workload folding as 01 — a pre-rollover peak on a since-replaced pod still counts.
    m = re.match(r'^(.*)-\d{1,3}$', pod_name)
    if m: return m.group(1)
    m = re.match(r'^(.*)-[a-z0-9]+-[a-z0-9]+$', pod_name)
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

OWNED_NS         = set((os.environ.get("RESOURCE_OWNED_NAMESPACES") or "apps observability").split())
OVERCOMMIT_INFO  = envf("CPU_LIMIT_OVERCOMMIT_PCT_INFO", 1500)
UNDERLIMIT_RATIO = envf("CPU_UNDERLIMIT_PEAK_RATIO", 0.9)
UNDERLIMIT_MAX_M = envf("CPU_UNDERLIMIT_MAX_LIMIT_M", 2000)
SUSTAINED_RATIO  = envf("CPU_UNDERLIMIT_SUSTAINED_RATIO", 0.7)

def parse_cpu(s):
    # → millicores. "100m"=100, "1"=1000, "0.5"=500, "2"=2000.
    if s is None: return None
    s = str(s).strip()
    if s in ("", "0"): return 0.0
    try:
        if s.endswith("m"): return float(s[:-1])
        if s.endswith("n"): return float(s[:-1]) / 1_000_000   # nanocores (allocatable sometimes)
        if s.endswith("u"): return float(s[:-1]) / 1000          # microcores
        return float(s) * 1000
    except ValueError:
        return None

pods  = json.loads(_read("pods.json")  or "{}").get("items", [])
nodes = json.loads(_read("nodes.json") or "{}").get("items", [])

# Per-workload CPU 30d peak in millicores (VM gauge value is in cores → ×1000).
usage = {}
if os.environ.get("USAGE_SRC") == "vm-peak":
    vm = json.loads(_read("vm_cpu.json") or "{}")
    for r in vm.get("data", {}).get("result", []):
        m = r.get("metric", {})
        ns, name = m.get("k8s.namespace.name"), m.get("k8s.pod.name")
        if not ns or not name: continue
        wl = (m.get("k8s.deployment.name") or m.get("k8s.statefulset.name")
              or m.get("k8s.daemonset.name") or workload_key(name))
        try: mc = float(r.get("value", [None, None])[1]) * 1000   # cores → millicores
        except (TypeError, ValueError, IndexError): continue
        if mc > usage.get((ns, wl), 0.0): usage[(ns, wl)] = mc
    usage_label = f"{os.environ.get('VM_PEAK_WINDOW', '30d')} workload-peak"
else:
    usage_label = None   # no usage source → emit overcommit + missing only

# p95 per workload (millicores) — the SUSTAINED-throttle signal; VM peak source only.
usage_p95 = {}
if os.environ.get("USAGE_SRC") == "vm-peak":
    vmp = json.loads(_read("vm_cpu_p95.json") or "{}")
    for r in vmp.get("data", {}).get("result", []):
        m = r.get("metric", {})
        ns, name = m.get("k8s.namespace.name"), m.get("k8s.pod.name")
        if not ns or not name: continue
        wl = (m.get("k8s.deployment.name") or m.get("k8s.statefulset.name")
              or m.get("k8s.daemonset.name") or workload_key(name))
        try: mc = float(r.get("value", [None, None])[1]) * 1000
        except (TypeError, ValueError, IndexError): continue
        if mc > usage_p95.get((ns, wl), 0.0): usage_p95[(ns, wl)] = mc

def fmt(mc):
    return f"{mc/1000:.2f} cores" if mc >= 1000 else f"{int(mc)}m"

# ── a. node-wide CPU-limit overcommit (LOW-info, high gate; CPU throttles, doesn't OOM) ──
alloc_m = 0.0
for n in nodes:
    a = parse_cpu(n.get("status", {}).get("allocatable", {}).get("cpu"))
    alloc_m += a or 0.0
sum_limit_m = 0.0
for pod in pods:
    if pod.get("status", {}).get("phase") not in ("Running", "Pending"): continue
    for c in pod.get("spec", {}).get("containers", []):
        sum_limit_m += parse_cpu((c.get("resources", {}).get("limits") or {}).get("cpu")) or 0.0
if alloc_m > 0 and sum_limit_m > 0:
    pct = round(sum_limit_m / alloc_m * 100)
    if pct >= OVERCOMMIT_INFO:
        print(f"LOW|resource/cpu-overcommit|CPU limits sum to {pct}% of node allocatable ({fmt(sum_limit_m)} / {fmt(alloc_m)}) — compressible, so this throttles rather than OOMs, but a very high ratio means limits are nominal|review whether per-workload CPU limits reflect real ceilings")

# ── b/c. per-workload sizing, owned namespaces only ──
seen_wl = set()
for pod in pods:
    ns   = pod.get("metadata", {}).get("namespace", "")
    name = pod.get("metadata", {}).get("name", "")
    if ns not in OWNED_NS: continue
    if pod.get("status", {}).get("phase") != "Running": continue
    containers = pod.get("spec", {}).get("containers", [])

    # c. missing CPU request/limit (per container)
    for c in containers:
        r = (c.get("resources", {}).get("requests") or {}).get("cpu")
        l = (c.get("resources", {}).get("limits")   or {}).get("cpu")
        cn = c.get("name", "?")
        if l is None:
            print(f"LOW|resource/cpu-missing-limit|{ns}/{name} container {cn} has NO CPU limit — can monopolise cores under load on the shared node|set resources.limits.cpu in its manifest")
        if r is None:
            print(f"LOW|resource/cpu-missing-request|{ns}/{name} container {cn} has NO CPU request — scheduler can't account for its CPU demand|set resources.requests.cpu in its manifest")

    if usage_label is None: continue
    wl   = workload_key(name)
    if (ns, wl) in seen_wl: continue
    live = usage.get((ns, wl))
    if live is None: continue
    seen_wl.add((ns, wl))
    sum_lim_m = sum((parse_cpu((c.get("resources", {}).get("limits") or {}).get("cpu")) or 0.0) for c in containers)

    # b. under-limited: peak rides the limit AND the limit is small enough that throttling bites.
    # Two tiers by what the 30d-MAX gauge actually PROVES (a max_over_time on a spiky gauge
    # overstates *sustained* throttling — same single-spike caveat as 01's memory MAX):
    #   ≥100% of limit  → the gauge was read AT/OVER the cap, so CFS throttling demonstrably
    #                     occurred at least at peak → MED (raise/remove the limit).
    #   ratio–100%      → riding close; MAY throttle on a burst we didn't sample → LOW.
    # No HIGH: CPU is compressible, so the worst case is latency, never an OOM/outage.
    if sum_lim_m > 0 and sum_lim_m < UNDERLIMIT_MAX_M and live >= UNDERLIMIT_RATIO * sum_lim_m:
        pctlim = live / sum_lim_m * 100
        sev = "MED" if live >= sum_lim_m else "LOW"
        tail = "throttled at peak (gauge read at/over the cap)" if sev == "MED" else "rides close to its limit — may throttle on an unsampled burst"
        print(f"{sev}|resource/cpu-under-limit|{ns}/{wl} {usage_label} {fmt(live)} vs CPU limit {fmt(sum_lim_m)} ({pctlim:.0f}%) — {tail}|raise limits.cpu (or remove it) in its manifest")

    # sustained throttle: p95 (not just the MAX spike) rides the limit → chronic, not a one-off.
    # Distinct MED even when MAX-under-limit stayed LOW/silent; suppressed when MAX already hit
    # MED (>=100%) so the two don't double-report the same workload.
    p95 = usage_p95.get((ns, wl))
    if (p95 is not None and sum_lim_m > 0 and sum_lim_m < UNDERLIMIT_MAX_M
            and p95 >= SUSTAINED_RATIO * sum_lim_m
            and not (live is not None and live >= sum_lim_m)):
        print(f"MED|resource/cpu-sustained-limit|{ns}/{wl} p95 {fmt(p95)} is {p95/sum_lim_m*100:.0f}% of CPU limit {fmt(sum_lim_m)} (30d-MAX {fmt(live)}) — throttling is SUSTAINED across the window, not a one-off burst|raise limits.cpu in its manifest")
PY
