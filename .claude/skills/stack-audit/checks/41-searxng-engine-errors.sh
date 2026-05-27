#!/bin/bash
# SearxNG engine health.
#
# Counts ERROR:searx.engines.<name> lines over the lookback window and
# flags engines that exceed the threshold. Skips engines that are
# already `disabled: true` in settings.yml so the check doesn't keep
# nagging after a fix.
#
# Why a single count threshold works: SearxNG's `suspended_time` clamps
# the retry rate of engines hit with 403 / 429 / CAPTCHA — at
# suspended_time=1800-7200s these engines can only re-error ~1-2x/hr.
# Engines that have no suspend path (lxml ParserError on empty body,
# bare HTTP timeout) re-error on every search attempt and blow past
# the threshold immediately.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | grep -q '^searxng$' || exit 0

settings=/opt/docker/apps/searxng/settings.yml
[ -f "$settings" ] || exit 0

# Build the set of disabled engine names (yaml-aware via python).
disabled=$(python3 - <<'PY' 2>/dev/null
import yaml
try:
    with open('/opt/docker/apps/searxng/settings.yml') as f:
        s = yaml.safe_load(f)
    for e in s.get('engines', []):
        if e.get('disabled'):
            print(e.get('name'))
except Exception:
    pass
PY
)

# Extract ERROR:searx.engines.<name> from logs in the window; count per engine.
docker logs --since "${SEARXNG_ENGINE_ERR_WINDOW_HRS}h" searxng 2>&1 \
  | grep -oE 'ERROR:searx\.engines\.[a-z0-9_ ]+' \
  | sed 's/ERROR:searx\.engines\.//' \
  | sort | uniq -c | sort -rn \
  | while read -r cnt engine; do
      [ -z "$cnt" ] && continue
      # Skip already-disabled engines
      if echo "$disabled" | grep -Fxq "$engine"; then continue; fi
      if [ "$cnt" -ge "$SEARXNG_ENGINE_ERR_HIGH" ] 2>/dev/null; then
        sev=HIGH
      elif [ "$cnt" -ge "$SEARXNG_ENGINE_ERR_WARN" ] 2>/dev/null; then
        sev=MED
      else
        continue
      fi
      echo "${sev}|searxng|engine '$engine' errored ${cnt}× in last ${SEARXNG_ENGINE_ERR_WINDOW_HRS}h (warn ≥${SEARXNG_ENGINE_ERR_WARN}) — likely broken from this IP|set 'disabled: true' on the '$engine' block in apps/searxng/settings.yml and docker compose restart searxng"
    done
