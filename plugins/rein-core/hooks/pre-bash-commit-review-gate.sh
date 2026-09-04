#!/bin/bash
# Hook: PreToolUse(Bash), dispatched child — commit REVIEW axes (code_review +
# security_review) 전담 — v2 governance authority 로의 1급(first-class) 위임
# 래퍼.
#
# Phase 7 웨이브 3 ③-c (commit-gate 교대): 이 훅은 신설이다. (구)
# pre-bash-test-commit-gate.sh 의 리뷰 stamp 최종 판정(그 파일의
# check_review_stamp(), [P3]~[P6] — 두 축의 rein_check_code_review_stamp /
# rein_check_security_review_stamp 호출 두 줄)이 여기로 전량 이관됐다.
# sibling pre-bash-commit-discipline-gate.sh(coverage matrix [P2]/[I3] +
# 커밋 메시지 포맷 [P7]/[I4]/[I5] 등 그 외 v1 존속 규율을 계승)는 이 두
# 축을 전혀 다루지 않는다 — 두 훅은 각자 다른 축의 소유자다(sibling
# pre-edit-discipline-gate.sh / pre-edit-task-gate.sh 의 분리와 동일한
# 원리, ③-b 참조).
#
# 등록/실행 모델 (③-c 순차 디스패처 확장, 2026-08-23): hooks.json 은
# pre-bash-dispatcher.sh 하나만 PreToolUse(Bash) 에 등록하고, 그 디스패처의
# Step 3(CLASS_NEEDS_TC=1 일 때만)이 이제 두 자식 —
# pre-bash-commit-discipline-gate.sh → 이 훅 — 을 **순서를 보장해 순차**
# 실행하며 첫 차단(exit 2) 또는 JSON deny relay(exit 0 + stdout)에서 즉시
# 중단한다(그 디스패처 자신의 헤더 참조 — 왜 두 자식으로 쪼갰는지, 그리고
# pre-edit-dispatcher.sh 의 캡처-릴레이-중단 선례를 그대로 가져왔는지).
# 이 파일이 테스트 하네스에 의해 디스패처 없이 **직접** 호출되는 경로
# (단위 테스트)는 여전히 존재하고 계속 유효하다 — 그 경우 이 훅은 자신의
# 판정만 독립적으로 수행한다.
#
# 이 훅은 lib/code-review-gate.sh + lib/security-review-gate.sh 의 하위
# 함수 네 개(rein_code_review_authority_switched / rein_code_review_delegate
# / rein_security_review_authority_switched / rein_security_review_delegate)
# 만 직접 재사용한다 — 두 lib 의 구 진입점(rein_check_code_review_stamp /
# rein_check_security_review_stamp)은 이 교대와 **같은 커밋에서 lib 에서
# 제거됐다**. 그 진입점 안의 "v1 폴백 최종 판정"(미전환이거나 위임이 FAIL
# 일 때 stamp 파일 mtime 비교 등으로 v1 이 직접 판정하던 분기)이 바로 이
# 훅이 의도적으로 없애는 대상이기 때문이다 — 아래 판정 트리 참조. (legacy
# 표식 파일 자체의 쓰기 경로·v2 내부 dual-read 청산은 ③-d 소관으로 잔존.)
#
# 판정 트리 (부모 확정 설계, Phase 7 웨이브 3 ③-c — pre-edit-task-gate.sh
# 의 5분기 트리를 두 축에 순차 적용한 것과 동형이다, §3.6 5분기 참조):
#   축별(code_review → security_review 순, v1 이 검사하던 순서 그대로
#   보존 — check_review_stamp() 의 두 호출 순서와 동일):
#     전환됨 + ALLOW → 다음 축 진행 (마지막 축이면 exit 0)
#     전환됨 + DENY  → v2 JSON 그대로 relay + log_block + exit 0 (JSON deny
#       관례 — sibling pre-edit-task-gate.sh 의 활성-작업 축과 동일 형식)
#     전환됨 + FAIL(위임 실행 실패·timeout·응답 파싱 불능) → fail-closed
#       exit 2 + 명확한 stderr. v1 폴백 없음 — 의도된 방향 변화(아래 참조).
#     미전환(capability off) → 해당 축 skip(exit 0 방향, 다음 축 진행) —
#       문서화된 opt-out(§3.6 5분기 ④).
#     전환 상태 확인 자체가 실패(파이썬 부재/모듈 손상/예외 등) →
#       fail-closed exit 2 (§3.6 5분기 ⑤).
#
# ⚠️ 의도된 방향 변화 (이 교대에서 구 동작과 달라지는 지점 — 나머지는
# 동작 보존이 계약, pre-edit-task-gate.sh 헤더의 동일 절과 같은 서술
# 구조):
#   (a) DOD_EXISTS(활성 DoD 존재) 선행조건이 이 훅에 없다. 구
#   rein_check_code_review_stamp() / rein_check_security_review_stamp() 는
#   각자 독립적으로 "trail/dod/ 에 DoD 파일이 하나라도 있는가"부터 확인해,
#   없으면 그 즉시 이 축 전체를 통과시켰다(v1 시절 유일한 "리뷰가 왜
#   필요한가"의 게이트 — 그 게이트 자체가 없으면 리뷰 요구도 없었다). 이
#   훅은 그 선행조건을 계승하지 않는다 — "커밋에 code_review/security_review
#   가 필요한가"는 이제 v2 기본 정책의 task.exists 조건
#   (plugins/rein-core/policies/default/commit.yaml)이 판정한다(Phase 7
#   선행 결정 1). 즉 "DoD 가 없으면 리뷰도 면제"라는 v1 의 판단은 이
#   훅에서 사라진 것이 아니라, v2 policy 평가 안으로 이동했다 — v2 가
#   ALLOW 를 내는 경로 중 하나가 바로 "이 커밋이 요구하는 task 가 없다"는
#   판정이다.
#   (b) 보안 축의 v1 면제 2종(RT-1 경량 등급 + 보안-surface 면제 —
#   security-review-gate.sh 의 _sx_* 함수군)은 이 훅에서 계산하지 않는다.
#   v2 판정 재료(strict digest scope 프로필의 subject-empty=충족 등, §3.6
#   security_review "digest scope 프로필" 절)가 그 판단을 대체한다 — 이
#   훅은 면제를 스스로 계산하지 않고 v2 위임 결과를 그대로 신뢰한다.
#
# "미전환"과 "확인 자체 실패"를 구분하기 위해 각 lib 의
# rein_{code_review,security_review}_authority_switched() 가 채우는 전역
# `rein_{code_review,security_review}_switch_check_kind`
# ("SWITCHED"|"NOT_SWITCHED"|"ERROR")를 그 함수 호출 직후 읽는다 —
# pre-edit-task-gate.sh 가 active_task 축에서 하는 것과 정확히 같은 패턴.
#
# Exit code: 0=허용(또는 JSON deny relay), 2=차단

