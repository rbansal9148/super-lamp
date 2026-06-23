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

# Usage source for the sizing checks (oversized-limit, under-request).
# Prefer VictoriaMetrics PEAK (max working_set over a window) over instantaneous
# `kubectl top`: spiky workloads idle low between bursts, so `top` under-reports and
# the sizing checks false-positive (zilean idles ~114Mi but peaks ~800Mi → looked 18×
# oversized vs a 2Gi limit that's actually right). VM is reached via the apiserver
# service-proxy (works wherever kubectl does — no ClusterIP routing/port-forward/exec).
# Falls back to `kubectl top`, then to overcommit-only, if VM is unreachable.
# Set USE_VM_PEAK=0 to force the old instantaneous-top behaviour.
: "${USE_VM_PEAK:=1}"
: "${VM_PEAK_METRIC:=k8s.pod.memory.working_set}"   # per-pod working set (OTLP/kubeletstats)
: "${VM_PEAK_WINDOW:=30d}"                           # max_over_time lookback — 30d captures monthly
                                                     # peaks (e.g. import bursts); VMSingle keeps 3mo.
# Peak is aggregated by WORKLOAD (not per pod), so a spike on a prior pod survives a
# rollover: the node collector's k8sattributes processor stamps k8s.deployment.name
# (authoritative) and the check folds historical samples onto the same workload key by
# pod-name derivation until the label has filled the window. This closed the zilean
# rollover blind-spot (an ~800Mi import burst on a since-replaced pod that a per-pod peak
# missed — it then read 2Gi as 12× oversized and hid a real under-request).
: "${VM_NAMESPACE:=observability}"
: "${VM_SERVICE:=vmsingle-obs}"
: "${VM_PORT:=8428}"

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

# --- hostPath durability (08-hostpath-durability.sh) -------------------------
# The largest irreplaceable data lives on raw hostPath (no PV/reclaim guard), invisible
# to the PVC-scoped check 04. HOSTPATH_ALLOW skips system mounts that are NOT data — the
# node collector's read-only /var/log/pods etc — so they aren't permanent-noise findings.
# HOSTPATH_CRITICAL is the RESTORE.md set: a critical path that drifts out of the live
# cluster (renamed/unmounted) is the silent-orphan case → HIGH.
: "${HOSTPATH_ALLOW:=^/var/(log|lib)/|^/run/|^/sys/|^/proc/|^/dev/|^/etc/}"
: "${HOSTPATH_CRITICAL:=$(cat <<'EOF'
/opt/docker/data/prowlarr/db
/opt/docker/data/bitmagnet/db
/opt/docker/data/immich/library
/opt/docker/data/calibre-web-automated/calibre-library
/opt/docker/data/stremthru/db
EOF
)}"

# --- CPU allocation (10-cpu-allocation.sh) -----------------------------------
# CPU is COMPRESSIBLE: over-limit means CFS throttling (latency), not an OOM kill, so
# severities are deliberately gentler than memory. The CFS throttle metric
# (container_cpu_cfs_throttled_periods_total) is NOT scraped here, so "limit set too low
# vs sustained 30d peak demand" — a config-sizing-at-rest fact — is the one CPU signal
# that falls in NEITHER the audit nor an alarm. Sourced from the same VM peak path as 01.
# k8s.pod.cpu.usage is an OTLP utilization GAUGE in CORES → max_over_time directly (no rate()).
: "${CPU_VM_METRIC:=k8s.pod.cpu.usage}"
: "${CPU_LIMIT_OVERCOMMIT_PCT_INFO:=1500}"  # sum(cpu limits)/allocatable — LOW-info only above this
                                            # (compressible: throttles, doesn't OOM; high ratio is normal)
: "${CPU_UNDERLIMIT_PEAK_RATIO:=0.9}"       # 30d-peak ≥ ratio×limit → riding the limit, likely throttling
: "${CPU_UNDERLIMIT_MAX_LIMIT_M:=2000}"     # …and limit < this many millicores (big-limit pods self-absorb)

# --- NetworkPolicy DB coverage (09-netpol-db-coverage.sh) --------------------
# The apps cross-ns policy excludes DB pods via a hand-maintained NotIn list that FAILS
# OPEN — a new *-postgres/*-redis not added to it is silently reachable. Drift detector.
: "${NETPOL_DB_NS:=apps}"
: "${NETPOL_DB_NAME:=apps-allow-trusted-cross-ns}"
: "${NETPOL_DB_LABEL_PATTERN:=postgres|redis|valkey|mariadb|mysql|mongo}"

# Backup CronJobs whose suspension = "scheduled backups are silently NOT running".
# Name-matched (case-insensitive) so a new backup job is covered without per-job config.
: "${BACKUP_CRONJOB_PATTERN:=backup|restic|dump|borg|velero|pg_dump|pgdump}"

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
       USE_VM_PEAK VM_PEAK_METRIC VM_PEAK_WINDOW VM_NAMESPACE VM_SERVICE VM_PORT \
       IMAGE_PIN_SKIP_CONTAINERS GITOPS_DIR \
       AUTH_PORTAL_HOST PUBLIC_ENDPOINT_PROBES PUBLIC_ENDPOINT_PROBE_TIMEOUT \
       HOSTPATH_ALLOW HOSTPATH_CRITICAL \
       NETPOL_DB_NS NETPOL_DB_NAME NETPOL_DB_LABEL_PATTERN \
       CPU_VM_METRIC CPU_LIMIT_OVERCOMMIT_PCT_INFO CPU_UNDERLIMIT_PEAK_RATIO CPU_UNDERLIMIT_MAX_LIMIT_M \
       BACKUP_CRONJOB_PATTERN
