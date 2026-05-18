#!/bin/bash
# tests/hooks/test-pre-bash-guard-command-anchoring.sh
#
# FU-4 regression suite — pre-bash-guard 의 명령 분류기 clause-앵커링.
#
# 검증 대상 (need-to-confirm.md FU-4):
#   pre-bash-guard 가 명령을 "테스트 실행 / 커밋 / .env 읽기 / 파괴적 git" 으로
#   분류할 때, 앵커 없는 substring 매칭이 키워드를 단순 "언급" 한 명령 (grep 인자,
#   npm pkg set 값, echo 텍스트) 까지 잡아 과다 차단했다. fix 는 분류기를
#   command clause 시작 위치 매칭 (command_invokes 헬퍼) 으로 전환한다.
#
# Contract:
#   - false-positive (키워드 언급) → 차단 안 함 (exit 0, stdout 비어 있음)
#   - true-positive (실제 invocation) → 기존대로 차단 (JSON deny)
#
# Sandbox: test-harness.sh 가 pre-bash-guard.sh + lib/ 를 sandbox 로 복사하고
#          run_hook 으로 합성 JSON 을 stdin 에 흘려넣어 exit/stdout/stderr 회수.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/test-harness.sh
source "$SCRIPT_DIR/lib/test-harness.sh"

# ============================================================
# assert helpers
# ============================================================

# assert_not_blocked LABEL
#   pre-bash-guard 가 명령을 통과시킨 상태: exit 0 + stdout 비어 있음.
#   (JSON deny 는 exit 0 + stdout JSON 이므로 exit code 만으로는 구분 불가.)
assert_not_blocked() {
  local label="$1"
  [ "$HOOK_EXIT" = "0" ] \
    || fail "$label: expected exit 0 (not blocked), got exit $HOOK_EXIT (stderr: $HOOK_STDERR)"
  [ -z "$HOOK_STDOUT" ] \
    || fail "$label: expected empty stdout (not blocked) but guard emitted: $HOOK_STDOUT"
}

# assert_json_deny REASON_CODE [LABEL]
#   pre-bash-guard 가 JSON deny 를 발행한 상태: exit 0 + stdout 에
#   permissionDecision=deny + reason_code.
assert_json_deny() {
  local reason_code="$1"
  local label="${2:-JSON deny $reason_code}"
  [ "$HOOK_EXIT" = "0" ] \
    || fail "$label: expected exit 0 (JSON deny), got exit $HOOK_EXIT"
  local decision
  decision=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])
except Exception:
    print("none")
' 2>/dev/null)
  [ "$decision" = "deny" ] \
    || fail "$label: permissionDecision not \"deny\" (got '$decision', stdout: $HOOK_STDOUT)"
  local pdr
  pdr=$(printf '%s' "$HOOK_STDOUT" | python3 -c '
import json,sys
try:
    print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])
except Exception:
    print("")
' 2>/dev/null)
  case "$pdr" in
    *"$reason_code"*) ;;
    *) fail "$label: reason_code '$reason_code' not in permissionDecisionReason: '$pdr'" ;;
  esac
}

# 리뷰 stamp gate 진입 조건: DoD 파일이 존재해야 check_review_stamp 가
# early-return 하지 않는다. stamp 는 일부러 seed 하지 않아 — 실제 test/commit
# invocation 이면 CODEX_STAMP_MISSING (P5) 가 발동한다.
_seed_dod_no_stamps() {
  seed_dod "dod-2026-05-18-anchor-test.md"
  seed_inbox "2026-05-18-anchor-test.md"
}

# ============================================================
# Suite A: 테스트 분류기 — false-positive 미차단
# ============================================================

# grep 인자에 들어간 "pytest" 는 테스트 실행이 아니다.
test_grep_pytest_mention_does_not_trigger_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"grep -n \"pytest\" tests/conftest.py"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "grep \"pytest\" 인자는 테스트 실행이 아님"
}

# npm pkg set 의 값에 들어간 "vitest" 는 테스트 실행이 아니다 (package.json 편집).
test_npm_pkg_set_test_script_does_not_trigger_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"npm pkg set scripts.test=vitest"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "npm pkg set 값의 vitest 는 테스트 실행이 아님"
}

# grep 인자에 들어간 "git commit" 은 커밋이 아니다.
test_grep_git_commit_mention_does_not_trigger_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"grep -rn \"git commit\" hooks/"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "grep \"git commit\" 인자는 커밋이 아님"
}

# ============================================================
# Suite B: 테스트/커밋 분류기 — true-positive 차단 (회귀 방지)
# ============================================================

# 실제 pytest invocation 은 여전히 리뷰 stamp gate 를 발동한다.
test_pytest_invocation_triggers_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"pytest tests/"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "실제 pytest 실행은 차단되어야 함"
}

# 선행 env 할당이 붙은 pytest invocation 도 발동한다.
test_env_prefixed_pytest_triggers_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"PYTHONPATH=src pytest tests/"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "env-prefix pytest 실행도 차단되어야 함"
}

# 복합 명령의 clause 로 들어간 git commit 은 여전히 발동한다.
test_compound_git_commit_triggers_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"cd src && git commit -m \"feat: x\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "&& 뒤 실제 git commit 은 차단되어야 함"
}

# ============================================================
# Suite C: .env 읽기 분류기 [P8]
# ============================================================

# .env.example 은 키만 담은 안전한 템플릿 — 읽기 차단 대상이 아니다.
test_cat_env_example_is_not_blocked() {
  local input='{"tool_input":{"command":"cat .env.example"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "cat .env.example 은 안전한 템플릿 — 차단 금지"
}

