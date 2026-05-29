#!/bin/bash
# Postgres data integrity — two latent, catastrophic-when-they-hit conditions
# that no other check covers, both read-only (SELECT/SHOW only):
#
#   1. data_checksums OFF — on-disk bit-rot in heap/index pages is silently
#      served as valid data. Remediation is heavy (dump + initdb
#      --data-checksums + restore), so this is MED: flag it for the next
#      rebuild rather than alarm. The 03/11/24/31 postgres checks never look
#      at it.
#   2. Transaction-ID wraparound proximity — as age(datfrozenxid) climbs toward
#      2^31, autovacuum enters emergency freeze-only mode and eventually the DB
#      goes READ-ONLY. A healthy DB sits in the low millions; alerting only
#      fires when freeze autovacuum is genuinely falling behind (so 0 false
#      positives on a healthy stack — it's a dormant guard).
#
# Tunables (thresholds.sh): XID_AGE_MED / XID_AGE_HIGH / XID_AGE_CRIT.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
: "${XID_AGE_MED:=1000000000}"   # ~1.0B  (autovacuum freeze clearly behind)
: "${XID_AGE_HIGH:=1500000000}"  # ~1.5B
: "${XID_AGE_CRIT:=1900000000}"  # ~1.9B  (read-only safety stop ~2.1B)

for pg in $(docker ps --format '{{.Names}}' | rg '_postgres$' | sort); do
  user="$(docker exec "$pg" printenv POSTGRES_USER 2>/dev/null)"; [ -z "$user" ] && continue
  db="$(docker exec "$pg" printenv POSTGRES_DB 2>/dev/null)"; [ -z "$db" ] && continue
  PSQL="docker exec $pg psql -U $user -d $db -At -c"

  ck="$($PSQL "SHOW data_checksums;" 2>/dev/null | tr -d '\r')"
  [ "$ck" = "off" ] && echo "MED|postgres/$pg|data_checksums OFF — on-disk corruption in heap/index pages goes undetected (fix needs dump + initdb --data-checksums + restore)|flag for next rebuild; until then rely on ZFS/btrfs/ECC if present"

  age="$($PSQL "SELECT max(age(datfrozenxid)) FROM pg_database;" 2>/dev/null | tr -d '\r')"
  case "$age" in ''|*[!0-9]*) continue ;; esac
  if   [ "$age" -ge "$XID_AGE_CRIT" ]; then echo "CRIT|postgres/$pg|XID age ${age} — wraparound imminent, DB will go READ-ONLY|VACUUM FREEZE the oldest tables immediately"
  elif [ "$age" -ge "$XID_AGE_HIGH" ]; then echo "HIGH|postgres/$pg|XID age ${age} — wraparound approaching|find why freeze autovacuum is behind; VACUUM FREEZE large tables"
  elif [ "$age" -ge "$XID_AGE_MED" ]; then echo "MED|postgres/$pg|XID age ${age} elevated — freeze autovacuum falling behind|monitor age(datfrozenxid); ensure autovacuum freeze keeps up"
  fi
done
