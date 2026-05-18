#!/bin/bash
# tests/hooks/test-stop-gate-deadlock.sh
#
# Reproduction + regression tests for the v0.4.1 hotfix limitation.
#
# Background
# ----------
# v0.4.1 added post-edit-index-sync-inbox.sh, a PostToolUse hook that
# auto-creates today's trail/inbox/*.md when trail/index.md is edited. The
# purpose was to resolve a deadlock where a 3rd-party fact-force plugin
# blocked Claude's Write tool from creating new files, leaving the user
# unable to produce an inbox file and therefore unable to pass
# stop-session-gate.sh on session exit.
#
# The v0.4.1 fix had a precondition that was never validated:
#   **the user must edit trail/index.md during the session**
# If the user never touches index.md (e.g., they are stuck trying to
# create the inbox file and don't think to go edit index.md), the hook
# never fires and the deadlock persists.
#
# These tests prove that limitation exists (Phase 1) and later — after
# the v0.4.3 relaxation — verify the deadlock is resolved (Phase 2).
#
# Phase 1 (pre-v0.4.3): test_deadlock_reproduction_* SHOULD FAIL
#   (i.e., stop-session-gate exits 2, proving the deadlock).
# Phase 2 (post-v0.4.3): all tests should PASS.
#
# The tests below include the Phase-2 success assertions. Until v0.4.3
# lands, test_reproduces_deadlock_no_git_activity and
# test_gate_passes_with_today_commit are the two cases that will fail
# and motivate the fix.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

# Most tests need stop-session-gate.sh, but two scenarios specifically
# want the v0.4.1 hook to have been INSTALLED but NOT FIRED. The
# test-harness copies hooks into the sandbox, but hooks only fire via
# Claude Code; in the test environment we invoke stop-gate directly so
# post-edit-index-sync-inbox never runs unless we call it ourselves.
# This is exactly the real-world failure condition we're trying to
# capture.

_seed_bootstrap_marker() {
  # BG-1 / BG-D 신 contract: stop-session-gate.sh 는 .rein/project.json 부재 시
  # "bootstrap incomplete" 분기로 즉시 exit 0. 이 파일의 legacy 픽스처는
  # bootstrap 이 정상 완료된 환경에서의 inbox/git/index 동작을 검증하므로
  # 마커를 명시적으로 시드한다 (BG-D escape 를 의도적으로 우회).
  mkdir -p "$SANDBOX/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
    > "$SANDBOX/.rein/project.json"
}

_init_git_with_today_commit() {
  # Initialize a git repo in the sandbox and create ONE commit today.
  _seed_bootstrap_marker
  (
    cd "$SANDBOX" || exit 1
    git init --quiet >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "test"
    echo "content" > .rein-test-marker
    git add .rein-test-marker
    git -c commit.gpgsign=false commit -q -m "test: baseline" >/dev/null 2>&1
  )
}

_init_git_no_commits() {
  # Initialize a git repo with a single baseline commit dated yesterday.
  # The v0.4.3 gate uses `git diff HEAD` (tracked changes only), so any
  # untracked files left over from test harness setup do NOT count as
  # activity — no .gitignore trick needed.
  _seed_bootstrap_marker
  (
    cd "$SANDBOX" || exit 1
    git init --quiet >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "test"
    # A single tracked file as the baseline. Content is irrelevant; we
    # just need SOMETHING to exist in HEAD so later `diff HEAD` comparisons
    # have a reference point.
    printf 'baseline\n' > .rein-test-baseline
    git add .rein-test-baseline >/dev/null 2>&1
    git -c commit.gpgsign=false commit -q -m "init" >/dev/null 2>&1
    # Backdate to yesterday so the init commit is not counted as
    # "today's git activity".
    local yest_epoch
    yest_epoch=$(($(date +%s) - 86400))
    GIT_COMMITTER_DATE="$yest_epoch -0000" \
    GIT_AUTHOR_DATE="$yest_epoch -0000" \
      git -c commit.gpgsign=false commit --amend --no-edit --date="$yest_epoch -0000" >/dev/null 2>&1
  )
}

_init_git_with_uncommitted_change() {
  # _init_git_no_commits already creates a baseline tracked file
  # (`.rein-test-baseline`) committed yesterday. Modify it to simulate
  # "user did real work but has not yet committed or made an inbox file"
  # — the primary deadlock use case v0.4.3 unblocks.
  _init_git_no_commits
  (
    cd "$SANDBOX" || exit 1
    echo "wip user change" >> .rein-test-baseline
  )
}

