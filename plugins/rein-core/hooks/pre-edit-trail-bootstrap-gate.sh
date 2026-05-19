#!/usr/bin/env bash
# Plugin PreToolUse(Edit|Write|MultiEdit) bootstrap gate.
#
# Sources the bootstrap-check.sh helper (Task 1.1) and translates the helper's
# exit code into a Claude Code PreToolUse hook action:
#
#   helper exit 10 (trail/ absent, safe project_dir)
#     → echo helper stdout (bilingual guidance) to stderr + exit 2 (BLOCK)
#
#   helper exit 0 (trail/ present)
#     → silent exit 0 (PASS)
#
#   helper exit 11 (unsafe project_dir — resolution/plugin-dir/cache-path/
#                   sensitive-path/unwritable)
#     → silent exit 0 (PASS, best-effort: the gate's job is not to block
#                      sensitive paths, only to surface missing bootstrap)
#
# The helper is sourced (not exec'd) so future hooks (pre-bash-safety-guard,
# user-prompt-submit-rules, session-start-bootstrap) can share the same
# function via the same source pattern — satisfies Scope ID:
#   session-start-bootstrap-and-pre-edit-gate-and-pre-bash-gate-and-user-prompt-submit-share-bootstrap-check-helper-via-source
#
# Scope IDs covered:
#   - pre-edit-trail-bootstrap-gate-blocks-edit-write-multiedit-with-exit-2-and-bootstrap-command-stderr-when-trail-dir-absent
#   - pre-edit-trail-bootstrap-gate-passes-through-with-exit-0-when-bootstrap-check-helper-returns-exit-code-0-or-11
#   - session-start-bootstrap-and-pre-edit-gate-and-pre-bash-gate-and-user-prompt-submit-share-bootstrap-check-helper-via-source
#
# Exit codes (to Claude Code):
#   0  — pass through (bootstrap complete, or unsafe → best-effort skip)
#   2  — BLOCK + surface stderr (bootstrap missing, surfaced for user)

set -uo pipefail

# ---------------------------------------------------------------------------
# Graceful degrade — plugin runtime / helper absent
# ---------------------------------------------------------------------------
# CLAUDE_PLUGIN_ROOT is set by Claude Code when a plugin hook runs. Outside
# the plugin runtime (e.g. ad-hoc shell invocation), pass through silently —
# it is not this gate's job to assert plugin installation.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

# --- Policy toggle (plugin mode only) ---
# .rein/policy/hooks.yaml can disable this hook via
# `pre-edit-trail-bootstrap-gate: false` or
# `{ pre-edit-trail-bootstrap-gate: { enabled: false } }`.
# Individual hook setting overrides the `bootstrap-gate` umbrella key.
if [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  if ! python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-edit-trail-bootstrap-gate"; then
    exit 0  # disabled by user policy
  fi
fi

HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
if [ ! -f "$HELPER" ]; then
  # Install regression — not this gate's job to alarm. Pass through.
  exit 0
fi

# ---------------------------------------------------------------------------
# BG-C: capture stdin once, then route on (a) degraded marker and
# (b) target file path scope before invoking the bootstrap helper.
# ---------------------------------------------------------------------------
# The helper itself reads stdin to discover the project dir hint
# (`stdin.cwd`), so we must buffer the payload here and replay it via
# process substitution to the helper invocation below. Without this, the
# helper would see an empty stdin once we have already consumed it for
# file_path extraction.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat || true)
fi

# Resolve project_dir hint for the degraded-marker probe.
#
# HIGH-2 fix: SessionStart writes the marker at <git_root>/.claude/cache/,
# but in monorepo workflows the user's cwd is often a subdir like
# `apps/web/`. Using raw cwd here would miss the marker and force the gate
# into block mode for the rest of the session. Mirror bootstrap-check.sh's
# resolution: stdin.cwd (envelope) → git-root walkup (when inside a git
# repo) → stdin.cwd verbatim (non-git) → PWD git walkup → PWD. The probe
# itself remains a single -f file check, so cost is unchanged.
EXTRACT_JSON="${CLAUDE_PLUGIN_ROOT}/hooks/lib/extract-hook-json.py"
_pe_resolve_marker_root() {
  # Print one line: the directory in which `.claude/cache/.rein-session-degraded`
  # should be looked up. Mirrors bootstrap-check.sh's source-order so the
  # marker reader stays aligned with the marker writer in
  # session-start-bootstrap.sh.
  local stdin_cwd=""
  if [ -n "$INPUT" ] && [ -f "$EXTRACT_JSON" ] && command -v python3 >/dev/null 2>&1; then
    stdin_cwd=$(printf '%s' "$INPUT" | python3 "$EXTRACT_JSON" --field cwd --default '' 2>/dev/null || true)
  fi
  local candidate=""
  if [ -n "$stdin_cwd" ] && [ -d "$stdin_cwd" ]; then
    # stdin.cwd present → try git-root walkup. Sanitize inherited git env
    # so discovery is anchored strictly to stdin.cwd, matching
    # bootstrap-check.sh's stdin.cwd resolution branch.
    candidate=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
      git -C "$stdin_cwd" rev-parse --show-toplevel 2>/dev/null) || candidate=""
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    # non-git stdin.cwd → use verbatim (matches helper's source=stdin branch)
    printf '%s\n' "$stdin_cwd"
    return 0
  fi
  # No stdin.cwd → fall back to git-root walkup from PWD, then PWD raw.
  candidate=$(git rev-parse --show-toplevel 2>/dev/null) || candidate=""
  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  printf '%s\n' "${PWD:-.}"
}
PROJECT_DIR_HINT="$(_pe_resolve_marker_root)"

