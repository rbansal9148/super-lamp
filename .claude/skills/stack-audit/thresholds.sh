# Single source of truth for all audit thresholds (k8s edition).
# Sourced by every check script. Override via env vars before invoking audit.sh.
#
# History: this stack ran on Docker Compose until Jun 2026; it now runs entirely on
# k3s/ArgoCD. The Docker-era thresholds (container restart loops, .env shadowing, redis
# hit-rate-per-container, pg deep-stat knobs) were removed with the checks that used them.
# Most former runtime checks are now continuous Grafana alarms (see
# gitops/manifests/observability/alerts/), not point-in-time audit thresholds.

# --- Namespaces the operator OWNS (editable manifests) -----------------------
# Sizing/probe/image checks only fire here; third-party Helm installs (argocd,
# cert-manager, kube-system) are excluded as un-actionable noise.
: "${RESOURCE_OWNED_NAMESPACES:=apps observability}"

# --- Resource allocation (01-resource-allocation.sh) -------------------------
# Single swapless node → memory is the scarce, non-compressible resource.
# WARN raised 150→200 (Jun 2026): with 30+ workloads peak-sized on a 21.4Gi node,
# limit-overcommit sits ~184% by design — peaks don't coincide, and the real
# coincident-peak OOM risk is covered by the pod-oomkilled alarm, not this check.
# 150% produced a permanent false-HIGH; 200% flags genuine drift above the
# accepted density. CRIT 250% (node-OOM-likely) unchanged.
: "${MEM_LIMIT_OVERCOMMIT_PCT_WARN:=200}"   # sum(mem limits) / node allocatable %
: "${MEM_LIMIT_OVERCOMMIT_PCT_CRIT:=250}"
: "${MEM_LIMIT_OVERSIZE_RATIO:=8}"          # limit ≥ N× live usage → oversized
: "${MEM_LIMIT_OVERSIZE_FLOOR_MI:=1024}"    # …and limit ≥ this many Mi (ignore tiny pods)
: "${MEM_REQUEST_UNDER_RATIO:=1.5}"         # usage ≥ N× request → under-requested
: "${MEM_REQUEST_UNDER_FLOOR_MI:=256}"      # …and usage ≥ this many Mi

# --- Audit orchestration -----------------------------------------------------
# Per-check wall-clock budget. kubectl round-trips are the slow part; a hung
# api-server shouldn't wedge the whole audit.
: "${CHECK_TIMEOUT_SECS:=20}"
: "${CHECK_TIMEOUT_SECS_DEEP:=60}"

# --- Image pinning (02-image-pins.sh) ----------------------------------------
# Mesh-injected sidecars (Linkerd proxy/init) are added by the proxy-injector
# webhook, not declared in any workload manifest — their image is pinned ONCE at
# the Linkerd control-plane proxy version, not per-pod. Flagging them per-workload
# is un-actionable noise (92 of 123 pin findings, Jun 2026), so skip by container
# name. Mesh proxy pinning is a linkerd-config concern, out of this audit's
# per-workload scope.
: "${IMAGE_PIN_SKIP_CONTAINERS:=linkerd-proxy linkerd-init}"

# --- GitOps source tree (06-alert-delivery.sh) -------------------------------
# Static checks read desired-state manifests, not the live cluster.
: "${GITOPS_DIR:=/opt/docker/gitops}"

# --- Public-endpoint auth gating (07-public-endpoints.sh) --------------------
# Some services serve non-browser clients (Stremio addons, APIs) whose client
# entrypoints MUST stay reachable without an interactive SSO session. The
# aiostreams playback outage (Jun 2026) was exactly this: a forward-auth
# middleware silently swallowed /api/v1/debrid/playback, so players got the
# Authelia login page (HTML) instead of a stream and failed with "unrecognized
# format". No metric catches it — the app is Running/Ready; only the client sees
# the 302. The probe uses a bogus-but-prefix-matching path so it tests the
# ROUTING decision (auth middleware applied?) without needing a valid signed URL.
# Each entry: "host<space>path" — path SHOULD resolve WITHOUT redirect to the
# auth portal. A redirect to $AUTH_PORTAL_HOST = the gate is mis-applied.
: "${AUTH_PORTAL_HOST:=auth.my-blue-car.work}"
: "${PUBLIC_ENDPOINT_PROBES:=$(cat <<'EOF'
aiostreams.my-blue-car.work /api/v1/debrid/playback/x/y/z/probe.mkv
comet.my-blue-car.work /manifest.json
EOF
)}"
: "${PUBLIC_ENDPOINT_PROBE_TIMEOUT:=10}"

# Export everything: bash checks see these via sourcing, but child processes
# (the Python check 01-resource-allocation.sh, and any future awk/python check)
# only inherit EXPORTED vars. Without this, `:=` set the shell var but not the
# environment, so threshold overrides — via this file OR `VAR=x bash audit.sh` —
# silently never reached the Python checks (they fell back to hardcoded defaults).
export RESOURCE_OWNED_NAMESPACES \
       MEM_LIMIT_OVERCOMMIT_PCT_WARN MEM_LIMIT_OVERCOMMIT_PCT_CRIT \
       MEM_LIMIT_OVERSIZE_RATIO MEM_LIMIT_OVERSIZE_FLOOR_MI \
       MEM_REQUEST_UNDER_RATIO MEM_REQUEST_UNDER_FLOOR_MI \
       CHECK_TIMEOUT_SECS CHECK_TIMEOUT_SECS_DEEP \
       IMAGE_PIN_SKIP_CONTAINERS GITOPS_DIR \
       AUTH_PORTAL_HOST PUBLIC_ENDPOINT_PROBES PUBLIC_ENDPOINT_PROBE_TIMEOUT
