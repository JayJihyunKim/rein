#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit) — single-entry SEQUENTIAL dispatcher.
#
# Phase 7 웨이브 3 ③-b (편집 게이트 순차 디스패처, 2026-08-23) — code review
# round 6 High 의 근본 수리.
#
# ============================================================
# 왜 이 훅이 필요한가: 병렬·순서 비보장 → 형제 게이트 판정 peek 는 원리적
# 으로 불건전
# ============================================================
#
# Claude Code 는 같은 PreToolUse 이벤트에 매칭된 훅들을 병렬 실행하며 순서를
# 보장하지 않는다(hooks guide 원문: "the order is non-deterministic" — 이
# 저장소의 SPIKE-1 HK-4 도 직접 실측했다). hooks.json 이전 상태에서
# pre-edit-discipline-gate.sh / pre-edit-task-gate.sh / pre-edit-coverage-
# gate.sh 세 훅은 같은 PreToolUse Edit|Write|MultiEdit 매처 그룹에 개별
# 등록돼 있었고, 이 병렬·비보장 실행 모델 위에서 pre-edit-coverage-gate.sh
# 는 "형제 게이트(discipline-gate)가 이미 이 편집을 차단 중인가"를 디스크
# 표식(우회 마커·pending 표식) 재유도로 추론하는 precheck
# (`_rein_precheck_would_block`)를 갖고 있었다.
#
# 이 추론은 원리적으로 불건전하다: 재현된 회귀(round 6 High) — 사용자가
# 일회성 스펙 우회 표식(`.skip-spec-gate`)을 심어 스펙 리뷰 게이트를
# 우회하면, discipline-gate 의 실제(enforcing) 호출이 그 표식을 소비
# (`rm -f`)한다. coverage-gate 의 precheck 가 discipline-gate 의 실제 호출
# "이후"에 실행되면 표식이 이미 사라진 상태를 관측하고 "스펙 게이트가 아직
# 차단 중"이라고 오추론해 자기 자신의 coverage validator 호출을 건너뛴다
# (스펙 게이트 자체는 표식을 이미 소비했으므로 정상적으로 통과) — 그
# 결과 잘못된 `covers:` 값(존재하지 않는 Scope ID 포함)이 무검증으로
# 편집을 통과시킨다. 대조군(precheck 가 먼저 실행되거나 순서가 뒤집힌
# 경우)은 정상적으로 exit 2 + `.dod-coverage-mismatch` 마커를 남긴다 —
# 즉 결과가 "어느 프로세스가 먼저 끝나는가"라는 레이스에 달려 있었다.
#
# 근본 수리는 개별 훅이 서로의 판정을 disk 로 추론하는 모델 자체를
# 버리는 것이다. 이 디스패처는 세 자식 게이트를 **순서를 보장해
# 순차** 실행하고, 첫 차단에서 즉시 중단한다 — v1 시절 단일
# pre-edit-dod-gate.sh 가 갖고 있던 "첫 번째로 걸리는 조건에서 exit"
# 의미론을 복원한다. 이 모델에서는 coverage-gate 가 discipline-gate 의
# 판정을 추론할 필요가 전혀 없다 — 디스패처가 discipline-gate 를 먼저
# 실행해 이미 차단됐다면 coverage-gate 는 아예 호출되지도 않기 때문이다.
# pre-edit-coverage-gate.sh 자신의 peek 코드(`_rein_precheck_would_block`
# 및 그 호출부, 관련 lib 소싱)는 이 교대와 같은 커밋에서 제거됐다 — 그
# 파일의 갱신 주석 참조.
#
# 부수 효과 (의도된 것, code review round 7 High 로 서술 정밀화 —
# 아래는 정밀화된 최종 계약이다): blocks.jsonl 의 **차단 판정** 기록은
# 이벤트당 최대 1건 (첫-차단-중단) 으로 복원된다(v1 단일 훅 시절과
# 동일) — 첫 번째로 차단(exit 2)한 자식 이후로는 뒤의 자식이 아예
# 실행되지 않으므로, 서로 다른 두 축이 "동시에" 차단해 각자 다른 사유의
# 차단 판정 항목 2건을 남기는 일은 더 이상 없다.
#
# 이 "최대 1건"은 오직 차단(exit 2) 판정에만 적용된다 — round 7 이전
# 서술은 이 범위를 명시하지 않아 과대 서술이었다. 선행 자식이 편집을
# 허용(exit 0)하면서 남기는 감사 기록은 차단 판정과 다른 별개 클래스다
# — 예를 들어 pre-edit-discipline-gate.sh 가 소싱하는 lib/routing-
# gate.sh 는 사용자가 심어 둔 1회성 우회 표식(`.skip-routing-gate` 등)을
# 소비하며 통과시킬 때도 그 소비 사실을 log_block 으로 감사 기록한다
# (그 lib 의 MISSING_MARKERS 분기 참조 — 차단이 아니라 "우회를 실제로
# 썼다"는 감사 목적). 그런 우회-허용 감사 기록이 남은 뒤, 같은 이벤트를
# 후행 자식(예: coverage-gate)이 완전히 별개의 사유로 실제 차단하면,
# blocks.jsonl 에는 "우회-허용 감사 기록 1건 + 차단 판정 1건" 도합 2건이
# 정상적으로 남는다 — 이것은 회귀가 아니라 계약이다 (아래 pre-edit-
# task-gate.sh 의 "로그 계약" 절 및
# tests/hooks/test-pre-edit-dispatcher.sh 의 회귀 테스트 참조).
#
# 개별 훅을 테스트 하네스가 직접(디스패처를 거치지 않고) 호출하는
# 경우는 여전히 각자 독립적으로 로그를 남긴다 — 그것은 이 디스패처가
# 있든 없든 각 훅의 자체 계약이며, 프로덕션에서 실제로 발생하는 경로가
# 아니다(hooks.json 은 이제 이 디스패처 하나만 그 매처 그룹에 등록한다
# — 아래 "자식 목록·순서 계약" 참조).
#
# ============================================================
# 자식 목록·순서 계약
# ============================================================
#
# 정확히 이 순서로, 하나씩:
#   1. pre-edit-discipline-gate.sh — v1 존속 규율 게이트 묶음 (DoD 존재/
#      거버넌스/사건 리뷰/스펙 리뷰/라우팅)
#   2. pre-edit-task-gate.sh        — 활성 "작업" 축 (v2 authority 위임)
#   3. pre-edit-coverage-gate.sh    — coverage-validator tier/exit-code 표
#
# 이 순서를 바꾸면 어떤 축이 "먼저 차단해 나머지를 가리는가"가 바뀐다 —
# 순서 자체가 이 디스패처의 행동 계약의 일부다. hooks.json 에 등록된
# 이 디스패처 하나만 PreToolUse Edit|Write|MultiEdit 매처 그룹에서
# discipline/task/coverage 세 훅을 대신한다(그 세 파일 자체는 삭제하지
# 않는다 — 이 디스패처의 자식으로서, 그리고 테스트 하네스의 직접 호출
# 대상으로서 계속 존재한다).
#
# ============================================================
# 자식 응답 계약 (각 자식 훅이 지켜야 하는 것 — 새 자식을 추가할 때도
# 동일하게 적용)
# ============================================================
#
#   exit 2               → 차단. 디스패처는 즉시 exit 2 (잔여 자식 미실행).
#                           자식이 이미 stderr 에 이유를 낸다 — 디스패처는
#                           내용을 덧붙이지 않는다.
#   exit 0 + stdout 있음  → JSON deny relay 관례(v2 위임 축이 낸 deny
#                           JSON 등). 디스패처는 그 stdout 을 그대로
#                           relay 하고 exit 0 (잔여 자식 미실행) — Claude
#                           Code 에게는 "허용하되 특정 JSON 을 낸 것"으로
#                           보이는 정상 종료다.
#   exit 0 + stdout 없음  → 허용, 다음 자식으로 진행.
#   그 외(1 등 비정상)     → 게이트 자체가 실행에 실패한 것 — "통과"로
#                           삼키지 않는다. fail-closed exit 2 + 명확한
#                           stderr 메시지 후 즉시 중단.
#
# stderr 는 모든 경우에 자식 프로세스로부터 이 훅 프로세스로 그대로
# 상속된다(캡처하지 않는다) — 각 자식이 내는 [rein]/WARNING/NOTICE
# 진단 메시지가 지연이나 순서 왜곡 없이 사용자에게 도달해야 하기
# 때문이다. stdout 만 캡처하는 이유는 오직 "JSON deny 인가 아닌가"를
# 판정하기 위해서다 — 그 판정에는 값을 프로세스 메모리에 붙잡아 둘
# 필요가 있지만, stderr 진단 텍스트에는 그런 판정 목적이 없다.
#
# Exit code: 0=허용(또는 JSON deny relay), 2=차단

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT=$(cat)