_refresh_index_mtime_to_today() {
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# index
- status: test
- current: stop gate
- next: verify
- note: fixture
EOF
  touch "$SANDBOX/trail/index.md"
  # QA 세션 감지: 소스 편집이 있었던 세션으로 마킹 (없으면 gate 가 즉시 exit 0)
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
}

# =============================================================================
# Phase 1 — Reproduction: v0.4.1 hotfix precondition failure
# =============================================================================

# This test reproduces the exact failure mode in the incident report:
# no inbox for today, no git activity at all, session end attempted.
# The stop-gate should still block — because an empty session with no
# recorded work SHOULD block. v0.4.3 must preserve this "truly empty"
# block while still resolving the fact-force deadlock for active
# sessions.
test_empty_session_blocks() {
  _init_git_no_commits
  _refresh_index_mtime_to_today
  # Deliberately do NOT seed any inbox

  run_hook "stop-session-gate.sh"

  assert_exit 2 "empty session (no inbox, no git activity) must still block"
  assert_stderr_contains "inbox"
}

# This is the CORE reproduction: a session where real work happened
# (git changes exist) but the user could not create an inbox file due
# to fact-force blocking. Under v0.4.1, stop-gate blocks — deadlock.
# Under v0.4.3, stop-gate should detect the git activity and pass.
test_session_with_uncommitted_work_should_pass_post_v043() {
  _init_git_with_uncommitted_change
  _refresh_index_mtime_to_today
  # No inbox, but git status --porcelain has uncommitted changes

  run_hook "stop-session-gate.sh"

  # POST-v0.4.3 expectation
  assert_exit 0 "session with uncommitted git work should PASS (git activity is proof of work)"
  assert_stderr_contains "git"
}

# Same core reproduction but with a committed change today.
test_session_with_today_commit_should_pass_post_v043() {
  _init_git_with_today_commit
  _refresh_index_mtime_to_today
  # No inbox, but there's a commit from today

  run_hook "stop-session-gate.sh"

  assert_exit 0 "session with today's commit should PASS (git activity is proof of work)"
  assert_stderr_contains "git"
}

# =============================================================================
# Phase 1 — Reproduction: explicit bypass env var
# =============================================================================

test_env_bypass_allows_exit_on_empty_session() {
  _init_git_no_commits
  _refresh_index_mtime_to_today
  # Empty session that would normally block

  REIN_BYPASS_STOP_GATE=1 run_hook "stop-session-gate.sh"

  assert_exit 0 "REIN_BYPASS_STOP_GATE=1 must allow exit"
  assert_stderr_contains "bypass"
}

# =============================================================================
# Phase 1 — Regression: manual inbox + index.md path still works
# =============================================================================

test_happy_path_with_inbox_still_works() {
  _init_git_no_commits
  _refresh_index_mtime_to_today
  local today
  today=$(date +%Y-%m-%d)
  seed_inbox "${today}-legit-work.md" "# manual record"

  run_hook "stop-session-gate.sh"

  assert_exit 0 "valid session state with manual inbox must pass"
}

# =============================================================================
# Phase 1 — Regression: stale index.md still blocks
# =============================================================================

test_stale_index_still_blocks() {
  _init_git_no_commits
  # QA 세션 감지: 소스 편집이 있었던 세션으로 마킹
  touch "$SANDBOX/trail/dod/.session-has-src-edit"
  # index.md exists but was last touched yesterday
  cat > "$SANDBOX/trail/index.md" <<'EOF'
# stale
- status: test
- current: stop gate
- next: verify
- note: fixture
EOF
  # set mtime to yesterday using portable approach
  if ! touch -t "$(date -v-1d +%Y%m%d0000 2>/dev/null || date -d 'yesterday' +%Y%m%d0000)" "$SANDBOX/trail/index.md" 2>/dev/null; then
    # if we can't set an old mtime, just skip this assertion
    return
  fi
  local today
  today=$(date +%Y-%m-%d)
  seed_inbox "${today}-work.md" "# work"

  run_hook "stop-session-gate.sh"

  assert_exit 2 "stale index.md must still block"
  assert_stderr_contains "index.md"
}

# =============================================================================
# Phase 1 — Non-git project: the safety net only applies inside git
# =============================================================================

