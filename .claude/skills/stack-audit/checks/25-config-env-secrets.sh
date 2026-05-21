#!/bin/bash
# Detect secret-shaped values that ended up in apps/*/config.env (committed).
# Inverse of split_env.py: anything that would have been classified as a secret
# but is sitting in config.env is a finding. Also scans commented KV lines —
# split_env.py treats comments as preamble, so a commented secret can leak.
#
# Deterministic: same regex catalog as split_env.py (imported), placeholder
# values suppressed via split_env's is_weak() + a small example whitelist.
# No entropy heuristics, no external dependencies (Python stdlib only).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

APPS="/opt/docker/apps"
TOOLS="$(dirname "${BASH_SOURCE[0]}")/../tools"

python3 - "$APPS" "$TOOLS" <<'PY' 2>/dev/null
import sys, re, pathlib

apps_root = pathlib.Path(sys.argv[1])
tools_dir = pathlib.Path(sys.argv[2])

sys.path.insert(0, str(tools_dir))
try:
    from split_env import (
        SECRET_KEY_REGEX, NEVER_SECRET_REGEX, URI_WITH_CRED, KV_LINE, is_weak,
    )
except ImportError:
    sys.exit(0)  # tools missing — silent skip, not a regression

# Match commented KV lines:  `# VAR=value`, `#VAR=value`, with optional `export`.
COMMENTED_KV = re.compile(
    r"^\s*#+\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*)$"
)

# Broader-than-split_env secret-key patterns. Audit is the safety net, so it
# catches names split_env.py's conservative classifier missed (see commit
# 91b087d for the 3 historic false negatives: MEILI_MASTER_KEY, TMDB_API,
# commented TORBOX_API_KEY).
EXTRA_SECRET_KEY_REGEX = re.compile(
    r"(?:"
    r"MASTER[_-]?KEY"      # MEILI_MASTER_KEY etc.
    r"|HMAC"               # HMAC_SECRET, HMAC_KEY
    r"|SALT"               # password salts
    r"|SIGNATURE"          # signing keys
    r"|_API$"              # bare *_API (TMDB_API, OPENAI_API, …)
    r"|BEARER"
    r")",
    re.IGNORECASE,
)

# Tokens that mark a value as a documentation example rather than a real secret.
EXAMPLE_TOKENS = re.compile(
    r"(?:^|[\W_])(example|your[_-]?\w+|placeholder|todo|fixme|<[^>]+>|"
    r"single[_-](password|secret|token)|uuid\d*|password\d+|"
    r"admin\d*|change[_-]?me)(?:$|[\W_])",
    re.IGNORECASE,
)

# Values that are clearly non-secret literals (booleans, small integers).
LITERAL_VALUE = re.compile(
    r"^(?:true|false|yes|no|on|off|none|null|nil|-?\d{1,6})$",
    re.IGNORECASE,
)

def is_real_secret_value(value: str) -> bool:
    """True if VALUE looks like a real secret (not a doc placeholder)."""
    v = value.strip().strip("'\"")
    v = re.sub(r"\s+#.*$", "", v).strip()
    if not v or v.startswith("#"):     # `VAR=` or `VAR= # note` — no real value
        return False
    if is_weak(v):                     # `password`, `admin`, `changeme`, etc.
        return False
    if LITERAL_VALUE.match(v):         # `true`, `false`, `3600`, etc.
        return False
    if EXAMPLE_TOKENS.search(v):       # `your_token_here`, `<api-key>`, etc.
        return False
    return True

def is_secret_shaped(key: str, value: str) -> bool:
    if NEVER_SECRET_REGEX.match(key):
        return False
    val = value.strip().strip("'\"")
    val = re.sub(r"\s+#.*$", "", val).strip()
    if URI_WITH_CRED.search(val):
        return True
    if SECRET_KEY_REGEX.search(key):
        return True
    if EXTRA_SECRET_KEY_REGEX.search(key):
        return True
    return False

for cfg in sorted(apps_root.glob("*/config.env")):
    svc = cfg.parent.name
    try:
        lines = cfg.read_text().splitlines()
    except OSError:
        continue
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped:
            continue
        commented = stripped.startswith("#")
        m = COMMENTED_KV.match(line) if commented else KV_LINE.match(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if not is_secret_shaped(key, value):
            continue
        if not is_real_secret_value(value):
            continue
        tag = "commented" if commented else "active"
        print(
            f"HIGH|secret|{svc} config.env:{n} {key} ({tag}) holds secret-shaped "
            f"value in committed file|move {key}= to apps/{svc}/.env "
            f"(or rename if it is genuinely non-secret)"
        )
PY
