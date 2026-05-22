#!/bin/bash
# Cross-service TZ consistency. Mixed TZ values silently break log correlation
# during incident response (timestamps from different containers won't line up).
# Emit MED if more than one explicit non-UTC TZ value is set across the
# rendered compose tree. UTC defaults are fine.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

cd /opt/docker || exit 0

# Extract TZ values per service from rendered compose (covers env_file + environment:)
python3 - <<'PY'
import subprocess, json, sys, collections, pathlib, re

# Top-level .env already pinning TZ? Then ${TZ:-...} substitutions across the
# stack inherit it; the only inconsistency surfaceable here would be a hardcoded
# TZ that disagrees with the top-level one. Treat top-level pin as the source
# of truth.
top_env = pathlib.Path("/opt/docker/.env")
top_tz = None
if top_env.exists():
    for line in top_env.read_text().splitlines():
        m = re.match(r"^\s*TZ\s*=\s*(\S+)", line)
        if m:
            top_tz = m.group(1).strip("'\"")
            break
try:
    raw = subprocess.run(
        ["docker", "compose", "--profile", "all", "config", "--format", "json"],
        capture_output=True, text=True, check=True, timeout=30,
    ).stdout
    data = json.loads(raw)
except Exception:
    sys.exit(0)

explicit = collections.defaultdict(list)   # tz -> [services]
unset = []
for name, svc in (data.get("services") or {}).items():
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) for e in env if "=" in e)
    tz = (env.get("TZ") or "").strip()
    if tz:
        explicit[tz].append(name)
    else:
        unset.append(name)

non_utc = {tz: svcs for tz, svcs in explicit.items() if tz.upper() != "UTC"}

# Top-level TZ pinned? Only flag explicit disagreements with it. Services that
# never reference ${TZ} inherit the container image default (usually UTC); that
# is a different (per-service) decision, not a stack-level inconsistency.
if top_tz and top_tz.upper() != "UTC":
    conflicting = {tz: svcs for tz, svcs in non_utc.items() if tz != top_tz}
    if conflicting:
        sample = ", ".join(f"{tz}({len(svcs)})" for tz, svcs in sorted(conflicting.items()))
        print(
            f"MED|config|TZ={top_tz} pinned in /opt/docker/.env but {len(conflicting)} other "
            f"non-UTC TZ value(s) hardcoded: {sample}|align hardcoded TZ to {top_tz} or use ${{TZ}}"
        )
elif len(non_utc) > 1:
    sample = ", ".join(f"{tz}({len(svcs)})" for tz, svcs in sorted(non_utc.items()))
    print(
        f"MED|config|{len(non_utc)} distinct non-UTC TZ values and no top-level pin: {sample}|"
        f"pick one TZ for /opt/docker/.env; mixed TZ breaks log correlation"
    )
elif len(non_utc) == 1 and len(unset) > 0 and not top_tz:
    tz, svcs = next(iter(non_utc.items()))
    print(
        f"LOW|config|TZ={tz} on {len(svcs)} services but no top-level pin in /opt/docker/.env|"
        f"add TZ={tz} to /opt/docker/.env so ${{TZ}}-referencing services inherit it"
    )
PY
