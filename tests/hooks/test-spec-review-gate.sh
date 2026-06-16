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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  # Create pending marker (simulate post-edit hook)
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

test_post_edit_hook_hash_consistency() {
  seed_dod "dod-2026-04-13-test.md"

  # Create spec file
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/consistency-test.md"
  echo "# Test Spec" > "$spec_file"

  # Run post-edit hook
  local input='{
    "tool_input": {"file_path": "'$spec_file'"},
    "tool_result": {}
  }'

  run_hook "post-edit-spec-review-gate.sh" "$input"
  assert_exit 0 "post-edit should succeed"

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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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

  run_hook "post-edit-spec-review-gate.sh" "$input"
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
# SR-1 STALE .reviewed BYPASS TESTS (6 tests)
#
# Bug: editing an already-reviewed spec re-creates .pending but leaves the
# old .reviewed in place. The gate's existence-only check then passes on the
# stale .reviewed, unlocking source edits with unreviewed spec changes.
# Fix (b): post-edit gate removes a stale .reviewed when a spec is (re-)edited.
# Fix (a): pre-edit gate compares .pending created= vs .reviewed reviewed=
#          (fail-closed on stale / missing timestamps).
# =================================================================

test_post_edit_removes_stale_reviewed_on_respec() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec v1" > "$spec_file"

  # Reviewed state: .reviewed exists, .pending already cleaned (post-review).
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$spec_file" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  # Re-edit the reviewed spec → post-edit hook fires.
  echo "# Spec v2 (edited after review)" > "$spec_file"
  local input='{
    "tool_input": {"file_path": "'$spec_file'"},
    "tool_result": {}
  }'
  run_hook "post-edit-spec-review-gate.sh" "$input"
  assert_exit 0 "post-edit should succeed on re-edit"

  # Edit invalidates the prior review: stale .reviewed removed, fresh .pending created.
  [ ! -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed" ] || fail "stale .reviewed should be removed on re-edit"
  [ -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending" ] || fail "fresh .pending should be created on re-edit"
}

test_gate_blocks_stale_reviewed_when_pending_newer() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  # Coexisting bad state: old reviewed + newer pending (spec edited after review).
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "reviewer=codex"
    echo "reviewed=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block when reviewed is stale (pending newer than reviewed)"
}

test_gate_allows_when_reviewed_fresher_than_pending() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  # Pending older, reviewed newer (review happened after that edit) → fresh, allow.
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "reviewer=codex"
    echo "reviewed=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should allow when reviewed is fresher than pending"
}

test_gate_blocks_when_reviewed_timestamp_missing() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  # .reviewed without a reviewed= line → cannot verify freshness → fail-closed.
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "reviewer=codex"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block (fail-closed) when reviewed timestamp is missing"
}

test_gate_blocks_when_reviewed_timestamp_garbled() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  # A garbled created= that sorts BELOW a valid reviewed= would slip past a pure
  # lexical compare ("0000" < "2026-..."); strict shape validation must
  # fail-closed instead of treating it as fresh.
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=0000"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "reviewer=codex"
    echo "reviewed=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block (fail-closed) when a timestamp is garbled / non-ISO"
}

test_respec_after_review_blocks_source_edit() {
  # End-to-end: real post-edit hook + real mark-spec-reviewed.sh.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec v1" > "$spec_file"

  local spec_input='{
    "tool_input": {"file_path": "'$spec_file'"},
    "tool_result": {}
  }'

  # 1) First spec edit → .pending created.
  run_hook "post-edit-spec-review-gate.sh" "$spec_input"
  assert_exit 0 "post-edit should create pending on first edit"

  # 2) Review via the real helper → .reviewed created, .pending removed.
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/scripts/rein-mark-spec-reviewed.sh" "$spec_file" codex > /dev/null 2>&1
  [ $? -eq 0 ] || fail "mark-spec-reviewed should succeed"

  # 3) Re-edit the reviewed spec → post-edit hook fires again.
  echo "# Spec v2 (unreviewed change)" > "$spec_file"
  run_hook "post-edit-spec-review-gate.sh" "$spec_input"
  assert_exit 0 "post-edit should succeed on re-edit"

  # 4) Source edit must be blocked — spec was re-edited but not re-reviewed.
  local src_input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$src_input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "source edit must be blocked after spec is re-edited without re-review"
}

