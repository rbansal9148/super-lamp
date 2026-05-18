#!/bin/bash
# env_file completeness — detect the bitmagnet_vpn bug class:
# service has env_file listing only .env when sibling config.env also exists
# (or vice versa). Both must be loaded after the env split.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

APPS="/opt/docker/apps"

for dir in "$APPS"/*/; do
  svc=$(basename "$dir")
  cf="$dir/compose.yaml"
  [ -f "$cf" ] || continue

  has_env=0; has_cfg=0
  [ -f "$dir/.env" ] && has_env=1
  [ -f "$dir/config.env" ] && has_cfg=1
  # Skip services that don't have BOTH files
  [ "$has_env" = 1 ] && [ "$has_cfg" = 1 ] || continue

  # env_file declarations: gather all lines under any env_file: block.
  # Captures list-form (- .env) and string-form (env_file: .env).
  envs=$(awk '
    /^[[:space:]]+env_file:[[:space:]]*$/ {in_block=1; next}
    /^[[:space:]]+env_file:[[:space:]]+["'\''A-Za-z0-9._/${}-]+/ {
      sub(/^[[:space:]]+env_file:[[:space:]]+/, ""); gsub(/["'\'']/, ""); print; next
    }
    in_block && /^[[:space:]]+-/ {sub(/^[[:space:]]+-[[:space:]]+/, ""); gsub(/["'\'']/, ""); print; next}
    in_block && !/^[[:space:]]+-/ {in_block=0}
  ' "$cf")

  # Skip if no env_file declared at all (some services use environment: only)
  [ -z "$envs" ] && continue

  loads_env=$(echo "$envs" | grep -cE '(^|/)\.env$' || true)
  loads_cfg=$(echo "$envs" | grep -cE '(^|/)config\.env$' || true)

  if [ "$loads_env" -gt 0 ] && [ "$loads_cfg" -eq 0 ]; then
    echo "HIGH|env|$svc loads .env but not sibling config.env (env-split incomplete)|add '      - config.env' to env_file: in $cf"
  elif [ "$loads_cfg" -gt 0 ] && [ "$loads_env" -eq 0 ]; then
    echo "HIGH|env|$svc loads config.env but not sibling .env (secrets missing)|add '      - .env' to env_file: in $cf"
  fi
done

# Cross-service imports: catch the exact bitmagnet→gluetun pattern.
grep -lE 'env_file:.*\$\{DOCKER_APP_DIR\}/[^/]+/' "$APPS"/*/compose.yaml 2>/dev/null | while read -r cf; do
  svc=$(basename "$(dirname "$cf")")
  # Extract referenced other-service envs
  refs=$(grep -oE '\$\{DOCKER_APP_DIR\}/[^/]+/[a-zA-Z_.]+\.env' "$cf" | sort -u)
  # Group by source service
  echo "$refs" | sed -E 's|.*DOCKER_APP_DIR\}/([^/]+)/.*|\1|' | sort -u | while read -r other; do
    [ -z "$other" ] && continue
    [ "$other" = "$svc" ] && continue
    has_other_env=0; has_other_cfg=0
    [ -f "$APPS/$other/.env" ] && has_other_env=1
    [ -f "$APPS/$other/config.env" ] && has_other_cfg=1
    [ "$has_other_env" = 1 ] && [ "$has_other_cfg" = 1 ] || continue
    loads_other_env=$(echo "$refs" | grep -cE "/$other/\.env\$" || true)
    loads_other_cfg=$(echo "$refs" | grep -cE "/$other/config\.env\$" || true)
    if [ "$loads_other_env" -gt 0 ] && [ "$loads_other_cfg" -eq 0 ]; then
      echo "HIGH|env|$svc imports $other/.env but not $other/config.env (cross-service env-split incomplete)|add '      - \${DOCKER_APP_DIR}/$other/config.env' to env_file: in $cf"
    elif [ "$loads_other_cfg" -gt 0 ] && [ "$loads_other_env" -eq 0 ]; then
      echo "HIGH|env|$svc imports $other/config.env but not $other/.env (cross-service secrets missing)|add '      - \${DOCKER_APP_DIR}/$other/.env' to env_file: in $cf"
    fi
  done
done
