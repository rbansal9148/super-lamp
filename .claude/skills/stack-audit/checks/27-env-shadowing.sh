#!/bin/bash
# Compose silently lets environment: override env_file: (and later env_file
# entries override earlier ones). Same KEY in both is almost always a typo
# (operator meant to override different file but referenced one already
# overridden, or forgot env_file already defines it). Flag any explicit
# overlap so it gets reviewed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

APPS="/opt/docker/apps"

python3 - <<'PY'
import os, re, pathlib, yaml
from collections import defaultdict

KV = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=", re.M)

apps_root = pathlib.Path("/opt/docker/apps")
for compose_path in sorted(apps_root.glob("*/compose.yaml")):
    svc_dir = compose_path.parent
    try:
        doc = yaml.safe_load(compose_path.read_text()) or {}
    except Exception:
        continue
    for svc_name, svc in (doc.get("services") or {}).items():
        env_files = svc.get("env_file") or []
        if isinstance(env_files, str):
            env_files = [env_files]
        env_block_raw = svc.get("environment") or {}
        if isinstance(env_block_raw, list):
            kv = {}
            for e in env_block_raw:
                if isinstance(e, str) and "=" in e:
                    k, v = e.split("=", 1)
                    kv[k] = v
        elif isinstance(env_block_raw, dict):
            kv = {k: (str(v) if v is not None else "") for k, v in env_block_raw.items()}
        else:
            kv = {}
        # Skip the `KEY=${KEY}` pass-through pattern — it's intentional re-export,
        # not a silent override (compose interpolates from env_file → environment
        # writes back the same value).
        env_block_keys = {
            k for k, v in kv.items()
            if v.strip() not in (f"${{{k}}}", f"${k}")
        }
        if not env_block_keys:
            continue
        # Collect keys defined by each env_file (resolve relative to svc dir)
        env_file_keys = defaultdict(set)
        for ef in env_files:
            if not isinstance(ef, str):
                continue
            # env_file entries may be `name` or `${VAR}/name` — relative paths only here
            if ef.startswith("${") or ef.startswith("/"):
                continue
            p = svc_dir / ef
            if not p.exists():
                continue
            try:
                content = p.read_text()
            except Exception:
                continue
            for m in KV.finditer(content):
                env_file_keys[ef].add(m.group(1))
        for ef, keys in env_file_keys.items():
            shadowed = sorted(env_block_keys & keys)
            if shadowed:
                show = ", ".join(shadowed[:4]) + ("…" if len(shadowed) > 4 else "")
                print(
                    f"MED|config|{svc_dir.name}.{svc_name} env_file={ef} and environment: "
                    f"both define {len(shadowed)} key(s) ({show}). environment wins — likely a typo|"
                    f"remove the duplicates from environment: or env_file, whichever is wrong"
                )
PY
