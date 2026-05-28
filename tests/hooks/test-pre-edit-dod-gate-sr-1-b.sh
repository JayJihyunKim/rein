#!/bin/bash
# tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh
# SR-1.b — pre-edit spec gate backstop for orphan .reviewed (without .pending).
#
# Bug class: SR-1 fix's backstop (a) only runs when a .pending marker exists.
# If post-edit-spec-review-gate.sh fails to fire (hooks disabled, external IDE
# write, git checkout restoring a spec, MultiEdit JSON parse failure → exit 0)
# the new .pending is never created. The old .reviewed lingers as an orphan
# and the spec gate silently passes — source edits proceed with unreviewed
# spec changes. SR-1 pre-existing trust boundary, not a new gap.
#
# Fix: extend pre-edit-dod-gate.sh spec gate to also iterate *.reviewed
# markers that have no matching .pending sibling. For each orphan, compare
# the spec file's mtime against the reviewed= timestamp. mtime > reviewed →
# stale → block. Missing/garbled reviewed= or unreadable mtime → fail-closed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-harness.sh"

# Compute the deterministic 16-char shasum hash the gate uses to key markers.
_sr1b_compute_hash() {
  local input="$1"
  printf '%s' "$input" | shasum 2>/dev/null | cut -c1-16
}

# F1 (RED→GREEN proof): orphan .reviewed + spec mtime newer than reviewed=
#   must be blocked. Pre-fix this falls through to "no .pending found" branch
#   and the source edit succeeds (bug). Post-fix the gate iterates orphan
#   .reviewed markers and blocks (exit 2).
test_orphan_reviewed_with_stale_spec_blocks() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec v2 (edited after review, no post-edit hook ran)" > "$spec_file"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_sr1b_compute_hash "$spec_file")
  # Only .reviewed exists (.pending was never created — hook missed the edit).
  # reviewed= is in the past; spec was edited just now → mtime > reviewed.
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  # Make spec mtime explicitly newer than 2026-01-01.
  touch -t 202606010000 "$spec_file" 2>/dev/null || touch -d "2026-06-01" "$spec_file" 2>/dev/null

  # Confirm there is no .pending sibling (orphan condition).
  [ ! -f "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending" ] || fail "test setup: .pending should not exist"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "orphan .reviewed + stale spec must block (post-edit hook missed; spec edited after review)"
}

# F2 (no regression): orphan .reviewed + spec mtime ≤ reviewed= → allow.
#   The review was performed AFTER the last spec edit (normal flow where
#   .pending was already cleared by mark-spec-reviewed and no new edit
#   happened). Must remain allowed.
test_orphan_reviewed_with_fresh_spec_allows() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec v1 (reviewed, untouched after review)" > "$spec_file"

  # Spec mtime is older than reviewed=.
  touch -t 202601010000 "$spec_file" 2>/dev/null || touch -d "2026-01-01" "$spec_file" 2>/dev/null

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_sr1b_compute_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "orphan .reviewed + fresh review must allow (spec was reviewed after its last edit)"
}

# F3 (fail-closed): orphan .reviewed without a valid reviewed= timestamp →
#   cannot prove freshness → block. Mirrors SR-1's strict-ISO-shape check.
test_orphan_reviewed_with_garbled_timestamp_fails_closed() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec" > "$spec_file"

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_sr1b_compute_hash "$spec_file")
  # Garbled reviewed= violates the ISO 8601 shape regex.
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=not-a-timestamp"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 2 ] || fail "orphan .reviewed with garbled timestamp must fail-closed (cannot prove freshness)"
}

# F4 (no regression): no .reviewed and no .pending → pre-existing behavior
#   (no spec review markers at all). Spec gate must remain permissive — this
#   is the "fresh repo / no spec yet reviewed" case.
test_no_markers_allows() {
  seed_dod "dod-2026-04-13-test.md"

  # Either .spec-reviews dir exists but is empty, or doesn't exist. Both
  # must allow.
  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "empty .spec-reviews/ must remain permissive"
}

# F5 (no regression): when both .pending and .reviewed coexist, the SR-1
#   branch handles freshness comparison and the new orphan branch must NOT
#   double-check (avoid duplicate work + ensure SR-1 semantics unchanged).
#   This fixture mirrors SR-1's test_gate_allows_when_reviewed_fresher_than_pending.
#
#   The fixture is deliberately constructed so the SR-1 vs orphan branches
#   would DISAGREE if the orphan branch ran: SR-1 compares created= vs
#   reviewed= (created < reviewed → allow), but the spec mtime is set
#   STRICTLY NEWER than reviewed= so the orphan branch (which compares spec
#   mtime to reviewed=) would block. Exit 0 therefore proves the orphan
#   branch is correctly skipped when .pending exists (codex R1 Medium fix —
#   prior version had mtime == reviewed which made the test pass even if
#   the orphan branch accidentally ran, since `-gt` would be false).
test_pending_plus_reviewed_uses_sr1_branch_only() {
  seed_dod "dod-2026-04-13-test.md"
  mkdir -p "$SANDBOX/specs"
  local spec_file="$SANDBOX/specs/api-design.md"
  echo "# Spec" > "$spec_file"

  # Spec mtime STRICTLY NEWER than reviewed=. NOTE: `touch -t` uses local
  # time but the gate compares against reviewed= as UTC (writer uses
  # `date -u`). We therefore set the spec ~1 month after reviewed= so the
  # offset gap is irrelevant in any time zone. If the orphan branch
  # accidentally ran, `spec_mtime_epoch -gt reviewed_epoch` would be true
  # → exit 2. The SR-1 branch (created= 2026-01-01 ≤ reviewed= 2026-06-01)
  # allows → exit 0. The skip-when-pending-exists guard is the only way
  # exit 0 survives both branches.
  touch -t 202607010000 "$spec_file" 2>/dev/null || touch -d "2026-07-01" "$spec_file" 2>/dev/null

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  local hash
  hash=$(_sr1b_compute_hash "$spec_file")
  {
    echo "path=$spec_file"
    echo "created=2026-01-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.pending"
  {
    echo "path=$spec_file"
    echo "reviewer=codex"
    echo "reviewed=2026-06-01T00:00:00"
  } > "$SANDBOX/trail/dod/.spec-reviews/${hash}.reviewed"

  local input='{
    "tool_input": {"file_path": "'$SANDBOX'/src/auth.ts"},
    "tool_result": {}
  }'
  REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" bash "$SANDBOX/.claude/hooks/pre-edit-dod-gate.sh" <<< "$input" > /dev/null 2>&1
  [ $? -eq 0 ] || fail "coexisting .pending+.reviewed must follow SR-1 branch (allow when created ≤ reviewed), not orphan branch (which would block since spec mtime > reviewed=)"
}

# =================================================================
# RUN ALL TESTS
# =================================================================

run_test test_orphan_reviewed_with_stale_spec_blocks pre-edit-dod-gate.sh
run_test test_orphan_reviewed_with_fresh_spec_allows pre-edit-dod-gate.sh
run_test test_orphan_reviewed_with_garbled_timestamp_fails_closed pre-edit-dod-gate.sh
run_test test_no_markers_allows pre-edit-dod-gate.sh
run_test test_pending_plus_reviewed_uses_sr1_branch_only pre-edit-dod-gate.sh

summary
