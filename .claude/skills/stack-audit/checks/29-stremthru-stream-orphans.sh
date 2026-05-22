#!/bin/bash
# torrent_stream → torrent_info is not enforced by FK in stremthru's schema.
# Surfaced 21k orphans on first run (residue from various delete paths).
# Orphans bloat torrent_stream, slow stream lookups, and waste prune budget.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${STREMTHRU_STREAM_ORPHANS_WARN:=1000}"
: "${STREMTHRU_STREAM_ORPHANS_CRIT:=50000}"

docker ps --format '{{.Names}}' | grep -q '^stremthru_postgres$' || exit 0

PSQL="docker exec stremthru_postgres psql -U stremthru -d stremthru -At -c"

orphans=$($PSQL "
SELECT count(*) FROM torrent_stream ts
WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);" 2>/dev/null)

[ -z "$orphans" ] && exit 0

if [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_CRIT" ] 2>/dev/null; then
  echo "CRIT|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info) — bloating index|docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"DELETE FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);\""
elif [ "$orphans" -ge "$STREMTHRU_STREAM_ORPHANS_WARN" ] 2>/dev/null; then
  echo "MED|stremthru|$orphans orphan torrent_stream rows (no matching torrent_info)|docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"DELETE FROM torrent_stream ts WHERE NOT EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.hash = ts.h);\""
fi