# =================================================================
# WRITER content_sha anchor (rein-mark-spec-reviewed.sh)
# =================================================================

test_helper_writes_content_sha() {
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/test.md"
  echo "# Reviewed body" > "$spec_file"
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/scripts/rein-mark-spec-reviewed.sh" "$spec_file" codex > /dev/null 2>&1
  [ $? -eq 0 ] || fail "mark-spec-reviewed should succeed on existing spec"
  local marker; marker=$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.reviewed 2>/dev/null | head -1)
  [ -n "$marker" ] || { fail "reviewed marker should exist"; return; }
  local expected; expected=$(_sr1b_sha "$spec_file")
  grep -qF "content_sha=$expected" "$marker" || fail "marker must record content_sha matching spec content"
}

test_helper_fails_on_unhashable_spec() {
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  # spec path does not exist → content cannot be hashed → fail-closed (no stamp).
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/scripts/rein-mark-spec-reviewed.sh" "$SANDBOX/specs/missing.md" codex > /dev/null 2>&1
  [ $? -ne 0 ] || fail "mark-spec-reviewed must fail-closed when spec content cannot be hashed"
  [ "$(ls -1 "$SANDBOX/trail/dod/.spec-reviews"/*.reviewed 2>/dev/null | wc -l)" -eq 0 ] || fail "no marker should be written on hash failure"
}

# =================================================================
# SR-1.b ORPHAN BACKSTOP — content-based staleness (mtime FP fix)
#
# Bug (SR-1.b-MTIME-FP): the orphan .reviewed backstop compared the spec's
# filesystem mtime against reviewed=. git checkout / cherry-pick / rotation
# bump mtime without changing content → false "stale" → unrelated source
# edits chain-blocked (2026-05-29 incident: 25 dev-only docs).
#
# Fix (codex Mode B "tightened A"): content_sha anchor first (TIER 1),
# constrained git committer-time fallback for retrospective/healer markers
# only (TIER 2), mtime fallback preserved for non-retro / non-git (TIER 3).
# =================================================================

# Compute the byte-level content sha256 the writer/gate use (NOT the path hash).
_sr1b_sha() {
  python3 -c 'import hashlib,sys
with open(sys.argv[1],"rb") as f:
    print(hashlib.sha256(f.read()).hexdigest())' "$1" 2>/dev/null
}

# Initialize the sandbox as a git repo (TIER 2 tests). Commit date controllable
# via GIT_COMMITTER_DATE / GIT_AUTHOR_DATE by the caller.
_sr1b_git_init() {
  git -C "$SANDBOX" init -q 2>/dev/null
  git -C "$SANDBOX" config user.email "t@example.com"
  git -C "$SANDBOX" config user.name "test"
}

_sr1b_orphan_hash() {
  # mirror the gate's path-hash convention (only needs uniqueness + no .pending sibling)
  printf '%s' "$1" | shasum 2>/dev/null | cut -c1-16 || printf 'orphanhash01'
}

# --- TIER 1: content_sha anchor ---

test_orphan_content_sha_match_allows_despite_mtime() {
  # FP REGRESSION: content unchanged since review (matching content_sha) but
  # mtime bumped (checkout/cherry-pick). Old mtime>reviewed logic blocked;
  # content_sha match must ALLOW.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Reviewed content" > "$spec_file"
  local sha; sha=$(_sr1b_sha "$spec_file")

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-01-01T00:00:00"
    echo "content_sha=$sha"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"   # mtime > reviewed

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "content_sha match must allow despite bumped mtime (FP regression)"
}

