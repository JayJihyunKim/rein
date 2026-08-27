#!/bin/bash
# hooks/lib/code-review-gate.sh
#
# Code-review axis judgment (is the implementation-code review stamp present,
# fresh, and PASS) — originally extracted from pre-bash-test-commit-gate.sh's
# check_review_stamp() so the v2 governance runtime could swap the axis
# wholesale without touching the security-review axis (feature-builder-
# refactor task step 2 — 첫 전환 축(코드 리뷰) 분리).
#
# --- Phase 7 웨이브 3 ③-c (커밋 게이트 교대) 갱신 ---
#
# (구)pre-bash-test-commit-gate.sh 가 삭제되고 두 신설 훅으로 교대됐다.
# 이 파일의 v1 최종 판정 진입점이던 rein_check_code_review_stamp()(DOD_EXISTS
# 선행조건 + 구 pending 마커 신선도 비교 + P3/P4/P5/P5b v1 직접 판정 + 위임
# 오케스트레이션 전부)는 이 웨이브에서 제거됐다 — ③-b 가
# lib/active-task-gate.sh 의 rein_check_active_task() 에 적용한 것과 동일한
# 수술이다(그 파일의 "Phase 7 웨이브 3 ③-b 갱신" 절 참조, 같은 패턴).
#
# 이 파일은 이제 v2 전환확인 + 위임 하위 함수 두 개만 제공한다:
#   rein_code_review_authority_switched() — 전환 여부 확인
#   rein_code_review_delegate()           — 위임 실행
# 유일한 소비자는 신설 pre-bash-commit-review-gate.sh (③-c 로 새로 작성) —
# 그 훅이 이 두 함수만 직접 호출해 자신만의 판정 트리를 구성한다. v1
# 폴백은 이제 이 축에 존재하지 않는다 — 미전환/확인실패/위임FAIL 을 그
# 훅이 fail-closed 방향으로 직접 판정한다(lib/active-task-gate.sh 가 문서화한
# "의도된 방향 변화"와 동일 취지).
#
# 미전환("NOT_SWITCHED")과 확인 자체 실패("ERROR")를 구분하기 위해
# rein_code_review_authority_switched() 가 추가로 채우는 전역
# `rein_code_review_switch_check_kind` ("SWITCHED"|"NOT_SWITCHED"|"ERROR")는
# lib/active-task-gate.sh 의 동명 패턴(`rein_active_task_switch_check_kind`)과
# 바이트 수준으로 동일한 구조다 — 함수 자신의 반환값 계약(0=성공/전환됨,
# 1=그 외 전부)은 그대로 두고 이 전역만 부가한다. 오직 소비 훅만 이 전역을
# 읽는다.
#
# 남은 두 함수 자신의 로직은 이 교대로 1바이트도 바뀌지 않았다 — 아래
# 두 함수 정의는 여전히 MECHANICAL(전환 확인 + 위임 왕복, 판정하지 않음)
# 이다.
#
# Depends on ambient state already set by the sourcing hook (NOT sourced
# here, to avoid re-defining infra that must stay singly owned) — the two
# surviving functions only read:
#   $PROJECT_DIR    — v1 이 이미 확정한 프로젝트 루트.
#   $INPUT          — 원본 hook event JSON, 파싱 이전 그대로. 이 값을
#     `bin/rein hook`'s stdin 에 그대로 forward 한다(rein_code_review_
#     delegate()가 재조립·위조하지 않는다 — 그 함수 자신의 주석 참조).
#   $PYTHON_RUNNER  — resolve 된 python 인터프리터 배열.
# 제거된 rein_check_code_review_stamp() 가 쓰던 deny_emit()/log_block()/
# portable_mtime_epoch()/_parse_stamp_field()/_normalize_iso() 는 더 이상
# 이 파일의 의존이 아니다 — 그 함수와 함께 소멸했다(그 함수만이 유일한
# 소비자였다). lib/stamp-parse.sh 소싱도 같은 이유로 제거됐다 — 남은
# 두 함수 어느 쪽도 표식 필드를 파싱하지 않는다(그 파싱은 이제 판정
# 자체와 함께 v2 쪽에 있다).
#
# Usage:
#   . "$SCRIPT_DIR/lib/code-review-gate.sh"
#   if rein_code_review_authority_switched; then
#     rein_code_review_delegate
#     case "$rein_code_review_delegate_result" in
#       ALLOW) ... ;; DENY) ... "$rein_code_review_delegate_json" ... ;;
#       *) # FAIL ;;
#     esac
#   else
#     case "$rein_code_review_switch_check_kind" in
#       NOT_SWITCHED) ... ;; *) # ERROR ;;
#     esac
#   fi
#   # 전체 판정 트리는 이 파일의 유일한 소비자(pre-bash-commit-review-
#   # gate.sh) 자신의 헤더 참조 — 이 파일은 더 이상 스스로 exit 하거나
#   # deny_emit/log_block 을 호출하는 최종 판정 지점이 아니다.

