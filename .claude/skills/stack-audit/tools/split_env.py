#!/usr/bin/env python3
"""Split a Docker-style .env file into secrets.env and config.env.

Deterministic rules:
- A line stays in **.env** if EITHER:
  - KEY matches SECRET_KEY_REGEX (case-insensitive), and NOT NEVER_SECRET_REGEX, OR
  - VALUE contains an embedded credential pattern `://user:pass@host`, OR
  - KEY is referenced as `${KEY}` in the matching compose.yaml (compose's
    variable interpolation reads apps/<svc>/.env for INCLUDED compose files;
    if such a var is missing, `docker compose up` fails with
    "required variable X is missing a value").
- Everything else goes to **config.env**.

Comments and blank lines are attached to the NEXT KV line and follow it
into whichever bucket. Trailing comments after the last KV go to CONFIG.

The script is idempotent: if invoked on a file that's already secrets-only,
it produces the same .env (modulo the regenerated header).

Usage: split_env.py <input.env> <secrets_out.env> <config_out.env> [--weak-report <path>]

The optional --weak-report flag writes a list of weak/placeholder secret values
(e.g. `password`, `admin123`, `CHANGE_ME`, empty strings) to the given path so
they can be flagged for rotation.
"""
import re, sys, pathlib, argparse

# ---- Pattern catalog -------------------------------------------------------
# Order matters: NEVER_SECRET_REGEX is consulted FIRST and overrides SECRET_KEY_REGEX.

# Keys that LOOK secret-shaped but are not (timeouts, intervals, URLs, flags).
NEVER_SECRET_REGEX = re.compile(
    r"^(?:"
    r".+_CACHE_TTL"      # *_CACHE_TTL (durations)
    r"|.+_TIMEOUT"       # *_TIMEOUT
    r"|.+_INTERVAL.*"    # *_INTERVAL, *_INTERVAL_HOURS, etc.
    r"|.+_VALIDITY.*"    # *_VALIDITY_*
    r"|.+_ENABLED"       # boolean flags
    r"|.+_DISABLED"
    r"|.+_BASE_URL"      # URL bases without creds
    r"|.+_URL"           # generic URLs without creds (URI_WITH_CRED still catches credentialed ones)
    r"|.+_REDIRECT_URI"
    r"|.+_HOSTNAME"
    r"|.+_PATH"
    r"|.+_PORT"
    r"|.+_LIMIT"
    r"|.+_SIZE"
    r"|.+_COUNT"
    r"|.+_RATIO"
    r"|.+_THRESHOLD"
    r"|X_AUTHELIA_CONFIG_KEYS"
    r")$",
    re.IGNORECASE,
)

# Keys whose names indicate a secret value.
SECRET_KEY_REGEX = re.compile(
    r"(?:"
    r"PASSWORD"
    r"|SECRET"
    r"|TOKEN"
    r"|API[_-]?KEY"
    r"|ACCESS[_-]?KEY"
    r"|PRIVATE[_-]?KEY"
    r"|JWT"
    r"|CIPHER"
    r"|ENCRYPTION[_-]?KEY"
    r"|CREDENTIAL"
    r"|CLIENT[_-]?SECRET"
    r"|CLIENT[_-]?ID"     # OAuth client IDs are mildly sensitive; treat as secret
    r"|SESSION[_-]?KEY"
    r"|AUTH[_-]?KEY"
    r")",
    re.IGNORECASE,
)

# VALUE pattern: any URI with embedded user:pass@host credentials.
URI_WITH_CRED = re.compile(r"://[^/\s:]+:[^/\s@]+@")

# Compose substitution reference: ${VAR}, ${VAR?}, ${VAR:-default}, ${VAR:?msg}, $VAR
COMPOSE_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)|\$([A-Za-z_][A-Za-z0-9_]*)")

# KV line regex (handles optional `export ` prefix).
KV_LINE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*)$")

# Weak/placeholder values to flag (lowercased for comparison).
WEAK_VALUES = {
    "", "password", "admin", "admin123", "change_me", "changeme",
    "secret", "test", "demo", "default",
}
WEAK_VALUE_PATTERNS = [
    re.compile(r"^x+$", re.IGNORECASE),         # XXXXX...
    re.compile(r"^changeme_.*", re.IGNORECASE), # ChangeMe_*
    re.compile(r"^your_.*", re.IGNORECASE),     # YOUR_TOKEN_HERE
]

# ---- Classifier ------------------------------------------------------------

def extract_compose_vars(compose_path: pathlib.Path) -> set[str]:
    """Return the set of variable names referenced via $VAR or ${VAR...} in a
    compose.yaml. Docker Compose interpolates these from the .env file in the
    same directory as the (included) compose file. Vars not present there will
    cause `docker compose up` to fail when the var has the `?` required-marker.
    """
    if not compose_path.exists():
        return set()
    found = set()
    for m in COMPOSE_VAR_RE.finditer(compose_path.read_text()):
        name = m.group(1) or m.group(2)
        if name:
            found.add(name)
    return found

