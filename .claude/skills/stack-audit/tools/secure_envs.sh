#!/bin/bash
# secure_envs.sh — Apply the two universal env-file hygiene fixes:
#   1. chmod 600 every .env (defaults 664/644 are world-readable)
#   2. git rm --cached every tracked .env (keeps on disk; ensures .gitignore)
#
# Idempotent. Safe to re-run.
#
# Flags:
#   --no-perms    skip chmod step
#   --no-git      skip git untrack step
#   --dry-run     print actions only

set -uo pipefail
ROOT="${DOCKER_ROOT:-/opt/docker}"
DRY=0; PERMS=1; GIT=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-perms) PERMS=0 ;;
    --no-git) GIT=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

cd "$ROOT"

if [ "$PERMS" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    echo "WOULD: chmod 600 on $(find . -maxdepth 4 -name '.env' -type f 2>/dev/null | wc -l) .env files"
  else
    find . -maxdepth 4 -name '.env' -type f -exec chmod 600 {} + 2>/dev/null || true
    bad=$(find . -maxdepth 4 -name '.env' -type f \( -perm -004 -o -perm -040 \) 2>/dev/null | wc -l)
    echo "[perms] all .env files now chmod 600 ($bad still world-readable)"
  fi
fi

if [ "$GIT" -eq 1 ]; then
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[git] not a git repo; skipping untrack"
    exit 0
  fi
  tracked=$(git ls-files | grep -cE '\.env$' || true)
  if [ "$tracked" -eq 0 ]; then
    echo "[git] 0 tracked .env files; already clean"
  elif [ "$DRY" -eq 1 ]; then
    echo "WOULD: git rm --cached $tracked tracked .env files"
  else
    git ls-files | grep -E '\.env$' | xargs -r git rm --cached -f >/dev/null 2>&1
    after=$(git ls-files | grep -cE '\.env$' || true)
    echo "[git] untracked $((tracked - after)) .env files (working tree preserved)"
    if ! grep -qE '^\.env$' .gitignore 2>/dev/null; then
      echo ".env" >> .gitignore
      echo "[git] appended '.env' to .gitignore"
    fi
    echo "[git] reminder: commit and push to propagate; history STILL contains old secrets"
  fi
fi
