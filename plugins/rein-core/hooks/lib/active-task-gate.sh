#!/bin/bash
# hooks/lib/active-task-gate.sh
#
# Active-task axis judgment (is there an active task record covering this
# edit) — originally extracted from pre-edit-dod-gate.sh's "Pending DoD
# 판정" + final decision block so the v2 governance runtime could swap the
# axis wholesale without touching the other two axes (hooks/lib/code-
# review-gate.sh, hooks/lib/security-review-gate.sh, Task 6.1 first/second
# axis). Mirrors those two files' structure end to end.
#
# ============================================================
# Why this axis CANNOT use the "active DoD exists" precondition the
# other two axes rely on (순환 회피) — abridged, design rationale kept
# ============================================================
#
# code_review's and security_review's judgment both start (or started —
# see those files' own ③-c headers) with an independent "does at least
# one DoD file exist" precondition that gates whether the axis has
# anything to say at all. That precondition is safe for them because "a
# DoD exists" is a DIFFERENT question from "is the code/security review
# stamp valid" — the two questions do not collapse into each other.
#
# For this axis, "is there an active task record" IS the entire question
# active_task exists to answer. Using its own answer as a precondition
# for whether to ask v2 the same question would be circular — and worse,
# a straight glob-based DOD_FOUND scan (no path-relevance reasoning) would
# silently pre-empt v2's real judgment, which additionally weighs
# changeset.task_relevant (spec §6.3 — an active task is not even
# required if the edited path is irrelevant to task governance). So the
# switch-check + delegate attempt in this file happens UNCONDITIONALLY
# (subject only to the tool-specific policy-file existence guard below) —
# this is why this axis never adopted the sibling axes' "precondition
# gates whether to even ask v2" shape, and why (Phase 7 웨이브 3 ③-c)
# removing this file's own v1 fallback judgment did not require touching
# that unconditional shape at all — it was already independent of it.
#
# Depends on ambient state already set by the sourcing hook (NOT sourced
# here, to avoid re-defining infra that must stay singly owned) — the
# three surviving functions (rein_active_task_authority_switched,
# rein_active_task_delegate, _rein_atg_policy_file_for_tool) only read:
#   $PROJECT_DIR    — v1 이 이미 확정한 프로젝트 루트.
#   $INPUT          — 원본 hook event JSON, 파싱 이전 그대로. 이 값을
#     `bin/rein hook`'s stdin 에 그대로 forward 한다(rein_active_task_
#     delegate()가 재조립·위조하지 않는다 — 그 함수 자신의 주석 참조).
#   $PYTHON_RUNNER  — resolve 된 python 인터프리터 배열.
#   $TOOL_NAME      — 도구별 축 전용 정책 파일명을 고르는 데 쓴다
#     (_rein_atg_policy_file_for_tool 경유). 호출자가 이미 $INPUT 에서
#     FILE_PATH 와 함께 단일 extract-hook-json.py 호출로 뽑아 둔 값을
#     그대로 읽는다(재추출하지 않는다, 아래 "편집당 python 프로세스
#     기동 횟수" 절 참조).
# 제거된 rein_check_active_task() 가 쓰던 log_block()/emit_ext_source_
# notice()/rein_dod_found()·$DOD_FOUND·$SCRIPT_DIR 는 더 이상 이 파일의
# 의존이 아니다 — 그 함수와 함께 소멸했다(그 함수만이 유일한 소비자였다).
#
# --- 편집당 python 프로세스 기동 횟수 (성능, 2026-08-18 리뷰 수리) ---
# 전환(switched) 상태에서 위임 경로가 기동하는 python 프로세스는
# 정확히 3회다:
#   ① 전환 확인 — rein_active_task_authority_switched() 의 heredoc 호출
#   ② 위임 본체 — rein_active_task_delegate() 의 `bin/rein hook` 호출
#   ③ 응답 분류 — 위임 stdout 을 ALLOW/DENY/FAIL 로 판별하는 one-liner
# tool_name 추출은 이 축 전용 4번째 호출로 따로 존재하지 않는다 —
# 호출자가 FILE_PATH 와 함께 단일 extract-hook-json.py 호출로 뽑아
# TOOL_NAME 전역에 담아 둔 값을 rein_active_task_delegate() 가 그대로
# 읽는다.
#
# v2 delegation (Task 6.1 본작업 — active_task 축 전환, 사용자 결정
# 2026-08-18 "직접 위임" 구조, code_review/security_review 축과 동일
# 아키텍처) forwards $INPUT VERBATIM to `bin/rein hook`'s stdin — never
# reconstructed (see rein_active_task_delegate()'s own comment, same
# reasoning as the two sibling files).
#
# --- Why this axis needs a REIN_POLICY_DIR the code-review axis does
# not (but shaped differently from the security axis) ---
#
# code_review's delegate injects no REIN_POLICY_DIR — the bundled
# default policy set already requires code_review on a commit. Neither
# active_task has a free ride: the bundled default set declares only
# commit/push/release tiers (all trigger: tool.pre + command.type
# conditions) — it has NO policy at all for a bare tool.pre(Edit/Write/
# MultiEdit) event, so delegating without an explicit policy would have
# v2 silently judge "no requirement" and ALLOW every edit (same failure
# shape security_review's D6 investigation found, just for a different
# trigger shape). So this axis's delegate also injects REIN_POLICY_DIR,
# pointing at the task-axis policy folder — resolved in two tiers: the
# project override `<project>/.rein/policy/task-axis/` first, else the
# distribution-shipped default `<plugin-root>/policies/task-axis/` (see
# rein_active_task_delegate()'s "정책 위치 2단 해소" section for why the
# bundled fallback exists, and that folder's `_version.yaml` header for
# the full "why a new folder, why THREE policy files" reasoning — the
# OR-less `when:` clause forces one file per tool name).
#
# --- Phase 7 웨이브 3 ③-c (커밋 게이트 교대) 갱신 ---
#
# ③-b 당시 이 파일의 v1 최종 판정 진입점 rein_check_active_task() 는
# "회귀/롤백 여지를 남기기 위한 보수적 선택"으로 존치됐었다(호출자가
# 없어졌을 뿐 삭제되지 않았다). ③-c 에서 커밋 게이트 두 축(code_review/
# security_review, lib/code-review-gate.sh / lib/security-review-gate.sh)
# 까지 동일한 전환확인+위임 전용 구조로 교대되면서, 그 존치 사유(다른
# 축들이 아직 v1 최종 판정을 갖고 있어 이 파일만 먼저 없애면 일관성이
# 깨진다는 우려)가 소멸했다 — 세 축 전부가 같은 모양이 됐으므로 이 파일도
# rein_check_active_task() 를 제거한다(그 함수 안의 "v1 폴백 최종
# 판정" — 미전환/위임 실패 시 DOD_FOUND 기반 직접 판정 — 이 제거
# 대상이었다, ③-b 당시 신설된 pre-edit-task-gate.sh 가 이미 그 진입점을
# 쓰지 않았던 것과 같은 이유).
#
# 이 파일은 이제 v2 전환확인 + 위임 하위 함수 세 개만 제공한다:
#   rein_active_task_authority_switched() — 전환 여부 확인
#   rein_active_task_delegate()           — 위임 실행
#   _rein_atg_policy_file_for_tool()      — 도구별 축 정책 파일명 매핑
# 유일한 소비자는 pre-edit-task-gate.sh(③-b 신설, 원래부터 이 세 함수만
# 직접 호출했다) — 그 훅 자신의 판정 트리:
#   전환됨 + ALLOW → exit 0
#   전환됨 + DENY  → v2 JSON relay + log_block + exit 0
#   전환됨 + FAIL  → fail-closed exit 2 (v1 폴백 없음 — 의도된 방향 변화)
#   미전환         → exit 0 (문서화된 opt-out)
#   확인 자체 실패 → fail-closed exit 2
# 미전환과 확인-실패를 구분하기 위해 rein_active_task_authority_
# switched()가 추가로 채우는 전역 `rein_active_task_switch_check_kind`
# ("SWITCHED"|"NOT_SWITCHED"|"ERROR")는 그 함수 자신의 주석 참조 — 이
# 전역은 ③-b 부터 이미 존재했고 ③-c 는 변경하지 않는다.
#
# Usage:
#   . "$SCRIPT_DIR/lib/active-task-gate.sh"
#   if rein_active_task_authority_switched; then
#     rein_active_task_delegate
#     case "$rein_active_task_delegate_result" in
#       ALLOW) ... ;; DENY) ... "$rein_active_task_delegate_json" ... ;;
#       *) # FAIL ;;
#     esac
#   else
#     case "$rein_active_task_switch_check_kind" in
#       NOT_SWITCHED) ... ;; *) # ERROR ;;
#     esac
#   fi
#   # 전체 판정 트리는 이 파일의 유일한 소비자(pre-edit-task-gate.sh)
#   # 자신의 헤더 참조 — 이 파일은 더 이상 스스로 exit 하거나 log_block/
#   # emit_ext_source_notice 를 호출하는 최종 판정 지점이 아니다.

