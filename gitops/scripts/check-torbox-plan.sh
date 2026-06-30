#!/usr/bin/env bash
# Check the TorBox account plan + live search cooldown, using the API key stored in the
# aiostreams service-credential secret. The key is NEVER printed — only the plan JSON.
#
# Run this LOCALLY (needs a reachable kube context + jq + curl). It reads the key straight
# from Secret `aiostreams-secrets` (namespace apps), queries TorBox /user/me, and prints
# plan tier, subscription, expiry, and cooldown — with the email masked.
#
# Why this exists: aiostreams' `Rate limit exceeded: 0 per 1 minute` errors look like a bad
# or zero-quota key, but are usually a TorBox *search cooldown* (penalty for bursting past
# the search-API rate). plan>=1 + a future `cooldown` timestamp confirms key-is-fine /
# cooldown-active. plan tier: 0=Free 1=Essential 2=Pro 3=Standard.
#
# Secret field format (confirmed 2026-07-01): both FORCED_SERVICE_CREDENTIALS and
# DEFAULT_SERVICE_CREDENTIALS hold `torbox.apiKey=<36-char uuid>`. The extractor below also
# tolerates JSON ({"torbox":...}) and bare-key shapes in case the format changes.
set -uo pipefail
NS="${NS:-apps}"
SECRET="${SECRET:-aiostreams-secrets}"

get_field() { kubectl get secret -n "$NS" "$SECRET" -o jsonpath="{.data.$1}" | base64 -d 2>/dev/null; }

# Extract the TorBox key from a credential field, trying JSON, prefixed, and bare shapes.
extract_tb() {
  local v="$1" k pre
  # JSON: .torbox scalar, or nested apiKey/credential/key/token
  k=$(printf '%s' "$v" | jq -r '
        (.torbox // .TorBox // .tb // .torbox_key // empty) as $t
        | if ($t|type)=="object" then ($t.apiKey // $t.credential // $t.key // $t.token // empty)
          elif ($t|type)=="string" then $t else empty end' 2>/dev/null)
  if [ -n "$k" ] && [ "$k" != "null" ]; then printf '%s' "$k"; return 0; fi
  # Prefixed string: torbox.apiKey=KEY / torbox:KEY / torbox=KEY (key may itself end in '=')
  k=$(printf '%s' "$v" | grep -oiE 'torbox(\.[a-z]+)?[:=].+' | head -1 | sed -E 's/^torbox(\.[a-z]+)?[:=]//I')
  if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  # Bare credential, no list delimiters
  if ! printf '%s' "$v" | grep -q '[,:]'; then
    pre="${v%%=*}"
    if [ "${#pre}" -le 15 ] && printf '%s' "$v" | grep -q '='; then k="${v#*=}"
    else k=$(printf '%s' "$v" | tr -d '[:space:]'); fi
    if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  fi
  return 1
}

TB=""
for K in FORCED_SERVICE_CREDENTIALS DEFAULT_SERVICE_CREDENTIALS; do
  if TB=$(extract_tb "$(get_field "$K")"); then break; fi
done
if [ -z "$TB" ]; then
  echo "!! could not extract a TorBox key from $SECRET (FORCED/DEFAULT_SERVICE_CREDENTIALS)" >&2
  exit 1
fi

curl -fsS https://api.torbox.app/v1/api/user/me -H "Authorization: Bearer $TB" \
  | jq '{success, plan:.data.plan, plan_name:({"0":"Free","1":"Essential","2":"Pro","3":"Standard"}[.data.plan|tostring]),
         subscribed:.data.is_subscribed, expires:.data.premium_expires_at, cooldown:.data.cooldown_until,
         email_masked:(.data.email|if .==null then null else (.[0:2]+"***") end)}'
