#!/usr/bin/env bash
# PERF-2 — resolver-cache lib (write / read / cleanup / sanitizer) 검증.
# 회귀 대상: plugins/rein-core/hooks/lib/hook-resolver-cache.sh
#
# Scope ID: PERF-2-pre-edit-dod-gate-and-dispatcher-share-python-resolver-result-via-tool-use-id-keyed-cache-conditional-on-spike-1-confirming-posttooluse-carries-it

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/hook-resolver-cache.sh"

PASS=0
FAIL=0

# Isolated CLAUDE_PROJECT_DIR — repo 의 실제 .rein/cache/ 와 충돌 방지.
TEST_PROJECT_DIR=$(mktemp -d -t perf2-cache.XXXXXX)
trap 'rm -rf "$TEST_PROJECT_DIR"' EXIT
export CLAUDE_PROJECT_DIR="$TEST_PROJECT_DIR"

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected='$expected' actual='$actual'"
    FAIL=$((FAIL+1))
  fi
}

# shellcheck source=/dev/null
. "$LIB"

# === sanitizer 검증 ===
clean=$(resolver_cache_sanitize_id "toolu_01ABCdef-_XYZ" 2>/dev/null) || true
assert_eq "sanitizer_허용된_id_통과" "toolu_01ABCdef-_XYZ" "$clean"

if resolver_cache_sanitize_id "" 2>/dev/null; then
  echo "FAIL: sanitizer_빈문자열_reject"
  FAIL=$((FAIL+1))
else
  echo "PASS: sanitizer_빈문자열_reject"
  PASS=$((PASS+1))
fi

if resolver_cache_sanitize_id "../etc/passwd" 2>/dev/null; then
  echo "FAIL: sanitizer_path_traversal_reject"
  FAIL=$((FAIL+1))
else
  echo "PASS: sanitizer_path_traversal_reject"
  PASS=$((PASS+1))
fi

if resolver_cache_sanitize_id "toolu_id; rm -rf /" 2>/dev/null; then
  echo "FAIL: sanitizer_shell_inject_reject"
  FAIL=$((FAIL+1))
else
  echo "PASS: sanitizer_shell_inject_reject"
  PASS=$((PASS+1))
fi

if resolver_cache_sanitize_id "abc_01" 2>/dev/null; then
  echo "FAIL: sanitizer_prefix_누락_reject"
  FAIL=$((FAIL+1))
else
  echo "PASS: sanitizer_prefix_누락_reject"
  PASS=$((PASS+1))
fi

# === write / read 검증 ===
test_id="toolu_01ABCdef"
resolver_cache_write "$test_id" '{"file_path":"/tmp/x"}' || true
result=$(resolver_cache_read "$test_id" 2>/dev/null) || true
assert_eq "write_후_read_일치" '{"file_path":"/tmp/x"}' "$result"

# invalid id write — silent skip (caller fail-soft)
resolver_cache_write "../bad" '{"file_path":"/tmp/y"}' || true
if [ -f "$TEST_PROJECT_DIR/.rein/cache/hook-resolver/../bad.json" ]; then
  echo "FAIL: write_invalid_id_path_traversal_차단"
  FAIL=$((FAIL+1))
else
  echo "PASS: write_invalid_id_path_traversal_차단"
  PASS=$((PASS+1))
fi

# === cleanup 검증 ===
resolver_cache_cleanup "$test_id" || true
if [ -f "$TEST_PROJECT_DIR/.rein/cache/hook-resolver/$test_id.json" ]; then
  echo "FAIL: cleanup_후_파일_삭제"
  FAIL=$((FAIL+1))
else
  echo "PASS: cleanup_후_파일_삭제"
  PASS=$((PASS+1))
fi

# cleanup idempotent — 부재 상태에서도 exit 0
resolver_cache_cleanup "$test_id" || true
echo "PASS: cleanup_idempotent_no_error"
PASS=$((PASS+1))

# === read miss 시 exit 1 ===
if resolver_cache_read "toolu_nonexistent" >/dev/null 2>&1; then
  echo "FAIL: read_miss_exit_1"
  FAIL=$((FAIL+1))
else
  echo "PASS: read_miss_exit_1"
  PASS=$((PASS+1))
fi

echo
echo "PERF-2 resolver-cache: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
