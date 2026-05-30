#!/bin/bash
# torrent_stream → torrent_info is not enforced by FK in stremthru's schema.
# Surfaced 21k orphans on first run (residue from various delete paths).
# Orphans bloat torrent_stream, slow stream lookups, and waste prune budget.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${STREMTHRU_STREAM_ORPHANS_WARN:=1000}"
: "${STREMTHRU_STREAM_ORPHANS_CRIT:=50000}"

docker ps --format '{{.Names}}' | grep -q '^stremthru_postgres$' || exit 0

# This anti-join scans all of torrent_stream (~800k rows and growing); on a cold
# cache it exceeds a minute, with no upper bound as the table grows. Rather than
# run it unbounded every audit (and trip the orchestrator timeout), self-bound
# the scan: if it can't finish within ORPHAN_SCAN_TIMEOUT_MS, emit an
# informative finding with a manual command instead of a silent empty result.
# Passed through by name (-e PGOPTIONS) so the value's internal space survives
# the unquoted $PSQL word-split.
ORPHAN_SCAN_TIMEOUT_MS="${STREMTHRU_ORPHAN_SCAN_TIMEOUT_MS:-15000}"
export PGOPTIONS="-c statement_timeout=${ORPHAN_SCAN_TIMEOUT_MS}"
PSQL="docker exec -e PGOPTIONS stremthru_postgres psql -U stremthru -d stremthru -At -c"

ORPHAN_Q="SELECT count(*) FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);"
MANUAL_CMD="docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"$ORPHAN_Q\""

out=$($PSQL "$ORPHAN_Q" 2>&1)
if printf '%s' "$out" | grep -qi 'statement timeout\|canceling statement'; then
  echo "LOW|stremthru|orphan scan did not finish within $((ORPHAN_SCAN_TIMEOUT_MS/1000))s (torrent_stream too large for an inline anti-join) — run manually to measure bloat|$MANUAL_CMD"
  exit 0
fi
orphans="$out"

[ -z "$orphans" ] && exit 0
case "$orphans" in *[!0-9]*) exit 0 ;; esac

if [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_CRIT" ] 2>/dev/null; then
  echo "CRIT|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info) — bloating index|docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"DELETE FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);\""
elif [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_WARN" ] 2>/dev/null; then
  echo "MED|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info)|docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"DELETE FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);\""
fi
