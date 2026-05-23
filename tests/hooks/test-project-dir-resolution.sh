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
# PD-1 (2026-05-19): the fixed `SCRIPT_DIR/../..` positional fallback was
# removed in favor of trail/ walk-up + script_dir-anchored git. When there is
# no trail/ ancestor AND neither script_dir nor cwd is a git repo, resolution
# falls through to $PWD (step 7). The old behavior returned a guessed
# `SCRIPT_DIR/../..` which could silently point at the wrong directory for
# callers at a non-hook depth — that guesswork is intentionally gone.
out=$(_invoke "$NO_GIT_CWD" "$SCRIPT_E")
assert_equal "no trail/ + no git (script_dir not in git) -> \$PWD" \
  "$NO_GIT_CWD" "$out"

out=$(_invoke "$NO_GIT_CWD" "")
assert_equal "no SCRIPT_DIR + no git -> \$PWD" "$NO_GIT_CWD" "$out"

# --- Suite G: PD-1 — caller-depth-agnostic trail/ walk-up ------------------
# A helper script lives in `<repo>/scripts/` (one level deep), not the hook
# layout `<repo>/.claude/hooks/` (two levels deep). The old fixed `../..`
# assumption made resolve_project_dir return the repo's PARENT for a
# 1-level-deep caller. The walk-up must climb to the nearest trail/ ancestor
# regardless of caller depth.
SANDBOX_G=$(mktemp -d "/tmp/proj-dir-G-XXXXXX")
TMP_DIRS+=("$SANDBOX_G")
SANDBOX_G_REAL="$(_realpath "$SANDBOX_G")"
# rein-style repo with trail/ + a 1-level-deep scripts/ dir.
mkdir -p "$SANDBOX_G_REAL/repo/scripts" "$SANDBOX_G_REAL/repo/trail/dod"
cp "$HELPER" "$SANDBOX_G_REAL/repo/scripts/project-dir.sh" 2>/dev/null || true
(
  cd "$SANDBOX_G_REAL/repo"
  git init -q
  git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
SCRIPT_G="$SANDBOX_G_REAL/repo/scripts"

echo "Suite G — PD-1: 1-level-deep caller resolves to repo, not its parent"
out=$(_invoke "$SANDBOX_G_REAL/repo" "$SCRIPT_G")
assert_equal "scripts/ (1-level) caller -> repo root (not parent) via trail/ walk-up" \
  "$SANDBOX_G_REAL/repo" "$out"

# Sub-case: caller depth is irrelevant — a deeply nested helper also climbs
# to the same trail/ ancestor.
mkdir -p "$SANDBOX_G_REAL/repo/scripts/sub/deep"
out=$(_invoke "$SANDBOX_G_REAL/repo" "$SANDBOX_G_REAL/repo/scripts/sub/deep")
assert_equal "deeply-nested caller -> same trail/ ancestor" \
  "$SANDBOX_G_REAL/repo" "$out"

# Sub-case: no trail/ ancestor but caller is inside a git repo → fall back to
# `git -C "$script_dir" rev-parse`, NOT the parent directory. cwd is an
# unrelated location so cwd-git cannot mask the script_dir-git fallback.
SANDBOX_G2=$(mktemp -d "/tmp/proj-dir-G2-XXXXXX")
TMP_DIRS+=("$SANDBOX_G2")
SANDBOX_G2_REAL="$(_realpath "$SANDBOX_G2")"
mkdir -p "$SANDBOX_G2_REAL/gitrepo/scripts"
(
  cd "$SANDBOX_G2_REAL/gitrepo"
  git init -q
  git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
# No trail/ anywhere → step 5 git-from-script_dir must return the gitrepo root.
out=$(_invoke "$NO_GIT_CWD" "$SANDBOX_G2_REAL/gitrepo/scripts")
assert_equal "no trail/: 1-level caller -> script_dir git toplevel (not parent)" \
  "$SANDBOX_G2_REAL/gitrepo" "$out"

# --- Suite H: PD-1 — rein-mark-spec-reviewed.sh loud fail on bad trail/ ----
# When PROJECT_DIR resolves to a directory without trail/, the script must
# fail loudly (non-zero exit) instead of writing a stamp to a place the gate
# never reads + exiting 0.
MARK_SCRIPT="$PROJECT_ROOT/scripts/rein-mark-spec-reviewed.sh"
echo "Suite H — PD-1: rein-mark-spec-reviewed.sh loud fail when trail/ absent"
if [ -f "$MARK_SCRIPT" ]; then
  SANDBOX_H=$(mktemp -d "/tmp/proj-dir-H-XXXXXX")
  TMP_DIRS+=("$SANDBOX_H")
  SANDBOX_H_REAL="$(_realpath "$SANDBOX_H")"
  # A directory with NO trail/ — point PROJECT_DIR there via override.
  mkdir -p "$SANDBOX_H_REAL/no-trail-dir"
  : > "$SANDBOX_H_REAL/spec.md"
  mark_rc=0
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX_H_REAL/no-trail-dir" \
    bash "$MARK_SCRIPT" "$SANDBOX_H_REAL/spec.md" tester >/dev/null 2>&1 || mark_rc=$?
  if [ "$mark_rc" -ne 0 ]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "mark-spec-reviewed exits non-zero when trail/ absent"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected non-zero exit, got 0\n' \
      "mark-spec-reviewed exits non-zero when trail/ absent"
  fi
  # And it must NOT have written a stamp into the bad dir.
  if ls "$SANDBOX_H_REAL/no-trail-dir/trail/dod/.spec-reviews/"*.reviewed \
       >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "mark-spec-reviewed wrote stamp despite missing trail/"
  else
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "mark-spec-reviewed wrote no stamp when trail/ absent"
  fi
  # Positive control: with a proper trail/ dir, the script must succeed.
  mkdir -p "$SANDBOX_H_REAL/good-repo/trail/dod"
  : > "$SANDBOX_H_REAL/good-spec.md"
  good_rc=0
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX_H_REAL/good-repo" \
    bash "$MARK_SCRIPT" "$SANDBOX_H_REAL/good-spec.md" tester >/dev/null 2>&1 \
    || good_rc=$?
  if [ "$good_rc" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "mark-spec-reviewed succeeds when trail/ present"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected exit 0, got %s\n' \
      "mark-spec-reviewed succeeds when trail/ present" "$good_rc"
  fi
  # Write-failure path (codex review 2026-05-19, High): even with a valid
  # trail/, if the .reviewed marker cannot be written the script must fail
  # loudly — never print "OK" + exit 0 with a stale/old marker. Simulate by
  # making the .spec-reviews/ dir read-only so the temp write cannot happen.
  RO_REPO="$SANDBOX_H_REAL/ro-repo"
  mkdir -p "$RO_REPO/trail/dod/.spec-reviews"
  : > "$SANDBOX_H_REAL/ro-spec.md"
  chmod 500 "$RO_REPO/trail/dod/.spec-reviews"
  ro_rc=0
  ro_out=$(REIN_PROJECT_DIR_OVERRIDE="$RO_REPO" \
    bash "$MARK_SCRIPT" "$SANDBOX_H_REAL/ro-spec.md" tester 2>&1) || ro_rc=$?
  chmod 700 "$RO_REPO/trail/dod/.spec-reviews"
  if [ "$ro_rc" -ne 0 ] && ! printf '%s' "$ro_out" | grep -q '^OK:'; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "mark-spec-reviewed fails loudly when marker write fails"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected non-zero exit + no OK line, got rc=%s out=%s\n' \
      "mark-spec-reviewed fails loudly when marker write fails" "$ro_rc" "$ro_out"
  fi
  # Stale-marker replacement (codex review 2026-05-19, High): re-running mark
  # with a different reviewer must REPLACE the existing .reviewed (mv -f over
  # an existing marker) — never leave stale content behind. good-repo already
  # has a .reviewed from the positive control above (reviewer=tester).
  repl_rc=0
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX_H_REAL/good-repo" \
    bash "$MARK_SCRIPT" "$SANDBOX_H_REAL/good-spec.md" second-reviewer >/dev/null 2>&1 \
    || repl_rc=$?
  repl_file=$(ls "$SANDBOX_H_REAL/good-repo/trail/dod/.spec-reviews/"*.reviewed 2>/dev/null | head -1)
  if [ "$repl_rc" -eq 0 ] && [ -n "$repl_file" ] \
     && grep -q '^reviewer=second-reviewer$' "$repl_file"; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "mark-spec-reviewed replaces an existing .reviewed marker"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected fresh reviewer, rc=%s file=%s\n' \
      "mark-spec-reviewed replaces an existing .reviewed marker" "$repl_rc" "$repl_file"
  fi
else
  printf '  skip rein-mark-spec-reviewed.sh not found at %s\n' "$MARK_SCRIPT"
fi

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

# --- Suite J: BC-INFO1-siblings — git env-pollution must NOT latch a decoy ----
# Regression for INFO-1 (security review of v1.3.6 BC-INFO1). The cwd-git
# resolution paths (Step 3a plugin-mode + Step 6 final cwd-git) invoke
# `git rev-parse --show-toplevel`. A caller that exports a poisoned
# GIT_DIR / GIT_WORK_TREE pointing at an attacker-controlled decoy repo could
# redirect git discovery onto the decoy and make resolve_project_dir adopt it
# as the project root. The fix wraps each git invocation with
# `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE` (mirrors
# bootstrap-check.sh Fixture J2). With sanitation, discovery from $PWD finds no
# enclosing repo → falls back to $PWD; the decoy is NEVER adopted.
echo "Suite J — BC-INFO1: poisoned GIT_DIR/GIT_WORK_TREE must not latch a decoy"
if command -v git >/dev/null 2>&1; then
  # Non-git working dir: no trail/, no enclosing .git. Bound discovery with
  # GIT_CEILING_DIRECTORIES so a real ancestor repo (e.g. the test checkout)
  # cannot be discovered and confuse the assertion.
  SANDBOX_J=$(mktemp -d "/tmp/proj-dir-J-XXXXXX")
  TMP_DIRS+=("$SANDBOX_J")
  SANDBOX_J_REAL="$(_realpath "$SANDBOX_J")"
  WORK_J="$SANDBOX_J_REAL/work"          # non-git cwd
  DECOY_J="$SANDBOX_J_REAL/decoy"        # the poisoned-env target
  mkdir -p "$WORK_J" "$DECOY_J"
  ( cd "$DECOY_J" && git init -q )
  DECOY_J_REAL="$(_realpath "$DECOY_J")"

  # Run resolve_project_dir from a non-git cwd with poisoned GIT_DIR/GIT_WORK_TREE
  # pointing at the decoy. Without sanitation git rev-parse honors GIT_WORK_TREE
  # → returns the decoy. With sanitation → discovery from $PWD finds nothing →
  # falls through to $PWD ($WORK_J). The decoy must NEVER be the answer.
  _invoke_poisoned() {
    local cwd="$1" script_dir="$2" plugin_root="${3:-}"
    (
      cd "$cwd"
      unset REIN_PROJECT_DIR REIN_PROJECT_DIR_OVERRIDE CLAUDE_PLUGIN_ROOT
      export GIT_DIR="$DECOY_J_REAL/.git" GIT_WORK_TREE="$DECOY_J_REAL"
      export GIT_CEILING_DIRECTORIES="$SANDBOX_J_REAL"
      if [ -n "$plugin_root" ]; then export CLAUDE_PLUGIN_ROOT="$plugin_root"; fi
      # shellcheck disable=SC1090
      . "$HELPER"
      resolve_project_dir "$script_dir"
    )
  }

  # Step 6 path (no CLAUDE_PLUGIN_ROOT, no trail/ ancestor, script_dir not a
  # git repo): must fall through to $PWD, NOT the poisoned decoy.
  out=$(_invoke_poisoned "$WORK_J" "$WORK_J")
  if [ "$out" = "$DECOY_J_REAL" ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    latched poisoned decoy=%s\n' \
      "Step 6 cwd-git: poisoned GIT env latched decoy (BC-INFO1 unsanitized)" "$out"
  else
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "Step 6 cwd-git: poisoned GIT_DIR/GIT_WORK_TREE ignored (-> \$PWD)"
  fi

  # Step 3a path (plugin mode: CLAUDE_PLUGIN_ROOT set → cwd-git, then $PWD):
  # must use the real cwd discovery (sanitized) and fall back to $PWD, NOT the
  # poisoned decoy.
  out=$(_invoke_poisoned "$WORK_J" "$WORK_J" "$WORK_J")
  if [ "$out" = "$DECOY_J_REAL" ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    latched poisoned decoy=%s\n' \
      "Step 3a plugin-mode cwd-git: poisoned GIT env latched decoy (BC-INFO1 unsanitized)" "$out"
  else
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "Step 3a plugin-mode: poisoned GIT_DIR/GIT_WORK_TREE ignored (-> \$PWD)"
  fi

  # Step 5 path (no plugin root, no trail/ ancestor, but script_dir IS inside a
  # git repo): SCRIPT_DIR-anchored `git -C "$script_dir" rev-parse` must resolve
  # to the script_dir's OWN repo, NOT the poisoned decoy.
  SANDBOX_J5=$(mktemp -d "/tmp/proj-dir-J5-XXXXXX")
  TMP_DIRS+=("$SANDBOX_J5")
  SANDBOX_J5_REAL="$(_realpath "$SANDBOX_J5")"
  mkdir -p "$SANDBOX_J5_REAL/gitrepo/scripts"
  ( cd "$SANDBOX_J5_REAL/gitrepo" && git init -q \
      && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init )
  GITREPO_J5_REAL="$(_realpath "$SANDBOX_J5_REAL/gitrepo")"
  # cwd is the non-git WORK_J; script_dir is inside gitrepo. Step 5 anchors at
  # script_dir. Poisoned env points at the decoy → without sanitation, even the
  # `git -C "$script_dir"` form honors GIT_DIR/GIT_WORK_TREE and returns the
  # decoy. With sanitation → returns gitrepo root.
  out=$(_invoke_poisoned "$WORK_J" "$GITREPO_J5_REAL/scripts")
  if [ "$out" = "$GITREPO_J5_REAL" ]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "Step 5 script_dir-anchored: poisoned GIT env ignored (-> script_dir repo)"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected=%s actual=%s\n' \
      "Step 5 script_dir-anchored: poisoned GIT env redirected resolution (BC-INFO1)" \
      "$GITREPO_J5_REAL" "$out"
  fi
else
  printf '  skip Suite J (BC-INFO1 env hygiene) — git not installed\n'
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-project-dir-resolution: $PASS PASS"
  exit 0
else
  echo "test-project-dir-resolution: $FAIL FAIL / $((PASS + FAIL)) total"
  exit 1
fi