# Security (High — sibling pre-edit-task-gate.sh 와 동일한 재현·수리, 그
# 훅의 동일 지점 주석 참조): REIN_GATE_PEEK_MODE 는 Edit 계열 게이트의
# peek 계약 값이며, 이 Bash 계열 게이트가 외부 상속으로 물려받아서는 안
# 된다. 이 훅이 직접 source 하는 두 lib 는 현재 이 변수를 읽지 않지만,
# 방어 원칙은 동일하게 적용한다 — "판정 lib 를 진짜로 집행하는
# 프로세스"라는 사실 자체가 이 변수의 외부 상속을 절대 허용하지 않아야
# 하는 이유다.
unset REIN_GATE_PEEK_MODE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Identity for blocks.jsonl + THRESHOLD counting (bash-guard-infra.sh 계약 —
# 반드시 소싱 전에 설정).
BG_GUARD_NAME="pre-bash-commit-review-gate"

# shellcheck source=./lib/bash-guard-infra.sh
# 공유 infra (log_block + command_invokes). `if !` 형태로 소싱해 lib 자체의
# 구문 오류도 fail-closed 로 잡는다 — 다른 Bash 계열 게이트와 동일 관례.
if ! . "$SCRIPT_DIR/lib/bash-guard-infra.sh" 2>/dev/null; then
  echo "[rein] The commit review gate cannot run because its shared infrastructure (lib/bash-guard-infra.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# [I6] 미해당 — 이 훅은 bg_infra_init() 을 호출하지 않는다. 그 함수는
# lib/json-deny-emitter.sh 를 로드하고 deny_emit 이 실제 함수로 정의됐는지
# 검증하는 것이 유일한 목적이다. 이 훅은 deny_emit 을 절대 호출하지
# 않는다 — v2 위임이 DENY 를 내면 그 JSON 을 그대로 relay 할 뿐, 이 훅
# 스스로 DENY JSON 을 구성하지 않는다(위 헤더의 판정 트리 참조). 따라서
# emitter 정합성 검증 자체가 이 훅에는 무의미하다.
#
# 다만 log_block()(bash-guard-infra.sh 제공, 위에서 이미 소싱됨)의 감사
# 기록 기능은 이 훅도 그대로 쓴다 — bg_infra_init 이 하는 두 가지 일 중
# 필요한 절반(BG_LOG_HELPER 설정)만 직접 수행한다. bg_infra_init 을
# 통째로 호출하면 쓰지도 않을 deny_emit 검증 실패가 이 훅을 불필요하게
# fail-close 시킬 수 있어(예: emitter lib 손상 — 이 훅의 정상 동작과
# 무관한 실패), 필요한 절반만 취하는 쪽이 더 정확한 fail-closed 표면이다.
BG_LOG_HELPER="$SCRIPT_DIR/lib/rein-log-block.py"

# Shadow Corpus 관측 (fire-and-forget) — 구 단일 훅(pre-bash-test-commit-
# gate.sh)에서는 두 리뷰 축의 판정도 그 훅 하나의 shadow_capture_init 아래
# 관측됐다. 이 축들이 독립 프로세스(이 훅)로 분리된 이상, 여기서도
# 초기화하지 않으면 관측 공백이 생긴다 — sibling pre-edit-task-gate.sh 와
# 동일한 원리로 자신의 이름으로 초기화한다.
. "$SCRIPT_DIR/lib/shadow-capture.sh" 2>/dev/null && shadow_capture_init "pre-bash-commit-review-gate"

INPUT=$(cat)

# [I1] infra integrity — python3 필수 (JSON 파싱 + v2 위임 호출).
bg_resolve_python_or_die

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form, own key,
# ③-c 리뷰 1회차 High 수리로 STRICT 계약 전환 ---
# .rein/policy/hooks.yaml 은 `pre-bash-commit-review-gate: false` 또는
# `{ pre-bash-commit-review-gate: { enabled: false } }` 로 이 훅을 끌 수
# 있다. 다른 모든 게이트와 동일한 순서 계약: 이 검사는 bg_resolve_python_
# or_die 이후에만 실행되므로(이미 인터프리터 부재를 fail-closed 했다),
# 인터프리터 부재가 사용자 정책 비활성으로 오인되는 일은 없다.
#
# STRICT 계약(0/78/그 외) — GMF-4 조건 갱신: 로더의 `--strict <hook-name>`
# 모드를 쓴다(구 bare-hook-name 모드 아님).
#   rc == 78 (EX_CONFIG) → 로더가 정상 실행됐고 "명시적 비활성" → exit 0
#   rc == 0               → enabled → 게이트 본문 계속(활성)
#   rc ∉ {0,78} (rc==1 포함) → 로더 호출 실패 → fail-closed(게이트 활성 유지)
# 왜 rc 1 이 더 이상 "비활성"이 아닌가: 구 bare-hook-name 계약(0=enabled/
# 1=disabled)은 로더 자체가 깨진 상태와 근본적으로 구분 불가능했다 —
# python SyntaxError 나 처리되지 않은 예외도 똑같이 rc 1 로 exit 하므로,
# rc==1 을 "비활성"으로 읽는 호출부는 실제 사용자 정책 선택과 손상된
# 로더를 구분할 수 없었다. 리뷰 1회차(High)가 이를 그대로 재현했다 —
# 구문 오류 로더로 바꿔치기하면 신설 커밋 게이트 두 훅 모두 이 구
# rc==1 분기를 통해 exit 0(fail-open)됐다. `--strict` 모드의 rc 78 은 그런
# 충돌이 없다(전체 근거는 로더 자신의 `--strict` 분기 주석 참조). 버전
# skew 안전성: `--strict` 를 모르는 구버전 로더는 자신의 레거시 기본
# 분기로 떨어져 is_enabled("--strict") 를 평가한다 — "--strict" 는 어떤
# 프로젝트의 hooks.yaml 에도 실재 훅 이름으로 등장하지 않으므로 rc 0
# (enabled) 을 반환한다 — 훅 스크립트와 로더 버전이 어긋나도 항상
# "활성" 방향으로 귀결되며, 조용한 비활성은 없다.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" --strict "pre-bash-commit-review-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 78 ]; then
    exit 0  # 로더 정상 실행 + 사용자 정책으로 명시 비활성
  fi
  # rc 0 = enabled(계속); rc ∉ {0,78}(rc 1 포함) = 로더 호출 실패 → fail-closed.
fi

# [I2] infra integrity — tool_input.command 파싱. COMMAND 전역을 without
# command substitution 으로 채운다(fail-close 가 top level 에 닿아야 하는
# 이유는 bash-guard-infra.sh 자신의 bg_extract_command 주석 참조).
COMMAND=""
bg_extract_command "$SCRIPT_DIR" "$INPUT" || exit 2

if [ -z "$COMMAND" ]; then
  exit 0
fi

# canonical git subcommand token model (SSOT) — GMF-1/GMF-2. 이 훅도 구
# pre-bash-test-commit-gate.sh 와 동일하게 HARD-FAIL 소비자다: lib 부재/손상
# 또는 $GIT_COMMIT_ERE/$GIT_MERGE_ERE 가 비어 있으면 fail-closed. 빈 ERE 를
# command_invokes 에 넘기면 매처가 신뢰 불가능해진다(전체 매치/오분류
# 위험) — 특히 빈 $GIT_MERGE_ERE 는 모든 커밋을 면제(fail-open)할 수 있고,
# 빈 $GIT_COMMIT_ERE 는 리뷰 게이트 자체를 무력화할 수 있다.
if ! { [ -f "$SCRIPT_DIR/lib/git-subcommand-model.sh" ] \
       && . "$SCRIPT_DIR/lib/git-subcommand-model.sh" \
       && [ -n "${GIT_COMMIT_ERE:-}" ] && [ -n "${GIT_MERGE_ERE:-}" ]; }; then
  echo "[rein] The commit review gate cannot run because its git-subcommand token model (lib/git-subcommand-model.sh) could not be loaded — it may be missing or corrupt. Run 'rein update' to repair the installation." >&2
  exit 2
fi

# --- 조기 종료 (v1 의미 보존, 순서 고정) ---

# (a) merge/rebase/am commit 은 리뷰 축 검사에서 면제 — 메시지를 자동
# 생성하는 커밋이라 사람이 작성한 코드 변경에 대한 리뷰 요구 대상이
# 아니다(GMF-2 앵커 근거는 구 pre-bash-test-commit-gate.sh 의 동일 지점
# 주석 참조 — 비앵커 substring 매치는 커밋 *메시지 본문*의 리터럴
# "git merge" 언급까지 오매칭했다).
if command_invokes "$GIT_MERGE_ERE"; then
  exit 0
fi

# (b) 커밋이 아니면 이 훅의 대상이 아니다 — 테스트 실행(pytest/jest 등)은
# GUARD-1(2026-05-19, need-to-confirm.md)대로 리뷰 게이트 비대상이다: TDD
# red-green 루프가 코드 작성/리뷰 이전에 실패하는 재현 테스트를 돌릴 수
# 있어야 한다. 게이트 대상은 *커밋/완료 선언*이며, 그것은 바로 이 훅이
# 담당한다.
if ! command_invokes "$GIT_COMMIT_ERE"; then
  exit 0
fi

# (c) 샌드박스 커밋 면제 (GSD-3, dod-2026-08-05-gate-scope-defects) — 리터럴
# 절대경로 cd 로 저장소 밖에 들어간 커밋은 이 저장소의 커밋이 아니므로
# 리뷰 게이트 대상에서 제외한다. 변수/불명 cd 는 기존대로 판정(확실할
# 때만 면제, FN 금지) — 상세 계약은 lib/git-subcommand-model.sh 의
# git_commit_outside_repo_cd() 헤더 참조.
if git_commit_outside_repo_cd "$COMMAND" "$PROJECT_DIR"; then
  echo "NOTICE: [commit-review-gate] git commit runs under a literal cd outside this repository — review axes skipped for this command (sandbox commit, not this repo)." >&2
  exit 0
fi

# --- 두 리뷰 lib 하드 소싱 (fail-closed) ---
# 이 훅이 소비하는 것은 각 lib 의 전환확인/위임 하위 함수 4개와
# switch_check_kind 전역 2개뿐이다(위 헤더 참조) — lib 의 구 v1 판정
# 진입점은 ③-c 에서 제거되어 존재하지 않는다.
if ! . "$SCRIPT_DIR/lib/code-review-gate.sh" 2>/dev/null; then
  echo "[rein] The commit review gate cannot run because a required library is missing (lib/code-review-gate.sh). Run 'rein update' to repair the installation." >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/security-review-gate.sh" 2>/dev/null; then
  echo "[rein] The commit review gate cannot run because a required library is missing (lib/security-review-gate.sh). Run 'rein update' to repair the installation." >&2
  exit 2
fi

# ============================================================
# 축 1 — code_review (v1 검사 순서 보존: code_review 가 먼저)
# ============================================================
if rein_code_review_authority_switched; then
  rein_code_review_delegate
  case "$rein_code_review_delegate_result" in
    ALLOW)
      # v2 가 이 축을 충족으로 판정했다 — 다음 축(security_review)으로.
      :
      ;;
    DENY)
      # v2 가 이 축을 차단으로 판정했다 — v2 가 낸 native JSON 을 그대로
      # relay 한다(재구성하지 않는다). sibling active_task 축과 동일한
      # exit 관례(exit 0 + JSON deny)를 따른다.
      printf '%s\n' "$rein_code_review_delegate_json"
      log_block "코드 리뷰 위임 차단 (v2)" "$COMMAND"
      exit 0
      ;;
    *)
      # FAIL — 위임 실행 실패(엔진 스크립트 부재/손상, timeout, 해석 불가한
      # 출력 등). ⚠️ 의도된 방향 변화: 이 훅은 v1 폴백(stamp 파일 mtime
      # 비교)을 갖지 않는다. 판단 불능은 거부 방향이다 — fail-closed.
      echo "[rein] The code-review axis could not be evaluated (v2 delegation failed, timed out, or returned an unparseable response) after authority for this axis was confirmed switched to v2. This commit is blocked until the underlying failure is fixed — there is no v1 fallback judgment for this axis anymore. Check the v2 engine installation (bin/rein)." >&2
      log_block "코드 리뷰 위임 실패 (v2, fail-closed)" "$COMMAND"
      exit 2
      ;;
  esac
