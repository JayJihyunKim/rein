#!/usr/bin/env bash
# Plugin helper — bootstrap predicate.
#
# Purpose: detect whether the resolved project_dir has been bootstrapped
# (i.e. has BOTH a `trail/` directory AND a `.rein/project.json` marker).
# When not, emit a bilingual guidance message instructing the user how to
# run rein-bootstrap-project.py.
#
# BG-1 (2026-05-14): require both trail/ and .rein/project.json — eliminates
# false positive when overlay residue trail/ exists without bootstrap
# completion (e.g. maintainer dogfood install where dev-overlay residue
# leaves a stray trail/ without the plugin-mode .rein/project.json marker).
# Pre-BG-1 behaviour was trail/-only, which mistakenly signalled
# "bootstrapped" for any project that happened to have a trail/ from
# unrelated processes. trail/index.md is still NOT consulted, because the
# bootstrap script (rein-bootstrap-project.py) generates project.json and
# trail/ atomically — presence of project.json is a reliable proxy for
# "bootstrap script ran to completion in plugin mode".
#
# Usage (direct invocation):
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh" [<project_dir_override>]
#
# Usage (via stdin — hook envelope):
#   echo "$JSON" | bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
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
  local path="${1:-}"
  if [ -z "$path" ]; then
    return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null || printf '%s' "$path"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || printf '%s' "$path"
  else
    printf '%s' "$path"
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
# Main
# ---------------------------------------------------------------------------

bootstrap_check() {
  local override="${1:-}"
  local resolved=""
  local source=""

  # ---- Project dir resolution -------------------------------------------
  #
  # stdin.cwd 는 Claude Code 가 PreToolUse:Bash hook envelope 으로 넘기는
  # 셸 CWD. monorepo 에서 사용자가 `cd apps/web` 한 뒤 모든 Bash 호출은
  # envelope.cwd = apps/web 으로 들어온다. stdin.cwd 를 그대로 project-dir
  # 로 채택하면 부트스트랩 contract (rein-bootstrap-project.py: git root
  # only) 와 어긋난 위치에 trail/ 을 찾아 false-negative exit 10 이 난다.
  #
  # 따라서 stdin.cwd 가 있으면 그것을 hint 로 받아 `git -C $stdin_cwd
  # rev-parse --show-toplevel` 로 walk up. git root 있으면 그것을 채택
  # (source=git-from-stdin), 없으면 stdin.cwd 자체 (source=stdin, non-git
  # project). 나머지 fallback (git from $PWD → $PWD) 은 stdin.cwd 부재 시
  # 동작 (이전과 동일).
  if [ -n "$override" ]; then
    resolved="$override"
    source="override"
  else
    local stdin_cwd=""
    stdin_cwd="$(_bc_read_stdin_cwd)"
    if [ -n "$stdin_cwd" ] && [ -d "$stdin_cwd" ]; then
      local git_root=""
      # Sanitize inherited git env vars so the walk-up is anchored strictly
      # to stdin.cwd. GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE
      # could redirect discovery to an unrelated worktree. GIT_CEILING_DIRECTORIES
      # is deliberately preserved — it is policy-sensitive (caller may have set
      # it intentionally to bound discovery).
      git_root="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        git -C "$stdin_cwd" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
      if [ -n "$git_root" ]; then
        resolved="$git_root"
        source="git-from-stdin"
      else
        resolved="$stdin_cwd"
        source="stdin"
      fi
    elif [ -n "$stdin_cwd" ]; then
      # stdin.cwd 가 존재하지 않는 디렉토리면 git walk-up 불가.
      # Step 1 의 [ -d "$resolved_real" ] 가 resolution 실패로 처리.
      resolved="$stdin_cwd"
      source="stdin"
    else
      local git_root=""
      git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || git_root=""
      if [ -n "$git_root" ]; then
        resolved="$git_root"
        source="git"
      elif [ -n "${PWD:-}" ] && [ -d "$PWD" ]; then
        resolved="$PWD"
        source="pwd"
      else
        # All resolution paths failed.
        echo "bootstrap-check: unsafe category=resolution project_dir=" >&2
        echo "resolution" >&2
        return 11
      fi
    fi
  fi

  # ---- Step 1: realpath normalisation -----------------------------------
  local resolved_real=""
  resolved_real="$(_bc_realpath "$resolved")"
  if [ -z "$resolved_real" ]; then
    resolved_real="$resolved"
  fi

  # If the resolved path does not exist as a directory, treat it as a
  # resolution failure: we can't probe trail/ presence safely on a
  # non-existent path. (This catches the $PWD=/nonexistent case.)
  if [ ! -d "$resolved_real" ]; then
    echo "bootstrap-check: unsafe category=resolution project_dir=$resolved_real" >&2
    echo "resolution" >&2
    return 11
  fi

  # ---- Step 2: plugin install dir match (CLAUDE_PLUGIN_ROOT) ------------
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    local plugin_root_real=""
    plugin_root_real="$(_bc_realpath "$CLAUDE_PLUGIN_ROOT")"
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
    cache_root_real="$(_bc_realpath "${HOME}/.claude/plugins/cache")/"
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
    home_real="$(_bc_realpath "$HOME")"
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

  # ---- Predicate: trail/ AND .rein/project.json both present ------------
  # BG-1 (2026-05-14): require both trail/ and .rein/project.json — eliminates
  # false positive when overlay residue trail/ exists without bootstrap
  # completion (e.g. maintainer dogfood install where dev-overlay residue
  # leaves a stray trail/ without the plugin-mode .rein/project.json marker).
  # Pre-BG-1: trail/-only check produced false positives.
  if [ -d "$resolved_real/trail" ] && [ -f "$resolved_real/.rein/project.json" ]; then
    # Happy path — no stdout, optional debug to stderr.
    # Keep silent on success: many hooks invoke this and chatty stderr
    # pollutes the platform log.
    return 0
  fi

  # ---- Guidance message (exit 10) ---------------------------------------
  # Byte-exact bilingual template, trailing newline preserved.
  local guidance
  guidance=$(cat <<EOF
ERROR: rein plugin의 trail/ 디렉토리가 없거나 .rein/project.json marker가 없습니다 — bootstrap 미완료.
ERROR: rein plugin trail/ directory missing or .rein/project.json marker absent — bootstrap not initialized.

실행: python3 "\${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" --project-dir "${resolved_real}"
Run: python3 "\${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" --project-dir "${resolved_real}"

(Claude: surface this message to the user immediately before doing anything else.)
EOF
)
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
