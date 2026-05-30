#!/bin/bash
# orphan_scan.sh — off-peak measurement of stremthru torrent_stream orphans.
#
# The orphan anti-join (torrent_stream rows with no matching torrent_info) is an
# exact count over millions of rows via a merge anti-join on both PKs — already
# optimally planned, just large (60s+ and growing). Running it inline in every
# audit is too slow, so this job measures it off-peak with a generous timeout
# and writes the result to a small state file. Check 29 reads that cached value,
# keeping the audit fast and deterministic.
#
# Flags:
#   --dry-run   print what would run; measure nothing, write nothing.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # cron-safe

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
. "$SKILL_DIR/tools/lib/lock.sh"

STATE="$SKILL_DIR/.orphan_scan.json"
LOG="$SKILL_DIR/orphan_scan.log"
PG="stremthru_postgres"
# Generous ceiling — off-peak, no inline budget. Bounds a pathological lock-wait
# without cutting off a normal (slow) completion.
TIMEOUT_MS="${STREMTHRU_ORPHAN_SCAN_STATEMENT_TIMEOUT_MS:-600000}"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

ORPHAN_Q="SELECT count(*) FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);"

if [ "$DRY" = 1 ]; then
  echo "[dry-run] would acquire lock, then run against $PG (timeout ${TIMEOUT_MS}ms):"
  echo "  $ORPHAN_Q"
  echo "[dry-run] would write result to $STATE"
  exit 0
fi

acquire_lock "/tmp/stack-audit-orphan-scan.lock"

# Skip cleanly if the DB isn't up — leave the previous result in place.
if ! docker ps --format '{{.Names}}' | grep -q "^${PG}$"; then
  log "skip: $PG not running"
  exit 0
fi

log "=== orphan_scan start (timeout=${TIMEOUT_MS}ms) ==="
ts=$(date -u +%FT%TZ); t0=$(date +%s)
export PGOPTIONS="-c statement_timeout=${TIMEOUT_MS}"
out=$(docker exec -e PGOPTIONS "$PG" psql -U stremthru -d stremthru -At -c "$ORPHAN_Q" 2>&1)
rc=$?
dur=$(( $(date +%s) - t0 ))

if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qE '^[0-9]+$'; then
  status=ok; orphans="$out"
  log "ok: $orphans orphans in ${dur}s"
else
  status=error; orphans=null
  if printf '%s' "$out" | grep -qi 'statement timeout\|canceling statement'; then
    status=timeout
  fi
  log "FAILED ($status) after ${dur}s: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi

tmp=$(mktemp)
printf '{"ts":"%s","status":"%s","orphans":%s,"duration_s":%d}\n' \
  "$ts" "$status" "$orphans" "$dur" > "$tmp"
mv "$tmp" "$STATE"
log "=== orphan_scan end (status=$status) ==="
