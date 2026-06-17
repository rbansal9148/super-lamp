#!/bin/bash
# Client-facing endpoints wrongly hidden behind SSO (behavioral probe).
#
# Some services serve NON-BROWSER clients (Stremio addons, plain APIs) whose entrypoints
# must stay reachable without an interactive Authelia session. When a forward-auth
# middleware over-matches and swallows such a path, the service stays Running/Ready and
# every dashboard is green — but the client receives a 302 to the login portal (an HTML
# page) instead of its payload. This is the paperless-ALLOWED_HOSTS class: up, but every
# real request fails. No metric sees it; only the client does. (Jun 2026: aiostreams
# /api/v1/debrid/playback got gated → players got the login page → "unrecognized format".)
#
# The probe sends a bogus-but-prefix-matching path, so it tests the ROUTING decision
# (is the auth middleware applied to this prefix?) without needing a valid signed URL.
# A redirect to $AUTH_PORTAL_HOST means the gate is mis-applied to a must-be-public path.
#
# Could graduate to a blackbox-exporter Grafana alarm later; until one exists, it lives
# here as a config-derived behavioral invariant.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v curl >/dev/null 2>&1 || { echo "LOW|audit/07-public-endpoints|curl not found — public-endpoint auth-gating probe skipped|install curl"; exit 0; }
PORTAL="${AUTH_PORTAL_HOST:-auth.my-blue-car.work}"
TMO="${PUBLIC_ENDPOINT_PROBE_TIMEOUT:-10}"

reachable=0
# Read probes deterministically (already a fixed, sorted seed list in thresholds.sh).
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [ -z "$line" ] && continue
  host="${line%% *}"; path="${line#* }"
  url="https://${host}${path}"
  # A transient curl/DNS failure on ONE probe must NOT silently vanish: the all-failed
  # marker below only fires when reachable==0, so a 1-of-N partial run would otherwise emit
  # neither this probe's verdict nor any marker — the auth-gating verdict would flicker with
  # network weather. Emit a per-probe inconclusive LOW instead of a silent drop.
  hdr=$(curl -sS -o /dev/null -D - --max-time "$TMO" "$url" 2>/dev/null) || { echo "LOW|audit/07-public-endpoints|probe ${host}${path} unreachable this run — auth-gating verdict UNKNOWN (not a pass)|re-run from a host that can resolve the public hostnames"; continue; }
  [ -z "$hdr" ] && { echo "LOW|audit/07-public-endpoints|probe ${host}${path} returned no headers this run — auth-gating verdict UNKNOWN (not a pass)|re-run from a host that can resolve the public hostnames"; continue; }
  reachable=$((reachable+1))
  loc=$(printf '%s' "$hdr" | grep -i '^location:' | head -1)
  if printf '%s' "$loc" | grep -qi "$PORTAL"; then
    echo "HIGH|ingress/auth-gating|${host}${path} is redirected to the SSO portal (${PORTAL}) but is declared a must-be-public client endpoint — non-browser clients receive the HTML login page instead of their payload|exclude this path from the forward-auth middleware in the service's IngressRoute (gate only the human UI / config paths)"
  fi
done <<< "$PUBLIC_ENDPOINT_PROBES"

# Graceful degrade: if nothing was reachable (audit host offline / DNS blocked), say so
# once rather than emit misleading green or false positives.
[ "$reachable" -eq 0 ] && echo "LOW|audit/07-public-endpoints|no probe endpoint was reachable (offline audit host or DNS blocked) — auth-gating probe inconclusive this run|re-run from a host that can resolve the public hostnames"
exit 0
