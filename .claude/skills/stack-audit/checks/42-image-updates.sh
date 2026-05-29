#!/bin/bash
# Image update check — for every @sha256-PINNED image in apps/*/compose.yaml,
# resolve the digest its tag currently points to in the registry and flag pins
# that have drifted (the tag now resolves to a newer digest).
#
# Scope is deliberately the digest-pinned set ONLY:
#   • It's the actionable set — a drifted pin is fixable in-file (the fixer
#     rewrites it forward on the same tag). Floating/version tags have no pin
#     to rewrite (they update on `docker compose pull`) and are already
#     surfaced by check 21 (floating-tags) — re-checking them here is just
#     redundant noise.
#   • It's bounded (~dozen-ish calls) so it stays under Docker Hub's
#     unauthenticated manifest rate limit. A full 100+-image sweep reliably
#     trips HTTP 429 and drops a different subset each run — a determinism bug.
#     Pinned-only keeps the result reproducible run-to-run.
#
# Network-heavy (one registry round-trip per unique pinned name:tag), so this
# runs in --deep mode only; quick mode exits silently to keep the ~30s budget.
# Lookups are deduped by tag, run PAR-wide, and retried once before a pin is
# reported as un-verifiable (LOW) rather than silently skipped.
#
# Severity:
#   MED  — a pinned image whose tag now resolves to a newer digest (drifted).
#   LOW  — a pinned image whose registry digest could not be resolved (rate
#          limit / network); coverage gap is reported, not hidden.
#
# MED findings carry FIX_TOOL=refresh_image_pins.
#
# Tunables (thresholds.sh): IMAGE_CHECK_PARALLEL (default 8),
#                           IMAGE_CHECK_TIMEOUT_SEC (per-lookup, default 25).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

[ "${MODE:-quick}" = "deep" ] || exit 0
command -v docker >/dev/null 2>&1 || exit 0
docker buildx version >/dev/null 2>&1 || exit 0

ROOT="${DOCKER_ROOT:-/opt/docker}"
PAR="${IMAGE_CHECK_PARALLEL:-8}"
TO="${IMAGE_CHECK_TIMEOUT_SEC:-25}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RECS="$TMP/recs"             # file<TAB>line<TAB>name_tag<TAB>pinned<TAB>queryref
CACHE="$TMP/cache"; mkdir -p "$CACHE"
keyfor() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Build the registry query ref (name:tag, tag defaulted to :latest) from a
# pinned name_tag. Emits a trailing newline (callers pipe this).
queryref() {
  local nt="$1"; local last="${nt##*/}"
  case "$last" in *:*) printf '%s\n' "$nt" ;; *) printf '%s:latest\n' "$nt" ;; esac
}

# Pass A: collect every uncommented, @sha256-pinned image line.
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; raw="${rest#*:}"
  raw="${raw#*image:}"; raw="${raw%%#*}"
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]\$//")"
  case "$raw" in *@sha256:*) : ;; *) continue ;; esac
  name_tag="${raw%@sha256:*}"; pinned="sha256:${raw##*@sha256:}"
  case "$name_tag" in *'${'*) continue ;; esac   # unresolved env-var in name → skip
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "$name_tag" "$pinned" "$(queryref "$name_tag")" >> "$RECS"
done < <(grep -rnE '^[[:space:]]*image:[[:space:]].*@sha256:' "$ROOT"/apps \
            --include='compose.yaml' --include='compose.yml' 2>/dev/null)

[ -s "$RECS" ] || exit 0

# Pass B: resolve registry digest per UNIQUE query ref, in parallel, 1 retry.
cut -f5 "$RECS" | sort -u \
  | xargs -P "$PAR" -I{} bash -c '
      q="{}"; o="'"$CACHE"'/$(printf "%s" "$q" | tr -c "A-Za-z0-9._-" "_")"
      for attempt in 1 2; do
        d=$(timeout '"$TO"' docker buildx imagetools inspect "$q" --format "{{.Manifest.Digest}}" 2>/dev/null | tr -d "[:space:]")
        case "$d" in sha256:*) printf "%s" "$d" > "$o"; exit 0 ;; esac
        sleep 2
      done
    ' 2>/dev/null

# Pass C: compare each pinned record against its registry digest.
while IFS=$'\t' read -r file line name_tag pinned qref; do
  reg="$(cat "$CACHE/$(keyfor "$qref")" 2>/dev/null)"
  rel="${file#"$ROOT"/}"
  case "$reg" in
    sha256:*)
      [ "$pinned" = "$reg" ] && continue
      echo "MED|images|$rel:$line pins $name_tag at ${pinned:0:19}… but its tag now resolves to ${reg:0:19}… — pin has drifted|refresh the @sha256 pin to $reg (preserves the tag)|refresh_image_pins"
      ;;
    *)
      echo "LOW|images|$rel:$line could not verify $name_tag against the registry (rate limit / network) — re-run --deep later|docker buildx imagetools inspect $qref --format '{{.Manifest.Digest}}'|"
      ;;
  esac
done < "$RECS"
