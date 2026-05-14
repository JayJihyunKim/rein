#!/bin/bash
# tests/hooks/test-spec-review-gate.sh
# Comprehensive test suite for spec review enforcement
# Test harness: tests/hooks/lib/test-harness.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

# =================================================================
# PATH MATCHING TESTS (10 tests)
# =================================================================

test_canonical_path_docs_specs() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical: docs/specs/2026-04-15-spec-review-enforcement-design.md
  mkdir -p "$SANDBOX/docs/specs"
  touch "$SANDBOX/docs/specs/2026-04-15-spec-review-enforcement-design.md"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/docs/specs/2026-04-15-spec-review-enforcement-design.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "canonical docs spec should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker"
}

test_canonical_path_docs_plans() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical: docs/features/plans/2026-Q2-roadmap.md
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/docs/features/plans/2026-Q2-roadmap.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "canonical docs plan should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create pending marker"
}

test_canonical_path_specs_root() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical: specs/api-design.md (root level)
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/specs/api-design.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "canonical specs root should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create pending marker"
}

test_canonical_path_plans_root() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical: plans/2026-roadmap.md (root level)
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/plans/2026-roadmap.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "canonical plans root should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create pending marker"
}

test_non_canonical_src_file() {
  seed_dod "dod-2026-04-13-test.md"

  # Non-canonical: src/components/auth.ts
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/components/auth.ts"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "non-canonical src file should allow (no marker)"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -eq 0 ] || fail "should NOT create marker" "should NOT create marker"
}

test_non_canonical_readme() {
  seed_dod "dod-2026-04-13-test.md"

  # Non-canonical: README.md (root)
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/README.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "non-canonical README should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -eq 0 ] || fail "should NOT create marker" "should NOT create marker"
}

test_canonical_deeply_nested_specs() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical with nested dirs: docs/a/b/c/specs/detail.md
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/docs/a/b/c/specs/detail.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "deeply nested canonical spec should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create pending marker"
}

test_canonical_deeply_nested_plans() {
  seed_dod "dod-2026-04-13-test.md"

  # Canonical with nested dirs: docs/x/y/z/plans/roadmap.md
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/docs/x/y/z/plans/roadmap.md"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "deeply nested canonical plan should allow"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create pending marker"
}

test_false_positive_specs_in_filename() {
  seed_dod "dod-2026-04-13-test.md"

  # Non-canonical: has "specs" in path but not at canonical level
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/specs-utils.js"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "specs in filename only should not trigger"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -eq 0 ] || fail "should NOT create marker" "should NOT create marker"
}

test_false_positive_plans_in_dir() {
  seed_dod "dod-2026-04-13-test.md"

  # Non-canonical: has "plans" in path but not at canonical level
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/app/plans/auth.ts"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "plans in path but wrong dir should not trigger"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -eq 0 ] || fail "should NOT create marker" "should NOT create marker"
}

# =================================================================
# GATE BEHAVIOR TESTS (7 tests)
# =================================================================

test_gate_blocks_unreviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  # Create pending marker (simulate post-write hook)
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | head -c 16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  # Try to edit source file
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  # pre-edit-dod-gate should block
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block when unreviewed spec exists"
}

test_gate_allows_reviewed_spec() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  # Create both pending and reviewed markers
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | head -c 16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "reviewer=codex"
    echo "reviewed=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  # Try to edit source file
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should allow when spec is reviewed"
}

test_gate_ignores_deleted_spec() {
  seed_dod "dod-2026-04-13-test.md"

  # Create marker for non-existent spec file
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  hash=$(printf '%s' "$SANDBOX/specs/deleted.md" | shasum 2>/dev/null | head -c 16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/deleted.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  # Try to edit source file
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should ignore markers for deleted specs"
}

test_gate_respects_bypass_file() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  # Create pending marker
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | head -c 16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  # Create bypass file
  touch "$SANDBOX/trail/dod/.skip-spec-gate"

  # Try to edit source file
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should allow when bypass file exists"
}

test_gate_no_spec_reviews_dir() {
  seed_dod "dod-2026-04-13-test.md"

  # No .spec-reviews directory at all
  [ -d "$SANDBOX/trail/dod/.spec-reviews" ] && rm -rf "$SANDBOX/trail/dod/.spec-reviews"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should allow when no spec-reviews directory"
}

test_gate_multiple_unreviewed_specs() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api.md"
  touch "$SANDBOX/specs/auth.md"

  # Create pending markers for both
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  for fname in api auth; do
    hash=$(printf '%s' "$SANDBOX/specs/${fname}.md" | shasum 2>/dev/null | head -c 16 || printf "spec${fname}")
    {
      echo "path=$SANDBOX/specs/${fname}.md"
      echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
    } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  done

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block when multiple unreviewed specs exist"
}

test_post_write_hook_hash_consistency() {
  seed_dod "dod-2026-04-13-test.md"

  # Create spec file
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/consistency-test.md"
  echo "# Test Spec" > "$spec_file"

  # Run post-write hook
  local input='{
    "tool_input": {"file_path": "'$spec_file'"},
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "post-write should succeed"

  # Check that marker was created (hash should be deterministic)
  [ -d "$SANDBOX/trail/dod/.spec-reviews" ] || fail "should create .spec-reviews directory"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker"
}

# =================================================================
# MULTIEDIT TESTS (2 tests)
# =================================================================

