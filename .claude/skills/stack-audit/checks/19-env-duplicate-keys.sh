#!/bin/bash
# Duplicate KEY=value in same env file (silent last-wins bug) and
# same KEY in BOTH .env and config.env (compose loads both — order-dependent).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

APPS="/opt/docker/apps"

# Pass 1: in-file duplicates
for f in "$APPS"/*/.env "$APPS"/*/config.env; do
  [ -f "$f" ] || continue
  svc=$(basename "$(dirname "$f")")
  fname=$(basename "$f")
  # Extract uncommented KEY= entries, count, print duplicates
  dups=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$f" 2>/dev/null | cut -d= -f1 | sort | uniq -d)
  [ -z "$dups" ] && continue
  for k in $dups; do
    lines=$(grep -nE "^${k}=" "$f" | cut -d: -f1 | paste -sd, -)
    echo "HIGH|env|$svc/$fname: duplicate key $k at lines $lines (later wins, silently)|sed -i -n -e \"/^${k}=/!p\" -e \"\\\$a\\\$(grep -E '^${k}=' $f | tail -1)\" $f"
  done
done

# Pass 2: cross-file (same key in both .env and config.env)
for dir in "$APPS"/*/; do
  e="$dir/.env"; c="$dir/config.env"
  [ -f "$e" ] && [ -f "$c" ] || continue
  svc=$(basename "$dir")
  e_keys=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$e" 2>/dev/null | cut -d= -f1 | sort -u)
  c_keys=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$c" 2>/dev/null | cut -d= -f1 | sort -u)
  overlap=$(comm -12 <(echo "$e_keys") <(echo "$c_keys"))
  [ -z "$overlap" ] && continue
  for k in $overlap; do
    e_val=$(grep -E "^${k}=" "$e" | head -1 | cut -d= -f2-)
    c_val=$(grep -E "^${k}=" "$c" | head -1 | cut -d= -f2-)
    if [ "$e_val" != "$c_val" ]; then
      echo "HIGH|env|$svc: $k defined in both .env and config.env with different values (env_file order decides)|move to one file only"
    else
      echo "LOW|env|$svc: $k duplicated in .env and config.env (same value)|remove from config.env (secrets file wins by convention)"
    fi
  done
done
