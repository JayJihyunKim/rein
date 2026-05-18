#!/bin/bash
# tests/hooks/test-project-dir-resolution.sh
#
# Regression suite for `.claude/hooks/lib/project-dir.sh::resolve_project_dir`.
# Verifies the priority order:
#   1. $REIN_PROJECT_DIR_OVERRIDE        — explicit
#   2. $REIN_PROJECT_DIR                 — legacy explicit
#   3. $CLAUDE_PLUGIN_ROOT set           — git rev-parse from cwd, then $PWD
#   4. SCRIPT_DIR/../.. has trail/       — hook-owner project (scaffold mode)
#   5. SCRIPT_DIR/../.. without trail/   — legacy positional fallback
#   6. git rev-parse from cwd            — last attempt before $PWD
#   7. $PWD                              — final fallback
#
# Including codex review 2026-04-29 reproduction: hook in project A invoked
# while cwd is unrelated git repo B must return A, not B.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PROJECT_ROOT/plugins/rein-core/hooks/lib/project-dir.sh"

PASS=0
FAIL=0
TMP_DIRS=()

cleanup() {
  for d in "${TMP_DIRS[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

assert_equal() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected=%s\n    actual=  %s\n' "$label" "$expected" "$actual"
  fi
}

# Run resolve_project_dir under controlled cwd + env. Forces a clean env so
# host-leaked REIN_PROJECT_DIR{,_OVERRIDE,_PLUGIN_ROOT} cannot poison the
# result. Optional 5th arg sets CLAUDE_PLUGIN_ROOT.
_invoke() {
  local cwd="$1" script_dir="$2" override="${3:-}" legacy_env="${4:-}" plugin_root="${5:-}"
  (
    cd "$cwd"
    unset REIN_PROJECT_DIR REIN_PROJECT_DIR_OVERRIDE CLAUDE_PLUGIN_ROOT
    if [ -n "$override" ]; then export REIN_PROJECT_DIR_OVERRIDE="$override"; fi
    if [ -n "$legacy_env" ]; then export REIN_PROJECT_DIR="$legacy_env"; fi
    if [ -n "$plugin_root" ]; then export CLAUDE_PLUGIN_ROOT="$plugin_root"; fi
    # shellcheck disable=SC1090
    . "$HELPER"
    resolve_project_dir "$script_dir"
  )
}

# Resolve symlinks the way `pwd` does (macOS /tmp -> /private/tmp etc.) so
# expected/actual comparisons hold.
_realpath() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

# Build a rein-style project layout (.claude/hooks/lib + trail/) at the
# given dir + git init.
_mkrein() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/trail/inbox" "$dir/trail/dod"
  cp "$HELPER" "$dir/.claude/hooks/lib/project-dir.sh"
  (
    cd "$dir"
    git init -q
    git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  )
}

# --- Setup A: scaffold-mode project with trail/ ----------------------------
SANDBOX_A=$(mktemp -d "/tmp/proj-dir-A-XXXXXX")
TMP_DIRS+=("$SANDBOX_A")
SANDBOX_A_REAL="$(_realpath "$SANDBOX_A")"
_mkrein "$SANDBOX_A_REAL"
SCRIPT_A="$SANDBOX_A_REAL/.claude/hooks"

echo "Suite A — scaffold mode (hook owns project with trail/)"
out=$(_invoke "$SANDBOX_A_REAL" "$SCRIPT_A")
assert_equal "SCRIPT_DIR/../.. with trail/ wins (project-owner)" "$SANDBOX_A_REAL" "$out"

out=$(_invoke "$SANDBOX_A_REAL" "$SCRIPT_A" "/tmp/override-target")
assert_equal "REIN_PROJECT_DIR_OVERRIDE wins above all" "/tmp/override-target" "$out"

out=$(_invoke "$SANDBOX_A_REAL" "$SCRIPT_A" "" "/tmp/legacy-target")
assert_equal "REIN_PROJECT_DIR legacy env wins over project-owner" "/tmp/legacy-target" "$out"

