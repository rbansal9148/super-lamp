# Single source of truth for all audit thresholds.
# Sourced by every check script. Override via env vars before invoking audit.sh.

# --- System ---
: "${DISK_USED_PCT_WARN:=80}"
: "${DISK_USED_PCT_CRIT:=90}"
: "${LOAD_PER_CORE_WARN:=2.0}"
: "${CPU_STEAL_PCT_WARN:=10}"
: "${SWAP_USED_PCT_WARN:=50}"

# --- Containers ---
: "${RESTART_COUNT_WARN:=5}"
: "${RESTART_LOOP_UPTIME_MIN:=30}"   # uptime above this minutes => assume restart loop is broken
: "${CONTAINER_LOG_MB_WARN:=50}"
: "${CONTAINER_LOG_MB_CRIT:=500}"
: "${MEM_PCT_OF_CAP_WARN:=80}"
: "${MEM_PCT_OF_CAP_CRIT:=95}"
: "${FD_COUNT_WARN:=2000}"
: "${FD_COUNT_CRIT:=3500}"

# --- Postgres ---
: "${HEAP_HIT_GOOD:=95}"
: "${HEAP_HIT_WARN:=80}"
: "${HEAP_HIT_CRIT:=50}"
: "${IDX_HIT_GOOD:=95}"
: "${IDX_HIT_WARN:=85}"
# DBs smaller than this in MB get a heap_hit pass (tuning makes no perceptible diff)
: "${HEAP_HIT_DB_MIN_MB:=50}"
# Postgres restarted within this many minutes — cache still warming, demote heap_hit severity
: "${HEAP_HIT_WARMUP_MIN:=60}"
: "${IDLE_CONN_MAX_MIN:=30}"
: "${DEAD_TUP_PCT_WARN:=10}"
: "${DEAD_TUP_PCT_CRIT:=25}"
: "${AUTOVACUUM_STALE_DAYS_WARN:=7}"
: "${UNUSED_INDEX_MIN_MB:=50}"
: "${SLOW_QUERY_MEAN_MS_WARN:=1000}"
: "${SLOW_QUERY_MEAN_MS_CRIT:=5000}"

# --- Redis ---
: "${REDIS_HIT_RATE_WARN:=70}"
# Redis instances whose workload is intrinsically low-repeat (per-search
# unique torrent hashes, etc) — hit-rate finding would be noise.
: "${REDIS_HIT_RATE_ALLOW_LOW:=aiostreams_redis comet_redis libremdb_redis}"
: "${REDIS_MUST_HAVE_MAXMEMORY:=true}"
: "${REDIS_MUST_HAVE_LRU_POLICY:=true}"
: "${REDIS_NO_TTL_KEYS_WARN:=1000}"

# --- Streaming ---
# 30% used to fire; most errors trace to TorBox bulk-cache-check timeouts —
# not actionable from this stack. Raised to 40% so the alert means "really
# elevated", not "TorBox normal".
: "${AIOSTREAMS_ERROR_RATE_PCT_WARN:=40}"
: "${AIOSTREAMS_ZERO_STREAMS_PCT_WARN:=20}"
: "${COMET_P95_RESP_S_WARN:=15}"
: "${MEDIAFUSION_P95_RESP_S_WARN:=15}"
: "${STREMTHRU_BROKEN_PIPE_RATE_WARN:=5}"

# --- Bitmagnet ---
: "${BITMAGNET_DHT_INGEST_PER_HOUR_WARN:=5000}"
# Window in hours for the DHT ingest rate sample. Shorter = more responsive to config changes, less smoothing.
: "${BITMAGNET_INGEST_WINDOW_HOURS:=1}"
: "${BITMAGNET_TORRENTS_GROWTH_NET_PER_DAY:=0}"

# --- Security ---
# Ports that MUST NOT be exposed on 0.0.0.0
: "${FORBIDDEN_PUBLIC_PORTS:=5432 3306 6379 27017 8191 9091}"
# All Traefik-enabled containers must have authelia middleware
: "${REQUIRE_AUTHELIA_MIDDLEWARE:=true}"

