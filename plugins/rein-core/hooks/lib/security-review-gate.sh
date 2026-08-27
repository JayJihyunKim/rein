#!/bin/bash
# hooks/lib/security-review-gate.sh
#
# Security-review axis judgment (is the security review stamp present,
# fresh, and PASS, or is this commit exempt) — originally extracted from
# pre-bash-test-commit-gate.sh's check_review_stamp() so the v2 governance
# runtime could swap the axis wholesale without touching the code-review
# axis (lib/code-review-gate.sh, Task 6.1 first axis). Mirrors that file's
# structure end to end.
#
# --- Phase 7 웨이브 3 ③-c (커밋 게이트 교대) 갱신 ---
#
# (구)pre-bash-test-commit-gate.sh 가 삭제되고 두 신설 훅으로 교대됐다.
# 이 파일에서 세 가지가 통째로 제거됐다 — lib/code-review-gate.sh 와
# lib/active-task-gate.sh 가 각자의 v1 최종 판정부에 적용한 것과 동일한
# 수술이다(그 두 파일의 "Phase 7 웨이브 3 ③-b/③-c 갱신" 절 참조):
#
#   1. v1 최종 판정 진입점 rein_check_security_review_stamp() — DOD_EXISTS
#      선행조건 + RT-1 light-tier 면제 재확인 + 보안-surface 면제 호출 +
#      전환확인/위임 오케스트레이션 + P6/P6b/P6c/M2 v1 직접 판정 전부.
#   2. _sx_* 명령형태 검사 helper 계열 전체(_sx_tokenize 부터
#      _sx_compute_security_surface_skip 까지) — 명령 형태 검사가 그 유일한
#      소비자(위 1번)와 함께 소멸했다(계획 4축 (d) 충족 경로 — lib 동반
#      소멸).
#   3. lib/stamp-parse.sh 소싱 — _parse_stamp_field()/_normalize_iso() 를
#      쓰던 유일한 소비자(위 1번)가 사라졌다.
#
# 이 파일은 이제 v2 전환확인 + 위임 하위 함수 두 개만 제공한다:
#   rein_security_review_authority_switched() — 전환 여부 확인
#   rein_security_review_delegate()           — 위임 실행
# 유일한 소비자는 신설 pre-bash-commit-review-gate.sh (③-c 로 새로 작성) —
# code_review 축과 함께 이 두 함수만 직접 호출해 자신만의 판정 트리를
# 구성한다. v1 폴백은 이제 이 축에 존재하지 않는다 — 미전환/확인실패/위임
# FAIL 을 그 훅이 fail-closed 방향으로 직접 판정한다. RT-1 light-tier
# 면제와 보안-surface 면제가 담당하던 재료(strict digest 범위의
# subject-empty=충족, scripts/rein.sh·plugin.json 버전-only 특례)는 이제
# v2 네이티브 판정이 대체한다 — 근거: docs/specs/2026-08-07-rein-v2-
# governance-orchestration.md §3.6 security_review 절 + DoD 선행 결정 3.
#
# 미전환("NOT_SWITCHED")과 확인 자체 실패("ERROR")를 구분하기 위해
# rein_security_review_authority_switched() 가 추가로 채우는 전역
# `rein_security_review_switch_check_kind` ("SWITCHED"|"NOT_SWITCHED"|
# "ERROR")는 lib/code-review-gate.sh / lib/active-task-gate.sh 의 동명
# 패턴과 바이트 수준으로 동일한 구조다 — 함수 자신의 반환값 계약(0=성공/
# 전환됨, 1=그 외 전부)은 그대로 두고 이 전역만 부가한다. 오직 소비 훅만
# 이 전역을 읽는다.
#
# 남은 두 함수 자신의 로직은 이 교대로 1바이트도 바뀌지 않았다(switch_
# check_kind 부가 제외) — 아래 두 함수 정의는 여전히 MECHANICAL(전환 확인
# + 위임 왕복, 판정하지 않음)이다.
#
# Depends on ambient state already set by the sourcing hook (NOT sourced
# here, to avoid re-defining infra that must stay singly owned) — the two
# surviving functions only read:
#   $PROJECT_DIR    — v1 이 이미 확정한 프로젝트 루트.
#   $INPUT          — 원본 hook event JSON, 파싱 이전 그대로. 이 값을
#     `bin/rein hook`'s stdin 에 그대로 forward 한다(rein_security_review_
#     delegate()가 재조립·위조하지 않는다 — 그 함수 자신의 주석 참조).
#   $PYTHON_RUNNER  — resolve 된 python 인터프리터 배열.
# 제거된 rein_check_security_review_stamp() 와 _sx_* 계열이 쓰던
# deny_emit()/log_block()/select_active_dod()/portable_mtime_epoch()/
# $COMMAND/_parse_stamp_field()/_normalize_iso() 는 더 이상 이 파일의
# 의존이 아니다 — 그 함수들과 함께 소멸했다(그 함수들만이 유일한
# 소비자였다). lib/stamp-parse.sh 소싱도 같은 이유로 제거됐다.
#
# --- Why this axis needs a REIN_POLICY_DIR the code-review axis does not ---
#
# code_review's delegate (lib/code-review-gate.sh) injects no REIN_POLICY_DIR
# — `bin/rein hook` then self-reliantly falls back to the bundled default
# policy set (plugins/rein-core/policies/default/), which already requires
# code_review on a commit (commit.yaml). security_review has no such free
# ride: the bundled default commit policy does NOT require security_review
# (2026-08-18 investigation D6) — delegating without a policy that says so
# would have v2 silently judge "no requirement" and ALLOW every commit,
# which is the opposite of what this axis is for. So this axis's delegate
# additionally injects REIN_POLICY_DIR pointing at a small, axis-only policy
# folder (`.rein/policy/security-axis/` — see that folder's own
# `_version.yaml` header for the full "why a new folder, why not reuse an
# existing one" reasoning) that declares exactly one requirement:
# security_review on git.commit. That folder is scoped to $PROJECT_DIR (the
# project the hook is running against), NOT this plugin's own package root —
# same override-lives-with-the-project convention `.rein/policy/
# authority.yaml` already uses.
#
# Usage:
#   . "$SCRIPT_DIR/lib/security-review-gate.sh"
#   if rein_security_review_authority_switched; then
#     rein_security_review_delegate
#     case "$rein_security_review_delegate_result" in
#       ALLOW) ... ;; DENY) ... "$rein_security_review_delegate_json" ... ;;
#       *) # FAIL ;;
#     esac
#   else
#     case "$rein_security_review_switch_check_kind" in
#       NOT_SWITCHED) ... ;; *) # ERROR ;;
#     esac
#   fi
#   # 전체 판정 트리는 이 파일의 유일한 소비자(pre-bash-commit-review-
#   # gate.sh) 자신의 헤더 참조 — 이 파일은 더 이상 스스로 exit 하거나
#   # deny_emit/log_block 을 호출하는 최종 판정 지점이 아니다.