test_orphan_content_sha_mismatch_blocks() {
  # content changed after review (stored sha != current) → stale → BLOCK,
  # even when mtime would let it pass under the old logic (reviewed in future).
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# v1 reviewed" > "$spec_file"
  local sha; sha=$(_sr1b_sha "$spec_file")
  echo "# v2 unreviewed change" > "$spec_file"   # content now differs from stored sha

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2027-01-01T00:00:00"   # future → old mtime logic would ALLOW
    echo "content_sha=$sha"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "content_sha mismatch must block (content changed after review)"
}

# --- TIER 2: retrospective/healer marker git committer-time fallback ---

test_orphan_retro_clean_checkout_allows() {
  # retro marker, no content_sha, spec committed BEFORE review, clean tree,
  # mtime bumped > reviewed. Old logic blocked; commit_epoch <= reviewed allows.
  seed_dod "dod-2026-04-13-test.md"
  _sr1b_git_init
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# shipped content" > "$spec_file"
  git -C "$SANDBOX" add specs/api-design.md
  GIT_AUTHOR_DATE="2025-06-01 00:00:00 +0000" GIT_COMMITTER_DATE="2025-06-01 00:00:00 +0000" \
    git -C "$SANDBOX" commit -q -m "ship spec" 2>/dev/null

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=retrospective-shipped-v1.0.0"
    echo "reviewed=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"   # mtime > reviewed (old logic would block)

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "retro marker + clean checkout (commit<=reviewed) must allow"
}

test_orphan_retro_dirty_blocks() {
  # retro marker, spec has uncommitted working-tree change → can't prove
  # freshness → BLOCK (FN guard). reviewed in future so old mtime logic allows.
  seed_dod "dod-2026-04-13-test.md"
  _sr1b_git_init
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# shipped content" > "$spec_file"
  git -C "$SANDBOX" add specs/api-design.md
  GIT_AUTHOR_DATE="2025-06-01 00:00:00 +0000" GIT_COMMITTER_DATE="2025-06-01 00:00:00 +0000" \
    git -C "$SANDBOX" commit -q -m "ship spec" 2>/dev/null
  echo "# uncommitted edit" >> "$spec_file"   # dirty

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=retrospective-shipped-v1.0.0"
    echo "reviewed=2027-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "retro marker + dirty working tree must block"
}

test_orphan_retro_commit_after_review_blocks() {
  # retro marker, clean, but spec committed AFTER review → genuine stale → BLOCK.
  # mtime set below reviewed so old logic would allow.
  seed_dod "dod-2026-04-13-test.md"
  _sr1b_git_init
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# edited then committed after review" > "$spec_file"
  git -C "$SANDBOX" add specs/api-design.md
  GIT_AUTHOR_DATE="2026-06-01 00:00:00 +0000" GIT_COMMITTER_DATE="2026-06-01 00:00:00 +0000" \
    git -C "$SANDBOX" commit -q -m "post-review edit" 2>/dev/null

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=retrospective-shipped-v1.0.0"
    echo "reviewed=2026-05-15T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-10"   # mtime < reviewed (old logic would allow)

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "retro marker + commit after review must block"
}

test_orphan_retro_untracked_blocks() {
  # retro marker but spec is untracked in the repo → can't verify via git → fail-closed BLOCK.
  seed_dod "dod-2026-04-13-test.md"
  _sr1b_git_init
  echo "seed" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  GIT_AUTHOR_DATE="2025-06-01 00:00:00 +0000" GIT_COMMITTER_DATE="2025-06-01 00:00:00 +0000" \
    git -C "$SANDBOX" commit -q -m "init" 2>/dev/null   # HEAD exists
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# untracked spec" > "$spec_file"   # NOT git-added

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=retrospective-shipped-v1.0.0"
    echo "reviewed=2027-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "retro marker + untracked spec must fail-closed (block)"
}

# --- TIER 3: mtime fallback preserved (non-retro / non-git) ---

test_orphan_non_retro_mtime_block_preserved() {
  # non-retro marker, non-git sandbox, content_sha absent, mtime > reviewed → BLOCK (current behavior).
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# spec" > "$spec_file"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"   # mtime > reviewed

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "non-retro contentless orphan must keep mtime-block behavior"
}