# echo 텍스트에 들어간 "cat .env" 는 실제 .env 읽기가 아니다.
test_echo_mentioning_env_read_is_not_blocked() {
  local input='{"tool_input":{"command":"echo \"use cat .env to inspect\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "echo 안의 cat .env 언급은 실제 읽기가 아님"
}

# 실제 .env 읽기는 여전히 차단한다.
test_cat_env_is_blocked() {
  local input='{"tool_input":{"command":"cat .env"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "실제 cat .env 는 차단되어야 함"
}

# .env.local 은 시크릿을 담는 실제 env 파일 — 여전히 차단한다.
test_cat_env_local_is_blocked() {
  local input='{"tool_input":{"command":"cat .env.local"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "cat .env.local 은 시크릿 파일 — 차단되어야 함"
}

# ============================================================
# Suite D: 파괴적 git 분류기 [P11]
# ============================================================

# echo 텍스트에 들어간 "git reset --hard" 는 실제 파괴적 명령이 아니다.
test_echo_mentioning_destructive_git_is_not_blocked() {
  local input='{"tool_input":{"command":"echo \"run git reset --hard to undo\""},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_not_blocked "echo 안의 git reset --hard 언급은 실제 명령이 아님"
}

# 실제 파괴적 git 명령은 여전히 차단(확인 요청)한다.
test_git_reset_hard_is_blocked() {
  local input='{"tool_input":{"command":"git reset --hard HEAD~1"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "DESTRUCTIVE_GIT_CONFIRM" "실제 git reset --hard 는 차단되어야 함"
}

# ============================================================
# Suite E: codex R1 fix — fail-closed .env + command wrapper
# ============================================================

# fail-closed: .env.secret 처럼 미등록 시크릿 변형도 차단된다 (allow-list 아님).
test_cat_env_secret_is_blocked() {
  local input='{"tool_input":{"command":"cat .env.secret"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "cat .env.secret 은 미등록 시크릿 변형 — fail-closed 차단"
}

# .envrc (direnv) 도 시크릿을 담을 수 있어 차단한다.
test_cat_envrc_is_blocked() {
  local input='{"tool_input":{"command":"cat .envrc"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "cat .envrc 은 시크릿 가능 — 차단"
}

# sudo 등 command wrapper 가 붙은 파괴적 git 도 차단한다.
test_sudo_wrapped_destructive_git_is_blocked() {
  local input='{"tool_input":{"command":"sudo git reset --hard HEAD~1"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "DESTRUCTIVE_GIT_CONFIRM" "sudo git reset --hard 도 파괴적 git — 차단"
}

# env wrapper 가 붙은 pytest invocation 도 리뷰 gate 를 발동한다.
test_env_wrapped_pytest_triggers_review_gate() {
  _seed_dod_no_stamps
  local input='{"tool_input":{"command":"env PYTHONPATH=src pytest tests/"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "CODEX_STAMP_MISSING" "env wrapper pytest 도 차단되어야 함"
}

# codex R2 — 안전 템플릿을 prefix 로만 가진 더 긴 파일명은 차단된다.
# .env.example.secret 은 .env.example 토큰이 아니라 별개의 시크릿 파일명.
test_cat_env_example_dot_secret_is_blocked() {
  local input='{"tool_input":{"command":"cat .env.example.secret"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "cat .env.example.secret 은 안전 토큰이 아님 — 차단"
}

# codex R2 — .env.examples (복수형) 는 안전 템플릿 .env.example 이 아니다.
test_cat_env_examples_plural_is_blocked() {
  local input='{"tool_input":{"command":"cat .env.examples"},"tool_result":{}}'
  run_hook "pre-bash-guard.sh" "$input"
  assert_json_deny "ENV_READ_BLOCKED" "cat .env.examples 는 안전 템플릿이 아님 — 차단"
}

main() {
  # Suite A — 분류기 false-positive 미차단
  run_test test_grep_pytest_mention_does_not_trigger_review_gate       pre-bash-guard.sh
  run_test test_npm_pkg_set_test_script_does_not_trigger_review_gate   pre-bash-guard.sh
  run_test test_grep_git_commit_mention_does_not_trigger_review_gate   pre-bash-guard.sh
  # Suite B — 테스트/커밋 true-positive 차단 (회귀 방지)
  run_test test_pytest_invocation_triggers_review_gate                 pre-bash-guard.sh
  run_test test_env_prefixed_pytest_triggers_review_gate               pre-bash-guard.sh
  run_test test_compound_git_commit_triggers_review_gate               pre-bash-guard.sh
  # Suite C — .env 읽기 분류기
  run_test test_cat_env_example_is_not_blocked                         pre-bash-guard.sh
  run_test test_echo_mentioning_env_read_is_not_blocked                pre-bash-guard.sh
  run_test test_cat_env_is_blocked                                     pre-bash-guard.sh
  run_test test_cat_env_local_is_blocked                               pre-bash-guard.sh
  # Suite D — 파괴적 git 분류기
  run_test test_echo_mentioning_destructive_git_is_not_blocked         pre-bash-guard.sh
  run_test test_git_reset_hard_is_blocked                              pre-bash-guard.sh
  # Suite E — codex R1 fix (fail-closed .env + command wrapper)
  run_test test_cat_env_secret_is_blocked                              pre-bash-guard.sh
  run_test test_cat_envrc_is_blocked                                   pre-bash-guard.sh
  run_test test_sudo_wrapped_destructive_git_is_blocked                pre-bash-guard.sh
  run_test test_env_wrapped_pytest_triggers_review_gate                pre-bash-guard.sh
  # Suite E2 — codex R2 fix (safe-template prefix must not fail open)
  run_test test_cat_env_example_dot_secret_is_blocked                  pre-bash-guard.sh
  run_test test_cat_env_examples_plural_is_blocked                     pre-bash-guard.sh
  summary
}

main "$@"
