#!/bin/bash
# tests/hooks/test-index-sync-inbox.sh
#
# Tests for post-edit-index-sync-inbox.sh.
#
# Contract:
#   - Only fires when file_path ends with trail/index.md
#   - If any today's inbox file already exists, leaves it alone
#   - Otherwise creates trail/inbox/YYYY-MM-DD-session.md with auto-generated body
#   - Always exits 0

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-harness.sh"

HOOK=post-edit-index-sync-inbox.sh
TODAY=$(date +%Y-%m-%d)

test_non_index_path_ignored() {
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/src/foo.ts"}}'
  run_hook "$HOOK" "$input"
  assert_exit 0 "non-index edit should exit 0"
  if ls "$SANDBOX/trail/inbox/${TODAY}"-*.md >/dev/null 2>&1; then
    fail "non-index edit should not create inbox file"
  fi
}

test_index_edit_creates_fallback_when_missing() {
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/trail/index.md"}}'
  run_hook "$HOOK" "$input"
  assert_exit 0 "index edit should exit 0"
  assert_file_exists "trail/inbox/${TODAY}-session.md"
  assert_file_contains "trail/inbox/${TODAY}-session.md" "자동 생성"
  assert_file_contains "trail/inbox/${TODAY}-session.md" "날짜: ${TODAY}"
  assert_file_contains "trail/inbox/${TODAY}-session.md" "유형: auto"
}

test_existing_manual_inbox_preserved() {
  seed_inbox "${TODAY}-manual-work.md" "# Manual work
MARKER_MANUAL_CONTENT"
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/trail/index.md"}}'
  run_hook "$HOOK" "$input"
  assert_exit 0 "should exit 0 when manual inbox present"
  assert_file_exists "trail/inbox/${TODAY}-manual-work.md"
  assert_file_contains "trail/inbox/${TODAY}-manual-work.md" "MARKER_MANUAL_CONTENT"
  assert_file_missing "trail/inbox/${TODAY}-session.md"
}

test_idempotent_no_overwrite() {
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/trail/index.md"}}'
  run_hook "$HOOK" "$input"
  assert_exit 0 "first run"
  assert_file_exists "trail/inbox/${TODAY}-session.md"
  echo "USER_EDITED_MARKER" >> "$SANDBOX/trail/inbox/${TODAY}-session.md"
  run_hook "$HOOK" "$input"
  assert_exit 0 "second run"
  assert_file_contains "trail/inbox/${TODAY}-session.md" "USER_EDITED_MARKER"
}

test_empty_stdin_is_safe() {
  run_hook "$HOOK" ''
  assert_exit 0 "empty stdin must not block"
  if ls "$SANDBOX/trail/inbox/${TODAY}"-*.md >/dev/null 2>&1; then
    fail "empty stdin should not create inbox file"
  fi
}

test_malformed_json_is_safe() {
  run_hook "$HOOK" 'not json'
  assert_exit 0 "malformed json must not block"
  if ls "$SANDBOX/trail/inbox/${TODAY}"-*.md >/dev/null 2>&1; then
    fail "malformed json should not create inbox file"
  fi
}

test_unrelated_md_path_ignored() {
  local input='{"tool_input":{"file_path":"'"$SANDBOX"'/docs/index.md"}}'
  run_hook "$HOOK" "$input"
  assert_exit 0
  if ls "$SANDBOX/trail/inbox/${TODAY}"-*.md >/dev/null 2>&1; then
    fail "non-trail index.md should not create inbox file"
  fi
}

run_test test_non_index_path_ignored                   "$HOOK"
run_test test_index_edit_creates_fallback_when_missing "$HOOK"
run_test test_existing_manual_inbox_preserved          "$HOOK"
run_test test_idempotent_no_overwrite                  "$HOOK"
run_test test_empty_stdin_is_safe                      "$HOOK"
run_test test_malformed_json_is_safe                   "$HOOK"
run_test test_unrelated_md_path_ignored                "$HOOK"

summary