if [ -n "${__REIN_ACTIVE_TASK_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_ACTIVE_TASK_GATE_LOADED=1

# --- v2 authority hand-off (Task 6.1 본작업 — active_task 축 전환) ---
#
# self-location: 이 파일 자신의 위치에서 rein 패키지의 부모 디렉토리를
# 구한다 — lib/code-review-gate.sh 의 _REIN_CRG_PKG_PARENT /
# lib/security-review-gate.sh 의 _REIN_SRG_PKG_PARENT 와 정확히 동일한
# 원리다(어느 훅이 source 하든, 설치 방식(plugin tarball/dev repo)이
# 무엇이든 상대 위치로 항상 올바르게 찾는다 — CLAUDE_PLUGIN_ROOT 존재를
# 전제하지 않는다):
#   hooks/lib/active-task-gate.sh → (..) hooks → (..) <plugin root>
# <plugin root> 아래에 rein/engine/authority.py 가 있으면 그 패키지를
# 그대로 import 한다.
_REIN_ATG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REIN_ATG_PKG_PARENT="$(cd "$_REIN_ATG_LIB_DIR/../.." 2>/dev/null && pwd)" || _REIN_ATG_PKG_PARENT=""

# rein_active_task_authority_switched
#   v2 authority(rein.engine.authority.is_switched)에 active_task 축이
#   실제로 전환됐는지 질의한다 — code_review/security_review 축의 동명
#   함수와 정확히 같은 계약(그 함수들의 docstring 을 그대로 상속한다):
#   이 함수는 스스로 "통과시킬지"를 결정하지 않는다 — 오직 "이 축을 v2
#   에 위임해도 되는가"만 답한다.
#
#   반환 0(성공) = 전환됨 — 호출자는 이 축을 v2 에 위임해야 한다.
#   반환 1(실패) = "전환 안 됨" 과 "확인 자체가 불가능함"(파이썬 부재·
#     모듈 로드 실패·정책 파일 손상·예외 등)을 구분하지 않고 동일하게
#     취급한다 — fail-closed 방향(다른 두 축과 동일 근거: 확인 불가를
#     "전환됨"으로 오인해 위임을 시도하는 것보다, v1 이 계속 직접
#     판정하는 쪽이 항상 안전하다).
#
#   추가 출력 (Phase 7 웨이브 3 ③-b, pre-edit-task-gate.sh 신설을 위한
#   최소 확장 — 동작 불변 계약): 반환값 하나로는 "전환 안 됨"(문서화된
#   opt-out)과 "확인 자체가 불가능함"(fail-closed 대상)을 구분할 수
#   없다. 기존 반환값 계약은 손대지 않는다 — 대신 전역
#   `rein_active_task_switch_check_kind` 를 "SWITCHED" | "NOT_SWITCHED" |
#   "ERROR" 중 하나로 함께 채운다. 이 함수를 직접 호출하는 소비 훅
#   (pre-edit-task-gate.sh)만 이 전역을 읽어 두 경우를 다르게 처리한다
#   (미전환→exit 0, 확인 실패→fail-closed exit 2). ③-b 당시엔 이 파일에
#   여전히 남아 있던 v1 폴백 진입점 rein_check_active_task() 는 이 전역을
#   읽지 않았다(둘 다 v1 폴백으로 흘러가는 동일 경로였으므로 구분이
#   불필요했다) — 그 함수는 ③-c 에서 제거됐다(파일 상단 "Phase 7 웨이브
#   3 ③-c" 절 참조).
rein_active_task_authority_switched() {
  rein_active_task_switch_check_kind="ERROR"

  [ -n "$_REIN_ATG_PKG_PARENT" ] || return 1

  local -a _atg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _atg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _atg_py=(python3)
  else
    return 1
  fi

  local _atg_switched_out
  _atg_switched_out=$("${_atg_py[@]}" - "$_REIN_ATG_PKG_PARENT" "$PROJECT_DIR" <<'PY' 2>/dev/null
import sys


def _main():
    if len(sys.argv) < 3:
        print("ERROR")
        return
    package_parent, project_root = sys.argv[1], sys.argv[2]
    sys.path.insert(0, package_parent)
    try:
        from rein.engine.authority import is_switched
        switched = is_switched("active_task", project_root=project_root)
    except Exception:
        # 모듈 부재/정책 손상/미지 capability 등 사유 불문 — 호출자가
        # "확인 실패"로 균일하게 취급하도록 ERROR 로만 신호한다.
        print("ERROR")
        return
    print("SWITCHED" if switched else "NOT_SWITCHED")


_main()
PY
  ) || return 1

  case "$_atg_switched_out" in
    SWITCHED)     rein_active_task_switch_check_kind="SWITCHED" ;;
    NOT_SWITCHED) rein_active_task_switch_check_kind="NOT_SWITCHED" ;;
    *)            rein_active_task_switch_check_kind="ERROR" ;;
  esac

  [ "$_atg_switched_out" = "SWITCHED" ]
}