test_orphan_non_retro_mtime_allow_preserved() {
  # non-retro marker, non-git, content_sha absent, mtime <= reviewed → ALLOW (current behavior).
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# spec" > "$spec_file"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash; hash=$(_sr1b_orphan_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2027-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"
  set_file_mtime "specs/api-design.md" "2026-05-01"   # mtime < reviewed

  local input='{"tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"}, "tool_result": {}}'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "non-retro contentless orphan must keep mtime-allow behavior"
}

# =================================================================
# M1 — .skip-spec-gate ONE-SHOT CONSUMPTION + fail-closed
#
# Bug: the spec gate skipped its whole body when .skip-spec-gate existed but
# never removed the marker (no rm -f), so a "one-shot" bypass became a permanent
# off-switch (contrast .skip-stop-gate which is consumed on match). Fix: consume
# the marker (rm -f) BEFORE skipping, verify removal, and fail-closed (run the
# gate normally) if removal can't be proven.
# =================================================================

test_skip_spec_gate_consumed_after_one_edit() {
  # Case A: .skip-spec-gate + unreviewed spec (pending, no reviewed).
  # ① first source edit allowed (exit 0) AND the marker is deleted;
  # ② a second edit under the same unreviewed-spec state is blocked (exit 2).
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  touch "$SANDBOX/trail/dod/.skip-spec-gate"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  # ① first edit: bypass applies → allowed, marker consumed.
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "first edit with .skip-spec-gate should be allowed"
  # `! -e` (not `! -f`): proof must reject ANY remaining path type, matching the
  # hook's fail-closed proof.
  [ ! -e "$SANDBOX/trail/dod/.skip-spec-gate" ] || fail "marker must be consumed (removed) after first edit"
  # honest-audit: the bypass log records a real "consumed" outcome.
  assert_file_contains "trail/incidents/auto-mode-bypass.log" "skip-spec-gate consumed"

  # ② second edit: marker gone, unreviewed spec still present → blocked.
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "second edit must be blocked (one-shot bypass already consumed)"
}

test_skip_spec_gate_fail_closed_when_unremovable() {
  # Case B: marker can't be removed (made a non-empty directory so `rm -f`
  # fails) + unreviewed spec → fail-closed: gate runs normally and blocks.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  touch "$SANDBOX/specs/api-design.md"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(printf '%s' "$SANDBOX/specs/api-design.md" | shasum 2>/dev/null | cut -c1-16 || printf 'abc123def456')
  {
    echo "path=$SANDBOX/specs/api-design.md"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"

  # Make .skip-spec-gate a non-empty directory → `rm -f` (no -r) cannot remove it.
  mkdir -p "$SANDBOX/trail/dod/.skip-spec-gate/keep"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'

  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "must fail-closed (block) when .skip-spec-gate cannot be removed"
  # honest-audit: a fail-closed path must NOT claim "consumed"; it records the
  # consume_failed outcome instead (codex R1 Medium).
  assert_file_contains "trail/incidents/auto-mode-bypass.log" "consume_failed"
  assert_file_not_contains "trail/incidents/auto-mode-bypass.log" "skip-spec-gate consumed"
}

# =================================================================
# M4 — spec-review GENERATOR fail-open conservative marker
#
# Bug (M4): post-edit-spec-review-gate.sh has THREE fail-open paths that
# `exit 0` silently when it cannot resolve python / parse JSON:
#   (1) non-cache python unresolved (L34-38)
#   (2) JSON parse failure          (L57-60)
#   (3) cache-path python unresolved (L71-78)
# A silent skip means an unreviewed spec edit produces NO .pending marker,
# so the next source edit is not blocked (fail-open). Fix (routing pattern):
# each fail-open path drops a generic conservative marker
# (trail/dod/.spec-review-gen-failed) recording cause=, and the success path
# auto-heals it (rm -f). pre-edit-dod-gate.sh glob-blocks on the marker, with
# a one-shot consume-on-use bypass (trail/dod/.skip-spec-gen-gate).
# =================================================================

# Marker / bypass token contract (spec §6.4 / plan Task 2.1-2.3).
M4_GEN_MARKER="trail/dod/.spec-review-gen-failed"
M4_BYPASS_MARKER="trail/dod/.skip-spec-gen-gate"

# Run the post-edit hook with a curated PATH that hides python entirely, so
# resolve_python fails (rc=10). Mirrors run_hook but lets us shadow PATH for
# the child only, leaving the harness shell's PATH intact.
_m4_run_post_edit_no_python() {
  # $1=stdin JSON. Extra env (e.g. cache vars) passed via the caller's env.
  local stdin_json="$1"
  local tmp_out tmp_err curated tool src
  curated=$(mktemp -d "/tmp/m4-nopy-XXXXXX")
  # Symlink the coreutils the hook + python-runner.sh need, but NO python*.
  for tool in uname tr mktemp cat chmod cp rm grep printf awk sed \
              head tail cut env dirname basename find ls touch mv \
              date readlink realpath bash sh sleep sort wc shasum sha1sum; do
    src=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$curated/$tool"
  done
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  printf '%s' "$stdin_json" | \
    PATH="$curated" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    bash "$SANDBOX/.claude/hooks/post-edit-spec-review-gate.sh" \
    > "$tmp_out" 2> "$tmp_err"
  HOOK_EXIT=$?
  HOOK_STDOUT=$(cat "$tmp_out"); HOOK_STDERR=$(cat "$tmp_err")
  rm -f "$tmp_out" "$tmp_err"; rm -rf "$curated"
  return 0
}

test_m4_noncache_python_unresolved_creates_marker() {
  # Path (1): non-cache + python missing → resolve_python fails → must drop
  # the conservative marker, then exit 0 (silent — does not revert the write).
  seed_dod "dod-2026-04-13-test.md"
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/specs/api-design.md"},
    "tool_result": {}
  }'
  _m4_run_post_edit_no_python "$input"
  [ "$HOOK_EXIT" -eq 0 ] || fail "post-edit must exit 0 on python-unresolved (silent)"
  assert_file_exists "$M4_GEN_MARKER"
  assert_file_contains "$M4_GEN_MARKER" "cause=noncache-python"
}

