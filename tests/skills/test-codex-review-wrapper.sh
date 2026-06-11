#!/bin/bash
# tests/skills/test-codex-review-wrapper.sh
#
# Golden test for scripts/rein-codex-review.sh (Plan A Phase 6).
#
# Scope IDs:
#   - GI-codex-review-context-assembly
#   - GI-codex-review-envelope-slots
#   - GI-codex-review-diff-base
#   - GI-codex-review-envelope-context-missing
#   - GI-codex-review-wrapper-script
#
# Verifications (plan Task 6.4):
#   1. Fake codex sees envelope with all 4 slots.
#   2. Missing context → envelope carries "High process gap" header.
#   3. Tier 1 vs Tier 2 selector produces different active DoD in assembly.
#   4. Code-review mode + PASS → .codex-reviewed stamp has `diff_base:` line.
#   5. Spec-review mode + PASS → .codex-reviewed NOT created (mtime unchanged,
#      .review-pending also unchanged).
#   6. Spec-review mode + NEEDS-FIX → no stamp (same as code-review).
#
# Each test runs inside a sandbox (mktemp -d) with:
#   - .claude/hooks/lib/ (full copy, wrapper sources select-active-dod.sh)
#   - scripts/rein-codex-review.sh  (copy of wrapper under test)
#   - docs/specs/ + docs/plans/ + trail/dod/ fixtures
#   - a minimal git repo (git init) so diff_base resolution works
#   - CODEX_BIN pointing at tests/fixtures/fake-codex.sh
#
# The wrapper is invoked directly (not via claude) with
# `--non-interactive` + the prompt-marker scheme.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
CURRENT_FAILS=0
SANDBOX=""

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

# ------------------------------------------------------------
# Sandbox helpers
# ------------------------------------------------------------

sandbox_setup() {
  SANDBOX=$(mktemp -d "/tmp/codex-review-wrapper-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/incidents"
  mkdir -p "$SANDBOX/docs/specs"
  mkdir -p "$SANDBOX/docs/plans"

  # Copy the wrapper + its deps. The select-active-dod library lives in the
  # plugin SSOT (plugins/rein-core/hooks/lib/) after Option C Phase 3 removed
  # the dev `.claude/hooks/` overlay; fall back to the overlay for legacy
  # maintainer environments that still carry it.
  local _sad_src=""
  if [ -f "$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
    _sad_src="$REAL_PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
  elif [ -f "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" ]; then
    _sad_src="$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
  else
    echo "sandbox_setup: select-active-dod.sh not found in .claude/ or plugin SSOT" >&2
    return 1
  fi
  cp "$_sad_src" "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  # GE-1: select-active-dod.sh sources its sibling path-containment.sh; copy it
  # too or the Tier 1 containment check fail-closes (rejects valid markers).
  cp "$(dirname "$_sad_src")/path-containment.sh" \
     "$SANDBOX/.claude/hooks/lib/path-containment.sh" 2>/dev/null || true
  cp "$REAL_PROJECT_DIR/scripts/rein-codex-review.sh" \
     "$SANDBOX/scripts/rein-codex-review.sh"
  chmod +x "$SANDBOX/scripts/rein-codex-review.sh"

  # Minimal git repo so `git log` / `git rev-parse` don't blow up.
  ( cd "$SANDBOX" && git init -q && git config user.email test@example.com \
    && git config user.name test && git commit --allow-empty -q -m "init" )
}

sandbox_teardown() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  SANDBOX=""
}

# seed_design <rel-path> "<id1> <id2> ..."
seed_design() {
  local path="$SANDBOX/$1"
  shift
  mkdir -p "$(dirname "$path")"
  {
    echo "# Design"
    echo ""
    echo "## Scope Items"
    echo ""
    echo "| ID | 설명 |"
    echo "|----|------|"
    for id in $@; do
      echo "| $id | desc of $id |"
    done
  } > "$path"
}

# seed_plan <rel-path> <design-ref> "<id1> <id2> ..."
seed_plan() {
  local path="$SANDBOX/$1"
  local design_ref="$2"
  shift 2
  mkdir -p "$(dirname "$path")"
  {
    echo "# Plan"
    echo ""
    echo "## Design 범위 커버리지 매트릭스"
    echo ""
    echo "> design ref: $design_ref"
    echo ""
    echo "| Scope ID | 상태 | 위치/사유 |"
    echo "|----------|------|----------|"
    for id in $@; do
      echo "| $id | implemented | Phase 1 |"
    done
    echo ""
    echo "## Phase 1"
    printf 'covers: ['
    local first=1
    for id in $@; do
      if [ "$first" = "1" ]; then
        printf '%s' "$id"
        first=0
      else
        printf ', %s' "$id"
      fi
    done
    printf ']\n'
  } > "$path"
}

# seed_dod <rel-path> <plan-ref> "<covers>"
seed_dod() {
  local path="$SANDBOX/$1"
  local plan_ref="$2"
  local covers_list="$3"
  mkdir -p "$(dirname "$path")"
  {
    echo "# DoD"
    echo ""
    echo "Some content."
    echo ""
    echo "## 범위 연결"
    echo ""
    echo "plan ref: $plan_ref"
    echo "work unit: placeholder"
    echo "covers: [$covers_list]"
  } > "$path"
}

# Run the wrapper with given stdin + optional env and capture stdout/stderr/rc.
#   RUN_WRAPPER_STDIN, RUN_WRAPPER_OUT, RUN_WRAPPER_ERR, RUN_WRAPPER_RC set on return.
run_wrapper() {
  local stdin_content="$1"
  shift
  local capture_file="$SANDBOX/.fake-codex-prompt-capture.txt"
  local stdin_file="$SANDBOX/.stdin-in.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "$stdin_content" > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    bash "$SANDBOX/scripts/rein-codex-review.sh" "$@" < "$stdin_file" \
      > "$tmp_stdout" 2> "$tmp_stderr"
  )
  RUN_WRAPPER_RC=$?
  RUN_WRAPPER_OUT=$(cat "$tmp_stdout")
  RUN_WRAPPER_ERR=$(cat "$tmp_stderr")
  RUN_WRAPPER_PROMPT_FILE="$capture_file"
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"
  return 0
}

run_test() {
  local fn="$1"
  CURRENT_TEST="$fn"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  sandbox_setup
  trap 'sandbox_teardown' RETURN
  echo "RUN $fn"
  "$fn"
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
  trap - RETURN
  sandbox_teardown
  CURRENT_TEST=""
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

# ------------------------------------------------------------
# Verification 1: fake-codex sees envelope containing all 4 slots.
# Verification 2: Tier 1 marker path appears in assembled context
#                 (not the later mtime DoD).
# ------------------------------------------------------------
test_envelope_contains_all_4_slots_and_tier1_dod() {
  # Arrange: design + plan + two DoDs (one older Tier-2 candidate,
  # one marker Tier-1 target). We set .active-dod to the Tier-1 target.
  seed_design "docs/specs/foo-design.md" "A1 A2"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1 A2"

  # Older DoD (would be Tier-2 fallback if no marker).
  seed_dod "trail/dod/dod-2026-04-20-older.md" \
           "docs/plans/foo-plan.md" "A2"

  # Tier-1 target.
  seed_dod "trail/dod/dod-2026-04-21-marker-target.md" \
           "docs/plans/foo-plan.md" "A1"

  # Ensure Tier-1 is explicitly selected (covers both mtime orderings).
  echo "path=trail/dod/dod-2026-04-21-marker-target.md" \
    > "$SANDBOX/trail/dod/.active-dod"

  # Act: run wrapper in code-review mode (no spec-review prefix).
  run_wrapper "code review please" --non-interactive

  # Assert: exit 0 (PASS), prompt captured.
  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Slot 1: Code defects
  grep -qF "Code defects and regressions" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing slot 1 'Code defects and regressions'"
  # Slot 2: Design Alignment
  grep -qF "Design Alignment" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing slot 2 'Design Alignment'"
  # Slot 3: Test Alignment
  grep -qF "Test Alignment" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing slot 3 'Test Alignment'"
  # Slot 4: Claim Audit
  grep -qF "Claim Audit" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing slot 4 'Claim Audit'"
  # Required review sections heading (Task 6.2 Step 3 literal).
  grep -qF "Required review sections" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'Required review sections' literal"

  # Tier 1 DoD path must appear (not the older file).
  grep -qF "dod-2026-04-21-marker-target.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "Tier 1 DoD path missing from envelope"
  grep -qF "dod-2026-04-20-older.md" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "older Tier-2 DoD leaked into envelope despite Tier-1 marker"

  # High process gap MUST NOT be present (all context available).
  grep -qF "High process gap" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "envelope has 'High process gap' even though all context is present"
  return 0
}

# ------------------------------------------------------------
# Verification 2 (standalone): context missing → "High process gap".
# ------------------------------------------------------------
test_envelope_high_process_gap_when_dod_missing() {
  # Arrange: no DoD at all → select_active_dod returns tier=0. Plan/design
  # refs also unresolvable. Wrapper must still run but insert the high-gap
  # header at the top of the envelope.
  # (Do NOT seed any dod-*.md.)

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # 'High process gap' header must be at (or near) the top of the prompt.
  # We allow optional leading [NON_INTERACTIVE] marker.
  head -10 "$RUN_WRAPPER_PROMPT_FILE" | grep -qF "High process gap" \
    || fail "'High process gap' not in envelope head (context missing)"

  # The header must also enumerate the missing fields.
  grep -qF "plan_ref:" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "gap header missing 'plan_ref:' marker"
  grep -qF "design_ref:" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "gap header missing 'design_ref:' marker"
  grep -qF "covers:" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "gap header missing 'covers:' marker"
  return 0
}

# ------------------------------------------------------------
# Verification 3: Tier 2 fallback (no .active-dod marker) chooses the
# latest-mtime DoD with `## 범위 연결`.
# ------------------------------------------------------------
test_tier2_fallback_chooses_latest_mtime() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-20-older.md" "docs/plans/foo-plan.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-newer.md" "docs/plans/foo-plan.md" "A1"
  # No .active-dod marker → Tier 2 selects newer-mtime.

  # Bump mtime on newer to guarantee ordering deterministically.
  sleep 1
  touch "$SANDBOX/trail/dod/dod-2026-04-21-newer.md"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  grep -qF "dod-2026-04-21-newer.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "Tier 2 latest-mtime DoD missing from envelope"
  return 0
}

