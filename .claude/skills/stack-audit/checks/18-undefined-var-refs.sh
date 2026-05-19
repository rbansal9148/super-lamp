#!/bin/bash
# Detect ${VAR} references in compose.yaml that won't resolve at recreate time.
# Rules:
#   - ${VAR:-default} is always OK (has fallback)
#   - ${VAR?error} or ${VAR} with no default must be defined in:
#       * the same service's env_file list, OR
#       * /opt/docker/.env (top-level), OR
#       * the current shell env
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

APPS="/opt/docker/apps"
ROOT_ENV="/opt/docker/.env"

python3 - <<'PY' 2>/dev/null
import os, re, sys
from pathlib import Path

apps = Path("/opt/docker/apps")
root_env = Path("/opt/docker/.env")
shell_env = set(os.environ.keys())

# Build set of enabled services from top-level compose.yaml.
# Only flag undefined vars in services that are actually included (uncommented).
enabled = set()
top = Path("/opt/docker/compose.yaml")
if top.exists():
    for ln in top.read_text().splitlines():
        m = re.match(r'^\s*-\s*apps/([^/]+)/compose\.yaml', ln)
        if m: enabled.add(m.group(1))

# Load top-level env vars
top_vars = set()
if root_env.exists():
    for ln in root_env.read_text().splitlines():
        m = re.match(r'^([A-Z_][A-Z0-9_]*)=', ln)
        if m: top_vars.add(m.group(1))

VAR_RE = re.compile(r'\$\{([A-Z_][A-Z0-9_]*)(:?-[^}]*|\?[^}]*)?\}')

for cf in sorted(apps.glob("*/compose.yaml")):
    svc_dir = cf.parent
    svc = svc_dir.name
    if enabled and svc not in enabled:
        continue  # disabled at top-level — don't flag latent issues
    txt = cf.read_text()
    refs = {}  # var -> first line number
    for i, line in enumerate(txt.splitlines(), 1):
        for m in VAR_RE.finditer(line):
            var, sfx = m.group(1), m.group(2) or ""
            # Skip those with a default value (e.g. :-foo)
            if sfx.startswith(":-") or sfx.startswith("-"):
                continue
            if var not in refs:
                refs[var] = i

    # Gather defined vars from env_file list (resolve ${DOCKER_APP_DIR} only)
    defined = set(top_vars) | shell_env
    for m in re.finditer(r'env_file:\s*\n((?:\s*-\s*[^\n]+\n)+)|env_file:\s*([^\n]+)', txt):
        block = m.group(1) or ("- " + m.group(2) + "\n")
        for ln in block.splitlines():
            ef = re.sub(r'^\s*-\s*', '', ln).strip().strip('"\'')
            if not ef: continue
            ef = ef.replace('${DOCKER_APP_DIR}', '/opt/docker/apps')
            # Make relative paths resolve from compose-file dir
            ef_path = Path(ef) if ef.startswith('/') else svc_dir / ef
            if ef_path.exists():
                for el in ef_path.read_text().splitlines():
                    mm = re.match(r'^([A-Z_][A-Z0-9_]*)=', el)
                    if mm: defined.add(mm.group(1))

    for var, lineno in refs.items():
        if var in defined: continue
        # Skip well-known compose-built-ins
        if var in {"DOCKER_APP_DIR", "DOCKER_DATA_DIR", "DOCKER_NETWORK", "DOCKER_DIR", "PWD", "HOME"}:
            continue
        # Use HIGH for credentials/keys patterns; else MED
        sev = "HIGH" if re.search(r'(KEY|TOKEN|SECRET|PASSWORD|API)', var) else "MED"
        print(f"{sev}|env|{svc}: ${{{var}}} referenced at line {lineno} is not defined anywhere it can reach|define {var}= in /opt/docker/apps/{svc}/.env or /opt/docker/.env")
PY