test_m4_json_parse_failure_creates_marker() {
  # Path (2): python present but extract-hook-json.py exits non-zero → JSON
  # parse failure branch → conservative marker + exit 0.
  seed_dod "dod-2026-04-13-test.md"
  # Replace the sandbox extractor with a stub that always fails.
  cat > "$SANDBOX/.claude/hooks/lib/extract-hook-json.py" <<'PYEOF'
import sys
sys.exit(3)
PYEOF
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/specs/api-design.md"},
    "tool_result": {}
  }'
  run_hook "post-edit-spec-review-gate.sh" "$input"
  assert_exit 0 "post-edit must exit 0 on JSON parse failure (silent)"
  assert_file_exists "$M4_GEN_MARKER"
  assert_file_contains "$M4_GEN_MARKER" "cause=json-parse"
}

test_m4_cache_path_python_unresolved_creates_marker() {
  # Path (3): cache active (FILE_PATHS supplied) but python missing so the
  # cache-path resolve_python (for path normalize) fails → conservative
  # marker + exit 0.
  seed_dod "dod-2026-04-13-test.md"
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/specs/api-design.md"},
    "tool_result": {}
  }'
  local tmp_out tmp_err curated tool src input_file
  curated=$(mktemp -d "/tmp/m4-nopy-XXXXXX")
  for tool in uname tr mktemp cat chmod cp rm grep printf awk sed \
              head tail cut env dirname basename find ls touch mv \
              date readlink realpath bash sh sleep sort wc shasum sha1sum; do
    src=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$curated/$tool"
  done
  input_file=$(mktemp)
  printf '%s' "$input" > "$input_file"
  tmp_out=$(mktemp); tmp_err=$(mktemp)
  PATH="$curated" REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
    REIN_HOOK_INPUT_CACHE=1 \
    REIN_HOOK_INPUT_FILE="$input_file" \
    REIN_HOOK_FILE_PATHS="$SANDBOX/specs/api-design.md" \
    REIN_HOOK_FILE_PATH="$SANDBOX/specs/api-design.md" \
    bash "$SANDBOX/.claude/hooks/post-edit-spec-review-gate.sh" \
    < /dev/null > "$tmp_out" 2> "$tmp_err"
  HOOK_EXIT=$?
  rm -f "$tmp_out" "$tmp_err" "$input_file"; rm -rf "$curated"
  [ "$HOOK_EXIT" -eq 0 ] || fail "cache-path python-unresolved must exit 0 (silent)"
  assert_file_exists "$M4_GEN_MARKER"
  assert_file_contains "$M4_GEN_MARKER" "cause=cache-python"
}