# ------------------------------------------------------------
# Verification 4: code-review + PASS → stamp has diff_base: line.
# ------------------------------------------------------------
test_code_review_pass_stamp_has_diff_base() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-cr.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-cr.md" > "$SANDBOX/trail/dod/.active-dod"

  # Default fake verdict = "PASS".
  run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail ".codex-reviewed not created in code-review mode"
  grep -q '^diff_base:' "$SANDBOX/trail/dod/.codex-reviewed" \
    || fail ".codex-reviewed missing 'diff_base:' line"
  grep -q '^verdict:' "$SANDBOX/trail/dod/.codex-reviewed" \
    || fail ".codex-reviewed missing 'verdict:' line"
  return 0
}

# ------------------------------------------------------------
# Verification 5: spec-review mode + PASS → .codex-reviewed NOT created,
# .review-pending unchanged (CRITICAL invariant).
# ------------------------------------------------------------
test_spec_review_pass_no_stamp_created_and_pending_unchanged() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-sr.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-sr.md" > "$SANDBOX/trail/dod/.active-dod"

  # Pre-create a .review-pending marker to verify wrapper doesn't touch it.
  echo "preexisting" > "$SANDBOX/trail/dod/.review-pending"
  local pending_mtime_before
  pending_mtime_before=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' \
    "$SANDBOX/trail/dod/.review-pending")
  local pending_content_before
  pending_content_before=$(cat "$SANDBOX/trail/dod/.review-pending")

  # Remember .codex-reviewed state (should not exist before).
  [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "precondition: .codex-reviewed already exists"

  # Spec-review marker in prompt → wrapper MUST detect and skip stamp.
  run_wrapper "[NON_INTERACTIVE] spec review for plan: docs/plans/foo-plan.md" \
              --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"

  # CRITICAL: .codex-reviewed must NOT exist.
  [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "CRITICAL: .codex-reviewed was created in spec-review mode (must not happen)"

  # .review-pending must be unchanged (mtime + content identical).
  [ -f "$SANDBOX/trail/dod/.review-pending" ] \
    || fail ".review-pending was removed by wrapper (must stay)"
  local pending_mtime_after
  pending_mtime_after=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime)' \
    "$SANDBOX/trail/dod/.review-pending")
  [ "$pending_mtime_before" = "$pending_mtime_after" ] \
    || fail ".review-pending mtime changed (before=$pending_mtime_before after=$pending_mtime_after)"
  local pending_content_after
  pending_content_after=$(cat "$SANDBOX/trail/dod/.review-pending")
  [ "$pending_content_before" = "$pending_content_after" ] \
    || fail ".review-pending content changed"

  # Envelope MUST contain the [NON_INTERACTIVE] marker preserved.
  grep -qF "[NON_INTERACTIVE]" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "spec-review envelope missing [NON_INTERACTIVE] marker"

  return 0
}

# ------------------------------------------------------------
# Verification 6: spec-review mode + NEEDS-FIX → no stamp (same outcome
# as code-review NEEDS-FIX, but explicitly tested for mode parity).
# ------------------------------------------------------------
test_spec_review_needs_fix_no_stamp() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-sr2.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-sr2.md" > "$SANDBOX/trail/dod/.active-dod"

  [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "precondition: .codex-reviewed already exists"

  # Force fake codex to emit NEEDS-FIX verdict.
  local tmp_stdout tmp_stderr capture_file stdin_file
  capture_file="$SANDBOX/.fake-codex-prompt-capture.txt"
  stdin_file="$SANDBOX/.stdin-in.txt"
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "[NON_INTERACTIVE] spec review for plan: docs/plans/foo-plan.md" > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    export FAKE_CODEX_VERDICT="NEEDS-FIX
Something needs revision."
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  local rc=$?
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  # NEEDS-FIX in any mode → no stamp.
  [ ! -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail ".codex-reviewed created in spec-review NEEDS-FIX (must not)"

  # Also no stamp when code-review NEEDS-FIX (symmetry check).
  [ ! -f "$SANDBOX/trail/dod/.review-pending" ] \
    || fail "(informational) .review-pending exists — not seeded in this test"

  # Exit code: wrapper should NOT hide NEEDS-FIX from the caller. We only
  # require that the wrapper does not claim success (non-zero or caller
  # parses stdout). Accept either non-zero OR zero with NEEDS-FIX on stdout;
  # primary gate is the stamp assertion above.
  return 0
}

# ------------------------------------------------------------
# Verification 7 (H1, 2026-04-22 retro-review-sweep):
# plan-relative `> design ref: ../specs/foo-design.md` must resolve
# against the plan's parent directory. Previously the wrapper treated
# the string as CWD-relative and silently produced scope_items=(none)
# while the gap header lied ("design_ref: present").
# ------------------------------------------------------------
test_h1_design_ref_plan_relative_resolves() {
  seed_design "docs/specs/foo-design.md" "A1"
  # Plan uses plan-relative path (../specs/...) — same as shipped governance-integrity plan.
  seed_plan "docs/plans/foo-plan.md" "../specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-22-h1.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-22-h1.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Envelope must contain the actual design filename (path resolved), not raw `../specs/...`.
  grep -qF "foo-design.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing resolved design filename (got raw ref instead?)"

  # Scope items extracted from the design must appear in the envelope.
  grep -qF "A1" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing scope items from resolved design"

  # Gap header MUST NOT be present — design was resolvable.
  head -10 "$RUN_WRAPPER_PROMPT_FILE" | grep -qF "High process gap" \
    && fail "false High process gap on resolvable plan-relative design_ref"
  return 0
}

# ------------------------------------------------------------
# Verification 8 (H1): unresolvable design_ref must be reported as
# MISSING in the gap header (not silently marked "present").
# ------------------------------------------------------------
test_h1_unresolvable_design_ref_flagged_missing() {
  seed_design "docs/specs/foo-design.md" "A1"
  # Plan refers to a design that does not exist.
  seed_plan "docs/plans/foo-plan.md" "../specs/DOES-NOT-EXIST.md" "A1"
  seed_dod "trail/dod/dod-2026-04-22-h1b.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-22-h1b.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Gap header must be present because design_ref is unresolvable.
  head -15 "$RUN_WRAPPER_PROMPT_FILE" | grep -qF "High process gap" \
    || fail "gap header absent even though design_ref is unresolvable"

  # Gap header must explicitly say MISSING with raw ref for diagnosis.
  grep -qE "design_ref: MISSING" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "gap header missing 'design_ref: MISSING' flag"
  grep -qF "DOES-NOT-EXIST.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "gap header missing raw unresolved ref for diagnosis"
  return 0
}

# ------------------------------------------------------------
# Verification 9 (H2, 2026-04-22): DoD with multiple plan_ref lines
# must be flagged in the envelope gap header AND emit a stderr warning.
# Wrapper proceeds with the first plan_ref (single-plan contract;
# integration DoD is Phase 2).
# ------------------------------------------------------------
test_h2_multiple_plan_refs_flagged_in_envelope() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/bar-plan.md" "docs/specs/foo-design.md" "A1"

  # Hand-craft DoD with 2 plan_ref lines (annotation suffixes).
  cat > "$SANDBOX/trail/dod/dod-2026-04-22-h2.md" <<'EOF'
# DoD

## 범위 연결

plan ref: docs/plans/foo-plan.md (Team A)
plan ref: docs/plans/bar-plan.md (Team B)
work unit: placeholder
covers: [A1]
EOF
  echo "path=trail/dod/dod-2026-04-22-h2.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Stderr warning about multiple plan refs.
  echo "$RUN_WRAPPER_ERR" | grep -qF "declares 2 plan refs" \
    || fail "stderr missing multi-plan warning (got: $RUN_WRAPPER_ERR)"

  # Envelope gap header flags MULTIPLE_FAIL_CLOSED state.
  grep -qF "MULTIPLE_FAIL_CLOSED" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope gap header missing MULTIPLE_FAIL_CLOSED flag"

  # Wrapper still uses the first plan_ref (annotation stripped).
  grep -qF "docs/plans/foo-plan.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing first plan path after annotation strip"
  # `(Team A)` annotation must not leak into envelope plan_ref line.
  grep -qE "plan_ref:.*\(Team A\)" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "annotation suffix leaked into plan_ref line"
  return 0
}

# ------------------------------------------------------------
# Claim-audit-hardening verifications (Plan 2026-04-24, Task 4.2).
# Seven tests covering Phase 1 behavior:
#   10. diff_base_iso + head_iso fields present in Context block
#   11. claim_source_iso_hints block emitted when file refs present
#   12. claim_source_iso_hints block omitted when no file refs
#   13. malicious paths skipped (../, $(…), ;, backtick)
#   14. 20-item cap honored
#   15. tracked-but-no-history path → (unavailable)
#   16. nonexistent path → skipped
# ------------------------------------------------------------

test_envelope_context_block_has_diff_base_iso_and_head_iso() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-iso.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-iso.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  grep -qE "^diff_base_iso: " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'diff_base_iso:' field"
  grep -qE "^head_iso: " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'head_iso:' field"
  return 0
}

test_claim_source_iso_hints_emitted_when_file_ref_present() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-emit.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-emit.md" > "$SANDBOX/trail/dod/.active-dod"

  # Override via REIN_PR_BODY to include a real file path that was seeded.
  REIN_PR_BODY="Related to docs/specs/foo-design.md" run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  grep -qE "^claim_source_iso_hints:" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'claim_source_iso_hints:' block header"
  grep -qE "^  docs/specs/foo-design\.md: " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "hints block missing seeded file entry"
  return 0
}

test_claim_source_iso_hints_omitted_when_no_file_ref() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-empty.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-empty.md" > "$SANDBOX/trail/dod/.active-dod"

  REIN_PR_BODY="Pure prose with no file references." run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  grep -qE "^claim_source_iso_hints:" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "hints block emitted when no file refs should match"
  return 0
}

test_claim_source_iso_hints_skips_malicious_paths() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-sec.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-sec.md" > "$SANDBOX/trail/dod/.active-dod"

  # Mix malicious + one legitimate path.
  REIN_PR_BODY="ignore ../../../etc/passwd.md and \$(evil.md) and ;bad.md and \`rce.md\` but docs/specs/foo-design.md is safe" \
    run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  # Extract only the claim_source_iso_hints block — the raw claim_sources
  # verbatim section above will contain the malicious strings, which is fine.
  # We only care that they don't appear as keys in the hints block.
  local hints_block
  hints_block=$(awk '/^claim_source_iso_hints:/,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")
  # Legitimate one should be present.
  printf '%s' "$hints_block" | grep -qE "^  docs/specs/foo-design\.md: " \
    || fail "safe path dropped by filter"
  # Traversal/metachar variants must not appear as hint keys.
  printf '%s' "$hints_block" | grep -qE "^  \.\./" \
    && fail "../ traversal path leaked into hints"
  printf '%s' "$hints_block" | grep -qE "^  .*evil\.md:" \
    && fail '$(…) metachar path leaked into hints'
  printf '%s' "$hints_block" | grep -qE "^  .*bad\.md:" \
    && fail "; metachar path leaked into hints"
  printf '%s' "$hints_block" | grep -qE "^  .*rce\.md:" \
    && fail "backtick metachar path leaked into hints"
  return 0
}

