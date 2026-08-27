#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# 활성 "작업" 축(=이 편집을 커버하는 활성 task record 가 있는가) 전담 —
# v2 governance authority 로의 1급(first-class) 위임 래퍼.
#
# Phase 7 웨이브 3 ③-b (edit-gate 교대): 이 훅은 신설이다. (구)pre-edit-
# dod-gate.sh 의 활성-작업 최종 판정(그 파일 L424-439, lib/active-task-
# gate.sh 소싱 + rein_check_active_task 호출)이 여기로 전량 이관됐다.
# sibling pre-edit-discipline-gate.sh(그 외 v1 존속 규율 게이트 전부를
# 계승)는 이 축을 전혀 다루지 않는다.
#
# 등록/실행 모델 (③-b 순차 디스패처 도입, 2026-08-23 갱신 — 이전
# 리비전의 "병렬 등록, OR-병합" 서술은 폐기): hooks.json 은 이제 이
# 세 훅(discipline-gate/task-gate/coverage-gate) 을 PreToolUse
# Edit|Write|MultiEdit 매처 그룹에 개별 등록하지 않는다 — 그 자리에는
# pre-edit-dispatcher.sh 하나만 등록되고, 그 디스패처가 이 훅을
# discipline-gate 다음, coverage-gate 앞 순서로 **순서를 보장해 순차**
# 실행하며 첫 차단에서 즉시 중단한다(그 훅 자신의 헤더 참조 — 왜
# 병렬·순서 비보장(SPIKE-1 HK-4 실측 + hooks-guide 공식 문서) 위에서의
# same-process peek 가 불건전했는지, 그리고 그 수리로 이 순차 모델이
# 왜 채택됐는지). 이 파일이 테스트 하네스에 의해 디스패처 없이
# **직접** 호출되는 경로(단위 테스트)는 여전히 존재하고 계속 유효하다
# — 그 경우 이 훅은 자신의 판정만 독립적으로 수행한다.
#
# 이 훅은 lib/active-task-gate.sh 의 하위 함수 두 개
# (rein_active_task_authority_switched, rein_active_task_delegate) 만 직접
# 재사용한다 — 그 파일의 진입점 rein_check_active_task() 는 쓰지 않는다.
# 그 진입점 안의 "v1 폴백 최종 판정"(미전환이거나 위임이 FAIL 일 때
# DOD_FOUND 기반으로 v1 이 직접 판정하던 분기)이 바로 이 훅이 의도적으로
# 없애려는 대상이기 때문이다 — 아래 판정 트리 참조.
#
# 판정 트리 (부모 확정 설계, Phase 7 웨이브 3 ③-b):
#   전환됨 + ALLOW → exit 0
#   전환됨 + DENY  → v2 JSON 그대로 relay + log_block + exit 0 (JSON deny
#     관례). DENY 대상이 확장자만으로 소스 판정된 경로면(EXT_SOURCE_HIT)
#     lib/ext-source-notice.sh 의 emit_ext_source_notice() 를 stderr 로
#     병행 — 구 v1 차단 경로가 주던 "왜 이 파일에 DoD 가 필요한가" 안내
#     UX 를 v2-위임 차단에서도 보존한다.
#   전환됨 + FAIL(위임 실행 실패·timeout·응답 파싱 불능) → fail-closed
#     exit 2 + 명확한 stderr.
#   미전환(capability off) → exit 0 (축 명시 비활성 — 문서화된 opt-out).
#   전환 상태 확인 자체가 실패(파이썬 부재/모듈 손상/예외 등) → fail-closed
#     exit 2.
#
# ⚠️ 의도된 방향 변화 (이 교대에서 유일하게 구 동작과 달라지는 지점,
# 나머지는 전부 동작 보존이 계약): 구 rein_check_active_task() 는
# "미전환" 과 "확인 자체 불가능" 을 구분하지 않고 똑같이 v1 자신의
# DOD_FOUND 기반 최종 판정으로 흘려보냈다(그래서 v1 이 사실상 항상
# 최종 결정권을 유지했다). 이 훅은 그 v1 폴백을 아예 갖지 않는다 —
# 위임이 FAIL 이면(전환은 됐는데 판정을 받지 못한 경우) 판단 불능을
# 거부 방향으로 처리해 fail-closed exit 2 하고, 미전환(capability 가
# 아직 v2 로 전환되지 않은 경우)이면 이 축이 아직 활성화되지 않은
# 것으로 보고 exit 0 한다(문서화된 opt-out — design doc §3.4). 즉 이
# 축의 "차단 권한"이 이제 전적으로 v2 전환 여부에 달려 있다 — v1 은
# 더 이상 이 축을 대신 판정하지 않는다.
#
# "미전환"과 "확인 자체 실패"를 구분하기 위해 lib/active-task-gate.sh 의
# rein_active_task_authority_switched() 가 채우는 전역
# `rein_active_task_switch_check_kind` ("SWITCHED"|"NOT_SWITCHED"|"ERROR")
# 를 그 함수 호출 직후 읽는다 (그 lib 의 Phase 7 웨이브 3 ③-b 갱신 주석
# 참조 — 함수 자신의 반환값 계약은 그대로 두고 이 전역만 추가했다).
#
# Exit code: 0=허용, 2=차단

