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
#   4. Walk-up fallback (no CLAUDE_PLUGIN_ROOT, e.g. CI): walk up from SCRIPT_DIR until a directory with a
#      trail/ subdirectory is found. The nearest trail/ ancestor is the
#      rein project that owns this invocation. (PD-1, 2026-05-19: the old
#      code assumed a fixed SCRIPT_DIR/../.. depth — correct for hooks at
#      <repo>/.claude/hooks/ but wrong for helper scripts at <repo>/scripts/
#      which are only one level deep, making ../.. point at the repo's
#      PARENT.) Walk-up is caller-depth-agnostic.
#      Reason for preferring this over cwd-git: a hook/script physically
#      inside a project owns that project. Falling back to cwd-git would let
#      an unrelated repo capture trail/ writes when invoked by absolute path
#      from outside (audit-integrity regression, codex review 2026-04-29).
#   5. No trail/ ancestor: git rev-parse --show-toplevel anchored at
#      SCRIPT_DIR (the repo the script physically belongs to — NOT cwd, so
#      an unrelated cwd repo cannot intercept trail/ writes). Covers fresh
#      installs before `rein init` created trail/.
#   6. git rev-parse --show-toplevel from cwd — last attempt before $PWD.
#   7. $PWD — final fallback.
#
# Always exits 0; the result printed on stdout is the answer. Callers may
# additionally validate that the directory contains the expected layout.

resolve_project_dir() {
  local script_dir="${1:-}"
  local candidate=""

  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$REIN_PROJECT_DIR_OVERRIDE"
    return 0
  fi

  if [ -n "${REIN_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$REIN_PROJECT_DIR"
    return 0
  fi

  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    # Sanitize inherited git env vars (BC-INFO1) so cwd discovery cannot be
    # redirected onto a decoy repo. GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR /
    # GIT_INDEX_FILE could latch an unrelated worktree as project_dir.
    # GIT_CEILING_DIRECTORIES is deliberately preserved (it can only narrow
    # discovery, never redirect it to a decoy).
    candidate="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      git rev-parse --show-toplevel 2>/dev/null)" || candidate=""
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    printf '%s\n' "$PWD"
    return 0
  fi

  # Step 4 — walk up from SCRIPT_DIR to the nearest trail/ ancestor. dirname
  # monotonically shrinks toward "/", so the loop always terminates.
  if [ -n "$script_dir" ]; then
    local walk=""
    walk="$(cd "$script_dir" 2>/dev/null && pwd)" || walk=""
    while [ -n "$walk" ] && [ "$walk" != "/" ]; do
      if [ -d "$walk/trail" ]; then
        printf '%s\n' "$walk"
        return 0
      fi
      walk="$(dirname "$walk")"
    done
  fi

  # Step 5 — no trail/ ancestor: anchor git rev-parse at SCRIPT_DIR (not cwd)
  # so the script resolves to the repo it physically belongs to. Sanitize
  # inherited git env vars (BC-INFO1) so a polluted GIT_DIR / GIT_WORK_TREE /
  # GIT_COMMON_DIR / GIT_INDEX_FILE cannot override the SCRIPT_DIR anchoring and
  # redirect discovery onto a decoy. GIT_CEILING_DIRECTORIES is preserved.
  if [ -n "$script_dir" ]; then
    candidate="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
      || candidate=""
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # Step 6 — git rev-parse from cwd. Sanitize inherited git env vars (BC-INFO1)
  # so a polluted GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE
  # cannot redirect this bare cwd discovery onto a decoy repo.
  # GIT_CEILING_DIRECTORIES is preserved.
  candidate="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git rev-parse --show-toplevel 2>/dev/null)" || candidate=""
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "$PWD"
  return 0
}