test_claim_source_iso_hints_limit_20_entries() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-cap.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-cap.md" > "$SANDBOX/trail/dod/.active-dod"

  # Create 25 files.
  local i body=""
  mkdir -p "$SANDBOX/docs/many"
  for i in $(seq 1 25); do
    : > "$SANDBOX/docs/many/file${i}.md"
    body="$body docs/many/file${i}.md"
  done

  REIN_PR_BODY="$body" run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  local hint_count
  hint_count=$(grep -cE "^  docs/many/file" "$RUN_WRAPPER_PROMPT_FILE" || true)
  [ "$hint_count" = "20" ] \
    || fail "expected exactly 20 hint entries, got $hint_count"
  return 0
}

test_claim_source_iso_hints_emits_unavailable_for_untracked_file() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-unavail.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-unavail.md" > "$SANDBOX/trail/dod/.active-dod"

  # Create a file but never git-add it. Sandbox setup committed only --allow-empty.
  : > "$SANDBOX/docs/untracked.md"

  REIN_PR_BODY="See docs/untracked.md for context" run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  # Expect: line `  docs/untracked.md: (unavailable)`
  grep -qE "^  docs/untracked\.md: \(unavailable\)$" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "untracked file did not emit '(unavailable)' hint"
  return 0
}

test_envelope_retains_exactly_four_slot_headings_after_hardening() {
  # Phase 3 Task 3.1 (claim-audit-hardening): envelope MUST keep exactly
  # four top-level slot headings. The new sub-items 5/6 belong inside
  # slot 4 (Claim Audit) and must not escape to column 0.
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-slots.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-slots.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive
  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"

  # Four exact slot headings at column 0.
  grep -qE "^1\. Code defects and regressions$" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "slot 1 heading missing"
  grep -qE "^2\. Design Alignment " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "slot 2 heading missing"
  grep -qE "^3\. Test Alignment " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "slot 3 heading missing"
  grep -qE "^4\. Claim Audit " "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "slot 4 heading missing"

  # 'Required review sections' header appears exactly once.
  local rrs_count
  rrs_count=$(grep -cF "Required review sections" "$RUN_WRAPPER_PROMPT_FILE" || true)
  [ "$rrs_count" = "1" ] \
    || fail "'Required review sections' must appear exactly once (got $rrs_count)"

  # NO fifth top-level heading at column 0.
  grep -qE "^5\. [A-Z]" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "5th top-level heading leaked (sub-items must stay inside slot 4)"

  # Sub-items 5 and 6 exist AFTER slot 4 header (indented, inside heredoc).
  local slot_block
  slot_block=$(awk '/^4\. Claim Audit /,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")
  printf '%s' "$slot_block" | grep -qF "Evidence freshness" \
    || fail "sub-item 5 'Evidence freshness' not in slot 4 body"
  printf '%s' "$slot_block" | grep -qF "Claim discrepancy escalation" \
    || fail "sub-item 6 'Claim discrepancy escalation' not in slot 4 body"
  return 0
}

test_claim_source_iso_hints_skips_nonexistent_file() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-24-miss.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-24-miss.md" > "$SANDBOX/trail/dod/.active-dod"

  # Reference a .md path that does not exist in sandbox.
  REIN_PR_BODY="See docs/DOES-NOT-EXIST.md for context" run_wrapper "code review" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  # claim_sources block will echo the raw REIN_PR_BODY (including the
  # nonexistent ref). We only enforce that the hints block has no key
  # for it. Also the hints block may simply be absent entirely.
  local hints_block
  hints_block=$(awk '/^claim_source_iso_hints:/,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")
  printf '%s' "$hints_block" | grep -qE "^  docs/DOES-NOT-EXIST\.md:" \
    && fail "nonexistent file leaked into hints (should be skipped by [ -f ] check)"
  return 0
}

# ------------------------------------------------------------
# P2 verdict parser hardening (need-to-confirm.md 그룹 6 P2, 2026-04-25).
# 두 세션 연속 false-verdict 재현 (2026-04-24 claim-audit-hardening +
# 2026-04-25 spec-flow-policy-hardening) 의 회귀 방지.
# ------------------------------------------------------------

# Helper: sandbox 시드 + FAKE_CODEX_VERDICT 커스텀 후 wrapper 실행.
# RUN_WRAPPER_RC, RUN_WRAPPER_OUT, RUN_WRAPPER_PROMPT_FILE 설정.
_run_wrapper_with_verdict() {
  local verdict="$1"
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-25-pv.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-25-pv.md" > "$SANDBOX/trail/dod/.active-dod"
  local capture_file="$SANDBOX/.fake-codex-prompt-capture.txt"
  local stdin_file="$SANDBOX/.stdin-in.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "code review please" > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    export FAKE_CODEX_VERDICT="$verdict"
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  RUN_WRAPPER_RC=$?
  RUN_WRAPPER_OUT=$(cat "$tmp_stdout")
  RUN_WRAPPER_PROMPT_FILE="$capture_file"
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"
  return 0
}

test_envelope_contains_final_verdict_instruction() {
  # Envelope 가 codex 에게 'FINAL_VERDICT: <PASS|NEEDS-FIX|REJECT>' 출력
  # 형식을 명시 지시해야 한다 (chain Stage 1 의 source).
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-25-fv-instr.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-25-fv-instr.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC"
  grep -qF "FINAL_VERDICT: <PASS|NEEDS-FIX|REJECT>" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'FINAL_VERDICT: <PASS|NEEDS-FIX|REJECT>' instruction"
  return 0
}

test_parse_verdict_recognizes_final_verdict_line_in_body() {
  # codex 가 본문 분석 후 마지막에 'FINAL_VERDICT: PASS' 라인을 출력 →
  # parser 가 chain Stage 1 으로 PASS 판정 → wrapper exit 0.
  _run_wrapper_with_verdict "Detailed review notes here.

The change looks safe; design alignment MATCH for A1.

FINAL_VERDICT: PASS"

  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "FINAL_VERDICT: PASS 라인이 PASS 로 판정되지 않음 (rc=$RUN_WRAPPER_RC)"
  return 0
}

test_parse_verdict_falls_back_to_first_line_keyword_when_no_final_verdict() {
  # FINAL_VERDICT 라인 부재 + 첫 줄이 'PASS' → chain Stage 2 fallback PASS.
  # transition 기간 backward-compat 보장 (envelope 지시 도달 전 응답 패턴).
  _run_wrapper_with_verdict "PASS
All checks clean and design alignment confirmed."

  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "Stage 2 first-line keyword fallback 실패 (rc=$RUN_WRAPPER_RC)"
  return 0
}

test_parse_verdict_final_verdict_line_overrides_first_line_keyword() {
  # 첫 줄에 'NEEDS-FIX' (preliminary signal) + 마지막에 'FINAL_VERDICT: PASS'
  # → chain Stage 1 우선 매칭으로 PASS (Stage 2 의 NEEDS-FIX 무시).
  _run_wrapper_with_verdict "NEEDS-FIX preliminary scan note
But after careful analysis the change is fully safe.
FINAL_VERDICT: PASS"

  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "Stage 1 FINAL_VERDICT 가 Stage 2 의 첫 줄 NEEDS-FIX 를 무시 안 함 (rc=$RUN_WRAPPER_RC)"
  return 0
}

test_parse_verdict_multiple_final_verdict_lines_last_match_wins() {
  # B3 (2026-06-09): codex 응답에 FINAL_VERDICT 라인이 둘 이상이면 parser 는
  # 마지막(tail) 매치를 채택한다 (Stage 1 의 `grep ... | tail -1` 계약).
  # 근거: envelope 규칙이 codex 에게 "응답 끝에 FINAL_VERDICT" 를 지시하므로
  # 진짜 결론은 응답 끝 라인이다. 본문 앞쪽 FINAL_VERDICT 는 인용/예시 노이즈.
  # 순서: 'FINAL_VERDICT: PASS' 가 먼저, 'FINAL_VERDICT: REJECT' 가 나중(끝).
  # 기대: 마지막 매치 REJECT 채택 → wrapper exit 2 (보수적).
  # 회귀 방지 — tail-match 계약이 깨져 first-match 로 회귀하면 앞쪽 PASS 가
  # 채택돼 exit 0 이 되어 본 테스트가 즉시 실패한다.
  _run_wrapper_with_verdict "Detailed analysis follows.
FINAL_VERDICT: PASS
Addendum reviewer note below.
FINAL_VERDICT: REJECT"

  [ "$RUN_WRAPPER_RC" = "2" ] \
    || fail "복수 FINAL_VERDICT 라인에서 마지막 매치 REJECT 가 채택되지 않음 (rc=$RUN_WRAPPER_RC, 앞쪽 PASS 가 우선됐을 수 있음)"
  return 0
}

test_parse_verdict_body_quoted_verdict_does_not_override_final() {
  # B3 (2026-06-09): codex 가 리뷰 본문 앞쪽에서 테스트 stub/예시의
  # FINAL_VERDICT 를 들여써 인용하면, 그 인용을 결론으로 오인하면 안 된다.
  # 진짜 결론은 envelope 규칙대로 응답 끝의 FINAL_VERDICT 라인이다.
  # body 앞쪽: 들여쓴 인용 '  FINAL_VERDICT: PASS' (예시 코드 인용).
  # 끝: 실제 결론 'FINAL_VERDICT: NEEDS-FIX'.
  # 기대: tail-match 로 NEEDS-FIX 채택 → wrapper exit 1.
  # 현재(first-match) 버그: 들여쓴 인용 PASS 가 첫 매치로 채택 → exit 0.
  _run_wrapper_with_verdict "Reviewing the test fixture which contains:
  FINAL_VERDICT: PASS
That quoted line is the fixture's expected stub, not my verdict.
The actual change has an unhandled edge case.
FINAL_VERDICT: NEEDS-FIX"

  [ "$RUN_WRAPPER_RC" = "1" ] \
    || fail "본문 앞쪽 인용 FINAL_VERDICT: PASS 가 끝의 실제 NEEDS-FIX 를 덮음 (rc=$RUN_WRAPPER_RC, 기대=1)"
  return 0
}

test_codex_nonzero_exit_propagates() {
  # B2 (2026-06-09): codex 가 비모델(일반) 실패로 exit≠0 이면 wrapper 는
  # 동일한 non-zero exit code 를 전파해야 한다. 현재 버그(`if ! CMD; then
  # RC=$?`)는 `$?` 가 `! CMD`(항상 0)를 캡처해 exit 0 으로 성공 위장한다.
  # fake codex: 비모델 실패 (FAKE_CODEX_EXIT=37) + 모델거부 패턴 없는 일반
  # 실패 문구 (invalid_request_error / model_not_found / "is not supported"
  # 미포함, FINAL_VERDICT 라인도 없음 → fail-soft exit 3 분기로 안 빠짐).
  # 기대: wrapper RC=37. 현재 버그=0.
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b2.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b2.md" > "$SANDBOX/trail/dod/.active-dod"

  local capture_file="$SANDBOX/.fake-codex-prompt-capture.txt"
  local stdin_file="$SANDBOX/.stdin-in.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp)
  tmp_stderr=$(mktemp)
  printf '%s' "code review please" > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    export FAKE_CODEX_EXIT=37
    export FAKE_CODEX_VERDICT="codex: stream error: connection reset by peer
retrying... gave up after 3 attempts."
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  local rc=$?
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  [ "$rc" = "37" ] \
    || fail "codex 비모델 실패(exit 37)가 전파되지 않음 (rc=$rc, 기대=37 — 현재 버그는 exit 0 으로 성공 위장)"
  return 0
}

test_parse_verdict_no_keyword_returns_needs_fix() {
  # 본문에 PASS/NEEDS-FIX/REJECT 가 첫 컬럼에도 FINAL_VERDICT 라인에도
  # 없으면 → chain Stage 3 conservative fallback NEEDS-FIX → wrapper exit 1.
  _run_wrapper_with_verdict "Just some prose without any verdict keyword.
The reviewer wrote analysis but forgot to declare a verdict."

  [ "$RUN_WRAPPER_RC" = "1" ] \
    || fail "verdict 부재 시 NEEDS-FIX (exit 1) 기대 (rc=$RUN_WRAPPER_RC)"
  return 0
}

# ------------------------------------------------------------
# Verification 7 (2026-05-12 hotfix): plugin layout self-containment.
# Wrapper bundled inside a plugin tree (scripts/ + hooks/lib/ siblings)
# must source the bundled lib instead of $PROJECT_DIR/.claude/hooks/lib,
# and must operate on the USER repo's trail/dod (not the plugin tree's).
# Regression for plugins/rein-core/scripts/rein-codex-review.sh:53.
# ------------------------------------------------------------
test_wrapper_plugin_layout_user_repo_without_claude_dir_uses_bundled_lib() {
  # Arrange: skip the scaffold sandbox_setup; build plugin layout manually.
  sandbox_teardown

  SANDBOX=$(mktemp -d "/tmp/codex-review-plugin-layout-XXXXXX")
  local plugin_root="$SANDBOX/fake-plugin"
  local user_repo="$SANDBOX/user-repo"
  mkdir -p "$plugin_root/scripts" "$plugin_root/hooks/lib"
  mkdir -p "$user_repo/trail/dod" "$user_repo/docs/specs" "$user_repo/docs/plans"

  # Plugin-bundled wrapper + lib (siblings).
  cp "$REAL_PROJECT_DIR/plugins/rein-core/scripts/rein-codex-review.sh" \
     "$plugin_root/scripts/rein-codex-review.sh"
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh" \
     "$plugin_root/hooks/lib/select-active-dod.sh"
  # GE-1: sibling path-containment.sh dependency of select-active-dod.sh.
  cp "$REAL_PROJECT_DIR/plugins/rein-core/hooks/lib/path-containment.sh" \
     "$plugin_root/hooks/lib/path-containment.sh" 2>/dev/null || true
  chmod +x "$plugin_root/scripts/rein-codex-review.sh"

  # User repo: NO .claude/ directory anywhere. Minimal git so diff_base works.
  ( cd "$user_repo" && git init -q && git config user.email t@example.com \
    && git config user.name t && git commit --allow-empty -q -m "init" )

  # Seed design + plan + DoD inside the user repo. Mark Tier 1.
  {
    echo "# Design"; echo ""; echo "## Scope Items"; echo ""
    echo "| ID | 설명 |"; echo "|----|------|"; echo "| P1 | plugin-layout regression |"
  } > "$user_repo/docs/specs/plugin-layout-design.md"
  {
    echo "# Plan"; echo ""; echo "## Design 범위 커버리지 매트릭스"; echo ""
    echo "> design ref: docs/specs/plugin-layout-design.md"; echo ""
    echo "| Scope ID | 상태 | 위치/사유 |"; echo "|----------|------|----------|"
    echo "| P1 | implemented | Phase 1 |"; echo ""
    echo "## Phase 1"; echo "covers: [P1]"
  } > "$user_repo/docs/plans/plugin-layout-plan.md"
  {
    echo "# DoD"; echo ""; echo "## 범위 연결"; echo ""
    echo "plan ref: docs/plans/plugin-layout-plan.md"
    echo "work unit: Phase 1"; echo "covers: [P1]"
  } > "$user_repo/trail/dod/dod-2026-05-12-plugin-layout.md"
  echo "path=trail/dod/dod-2026-05-12-plugin-layout.md" \
    > "$user_repo/trail/dod/.active-dod"

  # Act: invoke the plugin-bundled wrapper from the user repo (CWD = user_repo).
  # CLAUDE_PROJECT_DIR mirrors Claude Code's plugin runtime env.
  local capture_file="$user_repo/.fake-codex-prompt-capture.txt"
  local stdin_file="$user_repo/.stdin.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp); tmp_stderr=$(mktemp)
  printf 'code review please' > "$stdin_file"
  (
    cd "$user_repo"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    export CLAUDE_PROJECT_DIR="$user_repo"
    bash "$plugin_root/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  RUN_WRAPPER_RC=$?
  RUN_WRAPPER_OUT=$(cat "$tmp_stdout"); RUN_WRAPPER_ERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  # Assert: wrapper did NOT fail with "missing select-active-dod" error
  #         (which would prove it still sources from $PROJECT_DIR/.claude/).
  echo "$RUN_WRAPPER_ERR" | grep -qF "missing select-active-dod library" \
    && fail "wrapper still falls back to user-repo .claude/ instead of bundled sibling"

  # The lib resolution should succeed → exit 0 (fake-codex default PASS).
  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "wrapper exit=$RUN_WRAPPER_RC in plugin layout (stderr: $RUN_WRAPPER_ERR)"

  # Captured prompt must reference the USER repo's DoD path, not a plugin path.
  [ -f "$capture_file" ] || fail "fake-codex did not capture prompt"
  grep -qF "dod-2026-05-12-plugin-layout.md" "$capture_file" \
    || fail "envelope missing user-repo DoD path (lib resolved wrong project_dir?)"
  grep -qF "fake-plugin/trail/dod" "$capture_file" \
    && fail "envelope leaked plugin-tree trail/dod path — PROJECT_DIR resolved to plugin root"

  # User repo must NOT have scaffold paths (.claude/hooks, .claude/skills, etc.)
  # created as side effect. .claude/cache/ IS an allowed cache target — the
  # wrapper writes active-dod-choice.log there.
  [ ! -d "$user_repo/.claude/hooks" ] \
    || fail "wrapper created .claude/hooks/ in user repo (scaffold contract violation)"
  [ ! -d "$user_repo/.claude/skills" ] \
    || fail "wrapper created .claude/skills/ in user repo (scaffold contract violation)"
  return 0
}

# ------------------------------------------------------------
# BUG-WRAP-SOURCE (2026-05-29): fail-closed when the select-active-dod
# library is missing or unreadable.
#
# Root cause: `set -euo pipefail` (wrapper line 37) interacts with the
# `source` builtin's "cannot read source file" error path — the `if !`
# errexit exception that works for ordinary commands does NOT suppress
# errexit for a failed `source`, so the wrapper died (exit 1) BEFORE
# reaching the intended `echo ERROR ... ; exit 2` block. The `2>/dev/null`
# also swallowed the diagnostic. Fix: precheck `[ -r ]` + a subshell that
# verifies the lib both sources cleanly AND defines `select_active_dod`,
# avoiding the bare `source` that tripped errexit.
#
# These tests live under tests/ so they are exempt from the pre-edit spec
# gate (TDD). They are RED against the pre-fix wrapper (exit 1, no message)
# and GREEN after the fix (exit 2 + "missing or invalid ... library").
# ------------------------------------------------------------
test_wrapper_missing_lib_fails_closed_exit2() {
  # The standard sandbox resolves the lib to .claude/hooks/lib/select-active-dod.sh
  # (wrapper falls to its else branch since $SANDBOX/hooks/lib does not exist).
  # Remove it so the lib is absent at the resolved path.
  rm -f "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  run_wrapper "code review please" --non-interactive
  [ "$RUN_WRAPPER_RC" = "2" ] \
    || fail "missing lib expected exit 2, got $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  echo "$RUN_WRAPPER_ERR" | grep -qF "library" \
    || fail "missing lib: stderr should name the library, got: $RUN_WRAPPER_ERR"
  echo "$RUN_WRAPPER_ERR" | grep -qiF "ERROR" \
    || fail "missing lib: stderr should carry an ERROR diagnostic, got: $RUN_WRAPPER_ERR"
}

test_wrapper_unreadable_lib_fails_closed_exit2() {
  # Library present but not readable → the [ -r ] precheck must fail-close.
  # (Skipped when running as root, where the read bit is ignored.)
  if [ "$(id -u)" = "0" ]; then
    return 0
  fi
  chmod 000 "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  run_wrapper "code review please" --non-interactive
  local rc="$RUN_WRAPPER_RC"
  # Restore perms so sandbox teardown can remove it cleanly.
  chmod 644 "$SANDBOX/.claude/hooks/lib/select-active-dod.sh" 2>/dev/null || true
  [ "$rc" = "2" ] \
    || fail "unreadable lib expected exit 2, got $rc (stderr: $RUN_WRAPPER_ERR)"
  echo "$RUN_WRAPPER_ERR" | grep -qF "library" \
    || fail "unreadable lib: stderr should name the library, got: $RUN_WRAPPER_ERR"
}

test_wrapper_invalid_lib_missing_function_fails_closed_exit2() {
  # Library present + readable + sources cleanly, but does NOT define
  # select_active_dod → the subshell `declare -F` check must fail-close.
  printf '#!/bin/bash\n# stub without select_active_dod\n: noop\n' \
    > "$SANDBOX/.claude/hooks/lib/select-active-dod.sh"
  run_wrapper "code review please" --non-interactive
  [ "$RUN_WRAPPER_RC" = "2" ] \
    || fail "invalid lib expected exit 2, got $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  echo "$RUN_WRAPPER_ERR" | grep -qF "library" \
    || fail "invalid lib: stderr should name the library, got: $RUN_WRAPPER_ERR"
}

test_wrapper_valid_lib_still_works() {
  # Regression guard: the precheck + double-source must NOT break the normal
  # path. A valid lib (the real one copied by sandbox_setup) → wrapper runs
  # codex (fake) and exits 0 (default PASS), proving select_active_dod is
  # available in the wrapper's own shell after the subshell verification.
  seed_design "docs/specs/wrap-source-design.md" "WS1"
  seed_plan "docs/plans/wrap-source-plan.md" "docs/specs/wrap-source-design.md" "WS1"
  seed_dod "trail/dod/dod-2026-05-29-wrap-source.md" "docs/plans/wrap-source-plan.md" "WS1"
  echo "path=trail/dod/dod-2026-05-29-wrap-source.md" > "$SANDBOX/trail/dod/.active-dod"
  run_wrapper "code review please" --non-interactive
  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "valid lib expected exit 0, got $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  echo "$RUN_WRAPPER_ERR" | grep -qF "missing or invalid select-active-dod" \
    && fail "valid lib must NOT emit the missing-library error"
  # select_active_dod must have actually run (envelope carries the DoD path).
  grep -qF "dod-2026-05-29-wrap-source.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "valid lib: envelope missing active DoD path — select_active_dod not loaded in wrapper shell"
}

# ------------------------------------------------------------
# Verification 8 (PD-2, 2026-05-19): PROJECT_DIR sanity check.
# The wrapper resolves PROJECT_DIR then cd's into it + writes a stamp there.
# If PROJECT_DIR does not point at a real repo root (no trail/, or not the
# git toplevel) the wrapper must fail loudly (exit 2) BEFORE running codex,
# instead of silently reviewing the wrong tree and stamping outside the repo.
# Normal PROJECT_DIR (sandbox with trail/ + git) must keep working — that is
# covered by every other test in this file, so here we only assert the new
# failure modes plus one positive control.
# ------------------------------------------------------------
test_pd2_sanity_rejects_project_dir_without_trail() {
  # Arrange: a directory that exists but has NO trail/ subdirectory.
  local bad_dir="$SANDBOX/no-trail-here"
  mkdir -p "$bad_dir"

  local stdin_file="$SANDBOX/.stdin-pd2.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp); tmp_stderr=$(mktemp)
  printf 'code review please' > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export REIN_PROJECT_DIR_OVERRIDE="$bad_dir"
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  local rc=$?
  local err
  err=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  [ "$rc" -eq 2 ] \
    || fail "wrapper exited $rc for PROJECT_DIR without trail/ (expected exit 2)"
  echo "$err" | grep -qF "[codex-review]" \
    || fail "stderr missing '[codex-review]' diagnostic for bad PROJECT_DIR (got: $err)"
}

test_pd2_sanity_rejects_project_dir_not_git_toplevel() {
  # Arrange: a git repo, but point PROJECT_DIR at a SUBDIRECTORY of it that
  # has its own trail/. trail/ alone passes; the git-toplevel mismatch must
  # still trip the sanity check.
  local subdir="$SANDBOX/subdir"
  mkdir -p "$subdir/trail/dod"

  local stdin_file="$SANDBOX/.stdin-pd2b.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp); tmp_stderr=$(mktemp)
  printf 'code review please' > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export REIN_PROJECT_DIR_OVERRIDE="$subdir"
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$tmp_stdout" 2> "$tmp_stderr"
  )
  local rc=$?
  local err
  err=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  [ "$rc" -eq 2 ] \
    || fail "wrapper exited $rc for PROJECT_DIR != git toplevel (expected exit 2)"
  echo "$err" | grep -qF "[codex-review]" \
    || fail "stderr missing '[codex-review]' diagnostic for non-toplevel PROJECT_DIR"
}

test_pd2_sanity_accepts_valid_project_dir() {
  # Positive control: a proper repo root (trail/ + git toplevel) passes the
  # sanity check and the wrapper runs to completion (fake-codex PASS).
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-05-19-pd2.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-05-19-pd2.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] \
    || fail "valid PROJECT_DIR rejected by sanity check (rc=$RUN_WRAPPER_RC, err: $RUN_WRAPPER_ERR)"
}

