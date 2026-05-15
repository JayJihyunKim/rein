#!/usr/bin/env bash
# Plugin helper — degraded mode marker management.
#
# Purpose: provide a session-only governance bypass mechanism. When the
# SessionStart hook (session-start-bootstrap.sh) detects a condition where
# rein cannot meaningfully operate (git binary missing, cwd is not a git
# repo, user opted out via REIN_NO_AUTO_BOOTSTRAP=1, or bootstrap helper
# refused the path), it writes a degraded marker. Other gates (Bash, Edit/
# Write trail, Stop session) consult the marker and pass through silently
# when present, so Claude Code remains usable while rein governance is
# inactive.
#
# Marker file: <project_dir>/.claude/cache/.rein-session-degraded
#   - Content: a single-line reason code (git-missing | non-git-dir
#     | user-opt-out | bootstrap-refused).
#   - Lifetime: session-only. The next SessionStart re-evaluates and either
#     overwrites or clears the marker.
#   - Location: under .claude/cache/, which is gitignored — no commit risk.
#
# Usage (source from a hook):
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/degraded-check.sh"
#   rein_is_degraded "$PROJECT_DIR" && exit 0
#
# Functions:
#   rein_is_degraded [project_dir]
#       Returns 0 if marker exists (degraded mode active), 1 otherwise.
#       Default project_dir is $PWD.
#   rein_write_degraded <project_dir> <reason>
#       Creates the marker with the given reason code.
#       mkdir -p ensures .claude/cache/ exists.
#   rein_clear_degraded [project_dir]
#       Removes the marker if present. Idempotent.

rein_is_degraded() {
  local project_dir="${1:-${PWD:-.}}"
  [ -f "$project_dir/.claude/cache/.rein-session-degraded" ]
}

rein_write_degraded() {
  local project_dir="$1"
  local reason="$2"
  if [ -z "$project_dir" ] || [ -z "$reason" ]; then
    return 1
  fi
  mkdir -p "$project_dir/.claude/cache" 2>/dev/null || return 1
  printf '%s\n' "$reason" > "$project_dir/.claude/cache/.rein-session-degraded"
}

rein_clear_degraded() {
  local project_dir="${1:-${PWD:-.}}"
  rm -f "$project_dir/.claude/cache/.rein-session-degraded" 2>/dev/null
}
