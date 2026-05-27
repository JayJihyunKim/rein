#!/usr/bin/env bash
# plugins/rein-core/hooks/lib/auto-mode.sh
#
# Helper for the "auto mode" semantic — when the user is running a long
# autonomous cycle (`/loop`, multi-step self-directed work, the
# "Auto Mode Active" system-reminder branch), incident-related advisory and
# block emissions become noise. This helper lets hooks gate their alerts on
# a single boolean check.
#
# Marker contract:
#   .rein/auto-mode.flag   — presence means "auto mode is ON".
#   File contents are irrelevant; existence is the signal.
#
# Toggle via the rein:auto-mode-on / rein:auto-mode-off skills, or manually:
#   mkdir -p .rein && touch .rein/auto-mode.flag    # on
#   rm -f .rein/auto-mode.flag                       # off
#
# Usage (sourced):
#   . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh"
#   if is_auto_mode; then exit 0; fi   # silent skip
#
# Fail-safe: missing marker / unreadable path / no project dir → return 1
# (= NOT in auto mode). Default is "alerts on" so a corrupt env never
# silences alerts the user wanted.

if [ -n "${__REIN_AUTO_MODE_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_AUTO_MODE_SH_LOADED=1

# Resolve project dir without depending on state-machine.sh — keep this
# helper standalone for use from hooks that don't already source other libs.
_auto_mode_project_dir() {
  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$REIN_PROJECT_DIR_OVERRIDE"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  # BC-INFO1 pattern — strip git env vars before rev-parse so an inherited
  # GIT_DIR / GIT_WORK_TREE cannot redirect onto a decoy repo.
  local pdir
  pdir=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git rev-parse --show-toplevel 2>/dev/null) || pdir=""
  if [ -n "$pdir" ]; then
    printf '%s' "$pdir"
  else
    printf '%s' "$PWD"
  fi
}

# is_auto_mode: return 0 iff the marker file exists.
is_auto_mode() {
  local pdir
  pdir=$(_auto_mode_project_dir)
  [ -n "$pdir" ] || return 1
  [ -f "${pdir}/.rein/auto-mode.flag" ]
}

# auto_mode_log_bypass <reason>: append a single audit line to
# trail/incidents/auto-mode-bypass.log when a hook silences a block.
# Always returns 0 so the calling hook never aborts because of audit
# logging itself.
auto_mode_log_bypass() {
  local reason="${1:-unspecified}"
  local pdir
  pdir=$(_auto_mode_project_dir)
  [ -n "$pdir" ] || return 0
  local log_dir="${pdir}/trail/incidents"
  local log_file="${log_dir}/auto-mode-bypass.log"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$reason" >> "$log_file" 2>/dev/null || true
  return 0
}
