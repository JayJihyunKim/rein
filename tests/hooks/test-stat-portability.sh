#!/bin/bash
# tests/hooks/test-stat-portability.sh
#
# Regression + unit tests for the cross-platform shell helpers that
# underpin rein's hook suite. Target: `.claude/hooks/lib/portable.sh`.
#
# Background:
#   Earlier versions of the hooks used `stat -f %m FILE || stat -c %Y FILE`
#   and `stat -f %z FILE || stat -c %s FILE` chains. On Linux, `stat -f`
#   is NOT an error — it prints filesystem info and exits 0, which poisoned
#   downstream arithmetic and silently broke the hooks for every non-macOS
#   user.
#
#   The helpers now live in `.claude/hooks/lib/portable.sh` and dispatch
#   via `uname` explicitly. This test sources that file and exercises each
#   function, plus grep-guards to prevent the legacy chains from creeping
#   back into any hook.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/plugins/rein-core/hooks"
PORTABLE_LIB="$HOOKS_DIR/lib/portable.sh"

if [ ! -f "$PORTABLE_LIB" ]; then
  echo "FATAL: $PORTABLE_LIB not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$PORTABLE_LIB"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

begin() {
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $1"
}

end() {
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
}

make_tmp() {
  # mktemp wrapper that fails loudly instead of silently.
  local t
  t=$(mktemp 2>/dev/null) || { fail "mktemp failed"; return 1; }
  if [ ! -f "$t" ]; then
    fail "mktemp returned missing path: $t"
    return 1
  fi
  printf '%s\n' "$t"
}

# ============================================================
# Test 1: buggy `stat -f %m ... || stat -c %Y ...` chain is gone
# ============================================================
test_no_buggy_mtime_chain() {
  begin "test_no_buggy_mtime_chain"
  # Scan every .sh under .claude/hooks (including lib/) — the chain must
  # not reappear anywhere, even inside the portable helper itself.
  while IFS= read -r path; do
    if grep -qE 'stat -f %m .* \|\| stat -c %Y' "$path"; then
      fail "buggy stat -f %m / stat -c %Y chain still present in ${path#"$PROJECT_DIR/"}"
    fi
  done < <(find "$HOOKS_DIR" -type f -name '*.sh')
  end
}

# ============================================================
# Test 2: buggy `stat -f %z ... || stat -c %s ...` chain is gone
# (size variant of the same portability bug, reported 2026-04-20 on Linux)
# ============================================================
test_no_buggy_stat_size_chain() {
  begin "test_no_buggy_stat_size_chain"
  while IFS= read -r path; do
    if grep -qE 'stat -f %z .* \|\| stat -c %s' "$path"; then
      fail "buggy stat -f %z / stat -c %s chain still present in ${path#"$PROJECT_DIR/"}"
    fi
  done < <(find "$HOOKS_DIR" -type f -name '*.sh')
  end
}

# ============================================================
# Test 3: portable_stat_size returns real byte count
# ============================================================
test_portable_stat_size_valid_file_returns_bytes() {
  begin "test_portable_stat_size_valid_file_returns_bytes"
  local tmp got
  tmp=$(make_tmp) || return
  # Arrange: write exactly 42 bytes
  printf '%42s' '' > "$tmp"
  # Act
  got=$(portable_stat_size "$tmp")
  # Assert
  case "$got" in
    ''|*[!0-9]*) fail "not numeric: '$got'" ;;
  esac
  if [ "$got" != "42" ]; then
    fail "expected 42, got '$got'"
  fi
  rm -f "$tmp"
  end
}

test_portable_stat_size_missing_file_returns_zero() {
  begin "test_portable_stat_size_missing_file_returns_zero"
  local got
  got=$(portable_stat_size "/nonexistent-rein-$(date +%s)-$$")
  if [ "$got" != "0" ]; then
    fail "missing file should return 0, got '$got'"
  fi
  end
}

test_portable_stat_size_arithmetic_safe() {
  begin "test_portable_stat_size_arithmetic_safe"
  # Mirror the real call site inside `$(( USED_BYTES + sz ))`.
  local tmp sz used total
  tmp=$(make_tmp) || return
  printf 'hello' > "$tmp"
  used=100
  sz=$(portable_stat_size "$tmp")
  if ! total=$(( used + sz )) 2>/dev/null; then
    fail "arithmetic with portable_stat_size failed"
  fi
  if [ "$total" -ne 105 ]; then
    fail "expected 105, got '$total'"
  fi
  sz=$(portable_stat_size "/nonexistent-rein-$(date +%s)-$$")
  if ! total=$(( used + sz )) 2>/dev/null; then
    fail "arithmetic with missing-file portable_stat_size failed"
  fi
  if [ "$total" -ne 100 ]; then
    fail "expected 100 for missing file, got '$total'"
  fi
  rm -f "$tmp"
  end
}

# ============================================================
# Test 4: portable_mtime_epoch returns epoch seconds
# ============================================================
test_portable_mtime_epoch_valid_file_returns_recent_epoch() {
  begin "test_portable_mtime_epoch_valid_file_returns_recent_epoch"
  local tmp now got delta
  tmp=$(make_tmp) || return
  now=$(date +%s)
  got=$(portable_mtime_epoch "$tmp")
  case "$got" in
    ''|*[!0-9]*) fail "not numeric: '$got'" ;;
  esac
  delta=$(( now - got ))
  [ "$delta" -lt 0 ] && delta=$(( -delta ))
  if [ "$delta" -gt 60 ]; then
    fail "mtime delta too large: ${delta}s"
  fi
  rm -f "$tmp"
  end
}

