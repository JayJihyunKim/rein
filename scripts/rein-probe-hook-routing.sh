#!/usr/bin/env bash
# scripts/rein-probe-hook-routing.sh
#
# ============================================================================
# 메인테이너 전용 수동 진단 도구 — CI 미편입.
# ============================================================================
# 이 스크립트는 tests/*/run-all.sh 에 등록되지 않는다. 환경 의존(로그인된
# `claude` CLI 필요, 실제 LLM 세션 비용 발생, 실행 시간 수십~수백 초)이라
# 자동 회귀 테스트로 부적합하다 — 메인테이너가 hooks.json 라우팅을 바꾸기
# 전후 손으로 실행하는 실증 도구다.
#
# 목적
# ----
# `plugins/rein-core/hooks/hooks.json` 의 라우팅(어떤 이벤트에 어떤 훅을
# 매핑하는지)을 바꾸기 전후, Claude Code 호스트가 그 설정을 실제로
# 로드·등록·발화하는지 실증한다. 기존 자동 테스트(tests/hooks/**)는 설정
# 파일을 정적으로 파싱하거나 훅 스크립트를 직접 호출하는 것뿐이라, 호스트가
# hooks.json 을 어떻게 해석하는지는 아무 것도 검증하지 않는다 — 이 gap 을
# 메운다.
#
# 무엇을 하나
# ----------
#   1. `git worktree` 로 <ref> 커밋의 격리된 사본을 만든다 (메인 작업
#      트리는 절대 건드리지 않는다 — worktree add/remove 는 `.git/worktrees/`
#      메타데이터만 건드리고 추적 파일은 손대지 않는다).
#   2. 저장소 밖의 별도 임시 폴더를 cwd 로 삼아, 그 worktree 의
#      plugins/rein-core 를 `claude -p --plugin-dir` 로 명시 로드해 1회
#      headless 세션을 실행한다. `--setting-sources project,local` 로
#      user-level(전역 설치된 `rein@rein`) 자동 개입을 배제한다 — 그 cwd
#      는 git 저장소도 아니고 project/local 설정도 없으므로, 이 세션에서
#      작동하는 훅은 순수하게 `--plugin-dir` 로 명시 로드한 <ref> 시점의
#      hooks.json 뿐이다. (패턴 출처: plugins/rein-core/tests/orchestration/
#      e2e-orchestration.sh 헤더 — 먼저 읽고 이 스크립트를 작성함.)
#   3. 두 개의 독립 신호로 판정한다:
#        a) `--debug hooks --debug-file` — 호스트가 hooks.json 을 읽고
#           등록을 마쳤다는 host-side 로그 ("Registered N hooks from M
#           plugins").
#        b) `--output-format stream-json --include-hook-events` — 세션 중
#           실제로 발화한 hook_started/hook_response 이벤트(hook_event,
#           hook_name, exit_code, outcome).
#
# 실측 스키마 (Claude Code 2.1.229, darwin — 이 스크립트 작성 시점에 별도
# 격리 sandbox 에서 직접 확인함. 문서화된 공개 계약이 아니므로 CLI 버전이
# 바뀌면 이 스크립트의 파서(REPORT_DIR/parse_probe.py 생성부)도 함께
# 갱신해야 한다):
#   - system/init 메시지의 `plugins[].path` — 어느 디렉터리에서 플러그인이
#     로드됐는지 (`--plugin-dir` 인자와 일치해야 한다).
#   - --debug-file 로그의 "Registered N hooks from M plugins" 한 줄 —
#     hooks.json 을 읽고 등록을 마쳤다는 확인. 이 줄은 세션이 끝까지 가지
#     못하고 타임아웃/에러로 죽어도 이미 기록돼 있는 경우가 많다(등록은
#     세션 극초반에 일어남) — 그래서 claude -p 자체가 실패해도 이 신호는
#     별도로 유의미하다.
#   - system 메시지 subtype `hook_started`/`hook_response` — 공통 필드
#     hook_name/hook_event, response 쪽에 추가로 exit_code/outcome/
#     stdout/stderr/output.
#
# `--permission-mode bypassPermissions` 사용 근거 (e2e-orchestration.sh
# 헤더의 선례를 그대로 따름 — 이미 그 스크립트에서 보안 리뷰를 거친 근거):
# headless `claude -p` 에는 interactive 권한 프롬프트를 받을 터미널이 없어
# 다른 모드는 Edit/Write/Bash 승인을 기다리며 무기한 멈춘다. 위험 범위:
#   (1) 프롬프트는 이 스크립트에 고정된 내장 시나리오 문자열이거나 사용자가
#       CLI 인자로 명시적으로 넘긴 --prompt 뿐 — 세션 실행 중에 외부/사용자
#       입력이 주입되는 경로가 없다.
#   (2) cwd 는 저장소 밖 mktemp 격리 sandbox 뿐이다(--add-dir 로 실제
#       저장소를 노출하지 않는다).
#   (3) --strict-mcp-config 로 어떤 MCP 서버도 붙지 않는다.
#   (4) `trap cleanup EXIT` 가 모든 종료 경로(정상/에러/시그널)에서
#       worktree+sandbox 파일을 정리하고, 그보다 먼저 대상 프로세스(그리고
#       그 자식들)를 process group 단위로 회수한다(reap_target_process,
#       scripts/rein.sh 의 cmd_job_stop_posix 와 동일한 TERM→유예→KILL
#       패턴 재사용 — 정리 절 참조).
#
# 실행 시 고지 + 대화형 확인 (리뷰 수정, 2차):
#   - 매 실행마다(지정한 --ref 가 무엇이든) claude -p 를 띄우기 전에 "이
#     커밋의 훅을 승인 없이 실제 실행한다"는 한 줄 고지를 stderr 에 낸다.
#     예전엔 --ref 가 현재 HEAD 와 같은 기본값 실행에는 아무 신호가 없었다
#     — 그런데 "현재 체크아웃된 커밋 자체가 검토 전/오염된 경우"는 기본값
#     실행이 곧 "검토 안 된 코드의 승인 없는 실제 실행"인데도 조용히
#     지나갔다.
#   - 지정한 커밋이 현재 HEAD 와 달라 아래 WARNING 블록이 뜨는 경우, 표준
#     입력이 터미널일 때만(`[ -t 0 ]`) y/N 확인을 받는다. 기본값은 거부(N)
#     — 그냥 Enter 를 누르거나 y/yes 이외 어떤 입력도 거부로 처리한다.
#     비대화형 호출(파이프/스크립트/CI 등, 표준입력이 터미널이 아님)은
#     확인을 건너뛰고 기존처럼 경고만 출력한 채 진행한다 — 자동화 호출을
#     막지 않기 위함.
#
# 과거 함정 (사전 조사에서 확정, 이 스크립트가 대응함):
#   - headless 실행이 로그인 세션 없이 돌면 실행 자체가 실패한 전례 —
#     `claude auth status` 로 사전에 명시 확인한다 (조용히 통과시키지 않음).
#   - 이 darwin 환경에는 `timeout`/`gtimeout` 바이너리가 없다 — 백그라운드
#     프로세스 + sleep 워치독으로 직접 구현한다(e2e-orchestration.sh 와
#     동일 패턴). 단, 워치독이 실제로 대상 프로세스(트리)를 죽이는지는
#     e2e-orchestration.sh 도 이 스크립트의 이전 버전과 같은 결함을 갖고
#     있었다(감싸는 subshell 의 PID 만 죽이고 실제 대상은 고아로 남김) —
#     그래서 이 부분은 e2e-orchestration.sh 를 따르지 않고 scripts/rein.sh
#     의 job 관리(process-group kill) 패턴을 재사용해 수리했다.
#   - 훅 테스트 하네스는 테스트 모드 표식을 붙여 집계에서 제외하지만, 이
#     headless 프로브는 그런 표식이 없다 — 그래서 반드시 저장소 밖 격리
#     sandbox 를 cwd 로 써서, 훅이 무엇을 하든(trail/incidents 기록 등)
#     실제 저장소가 아니라 disposable sandbox 로 향하게 한다.
#
# Usage
# -----
#   bash scripts/rein-probe-hook-routing.sh [옵션]
#
# 옵션:
#   --ref <branch-or-commit>   검증할 브랜치/커밋 (기본: HEAD)
#   --scenario <name>          내장 시나리오 선택 (기본: edit-write).
#                               `--scenario list` 로 목록 확인.
#   --prompt <text>            시나리오 대신 직접 프롬프트 지정 (custom
#                               모드 — baseline 이벤트만 판정, tool-event
#                               기대값은 없음. 관측 표는 그대로 출력).
#   --timeout <secs>           claude -p 워치독 타임아웃 (기본: 180)
#   -h, --help                 이 사용법 출력
#
# 종료 코드: 0=전 판정 PASS, 1=실행/판정 실패, 2=인자 오류.
# ============================================================================

