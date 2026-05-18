#!/bin/bash
# audit_log.sh — append one JSONL line per fixer invocation to a persistent
# audit trail. Each line: {ts, tool, args, dry_run, exit, changed, restarted}
#
# Callers populate fields via env vars:
#   AUDIT_TOOL       (defaults to $0 basename)
#   AUDIT_DRY_RUN    "1"/"0"
#   AUDIT_CHANGED    integer
#   AUDIT_RESTARTED  integer
#   AUDIT_NOTE       free-text (escape-safe)
# and call: audit_log_emit <exit_code>

AUDIT_LOG_PATH="${AUDIT_LOG_PATH:-/opt/docker/.claude/skills/stack-audit/audit.log}"

audit_log_emit() {
  local rc="${1:-0}"
  local tool="${AUDIT_TOOL:-$(basename "$0")}"
  local args="${AUDIT_ARGS:-}"
  local dry="${AUDIT_DRY_RUN:-0}"
  local changed="${AUDIT_CHANGED:-0}"
  local restarted="${AUDIT_RESTARTED:-0}"
  local note="${AUDIT_NOTE:-}"
  local ts
  ts=$(date -u +%FT%TZ)
  # Escape pipes and quotes from args/note minimally.
  args="${args//\"/\\\"}"
  note="${note//\"/\\\"}"
  mkdir -p "$(dirname "$AUDIT_LOG_PATH")" 2>/dev/null
  printf '{"ts":"%s","tool":"%s","args":"%s","dry_run":%s,"exit":%d,"changed":%d,"restarted":%d,"note":"%s"}\n' \
    "$ts" "$tool" "$args" "$dry" "$rc" "$changed" "$restarted" "$note" \
    >> "$AUDIT_LOG_PATH" 2>/dev/null || true
}
