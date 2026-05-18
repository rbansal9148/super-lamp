#!/bin/bash
# Bitmagnet-specific: DHT ingest rate vs prune rate (must be net-negative or zero).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | grep -q '^bitmagnet_postgres$' || exit 0

PSQL="docker exec bitmagnet_postgres psql -U bitmagnet -d bitmagnet -At -c"

# 1. DHT ingest rate (last $BITMAGNET_INGEST_WINDOW_HOURS hours — short window catches recent config changes)
recent=$($PSQL "SELECT count(*) FROM torrents WHERE created_at > NOW() - INTERVAL '${BITMAGNET_INGEST_WINDOW_HOURS} hours';" 2>/dev/null)
[ -z "$recent" ] && exit 0
per_hour=$((recent / BITMAGNET_INGEST_WINDOW_HOURS))

if [ "$per_hour" -gt "$BITMAGNET_DHT_INGEST_PER_HOUR_WARN" ]; then
  echo "MED|bitmagnet|DHT ingest ${per_hour}/hr (warn >${BITMAGNET_DHT_INGEST_PER_HOUR_WARN}/hr) — prune may fall behind|lower DHT_CRAWLER.SCALING_FACTOR in apps/bitmagnet/.env"
fi

# 2. Unclassified backlog (should stay small if prune is keeping up)
unclassified=$($PSQL "SELECT count(*) FROM torrents t LEFT JOIN torrent_contents tc ON tc.info_hash=t.info_hash WHERE tc.content_type IS NULL;" 2>/dev/null)
if [ -n "$unclassified" ] && [ "$unclassified" -gt 100000 ]; then
  echo "MED|bitmagnet|$unclassified unclassified torrents backlog|verify bitmagnet_prune sidecar running; consider larger nightly batch"
fi

# 3. Prune sidecar must be running
if ! docker ps --format '{{.Names}}' | grep -q '^bitmagnet_prune$'; then
  echo "HIGH|bitmagnet|bitmagnet_prune sidecar not running — DB will grow unbounded|docker compose --profile bitmagnet up -d bitmagnet_prune"
fi

# 4. DB size
db_size_gb=$($PSQL "SELECT (pg_database_size('bitmagnet')/1024/1024/1024)::int;" 2>/dev/null)
[ -n "$db_size_gb" ] && [ "$db_size_gb" -gt 100 ] && \
  echo "MED|bitmagnet|DB size ${db_size_gb}GB — consider VACUUM FULL after large prune|docker exec bitmagnet_postgres psql -U bitmagnet -d bitmagnet -c 'VACUUM FULL torrent_files;'"

# 5. Last autovacuum on hottest table
last_av_age=$($PSQL "SELECT EXTRACT(EPOCH FROM (now() - last_autovacuum))/86400 FROM pg_stat_user_tables WHERE relname='torrent_files';" 2>/dev/null | xargs printf '%.0f' 2>/dev/null)
if [ -n "$last_av_age" ] && [ "$last_av_age" -gt "$AUTOVACUUM_STALE_DAYS_WARN" ]; then
  echo "MED|bitmagnet|torrent_files last autovacuum ${last_av_age}d ago|VACUUM ANALYZE torrent_files; or lower autovacuum_vacuum_scale_factor"
fi
