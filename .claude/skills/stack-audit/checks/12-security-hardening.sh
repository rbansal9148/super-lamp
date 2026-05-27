#!/bin/bash
# Security hardening: run-as-root, capabilities, weak credentials, traefik hardening.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# 1. Privileged containers (should be none in this stack)
if [ "$PRIVILEGED_FORBIDDEN" = "true" ]; then
  docker ps --format '{{.Names}}' | while read c; do
    priv=$(docker inspect "$c" --format '{{.HostConfig.Privileged}}' 2>/dev/null)
    if [ "$priv" = "true" ]; then
      echo "CRIT|security|$c runs with --privileged — full host kernel access|remove privileged: true from apps/$c/compose.yaml"
    fi
  done
fi

# 2. Containers running as root that don't need to (best-effort, only the easy wins)
docker ps --format '{{.Names}}' | while read c; do
  if echo " $ALLOW_ROOT_USER " | grep -q " $c "; then continue; fi
  user=$(docker inspect "$c" --format '{{.Config.User}}' 2>/dev/null)
  # Empty user = root by default
  if [ -z "$user" ] || [ "$user" = "root" ] || [ "$user" = "0" ] || [ "$user" = "0:0" ]; then
    # Skip if image is well-known minimal (postgres/redis run as user internally)
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null | awk -F'[/@:]' '{print $(NF-1)}')
    case "$c" in *_postgres|*_redis|*_vacuum|*_prune|*_history_prune|aiostreams_*|comet_*|stremthru_*) continue ;; esac
    echo "LOW|security|$c runs as root (no user: directive) — best practice is non-root|add 'user: \"1000:1000\"' to apps/$c/compose.yaml (verify image supports it)"
  fi
done

# 3. Weak / default credentials in .env files (sampling)
# Strip comments and blank lines BEFORE matching, so "e.g. postgresql://bitmagnet:bitmagnet@…"
# in a `# comment` doesn't trip the check.
for envf in /opt/docker/apps/*/.env; do
  [ -f "$envf" ] || continue
  app=$(basename $(dirname "$envf"))
  uncommented=$(sed -E 's/[[:space:]]*#.*$//' "$envf" 2>/dev/null | grep -vE '^[[:space:]]*$')
  for pat in $WEAK_PW_PATTERNS; do
    if echo "$uncommented" | grep -qE "^${pat//:/=}|${pat}"; then
      echo "MED|security|$app/.env contains weak/default credential pattern '$pat'|rotate to a strong password; update both .env and the postgres user|rotate_pg_password"
    fi
  done
done

# 4. Traefik routes lacking rate limit middleware (only flag explicitly required ones)
if [ -n "$RATE_LIMIT_REQUIRED_ROUTES" ]; then
  for route in $RATE_LIMIT_REQUIRED_ROUTES; do
    c=$(docker ps --format '{{.Names}}' | grep "^${route}$" | head -1)
    [ -z "$c" ] && continue
    labels=$(docker inspect --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}|{{end}}' "$c" 2>/dev/null)
    if ! echo "$labels" | grep -qiE "ratelimit|rate-limit"; then
      echo "MED|security|$c lacks rate-limit middleware|add traefik.http.middlewares.${c}-rl.ratelimit.average=10 label"
    fi
  done
fi

# 5. Traefik HTTP→HTTPS redirect verified
trf_args=$(docker inspect traefik --format '{{range .Args}}{{.}} {{end}}' 2>/dev/null)
if [ -n "$trf_args" ] && ! echo "$trf_args" | grep -q "redirections.entryPoint.scheme=https"; then
  echo "HIGH|security|Traefik has no HTTP→HTTPS redirect — plaintext traffic possible|add --entryPoints.web.http.redirections.entryPoint.to=websecure to traefik compose"
fi

# 6. /etc/docker/daemon.json log defaults
if [ ! -f /etc/docker/daemon.json ]; then
  echo "MED|security|no /etc/docker/daemon.json — unbounded container logs|sudo tee /etc/docker/daemon.json <<<'{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}'; sudo systemctl reload docker"
fi
