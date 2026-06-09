#!/bin/bash
# tests/integration/test-governance-e2e.sh
#
# Plan A Phase 8 Task 8.1 end-to-end integration test for the governance
# integrity trio (validator v2 + pre-edit-dod-gate + pre-bash-test-commit-gate +
# codex-review wrapper + govcheck).
#
# Scope IDs covered (regression):
#   - GI-validator-v2-parser-single-source
#   - GI-codex-review-wrapper-script
#
# Scenarios (plan Task 8.1):
#   1. Happy path — design + plan + DoD all align → edit passes, commit passes.
#   2. DoD unknown-covers-ID + Tier 1 marker → pre-edit-dod-gate exits 2 +
#      .dod-coverage-mismatch created → pre-bash-test-commit-gate blocks commit.
#   3. Governance stage corruption → pre-edit-dod-gate blocks.
#   4. codex-review wrapper emits envelope with diff_base (fake codex).
#   5. govcheck smoke — running it in a sandbox with a fake broken ref
#      returns exit 2, restoring the ref returns exit 0.
#
# Each scenario uses an isolated sandbox (mktemp -d) with a minimal
# rein-shaped tree: .claude/hooks + hooks lib, scripts, docs, trail,
# and a fake codex binary for wrapper assertions.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

# ------------------------------------------------------------
# Shared sandbox helpers
# ------------------------------------------------------------

