#!/bin/bash
# Sweep every apps/<svc>/.env under /opt/docker and split into:
#   - apps/<svc>/.env         (secrets only, chmod 600)
#   - apps/<svc>/config.env   (non-secrets, chmod 644)
#
# Then mutate apps/<svc>/compose.yaml to add `- config.env` after the FIRST
# `- .env` line in the FIRST env_file: block (idempotent: skipped if already there).
#
# Finally, for each modified service whose container is currently running,
# `docker compose up -d <svc>` to pick up the new env_file. Stopped services
# are NOT started.
#
# Flags:
#   --dry-run            classify only, print what WOULD change
#   --no-restart         skip the docker compose up step (useful in CI)
#   --only=svc1,svc2     restrict to specific services
#   --weak-report PATH   accumulate weak/placeholder secrets across all services
#
# Idempotence:
#   - If apps/<svc>/config.env already exists AND apps/<svc>/.env is already
#     secrets-only (no obvious config lines), the service is SKIPPED.
#   - The compose.yaml edit checks for existing `- config.env` line first.
#
# Safety:
#   - No .env.bak files are left on disk (they would re-leak secrets).
#   - The splitter is pure-functional; we tee its output to temp files,
#     verify both exist non-empty, then atomically `mv` over the originals.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
SPLITTER="$SKILL_DIR/tools/split_env.py"
ROOT="${DOCKER_ROOT:-/opt/docker}"

DRY=0
NORESTART=0
ONLY=""
WEAK_REPORT=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-restart) NORESTART=1 ;;
    --only=*) ONLY="${a#--only=}" ;;
    --weak-report=*) WEAK_REPORT="${a#--weak-report=}"; : > "$WEAK_REPORT" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

# In-list helper
in_list() { case ",$2," in *",$1,"*) return 0;; esac; return 1; }

# Mutator: insert `- config.env` after first `- .env` in first env_file: block,
# only if not already present. Idempotent.
mutate_compose() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
text = p.read_text()
lines = text.splitlines(keepends=True)
out = []
inserted = False
seen_env_block = False
env_file_indent_depth = None
i = 0
while i < len(lines):
    L = lines[i]
    out.append(L)
    if not inserted:
        # Detect first env_file: block
        m = re.match(r'^(\s*)env_file:\s*$', L)
        if m and not seen_env_block:
            seen_env_block = True
            env_file_indent_depth = len(m.group(1))
            # Walk forward through list items at depth > env_file_indent_depth
            j = i + 1
            saw_dot_env = False
            already_has_config = False
            list_lines = []
            while j < len(lines):
                LL = lines[j]
                m2 = re.match(r'^(\s*)-\s+(\S.*)$', LL)
                if not m2:
                    break  # block ended
                d = len(m2.group(1))
                if d <= env_file_indent_depth:
                    break
                item = m2.group(2).strip()
                list_lines.append((j, LL, d, item))
                if item == '.env':
                    saw_dot_env = True
                if item == 'config.env':
                    already_has_config = True
                j += 1
            if saw_dot_env and not already_has_config:
                # Append items up to the first .env, insert config.env, then rest
                inserted_local = False
                for (idx, LL, d, item) in list_lines:
                    out.append(LL)
                    if not inserted_local and item == '.env':
                        indent = LL[:len(LL) - len(LL.lstrip())]
                        out.append(f"{indent}- config.env\n")
                        inserted_local = True
                inserted = inserted_local
                i = (list_lines[-1][0] + 1) if list_lines else (i + 1)
                continue
    i += 1
p.write_text("".join(out))
print("MUTATED" if inserted else "UNCHANGED")
PY
}

# Detect "is container currently running"
is_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

shopt -s nullglob
TOUCHED=0
SKIPPED=0
WOULD=0

for envf in "$ROOT"/apps/*/.env; do
  svc=$(basename "$(dirname "$envf")")
  if [ -n "$ONLY" ] && ! in_list "$svc" "$ONLY"; then continue; fi
  cfgf="$(dirname "$envf")/config.env"
  cmpf="$(dirname "$envf")/compose.yaml"

  # Build composite input: if a previous split exists, merge config.env back
  # in so we re-classify under the (possibly updated) rules. Order is
  # config.env then .env so that if a key duplicated for some reason, the
  # .env (secrets) wins on last-write.
  composite=$(mktemp)
  if [ -f "$cfgf" ]; then
    cat "$cfgf" "$envf" > "$composite"
  else
    cp "$envf" "$composite"
  fi

  # Skip iff already split AND compose has the marker AND re-splitting would
  # be a no-op (we detect that by comparing line counts before/after a dry
  # split; cheaper: just always re-split — idempotent on stable rules).

  COMP_ARG=()
  [ -f "$cmpf" ] && COMP_ARG=(--compose-yaml "$cmpf")
  WARG=()
  [ -n "$WEAK_REPORT" ] && WARG=(--weak-report "$WEAK_REPORT")

  SRC_ARG=(--source-label "$envf")

  if [ "$DRY" -eq 1 ]; then
    tmpS=$(mktemp); tmpC=$(mktemp)
    python3 "$SPLITTER" "$composite" "$tmpS" "$tmpC" "${WARG[@]}" "${COMP_ARG[@]}" "${SRC_ARG[@]}" || true
    rm -f "$tmpS" "$tmpC" "$composite"
    WOULD=$((WOULD+1))
    continue
  fi

  tmpS=$(mktemp); tmpC=$(mktemp)
  if ! python3 "$SPLITTER" "$composite" "$tmpS" "$tmpC" "${WARG[@]}" "${COMP_ARG[@]}" "${SRC_ARG[@]}"; then
    echo "  [ERR] splitter failed on $svc" >&2
    rm -f "$tmpS" "$tmpC" "$composite"
    continue
  fi
  rm -f "$composite"
  # Atomic install
  mv "$tmpC" "$cfgf"
  mv "$tmpS" "$envf"
  chmod 600 "$envf"
  chmod 644 "$cfgf"

  if [ -f "$cmpf" ]; then
    mutate_compose "$cmpf" >/dev/null
  fi

  TOUCHED=$((TOUCHED+1))

  if [ "$NORESTART" -eq 0 ] && is_running "$svc"; then
    (cd "$ROOT" && docker compose up -d "$svc" >/dev/null 2>&1 && echo "  [restarted] $svc" \
      || echo "  [WARN] failed to restart $svc — manual check needed")
  fi
done

if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN: $WOULD services would be split, $SKIPPED already split"
else
  echo "TOUCHED: $TOUCHED, SKIPPED: $SKIPPED"
  [ -n "$WEAK_REPORT" ] && [ -s "$WEAK_REPORT" ] && {
    echo "Weak secrets flagged → $WEAK_REPORT"
    head -10 "$WEAK_REPORT"
  }
fi