test_non_git_project_empty_session_blocks() {
  # Not a git repo, no inbox → must block (git safety net not available).
  # Bootstrap marker is required so the BG-D early-escape does NOT trigger
  # before we reach the inbox-or-git validation (the contract under test).
  _seed_bootstrap_marker
  _refresh_index_mtime_to_today

  run_hook "stop-session-gate.sh"

  assert_exit 2 "non-git empty session must block"
}

# =============================================================================
# Governance: untracked-only state must NOT be treated as "work"
# This prevents noise (.DS_Store, swap files, build artifacts) from
# silently bypassing the inbox requirement. (security-reviewer M1)
# =============================================================================

test_untracked_only_state_still_blocks() {
  _init_git_no_commits
  _refresh_index_mtime_to_today
  # Create an untracked file simulating .DS_Store / editor swap noise.
  # This must NOT count as "work" under v0.4.3's tracked-only semantics.
  echo "junk" > "$SANDBOX/.DS_Store"

  run_hook "stop-session-gate.sh"

  assert_exit 2 "untracked-only state must still block (noise rejection)"
  assert_stderr_contains "inbox"
}

test_bypass_writes_audit_log() {
  _init_git_no_commits
  _refresh_index_mtime_to_today

  REIN_BYPASS_STOP_GATE=1 run_hook "stop-session-gate.sh"
  assert_exit 0 "bypass should allow exit"

  # Verify the audit trail was written
  if [[ ! -f "$SANDBOX/trail/incidents/blocks.log" ]]; then
    fail "trail/incidents/blocks.log should exist after bypass"
  fi
  if ! grep -q "BYPASS_ENV" "$SANDBOX/trail/incidents/blocks.log" 2>/dev/null; then
    fail "blocks.log should contain BYPASS_ENV marker"
  fi
}

run_test test_empty_session_blocks                              "stop-session-gate.sh"
run_test test_session_with_uncommitted_work_should_pass_post_v043 "stop-session-gate.sh"
run_test test_session_with_today_commit_should_pass_post_v043   "stop-session-gate.sh"
run_test test_env_bypass_allows_exit_on_empty_session           "stop-session-gate.sh"
run_test test_happy_path_with_inbox_still_works                 "stop-session-gate.sh"
run_test test_stale_index_still_blocks                          "stop-session-gate.sh"
run_test test_non_git_project_empty_session_blocks              "stop-session-gate.sh"
run_test test_untracked_only_state_still_blocks                 "stop-session-gate.sh"
run_test test_bypass_writes_audit_log                           "stop-session-gate.sh"

# =============================================================================
# BG-I fixtures (v1.3.0 deadlock fix) — BG-D contract: stop hook must NOT
# block when bootstrap is incomplete (fresh install) or degraded mode is
# active. Spec: /Users/jihyunkim/.claude/plans/b-prancy-valiant.md §BG-D.
# =============================================================================
# These fixtures bypass the test-harness `run_test`/`sandbox_setup` path
# because the harness expects hooks under .claude/hooks/, but the plugin-SSOT
# layout (Option C Phase 3) keeps the real hook only in plugins/rein-core/.
# Instead we invoke the plugin hook directly with a fresh tmpdir sandbox
# (the same pattern test-pre-tool-use-bash-bootstrap-gate.sh uses for
# fixtures A-I). The fixtures still feed back into TEST_COUNT/FAIL_COUNT so
# the summary line is accurate.

BGI_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BGI_PROJECT_DIR="$(cd "$BGI_SCRIPT_DIR/../.." && pwd)"
BGI_PLUGIN_ROOT="$BGI_PROJECT_DIR/plugins/rein-core"
BGI_HOOK="$BGI_PLUGIN_ROOT/hooks/stop-session-gate.sh"

_bgi_record_pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
  echo "  OK"
}
_bgi_record_fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "RUN $1"
  echo "  FAIL: $2" >&2
}

