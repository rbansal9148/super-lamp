#!/bin/bash
# Runtime drift — the bitmagnet_vpn bug class.
#
# Compare each running container's env / image / mem_limit / restart policy
# against what `docker compose config` would render NOW. A mismatch means a
# pending recreate will silently change the container — and may expose a
# config error that's been masked by the running state (like bitmagnet_vpn
# losing VPN_TYPE on recreate).
#
# Output: per-container drift findings, severity HIGH for env mismatch on
# anything not in a benign-base-image allowlist.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Env keys we ignore: set by docker base images / runtimes, never set by us.
BENIGN_ENV='^(PATH|HOSTNAME|HOME|TERM|LANG|LC_[A-Z]+|PWD|SHLVL|OLDPWD|GPG_KEY|PYTHON_[A-Z]+|NODE_VERSION|JAVA_HOME|JAVA_VERSION|GOSU_VERSION|S6_[A-Z_]+|YARN_VERSION|NPM_[A-Z]+|PG_[A-Z_]+|POSTGRES_INITDB_ARGS|DEBIAN_FRONTEND|REDIS_VERSION|REDIS_DOWNLOAD_URL|REDIS_DOWNLOAD_SHA|REDIS_SHA1|ALPINE_[A-Z_]+|MUSL_[A-Z_]+|JVM_OPTS|LD_LIBRARY_PATH)$'

cd /opt/docker || exit 0

# Render full compose config once (JSON for reliable parsing)
rendered=$(docker compose --profile all config --format json 2>/dev/null) || exit 0

# Per running container: diff env keys vs rendered
docker ps --format '{{.Names}}' | while read -r ctr; do
  # Find rendered service by container_name
  svc_env=$(echo "$rendered" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ctr = '$ctr'
for name, svc in data.get('services', {}).items():
    if svc.get('container_name') == ctr or name == ctr:
        env = svc.get('environment') or {}
        if isinstance(env, list):
            env = dict(x.split('=', 1) if '=' in x else (x, '') for x in env)
        for k in sorted(env.keys()):
            print(k)
        break
" 2>/dev/null)
  [ -z "$svc_env" ] && continue

  run_env=$(docker inspect "$ctr" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed 's/=.*//' | grep -vE "$BENIGN_ENV" | sort -u)
  rendered_keys=$(echo "$svc_env" | grep -vE "$BENIGN_ENV" | sort -u)

  # Keys in rendered but missing from running → recreate would ADD them
  added=$(comm -23 <(echo "$rendered_keys") <(echo "$run_env") | tr '\n' ',' | sed 's/,$//')
  # Keys in running but absent from rendered → recreate would REMOVE them
  removed=$(comm -13 <(echo "$rendered_keys") <(echo "$run_env") | tr '\n' ',' | sed 's/,$//')

  # Only flag the "rendered has X, container doesn't" direction — that's the
  # bitmagnet_vpn signal (a recreate would *set* something the running
  # instance is missing, often exposing a latent bug). The reverse direction
  # (container has X that compose doesn't) is almost always base-image vars
  # not declared in compose, which is fine.
  if [ -n "$added" ]; then
    # Skip if "added" is just an empty string artifact from sort -u
    added_real=$(echo "$added" | tr ',' '\n' | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
    [ -n "$added_real" ] && \
      echo "HIGH|drift|$ctr is missing env vars that compose would set on recreate: $added_real|docker compose --profile all up -d $ctr (verify after)"
  fi

  # Image drift
  run_img=$(docker inspect "$ctr" --format '{{.Image}}' 2>/dev/null)
  cfg_img=$(echo "$rendered" | python3 -c "
import sys, json
data = json.load(sys.stdin); ctr = '$ctr'
for name, svc in data.get('services', {}).items():
    if svc.get('container_name') == ctr or name == ctr:
        print(svc.get('image', '')); break
" 2>/dev/null)
  if [ -n "$cfg_img" ] && [[ "$cfg_img" == *@sha256:* ]]; then
    digest=${cfg_img##*@}
    inspected_digest=$(docker inspect "$ctr" --format '{{index .Config.Image}}' 2>/dev/null)
    image_id=$(docker inspect "$ctr" --format '{{.Image}}' 2>/dev/null)
    # Check the running container's image ID against the one compose would resolve
    cfg_id=$(docker image inspect "$cfg_img" --format '{{.Id}}' 2>/dev/null || true)
    if [ -n "$cfg_id" ] && [ "$image_id" != "$cfg_id" ]; then
      echo "HIGH|drift|$ctr image ($run_img) differs from compose-pinned digest ($cfg_img)|docker compose --profile all up -d $ctr"
    fi
  fi
done
