#!/bin/bash
# lock_public_ports.sh — for any service that has Traefik labels but also
# publishes ports on 0.0.0.0/::, remove the `ports:` block. Traefik handles
# external access; the host-port publish bypasses Authelia.
#
# Detects services in apps/*/compose.yaml that have:
#   - at least one `traefik.http.routers.*` label, AND
#   - a `ports:` directive with non-127.0.0.1 mapping
#
# The remediation is conservative: it COMMENTS OUT the ports: block rather
# than deleting it, so re-enabling is trivial.
#
# Flags:
#   --dry-run     report candidates only

set -uo pipefail
ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0
# Services whose host-published ports are intentional. Never auto-lock these.
#   - traefik: needs 80/443/853 by definition
#   - gluetun / bitmagnet_vpn: VPN-side WireGuard/torrent ports
#   - plex: direct-connect from clients (DLNA, remote access)
#   - cloudflare-ddns: network_mode: host (no ports: block but skip just in case)
DEFAULT_SKIP="traefik,gluetun,bitmagnet_vpn,plex,cloudflare-ddns"
SKIP="$DEFAULT_SKIP"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --skip=*) SKIP="${a#--skip=}" ;;
    --add-skip=*) SKIP="$SKIP,${a#--add-skip=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

in_skip() { case ",$SKIP," in *",$1,"*) return 0;; esac; return 1; }

shopt -s nullglob
for cf in "$ROOT"/apps/*/compose.yaml; do
  svc=$(basename "$(dirname "$cf")")
  if in_skip "$svc"; then continue; fi
  python3 - "$cf" "$svc" "$DRY" <<'PY'
import sys, pathlib, re
cf, svc, dry = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = pathlib.Path(cf).read_text()
# Quick gate: must have traefik router label
if "traefik.http.routers." not in text:
    sys.exit(0)
lines = text.splitlines()
# Find a `ports:` block in the FIRST service (the one named svc).
# Find the `<svc>:` heading line.
svc_re = re.compile(rf'^\s+{re.escape(svc)}:\s*$')
service_start = None
for i, L in enumerate(lines):
    if svc_re.match(L):
        service_start = i; break
if service_start is None:
    sys.exit(0)
# Find `ports:` block within this service (until next sibling at same indent or higher)
header_indent = len(lines[service_start]) - len(lines[service_start].lstrip())
i = service_start + 1
ports_start = None
ports_end = None
in_ports = False
items_indent = None
problem = False
while i < len(lines):
    L = lines[i]
    indent = len(L) - len(L.lstrip())
    if L.strip() and indent <= header_indent and L.strip().endswith(":"):
        break  # next service
    if not in_ports:
        m = re.match(r'^(\s+)ports:\s*$', L)
        if m:
            ports_start = i
            items_indent = len(m.group(1))
            in_ports = True
            i += 1
            continue
    else:
        if L.strip().startswith("-"):
            # Check if maps a public port (anything not 127.0.0.1:)
            v = L.strip().lstrip('-').strip().strip('"').strip("'")
            if not v.startswith("127.0.0.1") and ("0.0.0.0" in v or ":" in v.split()[0]):
                problem = True
            ports_end = i
            i += 1
            continue
        else:
            break
    i += 1

if ports_start is None or not problem:
    sys.exit(0)

print(f"  candidate: {svc}  ports lines {ports_start+1}-{(ports_end or ports_start)+1}")
if dry:
    sys.exit(0)

# Comment out the ports block
end = ports_end if ports_end is not None else ports_start
new_lines = []
for idx, L in enumerate(lines):
    if ports_start <= idx <= end:
        new_lines.append("    # " + L.lstrip("\n"))  # crude indent; works for typical layouts
    else:
        new_lines.append(L)
pathlib.Path(cf).write_text("\n".join(new_lines) + ("\n" if text.endswith("\n") else ""))
print(f"    commented out ports in {cf}")
PY
done
