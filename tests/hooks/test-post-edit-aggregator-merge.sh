#!/usr/bin/env bash
# Phase 2c HK-5 본격 — post-edit-aggregator merge + sub-hook output cache write.
#
# Scope ID: HK-5-posttoolbatch-hook-aggregates-parallel-subhook-result-files-into-single-trail-entry-conditional-on-hk-4-parallelization-landing
#
# Contract:
#   1. lib/hook-output-cache.sh 가 output_cache_dir/write/collect/cleanup 제공
#   2. sanitizer 는 hook-resolver-cache.sh 의 resolver_cache_sanitize_id 재사용
#   3. aggregator 가 stdin JSON 의 tool_use_id 를 추출하여 cache 의 sub-hook
#      envelope 들을 collect → additionalContext 만 추출 → "\n\n---\n\n"
#      separator 로 concat → 단일 PostToolUse envelope JSON 으로 stdout 출력
#   4. cache dir 은 aggregator cleanup 후 부재
#   5. no-id / empty cache 시 aggregator silent exit 0 (stdout empty)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/hook-output-cache.sh"
AGGREGATOR="$REPO_ROOT/plugins/rein-core/hooks/post-edit-aggregator.sh"

PASS=0
FAIL=0

TEST_PROJECT_DIR=$(mktemp -d -t aggr-merge.XXXXXX)
trap 'rm -rf "$TEST_PROJECT_DIR"' EXIT
export CLAUDE_PROJECT_DIR="$TEST_PROJECT_DIR"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core"

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

assert_eq() {
  local name="$1"; local expected="$2"; local actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"
  else fail "$name" "expected='$expected' actual='$actual'"; fi
}

assert_contains() {
  local name="$1"; local needle="$2"; local hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name" "'$needle' not in output"; fi
}

# === lib 존재 ===
if [ -f "$OUTPUT_LIB" ]; then pass "output_lib_exists"
else fail "output_lib_exists" "$OUTPUT_LIB 부재"; fi

# shellcheck source=/dev/null
. "$OUTPUT_LIB" 2>/dev/null || true

# === lib write — production 2개 sub-hook + 1 generic fixture (lib contract
# 은 arbitrary count 를 지원해야 함, test 가 3-entry merge 시나리오도 검증) ===
test_id="toolu_01ABCmergeTest"
output_cache_write "$test_id" "post-edit-design-plan-coverage-rule" \
  '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"DESIGN-PLAN body"}}' 2>/dev/null || true
output_cache_write "$test_id" "post-edit-routing-procedure-rule" \
  '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"ROUTING body"}}' 2>/dev/null || true
# Generic fixture (production sub-hook 이름 아님) — lib 의 arbitrary-N contract
# 검증용. envelope 1 개만 있어도 정상 merge 동작 + 향후 envelope-emitting
# sub-hook 추가 시 자동 포함되는지 확인.
output_cache_write "$test_id" "z-fixture-extra-envelope" \
  '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"EXTRA body"}}' 2>/dev/null || true

expected_dir="$TEST_PROJECT_DIR/.rein/cache/hook-output/$test_id"
if [ -d "$expected_dir" ]; then pass "output_cache_dir_created"
else fail "output_cache_dir_created" "$expected_dir 부재"; fi

# shellcheck disable=SC2012
count=$(ls "$expected_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
assert_eq "output_cache_3_files_written" "3" "$count"

# === sanitizer — invalid id reject (path traversal 방어) ===
# 정상 entry 는 test_id 의 dir 1개만 — invalid id (3건) 가 sanitizer 통과
# 했다면 새 dir 가 생성되어 count > 1 이 됨.
output_cache_write "invalid" "post-edit-x" "data" 2>/dev/null || true
output_cache_write "../etc/passwd" "post-edit-x" "data" 2>/dev/null || true
output_cache_write "" "post-edit-x" "data" 2>/dev/null || true

hook_output_root="$TEST_PROJECT_DIR/.rein/cache/hook-output"
# shellcheck disable=SC2012
entry_count=$(ls -1 "$hook_output_root" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "output_cache_sanitizer_rejects_invalid_id" "1" "$entry_count"

# === lib collect — 3 envelope JSON 을 NUL-delimited stream 으로 stdout ===
collected=$(output_cache_collect "$test_id" 2>/dev/null)
assert_contains "lib_collect_design_body" "DESIGN-PLAN body" "$collected"
assert_contains "lib_collect_routing_body" "ROUTING body" "$collected"
assert_contains "lib_collect_extra_body" "EXTRA body" "$collected"

# === aggregator merge — 3개 envelope 을 단일 envelope 으로 ===
STDIN_JSON='{"tool_use_id":"'"$test_id"'","hook_event_name":"PostToolUse","tool_name":"Edit"}'
merged=$(printf '%s' "$STDIN_JSON" | bash "$AGGREGATOR" 2>/dev/null)
agg_rc=$?

assert_eq "aggregator_exit_0_on_merge" "0" "$agg_rc"
assert_contains "aggregator_emits_single_envelope" '"hookSpecificOutput"' "$merged"
assert_contains "aggregator_emits_event_name" '"hookEventName":"PostToolUse"' "$merged"
assert_contains "aggregator_emits_additional_context" '"additionalContext"' "$merged"
assert_contains "aggregator_merges_design_body" "DESIGN-PLAN body" "$merged"
assert_contains "aggregator_merges_routing_body" "ROUTING body" "$merged"
assert_contains "aggregator_merges_extra_body" "EXTRA body" "$merged"

# separator 검증 — JSON 인코딩 후 "\n\n---\n\n" 가 본문에 존재 (escaped 형태로)
case "$merged" in
  *'\n\n---\n\n'*) pass "aggregator_uses_separator" ;;
  *) fail "aggregator_uses_separator" "separator pattern 부재" ;;