# ----------------------------------------------------------------------------
# Fixture H — SRC_EDIT_MARKER present + .rein/project.json absent
#   → exit 0 + stderr "bootstrap incomplete" (BG-D fresh-install escape)
# ----------------------------------------------------------------------------
# Reproduction of the bootstrap-gate-deadlock.md incident: a session that
# touched source files (SRC_EDIT_MARKER created) but the user's repo never
# completed bootstrap (.rein/project.json absent). Pre-BG-D the stop hook
# would fall into the incident gate aggregation and block forever — the
# user could not exit the session even with REIN_BYPASS_STOP_GATE because
# the loop counter kept growing. BG-D adds an early `exit 0` once the
# advisory check has run.
fixture_h() {
  local label="fixture_h_bootstrap_incomplete_escape"
  if [ ! -x "$BGI_HOOK" ]; then
    _bgi_record_fail "$label" "plugin hook not executable: $BGI_HOOK"
    return
  fi
  local dir
  dir="$(mktemp -d "/tmp/bgi-stop-H-XXXXXX")"
  # Build a "session with source edits but incomplete bootstrap" sandbox:
  #   - trail/dod/.session-has-src-edit (SRC_EDIT_MARKER)  → present
  #   - trail/                                             → present (partial)
  #   - .rein/project.json                                 → absent (BG-1)
  #   - degraded marker                                    → absent
  mkdir -p "$dir/trail/dod" "$dir/trail/inbox" "$dir/trail/incidents"
  touch "$dir/trail/dod/.session-has-src-edit"
  cat > "$dir/trail/index.md" <<'EOF'
# index
- status: bootstrap-incomplete fixture
- current: stop gate H
- next: verify BG-D escape
- note: regression test
EOF
  touch "$dir/trail/index.md"
  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$BGI_PLUGIN_ROOT" \
       bash "$BGI_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"
  rm -rf "$dir"
  if [ "$rc" -ne 0 ]; then
    _bgi_record_fail "$label" "expected exit 0 (BG-D escape), got $rc; stderr: $err"
    return
  fi
  if ! printf '%s' "$err" | grep -q "bootstrap incomplete"; then
    _bgi_record_fail "$label" "stderr missing 'bootstrap incomplete' (got: $err)"
    return
  fi
  _bgi_record_pass "$label"
}

# ----------------------------------------------------------------------------
# Fixture I — SRC_EDIT_MARKER present + degraded marker present
#   → exit 0 + stderr "degraded mode" (BG-D degraded escape)
# ----------------------------------------------------------------------------
# When SessionStart wrote .claude/cache/.rein-session-degraded (because git
# is missing / cwd is not a git repo / user opted out / bootstrap helper
# refused), the stop gate must skip the incident aggregation entirely and
# emit a clear "degraded mode" diagnostic so blocks.log auditors can
# correlate the bypass to the SessionStart decision.
fixture_i() {
  local label="fixture_i_degraded_mode_escape"
  if [ ! -x "$BGI_HOOK" ]; then
    _bgi_record_fail "$label" "plugin hook not executable: $BGI_HOOK"
    return
  fi
  local dir
  dir="$(mktemp -d "/tmp/bgi-stop-I-XXXXXX")"
  # Build a "session with source edits + degraded marker" sandbox.
  # We include .rein/project.json here so the degraded branch is what
  # actually triggers the exit 0 (and not the BG-D bootstrap-incomplete
  # branch, which would also pass but with a different stderr message).
  mkdir -p "$dir/trail/dod" "$dir/trail/inbox" "$dir/trail/incidents" \
           "$dir/.claude/cache" "$dir/.rein"
  touch "$dir/trail/dod/.session-has-src-edit"
  printf 'non-git-dir\n' > "$dir/.claude/cache/.rein-session-degraded"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
    > "$dir/.rein/project.json"
  cat > "$dir/trail/index.md" <<'EOF'
# index
- status: degraded fixture
- current: stop gate I
- next: verify BG-D degraded escape
- note: regression test
EOF
  touch "$dir/trail/index.md"
  local errfile
  errfile="$(mktemp)"
  local rc
  (cd "$dir" \
    && REIN_PROJECT_DIR_OVERRIDE="$dir" \
       CLAUDE_PLUGIN_ROOT="$BGI_PLUGIN_ROOT" \
       bash "$BGI_HOOK" </dev/null >/dev/null 2>"$errfile")
  rc=$?
  local err
  err=$(cat "$errfile")
  rm -f "$errfile"
  rm -rf "$dir"
  if [ "$rc" -ne 0 ]; then
    _bgi_record_fail "$label" "expected exit 0 (BG-D degraded escape), got $rc; stderr: $err"
    return
  fi
  if ! printf '%s' "$err" | grep -q "degraded mode"; then
    _bgi_record_fail "$label" "stderr missing 'degraded mode' (got: $err)"
    return
  fi
  _bgi_record_pass "$label"
}

fixture_h
fixture_i

summary