# --- Network / VPN ---
: "${EXPECTED_VPN_REGION:=Singapore}"
: "${VPN_HEALTHCHECK_ALLOWED_STALE_S:=120}"

# --- Storage ---
# Data dirs in /opt/docker/data/ for services NOT in this allowlist will be flagged as orphan
: "${EXPECTED_DATA_DIRS:=aiostreams aiometadata authelia bitmagnet calibre-web-automated comet gluetun mediafusion prowlarr stremthru syncio searxng traefik zilean}"

# --- Postgres deep ---
: "${BLOCKING_LOCK_SECONDS_WARN:=30}"
: "${INDEX_BLOAT_MB_WARN:=500}"        # only flag bloat candidates this large
: "${INDEX_BLOAT_SCAN_RATIO_MAX:=10}"  # MB/scan threshold for "bloated"
: "${LOG_MIN_DURATION_MS_RECOMMEND:=1000}"

# --- Filesystem ---
: "${INODE_USED_PCT_WARN:=80}"
: "${INODE_USED_PCT_CRIT:=90}"

# --- Backups ---
# Path to look for pg_dump output files. Empty = skip backup check.
: "${BACKUP_DIR:=/opt/docker/backups}"
: "${BACKUP_STALE_DAYS_WARN:=2}"
: "${BACKUP_STALE_DAYS_CRIT:=7}"

# --- Security hardening ---
# Containers permitted to run as root. Two reasons a name appears here:
#   1. Truly needs root (VPN/cap_add, raw network access, etc).
#   2. Image cannot be coerced into non-root without an upstream rebuild
#      (we tried and reverted, or have a definite reason it would break).
# Re-test any name here on a major image bump — upstream may have fixed it.
: "${ALLOW_ROOT_USER:=gluetun bitmagnet_vpn traefik authelia browserless \
  bitmagnet stremthru comet shelfmark dozzle dash searxng zilean \
  prowlarr calibre-web-automated bitmagnet_prune prowlarr_history_prune}"
# Notes on the image-constrained additions (verified 2026-05-19):
#   bitmagnet                  config mount is /root/.config/bitmagnet
#   stremthru, comet           single data-dir bind-mount includes postgres pgdata
#   shelfmark                  shares calibre-web-automated lscr-style data
#   dozzle                     scratch image, no shell to drop privs
#   dash                       needs root for /proc, /sys, /:/mnt/host:ro reads
#   searxng                    image has custom user expectations
#   zilean                     image bakes /app/data as root-owned
#   prowlarr, calibre-web-*    lscr.io PUID/PGID-style: entrypoint runs as root
#                              then drops privs internally; user: bypasses that
#   *_prune sidecars           postgres images need root for entrypoint
# Containers expected to NOT be privileged
: "${PRIVILEGED_FORBIDDEN:=true}"
# Patterns for weak credentials in .env files
: "${WEAK_PW_PATTERNS:=password=password admin=admin POSTGRES_PASSWORD=postgres bitmagnet:bitmagnet prowlarr:prowlarr aiostreams:aiostreams}"
# Traefik routes that must have rate-limit middleware (admin/public endpoints)
: "${RATE_LIMIT_REQUIRED_ROUTES:=}"

# --- Streaming telemetry ---
# How many recent requests to look at for per-addon contribution analysis
: "${PER_ADDON_SAMPLE_REQUESTS:=20}"

# --- Prowlarr indexer health (check 34) ---
: "${PROWLARR_INDEXER_FAIL_RATE_WARN:=50}"
: "${PROWLARR_INDEXER_AVG_MS_WARN:=5000}"
: "${PROWLARR_INDEXER_AVG_MS_HIGH:=30000}"
: "${PROWLARR_MIN_QUERIES_FOR_STATS:=5}"

# --- Dormant data dirs (check 36) ---
: "${DORMANT_DATA_MB_WARN:=100}"
: "${DORMANT_DATA_MB_HIGH:=5000}"

# --- Modes ---
: "${MODE:=quick}"  # quick | deep
: "${OUTPUT:=md}"   # md | json