# ------------------------------------------------------------
# Verification 9 (G8-3, 2026-05-23): fresh spec review must NOT adopt an
# unrelated active DoD as a Tier-2 fallback context.
#
# Reproduction of the recurring (5+) false NEEDS-FIX: on the FIRST
# /codex-review of a brand-new design/plan there is no related DoD yet, only
# an UNRELATED active DoD from some other in-flight task. The wrapper used to
# call select_active_dod() unconditionally and inject that unrelated DoD as
# `active_dod_tier: 2` / `active_dod_path: <unrelated>`, then the Design
# Alignment slot reported the unrelated Scope IDs as MISSING → false verdict.
#
# Fix (option a from need-to-confirm G8-3): in spec-review mode, disable the
# active-DoD fallback entirely. Represent it as `(N/A for fresh spec review)`,
# force diff_base = N/A, and scope changed_files to the reviewed document.
# Incident: trail/incidents/2026-04-24-wrapper-fresh-spec-review-stale-active-dod.md
# ------------------------------------------------------------
test_g8_3_fresh_spec_review_ignores_unrelated_active_dod() {
  # Arrange: a brand-new design under review, but the ONLY DoD in the repo is
  # an UNRELATED one (different task). No marker points at it; it is the
  # latest-mtime DoD so the old Tier-2 fallback would have grabbed it.
  seed_design "docs/specs/2026-05-23-fresh-design.md" "F1 F2"
  seed_dod "trail/dod/dod-2026-01-01-unrelated.md" \
           "docs/plans/unrelated-plan.md" "U1 U2"
  # Deliberately NO .active-dod marker (fresh spec review has no related DoD).

  # Act: fresh spec review of the new design document.
  run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/2026-05-23-fresh-design.md" \
              --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # CRITICAL: the unrelated DoD must NOT be adopted as the active context.
  grep -qF "dod-2026-01-01-unrelated.md" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "unrelated active DoD leaked into fresh spec-review envelope (Tier-2 fallback not disabled)"

  # active_dod_tier must be the explicit N/A sentinel, not '2'.
  grep -qF "active_dod_tier: (N/A for fresh spec review)" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "active_dod_tier not represented as '(N/A for fresh spec review)'"
  grep -qE "^active_dod_tier: 2$" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "active_dod_tier: 2 still present in fresh spec review (unrelated DoD adopted)"

  # active_dod_path must be the N/A sentinel, not the unrelated DoD path.
  grep -qF "active_dod_path: (N/A for fresh spec review)" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "active_dod_path not represented as '(N/A for fresh spec review)'"

  # diff_base must be N/A for a fresh spec review (no code diff to anchor on).
  grep -qF "diff_base: N/A" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "diff_base not forced to N/A in spec-review mode"

  # changed_files must scope to the reviewed document itself only.
  grep -qF "docs/specs/2026-05-23-fresh-design.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "reviewed document not present as the changed file in spec review"

  return 0
}

