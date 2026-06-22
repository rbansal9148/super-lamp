#!/bin/bash
# Image drift — FLOATING-TAG digest drift (live, network).
#
# DELIBERATELY NOT a check under checks/ and NOT part of the default audit: it makes
# outbound registry calls (non-deterministic, network-dependent, ~1-2s/image) so it is
# opt-in via `audit.sh --updates`. It is the COMPLEMENT to checks/02-image-pins.sh:
#   • 02-image-pins.sh (deterministic) → "is every image pinned by @sha256?" (hygiene)
#   • this (live)                      → "has a floating tag's digest MOVED past the pin?"
#
# Scope = floating tags only (:latest/:nightly/:dev/:edge/:main/:public/… or no tag).
# Semver-pinned tags (postgres:18.4, immich:v2.7.5) are INTENTIONALLY skipped: their tag
# is immutable, so "is there a newer VERSION" is a per-app GitHub/registry-release question
# (high-maintenance, bespoke per project) — not digest drift. Surfaced in a one-off sweep
# instead. Registries handled: Docker Hub + ghcr.io (where all floating tags here live);
# anything else is reported as "registry unsupported — skipped", never a false ✅.
set -u

OWNED_NS="${RESOURCE_OWNED_NAMESPACES:-apps observability}"
# tags treated as mutable/floating (case-insensitive); extend via env if needed
FLOATING_RE="${IMAGE_FLOATING_TAGS:-^(latest|nightly|dev|edge|main|master|develop|rolling|stable|public|beta|canary)$}"

for bin in kubectl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "_Image drift skipped: $bin not found._"; exit 0; }
done

echo "## 🔄 Image drift — floating tags vs pinned digest (live, $(date -u +%FT%TZ))"
echo ""
echo "_Floating-tag images whose upstream digest has moved past the pinned \`@sha256\`. Complements the deterministic \`02-image-pins.sh\` (which only checks THAT images are pinned). Semver-pinned tags are out of scope — see header._"
echo ""

# resolve the digest a tag currently points to (top-level index/manifest digest)
resolve() { # $1=registry $2=repo $3=tag  -> prints sha256:... or empty
  local reg=$1 repo=$2 tag=$3 tok acc
  acc='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'
  if [ "$reg" = "registry-1.docker.io" ]; then
    tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" 2>/dev/null | jq -r '.token // empty')
  elif [ "$reg" = "ghcr.io" ]; then
    tok=$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" 2>/dev/null | jq -r '.token // .access_token // empty')
  else
    echo "__UNSUPPORTED__"; return
  fi
  [ -n "$tok" ] || { echo "__NOAUTH__"; return; }
  curl -fsS -o /dev/null -D - -H "Authorization: Bearer $tok" -H "Accept: $acc" \
    "https://$reg/v2/$repo/manifests/$tag" 2>/dev/null | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# collect unique images from live pods in owned namespaces
imgs=$(for ns in $OWNED_NS; do
  kubectl -n "$ns" get pods -o json 2>/dev/null \
    | jq -r '.items[].spec | (.containers[], (.initContainers // [])[]) | .image'
done | sort -u)

[ -n "$imgs" ] || { echo "- ⚠ no images read (cluster unreachable?) — INCONCLUSIVE"; exit 0; }

drift=0; checked=0; skipped=0
while IFS= read -r img; do
  [ -n "$img" ] || continue
  case "$img" in *"@sha256:"*) : ;; *) continue ;; esac   # only digest-pinned refs
  pinned="${img##*@}"                                       # sha256:...
  ref="${img%@*}"                                           # repo[:tag]
  # split registry host / repo / tag. A registry host is the first path segment IFF it
  # contains a dot (ghcr.io, registry.k8s.io) — otherwise it's a bare Docker Hub ref.
  case "${ref%%/*}" in
    *.*) reg="${ref%%/*}"; rest="${ref#*/}" ;;
    *)   reg="registry-1.docker.io"; rest="$ref" ;;
  esac
  tag="latest"; repo="$rest"
  case "$rest" in *:*) tag="${rest##*:}"; repo="${rest%:*}" ;; esac
  # docker-hub library shorthand (single path segment) -> library/<name>
  if [ "$reg" = "registry-1.docker.io" ]; then case "$repo" in */*) : ;; *) repo="library/$repo" ;; esac; fi
  # floating tags only
  echo "$tag" | grep -qiE "$FLOATING_RE" || continue
  checked=$((checked+1))
  cur=$(resolve "$reg" "$repo" "$tag")
  case "$cur" in
    __UNSUPPORTED__) echo "- ⚪ **$repo:$tag** — registry \`$reg\` unsupported, skipped"; skipped=$((skipped+1)) ;;
    __NOAUTH__|"")   echo "- ⚠ **$repo:$tag** — could not resolve current digest (auth/network)"; skipped=$((skipped+1)) ;;
    "$pinned")       : ;;                                        # current — stay quiet
    *)               echo "- ⬆ **$repo:\`$tag\`** drifted — pinned \`${pinned:0:19}…\` → now \`${cur:0:19}…\`"; drift=$((drift+1)) ;;
  esac
done <<EOF
$imgs
EOF

echo ""
[ "$drift" = 0 ] && echo "_✅ no floating-tag drift across $checked floating images ($skipped unresolved)._" \
                 || echo "_$drift floating image(s) drifted; $checked checked, $skipped unresolved. To adopt: repin the manifest \`@sha256\` and let ArgoCD roll it._"