test_portable_mtime_epoch_missing_file_returns_zero() {
  begin "test_portable_mtime_epoch_missing_file_returns_zero"
  local got
  got=$(portable_mtime_epoch "/nonexistent-rein-$(date +%s)-$$")
  if [ "$got" != "0" ]; then
    fail "missing file should return 0, got '$got'"
  fi
  end
}

test_portable_mtime_epoch_arithmetic_safe() {
  begin "test_portable_mtime_epoch_arithmetic_safe"
  # Mirror pre-edit-dod-gate.sh: $(( $(date +%s) - $(portable_mtime_epoch "$CACHE") ))
  local tmp age
  tmp=$(make_tmp) || return
  if ! age=$(( $(date +%s) - $(portable_mtime_epoch "$tmp") )) 2>/dev/null; then
    fail "arithmetic failed for existing file"
  fi
  case "$age" in
    ''|*[!0-9-]*) fail "age not numeric: '$age'" ;;
  esac
  if ! age=$(( $(date +%s) - $(portable_mtime_epoch "/nonexistent-rein-$(date +%s)-$$") )) 2>/dev/null; then
    fail "arithmetic failed for missing file"
  fi
  rm -f "$tmp"
  end
}

# ============================================================
# Test 5: portable_mtime_date returns YYYY-MM-DD
# ============================================================
test_portable_mtime_date_valid_file_returns_ymd() {
  begin "test_portable_mtime_date_valid_file_returns_ymd"
  local tmp got
  tmp=$(make_tmp) || return
  got=$(portable_mtime_date "$tmp")
  if ! echo "$got" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    fail "did not return YYYY-MM-DD: '$got'"
  fi
  rm -f "$tmp"
  end
}

test_portable_mtime_date_missing_file_returns_empty() {
  begin "test_portable_mtime_date_missing_file_returns_empty"
  local got
  got=$(portable_mtime_date "/nonexistent-rein-$(date +%s)-$$")
  if [ -n "$got" ]; then
    fail "missing file should return empty, got '$got'"
  fi
  end
}

# ============================================================
# Test 6: portable_date_ymd_to_epoch converts string to epoch
# ============================================================
test_portable_date_ymd_to_epoch_known_date() {
  begin "test_portable_date_ymd_to_epoch_known_date"
  local got
  got=$(portable_date_ymd_to_epoch "2026-01-01")
  case "$got" in
    ''|*[!0-9]*) fail "not numeric: '$got'" ;;
  esac
  # 2026-01-01 midnight UTC = 1767225600; local TZ shifts by at most 24h.
  # Accept any value within ±1 day of UTC midnight (so CI TZ doesn't matter).
  if [ -n "$got" ] && [ "$got" -lt 1767139200 ]; then
    fail "epoch too small: '$got'"
  fi
  if [ -n "$got" ] && [ "$got" -gt 1767312000 ]; then
    fail "epoch too large: '$got'"
  fi
  end
}

test_portable_date_ymd_to_epoch_invalid_returns_empty() {
  begin "test_portable_date_ymd_to_epoch_invalid_returns_empty"
  local got
  got=$(portable_date_ymd_to_epoch "not-a-date")
  if [ -n "$got" ]; then
    fail "invalid date should return empty, got '$got'"
  fi
  end
}

# ============================================================
# Test 7: every hook that previously owned a portable helper
#         now sources portable.sh
# ============================================================
test_hooks_source_portable_lib() {
  begin "test_hooks_source_portable_lib"
  for f in pre-edit-dod-gate.sh pre-bash-safety-guard.sh pre-bash-test-commit-gate.sh trail-rotate.sh session-start-load-trail.sh stop-session-gate.sh; do
    local path="$HOOKS_DIR/$f"
    if [ ! -f "$path" ]; then
      fail "hook missing: $f"
      continue
    fi
    if ! grep -qE '\.\s+"\$SCRIPT_DIR/lib/portable\.sh"' "$path"; then
      fail "$f does not source lib/portable.sh"
    fi
  done
  end
}

# ============================================================
# Test 8: bash -n parse check on all hooks (including lib)
# ============================================================
test_parse_check() {
  begin "test_parse_check"
  while IFS= read -r path; do
    if ! bash -n "$path" 2>/dev/null; then
      fail "bash -n failed: ${path#"$PROJECT_DIR/"}"
    fi
  done < <(find "$HOOKS_DIR" -type f -name '*.sh')
  end
}

test_no_buggy_mtime_chain
test_no_buggy_stat_size_chain
test_portable_stat_size_valid_file_returns_bytes
test_portable_stat_size_missing_file_returns_zero
test_portable_stat_size_arithmetic_safe
test_portable_mtime_epoch_valid_file_returns_recent_epoch
test_portable_mtime_epoch_missing_file_returns_zero
test_portable_mtime_epoch_arithmetic_safe
test_portable_mtime_date_valid_file_returns_ymd
test_portable_mtime_date_missing_file_returns_empty
test_portable_date_ymd_to_epoch_known_date
test_portable_date_ymd_to_epoch_invalid_returns_empty
test_hooks_source_portable_lib
test_parse_check

echo ""
echo "================================"
echo "Tests run: $TEST_COUNT"
echo "Passed:    $((TEST_COUNT - FAIL_COUNT))"
echo "Failed:    $FAIL_COUNT"
echo "================================"
[ "$FAIL_COUNT" -eq 0 ]
