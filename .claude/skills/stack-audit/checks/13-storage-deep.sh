#!/bin/bash
# Storage deep: inode usage, backup posture, DB growth tracking.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# 1. Inode usage on root filesystem (orthogonal to disk %; can fill on small files)
inode_pct=$(df -i / | awk 'NR==2{gsub(/%/,"");print $5}')
if [ -n "$inode_pct" ]; then
  if [ "$inode_pct" -ge "$INODE_USED_PCT_CRIT" ]; then
    echo "CRIT|storage|inode usage ${inode_pct}% (crit ≥${INODE_USED_PCT_CRIT}%) — file creation will fail|find / -xdev -type f 2>/dev/null | awk -F/ '{print \$2\"/\"\$3}' | sort | uniq -c | sort -rn | head"
  elif [ "$inode_pct" -ge "$INODE_USED_PCT_WARN" ]; then
    echo "HIGH|storage|inode usage ${inode_pct}% (warn ≥${INODE_USED_PCT_WARN}%)|investigate biggest small-file dirs"
  fi
fi

# 2. Backup posture — flag if BACKUP_DIR doesn't exist OR most recent dump is stale
if [ -n "$BACKUP_DIR" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "MED|storage|no backup directory at $BACKUP_DIR — disaster recovery gap|sudo mkdir -p $BACKUP_DIR; set up a nightly pg_dump cron (one per important DB)"
  else
    # Find most recent dump file
    newest=$(find "$BACKUP_DIR" -type f \( -name '*.sql*' -o -name '*.dump' -o -name '*.tar*' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    if [ -z "$newest" ]; then
      echo "MED|storage|$BACKUP_DIR exists but no dump files found — no backups running|set up pg_dump cron"
    else
      age_days=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
      if [ "$age_days" -ge "$BACKUP_STALE_DAYS_CRIT" ]; then
        echo "CRIT|storage|newest backup is ${age_days}d old (crit ≥${BACKUP_STALE_DAYS_CRIT}d) — backups may be broken|check cron job and dump output"
      elif [ "$age_days" -ge "$BACKUP_STALE_DAYS_WARN" ]; then
        echo "MED|storage|newest backup is ${age_days}d old (warn ≥${BACKUP_STALE_DAYS_WARN}d)|verify backup schedule"
      fi
    fi
  fi
fi

# 3. Per-data-dir sizes (informational — flag any single dir >30GB)
if [ -d /opt/docker/data ]; then
  for dir in /opt/docker/data/*/; do
    name=$(basename "$dir")
    gb=$(sudo du -shx --block-size=1G "$dir" 2>/dev/null | awk '{print $1}')
    [ -z "$gb" ] && continue
    if [ "$gb" -ge 30 ] && docker ps --format '{{.Names}}' | grep -q "^${name}$\|^${name}_"; then
      # Only mention very large active dirs
      echo "LOW|storage|/opt/docker/data/$name is ${gb}GB (large active dir)|sudo du -shx $dir/* 2>/dev/null | sort -h | tail"
    fi
  done
fi
