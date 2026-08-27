# lib/shadow-capture.sh — v1 hook → Shadow Corpus 백그라운드 capture shim
# (plan Task 2.8, `docs/plans/2026-08-08-rein-v2-governance-orchestration.md`
# §Task 2.8, spec §6.4).조건: Task 2.0 SPIKE-2 판정 = 채택.
#
# 계약 (절대 불변): capture 의 성공/실패/지연/오류가 v1 게이트의 판정·
# exit code·출력에 어떤 영향도 주면 안 된다 (fire-and-forget). 이를
# 위해 이 파일이 하는 모든 실질 작업(마스킹·corpus 반입)은:
#   1) 훅 프로세스가 종료되기 직전 EXIT trap 에서만 시작하고
#   2) 항상 백그라운드 서브셸(`&`)로 던지며 훅 프로세스는 기다리지 않고
#   3) stdin/stdout/stderr 를 전부 버려 훅의 stdout(JSON deny 등)과
#      섞이거나 Claude Code 의 EOF 대기를 지연시키지 않고
#   4) python 쪽은 전부 `except Exception: pass` 로 감싸 무엇이 실패해도
#      조용히 사라진다.
#
# 단일 삽입 지점 계약 — 각 훅은 정확히 1줄만 추가한다:
#   . "$SCRIPT_DIR/lib/shadow-capture.sh" 2>/dev/null && shadow_capture_init "<hook-name>"
# (source 자체가 깨져도 `&&` 가 훅을 절대 막지 않는다 — 그냥 skip.)
#
# 동작 원리 — SPIKE-2 harness(`tests/perf/spike2_capture_cost.sh`, 채택
# 판정 근거)가 검증한 "deny_emit/log_block 함수 래핑 + EXIT trap" 패턴을
# 그대로 재사용한다: 훅 파일 안의 exit 지점을 하나하나 건드리지 않고
# `shadow_capture_init` 호출 1곳만으로 그 훅의 모든 decision 경로
# (P1~P11, DoD gate 차단, review/spec-review 마커 생성 등)를 관측한다.
# SPIKE-2 와의 차이는 마스킹 구현체 하나뿐이다: SPIKE-2 프로토타입은 sed
# 기반 마스킹을 자체 구현했지만(측정 전용, 영구 채택 대상 아님), 이 버전은
# masking SSOT(`rein.shadow.masking`, Task 2.6)를 capture/corpus 계층
# (Task 2.7)을 통해 그대로 쓴다 — 이 파일은 마스킹 정규식을 재구현하지
# 않는다. python 서브프로세스를 동기 호출하지 않고 백그라운드로 미루는
# 이유는 보안 리뷰 권고다: python 인터프리터 기동 비용이 sed 한 줄보다
# 훨씬 크므로, 동기 호출은 매 도구 호출마다 지연을 더할 수 있다.
#
# 훅마다 deny_emit/log_block 이 항상 존재하는 건 아니다 (post-edit-*-gate.sh
# 류는 마커만 남기고 항상 exit 0) — `declare -F` 가드가 없는 함수는 조용히
# 건너뛰고, 그 경우 v1_decision 은 exit code 만으로 판정하고 v1_reason 은
# 빈 문자열로 남는다. 이는 계약 위반이 아니다 — corpus.py 의 최소 스키마는
# "필드가 존재" 를 요구하지 "항상 채워짐" 을 요구하지 않는다.