# --- Setup B: hostile cwd (codex review 2026-04-29 High repro) -------------
# Hook lives in project A. cwd is unrelated git repo B. Helper must return
# A (the hook-owner), NOT B (cwd-git). Otherwise trail writes leak into B.
SANDBOX_B=$(mktemp -d "/tmp/proj-dir-B-XXXXXX")
TMP_DIRS+=("$SANDBOX_B")
SANDBOX_B_REAL="$(_realpath "$SANDBOX_B")"
(
  cd "$SANDBOX_B_REAL"
  git init -q
  git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)

echo "Suite B — hostile cwd (project A's hook invoked from unrelated repo B)"
out=$(_invoke "$SANDBOX_B_REAL" "$SCRIPT_A")
assert_equal "scaffold-mode wins over cwd-git (no trail leak to B)" \
  "$SANDBOX_A_REAL" "$out"

# --- Setup C: plugin mode --------------------------------------------------
# Hook physically lives in plugin install (no trail/). User's project is cwd.
# CLAUDE_PLUGIN_ROOT signals plugin mode; helper must use cwd-git.
SANDBOX_C_PLUGIN=$(mktemp -d "/tmp/proj-dir-Cp-XXXXXX")
TMP_DIRS+=("$SANDBOX_C_PLUGIN")
mkdir -p "$SANDBOX_C_PLUGIN/install/.claude/hooks/lib"
cp "$HELPER" "$SANDBOX_C_PLUGIN/install/.claude/hooks/lib/project-dir.sh"
SCRIPT_C="$(_realpath "$SANDBOX_C_PLUGIN")/install/.claude/hooks"

SANDBOX_C_USER=$(mktemp -d "/tmp/proj-dir-Cu-XXXXXX")
TMP_DIRS+=("$SANDBOX_C_USER")
SANDBOX_C_USER_REAL="$(_realpath "$SANDBOX_C_USER")"
_mkrein "$SANDBOX_C_USER_REAL"

echo "Suite C — plugin mode (CLAUDE_PLUGIN_ROOT set)"
out=$(_invoke "$SANDBOX_C_USER_REAL" "$SCRIPT_C" "" "" "$SCRIPT_C")
assert_equal "plugin mode: cwd-git wins (user project)" \
  "$SANDBOX_C_USER_REAL" "$out"

# --- Setup D: git worktree (scaffold-mode worktree) ------------------------
# Worktree has its own trail/. Helper picks it (worktree-local accumulation).
WORKTREE_D="$SANDBOX_A_REAL/.worktrees/feature"
(
  cd "$SANDBOX_A_REAL"
  git worktree add -q -b feat-test "$WORKTREE_D" >/dev/null
)
WORKTREE_D_REAL="$(_realpath "$WORKTREE_D")"
mkdir -p "$WORKTREE_D_REAL/.claude/hooks/lib" "$WORKTREE_D_REAL/trail"
cp "$HELPER" "$WORKTREE_D_REAL/.claude/hooks/lib/project-dir.sh"
SCRIPT_D="$WORKTREE_D_REAL/.claude/hooks"

echo "Suite D — git worktree (worktree owns its own trail/)"
out=$(_invoke "$WORKTREE_D_REAL" "$SCRIPT_D")
assert_equal "worktree with trail/ stays local" "$WORKTREE_D_REAL" "$out"

# --- Setup E: legacy fallbacks (no git, no trail/) -------------------------
SANDBOX_E=$(mktemp -d "/tmp/proj-dir-E-XXXXXX")
TMP_DIRS+=("$SANDBOX_E")
mkdir -p "$SANDBOX_E/repo/.claude/hooks/lib"
cp "$HELPER" "$SANDBOX_E/repo/.claude/hooks/lib/project-dir.sh"
SANDBOX_E_REAL="$(_realpath "$SANDBOX_E")"
SCRIPT_E="$SANDBOX_E_REAL/repo/.claude/hooks"
NO_GIT_CWD="$SANDBOX_E_REAL"

echo "Suite E — legacy fallbacks"
out=$(_invoke "$NO_GIT_CWD" "$SCRIPT_E")
assert_equal "no trail/ + no git -> SCRIPT_DIR/../.. fallback" \
  "$SANDBOX_E_REAL/repo" "$out"

out=$(_invoke "$NO_GIT_CWD" "")
assert_equal "no SCRIPT_DIR + no git -> \$PWD" "$NO_GIT_CWD" "$out"