if [ -n "${__REIN_SECURITY_REVIEW_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_SECURITY_REVIEW_GATE_LOADED=1

# ============================================================================
# --- v2 authority hand-off (Task 6.1 본작업 — security_review 축 전환) ---
# ============================================================================
#
# self-location: 이 파일 자신의 위치에서 rein 패키지의 부모 디렉토리를
# 구한다 — lib/code-review-gate.sh 의 _REIN_CRG_PKG_PARENT 와 정확히 동일한
# 원리다(어느 훅이 source 하든, 설치 방식(plugin tarball/dev repo)이
# 무엇이든 상대 위치로 항상 올바르게 찾는다 — CLAUDE_PLUGIN_ROOT 존재를
# 전제하지 않는다):
#   hooks/lib/security-review-gate.sh → (..) hooks → (..) <plugin root>
# <plugin root> 아래에 rein/engine/authority.py 가 있으면 그 패키지를
# 그대로 import 한다.
_REIN_SRG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REIN_SRG_PKG_PARENT="$(cd "$_REIN_SRG_LIB_DIR/../.." 2>/dev/null && pwd)" || _REIN_SRG_PKG_PARENT=""

# rein_security_review_authority_switched
#   v2 authority(rein.engine.authority.is_switched)에 security_review 축이
#   실제로 전환됐는지 질의한다 — code_review 축의
#   rein_code_review_authority_switched()와 정확히 같은 계약(그 함수의
#   docstring 을 그대로 상속한다): 이 함수는 스스로 "통과시킬지"를 결정하지
#   않는다 — 오직 "이 축을 v2 에 위임해도 되는가"만 답한다.
#
#   반환 0(성공) = 전환됨 — 호출자는 이 축을 v2 에 위임해야 한다.
#   반환 1(실패) = "전환 안 됨" 과 "확인 자체가 불가능함"(파이썬 부재·
#     모듈 로드 실패·정책 파일 손상·예외 등)을 구분하지 않고 동일하게
#     취급한다 — fail-closed 방향(코드 축과 동일 근거).
#
#   추가 출력 (Phase 7 웨이브 3 ③-c, pre-bash-commit-review-gate.sh 신설을
#   위한 최소 확장 — 동작 불변 계약, lib/code-review-gate.sh / lib/active-
#   task-gate.sh 의 동명 확장과 바이트 수준으로 동일한 패턴): 반환값
#   하나로는 "전환 안 됨"(문서화된 opt-out)과 "확인 자체가 불가능함"
#   (fail-closed 대상)을 구분할 수 없다. 기존 반환값 계약은 손대지 않는다
#   — 대신 전역 `rein_security_review_switch_check_kind` 를 "SWITCHED" |
#   "NOT_SWITCHED" | "ERROR" 중 하나로 함께 채운다. 이 함수를 호출하는
#   소비 훅만 이 전역을 읽어 두 경우를 다르게 처리한다.
rein_security_review_authority_switched() {
  rein_security_review_switch_check_kind="ERROR"

  [ -n "$_REIN_SRG_PKG_PARENT" ] || return 1

  local -a _srg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _srg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _srg_py=(python3)
  else
    return 1
  fi

  local _srg_out
  _srg_out=$("${_srg_py[@]}" - "$_REIN_SRG_PKG_PARENT" "$PROJECT_DIR" <<'PY' 2>/dev/null
import sys


def _main():
    if len(sys.argv) < 3:
        print("ERROR")
        return
    package_parent, project_root = sys.argv[1], sys.argv[2]
    sys.path.insert(0, package_parent)
    try:
        from rein.engine.authority import is_switched
        switched = is_switched("security_review", project_root=project_root)
    except Exception:
        # 모듈 부재/정책 손상/미지 capability 등 사유 불문 — 호출자가
        # "확인 실패"로 균일하게 취급하도록 ERROR 로만 신호한다.
        print("ERROR")
        return
    print("SWITCHED" if switched else "NOT_SWITCHED")


_main()
PY
  ) || return 1

  case "$_srg_out" in
    SWITCHED)     rein_security_review_switch_check_kind="SWITCHED" ;;
    NOT_SWITCHED) rein_security_review_switch_check_kind="NOT_SWITCHED" ;;
    *)            rein_security_review_switch_check_kind="ERROR" ;;
  esac

  [ "$_srg_out" = "SWITCHED" ]
}

