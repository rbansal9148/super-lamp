#!/bin/bash
# run.sh — golden-file tests for split_env.py.
#
# For each fixture `tools/test/fixtures/NAME.input.env`:
#   1. Run split_env.py on it (optionally with NAME.compose.yaml).
#   2. Diff the resulting secrets-output against NAME.expect-secrets.env.
#   3. Diff the resulting config-output against NAME.expect-config.env.
# Exit 0 on all green, non-zero if any test fails.
#
# Regenerate goldens (use with extreme care — manually inspect after):
#   bash run.sh --update
#
# Each fixture pins a specific behavior the splitter MUST preserve:
#   01-basic                 baseline secrets / config classification.
#   02-compose-substitution  ${VAR} refs from compose.yaml stay in .env.
#   03-uri-with-credentials  credentialed URIs are SECRET even with bland keys.
#   04-idempotent-resplit    re-splitting a previously-split file is a no-op
#                            (header is preserved; the input file IS the
#                            expected secrets output minus comment dedup).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPLITTER="$HERE/../split_env.py"
FX="$HERE/fixtures"
UPDATE=0
for a in "$@"; do
  case "$a" in
    --update) UPDATE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

PASS=0; FAIL=0
for inp in "$FX"/*.input.env; do
  name=$(basename "$inp" .input.env)
  comp_yaml="$FX/${name}.compose.yaml"
  exp_s="$FX/${name}.expect-secrets.env"
  exp_c="$FX/${name}.expect-config.env"

  tmp_s=$(mktemp); tmp_c=$(mktemp)
  ARGS=()
  [ -f "$comp_yaml" ] && ARGS=(--compose-yaml "$comp_yaml")

  python3 "$SPLITTER" "$inp" "$tmp_s" "$tmp_c" "${ARGS[@]}" >/dev/null

  if [ "$UPDATE" = "1" ]; then
    cp "$tmp_s" "$exp_s"
    cp "$tmp_c" "$exp_c"
    echo "  [updated] $name"
    rm -f "$tmp_s" "$tmp_c"
    PASS=$((PASS+1))
    continue
  fi

  fail=0
  if ! diff -u "$exp_s" "$tmp_s" >/tmp/${name}.secrets.diff 2>&1; then
    echo "  [FAIL] $name secrets mismatch:"
    sed 's/^/    /' /tmp/${name}.secrets.diff | head -20
    fail=1
  fi
  if ! diff -u "$exp_c" "$tmp_c" >/tmp/${name}.config.diff 2>&1; then
    echo "  [FAIL] $name config mismatch:"
    sed 's/^/    /' /tmp/${name}.config.diff | head -20
    fail=1
  fi
  if [ "$fail" -eq 0 ]; then
    echo "  [PASS] $name"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp_s" "$tmp_c"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
