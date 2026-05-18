#!/bin/bash
# Security: public-port exposure, authelia coverage, daemon log caps.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# 1. Forbidden public-port bindings (e.g., DB ports on 0.0.0.0)
for port in $FORBIDDEN_PUBLIC_PORTS; do
  hit=$(sudo ss -tln 2>/dev/null | awk -v p="$port" '$4 ~ "(\\*|0\\.0\\.0\\.0):"p"$"' | head -1)
  if [ -n "$hit" ]; then
    container=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E "0\\.0\\.0\\.0:${port}->" | awk -F'\t' '{print $1}' | head -1)
    echo "CRIT|security|port $port publicly bound (container=$container) — sensitive service exposed to internet|remove 'ports:' mapping in apps/${container%%_*}/compose.yaml (use 'expose:' for internal-only)"
  fi
done

# 2. Traefik routes lacking authelia middleware
if [ "$REQUIRE_AUTHELIA_MIDDLEWARE" = "true" ]; then
  docker ps --format '{{.Names}}' | while read c; do
    labels=$(docker inspect --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}|{{end}}' "$c" 2>/dev/null)
    if echo "$labels" | grep -q "traefik.enable=true"; then
      # Whitelist: authelia itself + traefik dashboard need their own auth
      case "$c" in authelia|honey) continue ;; esac
      if ! echo "$labels" | grep -q "authelia"; then
        echo "HIGH|security|$c has traefik route but no authelia middleware|add 'traefik.http.routers.<svc>.middlewares=authelia@docker' label"
      fi
    fi
  done
fi

# 3. Daemon-level log caps
if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
  echo "MED|security|Docker daemon has no default log caps — uncapped logs eat disk|create /etc/docker/daemon.json with log-driver json-file + max-size 10m + max-file 3"
fi

# 4. Traefik log level (DEBUG generates massive logs)
trf_loglevel=$(docker inspect traefik --format '{{range .Args}}{{.}} {{end}}' 2>/dev/null | grep -oE 'log\.level=[A-Z]+' | head -1 | cut -d= -f2)
if [ "$trf_loglevel" = "DEBUG" ]; then
  echo "MED|security|Traefik log level is DEBUG — generates massive log volume|change --log.level=WARN in apps/traefik/compose.yaml"
fi

# 5. Authelia maxResponseBodySize set (DoS protection)
if docker ps --format '{{.Names}}' | grep -q '^authelia$'; then
  labels=$(docker inspect authelia --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}|{{end}}' 2>/dev/null)
  if ! echo "$labels" | grep -q "maxResponseBodySize"; then
    echo "LOW|security|authelia forwardAuth.maxResponseBodySize not set — unbounded auth response = DoS surface|add traefik.http.middlewares.authelia.forwardAuth.maxResponseBodySize=16777216"
  fi
fi