esac

# JSON valid 검증 — python3 로 parse
if printf '%s' "$merged" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
  pass "aggregator_emits_valid_json"
else
  fail "aggregator_emits_valid_json" "invalid JSON output"
fi

# === cleanup 후 cache dir 부재 ===
if [ ! -d "$expected_dir" ]; then pass "aggregator_cleanup_removes_dir"
else fail "aggregator_cleanup_removes_dir" "$expected_dir 잔존"; fi

# === aggregator no-id silent exit 0 ===
NO_ID_STDIN='{"hook_event_name":"PostToolUse","tool_name":"Edit"}'
no_id_out=$(printf '%s' "$NO_ID_STDIN" | bash "$AGGREGATOR" 2>/dev/null)
rc=$?
assert_eq "aggregator_no_id_exit_0" "0" "$rc"
assert_eq "aggregator_no_id_empty_stdout" "" "$no_id_out"

# === aggregator empty cache (id 있으나 cache 부재) silent exit 0 ===
EMPTY_ID="toolu_01ABCEmptyCache"
EMPTY_STDIN='{"tool_use_id":"'"$EMPTY_ID"'","hook_event_name":"PostToolUse"}'
empty_out=$(printf '%s' "$EMPTY_STDIN" | bash "$AGGREGATOR" 2>/dev/null)
rc=$?
assert_eq "aggregator_empty_cache_exit_0" "0" "$rc"
assert_eq "aggregator_empty_cache_empty_stdout" "" "$empty_out"

# === 2개 sub-hook source 의 cache write 패턴 검증 ===
# 전수 조사 (2026-05-20): stdout envelope emit 하는 sub-hook 은 2개만 —
# design-plan-coverage-rule, routing-procedure-rule. 나머지 6개는 stderr 만
# 또는 file system write — entry-level evaluation 영향 없음 (plan task 2b.3
# 의 "sub-hook 8개" 표현은 실제로 2개 한정).
for hook in design-plan-coverage-rule routing-procedure-rule; do
  src="$REPO_ROOT/plugins/rein-core/hooks/post-edit-${hook}.sh"
  if grep -q "output_cache_write.*post-edit-${hook}" "$src" 2>/dev/null; then
    pass "sub_hook_${hook}_calls_output_cache_write"
  else
    fail "sub_hook_${hook}_calls_output_cache_write" "$src 에 output_cache_write 호출 패턴 없음"
  fi
  if grep -q "hook-output-cache.sh" "$src" 2>/dev/null; then
    pass "sub_hook_${hook}_sources_output_cache_lib"
  else
    fail "sub_hook_${hook}_sources_output_cache_lib" "$src 에 lib source 없음"
  fi
done

# === 6개 non-envelope sub-hook 의 cache write 패턴 미존재 (정직성 검증) ===
# 본 cycle 의 scope 는 2개 production envelope-emitting sub-hook 한정. 나머지
# 6개 (hygiene/review-gate/spec-review-gate/plan-coverage/dod-routing-check 의
# stderr 출력 + index-sync-inbox 의 file-system write) 는 entry-level
# evaluation 영향 없음 — 향후 stderr 또는 file-write 통합이 필요하면 별 cycle.
for hook in hygiene review-gate index-sync-inbox spec-review-gate plan-coverage dod-routing-check; do
  src="$REPO_ROOT/plugins/rein-core/hooks/post-edit-${hook}.sh"
  if [ -f "$src" ]; then
    if grep -q "output_cache_write" "$src" 2>/dev/null; then
      fail "sub_hook_${hook}_no_output_cache_write" "본 cycle scope 밖인데 cache write 추가됨"
    else
      pass "sub_hook_${hook}_no_output_cache_write"
    fi
  fi
done

# === codex R1 High fix regression — CLAUDE_PROJECT_DIR 공백 path 안전성 ===
# 이전 collect 구현 (`for f in $(ls | sort)`) 은 word-splitting 으로 공백
# 포함 path 가 망가져서 sub-hook envelope 이 누락됐다. find -print0 + NUL-read
# 패턴이 회귀 방지.
SPACE_PROJECT_DIR=$(mktemp -d -t "aggr space.XXXXXX")
SPACE_ID="toolu_01ABCspaceTest"
SPACE_OUT_FILE=$(mktemp -t aggr-space-out.XXXXXX)
(
  export CLAUDE_PROJECT_DIR="$SPACE_PROJECT_DIR"
  # shellcheck source=/dev/null
  . "$OUTPUT_LIB" 2>/dev/null || true
  output_cache_write "$SPACE_ID" "post-edit-design-plan-coverage-rule" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"SPACE A"}}' 2>/dev/null || true
  output_cache_write "$SPACE_ID" "post-edit-routing-procedure-rule" \
    '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"SPACE B"}}' 2>/dev/null || true
  output_cache_collect "$SPACE_ID" 2>/dev/null
) > "$SPACE_OUT_FILE"

space_collected=$(cat "$SPACE_OUT_FILE")
assert_contains "collect_space_path_body_a" "SPACE A" "$space_collected"
assert_contains "collect_space_path_body_b" "SPACE B" "$space_collected"

rm -f "$SPACE_OUT_FILE"
rm -rf "$SPACE_PROJECT_DIR"

echo ""
echo "Summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
