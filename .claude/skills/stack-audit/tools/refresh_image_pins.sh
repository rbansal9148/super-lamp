#!/bin/bash
# refresh_image_pins.sh — move every @sha256 image pin in apps/*/compose.yaml
# FORWARD to the digest its tag currently resolves to in the registry.
#
# Scope (deliberately narrow, so "update to latest" can never break a stack):
#   • ONLY rewrites lines that are already digest-pinned (`...:tag@sha256:OLD`).
#   • Preserves the human-readable tag; only the @sha256 changes.
#   • NEVER bumps a version tag (postgres:18.4 → 19) — that's a data-dir risk
#     and is left for a human. NEVER touches floating tags (they update on
#     `docker compose pull`).
#   • NEVER pulls or restarts a container. It edits files only; deployment is
#     a separate, deliberate step (recreate tier-by-tier, verify health —
#     see obs 902 for the pattern).
#
# Flags:
#   --dry-run       report the OLD→NEW pin changes; write nothing.
#   --app=NAME      limit to apps/NAME/ (repeatable; default: all apps).
#   --parallel=N    registry lookups in flight (default 8).
#
# Idempotent: a pin already equal to the registry digest is left untouched.
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
. "$SKILL_DIR/tools/lib/preflight.sh"
. "$SKILL_DIR/tools/lib/audit_log.sh"

ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0; PAR=8; APPS=()
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY=1 ;;
    --app=*)     APPS+=("${a#--app=}") ;;
    --parallel=*) PAR="${a#--parallel=}" ;;
    -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown arg: $a" ;;
  esac
done

preflight_docker
[ "$DRY" = "1" ] || preflight_root_writable
docker buildx version >/dev/null 2>&1 || die "docker buildx not available (needed for registry digest lookup)"

# Which compose files to scan.
files=()
if [ "${#APPS[@]}" -gt 0 ]; then
  for app in "${APPS[@]}"; do
    for f in "$ROOT/apps/$app/compose.yaml" "$ROOT/apps/$app/compose.yml"; do
      [ -f "$f" ] && files+=("$f")
    done
  done
else
  while IFS= read -r f; do files+=("$f"); done \
    < <(find "$ROOT/apps" -maxdepth 2 \( -name compose.yaml -o -name compose.yml \) -type f | sort)
fi
[ "${#files[@]}" -gt 0 ] || die "no compose files found"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/cache"; mkdir -p "$CACHE"
keyfor() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Build query ref (name:tag, tag defaulted to latest) from a pinned name_tag.
queryref() {
  local nt="$1"; local last="${nt##*/}"
  case "$last" in *:*) printf '%s\n' "$nt" ;; *) printf '%s:latest\n' "$nt" ;; esac
}

# Pass A: collect pinned lines -> file<TAB>line<TAB>name_tag<TAB>old_digest
RECS="$TMP/recs"
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; raw="${rest#*:}"
  raw="${raw#*image:}"; raw="${raw%%#*}"
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]\$//")"
  case "$raw" in *@sha256:*) : ;; *) continue ;; esac
  name_tag="${raw%@sha256:*}"; old="sha256:${raw##*@sha256:}"
  case "$name_tag" in *'${'*) continue ;; esac   # unresolved env-var in name → skip
  printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$name_tag" "$old" >> "$RECS"
done < <(grep -rnE '^[[:space:]]*image:[[:space:]].*@sha256:' "${files[@]}" 2>/dev/null)

[ -s "$RECS" ] || { echo "No @sha256-pinned images found in scope."; AUDIT_DRY_RUN=$DRY AUDIT_CHANGED=0 audit_log_emit 0; exit 0; }

# Pass B: resolve registry digest per unique query ref, in parallel.
cut -f3 "$RECS" | sort -u | while IFS= read -r nt; do queryref "$nt"; done | sort -u \
  | xargs -P "$PAR" -I{} bash -c '
      q="{}"; o="'"$CACHE"'/$(printf "%s" "$q" | tr -c "A-Za-z0-9._-" "_")"
      timeout 25 docker buildx imagetools inspect "$q" --format "{{.Manifest.Digest}}" 2>/dev/null | tr -d "[:space:]" > "$o"
    ' 2>/dev/null

# Pass C: apply (or preview) the forward move.
CHANGED=0; SKIPPED=0; FAILED=0
while IFS=$'\t' read -r file line name_tag old; do
  qref="$(queryref "$name_tag")"
  new="$(cat "$CACHE/$(keyfor "$qref")" 2>/dev/null)"
  rel="${file#"$ROOT"/}"
  case "$new" in sha256:*) : ;; *) echo "  ?? $rel:$line  $name_tag  (registry lookup failed — left as-is)"; FAILED=$((FAILED+1)); continue ;; esac
  if [ "$new" = "$old" ]; then SKIPPED=$((SKIPPED+1)); continue; fi
  echo "  -> $rel:$line  $name_tag"
  echo "       ${old}"
  echo "       ${new}"
  if [ "$DRY" != "1" ]; then
    # Line-addressed replace of the exact old digest on this line only.
    sed -i "${line}s|${old}|${new}|" "$file" || { FAILED=$((FAILED+1)); continue; }
  fi
  CHANGED=$((CHANGED+1))
done < "$RECS"

echo
if [ "$DRY" = "1" ]; then
  echo "DRY-RUN: $CHANGED pin(s) would move forward, $SKIPPED already current, $FAILED unresolved."
  echo "Re-run without --dry-run to write. Then redeploy each touched service deliberately:"
  echo "  docker compose -f apps/<svc>/compose.yaml up -d   # one at a time; verify health"
else
  echo "Refreshed $CHANGED pin(s); $SKIPPED already current, $FAILED unresolved."
  echo "No containers were restarted. Deploy each touched service deliberately:"
  echo "  docker compose -f apps/<svc>/compose.yaml up -d   # one at a time; verify health"
fi
AUDIT_DRY_RUN=$DRY AUDIT_CHANGED=$CHANGED AUDIT_RESTARTED=0 \
  AUDIT_NOTE="refresh_image_pins skipped=$SKIPPED failed=$FAILED" audit_log_emit 0
