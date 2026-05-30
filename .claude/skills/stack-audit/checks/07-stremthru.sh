#!/bin/bash
# StremThru-specific: prune sidecar, tunnel routing, TorBox bypass.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | grep -q '^stremthru_postgres$' || exit 0

# Bound every query below; passed through to the container by name (-e PGOPTIONS)
# so the value's internal space survives the unquoted $PSQL word-split.
export PGOPTIONS="-c statement_timeout=${PG_STATEMENT_TIMEOUT_MS}"
PSQL="docker exec -e PGOPTIONS stremthru_postgres psql -U stremthru -d stremthru -At -c"

# 1. Prune sidecar running
if ! docker ps --format '{{.Names}}' | grep -q '^stremthru_prune$'; then
  echo "MED|stremthru|stremthru_prune sidecar not running — torrent_stream will grow|docker compose --profile stremthru up -d stremthru_prune"
fi

# 2. torrent_stream over-90d backlog
over90=$($PSQL "SELECT count(*) FROM torrent_stream WHERE uat < NOW() - INTERVAL '90 days';" 2>/dev/null)
[ -n "$over90" ] && [ "$over90" -gt 500000 ] && \
  echo "LOW|stremthru|$over90 torrent_stream rows over 90d — prune backlog|wait for prune sidecar to drain (250k/day)"

# 3. Tunnel config — TorBox should bypass VPN (direct from Mumbai is fast; via VPN slow)
tunnel=$(grep -E "^STREMTHRU_STORE_TUNNEL=" /opt/docker/apps/stremthru/.env 2>/dev/null | cut -d= -f2-)
if [ -n "$tunnel" ] && ! echo "$tunnel" | grep -q "torbox:false"; then
  echo "MED|stremthru|TorBox not configured to bypass VPN tunnel — TLS handshake delays|set STREMTHRU_STORE_TUNNEL=torbox:false,*:true"
fi

# 4. HTTP proxy must point to a real reachable proxy
proxy=$(grep -E "^STREMTHRU_HTTP_PROXY=" /opt/docker/apps/stremthru/.env 2>/dev/null | cut -d= -f2-)
if [ -n "$proxy" ]; then
  if ! docker exec stremthru wget -qO /dev/null --timeout=3 "$proxy" 2>&1 | grep -q "400 Bad Request\|200 OK\|Connection refused"; then
    # gost responds 400 to direct GET which is normal proxy behavior
    echo "HIGH|stremthru|STREMTHRU_HTTP_PROXY=$proxy unreachable — outbound calls will fail|verify gluetun + gost are healthy"
  fi
fi

# 5. parse-torrent poison rows — torrent_info with parser_version=0 aged past 1h.
# MarkForReparseBelowVersion(9000) re-marks these on every container restart;
# go-ptt's parser can hang on pathological titles (long, mixed-bracket DHT rows),
# blocking the worker, breaking the heartbeat, and crashing the container in a
# ~5-min loop. Caught the live incident at 280 restarts (commit ref in audit.log).
stuck_unparsed=$($PSQL "SELECT count(*) FROM torrent_info WHERE parser_version = 0 AND created_at < NOW() - INTERVAL '1 hour';" 2>/dev/null)
if [ -n "$stuck_unparsed" ] && [ "$stuck_unparsed" -gt 0 ]; then
  echo "HIGH|stremthru|$stuck_unparsed torrent_info rows have parser_version=0 older than 1h — parse-torrent worker likely hanging on poison titles, restart loop imminent|inspect with: docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"SELECT src, count(*) FROM torrent_info WHERE parser_version = 0 AND created_at < NOW() - INTERVAL '1 hour' GROUP BY src;\" — then DELETE poison rows + dependent torrent_stream rows in one txn"
fi
