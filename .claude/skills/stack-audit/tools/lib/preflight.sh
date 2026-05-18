#!/bin/bash
# preflight.sh — sourced helpers used by every fixer to fail fast on a
# missing prerequisite instead of silently corrupting state midway.
#
# Caller is expected to `set -uo pipefail` first and `. lib/preflight.sh`.

# Exit with a clear, prefixed message.
die() { echo "[preflight] $*" >&2; exit 2; }

preflight_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI not in PATH"
  docker info >/dev/null 2>&1 || die "docker daemon unreachable"
}

preflight_root_writable() {
  local root="${DOCKER_ROOT:-/opt/docker}"
  [ -w "$root" ] || die "$root not writable by $(id -un)"
}

# Verify a list of containers is running. Usage: preflight_containers c1 c2 ...
preflight_containers() {
  local missing=()
  local c
  for c in "$@"; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || missing+=("$c")
  done
  [ "${#missing[@]}" -eq 0 ] || die "containers not running: ${missing[*]}"
}

# Verify a postgres extension exists in <container> <db>.
preflight_pg_extension() {
  local c="$1" db="$2" ext="$3"
  local user="${c%_postgres}"
  docker exec "$c" psql -U "$user" -d "$db" -At \
    -c "SELECT 1 FROM pg_extension WHERE extname='$ext';" 2>/dev/null \
    | grep -q '^1$' || die "extension '$ext' not installed in $c/$db"
}

# Run the default preflights (docker + writable root). Tools call this at start.
preflight_default() {
  preflight_docker
  preflight_root_writable
}