# ------------------------------------------------------------
# Verification 9b (G8-3 negative-side): the CODE-review branch must keep
# adopting the unrelated active DoD via the Tier-2 fallback. The fix must be
# scoped to spec-review only and must not regress code-review behavior.
# ------------------------------------------------------------
test_g8_3_code_review_still_uses_tier2_fallback() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  # Only one DoD, no marker → Tier-2 fallback should still pick it up.
  seed_dod "trail/dod/dod-2026-05-23-cr-fallback.md" "docs/plans/foo-plan.md" "A1"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Code-review mode must still adopt the Tier-2 DoD (no spec-review N/A).
  grep -qF "dod-2026-05-23-cr-fallback.md" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "code-review Tier-2 fallback regressed (DoD not adopted)"
  # ENV-SUBJ A4 (2026-06-11): tier 2 is still adopted but the display now
  # carries the advisory-guess qualifier (confidence propagation).
  grep -qE "^active_dod_tier: 2 \(advisory fallback guess" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "code-review active_dod_tier no longer reports Tier 2 (with advisory qualifier)"
  grep -qF "(N/A for fresh spec review)" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "spec-review N/A sentinel leaked into code-review envelope"
  return 0
}

# ------------------------------------------------------------
# B4 (2026-06-09): _changed_files must prefer the WORKING TREE (staged +
# unstaged) over an unrelated committed range.
#
# Reproduction of the stale-review-context bug: rein's review-before-commit
# flow stages the real subject (uncommitted) and runs /codex-review. But
# _changed_files used `git diff --name-only <DIFF_BASE>..HEAD` FIRST and only
# fell back to --cached when that committed range was empty. When an unrelated
# file was already committed (so DIFF_BASE..HEAD is non-empty), the wrapper
# reviewed that unrelated committed file and never looked at the staged
# subject — the envelope's changed_files slot listed the wrong file.
#
# Fix: union of staged (--cached) + unstaged (working tree), and degrade to
# the committed range (DIFF_BASE..HEAD) ONLY when the working tree is clean
# (PR flow, everything already committed). Comment above _changed_files is
# updated to match.
#
# RED (pre-fix): staged subject missing from the changed_files slot; the
# unrelated committed file is listed instead.
# GREEN (post-fix): staged subject present; unrelated committed file absent
# from the changed_files slot.
# ------------------------------------------------------------
test_changed_files_prefers_staged_over_committed_range() {
  # Arrange: minimal DoD context so the envelope assembles cleanly (the slot
  # under test is independent of the DoD, but a real DoD avoids the high-gap
  # path muddying the assertion).
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b4.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b4.md" > "$SANDBOX/trail/dod/.active-dod"

  # (a) Commit an UNRELATED file so DIFF_BASE..HEAD (HEAD~1..HEAD) is
  #     non-empty. No .codex-reviewed stamp exists → _resolve_diff_base
  #     resolves to HEAD~1, and `git diff HEAD~1..HEAD` lists this file.
  ( cd "$SANDBOX" \
      && echo "unrelated committed content" > unrelated-committed.txt \
      && git add unrelated-committed.txt \
      && git commit -q -m "unrelated: prior committed change" )

  # (b) Stage the REAL review subject (uncommitted, staged) — this is what
  #     rein's review-before-commit flow actually puts in front of the
  #     reviewer.
  ( cd "$SANDBOX" \
      && echo "the actual change under review" > real-staged-subject.txt \
      && git add real-staged-subject.txt )

  # Act: code-review mode (no spec-review prefix → spec-review scoping at
  # lines 321-327 is bypassed, so _changed_files governs the slot).
  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Extract the changed_files slot block from the envelope so we assert on the
  # actual review subject list, not an incidental mention elsewhere.
  local cf_block
  cf_block=$(awk '/^changed_files \(/,/^$/' "$RUN_WRAPPER_PROMPT_FILE")

  # The staged subject MUST be the reviewed file.
  printf '%s' "$cf_block" | grep -qF "real-staged-subject.txt" \
    || fail "staged review subject missing from changed_files slot (committed range wrongly preferred over staged)"

  # The unrelated committed file MUST NOT be the review subject.
  printf '%s' "$cf_block" | grep -qF "unrelated-committed.txt" \
    && fail "unrelated committed file leaked into changed_files slot (stale review context)"
  return 0
}