else
  # 전환되지 않았거나(NOT_SWITCHED) 전환 확인 자체가 실패(ERROR)했다 —
  # rein_code_review_authority_switched() 가 채운 전역으로 구분한다(그
  # 함수 자신의 반환값은 두 경우 모두 1 로 동일해 구분이 안 되므로, 이 훅
  # 전용으로 추가된 전역을 읽는다 — pre-edit-task-gate.sh 와 동일 패턴).
  case "${rein_code_review_switch_check_kind:-ERROR}" in
    NOT_SWITCHED)
      # 축 명시 비활성 — 문서화된 opt-out. 다음 축(security_review)으로.
      :
      ;;
    *)
      # ERROR — 전환 여부 확인 자체가 불가능했다. fail-closed — 확인
      # 불가를 "미전환"으로 오인해 조용히 통과시키는 것보다 항상 안전한
      # 방향이다.
      echo "[rein] The commit review gate cannot run because whether the code-review axis has been switched to v2 could not be determined (Python failure, module load failure, or corrupt policy). This commit is blocked until the check can succeed. Run 'rein update' or check your Python installation." >&2
      log_block "코드 리뷰 전환 확인 실패 (fail-closed)" "$COMMAND"
      exit 2
      ;;
  esac
fi

# ============================================================
# 축 2 — security_review (v1 검사 순서 보존: security_review 가 두 번째)
# ============================================================
#
# 축 설정 가드 선행 (구 lib 의 HOLE FIX 시나리오 (j) 를 구조적으로
# 계승 — hooks/lib/security-review-gate.sh 의 rein_security_review_
# delegate() 헤더 참조): 그 시나리오는 "정책 폴더는 있는데 commit-
# security.yaml 만 없으면 매칭 policy 0개 = v2 native ALLOW({}) 로
# 되돌아와, 위임 분류상 정상 ALLOW 로 보이지만 실제로는 이 축의 요구
# 전체가 로그도 에러도 없이 사라진다"는 것이었다. 그 HOLE FIX 는
# delegate() 내부에서 파일 부재를 FAIL 로 전환해 v1 이 이어서 직접
# 판정하게 만드는 방식이었다 — 그러나 이 훅에는 그 v1 폴백이 없다(위
# 판정 트리 참조). 그래서 이 훅은 위임을 시도하기 전에 축 설정 자체를
# 먼저 점검한다 — 전환 여부와 무관하게(미전환이어도) 이 축을 판정할
# 정책이 어디에도 없는 상태를 조용한 opt-out 으로 흘려보내지 않는다. 이
# 검사는 switched/delegate 트리보다 앞선다(先行) — 축이 아예 사라지는
# 경로를 원천 차단하는 것이 목적이라, 전환 상태 분기 안쪽에 두면 미전환
# 경로가 이 검사를 우회하게 된다.
#
# 정책 위치는 hooks/lib/security-axis-policy-resolve.sh 의
# rein_security_axis_policy_resolve() 로 해소한다 — project override
# (.rein/policy/security-axis/) → 배포 번들(<plugin-root>/policies/
# security-axis/) 순, hooks/lib/security-review-gate.sh 의 delegate 가 쓰는
# 것과 완전히 같은 함수(그 lib 가 이미 이 함수를 소싱해 두었으므로 여기서
# 다시 source 하지 않는다 — 위 "두 리뷰 lib 하드 소싱" 블록이 이미 이
# 함수를 이 프로세스에 로드했다). "폴더 없음 = opt-out" 이라는 구 가정은
# 더 이상 성립하지 않는다 — 배포 번들이 있는 한 project override 를 지운
# 것만으로는 이 축이 꺼지지 않는다(active_task 축의 동일한 위변조 가드
# 강화, hooks/lib/active-task-gate.sh 의 "위변조 가드는 오히려 강화된다"
# 절과 동일한 원리). 이 축의 유일한 문서화된 opt-out 은 `.rein/policy/
# authority.yaml` 로 capability 를 switched 목록에서 빼는 것뿐이며, 그
# 판정은 아래 switched-check 가 담당한다.
rein_security_axis_policy_resolve "$PROJECT_DIR" "$_REIN_SRG_PKG_PARENT"
case "$rein_security_axis_policy_kind" in
  PROJECT|BUNDLE)
    # 정책을 어느 계층에서든 찾았다 — 아래 switched-check + 위임으로.
    :
    ;;
  PROJECT_DAMAGED)
    # 프로젝트 오버라이드 폴더는 있는데 commit-security.yaml 이 없다 —
    # 의도된 미선언이 아니라 설정 손상 가능성이 높다. 배포 번들로도
    # 넘어가지 않는다(resolver 자신의 계약 — 손상된 설정을 그럴듯한
    # 기본값으로 가리면 사용자가 자신의 설정이 깨졌다는 사실 자체를 알
    # 길이 없어진다). fail-closed — 축이 로그 없이 사라지는 방향을
    # 금지한다.
    echo "[rein] The commit review gate cannot evaluate the security-review axis because its project policy path (.rein/policy/security-axis) exists but is not a usable policy folder — either commit-security.yaml is missing inside it, or the path is not a directory at all (a regular file or a dangling symbolic link). This looks like damaged configuration, not an intentional opt-out — removing the whole folder no longer disables this axis either (the plugin's bundled default policy takes over). The commit is blocked until the file is restored, or the whole folder is removed to fall back to the bundled default." >&2
    log_block "보안 축 설정 손상 (fail-closed)" "$COMMAND"
    exit 2
    ;;
  *)
    # NONE — project override 도, 배포 번들도 없다. 이것은 opt-out 이
    # 아니라 설치 손상이다: security_review 는 배포 기본으로 v2 전환돼
    # 있어 정상 플러그인 install 은 항상 번들 정책을 갖고 있어야 한다
    # (hooks/pre-edit-task-gate.sh 의 동형 fail-closed 안내와 같은
    # 형태 — active_task 축의 동일한 "정책이 배포본에 있어야 한다" 계약).
    echo "[rein] The commit review gate cannot evaluate the security-review axis because no policy for it could be found anywhere — not in this project's override (.rein/policy/security-axis/) and not in the plugin's bundled default. The security-axis policy ships with the plugin; if it is missing, your install is damaged — reinstall the plugin with 'claude plugin update rein' to restore it. Do not hand-craft policy files to bypass this. The commit is blocked until the policy is restored." >&2
    log_block "보안 축 정책 없음 (fail-closed)" "$COMMAND"
    exit 2
    ;;
