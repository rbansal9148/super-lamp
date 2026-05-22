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
import subprocess, json, sys, collections
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

if len(non_utc) > 1:
    sample = ", ".join(f"{tz}({len(svcs)})" for tz, svcs in sorted(non_utc.items()))
    print(
        f"MED|config|{len(non_utc)} distinct non-UTC TZ values across services: {sample}|"
        "pick one TZ for the whole stack; mixed TZ breaks log correlation"
    )
elif len(non_utc) == 1 and len(unset) > 0:
    tz, svcs = next(iter(non_utc.items()))
    print(
        f"LOW|config|TZ={tz} on {len(svcs)} services but {len(unset)} other services have no TZ set "
        f"(default UTC). Inconsistent: {svcs[:3]}{'…' if len(svcs)>3 else ''}|"
        f"either propagate TZ={tz} via top-level .env, or drop it everywhere and standardize on UTC"
    )
PY