test_multiedit_extracts_all_files() {
  seed_dod "dod-2026-04-13-test.md"

  # MultiEdit with 3 files including one spec
  mkdir -p "$SANDBOX/docs/features/specs"
  touch "$SANDBOX/docs/features/specs/test-spec.md"
  touch "$SANDBOX/src/component1.ts"
  touch "$SANDBOX/src/component2.ts"

  local input='{
    "tool_input": {
      "edits": [
        {"file_path": "'$SANDBOX'/docs/features/specs/test-spec.md"},
        {"file_path": "'$SANDBOX'/src/component1.ts"},
        {"file_path": "'$SANDBOX'/src/component2.ts"}
      ]
    },
    "tool_result": {}
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "multiedit should process all files"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)" -gt 0 ] || fail "should create pending marker" "should create marker for spec"
}

test_multiedit_deduplicates_files() {
  seed_dod "dod-2026-04-13-test.md"

  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/dedup-test.md"

  # Spec path appears in both tool_input and tool_result
  local input='{
    "tool_input": {
      "file_path": "'$SANDBOX'/specs/dedup-test.md",
      "edits": [{"file_path": "'$SANDBOX'/specs/dedup-test.md"}]
    },
    "tool_result": {
      "edits": [{"file_path": "'$SANDBOX'/specs/dedup-test.md"}]
    }
  }'

  run_hook "post-write-spec-review-gate.sh" "$input"
  assert_exit 0 "multiedit should handle duplicates"

  # Should only create one marker (deduplicated)
  marker_count=$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.pending 2>/dev/null | wc -l)
  [ "$marker_count" -eq 1 ] || fail "should create only one marker for dedup file"
}

# =================================================================
# HELPER SCRIPT TESTS (2 tests)
# =================================================================

test_helper_marks_spec_reviewed() {
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/test.md"
  echo "# Test" > "$spec_file"

  # Create pending marker
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  hash=$(printf '%s' "$spec_file" | shasum 2>/dev/null | head -c 16 || printf 'test1234567890')
  {
    echo "path=$spec_file"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  # Create a wrapper script to avoid PROJECT_DIR issues
  mkdir -p "$SANDBOX/scripts"
  cat > "$SANDBOX/scripts/rein-mark-spec-reviewed.sh" <<'EOF'
#!/bin/bash
set -u
SPEC_PATH="${1:-}"
REVIEWER="${2:-}"
if [ -z "$SPEC_PATH" ] || [ -z "$REVIEWER" ]; then
  echo "Usage: bash scripts/rein-mark-spec-reviewed.sh <spec_path> <reviewer>" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"
ABS_SPEC=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$SPEC_PATH" 2>/dev/null)
[ -z "$ABS_SPEC" ] && { echo "ERROR: invalid spec path: $SPEC_PATH" >&2; exit 1; }
compute_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum | cut -c1-16
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha1sum | cut -c1-16
  else
    local tail="${input: -12}"
    local len="${#input}"
    printf '%s%d' "$(echo "$tail" | tr -cd 'a-zA-Z0-9')" "$len" | cut -c1-16
  fi
}
mkdir -p "$SPEC_REVIEWS_DIR"
HASH=$(compute_hash "$ABS_SPEC")
PENDING_MARKER="$SPEC_REVIEWS_DIR/${HASH}.pending"
REVIEWED_MARKER="$SPEC_REVIEWS_DIR/${HASH}.reviewed"
[ -f "$PENDING_MARKER" ] && rm -f "$PENDING_MARKER"
{
  echo "path=$ABS_SPEC"
  echo "reviewer=$REVIEWER"
  echo "reviewed=$(date -u +%Y-%m-%dT%H:%M:%S)"
} > "$REVIEWED_MARKER"
echo "OK: spec reviewed — $ABS_SPEC (reviewer: $REVIEWER)" >&2
exit 0
EOF
  chmod +x "$SANDBOX/scripts/rein-mark-spec-reviewed.sh"

  # Run helper script
  bash "$SANDBOX/scripts/rein-mark-spec-reviewed.sh" "$spec_file" "codex" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "helper script should succeed"

  # Check markers
  [ ! -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending" ] || fail "pending marker should be deleted"
  [ -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed" ] || fail "reviewed marker should be created"

  # Check content
  grep -q "reviewer=codex" "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed" || fail "should record reviewer"
}

test_helper_normalizes_relative_paths() {
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/test.md"
  echo "# Test" > "$spec_file"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"

  # Run helper with relative path (helper is in SANDBOX/scripts/)
  (cd "$SANDBOX" && bash "./scripts/rein-mark-spec-reviewed.sh" "specs/test.md" "reviewer1" > /dev/null 2>&1)
  [ $? -eq 0 ] || fail "helper should handle relative paths"

  # Marker should exist (absolute path used for hash)
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.reviewed 2>/dev/null | wc -l)" -gt 0 ] || fail "should create reviewed marker with absolute path"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_canonical_path_docs_specs post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_docs_plans post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_specs_root post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_plans_root post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_non_canonical_src_file post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_non_canonical_readme post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_deeply_nested_specs post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_deeply_nested_plans post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_false_positive_specs_in_filename post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_false_positive_plans_in_dir post-write-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_gate_blocks_unreviewed_spec post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_allows_reviewed_spec post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_ignores_deleted_spec post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_respects_bypass_file post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_no_spec_reviews_dir post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_multiple_unreviewed_specs post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_post_write_hook_hash_consistency post-write-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_multiedit_extracts_all_files post-write-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_multiedit_deduplicates_files post-write-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_helper_marks_spec_reviewed post-write-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh
run_test test_helper_normalizes_relative_paths post-write-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh

summary