# Security (High, Phase 7 wave 3 ③-b code review round 2 — sibling
# pre-edit-discipline-gate.sh 와 동일한 재현·수리, 그 훅의 동일 지점 주석
# 참조): REIN_GATE_PEEK_MODE 는 pre-edit-coverage-gate.sh 의 서브셸이 그
# 수명 동안만 부여하는 내부 peek 계약 값이며, 이 훅처럼 ENFORCING 으로
# 호출하는 프로세스가 외부 상속으로 이 값을 물려받아서는 안 된다. 이 훅이
# 직접 source 하는 lib/active-task-gate.sh 는 현재 이 변수를 읽지 않지만
# (v2 위임 트리라 peek 대상 1회성 마커 자체가 없다), 방어 원칙은 동일하게
# 적용한다 — 이 훅이 "판정 lib 를 진짜로 집행하는 프로세스"라는 사실
# 자체가 이 변수의 외부 상속을 절대 허용하지 않아야 하는 이유이지, 현재
# 이 변수를 소비하는 코드가 있는지 여부가 이유가 아니다(sibling 훅과의
# 일관성 + 향후 이 lib 가 peek 패턴을 채택하더라도 안전망이 이미 존재).
unset REIN_GATE_PEEK_MODE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

DOD_DIR="$PROJECT_DIR/trail/dod"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