# REIN_SRG_DELEGATE_TIMEOUT_S — safety-net ceiling for the delegation
# subprocess call below. Mirrors REIN_CRG_DELEGATE_TIMEOUT_S
# (lib/code-review-gate.sh) — same value, same rationale (VALIDATOR_TIMEOUT_S
# convention, hooks/pre-edit-coverage-gate.sh:102 / hooks/pre-edit-dod-
# gate.sh:74), same "timeout unavailable → best-effort unwrapped call"
# fallback below.
REIN_SRG_DELEGATE_TIMEOUT_S=30

# rein_security_review_delegate
#   위임 실행 — rein_security_review_authority_switched() 가 이미 전환을
#   확인한 뒤에만 호출되는 것을 전제한다. 이 훅이 받은 **원본 이벤트
#   JSON 그대로**($INPUT)를 `bin/rein hook` 의 stdin 에 그대로 흘려보낸다
#   — 재조립·위조 금지(code_review 축과 동일 이유: v2 가 스스로
#   hook_event_name/tool_name/cwd 등을 다시 필요로 한다).
#
#   code_review 축과의 유일한 차이 — REIN_POLICY_DIR 추가 주입: 이
#   축은 REIN_PROJECT_ROOT 뿐 아니라 REIN_POLICY_DIR 도
#   `$PROJECT_DIR/.rein/policy/security-axis` 로 명시 주입한다(이 파일
#   상단 "왜 이 축은 REIN_POLICY_DIR 을 주입하는가" 절 참조) — 그래야
#   v2 가 이 커밋 이벤트에서 security_review 를 실제로 요구하는 정책을
#   본다. code_review 축은 이 주입을 하지 않는다(번들 기본 정책이 이미
#   code_review 를 요구하므로 불필요).
#
#   결과를 두 전역에 담아 반환한다(code_review 축과 동일 이유 — 함수
#   반환값 하나로는 DENY 의 JSON 본문까지 실어 나를 수 없다):
#     rein_security_review_delegate_result — ALLOW / DENY / FAIL 중 하나.
#     rein_security_review_delegate_json   — result=DENY 일 때만 채워지는,
#       v2 가 낸 그대로의 stdout JSON 원문(그대로 relay 할 바이트).
#
#   세 결과의 판정 기준은 code_review 축과 완전히 동일하다(rein_code_
#   review_delegate() 의 판정 계약을 그대로 상속):
#     ALLOW — bin/rein hook 이 exit 0 + 정확히 `{}` 를 냈다.
#     DENY  — bin/rein hook 이 exit 0 + `hookSpecificOutput.
#       permissionDecision == "deny"` 형태를 냈다.
#     FAIL  — 그 밖의 모든 경우를 균일하게 묶는다(엔진 스크립트 부재,
#       파이썬 인터프리터 실행 실패, timeout(124)/exec 실패 등 0 이
#       아닌 종료 코드, 빈 출력, JSON 파싱 불가, 위 두 계약 어느 쪽에도
#       맞지 않는 출력 형태). 호출자(소비 훅 pre-bash-commit-review-
#       gate.sh)의 유일한 의무는 FAIL 이면 fail-closed 로 직접 차단하는
#       것 — Phase 7 웨이브 3 ③-c 이후 이 축에는 v1 폴백 판정이 더 이상
#       존재하지 않는다(이 축이 조용히 사라지는 대신 항상 거부 방향으로
#       귀결된다).
#
#   NOTE — 정책 폴더 자체가 손상/부재이면 `bin/rein hook` 내부에서
#   PolicyLoadError 가 발생하고, `rein/cli/__init__.py::_run_hook()` 의
#   광범위 예외 처리기가 이를 **rc 0 + native BLOCK(DENY 형태) JSON** 으로
#   변환한다(실측 확인, 2026-08-18) — 즉 "정책 폴더 손상"은 이 함수
#   관점에서 FAIL 이 아니라 DENY 로 분류된다(엔진 스크립트 자체가
#   죽거나 응답하지 못하는 경우만 FAIL). 어느 쪽이든 이 축이 조용히
#   통과되는 경로는 없다 — DENY 로 분류되면 그 JSON 이 그대로 relay
#   되어 커밋이 차단되고, FAIL 로 분류되면 소비 훅이 fail-closed 로 직접
#   차단한다. 둘 다 fail-closed 방향이며, 이 함수는 code_review 축과
#   동일하게 두 갈래를 구분 없이 기계적으로 분류한다(축마다 다른
#   특별 취급을 추가하지 않는다 — 분류 로직 자체를 단일 소스로 유지).
rein_security_review_delegate() {
  rein_security_review_delegate_result="FAIL"
  rein_security_review_delegate_json=""

  [ -n "$_REIN_SRG_PKG_PARENT" ] || return 0
  local _srg_bin="$_REIN_SRG_PKG_PARENT/bin/rein"
  [ -f "$_srg_bin" ] || return 0

  local -a _srg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _srg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _srg_py=(python3)
  else
    return 0
  fi

  # REIN_PROJECT_ROOT + REIN_POLICY_DIR 를 명시 주입한다. REIN_PROJECT_ROOT
  # 는 code_review 축과 동일 이유(v1 이 이미 확정한 PROJECT_DIR 을 그대로
  # 넘겨 v1/v2 가 같은 프로젝트 루트를 보장받는다). REIN_POLICY_DIR 은 이
  # 축 고유(위 함수 docstring 참조) — 축 전용 정책 폴더를 가리킨다.
  local _srg_policy_dir="$PROJECT_DIR/.rein/policy/security-axis"

  # HOLE FIX (보안 검토, 2026-08-18) — bin/rein hook 을 부르기 전에
  # commit-security.yaml 자기 자신의 존재를 직접 확인한다. 아래 두
  # 실패 모드는 겉보기에 비슷하지만 결과가 정반대라 이 검사가 필요하다:
  #   - 축 폴더 전체가 없으면: kernel/policy.py의 load_policies() 가
  #     os.listdir() 에서 OSError → PolicyLoadError 로 죽고, bin/rein
  #     hook 은 이를 캐치해 native BLOCK(DENY) JSON 으로 번역한다
  #     (시나리오 (i) 와 동일 경로) — fail-closed, 의도대로 차단된다.
  #   - 폴더는 있는데 commit-security.yaml 만 없으면(비었거나
  #     _version.yaml 만 남으면): load_policies() 는 예약 파일
  #     _version.yaml 을 스킵하므로 매칭되는 policy 가 정확히 0개가
  #     된다 — 엔진의 "policy 0개 = 평가 기본 ALLOW"(다른 축·다른
  #     트리거를 위해 의도된 설계, kernel/policy.py:150-158 docstring,
  #     spec §3.4 — 여기서 건드리면 안 된다)에 걸려 이 커밋 이벤트가
  #     `{}` 로 되돌아온다. 호출자는 이를 ALLOW 로 해석해 그대로
  #     통과시킨다 — 위임 분류상으로는 정상 ALLOW 이지만 실제로는
  #     "이 축을 판단할 정책이 아예 없었다"는 뜻이라, 보안 리뷰 요구
  #     전체가 로그도 에러도 없이 사라진다(2026-08-18 보안 검토,
  #     샌드박스 재현으로 확정 — 시나리오 (j)가 이 재현을 고정한다).
  # 그래서 위임을 시도하기 전에 이 정책 파일 하나만 직접 확인한다.
  # 없으면 위임 자체를 건너뛰고 result 를 FAIL 초기값 그대로 둔다 —
  # FAIL 은 호출자(소비 훅 pre-bash-commit-review-gate.sh)를 fail-closed
  # 로 직접 차단시킨다(Phase 7 웨이브 3 ③-c 이후 이 축에는 v1 폴백
  # 판정이 더 이상 존재하지 않는다 — 이 축이 조용히 사라지는 대신 항상
  # 거부 방향으로 귀결된다. 엔진 스크립트 손상 시나리오 (f)와 동일한
  # 낙하 경로).
  local _srg_policy_file="$_srg_policy_dir/commit-security.yaml"
  [ -f "$_srg_policy_file" ] || return 0

  local _srg_out _srg_rc
  if command -v timeout >/dev/null 2>&1; then
    _srg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$_srg_policy_dir" \
        timeout "$REIN_SRG_DELEGATE_TIMEOUT_S" \
        "${_srg_py[@]}" "$_srg_bin" hook 2>/dev/null)
    _srg_rc=$?
  else
    # macOS BSD 는 기본적으로 GNU timeout 을 싣지 않는다(pre-edit-
    # coverage-gate.sh:402-407 과 동일한 폴백, code_review 축과 동일) —
    # 안 감싼 채로라도 호출은 계속한다. 시간 상한은 없어지지만 기능
    # 자체는 유지된다.
    _srg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$_srg_policy_dir" \
        "${_srg_py[@]}" "$_srg_bin" hook 2>/dev/null)
    _srg_rc=$?
  fi

  # rc 0 만 진짜 decision 왕복이다(code_review 축과 동일 근거 — bin/rein
  # 자신의 계약: 1=순수 입력 결함, 2=native 직렬화 실패). timeout(1) 은
  # 자신이 시간 초과시키면 124 를 얹고, exec 자체가 실패하면(127 등) 별도로
  # non-zero 를 낸다 — 그 어떤 non-zero 도, 그리고 빈 출력도 "판정 실패"로
  # 균일하게 취급한다.
  [ "$_srg_rc" -eq 0 ] && [ -n "$_srg_out" ] || return 0

  local _srg_kind
  _srg_kind=$(printf '%s' "$_srg_out" | "${_srg_py[@]}" -c '
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
' 2>/dev/null) || _srg_kind="FAIL"

  case "$_srg_kind" in
    ALLOW)
      rein_security_review_delegate_result="ALLOW"
      ;;
    DENY)
      rein_security_review_delegate_result="DENY"
      rein_security_review_delegate_json="$_srg_out"
      ;;
    *)
      rein_security_review_delegate_result="FAIL"
      ;;
  esac
  return 0
}