# --- Suite F: post-edit-index-sync-inbox ancestry guard --------------------
# Codex round 2: relative + absolute-outside FILE_PATH must NOT trigger
# inbox writes when invoked with hostile cwd. Reuses Suite A (real rein
# project) and Suite B's hostile cwd.
HOOK_SRC="$PROJECT_ROOT/plugins/rein-core/hooks/post-edit-index-sync-inbox.sh"
mkdir -p "$SANDBOX_A_REAL/.claude/hooks"
cp "$HOOK_SRC" "$SANDBOX_A_REAL/.claude/hooks/post-edit-index-sync-inbox.sh"
# Need supporting libs the hook sources (python-runner.sh, extract-hook-json.py).
cp -R "$PROJECT_ROOT/plugins/rein-core/hooks/lib/." "$SANDBOX_A_REAL/.claude/hooks/lib/"
INDEX_HOOK="$SANDBOX_A_REAL/.claude/hooks/post-edit-index-sync-inbox.sh"
INBOX_DIR_A="$SANDBOX_A_REAL/trail/inbox"
INBOX_DIR_B="$SANDBOX_B_REAL/trail/inbox"
mkdir -p "$INBOX_DIR_B"

echo "Suite F — post-edit-index-sync-inbox ancestry guard"

# Helper: invoke index-sync hook with given cwd + JSON file_path.
_invoke_index_hook() {
  local cwd="$1" file_path="$2"
  local json
  json=$(printf '{"tool_input":{"file_path":"%s"}}' "$file_path")
  (
    cd "$cwd" || exit 1
    unset REIN_PROJECT_DIR REIN_PROJECT_DIR_OVERRIDE CLAUDE_PLUGIN_ROOT
    printf '%s' "$json" | bash "$INDEX_HOOK" >/dev/null 2>&1
  )
}

# Subtest 1: relative file_path while cwd is hostile → no inbox write to A or B.
rm -f "$INBOX_DIR_A"/*-session.md "$INBOX_DIR_B"/*-session.md 2>/dev/null
_invoke_index_hook "$SANDBOX_B_REAL" "trail/index.md"
COUNT_A=$(ls "$INBOX_DIR_A"/*-session.md 2>/dev/null | wc -l | tr -d ' ')
COUNT_B=$(ls "$INBOX_DIR_B"/*-session.md 2>/dev/null | wc -l | tr -d ' ')
assert_equal "relative path + hostile cwd: no inbox in project A" "0" "$COUNT_A"
assert_equal "relative path + hostile cwd: no inbox in unrelated B" "0" "$COUNT_B"

# Subtest 2: absolute path inside project A while cwd is hostile B → write to A only.
rm -f "$INBOX_DIR_A"/*-session.md "$INBOX_DIR_B"/*-session.md 2>/dev/null
_invoke_index_hook "$SANDBOX_B_REAL" "$SANDBOX_A_REAL/trail/index.md"
COUNT_A=$(ls "$INBOX_DIR_A"/*-session.md 2>/dev/null | wc -l | tr -d ' ')
COUNT_B=$(ls "$INBOX_DIR_B"/*-session.md 2>/dev/null | wc -l | tr -d ' ')
assert_equal "abs path inside A + hostile cwd: inbox written to A" "1" "$COUNT_A"
assert_equal "abs path inside A + hostile cwd: B remains clean" "0" "$COUNT_B"

# Subtest 3: absolute path outside any rein project (e.g. /tmp/...) → no write.
rm -f "$INBOX_DIR_A"/*-session.md "$INBOX_DIR_B"/*-session.md 2>/dev/null
_invoke_index_hook "$SANDBOX_A_REAL" "/tmp/some-other/trail/index.md"
COUNT_A=$(ls "$INBOX_DIR_A"/*-session.md 2>/dev/null | wc -l | tr -d ' ')
assert_equal "abs path outside PROJECT_DIR: no inbox written" "0" "$COUNT_A"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-project-dir-resolution: $PASS PASS"
  exit 0
else
  echo "test-project-dir-resolution: $FAIL FAIL / $((PASS + FAIL)) total"
  exit 1
fi