# ============================================================
# 로그 계약 — 프로덕션 경로는 디스패처가 "차단 판정" 기록을 이벤트당
# 최대 1건으로 복원한다 (Phase 7 wave 3 ③-b code review round 2 결정
# → round 6 수리로 상위 전제 자체가 바뀌었다 → round 7 수리로 "최대
# 1건"의 범위를 차단 판정으로 정밀화했다. 아래는 갱신된 최종 계약.)
# ============================================================
#
# round 2 당시(이 훅과 sibling pre-edit-discipline-gate.sh 가 hooks.json
# 의 같은 PreToolUse Edit|Write|MultiEdit 매처 그룹에 각각 개별 등록돼
# 병렬·순서 비보장으로 실행되던 시절)에는, 두 훅이 같은 편집을 각자 다른
# 사유로 동시에 차단하면 blocks.jsonl 에 서로 다른 reason 을 가진 항목이
# 2건 남는 것을 "버그가 아니라 병렬 분리의 의도된 결과"로 부모가
# 확정했었다 — "누가 먼저 기록했으니 나중 것은 생략한다"는 조율 자체가
# 훅 간 결합(coupling)을 재도입한다는 논리였다.
#
# round 6(High, pre-edit-dispatcher.sh 신설)으로 그 전제가 바뀌었다:
# hooks.json 은 이제 이 매처 그룹에 pre-edit-dispatcher.sh 하나만
# 등록하고, 그 디스패처가 discipline-gate → task-gate → coverage-gate 를
# **순서를 보장해 순차** 실행하며 첫 차단에서 즉시 중단한다(그 훅
# 자신의 헤더 참조). 따라서 프로덕션 경로에서는 discipline-gate 가
# 차단하면 이 훅(task-gate)은 애초에 실행되지 않는다 — 로그를 남길
# 기회 자체가 없다. 두 축이 서로 다른 사유로 "동시에" 차단하는 상황은
# 더 이상 발생하지 않는다: 항상 순서상 먼저 오는 축(discipline-gate)의
# 판정 하나만 남고, 그 축이 통과해야만 이 훅이 실행되어 자신의 축을
# 판정한다 — v1 단일 pre-edit-dod-gate.sh 시절의 "이벤트당 최대 1건"
# 의미론이 복원됐다.
#
# round 7(High, 이번 수리) — 위 "이벤트당 최대 1건" 은 **차단 판정**
# 에만 적용되는 것으로 정밀화한다. discipline-gate 가 이 훅보다 먼저
# 실행되며 그 안의 lib/routing-gate.sh 등은 사용자의 1회성 우회 표식을
# 소비해 편집을 **허용**할 때도 그 소비 사실을 log_block 으로 감사
# 기록한다 — 이것은 차단이 아니라 "우회를 실제로 썼다"는 별개 클래스의
# 감사 기록이다(pre-edit-dispatcher.sh 헤더의 동일 지점 주석 참조).
# discipline-gate 가 그렇게 우회-허용 감사 기록을 남기고 통과시킨 뒤,
# 이 훅이나 coverage-gate 가 완전히 다른 사유로 실제 차단하면, 같은
# 이벤트에 "우회-허용 감사 기록 1건 + 차단 판정 1건" 도합 2건이
# blocks.jsonl 에 정상적으로 남는다 — 이전 리비전의 "이벤트당 최대
# 1건" 서술은 이 조합을 포함하지 않아 과대 서술이었다.
#
# 이 훅이 여전히 자신만의 log_block() 사본을 갖고 self-contained 로
# 로깅하는 이유는 바뀌지 않았다 — 다른 게이트들과 동일한 관례(각 게이트가
# lib/rein-log-block.py SSOT 를 자신의 이름으로 감싸 호출)이며, 디스패처를
# 거치지 않고 테스트 하네스가 이 훅을 **직접** 호출하는 경로(단위 테스트
# 관점)에서는 여전히 독립적으로 동작해야 하기 때문이다.
#
# 회귀 방지 테스트, 두 계층으로 분리:
#   - tests/hooks/test-pre-edit-task-gate.sh 의
#     test_dual_axis_independent_logging_two_distinct_reasons — 디스패처를
#     거치지 않고 discipline-gate/task-gate 를 각각 **직접** 호출해, 각
#     훅이 독립적으로 자신의 log_block 을 갖고 있다는 단위 계약(그 훅
#     하나만 떼어내 테스트할 때도 로깅이 self-contained 하게 동작함)을
#     고정한다. 이것은 더 이상 "프로덕션에서 실제로 몇 건이 남는가"를
#     검증하는 테스트가 아니다 — 그 검증은 아래로 이관됐다.
#   - tests/hooks/test-pre-edit-dispatcher.sh 의 동일 계열 테스트가 같은
#     이중-차단 fixture 를 **디스패처 경유**로 실행해, blocks.jsonl 에
#     정확히 1건(첫 차단 축의 것)만 남는 것을 단언한다 — 이것이 실제
#     프로덕션 경로의 "차단 판정" 카디널리티 계약이다.
#   - tests/hooks/test-pre-edit-dispatcher.sh 의
#     test_scenario_bypass_allow_plus_downstream_block_yields_two_log_entries
#     (round 7 신설) 이 위 두 클래스가 섞이는 조합 — 선행 축(routing-
#     gate)의 우회-허용 감사 기록 + 후행 축(coverage-gate)의 실제 차단
#     판정 — 을 디스패처 경유로 실행해, blocks.jsonl 에 정확히 2건(우회
#     계열 1 + 차단 판정 1)이 남고 차단 판정 사유는 그중 1건뿐임을
#     단언한다 — "차단 판정만 최대 1건" 이라는 정밀화된 계약과 "우회-
#     허용 감사 기록은 별개 클래스로 추가될 수 있다" 는 것을 함께
#     고정한다.

