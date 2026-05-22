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
  run_test test_parse_verdict_no_keyword_returns_needs_fix
  # Plugin self-containment hotfix (2026-05-12)
  run_test test_wrapper_plugin_layout_user_repo_without_claude_dir_uses_bundled_lib
  # PROJECT_DIR sanity check (PD-2, 2026-05-19)
  run_test test_pd2_sanity_rejects_project_dir_without_trail
  run_test test_pd2_sanity_rejects_project_dir_not_git_toplevel
  run_test test_pd2_sanity_accepts_valid_project_dir
  summary
}

main "$@"
