#!/bin/bash
# Existing 02-containers.sh flags missing healthchecks. This catches the
# opposite shape: critical services that DO have a healthcheck but the
# interval is wide enough that a hung-state goes undetected for minutes.
# Default warn ≥120s for streaming-path services (a stuck addon backs up
# upstream callers fast).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${HEALTHCHECK_INTERVAL_WARN_SEC:=120}"

CRITICAL_SVCS="aiostreams comet mediafusion stremthru bitmagnet zilean prowlarr aiometadata authelia traefik gluetun"

python3 - "$HEALTHCHECK_INTERVAL_WARN_SEC" "$CRITICAL_SVCS" <<'PY'
import subprocess, json, sys

warn_sec = int(sys.argv[1])
critical = set(sys.argv[2].split())

def parse_dur(s):
    """Parse Go-style durations like '30s', '1m30s', '5m'."""
    if not s:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    s = str(s).strip()
    total = 0.0
    num = ""
    for ch in s:
        if ch.isdigit() or ch == ".":
            num += ch
        elif ch in "hms":
            if not num:
                continue
            v = float(num)
            total += {"h": 3600, "m": 60, "s": 1}[ch] * v
            num = ""
    if num and not total:
        total = float(num)  # bare number => seconds
    return total or None

for c in critical:
    try:
        out = subprocess.run(
            ["docker", "inspect", "--format", "{{json .Config.Healthcheck}}", c],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout.strip()
    except Exception:
        continue
    if not out or out == "null":
        continue
    try:
        hc = json.loads(out)
    except Exception:
        continue
    interval_ns = hc.get("Interval")
    if not interval_ns:
        continue
    # Docker reports interval as nanoseconds (int)
    interval_sec = interval_ns / 1e9 if isinstance(interval_ns, (int, float)) else parse_dur(interval_ns)
    if not interval_sec:
        continue
    if interval_sec >= warn_sec:
        print(
            f"MED|containers|{c} healthcheck interval is {int(interval_sec)}s "
            f"(warn ≥{warn_sec}s) — hung-state detection lag|"
            f"set healthcheck.interval to 30s in apps/{c}/compose.yaml"
        )
PY
