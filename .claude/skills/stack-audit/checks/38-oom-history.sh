#!/bin/bash
# Kernel OOM-killer history per container. The existing 02-containers.sh
# checks the live OOMKilled flag — only catches the CURRENT incarnation.
# A container OOM-killed and auto-restarted by docker clears that flag,
# so a brutal loop ("OOM-killed 279 times in 24h, then suddenly stopped")
# leaves no trace in `docker inspect`. journalctl -k still has it.
#
# We surface every container with ≥OOM_HISTORY_WARN OOM events in last
# 7d, plus a HIGH if any are recent (within last 24h).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${OOM_HISTORY_WARN:=3}"
: "${OOM_HISTORY_HIGH:=20}"
: "${OOM_HISTORY_DAYS:=7}"
: "${OOM_RECENT_HOURS:=24}"
# A sustained loop whose last event is older than this is treated as
# resolved-and-acknowledged; finding drops MED → LOW. Auto-resolves once
# every event ages out of OOM_HISTORY_DAYS naturally.
: "${OOM_QUIET_HOURS:=48}"

command -v journalctl >/dev/null 2>&1 || exit 0

# Last 7d aggregate count per process name
hist=$(sudo journalctl --since "${OOM_HISTORY_DAYS} days ago" -k 2>/dev/null \
        | grep 'Memory cgroup out of memory' \
        | grep -oE 'Killed process [0-9]+ \([a-zA-Z0-9_-]+\)' \
        | grep -oE '\([a-zA-Z0-9_-]+\)' | tr -d '()' \
        | sort | uniq -c | sort -rn)

# Last 24h count per process name (separate query, smaller scan)
recent=$(sudo journalctl --since "${OOM_RECENT_HOURS} hours ago" -k 2>/dev/null \
          | grep 'Memory cgroup out of memory' \
          | grep -oE 'Killed process [0-9]+ \([a-zA-Z0-9_-]+\)' \
          | grep -oE '\([a-zA-Z0-9_-]+\)' | tr -d '()' \
          | sort | uniq -c | sort -rn)

now_ts=$(date +%s)
printf '%s\n' "$hist" | while read -r n proc; do
  [ -z "$proc" ] && continue
  [ "$n" -lt "$OOM_HISTORY_WARN" ] && continue
  recent_n=$(printf '%s\n' "$recent" | awk -v p="$proc" '$2==p {print $1}')
  recent_n=${recent_n:-0}
  # Age of the most recent event for this process, in hours
  last_ts=$(sudo journalctl -k --reverse --output=short-unix --since "${OOM_HISTORY_DAYS} days ago" 2>/dev/null \
            | grep "Killed process [0-9]* (${proc})" | head -1 | awk '{print $1}')
  if [ -n "$last_ts" ]; then
    hours_since=$(( (now_ts - ${last_ts%.*}) / 3600 ))
  else
    hours_since=9999
  fi
  if [ "$recent_n" -gt 0 ]; then
    echo "HIGH|memory|process '$proc' OOM-killed ${recent_n}× in last ${OOM_RECENT_HOURS}h (${n}× in ${OOM_HISTORY_DAYS}d) — raise mem_limit or investigate leak|sudo journalctl -k --since '${OOM_RECENT_HOURS} hours ago' | rg '$proc.*oom-killer' | head"
  elif [ "$n" -ge "$OOM_HISTORY_HIGH" ] && [ "$hours_since" -lt "$OOM_QUIET_HOURS" ]; then
    echo "MED|memory|process '$proc' OOM-killed ${n}× in last ${OOM_HISTORY_DAYS}d (none in last ${OOM_RECENT_HOURS}h, last ${hours_since}h ago) — was a sustained loop; verify root cause was addressed, not just masked by restart|sudo journalctl -k --since '${OOM_HISTORY_DAYS} days ago' | rg '$proc.*Killed process' | head"
  else
    echo "LOW|memory|process '$proc' OOM-killed ${n}× in last ${OOM_HISTORY_DAYS}d (last ${hours_since}h ago) — resolved or intermittent; will age out|sudo journalctl -k | rg '$proc.*Killed process'"
  fi
done
