#!/bin/bash
# torrent_stream → torrent_info is not enforced by FK in stremthru's schema.
# Surfaced 21k orphans on first run (residue from various delete paths).
# Orphans bloat torrent_stream, slow stream lookups, and waste prune budget.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${STREMTHRU_STREAM_ORPHANS_WARN:=1000}"
: "${STREMTHRU_STREAM_ORPHANS_CRIT:=50000}"
: "${STREMTHRU_ORPHAN_SCAN_STALE_HOURS:=48}"

docker ps --format '{{.Names}}' | grep -q '^stremthru_postgres$' || exit 0

# The orphan anti-join scans millions of rows (60s+ and growing) — too slow to
# run inline. The off-peak job tools/orphan_scan.sh measures it and writes the
# count to .orphan_scan.json; we just read that cached result, so the audit
# stays fast and deterministic. (An index doesn't help: hash is already the PK;
# the cost is row volume, not a missing index — see commit history.)
STATE="$(dirname "${BASH_SOURCE[0]}")/../.orphan_scan.json"
RUN_JOB="bash tools/orphan_scan.sh"

if [ ! -f "$STATE" ]; then
  echo "LOW|stremthru|no orphan-scan result yet — off-peak measurement job has not run|$RUN_JOB"
  exit 0
fi

status=$(jq -r '.status // "error"' "$STATE" 2>/dev/null)
orphans=$(jq -r '.orphans // "null"' "$STATE" 2>/dev/null)
scan_ts=$(jq -r '.ts // empty' "$STATE" 2>/dev/null)

if [ "$status" != "ok" ] || ! printf '%s' "$orphans" | grep -qE '^[0-9]+$'; then
  echo "LOW|stremthru|off-peak orphan scan did not produce a count (status=$status) — re-run or raise its timeout|$RUN_JOB"
  exit 0
fi

# Freshness of the cached measurement.
age_h=999999
if [ -n "$scan_ts" ]; then
  now=$(date -u +%s); scanned=$(date -u -d "$scan_ts" +%s 2>/dev/null || echo 0)
  [ "$scanned" -gt 0 ] && age_h=$(( (now - scanned) / 3600 ))
fi
if [ "$age_h" -ge 48 ]; then age_str="$((age_h/24))d ago"; else age_str="${age_h}h ago"; fi

if [ "$age_h" -ge "$STREMTHRU_ORPHAN_SCAN_STALE_HOURS" ]; then
  echo "LOW|stremthru|orphan count $orphans is stale (measured $age_str; off-peak job may not be running)|$RUN_JOB"
  exit 0
fi

DEL="docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"DELETE FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);\""
if [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_CRIT" ] 2>/dev/null; then
  echo "CRIT|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info, measured $age_str) — bloating index|$DEL"
elif [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_WARN" ] 2>/dev/null; then
  echo "MED|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info, measured $age_str)|$DEL"
fi
