#!/usr/bin/env bash
# Plugin helper — git-required onboarding guidance (single source of truth).
#
# Purpose: SessionStart (session-start-bootstrap.sh, branches "git binary
# missing" and "cwd is not a git repo") and the UserPromptSubmit advisory
# (via lib/bootstrap-check.sh, when it sees a matching degraded marker) both
# need to tell the user/assistant the SAME thing when a project can't be
# bootstrapped because git is either missing or the folder isn't a git
# repository yet. This lib is the ONLY place that generates that guidance
# text so the two channels cannot diverge.
#
# Usage (source from a hook):
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/git-required-guidance.sh"
#   rein_git_required_guidance <reason> <project_dir> <bootstrap_script_abs_path>
#   rein_git_required_reminder <reason> <project_dir> <bootstrap_script_abs_path>
#
#   <reason>                     "non-git-dir" | "git-missing" (anything else
#                                 → the function prints nothing and returns 1)
#   <project_dir>                absolute project path, rendered into the
#                                 --project-dir value of the Run: line.
#   <bootstrap_script_abs_path>  absolute path to rein-bootstrap-project.py.
#                                 MUST already be a literal absolute path —
#                                 never the string "${CLAUDE_PLUGIN_ROOT}"
#                                 itself. An unexpanded placeholder here would
#                                 reproduce the BG-E deadlock (see
#                                 bootstrap-check.sh): the printed Run: line
#                                 would expand to an empty prefix in the
#                                 user's shell and become uncopy-pasteable.
#
# Quoting: both arguments are rendered through the shared helper hooks/lib/
# shell-quote.sh's rein_shell_quote (single-quoted, or `printf %q` when the
# value itself contains a single quote) before being interpolated into the
# printed command — a project_dir containing shell metacharacters (`"`, `;`,
# `$(...)`, backticks, spaces) renders as ONE safe argument instead of
# executing extra shell code when copy-pasted. This is the only quoting rule
# used by any rendered rein-bootstrap-project.py command anywhere in the
# plugin (lib/bootstrap-check.sh's own fresh/partial templates and the
# PreToolUse(Bash) bootstrap gate's exact-match allow-list use the same
# helper). Falls back to `printf %q` directly if shell-quote.sh cannot be
# sourced (install regression) — never hard-fails on a missing dependency.
#
# rein_git_required_guidance prints: (a) one line explaining why git is
# required (rein's review/commit checks and their record-keeping are tied to
# git state — without a repository only the edit check runs), and (b) an
# explicit instruction block telling the assistant to ask the user for
# approval BEFORE running anything, the exact commands to run in order after
# approval, and what to say if the user declines. git-missing additionally
# lists the per-OS install commands (this lib is their only copy).
#
# rein_git_required_reminder prints a single short line (still names the
# reason and the recovery command) with NO approval instruction — used once
# the full guidance has already been shown this session (see the
# rein_git_guidance_* flag functions below) so the assistant does not ask
# the same approval question on every turn.
#
# Session "already shown" flag (once-per-session, mirrors hooks/lib/
# select-active-dod.sh's active-dod-choice.session-<key>.flag convention):
#   rein_git_guidance_flag_path <project_dir>
#       Prints <project_dir>/.claude/cache/.rein-git-guidance-shown.session-<key>
#       where <key> is ${REIN_SESSION_ID:-${PPID:-$$}}.
#   rein_git_guidance_already_shown <project_dir>
#       Returns 0 if the flag exists (full guidance already shown this
#       session), 1 otherwise.
#   rein_git_guidance_mark_shown <project_dir>
#       Creates the flag (mkdir -p the cache dir first). Best-effort —
#       failure is silent, never blocks the caller.
#
# Dependency: sources hooks/lib/shell-quote.sh (same directory) for the
# quoting helper; falls back to `printf %q` directly if that file is
# missing. No other sourcing, no command substitution or eval on the
# arguments — project_dir / bootstrap_script only ever pass through the
# quoting helper (a pure string transform) before interpolation into a
# heredoc via plain parameter expansion. Safe under `set -u`: every
# positional argument is read with a `${n:-}` default.
#
# Output budget: each reason's guidance targets ~1200 bytes (measured with a
# realistic project path + plugin-cache script path) so it stays a small
# fraction of the SessionStart per-hook additionalContext cap (~10,000 chars
# total, shared across every SessionStart hook).
#
# No internal identifiers (verdict / digest / evidence-record fields, marker
# file paths, hook names) leak into the printed text — this is user- and
# assistant-facing guidance, not an internal diagnostic.

# Source the shared quoting helper once, best-effort. Fail-soft: a missing
# shell-quote.sh (install regression) falls back to `printf %q` inline in
# _rein_ggr_quote below — this lib must never hard-fail on it.
_rein_ggr_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "$_rein_ggr_lib_dir" ] && [ -f "$_rein_ggr_lib_dir/shell-quote.sh" ]; then
  # shellcheck disable=SC1091
  source "$_rein_ggr_lib_dir/shell-quote.sh"
fi
unset _rein_ggr_lib_dir

_rein_ggr_quote() {
  if command -v rein_shell_quote >/dev/null 2>&1; then
    rein_shell_quote "$1"
  else
    printf '%q' "$1"
  fi
}

