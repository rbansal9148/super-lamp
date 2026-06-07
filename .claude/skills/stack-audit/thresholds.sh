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
: "${MEM_LIMIT_OVERCOMMIT_PCT_WARN:=150}"   # sum(mem limits) / node allocatable %
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