# invoke_child HOOK_FILENAME — 자식 게이트 하나를 같은 $INPUT 으로 실행.
# stdout 만 캡처(_CHILD_OUT), exit code 는 _CHILD_RC 에 별도 캡처(stdout
# 캡처 명령 자체의 $? 를 즉시 읽는다 — 그 사이에 다른 명령을 끼워 넣지
# 않는다). bash 에는 깔끔한 다중 반환이 없어 전역 변수 관례를 쓴다 —
# 이 저장소의 다른 디스패처형 훅(pre-bash-dispatcher.sh 의
# invoke_hook_required/invoke_hook_advisory)과 동일한 패턴이다.
#
# 자식 파일 자체가 없으면(플러그인 설치 손상) 실행을 시도하지 않고
# 곧바로 fail-closed 로 판정한다 — bash 의 "No such file or directory"
# 원시 에러 하나만 남기고 넘어가는 대신, 무엇이 없고 왜 차단하는지
# 명시한다.
invoke_child() {
  local hook="$1"
  local path="$SCRIPT_DIR/$hook"
  if [ ! -f "$path" ]; then
    echo "[rein] The edit gate dispatcher cannot run because a required child gate is missing ($hook). The plugin install may be corrupted — run 'rein update' to repair." >&2
    _CHILD_RC=2
    _CHILD_OUT=""
    return
  fi
  _CHILD_OUT=$(printf '%s' "$INPUT" | bash "$path")
  _CHILD_RC=$?
}

for _child in pre-edit-discipline-gate.sh pre-edit-task-gate.sh pre-edit-coverage-gate.sh; do
  invoke_child "$_child"
  case "$_CHILD_RC" in
    0)
      if [ -n "$_CHILD_OUT" ]; then
        # exit 0 + non-empty stdout — JSON deny relay 관례. 그대로 relay
        # 하고 즉시 종료 (잔여 자식 미실행).
        printf '%s\n' "$_CHILD_OUT"
        exit 0
      fi
      # exit 0 + stdout 없음 — 허용, 다음 자식으로.
      ;;
    2)
      # 차단 — 자식이 이미 stderr 에 이유를 냈다. 잔여 자식 미실행.
      exit 2
      ;;
    *)
      # 비정상 종료 — 게이트 실행 실패를 통과로 삼키지 않는다.
      echo "[rein] The edit gate dispatcher cannot continue because $_child exited abnormally (rc=$_CHILD_RC, expected 0 or 2). This is treated as a failure, not a pass — run 'rein update' to check for a corrupted plugin install, or check the child gate's own stderr output above for the underlying cause." >&2
      exit 2
      ;;
  esac
done

exit 0