# ------------------------------------------------------------
# B4 negative-side: when the working tree is CLEAN (PR flow, all changes
# already committed), _changed_files MUST degrade to the committed range so
# a normal PR review still sees its diff. The fix must not regress this.
# ------------------------------------------------------------
test_changed_files_degrades_to_committed_range_when_working_tree_clean() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b4b.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b4b.md" > "$SANDBOX/trail/dod/.active-dod"

  # Commit a file so HEAD~1..HEAD is non-empty, then leave the working tree
  # clean (nothing staged/unstaged) — the PR-review situation.
  ( cd "$SANDBOX" \
      && echo "committed pr change" > pr-committed-change.txt \
      && git add pr-committed-change.txt \
      && git commit -q -m "feat: a committed pr change" )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  local cf_block
  cf_block=$(awk '/^changed_files \(/,/^$/' "$RUN_WRAPPER_PROMPT_FILE")

  # Clean working tree → committed range is the only source; the committed
  # file must appear so PR review is not blinded.
  printf '%s' "$cf_block" | grep -qF "pr-committed-change.txt" \
    || fail "committed file missing from changed_files when working tree is clean (PR flow degrade broke)"
  return 0
}

# ------------------------------------------------------------
# B5 (2026-06-09): claim_sources must follow the review subject. In
# working_tree mode (staged ∪ unstaged non-empty) the HEAD commit is almost
# always an unrelated prior commit (rein's review-before-commit flow). Using
# its message as the claim source pollutes the Claim Audit with an unrelated
# claim. The fix decides a `review_subject` once and, in working_tree mode,
# skips the HEAD commit message and uses the DoD title (PR env stays top
# priority). This is the claim-comparison counterpart of B4's file-list fix.
#
# RED (pre-fix): claim_sources carries `head_commit=` with the unrelated HEAD
# message; the DoD title is absent.
# GREEN (post-fix): claim_sources carries the DoD title; the unrelated HEAD
# commit message is absent.
# ------------------------------------------------------------
test_claim_sources_uses_dod_not_head_in_working_tree_mode() {
  # Arrange: DoD context (its first heading is the title the fix should use).
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b5.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b5.md" > "$SANDBOX/trail/dod/.active-dod"

  # (a) Commit an UNRELATED change whose message must NOT become the claim
  #     source. The marker string is unique so we can assert its absence.
  ( cd "$SANDBOX" \
      && echo "unrelated content" > unrelated-persona.txt \
      && git add unrelated-persona.txt \
      && git commit -q -m "unrelated persona commit MARKER_B5_HEAD" )

  # (b) Stage the REAL review subject so the wrapper is in working_tree mode.
  ( cd "$SANDBOX" \
      && echo "the actual change under review" > real-staged-b5.txt \
      && git add real-staged-b5.txt )

  # Act: code-review mode (no spec-review prefix), no PR env → claim_sources
  # falls through the env branch and must pick the review-subject source.
  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Extract the claim_sources slot block so we assert on its contents only.
  local cs_block
  cs_block=$(awk '/^claim_sources:/,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")

  # The unrelated HEAD commit message MUST NOT be the claim source.
  printf '%s' "$cs_block" | grep -qF "MARKER_B5_HEAD" \
    && fail "unrelated HEAD commit message leaked into claim_sources in working_tree mode (stale claim context)"

  # The DoD title MUST be the claim source instead.
  printf '%s' "$cs_block" | grep -qF "dod_title=" \
    || fail "claim_sources did not fall back to dod_title in working_tree mode"
  return 0
}

# ------------------------------------------------------------
# B5 negative-side: when the working tree is CLEAN (PR flow / commit_range
# mode) and no PR env is set, claim_sources MUST still use the HEAD commit
# message — the committed change IS the review subject. The fix must not
# regress this.
# ------------------------------------------------------------
test_claim_sources_uses_head_in_commit_range_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b5b.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b5b.md" > "$SANDBOX/trail/dod/.active-dod"

  # Commit a change and leave the working tree clean → commit_range mode. The
  # committed message IS the review subject, so claim_sources should use it.
  ( cd "$SANDBOX" \
      && echo "committed pr content" > pr-committed-b5b.txt \
      && git add pr-committed-b5b.txt \
      && git commit -q -m "feat: pr change MARKER_B5_RANGE" )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  local cs_block
  cs_block=$(awk '/^claim_sources:/,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")

  # Clean working tree → HEAD commit message is the legitimate claim source.
  printf '%s' "$cs_block" | grep -qF "MARKER_B5_RANGE" \
    || fail "HEAD commit message missing from claim_sources in commit_range mode (PR flow degrade broke)"
  return 0
}

# ------------------------------------------------------------
# B6 (2026-06-09): the changed_files slot LABEL must reflect the review
# subject. In working_tree mode the slot lists staged+unstaged files, but the
# label was hardcoded `changed_files (<DIFF_BASE>..HEAD):` — claiming a
# committed range it is not actually showing. The fix makes the label
# mode-aware (working tree / committed range / spec review subject).
#
# RED (pre-fix): the label shows the `..HEAD` committed-range form even though
# the content is working-tree files.
# GREEN (post-fix): the label shows `working tree`.
# ------------------------------------------------------------
test_changed_files_label_reflects_working_tree_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b6.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b6.md" > "$SANDBOX/trail/dod/.active-dod"

  # Make the working tree dirty (staged) → working_tree mode.
  ( cd "$SANDBOX" \
      && echo "the actual change under review" > real-staged-b6.txt \
      && git add real-staged-b6.txt )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # The changed_files slot label must say "working tree", not a committed range.
  grep -qE "^changed_files \(working tree" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "changed_files label does not reflect working tree mode (got committed-range label for dirty tree)"

  # The label MUST NOT show the committed-range `..HEAD` form in this mode.
  grep -qE "^changed_files \(.*\.\.HEAD\):" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "changed_files label still shows committed range (..HEAD) while content is working-tree files"
  return 0
}

# ------------------------------------------------------------
# B6 negative-side: when the working tree is CLEAN (PR flow / commit_range
# mode) the label MUST keep the committed-range `<DIFF_BASE>..HEAD` form so a
# PR reviewer sees the diff range it is actually being shown.
# ------------------------------------------------------------
test_changed_files_label_reflects_commit_range_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b6b.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b6b.md" > "$SANDBOX/trail/dod/.active-dod"

  # Commit a change, leave working tree clean → commit_range mode.
  ( cd "$SANDBOX" \
      && echo "committed pr change" > pr-committed-b6b.txt \
      && git add pr-committed-b6b.txt \
      && git commit -q -m "feat: pr change for label test" )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Clean tree → committed-range label must be present.
  grep -qE "^changed_files \(.*\.\.HEAD\):" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "changed_files label lost committed-range form in commit_range mode (PR flow degrade broke)"
  grep -qE "^changed_files \(working tree" "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "working-tree label leaked into a clean-tree (commit_range) review"
  return 0
}

# ------------------------------------------------------------
# B5-cont (2026-06-09): the Claim Audit slot's claim-source-priority
# INSTRUCTION TEXT (slot 4, sub-item 4) must match the actual _claim_sources
# logic, which is REVIEW_SUBJECT-aware (B5). The instruction was hardcoded
# `PR title/body > HEAD commit > DoD/plan top > "unavailable"` — the old fixed
# order. After the B5 logic change, working_tree mode skips HEAD commit and
# uses the DoD title, so the static instruction tells a future reviewer the
# wrong priority and would false-flag the intended working_tree=DoD behavior
# as a "priority violation". The instruction must be built mode-aware (like
# B6's CHANGED_FILES_LABEL) so the policy text and the runtime behavior agree.
#
# RED (pre-fix): in working_tree mode the instruction still shows the
# `HEAD commit` priority (mode-blind static text).
# GREEN (post-fix): working_tree-mode instruction reflects the DoD priority and
# does NOT list HEAD commit ahead of the DoD.
# ------------------------------------------------------------

# Extract the slot-4 (Claim Audit) claim-source-priority instruction block
# from the captured envelope. The instruction begins at the numbered
# "Claim source 우선순위" sub-item and runs through its (possibly wrapped)
# header lines onto the priority-chain line, stopping at the first blank line
# that ends the sub-item (before "5. Evidence freshness").
_claim_priority_instruction_block() {
  awk '
    /Claim source[ ]?우선순위/ {grab=1}
    grab && /^[[:space:]]*$/ {grab=0}
    grab {print}
  ' "$1"
}

