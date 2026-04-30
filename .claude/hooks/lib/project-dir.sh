# lib/project-dir.sh
#
# resolve_project_dir SCRIPT_DIR
#   Print the absolute path of the rein project root that owns trail/,
#   .claude/, and .rein/ for the current invocation.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck source=./lib/project-dir.sh
#   . "$SCRIPT_DIR/lib/project-dir.sh"
#   PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
#
# Resolution order (first match wins):
#   1. $REIN_PROJECT_DIR_OVERRIDE — explicit override (used by tests/CI)
#   2. $REIN_PROJECT_DIR          — legacy override (kept for compat)
#   3. Plugin install: $CLAUDE_PLUGIN_ROOT is set
#         a) git rev-parse --show-toplevel from cwd, if a git repo
#         b) $PWD as last resort
#      Reason: in plugin mode SCRIPT_DIR points at ~/.claude/plugins/...,
#      not the user's project. The user's project is the cwd.
#   4. Scaffold install: SCRIPT_DIR/../.. looks like a rein project
#      (i.e. has a trail/ directory). Use it.
#      Reason: a hook physically inside a project owns that project. Falling
#      back to cwd-git would let an unrelated repo capture trail/ writes when
#      the hook is invoked by absolute path from outside (audit-integrity
#      regression observed by codex review 2026-04-29).
#   5. cd "$SCRIPT_DIR/../.." && pwd — positional fallback (no trail/ yet,
#      e.g. fresh install before `rein init` finished).
#   6. git rev-parse --show-toplevel from cwd — last attempt before $PWD.
#   7. $PWD — final fallback.
#
# Always exits 0; the result printed on stdout is the answer. Callers may
# additionally validate that the directory contains the expected layout.

resolve_project_dir() {
  local script_dir="${1:-}"
  local candidate=""
  local script_parent=""

  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$REIN_PROJECT_DIR_OVERRIDE"
    return 0
  fi

  if [ -n "${REIN_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$REIN_PROJECT_DIR"
    return 0
  fi

  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    candidate="$(git rev-parse --show-toplevel 2>/dev/null)" || candidate=""
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    printf '%s\n' "$PWD"
    return 0
  fi

  if [ -n "$script_dir" ]; then
    script_parent="$(cd "$script_dir/../.." 2>/dev/null && pwd)" || script_parent=""
    if [ -n "$script_parent" ] && [ -d "$script_parent/trail" ]; then
      printf '%s\n' "$script_parent"
      return 0
    fi
  fi

  if [ -n "$script_parent" ]; then
    printf '%s\n' "$script_parent"
    return 0
  fi

  candidate="$(git rev-parse --show-toplevel 2>/dev/null)" || candidate=""
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "$PWD"
  return 0
}
