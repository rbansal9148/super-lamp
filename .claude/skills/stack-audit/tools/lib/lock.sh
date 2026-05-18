#!/bin/bash
# lock.sh — sourced helper for non-blocking advisory file locking, so two
# parallel runs of the same fixer (or two different fixers mutating the same
# tree) cannot interleave.
#
# Usage:
#   . lib/lock.sh
#   acquire_lock "/tmp/stack-audit-sweep.lock"   # exits 3 if held by other PID
#
# The lock is released automatically when the script exits (the fd in the
# subshell trap is closed).

acquire_lock() {
  local lockfile="${1:-/tmp/stack-audit.lock}"
  exec 200>"$lockfile"
  if ! flock -n 200; then
    echo "[lock] another fixer holds $lockfile (pid=$(cat "$lockfile" 2>/dev/null))" >&2
    exit 3
  fi
  # Record our pid for diagnostics, never used for re-entry.
  echo $$ >&200
}