if [ -n "${__REIN_CODE_REVIEW_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_CODE_REVIEW_GATE_LOADED=1

# self-location for _REIN_CRG_PKG_PARENT (below) — Phase 7 웨이브 3 ③-c 이후
# 이 변수의 유일한 용도다. (구)lib/stamp-parse.sh 소싱은 이 지점에서
# 제거됐다 — 남은 두 함수 어느 쪽도 _parse_stamp_field()/_normalize_iso()
# 를 쓰지 않는다(파일 상단 헤더 "Depends on" 절 참조).
_REIN_CRG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- v2 authority hand-off (Task 6.1 본작업 — code_review 축 전환) ---
#
# self-location: 이 파일 자신의 위치에서 rein 패키지의 부모 디렉토리를
# 구한다 — lib/shadow-capture.sh 의 _SHADOW_PKG_PARENT 와 정확히 동일한
# 원리다(어느 훅이 source 하든, 설치 방식(plugin tarball/dev repo)이
# 무엇이든 상대 위치로 항상 올바르게 찾는다 — CLAUDE_PLUGIN_ROOT 존재를
# 전제하지 않는다):
#   hooks/lib/code-review-gate.sh → (..) hooks → (..) <plugin root>
# <plugin root> 아래에 rein/engine/authority.py 가 있으면 그 패키지를
# 그대로 import 한다.
_REIN_CRG_PKG_PARENT="$(cd "$_REIN_CRG_LIB_DIR/../.." 2>/dev/null && pwd)" || _REIN_CRG_PKG_PARENT=""

# rein_code_review_authority_switched
#   v2 authority(rein.engine.authority.is_switched)에 code_review 축이
#   실제로 전환됐는지 질의한다.
#
#   이 함수는 스스로 "통과시킬지"를 결정하지 않는다 — 오직 "이 축을 v2
#   에 위임해도 되는가"만 답한다. 실제 판정은 이 함수가 성공을 반환한
#   뒤 호출자가 수행하는 위임 호출(rein_code_review_delegate(), 아래)의
#   몫이다. (사용자 결정 2026-08-18, "직접 위임" 구조 — 이전 구현은 이
#   지점에서 곧바로 통과시키는 "양보" 였으나, hooks.json 등록이 Phase 7
#   로 이연된 상태에서 그 방식은 v1 양보 후 v2 가 아직 실제로 아무것도
#   판정하지 않는 공백 창을 만든다는 리뷰 지적[High-1]을 받아 교체됐다.)
#
#   반환 0(성공) = 전환됨 — 호출자는 이 축을 v2 에 위임해야 한다(v2 가
#     이 축을 소유한다, spec §7 dual read "미전환 capability 는
#     authority 가 개입하지 않는다"의 대칭 — 전환된 capability 는 v1 이
#     직접 판정하지 않는다).
#   반환 1(실패) = "전환 안 됨" 과 "확인 자체가 불가능함"(파이썬 부재·
#     모듈 로드 실패·정책 파일 손상·예외 등)을 구분하지 않고 동일하게
#     취급한다 — 이것이 fail-closed 방향이다: 확인 불가를 "전환됨"으로
#     오인해 위임을 시도하면(그리고 위임 결과 해석까지 실패하면) 그 축의
#     판정이 통째로 사라질 위험이 있다. 반대로 확인 불가를 "전환 안 됨"
#     으로 취급하면 최악의 경우가 v1 이 계속 직접 판정하는 것뿐이다 —
#     항상 안전한 방향이다.
#
#   추가 출력 (Phase 7 웨이브 3 ③-c, pre-bash-commit-review-gate.sh 신설을
#   위한 최소 확장 — 동작 불변 계약, lib/active-task-gate.sh 의 동명 확장과
#   바이트 수준으로 동일한 패턴): 반환값 하나로는 "전환 안 됨"(문서화된
#   opt-out)과 "확인 자체가 불가능함"(fail-closed 대상)을 구분할 수 없다.
#   기존 반환값 계약은 손대지 않는다 — 대신 전역
#   `rein_code_review_switch_check_kind` 를 "SWITCHED" | "NOT_SWITCHED" |
#   "ERROR" 중 하나로 함께 채운다. 이 함수를 호출하는 소비 훅만 이 전역을
#   읽어 두 경우를 다르게 처리한다.
rein_code_review_authority_switched() {
  rein_code_review_switch_check_kind="ERROR"

  [ -n "$_REIN_CRG_PKG_PARENT" ] || return 1

  local -a _crg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _crg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _crg_py=(python3)
  else
    return 1
  fi

  local _crg_out
  _crg_out=$("${_crg_py[@]}" - "$_REIN_CRG_PKG_PARENT" "$PROJECT_DIR" <<'PY' 2>/dev/null
import sys


def _main():
    if len(sys.argv) < 3:
        print("ERROR")
        return
    package_parent, project_root = sys.argv[1], sys.argv[2]
    sys.path.insert(0, package_parent)
    try:
        from rein.engine.authority import is_switched
        switched = is_switched("code_review", project_root=project_root)
    except Exception:
        # 모듈 부재/정책 손상/미지 capability 등 사유 불문 — 호출자가
        # "확인 실패"로 균일하게 취급하도록 ERROR 로만 신호한다.
        print("ERROR")
        return
    print("SWITCHED" if switched else "NOT_SWITCHED")


_main()
PY
  ) || return 1

  case "$_crg_out" in
    SWITCHED)     rein_code_review_switch_check_kind="SWITCHED" ;;
    NOT_SWITCHED) rein_code_review_switch_check_kind="NOT_SWITCHED" ;;
    *)            rein_code_review_switch_check_kind="ERROR" ;;
  esac

  [ "$_crg_out" = "SWITCHED" ]
}