# (1) Degraded pass-through — SessionStart marked rein inactive for this
# session (git missing, non-git cwd, user opt-out, bootstrap refused).
# Pass through silently so Claude Code remains usable.
DEGRADED_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/degraded-check.sh"
if [ -f "$DEGRADED_HELPER" ]; then
  # shellcheck disable=SC1090
  source "$DEGRADED_HELPER"
  if rein_is_degraded "$PROJECT_DIR_HINT"; then
    exit 0
  fi
fi

# (2) Path scope — this gate exists to protect trail/ from edits before
# bootstrap. Any other target (scripts/, src/, docs/, root configs) is
# out of scope and must not be blocked by missing bootstrap. Yesterday's
# deadlock root cause: this hook was blocking ALL Edit/Write/MultiEdit
# regardless of target, locking out recovery edits to scripts/ etc.
FILE_PATH=""
if [ -n "$INPUT" ] && [ -f "$EXTRACT_JSON" ] && command -v python3 >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | python3 "$EXTRACT_JSON" --field tool_input.file_path --default '' 2>/dev/null || true)
fi

case "$FILE_PATH" in
  */trail/*|trail/*) ;;  # in scope — fall through to bootstrap_check
  *) exit 0 ;;           # any other path (including empty) → pass through
esac

# Source the helper so bootstrap_check() is defined in this shell.
# shellcheck disable=SC1090
source "$HELPER"

# ---------------------------------------------------------------------------
# Invoke helper, preserving stdout (including trailing newline)
# ---------------------------------------------------------------------------
# Trailing-newline preservation idiom: command substitution `$(...)` strips
# trailing newlines. Append a sentinel byte ("x") inside the subshell, then
# strip it after capture — that preserves the helper's exact stdout including
# the final LF of the bilingual guidance.
#
# We also need the helper's exit code. We capture the substitution as a
# plain assignment (not as the condition of an `if`) so `$?` directly
# reflects the subshell's exit status. Putting `cmd=$(...)` inside `if`
# causes `$?` after the `fi` to be 0 (the if-statement's own status), not
# the failed command's exit code — a subtle bash gotcha.
#
# Replay the buffered stdin via a here-string so the helper's
# _bc_read_stdin_cwd() sees the original envelope JSON.
GUIDANCE=$(
  if bootstrap_check <<<"$INPUT"; then
    printf x
  else
    rc=$?
    printf x
    exit "$rc"
  fi
)
RC=$?
GUIDANCE="${GUIDANCE%x}"

if [ "$RC" = "0" ]; then
  # trail/ exists — silent pass.
  exit 0
fi

if [ "$RC" = "10" ]; then
  # trail/ missing, project_dir safe → block + surface guidance.
  printf '%s' "$GUIDANCE" >&2
  exit 2
fi

# RC = 11 (unsafe) or any other non-zero → best-effort pass-through.
exit 0
