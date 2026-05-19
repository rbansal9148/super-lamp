#!/bin/bash
# Cheap fixer-hint checks — these exist primarily so `audit.sh --fix` can
# discover work that the deterministic fixers in tools/ would do.
# Each finding emits a FIX_TOOL hint matching a tools/ script name.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

ROOT="${DOCKER_ROOT:-/opt/docker}"

# --- env hygiene → secure_envs -----------------------------------------------
world_readable=$(find "$ROOT" -maxdepth 4 -name '.env' -type f \( -perm -004 -o -perm -040 \) 2>/dev/null | wc -l)
if [ "$world_readable" -gt 0 ]; then
  echo "HIGH|security|$world_readable .env files are world/group-readable (perms != 600)|chmod 600 every apps/*/.env|secure_envs"
fi
if (cd "$ROOT" && git rev-parse --git-dir >/dev/null 2>&1); then
  # Exclude stack-audit test fixtures — those are intentional dummy data.
  tracked=$(cd "$ROOT" && git ls-files | grep -E '\.env$' | grep -vF '.claude/skills/stack-audit/tools/test/fixtures/' | wc -l)
  if [ "$tracked" -gt 0 ]; then
    echo "HIGH|security|$tracked .env files are committed to git — secrets leak in history|git rm --cached then commit|secure_envs"
  fi
fi

# --- compose hygiene → add_logging / lock_public_ports -----------------------
# Services in /opt/docker/compose.yaml's include list that lack a logging:
# block (direct child of services.<svc>). Cheap heuristic: count compose files
# with no "    logging:" line under any service.
missing_logging=0
for cf in "$ROOT"/apps/*/compose.yaml; do
  # Only flag services that ARE referenced from the root compose.yaml include
  svc=$(basename "$(dirname "$cf")")
  if ! grep -q "^[[:space:]]*-[[:space:]]*apps/$svc/compose.yaml" "$ROOT/compose.yaml" 2>/dev/null; then
    continue  # disabled / commented out — don't bother
  fi
  if ! grep -q "^[[:space:]]\{4\}logging:" "$cf" 2>/dev/null; then
    missing_logging=$((missing_logging+1))
  fi
done
if [ "$missing_logging" -gt 0 ]; then
  echo "MED|containers|$missing_logging enabled services lack a logging: block (unbounded json-file log growth)|add logging: json-file 10m × 3 to each|add_logging"
fi

# Traefik-fronted services that ALSO publish host ports (bypasses Authelia)
exposed=0
for cf in "$ROOT"/apps/*/compose.yaml; do
  svc=$(basename "$(dirname "$cf")")
  # Only flag if the svc has a traefik label AND ports: block AND is in active include
  if grep -q "^[[:space:]]*-[[:space:]]*apps/$svc/compose.yaml" "$ROOT/compose.yaml" 2>/dev/null \
     && grep -q "traefik.http.routers" "$cf" 2>/dev/null \
     && grep -qE "^[[:space:]]+ports:" "$cf" 2>/dev/null \
     && ! [[ ",traefik,gluetun,bitmagnet,bitmagnet_vpn,plex,cloudflare-ddns," == *",$svc,"* ]]; then
    exposed=$((exposed+1))
  fi
  # `bitmagnet` is skipped because its compose hosts a separate bitmagnet_vpn
  # service that legitimately publishes BitTorrent ports; the grep above isn't
  # YAML-structure-aware so it would otherwise false-positive.
done
if [ "$exposed" -gt 0 ]; then
  echo "HIGH|security|$exposed Traefik-fronted services also publish host ports (Authelia bypass)|comment out ports:|lock_public_ports"
fi

# --- postgres WAL bloat → checkpoint_wal -------------------------------------
# Flag only TRUE bloat: pg_wal directory exceeds 1.5× the instance's own
# max_wal_size setting. Postgres normally fills WAL up to max_wal_size before
# forcing a checkpoint — that's healthy steady-state, not bloat.
WAL_BLOAT_RATIO="${WAL_BLOAT_RATIO:-1.5}"
big_wal=0
for c in $(docker ps --format '{{.Names}}' | grep '_postgres$'); do
  for p in /var/lib/postgresql/data/pgdata/pg_wal /var/lib/postgresql/data/pg_wal; do
    if docker exec "$c" test -d "$p" 2>/dev/null; then
      mb=$(docker exec "$c" du -sm "$p" 2>/dev/null | awk '{print $1}')
      [ -z "$mb" ] && break
      # Query instance's max_wal_size (postgres returns it in pretty form e.g. "1GB")
      max_wal=$(docker exec "$c" psql -U "${c%_postgres}" -d "${c%_postgres}" -At -c "SHOW max_wal_size;" 2>/dev/null)
      # Convert max_wal to MB (best effort: handles MB/GB suffixes)
      max_mb=$(echo "$max_wal" | awk '
        /GB$/ {sub(/GB/,""); printf "%d", $1*1024; exit}
        /MB$/ {sub(/MB/,""); printf "%d", $1; exit}
        /^[0-9]+$/ {printf "%d", $1; exit}
      ')
      # Default to 1024 if we couldn't parse
      [ -z "$max_mb" ] && max_mb=1024
      threshold_mb=$(awk -v m=$max_mb -v r=$WAL_BLOAT_RATIO 'BEGIN{printf "%d", m*r}')
      if [ "$mb" -gt "$threshold_mb" ]; then
        big_wal=$((big_wal+1))
      fi
      break
    fi
  done
done
if [ "$big_wal" -gt 0 ]; then
  echo "MED|postgres|$big_wal postgres instances have pg_wal > ${WAL_BLOAT_RATIO}× max_wal_size (true bloat)|force CHECKPOINT to recycle segments|checkpoint_wal"
fi

# --- docker housekeeping → prune_docker --------------------------------------
reclaim_mb=$(docker system df --format '{{.Type}} {{.Reclaimable}}' 2>/dev/null \
  | awk '$1=="Images"{print $2}' | grep -oE '^[0-9.]+' | head -1)
if [ -n "$reclaim_mb" ]; then
  # crude: anything > 500MB worth flagging
  mb_int=$(printf '%.0f' "$reclaim_mb")
  if [ "$mb_int" -ge 500 ]; then
    echo "LOW|storage|docker has ${reclaim_mb}GB/MB of reclaimable image space|docker image prune -a|prune_docker"
  fi
fi