rein_git_required_guidance() {
  local reason="${1:-}"
  local project_dir="${2:-}"
  local bootstrap_script="${3:-}"
  local project_dir_q="" bootstrap_script_q=""
  project_dir_q="$(_rein_ggr_quote "$project_dir")"
  bootstrap_script_q="$(_rein_ggr_quote "$bootstrap_script")"

  case "$reason" in
    non-git-dir)
      cat <<EOF
rein: 이 폴더는 git 저장소가 아니라서 초기화가 멈췄습니다. (rein 의 리뷰·커밋 검사 결과는 git 상태에 묶여 있어, 저장소가 아니면 편집 검사만 동작해요)
rein: paused — not a git repository (rein's review/commit checks and their records are tied to git state; without a repository only the edit check runs).

(Claude: ask the user FIRST whether it's okay to run \`git init\` in this folder now — do not run anything below without that approval.
If yes, run in order: (1) git init  (2) python3 ${bootstrap_script_q} --project-dir ${project_dir_q} — then tell the user onboarding is complete.
If they decline, say rein stays off for this folder for this session, and that running \`git init\` then the command above later turns it on.)
EOF
      ;;
    git-missing)
      cat <<EOF
rein: git 이 설치되어 있지 않아 초기화가 멈췄습니다. (rein 의 리뷰·커밋 검사 결과는 git 상태에 묶여 있어, git 이 없으면 편집 검사만 동작해요)
rein: paused — git is not installed (rein's review/commit checks and their records are tied to git state; without git only the edit check runs).

설치 명령 (하나 선택) / install (pick one):
  macOS:         xcode-select --install   (또는: brew install git)
  Debian/Ubuntu: sudo apt install git
  Fedora:        sudo dnf install git
  Arch:          sudo pacman -S git
  Windows:       Git for Windows 설치 또는 \`winget install Git.Git\`

(Claude: ask the user FIRST whether it's okay to run the install command above now — do not run anything below without that approval.
If yes, run in order: (1) the install command  (2) git init  (3) python3 ${bootstrap_script_q} --project-dir ${project_dir_q} — then tell the user onboarding is complete.
If they decline, say rein stays off for this folder for this session, and that installing git then the two commands above later turns it on.)
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

rein_git_required_reminder() {
  local reason="${1:-}"
  local project_dir="${2:-}"
  local bootstrap_script="${3:-}"
  local project_dir_q="" bootstrap_script_q=""
  project_dir_q="$(_rein_ggr_quote "$project_dir")"
  bootstrap_script_q="$(_rein_ggr_quote "$bootstrap_script")"

  case "$reason" in
    non-git-dir)
      cat <<EOF
rein: 이 폴더는 git 저장소가 아니라 이 세션에서는 꺼져 있어요 — 켜려면: git init 후 python3 ${bootstrap_script_q} --project-dir ${project_dir_q} (사용자가 이미 결정했으면 다시 묻지 마세요).
rein: still off for this session (not a git repository) — to turn it on: git init, then python3 ${bootstrap_script_q} --project-dir ${project_dir_q} (don't ask again if the user already decided).
EOF
      ;;
    git-missing)
      cat <<EOF
rein: git 이 없어 이 세션에서는 꺼져 있어요 — 켜려면: git 설치 후 git init, python3 ${bootstrap_script_q} --project-dir ${project_dir_q} (사용자가 이미 결정했으면 다시 묻지 마세요).
rein: still off for this session (git not installed) — to turn it on: install git, then git init, then python3 ${bootstrap_script_q} --project-dir ${project_dir_q} (don't ask again if the user already decided).
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

_rein_git_guidance_session_key() {
  printf '%s' "${REIN_SESSION_ID:-${PPID:-$$}}"
}

rein_git_guidance_flag_path() {
  local project_dir="${1:-}"
  printf '%s/.claude/cache/.rein-git-guidance-shown.session-%s' \
    "$project_dir" "$(_rein_git_guidance_session_key)"
}

rein_git_guidance_already_shown() {
  local project_dir="${1:-}"
  [ -f "$(rein_git_guidance_flag_path "$project_dir")" ]
}

rein_git_guidance_mark_shown() {
  local project_dir="${1:-}"
  [ -n "$project_dir" ] || return 1
  mkdir -p "$project_dir/.claude/cache" 2>/dev/null || return 1
  # stderr redirect FIRST: bash sets up redirections left to right, so
  # `> file 2>/dev/null` still reports a failing `> file` open (e.g. a
  # read-only .claude/cache) to the ORIGINAL stderr — the `2>/dev/null`
  # after it is set up too late to catch that diagnostic. Reordering makes
  # fd 2 point at /dev/null before the `>` open is attempted, so the
  # failure is silent, matching this function's best-effort contract.
  # `printf ''`, NOT `:` — `:` is a POSIX *special* builtin, and a
  # redirection error on a special builtin makes a non-interactive POSIX-mode
  # shell (bash 5 under POSIXLY_CORRECT=1) exit outright, killing the whole
  # SessionStart helper mid-run (2026-09-04 Linux CI, fixture S). A regular
  # builtin just fails the command, which `|| true` then absorbs.
  printf '' 2>/dev/null > "$(rein_git_guidance_flag_path "$project_dir")" || true
}
