#!/bin/bash
# add_logging.sh — add a default json-file logging cap (10m × 3) to every
# top-level service in apps/*/compose.yaml that lacks a `logging:` block.
#
# Detection: a key directly under the top-level `services:` mapping whose
# body does NOT contain a `logging:` key. Sub-keys inside a service (such as
# `environment:`, `labels:`, `volumes:`, `healthcheck:`) are NEVER inserted
# under, even if their indent superficially matches.
#
# Top-level mappings other than `services:` (`networks:`, `volumes:`,
# `configs:`, `secrets:`) are NEVER touched.
#
# Flags:
#   --dry-run        report only
#   --size=10m       override max-size (default 10m)
#   --files=3        override max-file (default 3)

set -uo pipefail
ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0
SIZE="10m"
FILES=3
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --size=*) SIZE="${a#--size=}" ;;
    --files=*) FILES="${a#--files=}" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

ADDED=0; SKIPPED=0
for cf in "$ROOT"/apps/*/compose.yaml; do
  out=$(python3 - "$cf" "$SIZE" "$FILES" "$DRY" <<'PY'
import sys, re, pathlib
cf, size, files_n, dry = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
P = pathlib.Path(cf)
text = P.read_text()
lines = text.splitlines()

# Pass 1: locate every direct child of `services:` (service header lines).
#
# A "service header" is a line:
#   - at exactly N spaces of indent (N = the body-indent of `services:`)
#   - whose content is `<name>:` (no value)
# We only enter "services" mode when we see a top-level `services:` (indent 0).
service_headers = []  # (line_idx, indent, body_indent)
in_services = False
services_body_indent = None
i = 0
while i < len(lines):
    L = lines[i]
    stripped = L.strip()
    indent = len(L) - len(L.lstrip())
    if indent == 0 and stripped.endswith(":"):
        # Top-level section change
        in_services = (stripped[:-1] == "services")
        services_body_indent = None
        i += 1
        continue
    if not in_services:
        i += 1
        continue
    if not stripped or stripped.startswith("#"):
        i += 1
        continue
    if services_body_indent is None:
        services_body_indent = indent
    # A service header is at services_body_indent AND ends with ":"
    if indent == services_body_indent and re.match(r'^[A-Za-z0-9_-]+:\s*$', stripped):
        service_headers.append((i, indent))
    i += 1

# For each service header, check if its block already has `logging:` at
# child-indent (header_indent + 2). If not, plan an insertion right after
# the `restart:` line (or the header if no restart).
insertions = []  # (insert_at_line, indent_for_logging, [block lines])
n_added = 0
n_skipped = 0
for idx, (hdr, hindent) in enumerate(service_headers):
    child_indent = hindent + 2
    # End of this block is the next service header line OR the next non-empty
    # line at indent <= hindent.
    end = len(lines)
    if idx + 1 < len(service_headers):
        end = service_headers[idx + 1][0]
    has_logging = False
    insert_after = hdr  # default: right after header
    j = hdr + 1
    while j < end:
        LL = lines[j]
        s = LL.strip()
        if s and not s.startswith("#"):
            d = len(LL) - len(LL.lstrip())
            if d == child_indent and s.startswith("logging:"):
                has_logging = True
                break
            if d == child_indent and s.startswith("restart:"):
                insert_after = j
        j += 1
    if has_logging:
        n_skipped += 1
        continue
    pad1 = " " * child_indent
    pad2 = " " * (child_indent + 2)
    pad3 = " " * (child_indent + 4)
    block = [
        f"{pad1}logging:",
        f'{pad2}driver: "json-file"',
        f"{pad2}options:",
        f'{pad3}max-size: "{size}"',
        f'{pad3}max-file: "{files_n}"',
    ]
    insertions.append((insert_after + 1, block))
    n_added += 1

if dry:
    print(f"ADD {n_added}  SKIP {n_skipped}")
    sys.exit(0)
if n_added == 0:
    print(f"ADD 0  SKIP {n_skipped}")
    sys.exit(0)
new_lines = list(lines)
for idx_to_insert_at, block in sorted(insertions, key=lambda x: -x[0]):
    new_lines[idx_to_insert_at:idx_to_insert_at] = block
P.write_text("\n".join(new_lines) + ("\n" if text.endswith("\n") else ""))
print(f"ADD {n_added}  SKIP {n_skipped}")
PY
)
  added=$(echo "$out" | awk '{print $2}')
  skipped=$(echo "$out" | awk '{print $4}')
  if [ "${added:-0}" -gt 0 ]; then
    svc=$(basename "$(dirname "$cf")")
    echo "  $svc: +$added service block(s)"
    ADDED=$((ADDED + added))
  fi
  SKIPPED=$((SKIPPED + ${skipped:-0}))
done

if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN: would add logging to $ADDED service blocks ($SKIPPED already configured)"
else
  echo "added logging to $ADDED service blocks ($SKIPPED already configured)"
fi