# 같은 훅 프로세스 안에서 두 번 source 돼도 안전하게 no-op.
if [ -n "${_SHADOW_CAPTURE_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_SHADOW_CAPTURE_LIB_LOADED=1

# 이 파일 자신의 위치에서 rein 패키지의 부모 디렉토리를 구한다 — 어느
# 훅이 source 하든, 설치 방식(plugin tarball/dev repo)이 무엇이든 상대
# 위치로 항상 올바르게 찾는다 (bin/rein 의 `_locate_package_parent()` 와
# 동일한 원리 — 패키지 *부모* 만 sys.path 에 넣어야 `rein/platform` 이
# stdlib `platform` 을 가리는 사고를 피한다).
#   hooks/lib/shadow-capture.sh → (..) hooks → (..) <plugin root>
_SHADOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SHADOW_PKG_PARENT="$(cd "$_SHADOW_LIB_DIR/../.." && pwd)"

_SHADOW_HOOK_NAME=""
_SHADOW_REASONS=""
_SHADOW_DENIED=0
_SHADOW_SUBJECT=""

_shadow_note() {
  _SHADOW_REASONS="${_SHADOW_REASONS:+$_SHADOW_REASONS; }$1"
}

# shadow_capture_set_subject <path>
#   opt-in setter — 훅이 이번 호출의 기록 대상(subject) 을 명시적으로
#   알려준다 (code review MEDIUM 수정, 2026-08-10). 존재 이유: 이 훅 중
#   post-edit-spec-review-gate.sh 류(작성 당시엔 Phase 7 웨이브 3 ③-d 에서
#   삭제된 post-edit-review-gate.sh 도 같은 류였다)는
#   `while IFS= read -r FILE_PATH; do ... done <<< "$FILE_PATHS"` 관용구를
#   쓴다 — bash 의 here-string 은 끝에 개행을 보장하고, 루프를 끝내는
#   마지막(EOF) `read` 호출(while 조건을 깨는 그 호출)도 실패하기 직전에
#   변수에 빈 문자열을 대입한다. `break` 로 탈출하는 경로(예: 옛
#   post-edit-review-gate.sh 가 소스 확장자를 찾자마자 break 하던 것)는 이
#   마지막 read 자체가 실행되지 않으니 안전하지만, 끝까지 순회하고 자연
#   종료하는 경로(post-edit-spec-review-gate.sh 는 애초에 break 가 없다)는 EXIT trap
#   시점에 루프 변수가 이미 "" 로 덮여 있다 — capture 가 매번(또는 소스가
#   아닌 파일 편집일 때) subject 를 빈 값으로 기록하는 결함의 근본 원인.
#   해결: 루프 몸체 안, 경로가 확정되는 지점에서 이 함수로 별도 전역
#   (`_SHADOW_SUBJECT`) 에 값을 보관한다 — 이 전역은 그 마지막 실패한
#   `read` 의 대입 대상이 아니므로 루프 변수의 생애주기와 완전히 분리된다.
#   스칼라 `$COMMAND`/`$FILE_PATH` 를 그대로 쓰는 나머지 3개 훅
#   (pre-bash-safety-guard/pre-bash-test-commit-gate/pre-edit-dod-gate) 는
#   이 함수를 호출하지 않으므로 `_SHADOW_SUBJECT` 는 빈 채로 남고, 아래
#   `_shadow_on_exit` 의 fallback 체인이 그대로 `$FILE_PATH` 로 내려가
#   기존 동작이 무영향이다.
shadow_capture_set_subject() {
  _SHADOW_SUBJECT="$1"
}

# EXIT trap 본체. `trap '_shadow_on_exit $?' EXIT` 로 등록 — 원래 exit
# status 를 인자로 명시 전달받는다(트랩 안에서 커맨드를 실행하며 $? 가
# 덮이는 사고를 피하기 위해 SPIKE-2 harness 와 동일하게 인자로 캡처).
# 이 함수는 절대 `exit`/`return`으로 상태를 바꾸지 않는다 — 마지막
# 커맨드가 성공(0)으로 끝나도 트랩이 프로세스의 실제 종료 코드를
# 바꾸지 않는다는 것은 SPIKE-2 harness 의 11/11 포착률·rc 일치 실측으로
# 이미 검증된 전제다(같은 패턴 재사용, 신규 검증 아님).
_shadow_on_exit() {
  local rc="$1" decision

  if [ "$_SHADOW_DENIED" = 1 ]; then
    decision="BLOCK"                        # JSON deny 프로토콜 (exit 0 + deny)
  elif [ "$rc" -eq 2 ]; then
    decision="BLOCK"                        # stderr 프로토콜 (exit 2, fail-closed)
  elif [ "$rc" -eq 0 ]; then
    if [ -n "$_SHADOW_REASONS" ]; then
      decision="ALLOW_WITH_BYPASS"          # 통과했지만 bypass/경고 사유 존재
    else
      decision="ALLOW"
    fi
  else
    decision="ERROR"
  fi

  # python 인터프리터 선택 — 훅이 이미 resolve_python 을 거쳤다면
  # PYTHON_RUNNER(배열)를 그대로 재사용하고, 없으면 python3 로 최종
  # 폴백한다. 어느 쪽도 없으면 capture 를 아예 던지지 않는다 (실패
  # 조용히 무시 — 게이트는 이미 자기 exit code 로 확정된 뒤이므로
  # 이 분기 자체가 게이트 판정에 영향을 줄 여지가 없다).
  _shadow_py=()
  if [ -n "${PYTHON_RUNNER+x}" ] && [ "${#PYTHON_RUNNER[@]}" -gt 0 ]; then
    _shadow_py=("${PYTHON_RUNNER[@]}")
  elif command -v python3 >/dev/null 2>&1; then
    _shadow_py=(python3)
  fi

  if [ "${#_shadow_py[@]}" -gt 0 ]; then
    # --- fire-and-forget: 백그라운드 서브셸, 표준 입출력 전부 버림 ---
    # subject 원문(raw command/file path)은 여기서 절대 마스킹하지 않는다
    # — python 쪽 capture.py 가 capture 단계부터 masked representation 을
    # 만드는 SSOT 이므로(spec §46), bash 는 원문을 그대로 argv 로 넘기기만
    # 한다. argv 로 넘기는 이유: heredoc 안 python 소스는 고정 리터럴이라
    # 데이터가 소스 안에 섞여 들어갈 삽입 경로가 없다 — 셸 인용/이스케이프
    # 버그로 인한 injection 위험을 원천적으로 피한다.
    # bash 쪽에서 command_text 를 미리 자르지 않는다 — capture.py 의
    # `build_redacted_command()` 는 "마스킹 이후에만 절단" 순서를 지켜야
    # secret 값 중간이 잘려 평문 조각이 남는 결함을 피한다(그 모듈
    # docstring 참조); 여기서 선절단하면 그 보장을 무력화한다.
    (
      "${_shadow_py[@]}" - \
        "$_SHADOW_PKG_PARENT" "$PROJECT_DIR" "$_SHADOW_HOOK_NAME" \
        "$decision" "$_SHADOW_REASONS" "${COMMAND:-${_SHADOW_SUBJECT:-${FILE_PATH:-}}}" \
        <<'PY'
import sys

def _main():
    if len(sys.argv) < 7:
        return
    package_parent, project_root, hook_name, decision, reason, command_text = sys.argv[1:7]
    sys.path.insert(0, package_parent)
    from rein.shadow import capture as shadow_capture
    from rein.shadow import corpus as shadow_corpus

    case = shadow_capture.capture(
        event=hook_name,
        facts={"hook": hook_name},
        command_text=command_text,
        project_state={},
        v1_decision=decision,
        v1_reason=reason,
        # 경로 축약 기준 (2026-08-10). 이 인자가 없으면 훅이 넘기는
        # 절대 파일 경로가 축약되지 않아 corpus 반입 검증에 걸려 레코드가
        # 통째로 유실된다 — 홈 아래에 프로젝트를 두는 모든 사용자와 CI
        # 러너가 해당한다 (Phase 2 잔존 1번의 근본 원인).
        project_root=project_root,
    )
    shadow_corpus.import_case(case, project_root)

try:
    _main()
except Exception:
    # 실패 완전 무시 — capture 는 관측 전용, 실패가 훅에 보여서는 안 된다.
    pass
PY
    ) </dev/null >/dev/null 2>&1 &
    disown $! 2>/dev/null || true
  fi
}

# shadow_capture_init <hook-name>
#   훅 본문에서 정확히 1번 호출한다. deny_emit/log_block 이 정의돼 있으면
#   (동일 이름으로 재정의하며) 감싸고, EXIT trap 을 설치한다.
shadow_capture_init() {
  _SHADOW_HOOK_NAME="$1"

  if [ -n "${_SHADOW_CAPTURE_INITED:-}" ]; then
    return 0
  fi
  _SHADOW_CAPTURE_INITED=1

  if declare -F deny_emit >/dev/null 2>&1; then
    eval "$(declare -f deny_emit | sed '1s/^deny_emit/_shadow_orig_deny_emit/')"
    deny_emit() {
      _SHADOW_DENIED=1
      _shadow_note "${2:-deny}"
      _shadow_orig_deny_emit "$@"
    }
  fi
  if declare -F log_block >/dev/null 2>&1; then
    eval "$(declare -f log_block | sed '1s/^log_block/_shadow_orig_log_block/')"
    log_block() {
      _shadow_note "${1:-block}"
      _shadow_orig_log_block "$@"
    }
  fi

  trap '_shadow_on_exit $?' EXIT
}
