#!/usr/bin/env bash
# Plugin helper — bootstrap predicate.
#
# Purpose: detect whether the resolved project_dir has been bootstrapped
# (i.e. has a `trail/` directory, a `.rein/project.json` marker, AND a
# `trail/index.md`). When not, emit a bilingual guidance message with
# either the fresh-install template OR a partial-state template that names
# which components are present vs missing.
#
# BG-1 (2026-05-14): require both trail/ and .rein/project.json — eliminates
# false positive when overlay residue trail/ exists without bootstrap
# completion (e.g. maintainer dogfood install where dev-overlay residue
# leaves a stray trail/ without the plugin-mode .rein/project.json marker).
# Pre-BG-1 behaviour was trail/-only, which mistakenly signalled
# "bootstrapped" for any project that happened to have a trail/ from
# unrelated processes.
#
# Partial-bootstrap fix (v1.3.0+1, codex round 1 missed defect #3): also
# require trail/index.md. Combined with the bootstrap script's atomic
# "marker-last" write order (rein-bootstrap-project.py writes
# `.rein/project.json` LAST via temp+os.replace), this eliminates the
# class of failures where the marker existed but trail/ was incomplete
# (e.g. SIGINT mid-bootstrap leaving stale `.session-has-src-edit`-style
# markers behind that downstream session-start hooks could not recover
# from). Three components are checked because a future bootstrap step
# could add a fourth marker and the partial-state branch must continue to
# render diagnostically.
#
# Usage (direct invocation):
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh" [<project_dir_override>]
#
# Usage (via stdin — hook envelope):
#   echo "$JSON" | bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
#
# Usage (resolution only, no trail/marker probe — for callers that need the
# same confirmed project_dir bootstrap_check would use before running their
# own git/degraded-marker checks): source this file, then call
# `_bc_resolve_project_dir [override]` directly. See its own header comment
# for the output format.
#
# Project dir resolution priority:
#   $1 (explicit override) > stdin.cwd-then-git-walkup > git from $PWD > $PWD
#   - stdin.cwd is treated as a *hint*. We run `git -C <stdin.cwd> rev-parse
#     --show-toplevel` to walk up to the git root. This keeps the runtime
#     gate aligned with rein-bootstrap-project.py's "git root only" contract
#     in monorepos where the shell CWD persists on a subdir (e.g. apps/web).
#   - When stdin.cwd has no enclosing git repo, it is used verbatim (non-git
#     project). When stdin.cwd is missing/invalid, fall back to git-from-$PWD
#     then $PWD.
#   (CLAUDE_PROJECT_DIR is NOT used — Claude Code spec does not guarantee it.)
#
# Source labels (logged on stderr): override | git-from-stdin | stdin | git | pwd
#
# Exit codes:
#   0  — trail/ AND .rein/project.json both exist; stdout empty
#   10 — trail/ or .rein/project.json missing + project_dir safe; stdout = guidance text
#   11 — unsafe project_dir; stderr = one-line category keyword
#
# Unsafe categories (precedence order, first match wins):
#   (1) resolution        — stdin / git / PWD all failed
#   (2) plugin-dir        — resolved == CLAUDE_PLUGIN_ROOT (realpath equal)
#   (3) cache-path        — resolved starts with ~/.claude/plugins/cache/
#   (4) sensitive-path    — resolved == "/" OR == "$HOME"
#   (5) unwritable        — mktemp <project_dir>/.rein-bootstrap-write-test.XXXXXXXX fails
#
# Side effects: none (read-only).
#   - No file create/modify/delete (the unwritable probe uses mktemp with
#     an unpredictable 8-char suffix and removes it immediately on success;
#     a cleanup failure is surfaced to stderr rather than swallowed).
#   - Only read-only git invocations are used (rev-parse).
#   - stderr: one-line size/category diagnostic for the caller's log.