# REIN_ATG_DELEGATE_TIMEOUT_S — safety-net ceiling for the delegation
# subprocess call below. Mirrors REIN_CRG_DELEGATE_TIMEOUT_S /
# REIN_SRG_DELEGATE_TIMEOUT_S (the two sibling files) — same value, same
# rationale (VALIDATOR_TIMEOUT_S convention, hooks/pre-edit-coverage-
# gate.sh:102 / hooks/pre-edit-dod-gate.sh:74), same "timeout
# unavailable → best-effort unwrapped call" fallback below.
REIN_ATG_DELEGATE_TIMEOUT_S=30

# _rein_atg_policy_file_for_tool TOOL_NAME
#   Maps a tool name to its axis-only policy filename (the same filename is
#   looked up in whichever tier resolves — project override or bundled
#   default; see that folder's `_version.yaml` for why three separate
#   files — the D3 `when:` clause has no OR). Prints the filename on a match, or
#   nothing (rc 1) for any other tool name — the hook's own PreToolUse
#   matcher is Edit|Write|MultiEdit, so a non-match here can only happen
#   in a malformed/synthetic event, and the caller must treat that as
#   "cannot classify → do not delegate" (same fail-closed-to-v1 shape as
#   an actually-missing policy file, not a separate failure mode).
_rein_atg_policy_file_for_tool() {
  case "$1" in
    Edit) printf '%s\n' "edit-task.yaml"; return 0 ;;
    Write) printf '%s\n' "write-task.yaml"; return 0 ;;
    MultiEdit) printf '%s\n' "multiedit-task.yaml"; return 0 ;;
    *) return 1 ;;
  esac
}