# log_block — 이 훅 전용 로컬 복사본. 다른 게이트들과 같은 관례 (각
# 게이트가 lib/rein-log-block.py SSOT 를 자신의 이름으로 감싸 호출 —
# pre-edit-coverage-gate.sh 의 동명 주석 참조, 공유하지 않는다).
log_block() {
  local reason="$1"
  local target="$2"
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  local _lb_helper="$SCRIPT_DIR/lib/rein-log-block.py"
  if [ ! -f "$_lb_helper" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  local count
  count=$("${PYTHON_RUNNER[@]}" "$_lb_helper" \
    "pre-edit-task-gate" "$reason" "$target" \
    "$BLOCKS_LOG_JSONL" "$PROJECT_DIR/.rein/logs/blocks-raw.jsonl" \
    path "${REIN_TEST_MODE:-0}" 2>/dev/null || echo 0)
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  local _auto_silent=0
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ]; then
    # shellcheck disable=SC1091
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh" 2>/dev/null || true
    if declare -F is_auto_mode >/dev/null 2>&1 && is_auto_mode; then
      _auto_silent=1
    fi
  fi
  if [ "$_auto_silent" = "0" ]; then
    if [ "$count" -ge 3 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
    elif [ "$count" -ge 2 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
    fi
  fi
}

# Shadow Corpus 관측 (plan Task 2.8, fire-and-forget) — 구 단일 훅에서는
# active-task 축의 판정도 pre-edit-dod-gate.sh 하나의 shadow_capture_init
# 아래에서 관측됐다. 이 축이 독립 프로세스(이 훅)로 분리된 이상, 여기서도
# 초기화하지 않으면 이 축의 판정이 shadow corpus 관측에서 통째로 빠진다
# — 그 관측 공백을 막기 위해 이 훅도 자신의 이름으로 초기화한다(sibling
# 축 code_review/security_review 를 감싸는 pre-bash-test-commit-gate.sh
# 가 이미 자신의 shadow_capture_init 을 갖는 것과 같은 원리 — 그 두 축도
# v2-DENY relay 시 deny_emit 없이 exit 0 + log_block 만 호출하는 동일한
# 모양이라, 그 경로의 shadow 판정 라벨이 "ALLOW_WITH_BYPASS"로 근사되는
# 것도 이 훅과 동일한 기존 특성이다 — 이 훅이 새로 만드는 문제가 아니다).
. "$SCRIPT_DIR/lib/shadow-capture.sh" 2>/dev/null && shadow_capture_init "pre-edit-task-gate"

INPUT=$(cat)

# python3 필수 (JSON 파싱 + v2 위임 호출). 없으면 fail-closed — 다른 모든
# 게이트와 동일한 근거(lib/python-runner.sh 자체 헤더 참조).
resolve_python
rc=$?
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    10) echo "[rein] The task gate cannot run because Python is not installed. Install Python 3 to restore all edit checks." >&2 ;;
    11) echo "[rein] The task gate cannot run because the Windows App Execution Alias Python stub was detected instead of a real Python installation. Install Python 3 from python.org or the Microsoft Store to proceed." >&2 ;;
    12) echo "[rein] The task gate cannot run because Python failed to launch (exit 9009 family) — this is common in Windows Git Bash or MSYS, or when REIN_PYTHON points to an invalid interpreter. Check your Python installation or unset REIN_PYTHON." >&2 ;;
    *)  echo "[rein] The task gate cannot run because the Python resolver failed (rc=$rc). Check your Python installation or run 'rein update'." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form, own key ---