set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_bc_realpath() {
  # Best-effort realpath. Falls back to printing the input when realpath is
  # unavailable (e.g. minimal busybox). Errors are swallowed — the caller is
  # responsible for "no answer" semantics.
  #
  # Byte-exact contract: every branch prints the path followed by exactly one
  # trailing LF (realpath(1) and python's print() already do; the fallbacks
  # are made to match with an explicit `\n`). This lets every caller use the
  # sentinel-capture idiom (`out="$(_bc_realpath "$x"; printf x)"; out="${out%x}"`)
  # and then strip EXACTLY one trailing LF — never the caller's plain `$(...)`,
  # which strips ALL trailing newlines and would truncate a path whose last
  # byte is itself a literal LF.
  local path="${1:-}"
  if [ -z "$path" ]; then
    return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null || printf '%s\n' "$path"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

_bc_read_stdin_cwd() {
  # Parse the optional stdin hook-envelope JSON for `.cwd`. Output the raw
  # value on stdout; empty on absence or non-tty stdin.
  #
  # IMPORTANT: do NOT use `python3 - <<HEREDOC` — heredoc replaces python3's
  # stdin, so the JSON payload from the *caller's* stdin would never reach
  # the script. Use `python3 -c <script>` so python3 inherits the caller's
  # stdin as-is.
  if [ -t 0 ]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 -c '
import json, sys
try:
    raw = sys.stdin.buffer.read()
except Exception:
    sys.exit(0)
if not raw:
    sys.exit(0)
try:
    text = raw.decode("utf-8")
except Exception:
    sys.exit(0)
try:
    data = json.loads(text)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
cwd = data.get("cwd") or data.get("project_dir") or ""
if isinstance(cwd, str) and cwd:
    sys.stdout.write(cwd)
' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Project dir resolution
# ---------------------------------------------------------------------------

# _bc_resolve_project_dir [override]
#
# Pure resolution step (no trail/marker probing, no side effects). Callers
# that need the SAME confirmed project_dir bootstrap_check would use — but
# without paying for the full bootstrap-state check — call this directly.
#
# Priority: override arg > stdin.cwd-then-git-walkup > git from $PWD > $PWD.
#   - stdin.cwd is read via _bc_read_stdin_cwd. When present, it is walked
#     up via `git -C <stdin.cwd> rev-parse --show-toplevel` (GIT_DIR /
#     GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE stripped for the
#     walk-up so an inherited pointer can't redirect discovery elsewhere;
#     GIT_CEILING_DIRECTORIES is preserved — policy-sensitive, caller may
#     have set it intentionally). A git root found this way wins
#     (source=git-from-stdin); a non-git stdin.cwd is used verbatim
#     (source=stdin).
#   - Without stdin.cwd, the same env-stripped walk-up runs from $PWD
#     (source=git), falling back to $PWD itself (source=pwd).
#
# Output: on success, prints "<source><TAB><resolved_real>" to stdout (no
# trailing newline) and returns 0. source comes first because it is always
# one of a fixed enum (override|git-from-stdin|stdin|git|pwd) that never
# contains a tab, while resolved_real is an arbitrary filesystem path that
# legally CAN contain a literal tab byte — putting the tab-safe field first
# lets every consumer split on the FIRST tab and take the remainder as the
# path (`source="${resolution%%$'\t'*}"; resolved_real="${resolution#*$'\t'}"`)
# without truncating a tab-containing path. On failure — every resolution
# path exhausted, or the resolved path is not an existing directory — prints
# the one-line stderr diagnostic ("resolution" category) and returns 11.
_bc_resolve_project_dir() {
  local override="${1:-}"
  local resolved="" source=""

  if [ -n "$override" ]; then
    resolved="$override"
    source="override"
  else
    local stdin_cwd=""
    # Sentinel capture (see _bc_realpath's header comment for the rationale):
    # a plain `$(_bc_read_stdin_cwd)` strips ALL trailing newlines from the
    # captured output, which would truncate a cwd whose last byte is itself
    # a literal LF. _bc_read_stdin_cwd writes the cwd bytes with no added
    # newline of its own (sys.stdout.write, not print), so no LF-stripping
    # is needed here — only the sentinel to stop `$(...)` from eating a
    # caller-supplied trailing LF.
    stdin_cwd="$(_bc_read_stdin_cwd; printf x)"
    stdin_cwd="${stdin_cwd%x}"
    if [ -n "$stdin_cwd" ] && [ -d "$stdin_cwd" ]; then
      local git_root="" git_rc=0
      # Sentinel capture in if/else form (mirrors bootstrap_check's own
      # resolution capture below) — the git invocation's own exit code
      # matters here: a plain `cmd; printf x` always makes the substitution
      # succeed, so a failing git that still printed a path to stdout before
      # failing would be wrongly accepted as the walk-up root. On success,
      # strip exactly ONE trailing LF (git's own line terminator on
      # `rev-parse --show-toplevel` output) — NOT a plain `$(...)`
      # trailing-newline strip, which would also eat a literal LF that is
      # the last byte of the repo root's own path.
      git_root=$(
        if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
          git -C "$stdin_cwd" rev-parse --show-toplevel 2>/dev/null; then
          printf x
        else
          rc=$?
          printf x
          exit "$rc"
        fi
      )
      git_rc=$?
      git_root="${git_root%x}"
      if [ "$git_rc" -eq 0 ]; then
        git_root="${git_root%$'\n'}"
      else
        git_root=""
      fi
      if [ -n "$git_root" ]; then
        resolved="$git_root"
        source="git-from-stdin"
      else
        resolved="$stdin_cwd"
        source="stdin"
      fi
    elif [ -n "$stdin_cwd" ]; then
      # stdin.cwd names a non-existent directory — the directory-existence
      # check below reports this as a resolution failure.
      resolved="$stdin_cwd"
      source="stdin"
    else
      local git_root="" git_rc=0
      # Same if/else sentinel + exit-status-aware treatment as the
      # stdin-cwd walk-up above.
      git_root=$(
        if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
          git rev-parse --show-toplevel 2>/dev/null; then
          printf x
        else
          rc=$?
          printf x
          exit "$rc"
        fi
      )
      git_rc=$?
      git_root="${git_root%x}"
      if [ "$git_rc" -eq 0 ]; then
        git_root="${git_root%$'\n'}"
      else
        git_root=""
      fi
      if [ -n "$git_root" ]; then
        resolved="$git_root"
        source="git"
      elif [ -n "${PWD:-}" ] && [ -d "$PWD" ]; then
        resolved="$PWD"
        source="pwd"
      else
        echo "bootstrap-check: unsafe category=resolution project_dir=" >&2
        echo "resolution" >&2
        return 11
      fi
    fi
  fi

  local resolved_real=""
  resolved_real="$(_bc_realpath "$resolved"; printf x)"
  resolved_real="${resolved_real%x}"
  resolved_real="${resolved_real%$'\n'}"
  if [ -z "$resolved_real" ]; then
    resolved_real="$resolved"
  fi

  # Resolved path must exist as a directory — trail/ presence can't be
  # probed safely on a non-existent path (e.g. $PWD=/nonexistent).
  if [ ! -d "$resolved_real" ]; then
    echo "bootstrap-check: unsafe category=resolution project_dir=$resolved_real" >&2
    echo "resolution" >&2
    return 11
  fi

  printf '%s\t%s' "$source" "$resolved_real"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

bootstrap_check() {
  local override="${1:-}"
  local resolution=""
  local resolve_rc=0
  # Sentinel capture (if/else form — the exit code matters here, unlike the
  # gate's step 1 / session-start-bootstrap.sh, which only test emptiness):
  # a plain `$(_bc_resolve_project_dir ...) || return 11` strips ALL
  # trailing newlines from "<source><TAB><resolved_real>", which would
  # truncate a resolved_real whose last byte is itself a literal LF.
  resolution=$(
    if _bc_resolve_project_dir "$override"; then
      printf x
    else
      rc=$?
      printf x
      exit "$rc"
    fi
  )
  resolve_rc=$?
  resolution="${resolution%x}"
  if [ "$resolve_rc" -ne 0 ]; then
    return 11
  fi
  local source="${resolution%%$'\t'*}"
  local resolved_real="${resolution#*$'\t'}"

  # ---- Step 2: plugin install dir match (CLAUDE_PLUGIN_ROOT) ------------
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    local plugin_root_real=""
    plugin_root_real="$(_bc_realpath "$CLAUDE_PLUGIN_ROOT"; printf x)"
    plugin_root_real="${plugin_root_real%x}"
    plugin_root_real="${plugin_root_real%$'\n'}"
    if [ -z "$plugin_root_real" ]; then
      plugin_root_real="$CLAUDE_PLUGIN_ROOT"
    fi
    if [ "$resolved_real" = "$plugin_root_real" ]; then
      echo "bootstrap-check: unsafe category=plugin-dir project_dir=$resolved_real" >&2
      echo "plugin-dir" >&2
      return 11
    fi
  fi

  # ---- Step 3: plugin cache prefix match --------------------------------
  # Match against the realpath of ~/.claude/plugins/cache/ when it exists,
  # plus a literal HOME-prefixed string match (for cases where the cache
  # directory itself doesn't exist yet on disk).
  local cache_root_literal="${HOME:-}/.claude/plugins/cache/"
  local cache_root_real=""
  if [ -n "${HOME:-}" ] && [ -d "${HOME}/.claude/plugins/cache" ]; then
    cache_root_real="$(_bc_realpath "${HOME}/.claude/plugins/cache"; printf x)"
    cache_root_real="${cache_root_real%x}"
    cache_root_real="${cache_root_real%$'\n'}"
    cache_root_real="${cache_root_real}/"
  fi
  case "$resolved_real/" in
    "$cache_root_literal"*)
      echo "bootstrap-check: unsafe category=cache-path project_dir=$resolved_real" >&2
      echo "cache-path" >&2
      return 11
      ;;
  esac
  if [ -n "$cache_root_real" ]; then
    case "$resolved_real/" in
      "$cache_root_real"*)
        echo "bootstrap-check: unsafe category=cache-path project_dir=$resolved_real" >&2
        echo "cache-path" >&2
        return 11
        ;;
    esac
  fi

  # ---- Step 4: sensitive path (/ or $HOME) ------------------------------
  if [ "$resolved_real" = "/" ]; then
    echo "bootstrap-check: unsafe category=sensitive-path project_dir=$resolved_real" >&2
    echo "sensitive-path" >&2
    return 11
  fi
  if [ -n "${HOME:-}" ]; then
    local home_real=""
    home_real="$(_bc_realpath "$HOME"; printf x)"
    home_real="${home_real%x}"
    home_real="${home_real%$'\n'}"
    if [ -z "$home_real" ]; then
      home_real="$HOME"
    fi
    if [ "$resolved_real" = "$home_real" ]; then
      echo "bootstrap-check: unsafe category=sensitive-path project_dir=$resolved_real" >&2
      echo "sensitive-path" >&2
      return 11
    fi
  fi

  # ---- Step 5: unwritable (authoritative mktemp probe) ------------------
  # `[ -w ]` is advisory only — under ACLs / Linux capabilities it can
  # disagree with actual write outcomes. The authoritative test is to
  # actually create a file. We use `mktemp` (unpredictable suffix) instead
  # of a PID-based name (`.$$`) to prevent a local attacker with write
  # access to the directory from pre-creating the bait file (`touch`
  # silently "succeeds" on an existing owned file, and the subsequent
  # `rm -f` would delete the attacker's file with no diagnostic).
  local probe_file=""
  probe_file=$(mktemp "$resolved_real/.rein-bootstrap-write-test.XXXXXXXX" 2>/dev/null)
  local probe_rc=$?
  if [ "$probe_rc" -ne 0 ] || [ -z "$probe_file" ]; then
    echo "bootstrap-check: unsafe category=unwritable project_dir=$resolved_real" >&2
    echo "unwritable" >&2
    return 11
  fi
  # Cleanup is best-effort but NOT silenced — a failure here means a probe
  # file is left behind, which is a real diagnostic signal (e.g. directory
  # became read-only between mktemp and rm, or rm itself was tampered with).
  if ! rm -f "$probe_file" 2>/dev/null; then
    echo "bootstrap-check: warning: probe cleanup failed at $probe_file" >&2
  fi

  # ---- Predicate: trail/, .rein/project.json, AND trail/index.md --------
  # BG-1 (2026-05-14): require both trail/ and .rein/project.json — eliminates
  # false positive when overlay residue trail/ exists without bootstrap
  # completion (e.g. maintainer dogfood install where dev-overlay residue
  # leaves a stray trail/ without the plugin-mode .rein/project.json marker).
  # Pre-BG-1: trail/-only check produced false positives.
  #
  # Partial-bootstrap fix (v1.3.0+1, codex round 1 missed defect #3): the
  # paired bootstrap script (rein-bootstrap-project.py) writes
  # `.rein/project.json` LAST as the completion sentinel via atomic
  # temp+rename. Combined with this gate's tri-marker check (trail dir +
  # marker + trail/index.md), the false PASS / partial-state class of
  # failures is eliminated. Pre-fix scenario: bootstrap crashes between
  # marker write and trail subdir creation -> BG-1 sees marker + trail dir
  # (created by mkdir mid-run) -> reports "bootstrapped" -> downstream
  # gates (e.g. session-start-load-trail.sh) crash on missing
  # trail/index.md, leaving stale `.session-has-src-edit` markers behind.
  local has_trail_dir=0 has_marker=0 has_index=0
  [ -d "$resolved_real/trail" ] && has_trail_dir=1
  [ -f "$resolved_real/.rein/project.json" ] && has_marker=1
  [ -f "$resolved_real/trail/index.md" ] && has_index=1

  if [ "$has_trail_dir" = "1" ] && [ "$has_marker" = "1" ] && [ "$has_index" = "1" ]; then
    # Happy path — no stdout, optional debug to stderr.
    # Keep silent on success: many hooks invoke this and chatty stderr
    # pollutes the platform log.
    return 0
  fi

  # BG-E (2026-05-15): expand bootstrap_script to a literal absolute path so
  # users can copy-paste the Run: line directly. Previously the heredoc
  # emitted `\${CLAUDE_PLUGIN_ROOT}/scripts/...` literally, which expanded to
  # an empty prefix in user shells and produced an unrecoverable deadlock.
  # Hoisted above the degraded-reason override (next block) because both it
  # and the fresh/partial templates further down need the same two values.
  local plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local bootstrap_script="${plugin_root}/scripts/rein-bootstrap-project.py"

  # Quote both rendered values through the shared helper hooks/lib/
  # shell-quote.sh (single-quoted, or `printf %q` when the value itself
  # contains a single quote) so a resolved_real containing shell
  # metacharacters (`"`, `;`, `$(...)`, backticks, spaces) renders as ONE
  # safe argument in the fresh/partial Run:/재실행 lines below instead of
  # executing extra shell code when the line is copy-pasted. Same rendering
  # rule lib/git-required-guidance.sh applies to its own Run: line — one
  # quoting rule for every rendered bootstrap command. Falls back to
  # `printf %q` directly if shell-quote.sh cannot be sourced.
  local shell_quote_lib="${plugin_root}/hooks/lib/shell-quote.sh"
  if [ -f "$shell_quote_lib" ] && ! command -v rein_shell_quote >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "$shell_quote_lib"
  fi
  local bootstrap_script_q="" resolved_real_q=""
  if command -v rein_shell_quote >/dev/null 2>&1; then
    bootstrap_script_q="$(rein_shell_quote "$bootstrap_script")"
    resolved_real_q="$(rein_shell_quote "$resolved_real")"
  else
    printf -v bootstrap_script_q '%q' "$bootstrap_script"
    printf -v resolved_real_q '%q' "$resolved_real"
  fi

  # ---- Degraded-reason guidance override (git-required onboarding) ------
  # SessionStart (session-start-bootstrap.sh) writes .claude/cache/.rein-
  # session-degraded when it can't bootstrap because git is missing or this
  # folder isn't a git repository, and prints the shared lib's guidance for
  # that reason. Without this override, THIS hook's own advisory (consumed
  # by user-prompt-submit-rules.sh, pre-tool-use-bash-bootstrap-gate.sh, and
  # pre-edit-trail-bootstrap-gate.sh) would fall through to the generic
  # fresh/partial "just run the bootstrap script" template below — which
  # contradicts what SessionStart already told the user.
  # Other degraded reasons (user-opt-out, bootstrap-refused) are not
  # git-related and keep the existing fresh/partial template unchanged.
  #
  # A full approval-question guidance on EVERY
  # UserPromptSubmit call (i.e. every turn) repeats the same question even
  # after the user has already declined once this session. Once-per-session
  # state, keyed the same way hooks/lib/select-active-dod.sh keys its
  # active-dod-choice.session-<key>.flag: the FULL guidance (with the
  # trailer) fires only the first time this reason is seen in a session
  # (creating the flag right after), every subsequent call in the same
  # session gets a single short reminder line instead — still rc=10, still
  # names the git-required reason and the recovery command, but with no
  # instruction to ask again.
  local degraded_marker="$resolved_real/.claude/cache/.rein-session-degraded"
  if [ -f "$degraded_marker" ]; then
    local degraded_reason=""
    degraded_reason="$(head -n 1 "$degraded_marker" 2>/dev/null || true)"
    case "$degraded_reason" in
      non-git-dir|git-missing)
        local git_guidance_lib="${plugin_root}/hooks/lib/git-required-guidance.sh"
        if [ -f "$git_guidance_lib" ]; then
          # shellcheck disable=SC1090
          source "$git_guidance_lib"
          if rein_git_guidance_already_shown "$resolved_real"; then
            local git_reminder=""
            git_reminder="$(rein_git_required_reminder "$degraded_reason" "$resolved_real" "$bootstrap_script")"
            if [ -n "$git_reminder" ]; then
              local reminder_size=""
              reminder_size=$(printf '%s' "$git_reminder" | wc -c | tr -d ' ')
              echo "bootstrap-check: project_dir=$resolved_real guidance_size=$reminder_size source=$source degraded_reason=$degraded_reason reminder=1" >&2
              printf '%s' "$git_reminder"
              return 10
            fi
          else
            local git_guidance=""
            git_guidance="$(rein_git_required_guidance "$degraded_reason" "$resolved_real" "$bootstrap_script")"
            if [ -n "$git_guidance" ]; then
              local override_guidance="${git_guidance}
(Claude: surface this message to the user immediately before doing anything else.)
"
              local override_size=""
              override_size=$(printf '%s' "$override_guidance" | wc -c | tr -d ' ')
              echo "bootstrap-check: project_dir=$resolved_real guidance_size=$override_size source=$source degraded_reason=$degraded_reason reminder=0" >&2
              rein_git_guidance_mark_shown "$resolved_real"
              printf '%s' "$override_guidance"
              return 10
            fi
          fi
        fi
        ;;
    esac
    # Any other reason (or a lib/function failure above) falls through to
    # the fresh/partial templates below — fail-soft, this override must
    # never turn into a hard failure.
  fi

  # ---- Partial-bootstrap detection --------------------------------------
  # Distinct from "fresh install" (nothing exists). Partial = at least one
  # marker present, at least one missing. We surface a re-run command that is
  # safe to invoke (rein-bootstrap-project.py is idempotent —
  # write_text_if_missing + mkdir(exist_ok=True) + atomic marker write) and
  # explicitly name which parts are present vs missing so the user
  # understands the recovery state.
  local partial=0
  if [ "$has_trail_dir" = "1" ] || [ "$has_marker" = "1" ] || [ "$has_index" = "1" ]; then
    if [ "$has_trail_dir" = "0" ] || [ "$has_marker" = "0" ] || [ "$has_index" = "0" ]; then
      partial=1
    fi
  fi

  # ---- Guidance message (exit 10) ---------------------------------------
  # Byte-exact bilingual template, trailing newline preserved. plugin_root /
  # bootstrap_script were already computed above (degraded-reason override
  # block) — reused here unchanged.
  local guidance
  if [ "$partial" = "1" ]; then
    # Partial-state branch — name each present/missing component so the user
    # understands why a re-run is safe (and so support diagnostics get
    # enough context from a copy-pasted error).
    local present_list="" missing_list=""
    if [ "$has_trail_dir" = "1" ]; then present_list="${present_list}trail/ "; else missing_list="${missing_list}trail/ "; fi
    if [ "$has_marker" = "1" ]; then present_list="${present_list}.rein/project.json "; else missing_list="${missing_list}.rein/project.json "; fi
    if [ "$has_index" = "1" ]; then present_list="${present_list}trail/index.md "; else missing_list="${missing_list}trail/index.md "; fi
    # Trim trailing spaces.
    present_list="${present_list% }"
    missing_list="${missing_list% }"
    guidance=$(cat <<EOF
ERROR: rein plugin bootstrap가 부분 완료 상태입니다 — 이전 bootstrap이 중간에 실패했을 수 있습니다.
ERROR: rein plugin bootstrap is in PARTIAL state — a prior bootstrap likely crashed mid-run.
  존재 / Present: ${present_list}
  누락 / Missing: ${missing_list}

재실행 (idempotent — 안전): python3 ${bootstrap_script_q} --project-dir ${resolved_real_q}
Re-run (idempotent — safe): python3 ${bootstrap_script_q} --project-dir ${resolved_real_q}

(Claude: surface this message to the user immediately before doing anything else.)
EOF
)
  else
    guidance=$(cat <<EOF
ERROR: rein plugin의 trail/ 디렉토리가 없거나 .rein/project.json marker가 없습니다 — bootstrap 미완료.
ERROR: rein plugin trail/ directory missing or .rein/project.json marker absent — bootstrap not initialized.

실행: python3 ${bootstrap_script_q} --project-dir ${resolved_real_q}
Run: python3 ${bootstrap_script_q} --project-dir ${resolved_real_q}

(Claude: surface this message to the user immediately before doing anything else.)
EOF
)
  fi
  # Append trailing newline (heredoc strips the final \n once via $(...))
  guidance="${guidance}
"

  # Size diagnostic (bytes, UTF-8 — `wc -c` counts bytes).
  local guidance_size=""
  guidance_size=$(printf '%s' "$guidance" | wc -c | tr -d ' ')
  echo "bootstrap-check: project_dir=$resolved_real guidance_size=$guidance_size source=$source" >&2

  printf '%s' "$guidance"
  return 10
}

# If executed directly (not sourced), forward $1 as the project_dir override.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  bootstrap_check "${1:-}"
fi