# rein_active_task_delegate
#   위임 실행 — rein_active_task_authority_switched() 가 이미 전환을
#   확인한 뒤에만 호출되는 것을 전제한다. 이 훅이 받은 **원본 이벤트
#   JSON 그대로**($INPUT)를 `bin/rein hook` 의 stdin 에 그대로
#   흘려보낸다 — 재조립·위조 금지(다른 두 축과 동일 이유: v2 가 스스로
#   hook_event_name/tool_name/cwd 등을 다시 필요로 한다).
#
#   다른 두 축과의 유일한 차이 — 위임 전 도구별 정책 파일 존재를 직접
#   확인한다(security_review 축이 2026-08-18 보안 검토로 얻은 교훈의
#   선제 적용 — hooks/lib/security-review-gate.sh 의 동명 로직 및 그
#   축의 시나리오 (j) 참조): 정책 **폴더**가 아예 없으면 `bin/rein
#   hook` 내부에서 PolicyLoadError → native BLOCK(DENY)로 귀결돼
#   여전히 fail-closed 지만, 폴더는 있는데 이 도구에 해당하는 파일만
#   없으면(예: edit-task.yaml 삭제) 매칭되는 policy 가 0개가 되어
#   "policy 0개 = 평가 기본 ALLOW" 에 걸려 이 축의 요구 전체가 로그도
#   에러도 없이 사라진다. 그래서 위임을 시도하기 전에 이 도구용 정책
#   파일 하나가 실재하는지 직접 확인한다 — 없으면 위임 자체를 건너뛰고
#   result 를 FAIL 초기값 그대로 둔다.
#
#   --- 정책 위치 2단 해소 (프로젝트 오버라이드 → 배포 번들 폴백,
#   2026-08-28 hotfix — docs/reports/[issues]_2026-08-28.md) ---
#
#   위 존재 확인의 대상 디렉토리를 두 곳에서 순서대로 찾는다:
#     ① `$PROJECT_DIR/.rein/policy/task-axis/`  — 프로젝트 오버라이드
#     ② `$_REIN_ATG_PKG_PARENT/policies/task-axis/` — 배포 번들 기본
#        (플러그인에 동봉되는 SSOT, policies/task-axis/_version.yaml 참조)
#   ①에 이 도구용 파일이 있으면 그 폴더를, 없고 ②에 있으면 ②를
#   REIN_POLICY_DIR 로 주입한다. 둘 다 없을 때만 위임을 건너뛰고 FAIL
#   (fail-closed)로 둔다.
#
#   왜 ② 폴백이 필수인가: active_task 축은 배포 기본값(rein/engine/
#   authority.py DEFAULT_SWITCHED_CAPABILITIES)으로 v2 전환돼 있는데,
#   이 축이 요구하는 tool.pre 정책은 policies/default/ 에 없어 오직 이
#   축 전용 폴더에서만 온다. ①만 보던 이전 구현은 그 폴더를 dogfood
#   저장소의 프로젝트 오버라이드로만 갖고 있었고 배포본엔 동봉하지
#   않아서, v2 로 업데이트한 실사용자 프로젝트(① 부재)는 위임이 매번
#   FAIL → 모든 편집이 복구 불가로 하드 차단됐다(실측 리포트 동일).
#   ②를 폴백으로 두면 오버라이드 없는 프로젝트도 배포 번들 정책으로
#   정상 위임(활성 작업 없으면 정상 DENY, 있으면 ALLOW)한다.
#
#   위변조 가드는 오히려 강화된다: 위 "policy 0개 = 침묵 ALLOW" 함정을
#   막는 파일 존재 확인은 유지되고, 사용자가 ① 오버라이드 파일을 지워
#   축을 조용히 끄려 해도 ②가 이어받아 축이 계속 발동한다. FAIL 은
#   이제 ①②가 **모두** 없는 손상 상태(플러그인 파손 →
#   `claude plugin update rein` 로 재설치)에서만 도달한다. 정상 opt-out
#   은 여전히 authority.yaml/hooks.yaml 경로로만 한다(이 파일 판정 밖).
#
#   결과를 두 전역에 담아 반환한다(다른 두 축과 동일 이유 — 함수
#   반환값 하나로는 DENY 의 JSON 본문까지 실어 나를 수 없다):
#     rein_active_task_delegate_result — ALLOW / DENY / FAIL 중 하나.
#     rein_active_task_delegate_json   — result=DENY 일 때만 채워지는,
#       v2 가 낸 그대로의 stdout JSON 원문(그대로 relay 할 바이트).
#
#   세 결과의 판정 기준은 다른 두 축과 완전히 동일하다(그 함수들의
#   판정 계약을 그대로 상속):
#     ALLOW — bin/rein hook 이 exit 0 + 정확히 `{}` 를 냈다.
#     DENY  — bin/rein hook 이 exit 0 + `hookSpecificOutput.
#       permissionDecision == "deny"` 형태를 냈다.
#     FAIL  — 그 밖의 모든 경우를 균일하게 묶는다(엔진 스크립트 부재,
#       파이썬 인터프리터 실행 실패, timeout(124)/exec 실패 등 0 이
#       아닌 종료 코드, 빈 출력, JSON 파싱 불가, 위 두 계약 어느 쪽에도
#       맞지 않는 출력 형태, 그리고 위에서 설명한 "이 도구용 정책
#       파일이 없어 위임 자체를 시도하지 않음"도 이 FAIL 로 흡수된다).
#       호출자(소비 훅 pre-edit-task-gate.sh)의 유일한 의무는 FAIL 이면
#       fail-closed 로 직접 차단하는 것 — Phase 7 웨이브 3 ③-c 이후 이
#       축에는 v1 폴백 판정이 더 이상 존재하지 않는다(이 축이 조용히
#       사라지는 대신 항상 거부 방향으로 귀결된다).
rein_active_task_delegate() {
  rein_active_task_delegate_result="FAIL"
  rein_active_task_delegate_json=""

  [ -n "$_REIN_ATG_PKG_PARENT" ] || return 0
  local _atg_bin="$_REIN_ATG_PKG_PARENT/bin/rein"
  [ -f "$_atg_bin" ] || return 0

  local -a _atg_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _atg_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _atg_py=(python3)
  else
    return 0
  fi

  # 이 이벤트의 tool_name 으로 도구별 축 전용 정책 파일명을 정한다.
  # PERF (2026-08-18 성능 리뷰 수리): 이 축 전용으로 python 을 다시
  # 기동해 재추출하지 않는다 — 호출자(pre-edit-dod-gate.sh)가 이미
  # 같은 $INPUT 에서 FILE_PATH 와 함께 단일 extract-hook-json.py
  # 호출로 뽑아 TOOL_NAME 전역에 담아 둔 값을 그대로 읽는다(파일
  # 상단 "Depends on ambient" 절 + "편집당 python 프로세스 기동
  # 횟수" 절 참조). 값 부재·형식 이상 시의 방향은 기존과 동일하다 —
  # 미상 tool_name(malformed/synthetic 이벤트, 또는 TOOL_NAME 이
  # 비어있는 경우) → _rein_atg_policy_file_for_tool 이 매치 실패 →
  # 위임 시도 자체를 건너뛴다(FAIL 초기값 유지, fail-closed).
  local _atg_policy_file_name
  _atg_policy_file_name=$(_rein_atg_policy_file_for_tool "${TOOL_NAME:-}") || return 0

  # 정책 위치 2단 해소 — 프로젝트 오버라이드 우선, 없으면 배포 번들 폴백
  # (위 함수 docstring "정책 위치 2단 해소" 절 참조). 둘 다 이 도구용
  # 파일이 없을 때만 위임을 건너뛰고 FAIL(fail-closed)로 둔다.
  local _atg_policy_dir=""
  if [ -f "$PROJECT_DIR/.rein/policy/task-axis/$_atg_policy_file_name" ]; then
    _atg_policy_dir="$PROJECT_DIR/.rein/policy/task-axis"
  elif [ -f "$_REIN_ATG_PKG_PARENT/policies/task-axis/$_atg_policy_file_name" ]; then
    _atg_policy_dir="$_REIN_ATG_PKG_PARENT/policies/task-axis"
  else
    return 0
  fi

  # REIN_PROJECT_ROOT + REIN_POLICY_DIR 를 명시 주입한다 — 다른 두 축과
  # 동일 이유(v1 이 이미 확정한 PROJECT_DIR 을 그대로 넘겨 v1/v2 가 같은
  # 프로젝트 루트를 보장받는다; REIN_POLICY_DIR 은 이 축 전용 정책
  # 폴더를 가리킨다, 위 함수 docstring 참조).
  local _atg_out _atg_rc
  if command -v timeout >/dev/null 2>&1; then
    _atg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$_atg_policy_dir" \
        timeout "$REIN_ATG_DELEGATE_TIMEOUT_S" \
        "${_atg_py[@]}" "$_atg_bin" hook 2>/dev/null)
    _atg_rc=$?
  else
    # macOS BSD 는 기본적으로 GNU timeout 을 싣지 않는다(pre-edit-
    # coverage-gate.sh:402-407 과 동일한 폴백, 다른 두 축과 동일) — 안
    # 감싼 채로라도 호출은 계속한다. 시간 상한은 없어지지만 기능
    # 자체는 유지된다.
    _atg_out=$(printf '%s' "$INPUT" \
      | REIN_PROJECT_ROOT="$PROJECT_DIR" REIN_POLICY_DIR="$_atg_policy_dir" \
        "${_atg_py[@]}" "$_atg_bin" hook 2>/dev/null)
    _atg_rc=$?
  fi

  # rc 0 만 진짜 decision 왕복이다(다른 두 축과 동일 근거 — bin/rein
  # 자신의 계약: 1=순수 입력 결함, 2=native 직렬화 실패). timeout(1) 은
  # 자신이 시간 초과시키면 124 를 얹고, exec 자체가 실패하면(127 등)
  # 별도로 non-zero 를 낸다 — 그 어떤 non-zero 도, 그리고 빈 출력도
  # "판정 실패"로 균일하게 취급한다.
  [ "$_atg_rc" -eq 0 ] && [ -n "$_atg_out" ] || return 0

  local _atg_kind
  _atg_kind=$(printf '%s' "$_atg_out" | "${_atg_py[@]}" -c '
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
' 2>/dev/null) || _atg_kind="FAIL"

  case "$_atg_kind" in
    ALLOW)
      rein_active_task_delegate_result="ALLOW"
      ;;
    DENY)
      rein_active_task_delegate_result="DENY"
      rein_active_task_delegate_json="$_atg_out"
      ;;
    *)
      rein_active_task_delegate_result="FAIL"
      ;;
  esac
  return 0
}
