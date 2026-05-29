#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate-spec-tests-exempt.sh
# DOD-GATE-FP-TESTS — spec review gate must not block edits to tests/.
#
# Bug class: the spec review gate (pre-edit-dod-gate.sh) sets
# UNRESOLVED_SPECS=true whenever ANY .pending marker lacks a fresh .reviewed,
# then exit 2 without ever consulting FILE_PATH. While a spec waits for
# review, editing a test file (tests/**) is blocked too — breaking the
# reproduction-first / TDD red-green flow.
#   - 2026-05-28 incident 351623296a9bc1d8 (5x): blocked
#     tests/scripts/test-rein-publish-dual-channel.sh,
#     tests/scripts/test-rein-publish-tarball.sh,
#     tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh.
#
# Fix: the spec gate skips the block when FILE_PATH resolves under
# PROJECT_DIR/tests/. Non-tests source edits keep the existing exit 2.
#
# DoD: trail/dod/dod-2026-05-29-dod-gate-tests-fp-fix.md
#
# Test harness: tests/hooks/lib/test-harness.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

# Compute the deterministic 16-char shasum hash the gate uses to key markers.
_compute_hash() {
  local input="$1"
  printf '%s' "$input" | shasum 2>/dev/null | cut -c1-16
}

# Seed an unreviewed spec: a .pending marker with NO matching .reviewed.
# This drives UNRESOLVED_SPECS=true in the spec gate.
_seed_unreviewed_spec() {
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec (not yet reviewed)" > "$spec_file"
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_compute_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "created=2026-05-29T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  # Intentionally NO .reviewed sibling → unreviewed.
}

# F1 (RED→GREEN proof): unreviewed spec present + edit target is a tests/ file
#   → spec gate must SKIP its block and allow the edit (exit 0).
#   Pre-fix: exit 2 (global block). Post-fix: exit 0.
test_tests_path_allowed_with_unreviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  _seed_unreviewed_spec

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/tests/hooks/test-foo.sh"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "tests/ edit must be allowed even when an unreviewed spec exists (reproduction-first / TDD)"
}

# F1b: tests/scripts/ subtree (the actual incident-blocked path family).
test_tests_scripts_path_allowed_with_unreviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  _seed_unreviewed_spec

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/tests/scripts/test-rein-publish-tarball.sh"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "tests/scripts/ edit must be allowed even when an unreviewed spec exists"
}

# F2 (no regression / bypass guard): unreviewed spec present + edit target is
#   a NON-tests source file → spec gate must STILL block (exit 2). This proves
#   the exemption only frees tests/, not real source.
test_non_tests_source_still_blocked_with_unreviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  _seed_unreviewed_spec

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/scripts/rein-publish.sh"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "non-tests source edit must remain blocked by the unreviewed spec (no gate bypass)"
}

# F2b: a src/ file is also still blocked (second non-tests sample).
test_src_file_still_blocked_with_unreviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  _seed_unreviewed_spec

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "src/ edit must remain blocked by the unreviewed spec (no gate bypass)"
}

# F3 (no false-positive on substring): a file whose name merely contains
#   'tests' but is NOT under PROJECT_DIR/tests/ must NOT be exempted — it is
#   real source and must stay blocked.
test_tests_substring_not_under_tests_dir_still_blocked() {
  seed_dod "dod-2026-04-13-test.md"
  _seed_unreviewed_spec

  # Under src/, file named tests-helper.ts — must NOT match the tests/ exemption.
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/tests-helper.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "a 'tests' substring outside PROJECT_DIR/tests/ must stay blocked (no over-broad exemption)"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_tests_path_allowed_with_unreviewed_spec pre-edit-dod-gate.sh
run_test test_tests_scripts_path_allowed_with_unreviewed_spec pre-edit-dod-gate.sh
run_test test_non_tests_source_still_blocked_with_unreviewed_spec pre-edit-dod-gate.sh
run_test test_src_file_still_blocked_with_unreviewed_spec pre-edit-dod-gate.sh
run_test test_tests_substring_not_under_tests_dir_still_blocked pre-edit-dod-gate.sh

summary