esac

if rein_security_review_authority_switched; then
  rein_security_review_delegate
  case "$rein_security_review_delegate_result" in
    ALLOW)
      # v2 가 이 축을 충족으로 판정했다 — 더 남은 축이 없다, 최종 exit 0.
      :
      ;;
    DENY)
      printf '%s\n' "$rein_security_review_delegate_json"
      log_block "보안 리뷰 위임 차단 (v2)" "$COMMAND"
      exit 0
      ;;
    *)
      echo "[rein] The security-review axis could not be evaluated (v2 delegation failed, timed out, or returned an unparseable response) after authority for this axis was confirmed switched to v2. This commit is blocked until the underlying failure is fixed — there is no v1 fallback judgment for this axis anymore. Check the v2 engine installation (bin/rein) and the security-axis policy (project override at .rein/policy/security-axis/, or the plugin's bundled default)." >&2
      log_block "보안 리뷰 위임 실패 (v2, fail-closed)" "$COMMAND"
      exit 2
      ;;
  esac
else
  case "${rein_security_review_switch_check_kind:-ERROR}" in
    NOT_SWITCHED)
      # 축 명시 비활성 — 문서화된 opt-out. 더 남은 축이 없다, 최종 exit 0.
      :
      ;;
    *)
      echo "[rein] The commit review gate cannot run because whether the security-review axis has been switched to v2 could not be determined (Python failure, module load failure, or corrupt policy). This commit is blocked until the check can succeed. Run 'rein update' or check your Python installation." >&2
      log_block "보안 리뷰 전환 확인 실패 (fail-closed)" "$COMMAND"
      exit 2
      ;;
  esac
fi

exit 0
