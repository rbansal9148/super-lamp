#!/bin/bash
# Surface env vars on running containers that reference an internal docker
# hostname which doesn't exist. Catches the stremthru_redis class: env was
# set (STREMTHRU_REDIS_URI=redis://stremthru_redis:6379) but the referenced
# service was never defined in compose. Stremthru fell back silently to an
# unused in-memory cache → 14-16s per /stremio/store stream call instead of
# 0.07s with Redis. Invisible without a deep trace because the upstream
# service "gracefully degraded" rather than erroring.
#
# Heuristic for "internal docker hostname":
#   - No dots (not a FQDN like api.example.com)
#   - Not an IP (no /^[0-9.]+$/)
#   - Not localhost/0.0.0.0/127.0.0.1/::1
#   - Length > 2
#
# We then check if any RUNNING container has that exact name. If not,
# someone set the env once, the referenced service vanished or never
# existed, and the dependent container is silently misbehaving.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

# Patterns of URI-like env values to scrape. Each captures the hostname.
# Avoid double-matching: parse with python for clarity.

running=$(docker ps --format '{{.Names}}' | sort -u)

for ctr in $(docker ps --format '{{.Names}}' | sort -u); do
  docker inspect "$ctr" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
    CTR="$ctr" RUNNING="$running" python3 -c "
import sys, re, os
running = set(os.environ.get('RUNNING','').split())
ctr = os.environ.get('CTR','?')
# URI patterns: scheme://[user[:pw]@]host[:port][...]
uri_re = re.compile(r'^([A-Z_][A-Z0-9_]*)=([a-z][a-z0-9+.-]*://(?:[^@/\s]+@)?([a-zA-Z0-9._-]+)(?::\d+)?)')
# Special: postgresql://... is handled by the same regex.
# Also catch bare HOST=name patterns common in postgres envs.
host_re = re.compile(r'^([A-Z_]*HOST[A-Z_]*)=([a-zA-Z0-9._-]+)\$')
seen = set()
for line in sys.stdin:
    line = line.rstrip('\n')
    m = uri_re.match(line)
    host = None; key = None; value = None
    if m:
        key, value, host = m.group(1), m.group(2), m.group(3)
    else:
        m2 = host_re.match(line)
        if m2:
            key, host = m2.group(1), m2.group(2)
            value = host
    if not host:
        continue
    # Filter out non-internal hostnames
    if '.' in host:                # FQDN
        continue
    if re.fullmatch(r'[0-9.]+', host):  # IP
        continue
    if host in {'localhost','0.0.0.0','127.0.0.1','::1','host','db'}:
        continue
    # Boolean/scalar values that the bare-HOST regex spuriously catches
    # (e.g. DASHDOT_SHOW_HOST=true — a toggle, not a hostname).
    if host.lower() in {'true','false','yes','no','on','off','none','null'}:
        continue
    if host.isdigit():
        continue
    if len(host) < 3:
        continue
    # \$VAR-style unresolved templating
    if host.startswith('\$'):
        continue
    # Skip the container itself (some apps reference their own hostname)
    if host == ctr:
        continue
    # Already reported for this container? dedupe.
    if (host, key) in seen:
        continue
    seen.add((host, key))
    if host not in running:
        print(f'MED|config-drift|{ctr} env {key} references docker hostname \"{host}\" but no running container by that name exists — silent fallback risk|verify {ctr} is using the intended backend (often a redis or db); add the missing service to compose or correct the env value to a running hostname')
"
done
