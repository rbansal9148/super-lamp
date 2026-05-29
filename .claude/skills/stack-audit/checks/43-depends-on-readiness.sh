#!/bin/bash
# depends_on readiness — a service depends on a stateful service (DB/cache) that
# HAS a healthcheck, but with condition: service_started (or list-form, which
# normalises to service_started). On `docker compose restart` / host reboot the
# depender starts the moment the dependency container is *created* — before it's
# *ready* — racing into connection failures and cascade restarts. The fix is
# `condition: service_healthy`.
#
# Only flagged when the dependency actually defines a healthcheck (otherwise
# service_healthy is impossible and the warning would be noise). Maintenance
# sidecars (_vacuum/_prune/_init/_migrate/_backup) are exempt — they run after
# startup, off the critical path.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

ROOT="${DOCKER_ROOT:-/opt/docker}"
command -v jq >/dev/null 2>&1 || exit 0

cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT
docker compose -f "$ROOT/compose.yaml" config --format json > "$cfg" 2>/dev/null || exit 0

jq -r '
  .services as $svcs
  | .services | to_entries[]
  | .key as $svc
  | (.value.depends_on // {}) | to_entries[]
  | select(.value.condition == "service_started")
  | select($svc | test("_(vacuum|prune|init|migrate|backup)$") | not)
  | .key as $dep
  | select($dep | test("postgres|redis|mysql|mariadb|mongo|valkey|_db$|database"))
  | select(($svcs[$dep].healthcheck // null) != null)
  | "\($svc)\t\($dep)"
' "$cfg" 2>/dev/null | while IFS=$'\t' read -r svc dep; do
  [ -z "$svc" ] && continue
  echo "MED|reliability|$svc depends_on $dep with condition service_started, but $dep has a healthcheck — startup race on reboot/recreate|set 'condition: service_healthy' for $dep in $svc's depends_on in the relevant apps/<svc>/compose.yaml"
done
