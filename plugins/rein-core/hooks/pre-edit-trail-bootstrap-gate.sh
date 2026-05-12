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
# The helper is sourced (not exec'd) so future hooks (pre-bash-guard,
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
GUIDANCE=$(
  if bootstrap_check; then
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