sandbox_init() {
  SANDBOX=$(mktemp -d "/tmp/gov-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/.claude/.rein-state"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/inbox"
  mkdir -p "$SANDBOX/trail/incidents"
  mkdir -p "$SANDBOX/docs/specs"
  mkdir -p "$SANDBOX/docs/plans"

  # Copy hooks + libs. Source dir: `.claude/hooks` (legacy dev overlay) preferred,
  # else plugin SSOT `plugins/rein-core/hooks` — Option C Phase 3 removed the dev
  # overlay so the plugin tree is the single source. Same fallback as
  # tests/hooks/lib/test-harness.sh; the sandbox TARGET layout stays
  # `.claude/hooks/` because the hooks resolve their lib via a relative path.
  local HOOKS_SRC="$REAL_PROJECT_DIR/.claude/hooks"
  [ -d "$HOOKS_SRC/lib" ] || HOOKS_SRC="$REAL_PROJECT_DIR/plugins/rein-core/hooks"
  cp "$HOOKS_SRC/pre-edit-dod-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh"
  cp "$HOOKS_SRC/pre-bash-test-commit-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-bash-test-commit-gate.sh"
  cp -R "$HOOKS_SRC/lib/." \
        "$SANDBOX/.claude/hooks/lib/"
  chmod +x "$SANDBOX/.claude/hooks"/*.sh

  # Scripts
  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  cp "$REAL_PROJECT_DIR/scripts/rein-codex-review.sh" \
     "$SANDBOX/scripts/rein-codex-review.sh"
  cp "$REAL_PROJECT_DIR/scripts/rein-govcheck.py" \
     "$SANDBOX/scripts/rein-govcheck.py"
  chmod +x "$SANDBOX/scripts"/*

  # Init git for diff_base and govcheck.
  ( cd "$SANDBOX" && git init -q \
    && git config user.email e2e@test && git config user.name e2e \
    && git commit --allow-empty -q -m "init" )

  # Seed AGENTS.md so govcheck has an entry point (even if minimal).
  printf '# Sandbox AGENTS\n\nTest fixture for govcheck.\n' > "$SANDBOX/AGENTS.md"
  mkdir -p "$SANDBOX/.claude"
  printf '# Sandbox CLAUDE.md\n' > "$SANDBOX/.claude/CLAUDE.md"
  printf '# Sandbox orchestrator\n' > "$SANDBOX/.claude/orchestrator.md"
}

sandbox_clean() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

seed_trio() {
  # Design + plan + DoD that all align on S1.
  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample
## Scope Items

| ID | desc |
|----|------|
| S1 | sample |
EOF

  cat > "$SANDBOX/docs/plans/sample-plan.md" <<'EOF'
# Plan
## Design 범위 커버리지 매트릭스

> design ref: docs/specs/sample-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| S1 | implemented | Phase 1 |

## Phase 1
covers: [S1]
EOF

  cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1]
EOF
}

seed_trio_with_bad_dod() {
  seed_trio
  # Overwrite DoD with unknown covers ID → validator fails.
  cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, UNKNOWN]
EOF
}

run_pre_edit_gate() {
  local rel_file="$1"
  local abs="$SANDBOX/$rel_file"
  local json
  json=$(printf '{"tool_input":{"file_path":"%s"}}' "$abs")
  printf '%s' "$json" \
    | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" \
      > /tmp/gate-stdout.$$ 2> /tmp/gate-stderr.$$
  GATE_RC=$?
  GATE_STDOUT=$(cat /tmp/gate-stdout.$$)
  GATE_STDERR=$(cat /tmp/gate-stderr.$$)
  rm -f /tmp/gate-stdout.$$ /tmp/gate-stderr.$$
}

run_bash_guard() {
  local command="$1"
  # Use python3 to produce a correctly-escaped JSON value. Avoids the
  # manual \"...\"  / "..." escape minefield that breaks on realistic
  # git commit -m messages.
  local json
  json=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}}))
' "$command")
  printf '%s' "$json" \
    | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-bash-test-commit-gate.sh" \
      > /tmp/bg-stdout.$$ 2> /tmp/bg-stderr.$$
  GUARD_RC=$?
  GUARD_STDOUT=$(cat /tmp/bg-stdout.$$)
  GUARD_STDERR=$(cat /tmp/bg-stderr.$$)
  rm -f /tmp/bg-stdout.$$ /tmp/bg-stderr.$$
}

run_test() {
  local fn="$1"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $fn"
  sandbox_init
  trap 'sandbox_clean' RETURN
  "$fn"
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
  trap - RETURN
  sandbox_clean
}

# ------------------------------------------------------------
# Scenario 1 — Happy path.
# ------------------------------------------------------------
test_happy_path_passes_gate_and_guard() {
  seed_trio
  # Tier 1 marker so the DoD is unambiguously the active one.
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # Seed review stamps so bash-guard doesn't block on unrelated gates.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  # IMPORTANT: NO inbox file for the DoD slug → DoD is "pending/active" →
  # pre-edit-dod-gate considers it the active DoD. If we seed an inbox
  # match, the DoD is marked "complete" and the gate can't match.

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "0" ] || fail "happy path pre-edit-dod-gate exit=$GATE_RC stderr=$GATE_STDERR"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    && fail "happy path should not create .dod-coverage-mismatch"

  # bash-guard with heredoc message — use simpler format to avoid JSON escape.
  run_bash_guard 'git commit -m "feat: integration test"'
  [ "$GUARD_RC" = "0" ] || fail "happy path bash-guard exit=$GUARD_RC stderr=$GUARD_STDERR"
}

# ------------------------------------------------------------
# Scenario 2 — Tier 1 marker + unknown ID → gate blocks + marker set,
# then pre-bash-test-commit-gate blocks commit due to the marker.
# ------------------------------------------------------------
test_tier1_unknown_id_blocks_edit_and_commit() {
  seed_trio_with_bad_dod
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # Seed review stamps so the marker gate is the only blocker.
  touch "$SANDBOX/trail/dod/.codex-reviewed"
  touch "$SANDBOX/trail/dod/.security-reviewed"
  # NO inbox file → DoD is active/pending → gate evaluates it.

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "2" ] || fail "tier1 unknown ID should block (exit=$GATE_RC, stderr=$GATE_STDERR)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    || fail "tier1 unknown ID should create .dod-coverage-mismatch"

  # Now pre-bash-test-commit-gate must refuse commit while the marker exists.
  # The DoD carries an unknown covers ID → coverage validator FAIL → P2 deny,
  # emitted as a JSON deny (exit 0 + stdout permissionDecision:deny) per the
  # json-deny migration — NOT exit 2. Mirrors test-pre-bash-test-commit-gate.sh
  # assert_json_deny("COVERAGE_MISMATCH").
  run_bash_guard 'git commit -m "feat: integration test"'
  [ "$GUARD_RC" = "0" ] || fail "bash-guard JSON-deny path should exit 0 (exit=$GUARD_RC, stderr=$GUARD_STDERR)"
  echo "$GUARD_STDOUT" | grep -qF '"permissionDecision": "deny"' \
    || fail "bash-guard should JSON-deny with marker (stdout=$GUARD_STDOUT)"
  echo "$GUARD_STDOUT" | grep -qF "COVERAGE_MISMATCH" \
    || fail "bash-guard JSON deny missing COVERAGE_MISMATCH reason-code"
}

# ------------------------------------------------------------
# Scenario 3 — Governance config corruption → fail-closed block.
# ------------------------------------------------------------
test_governance_corruption_fails_closed() {
  seed_trio
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # Corrupt governance.json — fail-closed runs before DoD detection.
  echo 'corrupted' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "2" ] || fail "corrupt governance.json should block (exit=$GATE_RC)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    || fail "corrupt governance → missing .dod-coverage-mismatch"
  [ -f "$SANDBOX/trail/incidents/governance-config-invalid.log" ] \
    || fail "corrupt governance → missing governance-config-invalid.log"
}

# ------------------------------------------------------------
# Scenario 4 — codex-review wrapper emits diff_base in stamp.
# ------------------------------------------------------------
test_wrapper_writes_diff_base_stamp() {
  seed_trio
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  # Ensure no stamp / pending so wrapper starts clean.
  rm -f "$SANDBOX/trail/dod/.codex-reviewed" "$SANDBOX/trail/dod/.review-pending"

  local capture stdin_file
  capture="$SANDBOX/.cap-e2e.txt"
  stdin_file="$SANDBOX/.stdin.txt"
  printf 'integration test prompt' > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture"
    # Default FAKE_CODEX_VERDICT = PASS.
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > /dev/null 2>&1
  )
  local rc=$?
  [ "$rc" = "0" ] || fail "wrapper e2e exit=$rc"
  [ -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "wrapper should create .codex-reviewed in code-review PASS"
  grep -q '^diff_base:' "$SANDBOX/trail/dod/.codex-reviewed" \
    || fail ".codex-reviewed missing diff_base: line"
  grep -qF "Required review sections" "$capture" \
    || fail "captured envelope missing 'Required review sections'"
}

# ------------------------------------------------------------
# Scenario 5 — govcheck smoke: happy path exit 0, fake broken ref exit 2.
#
# We use a hermetic sandbox where all referenced scripts exist (copied
# from the real repo) + minimal governance docs. Happy path = govcheck
# passes. Then we inject a dangling reference to prove it catches the
# break.
# ------------------------------------------------------------
test_govcheck_happy_and_broken_ref() {
  # Copy every rein-* script the hooks reference so govcheck's ref graph
  # resolves. We simply mirror the entire scripts dir from the real repo —
  # it's light and guarantees the happy path.
  mkdir -p "$SANDBOX/scripts"
  cp "$REAL_PROJECT_DIR/scripts/"rein-*.{sh,py} "$SANDBOX/scripts/" 2>/dev/null || true

  # Happy path: govcheck exits 0 on a well-formed sandbox.
  ( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" \
      > /tmp/gc-stdout.$$ 2> /tmp/gc-stderr.$$ )
  local gc_rc=$?
  local gc_err
  gc_err=$(cat /tmp/gc-stderr.$$)
  rm -f /tmp/gc-stdout.$$ /tmp/gc-stderr.$$
  [ "$gc_rc" = "0" ] || fail "govcheck happy path exit=$gc_rc (stderr: $gc_err)"

  # Broken ref: inject a dangling reference into AGENTS.md → exit 2.
  printf 'see scripts/rein-nonexistent-zzzz.sh for details\n' >> "$SANDBOX/AGENTS.md"
  ( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" \
      > /tmp/gc-stdout.$$ 2> /tmp/gc-stderr.$$ )
  local gc_rc2=$?
  rm -f /tmp/gc-stdout.$$ /tmp/gc-stderr.$$
  [ "$gc_rc2" = "2" ] || fail "govcheck broken ref expected exit 2, got $gc_rc2"
}

summary() {
  local pass=$((TEST_COUNT - FAIL_COUNT))
  echo ""
  echo "================================"
  echo "Tests run: $TEST_COUNT"
  echo "Passed:    $pass"
  echo "Failed:    $FAIL_COUNT"
  echo "================================"
  [ "$FAIL_COUNT" -eq 0 ]
}

main() {
  run_test test_happy_path_passes_gate_and_guard
  run_test test_tier1_unknown_id_blocks_edit_and_commit
  run_test test_governance_corruption_fails_closed
  run_test test_wrapper_writes_diff_base_stamp
  run_test test_govcheck_happy_and_broken_ref
  summary
}

main "$@"