set -u

# ---------------------------------------------------------------------------
# 사용법 / 시나리오 목록 — precondition 체크보다 먼저 처리해서, claude/git
# 이 없어도 --help 와 --scenario list 는 항상 동작한다.
# ---------------------------------------------------------------------------
print_usage() {
  cat <<'USAGE'
rein-probe-hook-routing.sh — hooks.json 라우팅 실증 프로브
(메인테이너 전용 수동 도구 — CI/tests/*/run-all.sh 에 등록되지 않음)

Usage:
  bash scripts/rein-probe-hook-routing.sh [옵션]

옵션:
  --ref <branch-or-commit>   검증할 브랜치/커밋 (기본: HEAD)
  --scenario <name>          내장 시나리오 선택 (기본: edit-write)
                              `--scenario list` 로 목록 확인
  --prompt <text>            시나리오 대신 직접 프롬프트 지정 (custom 모드)
  --timeout <secs>           claude -p 워치독 타임아웃 (기본: 180)
  -h, --help                 이 사용법 출력

전제조건: claude CLI 설치 + 로그인, git, python3. 실행마다 실제 LLM 세션
비용이 발생한다. 격리를 위해 git worktree + 저장소 밖 임시 폴더를 쓰고,
종료 시(성공/실패/중단 모두) 자동 정리한다.

⚠️  보안 경고: 이 프로브는 --ref 로 지정한 커밋 "시점의 훅 스크립트를
    --permission-mode bypassPermissions 로 실제 실행"합니다 — 승인
    프롬프트 없이, 그 커밋에 들어있는 훅 명령이 이 계정 권한으로 그대로
    돕니다. 반드시 본인이 작성했거나 이미 검토를 마친 커밋에만 사용하고,
    제3자 브랜치·리뷰 전 PR·출처가 불확실한 커밋에는 절대 쓰지 마세요.
    매 실행마다 이 사실을 짧게 고지하는 한 줄이 stderr 에 출력됩니다
    (기본값 실행 포함). 기본값(현재 HEAD)이 아닌 ref 를 지정하면 실행
    직전 상세 경고가 추가로 출력되고, 표준입력이 터미널이면 y/N 확인
    (기본값=거부)을 받습니다 — 비대화형 호출(터미널 아님)에서는 확인
    없이 경고만 출력하고 그대로 진행합니다.
USAGE
}

list_scenarios() {
  cat <<'EOF'
사용 가능한 시나리오 (--scenario <name>):
  edit-write    (기본) 파일 쓰기 시도 -> Write 계열 PreToolUse/PostToolUse 발화 확인
  bash-echo     Bash 명령 실행 시도 -> Bash 계열 PreToolUse/PostToolUse 발화 확인
  session-only  도구 미사용 응답 -> SessionStart/UserPromptSubmit/Stop 만 기대 (negative control)
EOF
}

get_scenario() {
  # $1 = scenario name. 성공 시 SCEN_PROMPT / SCEN_EVENTS 를 채우고 0 리턴.
  case "$1" in
    edit-write)
      SCEN_PROMPT="Create a new file named probe-output.txt in the current directory containing exactly this one line: rein-probe-ok
Just create the file with the Write tool. Do not explain, do not ask questions, do not use any other tool."
      SCEN_EVENTS="PreToolUse,PostToolUse"
      ;;
    bash-echo)
      SCEN_PROMPT="Run this exact shell command with the Bash tool and show me its output: echo rein-probe-ok
Just run it. Do not explain, do not ask questions, do not use any other tool."
      SCEN_EVENTS="PreToolUse,PostToolUse"
      ;;
    session-only)
      SCEN_PROMPT="Reply with exactly the single word: ok
Do not use any tool. Just reply with that word."
      SCEN_EVENTS=""
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
REF="HEAD"
SCENARIO="edit-write"
CUSTOM_PROMPT=""
TIMEOUT_SECS=180

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      [ $# -ge 2 ] || { echo "ERROR: --ref 옵션에는 값이 필요합니다" >&2; exit 2; }
      REF="$2"; shift 2 ;;
    --scenario)
      [ $# -ge 2 ] || { echo "ERROR: --scenario 옵션에는 값이 필요합니다" >&2; exit 2; }
      SCENARIO="$2"; shift 2 ;;
    --prompt)
      [ $# -ge 2 ] || { echo "ERROR: --prompt 옵션에는 값이 필요합니다" >&2; exit 2; }
      CUSTOM_PROMPT="$2"; shift 2 ;;
    --timeout)
      [ $# -ge 2 ] || { echo "ERROR: --timeout 옵션에는 값이 필요합니다" >&2; exit 2; }
      TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)
      print_usage; exit 0 ;;
    *)
      echo "ERROR: 알 수 없는 옵션: $1" >&2
      print_usage >&2
      exit 2 ;;
  esac
done

if [ "$SCENARIO" = "list" ]; then
  list_scenarios
  exit 0
fi

case "$TIMEOUT_SECS" in
  ''|*[!0-9]*)
    echo "ERROR: --timeout 은 양의 정수여야 합니다: $TIMEOUT_SECS" >&2
    exit 2
    ;;
esac
# 리뷰 수정: 위 case 는 숫자로만 구성되면 통과시켜 "0"(그리고 "00" 류)도
# 받아들였다 — 메시지는 "양의 정수"라 0 을 배제한다고 말하지만 실제로는
# 안 그랬다. --timeout 0 은 sleep 0 이 사실상 즉시 반환해 워치독이
# claude_pid 파일이 아직 안 쓰인 시점에 reap_target_process 를 호출하고
# (pidfile 없음 → 조용히 no-op) 그대로 종료해버린다 — 감시가 켜진 척
# 하면서 실제로는 꺼진 채로 나머지 실행 시간 동안 대상을 전혀 감시하지
# 않는다. 산술 비교로 0 을 별도 거부한다(하한은 1 — 정상적인 빠른
# 워치독 검증 용도(예: --timeout 1/2)는 막지 않는다).
if [ "$TIMEOUT_SECS" -eq 0 ] 2>/dev/null; then
  echo "ERROR: --timeout 은 0 일 수 없습니다 (워치독이 사실상 꺼진 채로 동작합니다): $TIMEOUT_SECS" >&2
  exit 2
fi

if [ -n "$CUSTOM_PROMPT" ]; then
  RUN_LABEL="custom"
  RUN_PROMPT="$CUSTOM_PROMPT"
  RUN_EVENTS=""
else
  if ! get_scenario "$SCENARIO"; then
    echo "ERROR: 알 수 없는 시나리오: $SCENARIO (목록: bash $0 --scenario list)" >&2
    exit 2
  fi
  RUN_LABEL="$SCENARIO"
  RUN_PROMPT="$SCEN_PROMPT"
  RUN_EVENTS="$SCEN_EVENTS"
fi
BASELINE_EVENTS="SessionStart,UserPromptSubmit,Stop"

# ---------------------------------------------------------------------------
# 전제 조건 — 확인 못 한 것은 확인 못 했다고 명확히 실패한다 (조용한 통과
# 금지). claude/git/python3 부재, 로그인 안 됨을 여기서 잡는다.
# ---------------------------------------------------------------------------
for bin in claude git python3; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: 이 프로브에는 '$bin' 커맨드가 필요합니다 (PATH 에서 찾지 못함)." >&2
    echo "ERROR: 확인 불가 상태를 그대로 실패로 보고합니다 — 조용히 넘어가지 않습니다." >&2
    exit 1
  fi
done
echo "claude CLI: $(command -v claude) ($(claude --version 2>&1 | head -n1))"

AUTH_STATUS_JSON="$(claude auth status 2>&1)"
AUTH_STATUS_RC=$?
if [ "$AUTH_STATUS_RC" -ne 0 ]; then
  echo "ERROR: 'claude auth status' 실행 실패 (exit=$AUTH_STATUS_RC):" >&2
  echo "$AUTH_STATUS_JSON" >&2
  exit 1
fi
if ! printf '%s' "$AUTH_STATUS_JSON" | grep -q '"loggedIn": *true'; then
  echo "ERROR: claude CLI 가 로그인되어 있지 않습니다 (claude auth status):" >&2
  echo "$AUTH_STATUS_JSON" >&2
  echo "ERROR: 'claude auth login' 으로 로그인한 뒤 다시 시도하세요." >&2
  exit 1
fi
echo "claude 로그인 상태: OK"

# ---------------------------------------------------------------------------
# 저장소 루트 + ref 해석 — SCRIPT_DIR 기준(cwd 기준 아님, project-dir.sh
# 관례와 동일하게 스크립트가 물리적으로 속한 저장소를 앵커로 삼는다).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>&1)"
REPO_ROOT_RC=$?
if [ "$REPO_ROOT_RC" -ne 0 ] || [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: 이 스크립트가 속한 저장소 루트를 찾지 못했습니다 (git rev-parse 실패):" >&2
  echo "$REPO_ROOT" >&2
  exit 1
fi

if ! RESOLVED_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "${REF}^{commit}" 2>&1)"; then
  echo "ERROR: '--ref $REF' 를 커밋으로 해석할 수 없습니다:" >&2
  echo "$RESOLVED_SHA" >&2
  exit 1
fi
RESOLVED_SHA_SHORT="$(git -C "$REPO_ROOT" rev-parse --short "$RESOLVED_SHA")"

# ---------------------------------------------------------------------------
# 보안 경고 (실행 시점) — 리뷰 요구사항: 지정한 --ref 가 현재 체크아웃된
# HEAD 와 다르면(즉 기본값이 아니면), claude -p 를 실제로 띄우기 전에
# "그 커밋의 훅이 실제 실행된다"는 사실을 stderr 에 눈에 띄게 출력한다.
# 차단하지는 않는다 — 다른 커밋을 검증하는 것 자체는 정당한 용도이며,
# 이 프로브의 존재 이유이기도 하다. 판정은 SHA 비교(문자열 --ref 값이
# 아니라)로 한다: `--ref HEAD` 를 명시해도 SHA 가 같으면 안전하므로
# 경고하지 않는다.
# ---------------------------------------------------------------------------
CURRENT_HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

# 항상 보이는 한 줄 고지 (리뷰 수정 — Low-Medium #1): --ref 가 기본값
# (현재 HEAD)이든 아니든, 이 프로브를 실행하는 순간 그 커밋의 훅이 승인
# 없이 실제로 실행된다는 사실은 변하지 않는다. 아래 상세 WARNING 블록은
# 지정 커밋이 현재 HEAD 와 다를 때만 뜨므로, "현재 체크아웃된 커밋 자체가
# 검토 전/오염된 상태"인 기본값 실행에는 지금까지 아무 신호도 없었다 —
# 승인 없는 실제 코드 실행이라는 위험이 조용히 넘어갔다. 매 실행 공통으로
# 최소 고지를 남긴다.
echo "NOTICE: 이 프로브는 커밋 $RESOLVED_SHA_SHORT 의 훅 스크립트를 --permission-mode bypassPermissions 로 승인 없이 실제 실행합니다." >&2

if [ "$RESOLVED_SHA" != "$CURRENT_HEAD_SHA" ]; then
  {
    echo
    echo "############################################################################"
    echo "# WARNING: --ref 로 지정한 커밋($REF -> $RESOLVED_SHA_SHORT)이 현재"
    echo "#          체크아웃된 HEAD($([ -n "$CURRENT_HEAD_SHA" ] && git -C "$REPO_ROOT" rev-parse --short "$CURRENT_HEAD_SHA" || echo '확인불가')) 와 다릅니다."
    echo "#"
    echo "#          이 프로브는 그 커밋 시점의 훅 스크립트를 --permission-mode"
    echo "#          bypassPermissions 로 '실제 실행'합니다 — 승인 프롬프트 없이"
    echo "#          그 커밋에 있는 훅 명령이 이 계정 권한으로 그대로 돕니다."
    echo "#"
    echo "#          본인이 직접 작성했거나 이미 검토를 마친 커밋에만 사용하세요."
    echo "#          제3자 브랜치·리뷰 전 PR·출처가 불확실한 커밋에는 절대 쓰지"
    echo "#          마세요. (진행을 막지는 않습니다 — 검증 자체는 정당한 용도입니다.)"
    echo "############################################################################"
    echo
  } >&2

  # 대화형 확인 (리뷰 수정 — Low-Medium #2): 지정 커밋이 현재 HEAD 와 달라
  # 위 WARNING 이 뜬 경우에 한해, 표준입력이 터미널일 때만(`-t 0`) y/N
  # 확인을 받는다. 기본값은 거부(N) — 빈 입력(Enter 만 누름)을 포함해
  # y/yes 이외 무엇이든 거부로 처리하고 아무것도 실행하지 않은 채 종료한다
  # (이 시점엔 아직 worktree/REPORT_DIR/RUN_ROOT 어느 것도 만들어지지
  # 않았으므로 trap cleanup 없이 바로 exit 해도 정리할 게 없다). 표준입력이
  # 터미널이 아니면(파이프/스크립트/CI 등 비대화형 호출) 확인을 건너뛰고
  # 기존처럼 경고만 출력한 채 진행한다 — 자동화 호출을 막지 않기 위함.
  if [ -t 0 ]; then
    CONFIRM_ANSWER=""
    printf '위 커밋의 훅을 승인 없이 실행하시겠습니까? [y/N] ' >&2
    read -r CONFIRM_ANSWER || CONFIRM_ANSWER=""
    case "$CONFIRM_ANSWER" in
      y|Y|yes|YES|Yes)
        echo "확인됨 — 진행합니다." >&2
        ;;
      *)
        echo "ERROR: 사용자가 확인하지 않아 실행을 중단합니다 (기본값=거부). 아무 것도 실행되지 않았습니다." >&2
        exit 1
        ;;
    esac
  else
    echo "NOTE: 비대화형 실행(표준입력이 터미널이 아님) — 확인 없이 경고만 출력하고 진행합니다." >&2
  fi
fi

echo
echo "=== 프로브 설정 ==="
echo "  repo:          $REPO_ROOT"
echo "  ref:           $REF -> $RESOLVED_SHA_SHORT"
echo "  scenario:      $RUN_LABEL"
echo "  timeout:       ${TIMEOUT_SECS}s"

# ---------------------------------------------------------------------------
# 정리 — trap EXIT 하나로 정상/에러/시그널 종료 전부를 커버한다
# (e2e-orchestration.sh 헤더의 검증된 패턴과 동일).
#
# CLAUDE_PID_FILE + reap_target_process(): 리뷰 수정 — cleanup() 은 지금까지
# worktree/sandbox "파일" 만 정리했지, 대상 프로세스(트리)는 전혀 회수하지
# 않았다 (trap 이 실제로 보증하는 범위가 문서화된 것보다 좁았다). 아래
# reap_target_process 는 scripts/rein.sh 의 cmd_job_stop_posix
# (BG-job-stop-posix-process-group) 와 동일한 TERM → 유예 → KILL
# 에스컬레이션을 재사용하며, cleanup() 에서 "종료 경로와 무관하게" 무조건
# 먼저 호출된다 (정상 종료/에러/워치독 타임아웃/Ctrl-C 모두 동일 경로).
# ---------------------------------------------------------------------------
WORKTREE_CREATED=0
REPORT_DIR=""
RUN_ROOT=""
WORKTREE_DIR=""
CLAUDE_PID_FILE=""

# _probe_pid_alive <pid> — scripts/rein.sh 의 _probe_pid_alive(POSIX 분기)와
# 동일한 생존 확인(kill -0).
_probe_pid_alive() {
  kill -0 "$1" 2>/dev/null
}

# reap_target_process <pidfile> — 워치독 타임아웃과 cleanup() 양쪽이 공유하는
# 단일 종료 경로. <pidfile> 에 기록된 pid 는 항상 "claude -p 를 job-control
# 로 자신만의 process group 에 넣어 백그라운드로 띄운 시점의 $!"이므로(아래
# claude -p 실행부의 `set -m` 참조), `-$pid` 로 그룹 전체(= claude 와 그
# 자식들)에 신호를 보낼 수 있다. macOS 에는 setsid(1) 바이너리가 없어(이
# darwin 환경에서 실측 확인) scripts/rein.sh 처럼 setsid 를 직접 쓰는 대신
# bash 자체의 job-control(set -m)로 동등한 "백그라운드 job = 새 process
# group" 효과를 낸다 — Linux/macOS 양쪽에서 외부 바이너리 의존 없이 동작.
# 그룹 시그널이 거부되면(예: job-control 이 어떤 이유로 그룹을 못 만든 경우)
# 단일 pid 로 폴백한다 — cmd_job_stop_posix 의 폴백과 동일 패턴.
reap_target_process() {
  local pidfile="$1"
  [ -f "$pidfile" ] || return 0
  local pid
  pid="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$pid" ] || return 0
  _probe_pid_alive "$pid" || return 0

  echo "target pid $pid 가 살아있습니다 — process group -$pid 에 SIGTERM 전송"
  if ! kill -TERM -- "-$pid" 2>/dev/null; then
    echo "  그룹 시그널 실패 — 단일 pid $pid 에 SIGTERM 폴백"
    kill -TERM "$pid" 2>/dev/null
  fi

  local i
  for i in 1 2 3 4 5 6 7 8; do
    if ! _probe_pid_alive "$pid"; then
      echo "  pid $pid 정상 종료됨"
      return 0
    fi
    sleep 0.25
  done

  echo "  pid $pid 유예 시간(2s) 초과 — SIGKILL 로 에스컬레이션"
  if ! kill -KILL -- "-$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
  fi
  if _probe_pid_alive "$pid"; then
    echo "  WARN: pid $pid 가 SIGKILL 이후에도 살아있습니다"
    return 1
  fi
  return 0
}

cleanup() {
  echo
  echo "=== 정리 ==="
  local had_problem=0

  # 파일 정리보다 먼저 — 아직 돌고 있는 대상 프로세스(트리) 밑에서
  # worktree/sandbox 를 지우지 않기 위해 항상 첫 단계로 회수한다.
  reap_target_process "$CLAUDE_PID_FILE" || had_problem=1

  if [ "$WORKTREE_CREATED" = "1" ] && [ -n "$WORKTREE_DIR" ]; then
    echo "worktree 제거 시도: $WORKTREE_DIR"
    if ! git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1; then
      echo "WARN: git worktree remove 실패 — rm -rf 로 뒤이어 강제 정리합니다"
    fi
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1
  fi

  if [ -n "$RUN_ROOT" ] && [ -d "$RUN_ROOT" ]; then
    rm -rf "$RUN_ROOT" 2>/dev/null
  fi

  if [ -n "$RUN_ROOT" ] && [ -d "$RUN_ROOT" ]; then
    echo "WARN: 임시 작업 폴더(worktree+sandbox) 정리 실패 — 남은 경로: $RUN_ROOT"
    echo "      수동 삭제: rm -rf \"$RUN_ROOT\""
    had_problem=1
  else
    echo "임시 작업 폴더(worktree+sandbox) 정리 완료: ${RUN_ROOT:-<미생성>}"
  fi

  if [ -n "$WORKTREE_DIR" ] && git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -qF "$WORKTREE_DIR"; then
    echo "WARN: git worktree 메타데이터가 여전히 남아있습니다 — 수동 정리:"
    echo "      git -C \"$REPO_ROOT\" worktree remove --force \"$WORKTREE_DIR\""
    echo "      git -C \"$REPO_ROOT\" worktree prune"
    had_problem=1
  fi

  echo
  echo "메인 저장소 상태 확인 (이 프로브로 인한 변경이 없어야 정상 — 실행 전부터"
  echo "있던 변경은 포함될 수 있음, 아래는 참고용):"
  git -C "$REPO_ROOT" status --short 2>/dev/null | sed 's/^/    /'

  if [ "$had_problem" = "0" ]; then
    echo
    echo "정리 확인: 남은 흔적 없음."
  fi

  if [ -n "$REPORT_DIR" ]; then
    echo
    echo "원본 로그(자동 삭제 안 됨— 필요 시 직접 정리): $REPORT_DIR"
    echo "  rm -rf \"$REPORT_DIR\""
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# REPORT_DIR(영속 — 로그/판정 스크립트, trap 정리 대상 아님) +
# RUN_ROOT(휘발 — worktree+sandbox, trap 정리 대상).
# ---------------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
# 리뷰 재수정(Medium, 2차): 이전 수정은 안쪽 리프(${TS}-$$)에만 -m 0700 +
# chmod 700 을 걸었을 뿐, 상위 고정 이름 폴더 rein-probe-hook-routing-reports/
# 자체는 그대로 뒀다. `mkdir -m 0700 -p` 는 이미 존재하는 중간 디렉터리는
# 건드리지 않고, 새로 만들 때도 -m 모드는 리프에만 적용된다(중간 디렉터리는
# umask 를 그대로 상속 — 보통 0755, 실측 재현: `umask 022; mkdir -m 0700 -p
# a/b` 하면 a=0755, a/b=0700). 이 상위 폴더는 이름이 고정·예측 가능하고
# 이 스크립트의 모든 실행이 공유했다 — 같은 기계의 다른 로컬 계정이
# (1) 실행 이력(타임스탬프+pid 로 구성된 하위 폴더명 나열)을 열람하고
# (2) 최초 실행 시점에 그 이름을 먼저 선점하면, 이후 실행자가 그 안에
# 만드는 리프를 rename/delete 할 수 있었다(내용은 못 읽어도 — 임시
# 디렉터리와 달리 sticky bit 이 없으므로). 근본 수정: 상위 폴더 자체를
# 없앤다 — RUN_ROOT 가 이미 쓰는 것과 동일한 패턴(mktemp -d 한 번으로
# $TMPDIR 바로 아래 완전히 무작위인 리프 하나만 생성, 공유되는 고정 이름
# 중간 디렉터리 없음)으로 REPORT_DIR 도 만든다. mktemp -d(mkdtemp(3) 기반)
# 는 생성 시점부터 0700 을 기본으로 주지만, 플랫폼별 구현 차이에 기대지
# 않도록 생성 직후 chmod 로 한 번 더 명시 고정한다.
REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rein-probe-hook-routing-reports.${TS}.XXXXXX")" || {
  echo "ERROR: REPORT_DIR 생성 실패 (mktemp)" >&2
  exit 1
}
chmod 700 "$REPORT_DIR" || { echo "ERROR: REPORT_DIR 권한(0700) 고정 실패: $REPORT_DIR" >&2; exit 1; }
# macOS $TMPDIR ends with a trailing slash, so naive concatenation produces a
# double slash (e.g. ".../T//rein-probe-...") — canonicalize via `cd && pwd -P`
# so this path matches byte-for-byte what Claude Code reports in
# system/init.plugins[].path (also collapses /var vs /private/var symlinks).
# Confirmed as a real false-negative in an earlier manual run of this script
# before this fix (plugin_registered_via_init FAILed on a genuinely-loaded
# plugin purely due to the double-slash string mismatch).
REPORT_DIR="$(cd "$REPORT_DIR" && pwd -P)"

RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rein-probe-hook-routing.XXXXXX")" || {
  echo "ERROR: 임시 작업 폴더 생성 실패 (mktemp)" >&2
  exit 1
}
RUN_ROOT="$(cd "$RUN_ROOT" && pwd -P)"
SANDBOX_DIR="$RUN_ROOT/sandbox"
mkdir -p "$SANDBOX_DIR" || { echo "ERROR: sandbox 디렉터리 생성 실패: $SANDBOX_DIR" >&2; exit 1; }
WORKTREE_DIR="$RUN_ROOT/worktree"

# ---------------------------------------------------------------------------
# 판정 스크립트 — stream-json transcript + --debug hooks 로그를 함께 읽어
# 사람이 읽을 수 있는 표 + CHECK[label] PASS/FAIL 줄을 출력한다.
# ---------------------------------------------------------------------------
cat > "$REPORT_DIR/parse_probe.py" <<'PYEOF'
"""parse_probe.py — hooks.json 라우팅 실증 판정.

두 개의 독립 신호를 읽는다:
  1. --debug hooks --debug-file 로그의 "Registered N hooks from M plugins"
     한 줄 — 호스트가 hooks.json 을 읽고 등록을 마쳤다는 확인.
  2. --output-format stream-json --include-hook-events transcript 의
     system/init.plugins(로드된 플러그인 경로) 및 system/hook_started,
     system/hook_response(실제 발화 + exit_code/outcome) 이벤트.

outcome != "success" 인 훅 응답은 실패로 간주하지 않는다 — 정상적인
차단(예: bootstrap 안 된 sandbox 를 감시가 거부)일 수 있고, "발화했다"는
증거로는 여전히 유효하다. 그런 경우는 NOTE 로만 표면화한다.
"""
import json
import os
import re
import sys
from collections import defaultdict


def main():
    if len(sys.argv) != 7:
        print(
            "usage: parse_probe.py <transcript> <debug_log> <label> "
            "<expected_plugin_path> <scenario_events_csv> <baseline_events_csv>",
            file=sys.stderr,
        )
        sys.exit(2)

    (
        transcript_path,
        debug_log_path,
        label,
        expected_plugin_path,
        scenario_events_csv,
        baseline_events_csv,
    ) = sys.argv[1:7]

    scenario_events = [e for e in scenario_events_csv.split(",") if e]
    baseline_events = [e for e in baseline_events_csv.split(",") if e]

    checks = []

    def check(ok, desc):
        checks.append((ok, desc))

    if not os.path.isfile(transcript_path) or os.path.getsize(transcript_path) == 0:
        print("=== 관측된 훅 발화 ===")
        print("(transcript 없음 또는 비어 있음 — claude 세션이 정상 완료되지 않았을 가능성)")
        check(False, "transcript_nonempty (path={})".format(transcript_path))
        for ok, desc in checks:
            print("CHECK[{}] {} {}".format(label, "PASS" if ok else "FAIL", desc))
        print("PROBE_VERDICT[{}] FAIL (0/{} checks passed)".format(label, len(checks)))
        sys.exit(1)

    records = []
    init_msg = None
    with open(transcript_path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            records.append(obj)
            if obj.get("type") == "system" and obj.get("subtype") == "init":
                init_msg = obj

    # ---- 훅 등록 확인 (init.plugins) ----
    print("=== 훅 등록 확인 (init.plugins) ===")
    plugins = (init_msg or {}).get("plugins") or []
    matched = [p for p in plugins if p.get("path") == expected_plugin_path]
    if matched:
        for p in matched:
            print(
                "PASS  plugin {!r} registered from {} (version={})".format(
                    p.get("name"), p.get("path"), p.get("version")
                )
            )
        check(True, "plugin_registered_via_init (path={})".format(expected_plugin_path))
    else:
        seen_paths = [p.get("path") for p in plugins]
        print("FAIL  no plugin entry matched expected path {}".format(expected_plugin_path))
        print("      observed plugin paths: {!r}".format(seen_paths))
        check(
            False,
            "plugin_registered_via_init (expected={}, observed={!r})".format(
                expected_plugin_path, seen_paths
            ),
        )

    # ---- 훅 등록 확인 (--debug hooks 로그) ----
    # 리뷰 수정: 예전엔 "Registered"/"hooks from"/"plugins" 세 부분문자열이
    # 한 줄에 같이 나오기만 하면 통과했다 — N=0 이어도(즉 "Registered 0
    # hooks from 0 plugins" 같은 실질적으로 등록 실패를 뜻하는 줄이어도)
    # 그대로 PASS 였다. 이제 정규식으로 hook 개수(N)를 직접 뽑아 N>0 을
    # 요구한다 — 숫자를 못 뽑거나 N=0 이면 등록 증거로 인정하지 않는다.
    print()
    print("=== 훅 등록 확인 (--debug hooks 로그) ===")
    reg_line_re = re.compile(r"Registered\s+(\d+)\s+hooks?\s+from\s+(\d+)\s+plugins?")
    reg_line = None
    reg_hook_count = None
    if os.path.isfile(debug_log_path):
        with open(debug_log_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # 리뷰 수정: 예전 사전필터는 "hooks from"/"plugins" 복수형
                # 리터럴을 요구해 정규식(hooks?/plugins?)이 허용하는 단수
                # 표현("1 hook from 1 plugin")을 걸러냈다 — 이 프로브는
                # --plugin-dir 하나만 로드하므로 플러그인 수가 항상 1이라
                # 호스트가 단수로 찍는 순간 이 확인이 매 실행 거짓 실패
                # 한다. "Registered" 만 사전필터로 두고 나머지는 정규식이
                # 이미 충분히 특정적으로 판단한다.
                if "Registered" not in line:
                    continue
                m = reg_line_re.search(line)
                if m and int(m.group(1)) > 0:
                    reg_line = line.strip()
                    reg_hook_count = int(m.group(1))
                    break
    if reg_line:
        print("PASS  {} (parsed hook count N={})".format(reg_line, reg_hook_count))
        check(
            True,
            "debug_log_shows_registration (line={!r}, hooks={})".format(reg_line, reg_hook_count),
        )
    else:
        print(
            "FAIL  'Registered N hooks from M plugins' (N>0, 파싱 가능한 숫자) 줄을 "
            "debug 로그에서 찾지 못함: {}".format(debug_log_path)
        )
        check(False, "debug_log_shows_registration (debug_log={})".format(debug_log_path))

    # ---- 관측된 훅 발화 표 ----
    started = defaultdict(int)
    responded = defaultdict(int)
    exit_codes = defaultdict(set)
    outcomes = defaultdict(set)
    events_seen = set()
    for obj in records:
        if obj.get("type") != "system":
            continue
        subtype = obj.get("subtype")
        if subtype not in ("hook_started", "hook_response"):
            continue
        key = (obj.get("hook_event"), obj.get("hook_name"))
        events_seen.add(obj.get("hook_event"))
        if subtype == "hook_started":
            started[key] += 1
        else:
            responded[key] += 1
            exit_codes[key].add(obj.get("exit_code"))
            outcomes[key].add(obj.get("outcome"))

    print()
    print(
        "=== 관측된 훅 발화 (hook_event | hook_name | started | responded | "
        "exit_codes | outcomes) ==="
    )
    all_keys = sorted((k[0] or "?", k[1] or "?") for k in set(started.keys()) | set(responded.keys()))
    if not all_keys:
        print("(관측된 훅 발화 없음)")
    for ev, name in all_keys:
        key = (ev if ev != "?" else None, name if name != "?" else None)
        # re-resolve original key (None-safe) for lookups
        orig_key = None
        for k in set(started.keys()) | set(responded.keys()):
            if (k[0] or "?") == ev and (k[1] or "?") == name:
                orig_key = k
                break
        exs = sorted(x for x in exit_codes[orig_key] if x is not None)
        outs = sorted(x for x in outcomes[orig_key] if x is not None)
        print(
            "  {:<18} | {:<28} | {:>7} | {:>9} | {!s:<14} | {!s}".format(
                ev, name, started[orig_key], responded[orig_key], exs, outs
            )
        )

    non_success = [
        (key, outs) for key, outs in outcomes.items() if any(o not in (None, "success") for o in outs)
    ]
    if non_success:
        print()
        print("NOTE  일부 훅 응답이 outcome=success 가 아닙니다 (차단/에러일 수 있음 —")
        print("      발화 자체는 증거로 유효하니 위 표에서 직접 확인하세요):")
        for key, outs in non_success:
            print("        {} -> {!r}".format(key, sorted(outs)))

    # ---- 기준선 이벤트 판정 ----
    print()
    print("=== 기준선 이벤트 판정 (항상 기대: {}) ===".format(", ".join(baseline_events)))
    for ev in baseline_events:
        ok = ev in events_seen
        check(ok, "baseline_event_fired[{}]".format(ev))

    # ---- 시나리오 이벤트 판정 ----
    if scenario_events:
        print()
        print("=== 시나리오 이벤트 판정 ({}) ===".format(label))
        for ev in scenario_events:
            ok = ev in events_seen
            check(ok, "scenario_event_fired[{}]".format(ev))
    else:
        print()
        print("NOTE  custom 모드 또는 무기대 시나리오 — tool-event 기대값 없음. 위 표만 참고.")

    print()
    overall_ok = all(ok for ok, _ in checks)
    for ok, desc in checks:
        print("CHECK[{}] {} {}".format(label, "PASS" if ok else "FAIL", desc))
    print(
        "PROBE_VERDICT[{}] {} ({}/{} checks passed)".format(
            label,
            "PASS" if overall_ok else "FAIL",
            sum(1 for ok, _ in checks if ok),
            len(checks),
        )
    )
    sys.exit(0 if overall_ok else 1)


if __name__ == "__main__":
    main()
PYEOF

# ---------------------------------------------------------------------------
# 격리 worktree 생성
# ---------------------------------------------------------------------------
echo
echo "격리 worktree 생성 중: $WORKTREE_DIR (detached @ $RESOLVED_SHA_SHORT)"
if ! WORKTREE_ADD_OUT="$(git -C "$REPO_ROOT" worktree add --detach "$WORKTREE_DIR" "$RESOLVED_SHA" 2>&1)"; then
  echo "ERROR: git worktree add 실패:" >&2
  echo "$WORKTREE_ADD_OUT" >&2
  exit 1
fi
WORKTREE_CREATED=1
echo "$WORKTREE_ADD_OUT"

PLUGIN_DIR_IN_WORKTREE="$WORKTREE_DIR/plugins/rein-core"
if [ ! -f "$PLUGIN_DIR_IN_WORKTREE/hooks/hooks.json" ]; then
  echo "ERROR: worktree 에 plugins/rein-core/hooks/hooks.json 이 없습니다: $PLUGIN_DIR_IN_WORKTREE" >&2
  echo "ERROR: --ref $REF 시점에 플러그인 경로 구조가 다를 수 있습니다." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 실행 — 격리 sandbox cwd, --plugin-dir 로 worktree 의 훅만 로드, darwin 에
# timeout/gtimeout 이 없어 백그라운드+워치독으로 직접 구현.
#
# `set -m` (job control) 을 하위 subshell 안에서 켜서 `claude -p ...` 를
# 백그라운드로 띄운다 — job-control 이 켜진 상태에서 백그라운드로 띄운
# job 은 bash 가 자동으로 새 process group 을 만들고 그 group 의 leader
# pid = $! 가 된다(= process group id 이기도 함). 이렇게 캡처한 $! 를
# CLAUDE_PID_FILE 에 적어 워치독/cleanup() 양쪽이 reap_target_process 로
# 그 프로세스(그리고 그 프로세스가 낳은 자식들)를 group 단위로 종료할 수
# 있게 한다. (이전 버전은 `( ... claude -p ... ) &` 로 감싼 subshell 의
# PID 를 CLAUDE_BG_PID 로 착각해 워치독이 그 subshell 만 죽이고 실제
# claude -p 는 고아로 계속 돌게 두는 결함이 있었다 — 리뷰에서 지적됨.)
# ---------------------------------------------------------------------------
TRANSCRIPT_LOG="$REPORT_DIR/transcript.jsonl"
STDERR_LOG="$REPORT_DIR/stderr.log"
DEBUG_LOG="$REPORT_DIR/debug.log"
RC_FILE="$REPORT_DIR/claude.exit_code"
CLAUDE_PID_FILE="$REPORT_DIR/claude.pid"

echo
echo "=== claude -p 실행 (label=$RUN_LABEL, sandbox=$SANDBOX_DIR, timeout=${TIMEOUT_SECS}s) ==="
(
  set -m
  cd "$SANDBOX_DIR" || exit 1
  # --permission-mode bypassPermissions 근거: 스크립트 헤더 참조.
  claude -p \
    --plugin-dir "$PLUGIN_DIR_IN_WORKTREE" \
    --setting-sources project,local \
    --output-format stream-json \
    --include-hook-events \
    --permission-mode bypassPermissions \
    --strict-mcp-config \
    --verbose \
    --debug hooks \
    --debug-file "$DEBUG_LOG" \
    --model sonnet \
    -- \
    "$RUN_PROMPT" \
    > "$TRANSCRIPT_LOG" 2> "$STDERR_LOG" &
  claude_pid=$!
  printf '%s' "$claude_pid" > "$CLAUDE_PID_FILE"
  wait "$claude_pid"
  echo $? > "$RC_FILE"
) &
CLAUDE_BG_PID=$!
( sleep "$TIMEOUT_SECS" && reap_target_process "$CLAUDE_PID_FILE" ) &
WATCHDOG_PID=$!
wait "$CLAUDE_BG_PID" 2>/dev/null
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [ -f "$RC_FILE" ]; then
  CLAUDE_RC="$(cat "$RC_FILE")"
else
  CLAUDE_RC="timeout"
  echo "WARN: ${TIMEOUT_SECS}s 안에 완료되지 않아 워치독이 종료시켰습니다." >&2
fi
echo "claude -p 종료 코드: $CLAUDE_RC"

if [ "$CLAUDE_RC" != "0" ]; then
  echo
  echo "=== claude -p 실행 실패/미완료 (exit=$CLAUDE_RC) ==="
  echo "stderr:"
  sed 's/^/    /' "$STDERR_LOG" 2>/dev/null
  if grep -qiE 'invalid api key|not logged in|please (run|use).*login|unauthorized|authentication' "$STDERR_LOG" 2>/dev/null; then
    echo
    echo "HINT: 로그인/인증 문제로 보입니다 — 'claude auth status' 로 다시 확인하세요."
  fi
fi

# ---------------------------------------------------------------------------
# 판정 — claude -p 가 실패/타임아웃했어도, 부분 transcript/debug 로그가
# 있으면 그대로 파서에 넘긴다(등록 로그는 세션 극초반에 기록되므로 여전히
# 진단 가치가 있다). 파서가 스스로 transcript 부재/빈 파일을 FAIL 로 보고한다.
# ---------------------------------------------------------------------------
echo
echo "=== 판정 (parse_probe.py) ==="
PARSE_RC=0
python3 "$REPORT_DIR/parse_probe.py" \
  "$TRANSCRIPT_LOG" "$DEBUG_LOG" "$RUN_LABEL" "$PLUGIN_DIR_IN_WORKTREE" "$RUN_EVENTS" "$BASELINE_EVENTS" \
  || PARSE_RC=$?

FINAL_RC=0
if [ "$CLAUDE_RC" != "0" ] || [ "$PARSE_RC" != "0" ]; then
  FINAL_RC=1
fi

echo
echo "=== 최종 결과 ==="
echo "  ref:            $REF -> $RESOLVED_SHA_SHORT"
echo "  scenario/label: $RUN_LABEL"
echo "  claude -p exit: $CLAUDE_RC"
echo "  판정 exit:      $PARSE_RC"
if [ "$FINAL_RC" = "0" ]; then
  echo "  RESULT: PASS — 이 ref 의 hooks.json 라우팅이 실제로 로드·등록·발화함을 확인."
else
  echo "  RESULT: FAIL — 위 상세를 확인하세요 (claude 실행 실패/타임아웃 또는 기대한 훅 미발화)."
fi
echo
echo "원본 로그:"
echo "  transcript: $TRANSCRIPT_LOG"
echo "  stderr:     $STDERR_LOG"
echo "  debug:      $DEBUG_LOG"

exit "$FINAL_RC"