# .rein/policy/hooks.yaml can disable this hook via `pre-edit-task-gate: false`
# or `{ pre-edit-task-gate: { enabled: false } }`. Same ordering contract as
# every other gate: this check runs AFTER resolve_python (already fail-closed
# on interpreter absence), so a missing interpreter can never be mistaken for
# a user policy disable.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-edit-task-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

# file_path + tool_name 단일 프로세스 추출 — sibling pre-edit-discipline-
# gate.sh 와 동일한 2-필드 추출 + 0x1F/LF 보안 하드닝(2026-08-19 보안 검토
# 실증 2건, 그 훅의 동일 지점 주석 참조). 이 훅은 TOOL_NAME 을 실제로
# 소비한다(active-task-gate.sh 의 delegate 가 도구별 정책 파일을 고르는
# 데 필요) — discipline-gate.sh 와 달리 이 필드가 dead 가 아니다.
EXTRACT_SEP=$'\x1f'
EXTRACT_OUT=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --field tool_name --default '' --separator "$EXTRACT_SEP")
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "[rein] The task gate cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $EXTRACT_RC). This is an installation issue — run 'rein update' to repair." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

# Security hardening 1/2 — 0x1F 구분자 개수 검증 (파일 경로 자체에 0x1F 가
# 섞여 있으면 read/파라미터-분할이 잘못된 지점에서 갈라질 수 있다 — 상세
# 근거는 pre-edit-discipline-gate.sh 의 동일 지점 주석 참조, 바이트 동일한
# 검사).
EXTRACT_SEP_STRIPPED="${EXTRACT_OUT//$EXTRACT_SEP/}"
EXTRACT_SEP_COUNT=$(( ${#EXTRACT_OUT} - ${#EXTRACT_SEP_STRIPPED} ))
if [ "$EXTRACT_SEP_COUNT" -ne 1 ]; then
  echo "[rein] The task gate cannot run because the tool input produced a malformed field extraction (found $EXTRACT_SEP_COUNT embedded separator(s), expected exactly 1 — a file path or tool name likely contains the internal separator character). This is a parsing safety check, not an installation issue; the edit is blocked to avoid mis-splitting the path." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

# Security hardening 2/2 — LF-safe 파라미터 확장 분할 (bash `read` 는 IFS 와
# 무관하게 첫 LF 에서 레코드를 끊는다 — 상세 근거는 pre-edit-discipline-
# gate.sh 의 동일 지점 주석 참조, 바이트 동일한 처리).
FILE_PATH="${EXTRACT_OUT%%"$EXTRACT_SEP"*}"
TOOL_NAME="${EXTRACT_OUT#*"$EXTRACT_SEP"}"

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Path normalize — 다른 모든 게이트와 동일 원칙 (os.path.normpath, 정규화
# 전/후 불일치 시 stderr NOTICE 만, gate 동작 변경 없음).
FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
  'import os,sys; print(os.path.normpath(sys.argv[1]))' \
  "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
[ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"
if [ "$FILE_PATH_NORM" != "$FILE_PATH" ]; then
  echo "NOTICE: pre-edit-task-gate normalized path: $FILE_PATH → $FILE_PATH_NORM" >&2
fi
FILE_PATH="$FILE_PATH_NORM"

# --- 경로 기반 면제 + 소스 판정 — sibling pre-edit-discipline-gate.sh 와
# 동일한 공유 분류기 (lib/source-path-classify.sh). 두 훅이 "이 경로가
# 소스인가"에서 절대 갈라지면 안 된다 (그 lib 헤더 참조).
if ! . "$SCRIPT_DIR/lib/source-path-classify.sh" 2>/dev/null; then
  echo "[rein] The task gate cannot run because a required library is missing (lib/source-path-classify.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_classify_source_path "$FILE_PATH"
[ "$REIN_SRC_CLASS" = "exempt" ] && exit 0

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# GMF-3 "왜 이 파일에 DoD 가 필요한가" 안내 — 공유 lib (아래 DENY 분기에서만
# 호출한다, "차단 시점에만 호출" 계약은 그대로 — lib/ext-source-notice.sh
# 헤더 참조).
if ! . "$SCRIPT_DIR/lib/ext-source-notice.sh" 2>/dev/null; then
  echo "[rein] The task gate cannot run because a required library is missing (lib/ext-source-notice.sh). Run 'rein update' to restore it." >&2
  exit 2
fi

# --- 활성 "작업" 축 전환 확인 + 위임 (lib/active-task-gate.sh 의 하위
# 함수 두 개만 재사용 — 이 훅 자신의 header 판정 트리 참조) ---
if ! . "$SCRIPT_DIR/lib/active-task-gate.sh" 2>/dev/null; then
  echo "[rein] The task gate cannot run because a required library is missing (lib/active-task-gate.sh). Run 'rein update' to restore it." >&2
  exit 2
fi

if rein_active_task_authority_switched; then
  rein_active_task_delegate
  case "$rein_active_task_delegate_result" in
    ALLOW)
      # v2 가 이 축을 충족으로 판정했다 — 이 훅에 v1 폴백은 없다(header 의
      # "의도된 방향 변화" 절 참조), 그대로 통과.
      exit 0
      ;;
    DENY)
      # v2 가 이 축을 차단으로 판정했다 — v2 가 낸 native JSON 을 그대로
      # relay 한다(재구성하지 않는다). sibling code_review/security_review
      # 축과 동일한 exit 관례(exit 0 + JSON deny)를 따른다.
      printf '%s\n' "$rein_active_task_delegate_json"
      emit_ext_source_notice
      log_block "활성 작업 위임 차단 (v2)" "$FILE_PATH"
      exit 0
      ;;
    *)
      # FAIL — 위임 실행 실패(엔진 스크립트 부재/손상, timeout, 이 도구용
      # 정책 파일 부재, 해석 불가한 출력 등). ⚠️ 의도된 방향 변화: 구
      # rein_check_active_task() 는 이 경우 v1 자신의 DOD_FOUND 판정으로
      # 흘려보냈다 — 이 훅은 그 폴백을 갖지 않는다. 판단 불능은 거부
      # 방향이다(design doc §3.4) — fail-closed.
      echo "[rein] The active-task axis could not be evaluated (v2 delegation failed, timed out, or returned an unparseable response) after authority for this axis was confirmed switched to v2. This edit is blocked until the underlying failure is fixed — there is no v1 fallback judgment for this axis anymore. Check the v2 engine installation (bin/rein) and .rein/policy/task-axis/ policy files." >&2
      log_block "활성 작업 위임 실패 (v2, fail-closed)" "$FILE_PATH"
      exit 2
      ;;
  esac
fi

# 전환되지 않았거나(NOT_SWITCHED) 전환 확인 자체가 실패(ERROR)했다 —
# rein_active_task_authority_switched() 가 채운 전역으로 구분한다(그
# 함수 자신의 반환값은 위 두 경우 모두 1 로 동일해 구분이 안 되므로,
# 이 훅 전용으로 추가된 lib/active-task-gate.sh 의 전역을 읽는다).
case "${rein_active_task_switch_check_kind:-ERROR}" in
  NOT_SWITCHED)
    # 축 명시 비활성 — 문서화된 opt-out. 이 프로젝트가 아직 active_task
    # capability 를 v2 로 전환하지 않았다는 뜻이며, 이 훅은 그 상태를
    # 그대로 존중해 통과시킨다(header 의 "의도된 방향 변화" 절 참조).
    exit 0
    ;;
  *)
    # ERROR — 전환 여부 확인 자체가 불가능했다(파이썬 부재/모듈 로드
    # 실패/정책 파일 손상/예외 등). fail-closed — 확인 불가를 "미전환"
    # 으로 오인해 조용히 통과시키는 것보다 항상 안전한 방향이다.
    echo "[rein] The task gate cannot run because whether the active-task axis has been switched to v2 could not be determined (Python failure, module load failure, or corrupt policy). This edit is blocked until the check can succeed. Run 'rein update' or check your Python installation." >&2
    log_block "활성 작업 전환 확인 실패 (fail-closed)" "$FILE_PATH"
    exit 2
    ;;
esac
