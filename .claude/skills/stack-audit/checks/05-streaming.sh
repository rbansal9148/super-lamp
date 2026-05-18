#!/bin/bash
# Streaming addon health: aiostreams returns, Comet response time, MediaFusion scheduler, StremThru errors, AIOMetadata cache.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

WINDOW="30m"

# --- AIOStreams: streams-returned histogram + error rate
if docker ps --format '{{.Names}}' | grep -q '^aiostreams$'; then
  data=$(docker logs --since "$WINDOW" aiostreams 2>&1 | grep -oE 'Returning [0-9]+ streams and [0-9]+ errors' || true)
  total=$(echo "$data" | grep -c . || true)
  if [ "$total" -gt 0 ]; then
    zeros=$(echo "$data" | awk '$2==0' | wc -l)
    # Error rate average
    err_pct=$(echo "$data" | awk '{s+=$2;e+=$5;n++} END{if(n>0) printf "%d", 100*e/(s+e+1)}')
    zero_pct=$(( 100 * zeros / total ))
    if [ "$zero_pct" -ge "$AIOSTREAMS_ZERO_STREAMS_PCT_WARN" ]; then
      echo "HIGH|streaming/aiostreams|${zero_pct}% of last $total requests returned 0 streams (warn ≥${AIOSTREAMS_ZERO_STREAMS_PCT_WARN}%)|raise MAX_TIMEOUT; check addon health"
    fi
    if [ -n "$err_pct" ] && [ "$err_pct" -ge "$AIOSTREAMS_ERROR_RATE_PCT_WARN" ]; then
      echo "MED|streaming/aiostreams|addon error rate ${err_pct}% (warn ≥${AIOSTREAMS_ERROR_RATE_PCT_WARN}%)|disable slow addons or raise per-preset timeout"
    fi
  fi
fi

# --- Comet: response time p50/p95 from access logs
if docker ps --format '{{.Names}}' | grep -q '^comet$'; then
  times=$(docker logs --since "$WINDOW" comet 2>&1 | grep -oE '\.json - 200 - [0-9.]+s' | awk -F'- ' '{gsub(/s/,"",$NF); print $NF}' | sort -n)
  cnt=$(echo "$times" | grep -c . || echo 0)
  if [ "$cnt" -gt 5 ]; then
    p95=$(echo "$times" | awk -v n="$cnt" 'BEGIN{i=int(n*0.95)} NR==i')
    if awk -v p="$p95" -v t="$COMET_P95_RESP_S_WARN" 'BEGIN{exit !(p>t)}'; then
      echo "HIGH|streaming/comet|p95 response time ${p95}s (warn >${COMET_P95_RESP_S_WARN}s)|disable background scrapers, lower DEBRID_CACHE_CHECK_RATIO, reduce live scraper count"
    fi
  fi
fi

# --- MediaFusion: scheduler must be disabled (else background work load)
if docker ps --format '{{.Names}}' | grep -q '^mediafusion$'; then
  disabled=$(grep -E "^DISABLE_ALL_SCHEDULER" /opt/docker/apps/mediafusion/.env 2>/dev/null | tail -1 | cut -d= -f2)
  if [ "$disabled" != "true" ]; then
    echo "LOW|streaming/mediafusion|background scheduler enabled — adds CPU/IO load|set DISABLE_ALL_SCHEDULER=true in apps/mediafusion/.env"
  fi
  # External MediaFusionScraper failures
  fails=$(docker logs --since "$WINDOW" mediafusion 2>&1 | grep -c "404 Not Found.*mediafusion" || echo 0)
  if [ "$fails" -gt 5 ]; then
    echo "MED|streaming/mediafusion|$fails 404s from external MediaFusion scrape source (last $WINDOW)|set IS_SCRAP_FROM_MEDIAFUSION=False"
  fi
fi

# --- StremThru: mylist parse errors, broken pipe count
if docker ps --format '{{.Names}}' | grep -q '^stremthru$'; then
  unmarshal=$(docker logs --since "$WINDOW" stremthru 2>&1 | grep -c "cannot unmarshal array" || echo 0)
  if [ "$unmarshal" -gt 0 ]; then
    echo "HIGH|streaming/stremthru|$unmarshal mylist unmarshal errors (TorBox API mismatch) in last $WINDOW|upstream bug — file issue at github.com/MunifTanjim/stremthru/issues"
  fi
  pipes=$(docker logs --since "$WINDOW" stremthru 2>&1 | grep -c "broken pipe" || echo 0)
  pipes_per_min=$(( pipes / 30 ))
  if [ "$pipes_per_min" -ge "$STREMTHRU_BROKEN_PIPE_RATE_WARN" ]; then
    echo "MED|streaming/stremthru|${pipes_per_min}/min broken pipe (warn ≥${STREMTHRU_BROKEN_PIPE_RATE_WARN}/min) — clients timing out|raise AIOStreams preset timeouts; check upstream latency"
  fi
fi

# --- AIOMetadata: app-level cache rate
if docker ps --format '{{.Names}}' | grep -q '^aiometadata$'; then
  hit=$(docker logs --since "$WINDOW" aiometadata 2>&1 | grep "Cache-Health" | grep -oE 'Hit Rate: [0-9.]+%' | tail -1 | grep -oE '[0-9]+')
  if [ -n "$hit" ] && [ "$hit" -lt 50 ]; then
    echo "LOW|streaming/aiometadata|app-level hit rate ${hit}% (low for warmed instance)|verify TMDB_POPULAR_WARMING_ENABLED=true; lower CACHE_WARM_INTERVAL_HOURS"
  fi
  # TMDB connection failures
  fetch_fail=$(docker logs --since "$WINDOW" aiometadata 2>&1 | grep -c "fetch failed" || echo 0)
  if [ "$fetch_fail" -gt 50 ]; then
    echo "MED|streaming/aiometadata|$fetch_fail TMDB fetch failures in last $WINDOW|check TMDB connectivity; consider TMDB_SOCKS_PROXY_URL via gluetun"
  fi
fi