test_m4_success_path_autoheals_marker() {
  # Normal input (python OK, JSON OK) → no marker created, AND any pre-existing
  # conservative marker is auto-healed (rm -f), mirroring routing-check.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec" > "$spec_file"
  # Pre-seed a stale conservative marker from an earlier failed run.
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=noncache-python\ncreated=2026-01-01T00:00:00Z\n' \
    > "$SANDBOX/$M4_GEN_MARKER"

  local input='{
    "tool_input": {"file_path": "'$spec_file'"},
    "tool_result": {}
  }'
  run_hook "post-edit-spec-review-gate.sh" "$input"
  assert_exit 0 "post-edit must succeed on normal input"
  assert_file_missing "$M4_GEN_MARKER"
}

test_m4_non_spec_edit_does_not_autoheal_marker() {
  # codex integration-review R1 High regression: a successful NON-canonical edit
  # (e.g. a source file allowed through by a .skip-spec-gen-gate bypass) must NOT
  # auto-heal the conservative marker — else the spec missed during the failure
  # window stays untracked and M4 fail-open reopens. Auto-heal is narrowed to
  # canonical-spec reprocessing only.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=noncache-python\ncreated=2026-01-01T00:00:00Z\n' \
    > "$SANDBOX/$M4_GEN_MARKER"

  # Non-canonical source file, python OK, JSON OK → producer succeeds but no
  # canonical spec is processed.
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  run_hook "post-edit-spec-review-gate.sh" "$input"
  assert_exit 0 "post-edit must succeed on a non-spec edit"
  assert_file_exists "$M4_GEN_MARKER"  # marker must persist (not auto-healed)
}

# =================================================================
# M4 — spec-review CONSUMER glob-block + one-shot bypass consume
# =================================================================

test_m4_consumer_blocks_when_marker_present() {
  # Conservative marker present → next source edit blocked (exit 2).
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=json-parse\ncreated=2026-06-16T00:00:00Z\n' \
    > "$SANDBOX/$M4_GEN_MARKER"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "should block when spec-review-gen-failed marker present"
}

test_m4_consumer_allows_when_marker_absent() {
  # No conservative marker → edit allowed (no false block).
  seed_dod "dod-2026-04-13-test.md"
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "should allow when no spec-review-gen-failed marker"
}

test_m4_bypass_consumed_after_one_edit() {
  # Conservative marker + bypass marker → ① first edit allowed AND bypass
  # consumed; ② second edit (bypass gone, marker still present) → re-blocked.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=noncache-python\ncreated=2026-06-16T00:00:00Z\n' \
    > "$SANDBOX/$M4_GEN_MARKER"
  printf 'reason=manual override\n' > "$SANDBOX/$M4_BYPASS_MARKER"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  # ① bypass applies → allowed, bypass consumed.
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "first edit with .skip-spec-gen-gate should be allowed"
  [ ! -e "$SANDBOX/$M4_BYPASS_MARKER" ] || fail "bypass marker must be consumed after first edit"
  # ② bypass gone, conservative marker remains → re-blocked.
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "second edit must be re-blocked (one-shot bypass consumed)"
}

test_m4_bypass_fail_closed_when_unremovable() {
  # 통합 보안리뷰 INFO-1: bypass marker 가 제거 불가(비어있지 않은 디렉토리)면
  # rm -f 가 실패 → 제거 증명(`[ ! -e ]`) 불가 → fail-closed(차단). M1 패턴 일관.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=json-parse\ncreated=2026-06-16T00:00:00Z\n' > "$SANDBOX/$M4_GEN_MARKER"
  # bypass 를 비어있지 않은 디렉토리로 → `rm -f`(no -r) 가 제거 못 함.
  mkdir -p "$SANDBOX/$M4_BYPASS_MARKER/keep"
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "must fail-closed (block) when bypass marker cannot be removed"
}

