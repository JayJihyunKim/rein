#!/usr/bin/env bash
# HK-5 — post-edit-aggregator 는 resolver-cache cleanup 을 호출하고 exit 0 으로
# 종료한다 (sub-hook stdout 처리는 Claude Code 의 entry-level 평가에 의존).
#
# Scope ID: HK-5-posttoolbatch-hook-aggregates-parallel-subhook-result-files-into-single-trail-entry-conditional-on-hk-4-parallelization-landing

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGGREGATOR="$REPO_ROOT/plugins/rein-core/hooks/post-edit-aggregator.sh"

PASS=0
FAIL=0

TEST_PROJECT_DIR=$(mktemp -d -t aggregator-test.XXXXXX)
trap 'rm -rf "$TEST_PROJECT_DIR"' EXIT
export CLAUDE_PROJECT_DIR="$TEST_PROJECT_DIR"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core"

# === exec bit ===
if [ -x "$AGGREGATOR" ]; then
  echo "PASS: aggregator_exec_bit"
  PASS=$((PASS+1))
else
  echo "FAIL: aggregator_exec_bit"
  FAIL=$((FAIL+1))
fi

# === bash -n ===
if bash -n "$AGGREGATOR" 2>/dev/null; then
  echo "PASS: aggregator_syntax"
  PASS=$((PASS+1))
else
  echo "FAIL: aggregator_syntax"
  FAIL=$((FAIL+1))
fi

# === cache cleanup 동작 ===
test_id="toolu_aggrTest123"
mkdir -p "$TEST_PROJECT_DIR/.rein/cache/hook-resolver"
printf '{"file_path":"/tmp/x"}' > "$TEST_PROJECT_DIR/.rein/cache/hook-resolver/$test_id.json"

# stdin 으로 PostToolUse 입력 모사
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_use_id\":\"$test_id\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}" | bash "$AGGREGATOR" >/dev/null 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "PASS: aggregator_exit_0"
  PASS=$((PASS+1))
else
  echo "FAIL: aggregator_exit_0 — actual rc=$rc"
  FAIL=$((FAIL+1))
fi

if [ ! -f "$TEST_PROJECT_DIR/.rein/cache/hook-resolver/$test_id.json" ]; then
  echo "PASS: aggregator_cache_cleanup"
  PASS=$((PASS+1))
else
  echo "FAIL: aggregator_cache_cleanup — file still exists"
  FAIL=$((FAIL+1))
fi

# === 빈 stdin 에서도 exit 0 ===
printf '' | bash "$AGGREGATOR" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: aggregator_empty_stdin_exit_0"
  PASS=$((PASS+1))
else
  echo "FAIL: aggregator_empty_stdin_exit_0 — rc=$rc"
  FAIL=$((FAIL+1))
fi

echo
echo "HK-5 aggregator: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