test_claim_source_priority_note_reflects_working_tree_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b5c.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b5c.md" > "$SANDBOX/trail/dod/.active-dod"

  # Make the working tree dirty (staged) → working_tree mode.
  ( cd "$SANDBOX" \
      && echo "the actual change under review" > real-staged-b5c.txt \
      && git add real-staged-b5c.txt )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Isolate the actual priority CHAIN line (the one with `>` arrows) so the
  # assertions key off the real priority order, not incidental prose.
  local chain
  chain=$(_claim_priority_instruction_block "$RUN_WRAPPER_PROMPT_FILE" | grep -F '>')
  [ -n "$chain" ] \
    || fail "claim-source-priority chain line not found in envelope slot 4"

  # In working_tree mode the chain MUST reflect the DoD priority (the actual
  # _claim_sources behavior: PR env > DoD title, HEAD skipped).
  printf '%s' "$chain" | grep -qiF "DoD" \
    || fail "working_tree claim-priority chain does not list the DoD basis"

  # And the chain MUST NOT carry the old hardcoded 'HEAD commit >' priority arrow
  # — that is the mode-blind text that contradicts B5's working_tree logic.
  printf '%s' "$chain" | grep -qiF "HEAD commit >" \
    && fail "working_tree claim-priority chain still lists 'HEAD commit >' (mode-blind static text contradicting B5)"
  return 0
}

# ------------------------------------------------------------
# B5-cont negative-side: in commit_range mode (clean working tree, PR flow)
# the committed change IS the review subject, so the instruction text MUST
# keep listing the `HEAD commit` priority. The mode-aware fix must not drop it.
# ------------------------------------------------------------
test_claim_source_priority_note_reflects_commit_range_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-06-09-b5cb.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-06-09-b5cb.md" > "$SANDBOX/trail/dod/.active-dod"

  # Commit a change, leave working tree clean → commit_range mode.
  ( cd "$SANDBOX" \
      && echo "committed pr change" > pr-committed-b5cb.txt \
      && git add pr-committed-b5cb.txt \
      && git commit -q -m "feat: pr change for claim-priority text test" )

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Isolate the actual priority CHAIN line (the one with `>` arrows).
  local chain
  chain=$(_claim_priority_instruction_block "$RUN_WRAPPER_PROMPT_FILE" | grep -F '>')
  [ -n "$chain" ] \
    || fail "claim-source-priority chain line not found in envelope slot 4"

  # Commit_range mode: the HEAD commit message is the legitimate claim source,
  # so the chain MUST keep the 'HEAD commit >' priority arrow.
  printf '%s' "$chain" | grep -qiF "HEAD commit >" \
    || fail "commit_range claim-priority chain lost the 'HEAD commit >' priority (mode-aware fix dropped it for PR flow)"
  return 0
}

# ------------------------------------------------------------
# B5-spec (Round 5, 2026-06-09): in spec-review mode the claim-source
# INSTRUCTION TEXT (slot 4, sub-item 4) tells the reviewer
# `PR title/body > (no claim sources available)` — the HEAD-revision message
# is intentionally skipped (a fresh spec review has no commit diff to anchor a
# claim on; G8-3 already forces diff_base=N/A and SAD_PATH=""). But
# _claim_sources only branched on `working_tree`; the `spec` subject fell
# through to the generic `git log -1 --pretty=%B` tail and emitted
# `head_commit=` with the unrelated HEAD message. The instruction text (skip
# HEAD) and the runtime logic (use HEAD) contradicted each other.
#
# RED (pre-fix): claim_sources carries `head_commit=` with the unrelated HEAD
# message; the explicit no-source sentinel is absent.
# GREEN (post-fix): claim_sources skips HEAD entirely — no `head_commit=`, no
# unrelated HEAD message — and emits the `(no claim sources available)`
# sentinel, matching the spec-mode instruction text.
# ------------------------------------------------------------
test_claim_sources_spec_mode_skips_head() {
  # Arrange: a fresh design under review. Commit an UNRELATED change first so
  # HEAD carries a message that must NOT leak into the claim sources.
  seed_design "docs/specs/2026-06-09-spec-claim.md" "S1 S2"
  ( cd "$SANDBOX" \
      && echo "unrelated content" > unrelated-spec-head.txt \
      && git add unrelated-spec-head.txt \
      && git commit -q -m "unrelated commit MARKER_SPEC_HEAD" )
  # Deliberately NO .active-dod marker (fresh spec review has no related DoD;
  # G8-3 keeps SAD_PATH="" in spec mode, so dod_title is not a source either).

  # Act: spec-review mode (design) + no PR env → claim_sources must follow the
  # spec subject and skip the HEAD commit message.
  run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/2026-06-09-spec-claim.md" \
              --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$RUN_WRAPPER_PROMPT_FILE" ] || fail "fake-codex did not capture prompt"

  # Isolate the claim_sources slot block.
  local cs_block
  cs_block=$(awk '/^claim_sources:/,/^---$/' "$RUN_WRAPPER_PROMPT_FILE")

  # The unrelated HEAD commit message MUST NOT leak in (text says skip HEAD).
  printf '%s' "$cs_block" | grep -qF "MARKER_SPEC_HEAD" \
    && fail "unrelated HEAD commit message leaked into claim_sources in spec-review mode (text says skip HEAD, logic used it)"

  # The `head_commit=` source line itself MUST be absent in spec mode.
  printf '%s' "$cs_block" | grep -qF "head_commit=" \
    && fail "claim_sources emitted head_commit= in spec-review mode (HEAD must be skipped)"

  # The explicit no-source sentinel MUST be present (matches the spec-mode
  # instruction text `PR title/body > (no claim sources available)`).
  printf '%s' "$cs_block" | grep -qF "(no claim sources available)" \
    || fail "claim_sources did not emit the no-source sentinel in spec-review mode"
  return 0
}

# ------------------------------------------------------------
# B5-spec negative-side: a spec review WITH PR env set must still surface the
# PR claim (PR title/body stays top priority in every mode). The spec branch
# must not swallow an explicit PR claim.
# ------------------------------------------------------------
test_claim_sources_spec_mode_keeps_pr_env() {
  seed_design "docs/specs/2026-06-09-spec-claim-pr.md" "S1"
  ( cd "$SANDBOX" \
      && echo "unrelated content" > unrelated-spec-head-pr.txt \
      && git add unrelated-spec-head-pr.txt \
      && git commit -q -m "unrelated commit MARKER_SPEC_HEAD_PR" )

  # Run with PR env set — the explicit PR claim must win in spec mode too.
  local capture_file="$SANDBOX/.fake-codex-prompt-capture.txt"
  local stdin_file="$SANDBOX/.stdin-in.txt"
  local tmp_stdout tmp_stderr
  tmp_stdout=$(mktemp); tmp_stderr=$(mktemp)
  printf '%s' "[NON_INTERACTIVE] spec review for design: docs/specs/2026-06-09-spec-claim-pr.md" > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture_file"
    export REIN_PR_TITLE="MARKER_SPEC_PR_TITLE"
    export REIN_PR_BODY="some pr body"
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive < "$stdin_file" \
      > "$tmp_stdout" 2> "$tmp_stderr"
  )
  RUN_WRAPPER_RC=$?
  RUN_WRAPPER_ERR=$(cat "$tmp_stderr")
  rm -f "$tmp_stdout" "$tmp_stderr" "$stdin_file"

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  [ -f "$capture_file" ] || fail "fake-codex did not capture prompt"

  local cs_block
  cs_block=$(awk '/^claim_sources:/,/^---$/' "$capture_file")

  # The PR title MUST be the claim source even in spec mode.
  printf '%s' "$cs_block" | grep -qF "MARKER_SPEC_PR_TITLE" \
    || fail "PR title missing from claim_sources in spec-review mode (PR env must stay top priority)"
  # The unrelated HEAD message MUST still be absent.
  printf '%s' "$cs_block" | grep -qF "MARKER_SPEC_HEAD_PR" \
    && fail "unrelated HEAD commit message leaked into spec-review claim_sources even with PR env set"
  return 0
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
  run_test test_envelope_contains_all_4_slots_and_tier1_dod
  run_test test_envelope_high_process_gap_when_dod_missing
  run_test test_tier2_fallback_chooses_latest_mtime
  run_test test_code_review_pass_stamp_has_diff_base
  run_test test_spec_review_pass_no_stamp_created_and_pending_unchanged
  run_test test_spec_review_needs_fix_no_stamp
  run_test test_h1_design_ref_plan_relative_resolves
  run_test test_h1_unresolvable_design_ref_flagged_missing
  run_test test_h2_multiple_plan_refs_flagged_in_envelope
  # Claim-audit-hardening (2026-04-24)
  run_test test_envelope_context_block_has_diff_base_iso_and_head_iso
  run_test test_claim_source_iso_hints_emitted_when_file_ref_present
  run_test test_claim_source_iso_hints_omitted_when_no_file_ref
  run_test test_claim_source_iso_hints_skips_malicious_paths
  run_test test_claim_source_iso_hints_limit_20_entries
  run_test test_claim_source_iso_hints_emits_unavailable_for_untracked_file
  run_test test_envelope_retains_exactly_four_slot_headings_after_hardening
  run_test test_claim_source_iso_hints_skips_nonexistent_file
  # P2 verdict parser hardening (2026-04-25)
  run_test test_envelope_contains_final_verdict_instruction
  run_test test_parse_verdict_recognizes_final_verdict_line_in_body
  run_test test_parse_verdict_falls_back_to_first_line_keyword_when_no_final_verdict
  run_test test_parse_verdict_final_verdict_line_overrides_first_line_keyword
  run_test test_parse_verdict_multiple_final_verdict_lines_last_match_wins
  run_test test_parse_verdict_body_quoted_verdict_does_not_override_final
  run_test test_parse_verdict_no_keyword_returns_needs_fix
  # B2 exit-code 누수 회귀 방지 (2026-06-09)
  run_test test_codex_nonzero_exit_propagates
  # Plugin self-containment hotfix (2026-05-12)
  run_test test_wrapper_plugin_layout_user_repo_without_claude_dir_uses_bundled_lib
  # BUG-WRAP-SOURCE: fail-closed on missing/unreadable/invalid lib (2026-05-29)
  run_test test_wrapper_missing_lib_fails_closed_exit2
  run_test test_wrapper_unreadable_lib_fails_closed_exit2
  run_test test_wrapper_invalid_lib_missing_function_fails_closed_exit2
  run_test test_wrapper_valid_lib_still_works
  # PROJECT_DIR sanity check (PD-2, 2026-05-19)
  run_test test_pd2_sanity_rejects_project_dir_without_trail
  run_test test_pd2_sanity_rejects_project_dir_not_git_toplevel
  run_test test_pd2_sanity_accepts_valid_project_dir
  # Fresh spec-review unrelated active-DoD fallback (G8-3, 2026-05-23)
  run_test test_g8_3_fresh_spec_review_ignores_unrelated_active_dod
  run_test test_g8_3_code_review_still_uses_tier2_fallback
  # B4 stale review context: working tree preferred over committed range (2026-06-09)
  run_test test_changed_files_prefers_staged_over_committed_range
  run_test test_changed_files_degrades_to_committed_range_when_working_tree_clean
  # B5 claim_sources review-subject consistency (2026-06-09)
  run_test test_claim_sources_uses_dod_not_head_in_working_tree_mode
  run_test test_claim_sources_uses_head_in_commit_range_mode
  # B6 changed_files label review-subject consistency (2026-06-09)
  run_test test_changed_files_label_reflects_working_tree_mode
  run_test test_changed_files_label_reflects_commit_range_mode
  # B5-cont claim-source-priority instruction text review-subject consistency (2026-06-09)
  run_test test_claim_source_priority_note_reflects_working_tree_mode
  run_test test_claim_source_priority_note_reflects_commit_range_mode
  # B5-spec claim_sources spec-mode HEAD skip — text/logic consistency (Round 5, 2026-06-09)
  run_test test_claim_sources_spec_mode_skips_head
  run_test test_claim_sources_spec_mode_keeps_pr_env
  # ENV-SUBJ envelope review-subject consistency A1~A5 (2026-06-11)
  run_test test_envelope_declares_commit_range_subject_with_real_head_iso
  run_test test_envelope_working_tree_subject_neutralizes_head_iso
  run_test test_envelope_spec_subject_iso_explicit_na
  run_test test_tier2_dod_context_marked_advisory_not_blocking
  run_test test_tier1_dod_context_keeps_blocking_policy
  run_test test_freshness_rule_qualified_in_working_tree_mode
  run_test test_freshness_rule_strict_in_commit_range_mode
  # D1 fail-soft guard SIGPIPE 무력화 회귀 (2026-06-11)
  run_test test_model_failsoft_guard_survives_large_output_with_early_verdict_echo
  # D2 모드 감지 SIGPIPE 무력화 회귀 (2026-06-11, Round 2 High)
  run_test test_spec_mode_detection_survives_large_prompt
  summary
}