def must_stay_in_env(key: str, value: str, compose_vars: set[str]) -> bool:
    """Deterministic: return True if (key,value) must remain in apps/<svc>/.env
    (either because it is a secret, or because compose.yaml interpolates it)."""
    if key in compose_vars:
        return True
    if NEVER_SECRET_REGEX.match(key):
        return False
    val_unquoted = value.strip().strip("'\"")
    val_clean = re.sub(r"\s+#.*$", "", val_unquoted).strip()
    if URI_WITH_CRED.search(val_clean):
        return True
    if SECRET_KEY_REGEX.search(key):
        return True
    return False

def is_secret(key: str, value: str) -> bool:
    """Subset of must_stay_in_env: TRUE secrets (not just compose-substituted)."""
    if NEVER_SECRET_REGEX.match(key):
        return False
    val_unquoted = value.strip().strip("'\"")
    val_clean = re.sub(r"\s+#.*$", "", val_unquoted).strip()
    if URI_WITH_CRED.search(val_clean):
        return True
    if SECRET_KEY_REGEX.search(key):
        return True
    return False

def is_weak(value: str) -> bool:
    """True if the secret value is a weak/placeholder (worth rotating)."""
    v = value.strip().strip("'\"")
    # Drop inline comment
    v = re.sub(r"\s+#.*$", "", v).strip()
    if v.lower() in WEAK_VALUES:
        return True
    for p in WEAK_VALUE_PATTERNS:
        if p.match(v):
            return True
    return False

# ---- Main split -------------------------------------------------------------

HEADER_SECRETS = (
    "# Secrets — chmod 600, gitignored. Split by tools/split_env.py.\n"
    "# Add new secret-shaped vars here; non-secrets belong in config.env.\n"
    "# Rules: KEY contains PASSWORD/SECRET/TOKEN/API_KEY/JWT/etc, OR value is\n"
    "# a URI with embedded user:pass@host. Exceptions: *_CACHE_TTL, *_TIMEOUT,\n"
    "# *_INTERVAL, *_VALIDITY*, *_ENABLED, *_URL/_BASE_URL/_HOSTNAME are NOT secrets.\n"
    "\n"
)
HEADER_CONFIG = (
    "# Non-secret configuration. Safe to commit. Split by tools/split_env.py.\n"
    "# Add new non-secret vars here; secrets belong in .env.\n"
    "\n"
)

def split(in_path: pathlib.Path, secrets_path: pathlib.Path,
          config_path: pathlib.Path, weak_report: pathlib.Path | None = None,
          compose_path: pathlib.Path | None = None,
          source_label: str | None = None) -> dict:
    compose_vars = extract_compose_vars(compose_path) if compose_path else set()
    lines = in_path.read_text().splitlines(keepends=False)

    secrets_out: list[str] = []
    config_out: list[str] = []
    pending: list[str] = []
    weak: list[tuple[str, str]] = []  # (key, value)
    counts = {"secrets": 0, "config": 0, "weak": 0, "substituted": 0}

    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            pending.append(line)
            continue
        m = KV_LINE.match(line)
        if not m:
            pending.append(line)
            continue
        key, value = m.group(1), m.group(2)
        keep_in_env = must_stay_in_env(key, value, compose_vars)
        bucket = secrets_out if keep_in_env else config_out
        bucket.extend(pending)
        bucket.append(line)
        pending = []
        if keep_in_env:
            secret = is_secret(key, value)
            if secret:
                counts["secrets"] += 1
                if is_weak(value):
                    counts["weak"] += 1
                    weak.append((key, value))
            else:
                counts["substituted"] += 1
        else:
            counts["config"] += 1

    config_out.extend(pending)

    secrets_path.write_text(HEADER_SECRETS + "\n".join(secrets_out) + "\n")
    config_path.write_text(HEADER_CONFIG + "\n".join(config_out) + "\n")

    if weak_report is not None and weak:
        label = source_label or in_path.as_posix()
        with weak_report.open("a") as f:  # append so multi-service sweeps accumulate
            for k, v in weak:
                f.write(f"{label}\t{k}\t{v}\n")
    return counts

def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("secrets_out")
    ap.add_argument("config_out")
    ap.add_argument("--weak-report", default=None)
    ap.add_argument(
        "--compose-yaml",
        default=None,
        help="Compose file whose ${VAR} references should stay in the secrets file.",
    )
    ap.add_argument(
        "--source-label",
        default=None,
        help="Override path shown in the weak-report (use when input is a tempfile).",
    )
    ns = ap.parse_args(argv)
    c = split(
        pathlib.Path(ns.input),
        pathlib.Path(ns.secrets_out),
        pathlib.Path(ns.config_out),
        pathlib.Path(ns.weak_report) if ns.weak_report else None,
        pathlib.Path(ns.compose_yaml) if ns.compose_yaml else None,
        ns.source_label,
    )
    print(
        f"{ns.input}: {c['secrets']} secrets ({c['weak']} weak), "
        f"{c['substituted']} compose-substituted, {c['config']} config"
    )

if __name__ == "__main__":
    main(sys.argv[1:])
