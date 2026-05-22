#!/bin/bash
# Generalization of the stremthru parse-torrent poison-row pattern. Each
# service has its own retry-queue table; rows with high failure count + age
# represent poison inputs that pin worker CPU / block the queue indefinitely.
# Surfacing these early lets the operator decide: delete, fix upstream, or
# adjust max_attempts so the worker actually gives up.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${STUCK_JOB_WARN_COUNT:=10}"
: "${STUCK_JOB_HIGH_COUNT:=500}"

emit() {
  local sev="$1" svc="$2" cnt="$3" desc="$4" fix="$5"
  echo "$sev|$svc|$cnt $desc|$fix"
}

# --- comet: background_scraper_items with 5+ consecutive_failures aged >24h
if docker ps --format '{{.Names}}' | grep -q '^comet_postgres$'; then
  n=$(docker exec comet_postgres psql -U comet -d comet -At -c "
    SELECT count(*) FROM background_scraper_items
    WHERE consecutive_failures >= 5
      AND to_timestamp(created_at) < now() - interval '24 hours'
      AND status NOT IN ('completed', 'idle');" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -ge "$STUCK_JOB_WARN_COUNT" ]; then
    sev=MED
    [ "$n" -ge "$STUCK_JOB_HIGH_COUNT" ] && sev=HIGH
    emit "$sev" "comet" "$n" \
      "background_scraper_items stuck (5+ consecutive failures, >24h old) — poison-input pattern" \
      "inspect: docker exec comet_postgres psql -U comet -d comet -c \"SELECT title, year, consecutive_failures FROM background_scraper_items WHERE consecutive_failures >= 5 ORDER BY consecutive_failures DESC LIMIT 20;\" — then either delete or reset failure counter"
  fi
fi

# --- mediafusion: jobs at max_attempts that never succeeded
if docker ps --format '{{.Names}}' | grep -q '^mediafusion_postgres$'; then
  n=$(docker exec mediafusion_postgres psql -U mediafusion -d mediafusion -At -c "
    SELECT count(*) FROM jobs
    WHERE attempts >= max_attempts
      AND status NOT IN ('succeeded', 'cancelled')
      AND scheduled_at < now() - interval '6 hours';" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -ge "$STUCK_JOB_WARN_COUNT" ]; then
    sev=MED
    [ "$n" -ge "$STUCK_JOB_HIGH_COUNT" ] && sev=HIGH
    emit "$sev" "mediafusion" "$n" \
      "jobs exhausted max_attempts (still pending/failed, >6h old) — poison-payload pattern" \
      "inspect: docker exec mediafusion_postgres psql -U mediafusion -d mediafusion -c \"SELECT queue, status, last_error, count(*) FROM jobs WHERE attempts >= max_attempts AND status NOT IN ('succeeded','cancelled') GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 20;\""
  fi
  # also: jobs started but never finished (worker crashed mid-flight)
  m=$(docker exec mediafusion_postgres psql -U mediafusion -d mediafusion -At -c "
    SELECT count(*) FROM jobs
    WHERE started_at IS NOT NULL AND finished_at IS NULL
      AND started_at < now() - interval '2 hours';" 2>/dev/null)
  if [ -n "$m" ] && [ "$m" -gt 0 ]; then
    emit "MED" "mediafusion" "$m" \
      "jobs started but never finished (>2h ago) — worker died mid-execution" \
      "inspect: docker exec mediafusion_postgres psql -U mediafusion -d mediafusion -c \"SELECT id, queue, worker_id, started_at, last_error FROM jobs WHERE started_at IS NOT NULL AND finished_at IS NULL ORDER BY started_at LIMIT 10;\""
  fi
fi

# --- stremthru: same job_id appearing as 'failed' 10+ times in last 6h
# (orthogonal to the existing parse-torrent poison-row check in 07-stremthru)
if docker ps --format '{{.Names}}' | grep -q '^stremthru_postgres$'; then
  n=$(docker exec stremthru_postgres psql -U stremthru -d stremthru -At -c "
    SELECT count(*) FROM (
      SELECT name FROM job_log
      WHERE status = 'failed' AND created_at > now() - interval '6 hours'
      GROUP BY name HAVING count(*) >= 10
    ) t;" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -gt 0 ]; then
    emit "MED" "stremthru" "$n" \
      "distinct job names with 10+ failures in last 6h — repeated-failure poison pattern" \
      "inspect: docker exec stremthru_postgres psql -U stremthru -d stremthru -c \"SELECT name, count(*), max(error) FROM job_log WHERE status='failed' AND created_at > now() - interval '6 hours' GROUP BY name HAVING count(*) >= 10 ORDER BY count(*) DESC LIMIT 10;\""
  fi
fi