test_m4_bypass_reason_sanitized_in_stderr() {
  # 통합 보안리뷰 INFO-2: bypass reason 의 제어문자(터미널 이스케이프)는 stderr
  # echo 전에 제거돼야 한다. 출력 가능한 텍스트는 보존.
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/trail/dod"
  printf 'cause=json-parse\ncreated=2026-06-16T00:00:00Z\n' > "$SANDBOX/$M4_GEN_MARKER"
  # reason 에 ESC(\033) 제어문자 주입.
  printf 'reason=evil\033[31mRED\n' > "$SANDBOX/$M4_BYPASS_MARKER"
  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  local err
  err=$(REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" 2>&1 >/dev/null)
  if printf '%s' "$err" | LC_ALL=C grep -q "$(printf '\033')"; then
    fail "ESC control char must be stripped from bypass reason echo"
  fi
  printf '%s' "$err" | grep -q "evil" || fail "sanitized reason should retain printable text"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_canonical_path_docs_specs post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_docs_plans post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_specs_root post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_path_plans_root post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_non_canonical_src_file post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_non_canonical_readme post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_deeply_nested_specs post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_canonical_deeply_nested_plans post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_false_positive_specs_in_filename post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_false_positive_plans_in_dir post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_gate_blocks_unreviewed_spec post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_allows_reviewed_spec post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_ignores_deleted_spec post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_respects_bypass_file post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_no_spec_reviews_dir post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_multiple_unreviewed_specs post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_post_edit_hook_hash_consistency post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_multiedit_extracts_all_files post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_multiedit_deduplicates_files post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

run_test test_helper_marks_spec_reviewed post-edit-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh
run_test test_helper_normalizes_relative_paths post-edit-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh

run_test test_post_edit_removes_stale_reviewed_on_respec post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_blocks_stale_reviewed_when_pending_newer post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_allows_when_reviewed_fresher_than_pending post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_blocks_when_reviewed_timestamp_missing post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_gate_blocks_when_reviewed_timestamp_garbled post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_respec_after_review_blocks_source_edit post-edit-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh

# Writer content_sha anchor
run_test test_helper_writes_content_sha post-edit-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh
run_test test_helper_fails_on_unhashable_spec post-edit-spec-review-gate.sh pre-edit-dod-gate.sh rein-mark-spec-reviewed.sh

# SR-1.b orphan backstop — content-based staleness (mtime FP fix)
run_test test_orphan_content_sha_match_allows_despite_mtime post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_content_sha_mismatch_blocks post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_retro_clean_checkout_allows post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_retro_dirty_blocks post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_retro_commit_after_review_blocks post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_retro_untracked_blocks post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_non_retro_mtime_block_preserved post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_orphan_non_retro_mtime_allow_preserved post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

# M1 — .skip-spec-gate one-shot consumption + fail-closed
run_test test_skip_spec_gate_consumed_after_one_edit post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_skip_spec_gate_fail_closed_when_unremovable post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

# M4 — generator fail-open conservative marker (3 paths + auto-heal)
run_test test_m4_noncache_python_unresolved_creates_marker post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_json_parse_failure_creates_marker post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_cache_path_python_unresolved_creates_marker post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_success_path_autoheals_marker post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_non_spec_edit_does_not_autoheal_marker post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

# M4 — consumer glob-block + one-shot bypass consume
run_test test_m4_consumer_blocks_when_marker_present post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_consumer_allows_when_marker_absent post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_bypass_consumed_after_one_edit post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_bypass_fail_closed_when_unremovable post-edit-spec-review-gate.sh pre-edit-dod-gate.sh
run_test test_m4_bypass_reason_sanitized_in_stderr post-edit-spec-review-gate.sh pre-edit-dod-gate.sh

summary