# ------------------------------------------------------------
# ENV-SUBJ (2026-06-11): envelope review-subject consistency — A1~A5.
# 계약: envelope 의 모든 모드 의존 슬롯(review_subject 선언, head_iso,
# diff_base_iso, active DoD 컨텍스트 권위, freshness 비교)이 REVIEW_SUBJECT
# 를 정직하게 따른다. Tier 2(추측) DoD 컨텍스트는 advisory 로 강등 — blocking
# Design Alignment 근거로 승격 금지.
# ------------------------------------------------------------

# A1+A2: clean tree (commit_range) → review_subject 선언 + head_iso 실값.
test_envelope_declares_commit_range_subject_with_real_head_iso() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qE '^review_subject: commit_range$' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'review_subject: commit_range' declaration"
  grep -qE '^head_iso: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "head_iso not a real ISO in commit_range mode"
  return 0
}

# A1+A2: dirty tree (working_tree) → head_iso 는 명시 N/A (HEAD 는 subject 아님).
test_envelope_working_tree_subject_neutralizes_head_iso() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"
  # tracked 파일을 commit 후 수정 → unstaged 변경 = working_tree 모드.
  echo "v1" > "$SANDBOX/src.txt"
  ( cd "$SANDBOX" && git add src.txt && git commit -qm "add src" )
  echo "v2" >> "$SANDBOX/src.txt"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qE '^review_subject: working_tree$' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'review_subject: working_tree' declaration"
  grep -qF 'head_iso: (N/A: working-tree review' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "head_iso not neutralized in working_tree mode (HEAD is not the subject)"
  return 0
}

# A3: spec 모드 → review_subject=spec + ISO 쌍 명시 N/A + freshness skip 안내.
test_envelope_spec_subject_iso_explicit_na() {
  seed_design "docs/specs/2026-06-11-d.md" "A1"

  run_wrapper "[NON_INTERACTIVE] spec review for design: docs/specs/2026-06-11-d.md" \
    --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qE '^review_subject: spec$' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "envelope missing 'review_subject: spec' declaration"
  grep -qF 'diff_base_iso: (N/A: spec review has no commit diff)' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "spec diff_base_iso not explicit N/A (generic '(unavailable)' is ambiguous)"
  grep -qF 'head_iso: (N/A: spec review has no commit diff)' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "spec head_iso not explicit N/A"
  grep -qF 'freshness 비교 전체 skip' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "spec freshness skip qualifier missing"
  return 0
}

# A4: Tier 2 (marker 없는 추측 fallback) → DoD 컨텍스트 advisory 강등 표기.
test_tier2_dod_context_marked_advisory_not_blocking() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-guess.md" "docs/plans/foo-plan.md" "A1"
  # marker 없음 → Tier 2. dirty tree (실제 사고 형태: staged 작업 + 추측 DoD).
  echo "v1" > "$SANDBOX/src.txt"
  ( cd "$SANDBOX" && git add src.txt && git commit -qm "add src" )
  echo "v2" >> "$SANDBOX/src.txt"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qF 'active_dod_tier: 2 (advisory fallback guess' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "tier display not qualified as advisory guess"
  grep -qF '[Tier 2 advisory guess]' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "Design Alignment advisory note missing for Tier 2 context"
  return 0
}

# A4 negative: Tier 1 (명시 marker) → advisory 강등 노트 부재, blocking 정책 유지.
test_tier1_dod_context_keeps_blocking_policy() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qF '[Tier 2 advisory guess]' "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "advisory note leaked into Tier-1 envelope (blocking policy must stay intact)"
  grep -qE '^active_dod_tier: 1$' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "Tier-1 tier display altered"
  return 0
}

# A5: working_tree → freshness HIGH flag 비적용 qualifier 존재.
test_freshness_rule_qualified_in_working_tree_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"
  echo "v1" > "$SANDBOX/src.txt"
  ( cd "$SANDBOX" && git add src.txt && git commit -qm "add src" )
  echo "v2" >> "$SANDBOX/src.txt"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qF 'stale-evidence HIGH flag 비적용' "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "working_tree freshness qualifier missing (stale-evidence HIGH must not apply)"
  return 0
}

# D1 (2026-06-11): fail-soft 가드 SIGPIPE 무력화 회귀.
# pipefail 아래서 `printf <대용량> | grep -q` 는 grep 조기종료 → printf SIGPIPE(141)
# → if 조건 전체 거짓 → FINAL_VERDICT 가드 skip → 본문에 인용된 에러패턴을 모델
# 거부로 오인해 exit 3 (PASS 인데 stamp 미생성). 실측 재현: 본 사이클 Round 1
# self-review (wrapper 가 자기 소스의 에러패턴 주석을 리뷰 본문에 인용).
# 시나리오: 출력 앞부분에 verdict 양식 줄(envelope 인용) + ~800KB filler + 끝부분
# 에러패턴 인용 + 진짜 FINAL_VERDICT: PASS → wrapper 는 exit 0 + stamp 생성이 정답.
test_model_failsoft_guard_survives_large_output_with_early_verdict_echo() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"

  # 대용량 payload 는 env var 로 못 싣는다 (ARG_MAX) — 파일로 전달.
  local payload_file="$SANDBOX/.fake-codex-payload.txt"
  {
    printf '  FINAL_VERDICT: <PASS|NEEDS-FIX|REJECT>\n'
    yes 'filler line to push output far past the pipe buffer for the sigpipe window' | head -20000
    printf 'quoted wrapper source: invalid_request_error / model_not_found detection patterns\n'
    printf 'All checks clean.\n'
    printf 'FINAL_VERDICT: PASS\n'
  } > "$payload_file"

  FAKE_CODEX_VERDICT_FILE="$payload_file" run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC — fail-soft guard defeated by SIGPIPE/pipefail (expected PASS exit 0)"
  [ -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "stamp not created despite FINAL_VERDICT: PASS in large output"
  return 0
}

# D2 (2026-06-11, Round 2 High): 모드 감지 SIGPIPE 무력화 회귀.
# `printf <대용량 prompt> | head -1 | grep -q` 도 D1 과 동일 클래스 — head -1
# 조기종료가 printf SIGPIPE(141)를 유발, pipefail 아래서 첫 줄이 spec marker 와
# "매치했는데도" 조건이 거짓 → spec 리뷰가 code-review 로 오분류. 최악의 결과:
# spec 리뷰가 코드 게이트 stamp(.codex-reviewed)를 생성 (규율 구멍).
# 시나리오: spec marker 첫 줄 + ~1.5MB 본문 → spec-review 모드 유지(stamp 미생성
# + spec N/A 표기)가 정답.
test_spec_mode_detection_survives_large_prompt() {
  seed_design "docs/specs/2026-06-11-big.md" "A1"

  local big_prompt
  big_prompt="[NON_INTERACTIVE] spec review for design: docs/specs/2026-06-11-big.md
$(yes 'large prompt body line to exceed the pipe buffer for the sigpipe window' | head -20000)"

  run_wrapper "$big_prompt" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  # spec-review 모드 증거: active DoD 가 spec N/A sentinel 로 표기.
  grep -qF "(N/A for fresh spec review)" "$RUN_WRAPPER_PROMPT_FILE" \
    || fail "spec marker missed on large prompt — mode misclassified as code-review (SIGPIPE)"
  # 규율 핵심: spec 리뷰는 코드 게이트 stamp 를 절대 만들지 않는다.
  [ -f "$SANDBOX/trail/dod/.codex-reviewed" ] \
    && fail "spec review created .codex-reviewed stamp (code-gate pollution)"
  return 0
}

# A5 negative: commit_range → qualifier 부재 (기존 strict 비교 유지).
test_freshness_rule_strict_in_commit_range_mode() {
  seed_design "docs/specs/foo-design.md" "A1"
  seed_plan "docs/plans/foo-plan.md" "docs/specs/foo-design.md" "A1"
  seed_dod "trail/dod/dod-2026-04-21-t.md" "docs/plans/foo-plan.md" "A1"
  echo "path=trail/dod/dod-2026-04-21-t.md" > "$SANDBOX/trail/dod/.active-dod"

  run_wrapper "code review please" --non-interactive

  [ "$RUN_WRAPPER_RC" = "0" ] || fail "wrapper exit = $RUN_WRAPPER_RC (stderr: $RUN_WRAPPER_ERR)"
  grep -qF 'stale-evidence HIGH flag 비적용' "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "freshness qualifier leaked into commit_range mode (strict rule must stay)"
  grep -qF 'freshness 비교 전체 skip' "$RUN_WRAPPER_PROMPT_FILE" \
    && fail "spec skip qualifier leaked into commit_range mode"
  return 0
}

main "$@"
