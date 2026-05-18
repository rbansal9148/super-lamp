#!/bin/bash
# System-level checks: disk, mem, swap, load, CPU steal.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Disk
disk_pct=$(df / | awk 'NR==2{gsub(/%/,"");print $5}')
if [ "$disk_pct" -ge "$DISK_USED_PCT_CRIT" ]; then
  echo "CRIT|system|disk usage ${disk_pct}% (crit ≥${DISK_USED_PCT_CRIT})|sudo du -shx /opt/docker/data/* 2>/dev/null | sort -h | tail"
elif [ "$disk_pct" -ge "$DISK_USED_PCT_WARN" ]; then
  echo "HIGH|system|disk usage ${disk_pct}% (warn ≥${DISK_USED_PCT_WARN})|sudo du -shx /opt/docker/data/* 2>/dev/null | sort -h | tail"
fi

# Swap usage
swap_total=$(free -m | awk '/Swap:/ {print $2}')
swap_used=$(free -m | awk '/Swap:/ {print $3}')
if [ "$swap_total" = "0" ]; then
  echo "HIGH|system|no swap configured (host RAM tight = OOM-killer with no safety net)|sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
elif [ "$swap_total" -gt 0 ]; then
  swap_pct=$(( 100 * swap_used / swap_total ))
  if [ "$swap_pct" -ge "$SWAP_USED_PCT_WARN" ]; then
    echo "HIGH|system|swap usage ${swap_pct}% (warn ≥${SWAP_USED_PCT_WARN}%) — memory pressure|free -h; docker stats --no-stream"
  fi
fi

# Load average (1-min) per core
load1=$(cut -d' ' -f1 /proc/loadavg)
cores=$(nproc)
per_core=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')
if awk -v p="$per_core" -v w="$LOAD_PER_CORE_WARN" 'BEGIN{exit !(p>w)}'; then
  echo "HIGH|system|load_1m/${cores}cores = ${per_core} (warn >${LOAD_PER_CORE_WARN})|uptime; docker stats --no-stream | head -15"
fi

# CPU steal time (noisy neighbor on VPS)
steal=$(top -bn1 | awk '/Cpu\(s\):/ {for(i=1;i<=NF;i++) if($i=="st"||$i~/st$/) print $(i-1)}' | tr -d ',')
if [ -n "$steal" ] && awk -v s="$steal" -v t="$CPU_STEAL_PCT_WARN" 'BEGIN{exit !(s>t)}'; then
  echo "MED|system|CPU steal ${steal}% (warn >${CPU_STEAL_PCT_WARN}%) — VPS contention|"
fi