# REIN_CRG_DELEGATE_TIMEOUT_S — safety-net ceiling for the delegation
# subprocess call below. `bin/rein hook`'s own module docstring measures
# its cold-start overhead in the tens-of-ms range ("cold start 비용" 절) —
# this is not a normal-latency budget, it is a guard against a genuinely
# hung process (e.g. a corrupted interpreter, a filesystem stall opening
# the sqlite state file). Mirrors the existing
# VALIDATOR_TIMEOUT_S=30 convention (hooks/pre-edit-coverage-gate.sh:102,
# hooks/pre-edit-dod-gate.sh:74) — same value, same rationale, same
# "timeout unavailable → best-effort unwrapped call" fallback below.
REIN_CRG_DELEGATE_TIMEOUT_S=30

# rein_code_review_delegate
#   위임 실행 — rein_code_review_authority_switched() 가 이미 전환을
#   확인한 뒤에만 호출되는 것을 전제한다(소비 훅 pre-bash-commit-review-
#   gate.sh 의 호출 순서 참조, Phase 7 웨이브 3 ③-c). 이 훅이 받은 **원본
#   이벤트 JSON 그대로**($INPUT,
#   호출자가 파일 상단에서 `INPUT=$(cat)` 으로 이미 캡처해 둔 전역)를
#   `bin/rein hook` 의 stdin 에 그대로 흘려보낸다 — 재조립·위조 금지.
#   COMMAND(파싱된 문자열)이 아니라 $INPUT(원본 바이트)을 넘기는 이유는
#   v2 가 스스로 hook_event_name/tool_name/cwd 등 COMMAND 파싱 과정에서
#   버려지는 필드까지 다시 필요로 하기 때문이다 — v1 이 그 필드들을
#   추측해 재구성하면 v2 의 판정이 v1 의 재구성 실수에 종속된다.
#
#   결과를 두 전역에 담아 반환한다(캐치되는 정보가 3가지 뿐이라 함수
#   반환값 하나로는 DENY 의 JSON 본문까지 실어 나를 수 없다):
#     rein_code_review_delegate_result — ALLOW / DENY / FAIL 중 하나.
#     rein_code_review_delegate_json   — result=DENY 일 때만 채워지는,
#       v2 가 낸 그대로의 stdout JSON 원문(그대로 relay 할 바이트).
#
#   세 결과의 판정 기준:
#     ALLOW — bin/rein hook 이 exit 0 + 정확히 `{}` 를 냈다(adapter.
#       to_native_response 의 ALLOW 계약 — "모든 hook 에서 빈 응답").
#     DENY  — bin/rein hook 이 exit 0 + `hookSpecificOutput.
#       permissionDecision == "deny"` 형태를 냈다(PreToolUse 의 native
#       차단 계약).
#     FAIL  — 그 밖의 모든 경우를 균일하게 묶는다: 엔진 스크립트 부재,
#       파이썬 인터프리터 실행 실패, timeout(124)/exec 실패 등 0 이
#       아닌 종료 코드, 빈 출력, JSON 파싱 불가, 위 두 계약 어느 쪽에도
#       맞지 않는 출력 형태(예: PreToolUse 의 "ask" — 오늘 배포 기본
#       정책은 code_review 축에서 ask 를 내지 않지만, 낸다 해도 여기서는
#       "판정 실패"로 균일 처리한다 — 호출자가 그 경우 v1 자체 판정으로
#       fail-closed 하는 것이 이 축을 조용히 통과시키는 것보다 항상
#       안전하다).
#   FAIL 방향이 균일한 이유: 호출자(소비 훅 pre-bash-commit-review-
#   gate.sh)의 유일한 의무는 FAIL 이면 fail-closed 로 직접 판정하는 것 —
#   그 판정이 왜 실패했는지 세분화해도 호출자의 행동은 달라지지 않는다
#   (이 축이 조용히 사라지는 대신 항상 거부 방향으로 귀결된다. Phase 7
#   웨이브 3 ③-c 이후 이 축에는 v1 폴백 판정이 더 이상 존재하지 않는다).
rein_code_review_delegate() {
  rein_code_review_delegate_result="FAIL"
  rein_code_review_delegate_json=""

  [ -n "$_REIN_CRG_PKG_PARENT" ] || return 0
  local _crg_bin="$_REIN_CRG_PKG_PARENT/bin/rein"
  [ -f "$_crg_bin" ] || return 0

  local -a _crg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _crg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _crg_py=(python3)
  else
    return 0
  fi

  # REIN_PROJECT_ROOT 를 명시 주입한다 — v2 자립 규칙은 이 값이 없으면
  # payload 의 cwd 에서 `git rev-parse --show-toplevel` 로 유도하는데
  # (rein/cli/__init__.py::_resolve_project_root), v1 은 이미 자신의
  # PROJECT_DIR 을 (REIN_PROJECT_DIR_OVERRIDE 등 여러 경로를 거쳐)
  # 확정해 둔 상태다. 그 확정값을 그대로 넘기면 v1/v2 가 같은 프로젝트
  # 루트를 보장받는다 — v2 가 독자적으로(그리고 잠재적으로 다르게) 다시
  # 유도할 이유가 없다.
  local _crg_out _crg_rc
  if command -v timeout >/dev/null 2>&1; then
    _crg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" timeout "$REIN_CRG_DELEGATE_TIMEOUT_S" \
        "${_crg_py[@]}" "$_crg_bin" hook 2>/dev/null)
    _crg_rc=$?
  else
    # macOS BSD 는 기본적으로 GNU timeout 을 싣지 않는다(pre-edit-
    # coverage-gate.sh:402-407 과 동일한 폴백) — 안 감싼 채로라도 호출은
    # 계속한다. 시간 상한은 없어지지만 기능 자체는 유지된다.
    _crg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" "${_crg_py[@]}" "$_crg_bin" hook 2>/dev/null)
    _crg_rc=$?
  fi

  # rc 0 만 진짜 decision 왕복이다(bin/rein 자신의 계약 — 모듈 docstring
  # "fail-closed 매핑" 절: 1=순수 입력 결함, 2=native 직렬화 실패).
  # timeout(1) 은 자신이 시간 초과시키면 124 를 얹고, exec 자체가 실패하면
  # (127 등) 별도로 non-zero 를 낸다 — 그 어떤 non-zero 도, 그리고 빈
  # 출력도 "판정 실패"로 균일하게 취급한다.
  [ "$_crg_rc" -eq 0 ] && [ -n "$_crg_out" ] || return 0

  local _crg_kind
  _crg_kind=$(printf '%s' "$_crg_out" | "${_crg_py[@]}" -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("FAIL")
else:
    if data == {}:
        print("ALLOW")
    elif (
        isinstance(data, dict)
        and isinstance(data.get("hookSpecificOutput"), dict)
        and data["hookSpecificOutput"].get("permissionDecision") == "deny"
    ):
        print("DENY")
    else:
        print("FAIL")
' 2>/dev/null) || _crg_kind="FAIL"

  case "$_crg_kind" in
    ALLOW)
      rein_code_review_delegate_result="ALLOW"
      ;;
    DENY)
      rein_code_review_delegate_result="DENY"
      rein_code_review_delegate_json="$_crg_out"
      ;;
    *)
      rein_code_review_delegate_result="FAIL"
      ;;
  esac
  return 0
}
