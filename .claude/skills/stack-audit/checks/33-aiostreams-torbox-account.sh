#!/bin/bash
# Cluster signal for "TorBox account broken" (rate-limit cap=0, sub lapsed,
# key revoked). Symptom: EVERY addon with a `_TB` suffix produces error
# streams or timeouts in aiostreams logs simultaneously. Source-side fixes
# (disabling indexers, raising timeouts, more concurrency) won't help — the
# TorBox checkcached step is the universal failure point.
#
# If only 1 _TB addon fails it's likely that addon's specific issue. If 3+
# fail in the same window with the same TorBox flavor, the common factor is
# TorBox itself.
#
# We classify HIGH if ≥3 distinct _TB addons fail in last hour, with at
# least one in hard-timeout state (not just "addon returned error streams"
# which can also happen for content-not-found reasons).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

docker ps --format '{{.Names}}' | grep -q '^aiostreams$' || exit 0

logs=$(docker logs aiostreams --since 1h 2>&1)
[ -z "$logs" ] && exit 0

# Count distinct _TB addons that hit hard timeouts.
tb_addons_timing_out=$(printf '%s' "$logs" \
  | grep -F '"level":"warn"' \
  | grep -E 'timed out after [0-9]+ms' \
  | grep -oE '"addon":"[^"]*TB"' \
  | sort -u)

n_tb_addons=$(printf '%s' "$tb_addons_timing_out" | sed '/^$/d' | wc -l)

# Also count Zod parse-error from torbox-search specifically (the API rate-
# limit response shape mismatch).
tb_search_parse_errs=$(printf '%s' "$logs" \
  | grep -F 'Torbox Search: Failed to parse API response: ' \
  | wc -l)

if [ "$n_tb_addons" -ge 3 ] || [ "$tb_search_parse_errs" -ge 10 ]; then
  list=$(printf '%s' "$tb_addons_timing_out" | tr '\n' ',' | sed 's/,$//')
  echo "HIGH|streaming/aiostreams|$n_tb_addons _TB addons timing out + $tb_search_parse_errs TorBox Search parse-errors in last 1h — likely TorBox API account issue (rate-limit cap=0, sub lapsed, or key revoked) not addon-specific|verify account: curl -s -H 'Authorization: Bearer <KEY>' https://api.torbox.app/v1/api/user/me — if data.plan=0 or success=false, fix at torbox.app. Until then, consider disabling _TB variants of every addon in AIOStreams UI to stop wasting request budget"
elif [ "$n_tb_addons" -ge 1 ] || [ "$tb_search_parse_errs" -ge 1 ]; then
  echo "LOW|streaming/aiostreams|$n_tb_addons _TB addon(s) timing out + $tb_search_parse_errs TorBox Search parse-errors in last 1h — single-addon or intermittent, not yet a cluster signal|monitor; if pattern widens, treat as TorBox account issue"
fi
