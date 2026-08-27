#!/bin/bash
# plugins/rein-core/tests/orchestration/e2e-orchestration.sh
#
# plan Task 5.6 — Orchestration E2E: B안 위임 구조 검증
# (docs/plans/2026-08-08-rein-v2-governance-orchestration.md Task 5.6,
#  docs/specs/2026-08-07-rein-v2-governance-orchestration.md §2.5/§5.1)
#
# Verifies, in a real capable environment, that:
#   1. delegation structure — Orchestrator 서브에이전트가 워커를 실제로
#      중첩 디스패치한다 (main → orchestrator → worker, real Task/Agent
#      tool calls, not simulated data).
#   2. Orchestrator 자신은 파일을 직접 편집하지 않는다 (실질 구현은
#      워커에게 위임 — orchestrator.md 계약).
#   3. 깊이 4 시도 0건 — 워커가 스스로 하위 디스패치하지 않는다
#      (orchestrator.md "깊이 규칙" anchor:depth-rule).
#   4. 소형→단일 — 트리비얼한 작업은 분해하지 않고 단일 워커로 처리한다
#      (orchestrator.md anchor:single-worker).
#   5. 실패→강등 — 중첩 디스패치 불가/실패 관측 시 단일 워커로 강등하고,
#      가시적 통지 + tracker 기록을 남기며, 일반 작업을 BLOCK 하지
#      않는다 (spec §5.1, §4.5) — 상태 기계 검증 + 강등 이후 실제 단일
#      워커 dispatch 가 진짜로 완주하는지 real CLI 로 재확인한다.
#
# ---------------------------------------------------------------------------
# 설계 선택 (plan Task 5.6 지시 + round 8 코디네이터 강화 지시에 따른
# pragmatic 설계 — 근거를 여기 기록)
# ---------------------------------------------------------------------------
#
# Scenario 1/2/3-post-degradation (실제 nested dispatch, "not simulated
# data" 요구):
#   headless `claude -p` 를 --output-format stream-json --include-hook-events
#   --forward-subagent-text 로 구동하고, Claude Code 가 각 forwarded
#   assistant/user 메시지에 실제로 새기는 `parent_tool_use_id` 체인으로
#   중첩 깊이를 재구성한다. 이 필드는 이 스크립트 작성 시점에 실측으로
#   확인한 실제 스트림 스키마다(하위 `parse_and_check.py` 참조) — 문서화된
#   공개 계약이 아니라 실측 확인이므로, 이 필드가 향후 CLI 버전에서
#   바뀌면 이 스크립트도 함께 갱신해야 한다.
#
#   `--plugin-dir`(rein-core 플러그인 전체 로드)를 쓰지 않는다 — 이
#   메인테이너 환경은 `rein@rein` 이 **user-level** `~/.claude/settings.json`
#   `enabledPlugins` 로 전역 활성화돼 있어(dogfood), plugin-dir 여부와
#   무관하게 rein 자신의 governance hook(PreToolUse DoD gate 등)이 이미
#   발동한다 — 부트스트랩되지 않은 bare temp sandbox 에서 그 hook 들이
#   Edit/Write 를 막아 orchestration 구조 검증과 무관한 이유로 테스트가
#   깨진다(실측 확인: hook 이 `.claude/cache/.rein-session-degraded` 등을
#   실제로 만들며 개입했다). 대신 `--setting-sources project,local` 로
#   user-level 소스(그 안의 `enabledPlugins`)를 제외해 이 세션에서만
#   rein 자신의 hook 을 비활성화한다 — 이렇게 하면 이 e2e 는 "rein 이
#   rein 을 검사하는" 순환 없이 orchestration 구조만 순수하게 검증한다.
#   (`--bare` 는 대안으로 검토했으나 이 환경의 OAuth/keychain 인증을
#   깨서 실측으로 기각했다 — "Not logged in" 실패 재현.)
#
#   `--permission-mode bypassPermissions` 사용 근거 (보안 리뷰 LOW-MEDIUM
#   finding, round 10): headless `claude -p` 실행에는 상호작용 permission
#   프롬프트를 받을 터미널이 없다 — 기본/`acceptEdits`/`ask` 류 모드는
#   Edit/Write/Bash 승인을 기다리며 무기한 멈추므로 워치독이 있어도
#   스크립트가 완주할 수 없다. 이 위험은 아래 네 가지로 한정된다: (1)
#   각 시나리오의 프롬프트는 이 스크립트에 하드코딩된 고정 문자열이다
#   (사용자/외부 입력이 실행 시점에 주입되지 않는다 — adversarial 프롬프트
#   경로 없음), (2) 모든 실행은 `mktemp` 로 만든 격리 sandbox 안에서만
#   일어난다(cwd 가 그 sandbox 로 고정, `--add-dir` 로 실제 repo 를 노출하지
#   않는다), (3) `--strict-mcp-config` 로 어떤 MCP 서버도 붙지 않는다(부수
#   효과 표면 축소), (4) `trap cleanup_all EXIT` 가 스크립트 종료 경로
#   전부(정상/에러/시그널)에서 그 sandbox 를 지운다. 이 스크립트는 로컬/CI
#   에서 매 실행마다 새로 만들고 버리는 일회성 실행을 전제하며, ambient
#   secret(실제 API 키/자격증명 등 민감 값)이 있는 환경에서 이 스크립트를
#   그대로 재사용하지 않는다 — 그런 환경이 필요하면 이 가정을 재검토해야
#   한다. 두 `claude -p` 호출 지점(아래 `invoke_claude_with_timeout`)에는
#   이 절을 가리키는 짧은 포인터 주석을 달아둔다.
#
#   Orchestrator 에이전트는 `--agents` JSON 으로 등록하되, 그 prompt 는
#   `plugins/rein-core/agents/orchestrator.md` 의 YAML frontmatter 를 뺀
#   본문을 **실행 시점에 그대로 읽어** 그대로 쓴다 — 이 파일이 검증
#   대상 계약 그 자체이므로 사본을 스크립트에 박아두지 않는다(드리프트
#   방지). D5 워커 매핑(`feature-builder`/`code-reviewer`/
#   `security-reviewer`)이 참조하는 세 워커 에이전트는 실제 v1 정의
#   전체를 로드하지 않고 최소 스텁으로 등록한다 — v1 정의는 DoD/trail
#   전제가 있어 이 bare sandbox 에서 오히려 혼란을 유발한다. 스텁은
#   "워커 dispatch 계약"(커밋/스테이징/stamp/trail/stash 금지, 하위
#   위임 금지)을 그대로 반영한다.
#
# Scenario 1 강화 — 실제 파이프라인 관통 (round 8 코디네이터 지시 #2):
#   transcript 의 parent_tool_use_id 구조 검사만으로는 "위임 구조가
#   있었다"는 것만 보이지, tracker.py 가 실제로 그 실행을 올바르게
#   대조하는지는 보이지 않는다(Design PARTIAL). 그래서 scenario 1 의
#   claude -p 호출에 **캡처 전용 4-hook 최소 settings.json**
#   (TaskCreated/TaskCompleted/SubagentStart/SubagentStop, rein-core 와
#   무관한 별도 throwaway 캡처 스크립트 — `--setting-sources
#   project,local` 조합으로 여전히 rein 자신의 governance hook 은
#   배제된다)을 추가로 얹어, 실제 hook stdin payload 를 그대로 파일에
#   append 한다. 그 raw payload 를 실제 `rein.platform.claude.adapter.
#   normalize_event()` 에 통과시키고, 실제 `WorkUnit`/`WorkGraph.
#   to_planned_units()` 로 만든 2-unit 계획을 실제 `Tracker` 에 먹여
#   `comparison_record()` 가 두 계획 unit 모두 실행됨 + 거짓 mismatch
#   0건을 보이는지 검사한다(`check_tracker_pipeline.py`).
#
#   **실측 발견 (경계 밖 finding, 이 스크립트가 고칠 권한 밖 — 코디네이터
#   보고용)**: 이 설계를 준비하며 두 차례(장난감 2-worker stub 1회 +
#   실제 orchestrator.md 로 2-unit 작업 1회) 실측한 결과, **`TaskCreated`/
#   `TaskCompleted` hook 은 단 한 번도 발화하지 않았다** — Agent 도구를
#   통한 서브에이전트 디스패치(오케스트레이션의 핵심 경로)는
#   `run_in_background` true/false 와 무관하게 `SubagentStart`/
#   `SubagentStop` 만 발화했다(Claude Code 2.1.228, darwin). 이는
#   `tracker.py` 의 1순위 상관관계 경로(`bind_task()`)와 2순위 경로
#   (`[unit:<id>]` task_subject 마커, orchestrator.md anchor:unit-marker
#   가 프롬프트 계약으로 요구하는 바로 그 메커니즘)가 **이 실측 환경에서
#   실제 데이터로는 발동될 수 없다**는 뜻이다 — 그 둘 다 task_subject 를
#   담는 TaskCreated/TaskCompleted payload 에 의존하는데, 그 이벤트
#   자체가 관측되지 않았다. 이 스크립트는 이 사실을 조작된 데이터로
#   덮지 않는다 — 대신 실제로 발화하는 agent 채널(SubagentStart/Stop,
#   `agent_type` 이름 기반 FIFO)만으로 파이프라인을 실증하고,
#   `NOTE[...] task_channel_hook_events_observed=0` 한 줄로 이 finding 을
#   항상 가시화한다(pass/fail 게이트로 쓰지 않는다 — 이 스크립트가 만든
#   결함이 아니라 플랫폼/설계 경계에 대한 관찰이므로). `adapter.py`/
#   `tracker.py`/`orchestrator.md` 는 이 워커의 배타적 scope 밖이라
#   수정하지 않는다.
#
# Scenario 3 (실패→강등, round 8 코디네이터 지시 #3 로 강화):
#   plan 은 "6 시나리오 잔여 2종" 중 하나로 실패→강등을 요구하지만,
#   **spec §5.1 은 강등을 runtime-observed 상태 기계로 정의**하고, Task
#   5.4 는 그 상태 기계(`rein/orchestration/dispatch_env.py`)와 tracker
#   연동(`rein/orchestration/tracker.py`)을 이미 자체 GREEN 유닛
#   테스트로 검증했다(`tests/orchestration/test_dispatch_degradation.py`).
#   headless CLI 로 실제 "중첩 디스패치 불가능한 위치"를 재현하려면
#   에이전트 타입 자체에서 Agent 도구를 제거해야 하는데(SPIKE-3 의 두
#   위치 실측과 동일 조건), `--agents` 인라인 정의가 그 수준의 tool
#   allow/deny 세분화를 지원하지 않아 안정적으로 재현할 수 없다. 이
#   시나리오의 앞부분은 plan Task 5.6 이 명시적으로 허용한 대로("이
#   시나리오는 Python 상태 기계를 직접 사용해도 좋다") `dispatch_env.py` +
#   `tracker.py` 를 직접 조합해 강등 3계열(강등 발생·가시적 통지·tracker
#   기록, BLOCK 없이 흐름 지속)을 검증한다.
#
#   **강화 (round 8 지시 #3)**: 상태 기계 검증만으로는 "강등 이후 실제로
#   무엇이 일어나는가"가 안 보인다 — 그래서 뒤이어 scenario 2 와 동일한
#   harness 로 **실제 headless claude -p 를 1회 더** 구동해, orchestrator
#   를 거치지 않고 워커(`feature-builder`) 하나에 **직접** 단일
#   dispatch 하는 시나리오를 실행한다(`role=worker`, orchestrator 없이
#   "강등된 이후의 단일 워커 경로"를 모사). 이 real dispatch 가 실제로
#   완주(파일 산출물 존재, 깊이3+ 없음, 워커 자신이 직접 편집)하는지
#   검사해 "강등 이후에도 흐름이 진짜로 계속된다"를 상태 기계의
#   예외-없음 증거를 넘어 real evidence 로 보강한다.
#
#   **Governance evaluator 배선은 명시적으로 scope 밖이다** — kernel
#   `Decision`(ALLOW/BLOCK/ASK_USER) 평가를 이 강등 경로에 실제로 연결하는
#   일은 plan Task 6.1(Phase 6 authority 전환)의 소관이다. 이 시나리오는
#   오케스트레이션 메커니즘(강등 → 직접 단일 dispatch → 완주)만 증명하고,
#   그 경로에서 governance 가 실제로 평가되는지는 증명하지 않는다 — spec
#   §2.1 계약("Orchestration 은 Governance 판정에 관여하지 않는다")과도
#   합치하며, 이 스크립트의 배타적 scope(테스트 파일 1개)를 벗어나는
#   런타임 배선 작업을 여기서 시작하지 않는다.
#
# ---------------------------------------------------------------------------
# false-PASS 수정 (round 8 코디네이터 HIGH finding #1)
# ---------------------------------------------------------------------------
#   이전 버전은 claude -p 의 비정상 종료(`claude_rc`)와 parser 자체의
#   비정상 종료(`parse_rc`, 예: transcript 없음 → CHECK 라인 0개로 조용히
#   종료)를 최종 판정에서 누락할 수 있었다 — 그 시나리오가 CHECK 라인을
#   하나도 못 냈다면 FAILED_CHECKS 에도 안 잡히고, 다른 시나리오가 이미
#   충분한 통과 체크를 냈다면 최종 조건(`FAILED_CHECKS -eq 0 && TOTAL_CHECKS
#   -gt 0`)이 여전히 참이 되어 **false PASS** 가 가능했다. 지금은
#   `run_scenario` 가 시나리오마다 `claude_rc != 0` 또는 `parse_rc != 0`
#   중 하나라도 있으면 `SCENARIO_FAILURES` 를 1 증가시키고(시나리오당
#   최대 1, 이중 계상 방지), 최종 판정이 `FAILED_CHECKS -eq 0 &&
#   TOTAL_CHECKS -gt 0 && SCENARIO_FAILURES -eq 0` 세 조건 전부를
#   요구한다 — CHECK 라인이 하나도 안 나온 침묵 실패도 이제 최종 판정을
#   FAIL 로 끌어내린다.
#
# ---------------------------------------------------------------------------
# Bash 기반 self-edit 오탐 방지 (round 9 코디네이터 최종 HIGH finding)
# ---------------------------------------------------------------------------
#   `orchestrator_zero_self_edits` 는 원래 Edit/Write/MultiEdit/
#   NotebookEdit **tool_use 이름**만 세었다 — depth2(orchestrator)가
#   Bash 로 직접 파일을 쓰면(`echo ... > file`, `cat <<EOF > file`,
#   `tee`, `sed -i`, `mv`/`cp`, `mkdir`/`touch`, `python3 -c
#   "open(...,'w')..."` 등) 이 카운트에 전혀 잡히지 않고, 산출물 파일
#   존재 체크와 depth2 편집-0 체크 둘 다 조용히 통과하는 false-PASS
#   경로였다.
#
#   **선택한 규칙 (코디네이터가 제시한 두 안 중 하나를 선택 — 이유 포함)**:
#   코디네이터는 두 안을 제시했다 — (a) 일반적인 write-지시 패턴
#   (redirection/tee/sed -i/mv·cp/mkdir·touch/python·node inline write)
#   으로 depth2 의 **모든** Bash 호출을 분류, 또는 (b) 더 단순·엄격하게
#   depth2 Bash 호출이 **이번 시나리오의 산출물 파일명**을 건드리는지만
#   검사(읽기 전용 Bash 는 허용).
#
#   **(a) 를 선택했다.** 이유: (b) 는 호출부가 `expect_files` 로 넘긴
#   특정 파일명(예: calc.py/greet.py/slugify.py)에만 반응하므로,
#   orchestrator 가 **계획에 없던 다른 경로**에 Bash 로 쓰기를 해도(더
#   심각한 위반인데도) 놓친다 — "산출물 파일명 목록"이라는 우연한
#   좁힘에 안전성이 의존하게 된다. (a) 는 파일명과 무관하게 depth2 에서
#   관측되는 모든 Bash 호출의 **명령 형태** 자체를 검사하므로, 계획에
#   없는 경로에 대한 쓰기도 동일하게 잡는다 — 더 넓고 더 안전한 방향
#   (실제 위반을 놓치는 false negative 를 줄이는 쪽을 우선한다, false
#   positive 는 사람이 한 줄 보면 되는 저비용이다). 패턴 목록과
#   `_is_write_indicating_bash_command()` 는 `parse_and_check.py` 상단에
#   있다 — 정규식은 의도적으로 과포함(over-inclusive)이다.
#
#   `orchestrator_zero_self_edits` 체크 자체를
#   `orchestrator_zero_self_edits_via_tool_calls`(기존 Edit/Write 계열)
#   와 `orchestrator_zero_self_edits_via_bash`(신규, 이 절)로 **분리된
#   두 개의 CHECK 라인**으로 나눴다 — 코디네이터 지시대로 "미래의
#   false-negative 가 가시화되도록" 하기 위함이다: 둘 중 하나가 실패해도
#   정확히 어느 경로(도구 호출 vs Bash 명령)가 위반인지 로그만 보고 바로
#   알 수 있다. `role=worker` 시나리오(강등 이후 단일 워커 direct
#   dispatch, `worker_performs_direct_edit`)는 이 분류를 적용하지 않는다
#   — 코디네이터의 이번 지시는 "self-edit **금지**" 방향의 false-PASS
#   (orchestrator 가 몰래 편집)만 다루며, worker 가 Bash 로 정당하게
#   편집하는 경우를 놓치는 반대 방향(테스트가 헛되이 FAIL하는 것)은
#   보안·계약 위반이 아니라 단순 테스트 취약도 문제라 이번 scope 밖으로
#   명시적으로 남긴다.
#
# ---------------------------------------------------------------------------
# 실행 시간/비용
# ---------------------------------------------------------------------------
#   Scenario 1/2/3-post-degradation 는 각각 실제 LLM 세션 1회(--model
#   sonnet, 소형에 가까운 워커 프롬프트)다. 이 스크립트 작성 시점 실측
#   (darwin/Claude Code 2.1.228): 2-level nested dispatch 완주 ~15-90s,
#   단일 직접 워커 dispatch 는 더 짧다. 각 호출에 안전망으로 워치독을
#   건다 — `timeout`/`gtimeout` 바이너리가 이 darwin 환경에 없으므로
#   백그라운드+감시 프로세스로 직접 구현한다(`invoke_claude_with_timeout`).
#   Scenario 3 앞부분(상태 기계)은 순수 Python 이라 사실상 0초다. 목표
#   총 실행 시간 < 5분(plan Step 2 지시) — 실측치는 아래 실행 결과 참조.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCHESTRATOR_MD="$PLUGIN_ROOT/agents/orchestrator.md"

CLAUDE_INVOKE_TIMEOUT_SECS="${REIN_E2E_CLAUDE_TIMEOUT_SECS:-240}"

TOTAL_CHECKS=0
FAILED_CHECKS=0
SCENARIO_FAILURES=0
LAST_SBOX=""
LAST_CAPTURE_DIR=""

# ---------------------------------------------------------------------------
# CLI 부재 → 명시 SKIP + exit 0 (CI 조건부 실행, plan Step 1)
# ---------------------------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not found on PATH — orchestration e2e requires a"
  echo "SKIP: real headless-capable Claude Code install. Skipping cleanly"
  echo "SKIP: (CI conditional; this is not a failure)."
  echo "E2E RESULT: SKIP (0 checks)"
  exit 0
fi

if [ ! -f "$ORCHESTRATOR_MD" ]; then
  echo "FAIL: orchestrator contract not found at $ORCHESTRATOR_MD" >&2
  echo "E2E RESULT: FAIL (0 checks)"
  exit 1
fi

echo "e2e-orchestration: claude CLI found: $(command -v claude)"
echo "e2e-orchestration: claude --version: $(claude --version 2>&1 | head -n1)"
echo "e2e-orchestration: orchestrator contract: $ORCHESTRATOR_MD"

# ---------------------------------------------------------------------------
# 공유 작업 디렉터리 — 파서/agents.json 빌더/캡처 스크립트만 여기 둔다
# (각 scenario 의 실제 task 실행 sandbox 는 별도 mktemp, 아래 run_scenario).
# ---------------------------------------------------------------------------
WORK_BASE=$(mktemp -d "${TMPDIR:-/tmp}/rein-orch-e2e-base.XXXXXX") || exit 1
WORK_BASE=$(cd "$WORK_BASE" && pwd)  # canonicalize (macOS /var vs /private/var)
SCENARIO_DIRS=()

cleanup_all() {
  rm -rf "$WORK_BASE"
  for d in "${SCENARIO_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# 워커 스텁 프롬프트 + orchestrator.md 본문(frontmatter 제거)을 조합해
# `--agents` JSON 을 1회 빌드한다(모든 scenario 가 같은 계약을 쓴다).
# ---------------------------------------------------------------------------
cat > "$WORK_BASE/build_agents_json.py" <<'PYEOF'
import json
import sys

orchestrator_md_path = sys.argv[1]
with open(orchestrator_md_path, encoding="utf-8") as fh:
    raw = fh.read()

# YAML frontmatter (--- ... ---) 제거 — 실제 plugin agent 로더가 name/
# description 을 메타로 파싱해 prompt 본문에서 빼는 것과 동형으로 맞춘다.
body = raw
if raw.startswith("---\n"):
    end = raw.find("\n---\n", 4)
    if end != -1:
        body = raw[end + 5:]

FEATURE_BUILDER_PROMPT = (
    "You are a Builder worker dispatched by an Orchestrator subagent (or, "
    "in a degraded single-worker path, dispatched directly) as part of a "
    "rein v2 orchestration e2e test (D5 worker mapping: feature-builder). "
    "Read the WorkUnit description in the prompt you were given and "
    "perform exactly the file edit(s) it describes using the Write or "
    "Edit tool, and nothing else.\n\n"
    "You MUST NOT: run `git commit`, run `git add` or any other staging "
    "command, create or modify any review/security stamp file, write "
    "anything under a trail/ directory, or run `git stash` (worker "
    "dispatch prohibition list — those five are always parent-owned).\n\n"
    "You MUST NOT delegate this work to any other subagent — perform the "
    "edit yourself; depth budget forbids workers from dispatching "
    "further.\n\n"
    "When done, reply with a short structured summary: status: completed "
    "(or blocked), changed_files: <list>, summary: <one line>."
)
CODE_REVIEWER_PROMPT = (
    "You are a Reviewer worker dispatched by an Orchestrator subagent as "
    "part of a rein v2 orchestration e2e test (D5 worker mapping: "
    "code-reviewer). Read the file(s) described in your prompt, briefly "
    "assess correctness, and reply with a short structured summary: "
    "status: completed, summary: <one line>.\n\n"
    "You MUST NOT edit any files, run any git command, or delegate to any "
    "other subagent — this is a read-only review."
)
SECURITY_REVIEWER_PROMPT = (
    "You are a Security reviewer worker dispatched by an Orchestrator "
    "subagent as part of a rein v2 orchestration e2e test (D5 worker "
    "mapping: security-reviewer). Read the file(s) described in your "
    "prompt, briefly assess for obvious security issues, and reply with a "
    "short structured summary: status: completed, summary: <one line>.\n\n"
    "You MUST NOT edit any files, run any git command, or delegate to any "
    "other subagent — this is a read-only review."
)

agents = {
    "orchestrator": {
        "description": (
            "rein v2 orchestrator under e2e test — verbatim "
            "plugins/rein-core/agents/orchestrator.md contract body."
        ),
        "prompt": body,
    },
    "feature-builder": {
        "description": "Builder worker stub for e2e test (D5 worker mapping name).",
        "prompt": FEATURE_BUILDER_PROMPT,
    },
    "code-reviewer": {
        "description": "Reviewer worker stub for e2e test (D5 worker mapping name).",
        "prompt": CODE_REVIEWER_PROMPT,
    },
    "security-reviewer": {
        "description": "Security reviewer worker stub for e2e test (D5 worker mapping name).",
        "prompt": SECURITY_REVIEWER_PROMPT,
    },
}
json.dump(agents, sys.stdout)
PYEOF

AGENTS_JSON=$(python3 "$WORK_BASE/build_agents_json.py" "$ORCHESTRATOR_MD")
if [ -z "$AGENTS_JSON" ]; then
  echo "FAIL: failed to build --agents JSON from orchestrator.md" >&2
  echo "E2E RESULT: FAIL (0 checks)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 캡처 전용 hook 스크립트 + settings.json — scenario 1 의 real pipeline
# 검증(아래 check_tracker_pipeline.py)이 소비할 진짜 hook stdin payload 를
# 얻기 위한 것. rein-core 의 hooks/hooks.json 과는 완전히 무관한 4개
# 이벤트(TaskCreated/TaskCompleted/SubagentStart/SubagentStop) 전용
# throwaway 등록이다 — 절대 deny/block 하지 않고 stdin 을 그대로
# 파일 하나에 append 만 하고 exit 0. 캡처 디렉터리는
# REIN_E2E_HOOK_CAPTURE_DIR 환경변수로 매 호출마다 바뀐다(같은
# capture.sh 를 모든 capture 요청 시나리오가 공유).
# ---------------------------------------------------------------------------
cat > "$WORK_BASE/capture.sh" <<'SHEOF'
#!/bin/bash
CAPTURE_DIR="${REIN_E2E_HOOK_CAPTURE_DIR:-}"
if [ -z "$CAPTURE_DIR" ]; then
  cat > /dev/null
  exit 0
fi
mkdir -p "$CAPTURE_DIR" 2>/dev/null
OUTFILE="$CAPTURE_DIR/$(date +%s%N)-$$-$RANDOM.json"
cat > "$OUTFILE" 2>/dev/null
exit 0
SHEOF
chmod +x "$WORK_BASE/capture.sh"

HOOK_CAPTURE_SETTINGS_JSON=$(python3 -c "
import json
cmd = '$WORK_BASE/capture.sh'
hook_names = ['TaskCreated', 'TaskCompleted', 'SubagentStart', 'SubagentStop']
hooks = {name: [{'hooks': [{'type': 'command', 'command': cmd}]}] for name in hook_names}
print(json.dumps({'hooks': hooks}))
")

# ---------------------------------------------------------------------------
# transcript 파서 — parent_tool_use_id 체인으로 깊이를 재구성하고, 두
# role 을 지원한다:
#   role=orchestrator — depth1 이 depth2(=expected_depth2_agent, 보통
#     "orchestrator")를 위임하고, depth2 는 스스로 편집하지 않고 depth3
#     워커(들)에게 위임하며, depth3 는 더 이상 위임하지 않는다(깊이4=0),
#     그리고 depth3 메시지가 실제로 최소 1개 존재해야 한다(위임이 구조만
#     있고 실행되지 않은 게 아님을 확인 — round 8 지시 #2).
#   role=worker — depth1 이 depth2(=expected_depth2_agent, 예:
#     "feature-builder")를 **직접** 위임하고, depth2 자신이 편집하며,
#     더 이상 위임하지 않는다(depth3 이상 0건) — 강등 이후 단일 워커
#     직접 dispatch 경로(round 8 지시 #3, scenario3-post-degradation).
# ---------------------------------------------------------------------------
cat > "$WORK_BASE/parse_and_check.py" <<'PYEOF'
"""parse_and_check.py — real nested-dispatch evidence checker.

Parses a `claude -p --output-format stream-json --include-hook-events
--forward-subagent-text` transcript. Claude Code stamps every forwarded
subagent assistant/user message with `parent_tool_use_id` (the tool_use id
of the Task/Agent call that spawned it) and `subagent_type`. This script
walks the transcript in chronological (JSONL) order, and since a dispatching
tool_use block always appears strictly before any message it spawns, a
single forward pass is enough to assign each assistant message a nesting
depth (1 = top-level session, 2 = dispatch target, 3 = worker (role=
orchestrator only), 4+ = forbidden self-delegation).
"""
import json
import os
import re
import sys

DISPATCH_TOOL_NAMES = {"Agent", "Task"}
EDIT_TOOL_NAMES = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
BASH_TOOL_NAME = "Bash"
ROLES = ("orchestrator", "worker")

# round 9 (coordinator final HIGH fix) — a depth-2 orchestrator could
# perform a direct file write via Bash (redirection, `tee`, `sed -i`,
# `mv`/`cp`, `mkdir`/`touch`, python/node inline writes) instead of the
# Edit/Write/MultiEdit/NotebookEdit tool family, which the original
# orchestrator_zero_self_edits check never inspected at all — a genuine
# false-PASS route (see script header "Bash 기반 self-edit 오탐 방지"
# 절 for the chosen-rule rationale). This regex is deliberately broad and
# over-inclusive: false positives (flagging a harmless command that merely
# contains one of these tokens) are an acceptable, cheap-to-triage cost;
# false negatives (a real write slipping through unflagged) are exactly
# the failure mode this fix exists to close, so the pattern list errs
# toward catching too much rather than too little.
_WRITE_INDICATING_BASH_RE = re.compile(
    r">>?(?!\s*&[12]\b)(?!\s*/dev/null\b)"  # redirection, excluding fd-dup
    # (>&1, >&2) and the common harmless /dev/null idiom (round 9 fix-up —
    # kept narrow: only /dev/null is excluded, every other redirect target
    # still counts, in line with the "err toward catching too much" rule).
    r"|\btee\b"
    r"|\bsed\b[^\n|;&]*(-i\b|--in-place\b)"
    r"|\b(mv|cp)\b"
    r"|\bmkdir\b"
    r"|\btouch\b"
    r"|\bdd\b[^\n|;&]*\bof="
    r"|\bperl\b[^\n|;&]*-i\b"
    r"|writeFile\w*\("  # node fs.writeFile(...) / writeFileSync(...)
)

# python `open(...)` write-mode detection needs its own two-step matcher —
# a single regex like `open\([^)]*["\']a?w["\']` misses append-only mode
# (`'a'` with no literal `w`) and keyword form (`mode='w'`), and a naive
# "does the open(...) call contain a w/a/x character anywhere" broadening
# would false-positive on ordinary filenames that happen to contain those
# letters (e.g. `open('extract.py')`). So: find each `open(...)` call,
# then look specifically for its mode argument (positional after a comma,
# or `mode=` keyword) as a short quoted token drawn only from r/w/a/x/b/t/+
# — and flag it unless that token is a pure-read mode.
_OPEN_CALL_RE = re.compile(r"open\([^)]*\)")
_OPEN_MODE_ARG_RE = re.compile(r"(?:,\s*|mode\s*=\s*)[\"']([rwaxbt+]{1,4})[\"']")
_OPEN_READ_ONLY_MODES = frozenset({"r", "rt", "rb", "tr", "br"})


def _has_write_mode_open_call(command):
    for call in _OPEN_CALL_RE.findall(command):
        match = _OPEN_MODE_ARG_RE.search(call)
        if match and match.group(1) not in _OPEN_READ_ONLY_MODES:
            return True
    return False


def _is_write_indicating_bash_command(command):
    """True if `command` matches any write-indicating shell pattern.

    Deliberately broad heuristic (module docstring above) — used only to
    classify depth-2 (orchestrator) Bash tool_use commands as a self-edit
    violation. Non-str/empty input is never a violation.
    """
    if not isinstance(command, str) or not command:
        return False
    if _WRITE_INDICATING_BASH_RE.search(command):
        return True
    return _has_write_mode_open_call(command)


def fail(msg):
    print("PARSE_ERROR: {}".format(msg), file=sys.stderr)
    sys.exit(2)


def main():
    if len(sys.argv) < 8:
        fail(
            "usage: parse_and_check.py <transcript> <workdir> <label> "
            "<role:orchestrator|worker> <expected_depth2_agent> "
            "<worker_min> <worker_max|none> [rel_path substring]..."
        )

    (
        transcript_path,
        workdir,
        label,
        role,
        expected_depth2_agent,
        worker_min_s,
        worker_max_s,
    ) = sys.argv[1:8]
    file_pairs = sys.argv[8:]
    if len(file_pairs) % 2 != 0:
        fail("expect-file args must come in (path, substring) pairs")
    expect_files = list(zip(file_pairs[0::2], file_pairs[1::2]))

    if role not in ROLES:
        fail("role must be one of {}, got {!r}".format(ROLES, role))

    worker_min = int(worker_min_s)
    worker_max = None if worker_max_s == "none" else int(worker_max_s)

    if not os.path.isfile(transcript_path):
        fail("transcript not found: {}".format(transcript_path))

    records = []
    depth_of_tool_use_id = {}

    with open(transcript_path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if obj.get("type") != "assistant":
                continue
            parent = obj.get("parent_tool_use_id")
            subagent_type = obj.get("subagent_type")
            if parent is None:
                depth = 1
            else:
                parent_depth = depth_of_tool_use_id.get(parent)
                depth = None if parent_depth is None else parent_depth + 1
            content = (obj.get("message") or {}).get("content") or []
            tool_uses = [
                (
                    c.get("name"),
                    c.get("id"),
                    c.get("input") if isinstance(c.get("input"), dict) else {},
                )
                for c in content
                if isinstance(c, dict) and c.get("type") == "tool_use"
            ]
            for name, tid, _tool_input in tool_uses:
                if tid:
                    depth_of_tool_use_id[tid] = depth
            records.append(
                {"depth": depth, "subagent_type": subagent_type, "tool_uses": tool_uses}
            )

    checks = []

    depth1_dispatches = sum(
        1
        for r in records
        if r["depth"] == 1
        for name, _tid, _inp in r["tool_uses"]
        if name in DISPATCH_TOOL_NAMES
    )
    depth2_records = [r for r in records if r["depth"] == 2]
    depth2_dispatches = sum(
        1
        for r in depth2_records
        for name, _tid, _inp in r["tool_uses"]
        if name in DISPATCH_TOOL_NAMES
    )
    depth2_edits = sum(
        1
        for r in depth2_records
        for name, _tid, _inp in r["tool_uses"]
        if name in EDIT_TOOL_NAMES
    )
    depth2_bash_commands = [
        inp.get("command")
        for r in depth2_records
        for name, _tid, inp in r["tool_uses"]
        if name == BASH_TOOL_NAME
    ]
    depth2_bash_write_matches = [
        cmd for cmd in depth2_bash_commands if _is_write_indicating_bash_command(cmd)
    ]
    depth2_subagent_types = sorted(
        {r["subagent_type"] for r in depth2_records if r["subagent_type"]}
    )
    depth3_records = [r for r in records if r["depth"] == 3]
    depth3_dispatches = sum(
        1
        for r in depth3_records
        for name, _tid, _inp in r["tool_uses"]
        if name in DISPATCH_TOOL_NAMES
    )
    depth4_plus = sum(1 for r in records if r["depth"] is not None and r["depth"] >= 4)

    checks.append(
        (
            depth1_dispatches >= 1,
            "top_level_dispatches_{} (depth1 Agent/Task tool_use "
            "count={})".format(expected_depth2_agent, depth1_dispatches),
        )
    )

    checks.append(
        (
            bool(depth2_records) and depth2_subagent_types == [expected_depth2_agent],
            "depth2_is_{} (observed subagent_type set at depth2={})".format(
                expected_depth2_agent, depth2_subagent_types
            ),
        )
    )

    if role == "orchestrator":
        if worker_max is None:
            bound_desc = ">= {}".format(worker_min)
        elif worker_min == worker_max:
            bound_desc = "== {}".format(worker_min)
        else:
            bound_desc = "in [{}, {}]".format(worker_min, worker_max)
        worker_dispatch_ok = depth2_dispatches >= worker_min and (
            worker_max is None or depth2_dispatches <= worker_max
        )
        checks.append(
            (
                worker_dispatch_ok,
                "orchestrator_dispatches_workers (depth2 Agent/Task tool_use "
                "count={}, expected {})".format(depth2_dispatches, bound_desc),
            )
        )

        checks.append(
            (
                depth2_edits == 0,
                "orchestrator_zero_self_edits_via_tool_calls (depth2 Edit/"
                "Write/MultiEdit/NotebookEdit tool_use count={})".format(
                    depth2_edits
                ),
            )
        )

        # round 9 (coordinator final HIGH fix) — distinct CHECK line so a
        # future false-negative (orchestrator writing via Bash instead of
        # the Edit/Write tool family) is directly visible, not silently
        # folded into the tool-based check above. See script header
        # "Bash 기반 self-edit 오탐 방지" 절 for the classifier rationale.
        _depth2_bash_write_samples = [cmd[:80] for cmd in depth2_bash_write_matches[:3]]
        checks.append(
            (
                len(depth2_bash_write_matches) == 0,
                "orchestrator_zero_self_edits_via_bash (depth2 Bash tool_use "
                "count={}, classified as write-indicating={}, "
                "samples={!r})".format(
                    len(depth2_bash_commands),
                    len(depth2_bash_write_matches),
                    _depth2_bash_write_samples,
                ),
            )
        )

        checks.append(
            (
                depth3_dispatches == 0 and depth4_plus == 0,
                "zero_depth4_dispatch_attempts (depth3->depth4 dispatch "
                "attempts={}, observed depth>=4 messages={})".format(
                    depth3_dispatches, depth4_plus
                ),
            )
        )

        # round 8 지시 #2 — 위임이 "구조"만 있는 게 아니라 실제로 워커
        # 턴이 실행됐음을 확인한다(depth2 dispatch 카운트만으로는 실제
        # 워커 메시지 존재를 보장하지 않는다 — 예: dispatch 후 결과 없이
        # 끊긴 경우와 구분).
        checks.append(
            (
                len(depth3_records) >= 1,
                "depth3_worker_message_exists (depth3 message count={})".format(
                    len(depth3_records)
                ),
            )
        )
    else:  # role == "worker" — 강등 이후 직접 단일 dispatch 경로
        checks.append(
            (
                depth2_edits >= 1,
                "worker_performs_direct_edit (depth2 Edit/Write/MultiEdit/"
                "NotebookEdit tool_use count={})".format(depth2_edits),
            )
        )
        checks.append(
            (
                depth2_dispatches == 0,
                "worker_does_not_delegate_further (depth2 Agent/Task "
                "tool_use count={})".format(depth2_dispatches),
            )
        )
        checks.append(
            (
                len(depth3_records) == 0 and depth4_plus == 0,
                "zero_depth3_plus_messages (depth3 message count={}, "
                "depth>=4 message count={})".format(
                    len(depth3_records), depth4_plus
                ),
            )
        )

    for rel_path, substring in expect_files:
        abs_path = os.path.join(workdir, rel_path)
        ok = False
        detail = "missing"
        if os.path.isfile(abs_path):
            try:
                with open(abs_path, encoding="utf-8") as fh:
                    content = fh.read()
            except OSError as exc:
                content = ""
                detail = "read-error:{}".format(exc)
            else:
                ok = substring in content
                detail = "content={!r}".format(content[:120])
        checks.append(
            (
                ok,
                "worker_created_file[{}] contains {!r} ({})".format(
                    rel_path, substring, detail
                ),
            )
        )

    overall_ok = all(ok for ok, _ in checks)
    for ok, desc in checks:
        print("CHECK[{}] {} {}".format(label, "PASS" if ok else "FAIL", desc))

    print(
        "SCENARIO_VERDICT[{}] {} ({}/{} checks passed)".format(
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
# check_tracker_pipeline.py — scenario 1 강화(round 8 지시 #2): 실제로
# 캡처된 hook payload 를 실제 adapter.normalize_event() → 실제 Tracker
# (WorkGraph.to_planned_units() 로 만든 2-unit 계획) 로 흘려
# comparison_record() 를 검사한다. 위 스크립트 헤더 "Scenario 1 강화"
# 절의 TaskCreated/TaskCompleted 부재 finding 도 여기서 NOTE 로 표면화한다.
# ---------------------------------------------------------------------------
cat > "$WORK_BASE/check_tracker_pipeline.py" <<'PYEOF'
"""check_tracker_pipeline.py — real captured hook events through the real
adapter.normalize_event() -> Tracker pipeline (plan Task 5.6 round 8
strengthening #2).

Reads every raw hook JSON payload captured by the throwaway capture-only
settings.json during scenario 1's real claude -p run, builds a real 2-unit
WorkGraph (calc.py / greet.py — the exact task scenario 1 asked the
orchestrator to delegate), and feeds the captured agent-channel
(SubagentStart/SubagentStop) events through the production adapter +
Tracker code to assert both planned units were observed executing with
zero false mismatches.

See e2e-orchestration.sh header ("Scenario 1 강화") for why this only
exercises the agent-channel (name-based FIFO) correlation path and not
bind_task()/[unit:<id>] marker correlation: TaskCreated/TaskCompleted were
not observed to fire for Agent-tool subagent dispatch in this environment.
That is reported here as a NOTE line, not folded into pass/fail.
"""
import glob
import json
import os
import sys

# 이 tracker-pipeline 검사의 planned WorkGraph 는 scenario 1 이 실제로
# 요청한 2-unit 작업(calc.py/greet.py, 둘 다 feature-builder 위임)만
# 선언한다 — orchestrator 의 barrier 절차(script header "워커 dispatch
# 계약" 참조)는 code-reviewer/security-reviewer 를 추가로 dispatch 할
# 수도 있는데, 그건 이 2-unit 계획 밖의 정당한 행동이지 계획과 어긋난
# 실행이 아니다. 그래서 tracker 에 실제로 먹이는 이벤트는
# BUILDER_AGENT_TYPES(계획과 일치하는 타입)로 좁히고, 그 외 워커 타입은
# `OTHER_WORKER_ROLE_AGENT_TYPES` 로 별도 집계해 NOTE 로만 노출한다 —
# scope 밖 관측을 "거짓 mismatch" 로 오판하지 않기 위함(round 9 재확인
# 라운드에서 실측으로 드러남: 실제 실행이 feature-builder 2개 + 추가
# code-reviewer 1개였던 사례).
BUILDER_AGENT_TYPES = {"feature-builder"}
OTHER_WORKER_ROLE_AGENT_TYPES = {"code-reviewer", "security-reviewer"}


def main():
    if len(sys.argv) != 4:
        print(
            "usage: check_tracker_pipeline.py <capture_dir> <label> <plugin_root>",
            file=sys.stderr,
        )
        sys.exit(2)
    capture_dir, label, plugin_root = sys.argv[1:4]
    sys.path.insert(0, plugin_root)

    from rein.orchestration.tracker import Tracker
    from rein.orchestration.work_graph import WorkGraph
    from rein.orchestration.work_unit import WorkUnit
    from rein.platform.claude import adapter

    checks = []

    def check(ok, desc):
        checks.append((ok, desc))

    files = sorted(glob.glob(os.path.join(capture_dir, "*.json")))
    raw_events = []
    for fp in files:
        try:
            with open(fp, encoding="utf-8") as fh:
                raw_events.append(json.load(fh))
        except (OSError, json.JSONDecodeError):
            continue

    check(
        len(raw_events) > 0,
        "hook_capture_nonempty (captured {} raw hook payload(s) from {} "
        "file(s))".format(len(raw_events), len(files)),
    )

    task_channel_seen = [
        e for e in raw_events if e.get("hook_event_name") in ("TaskCreated", "TaskCompleted")
    ]
    agent_channel_all = [
        e for e in raw_events if e.get("hook_event_name") in ("SubagentStart", "SubagentStop")
    ]
    builder_events = [
        e for e in agent_channel_all if e.get("agent_type") in BUILDER_AGENT_TYPES
    ]
    other_worker_events = [
        e for e in agent_channel_all if e.get("agent_type") in OTHER_WORKER_ROLE_AGENT_TYPES
    ]

    # 실제 2-unit 계획 — scenario 1 이 orchestrator 에게 위임을 요청한
    # 바로 그 작업(calc.py add / greet.py greet)과 정확히 일치한다.
    planned = (
        WorkUnit(
            id="calc-work",
            objective="implement calc.py with add(a, b)",
            scope=["calc.py"],
            assigned_agent="feature-builder",
            expected_output="calc.py created with add(a, b)",
        ),
        WorkUnit(
            id="greet-work",
            objective="implement greet.py with greet(name)",
            scope=["greet.py"],
            assigned_agent="feature-builder",
            expected_output="greet.py created with greet(name)",
        ),
    )
    graph = WorkGraph(units=planned)
    tracker = Tracker(work_graph=graph.to_planned_units(), project_root=None)

    normalize_errors = 0
    for raw in builder_events:
        try:
            normalized = adapter.normalize_event(raw)
        except adapter.UnknownHookEventError:
            normalize_errors += 1
            continue
        tracker.observe(normalized)

    check(
        normalize_errors == 0,
        "adapter_normalize_event_no_errors (unrecognized hook payloads={})".format(
            normalize_errors
        ),
    )

    record = tracker.comparison_record()
    mismatches = record["mismatches"]

    check(
        mismatches["planned_unexecuted"] == [],
        "tracker_both_planned_units_executed (planned_unexecuted={!r})".format(
            mismatches["planned_unexecuted"]
        ),
    )
    check(
        mismatches["unplanned_observed"] == [],
        "tracker_zero_false_mismatches (unplanned_observed={!r})".format(
            mismatches["unplanned_observed"]
        ),
    )
    check(
        mismatches["unbound_observed"] == [],
        "tracker_zero_unbound_observations (unbound_observed={!r})".format(
            mismatches["unbound_observed"]
        ),
    )
    observed = record["observed"]
    check(
        len(observed) >= 2 and all(e["started"] and e["stopped"] for e in observed),
        "tracker_observed_full_lifecycle (observed={!r})".format(observed),
    )

    for ok, desc in checks:
        print("CHECK[{}-tracker-pipeline] {} {}".format(label, "PASS" if ok else "FAIL", desc))

    # NOTE — 정보성 라인, pass/fail 게이트에 포함하지 않는다(스크립트
    # 헤더 "Scenario 1 강화" finding 절 참조). 이 스크립트가 고칠 수 있는
    # 결함이 아니라 플랫폼 동작에 대한 관찰이다.
    print(
        "NOTE[{}-tracker-pipeline] task_channel_hook_events_observed={} "
        "(TaskCreated/TaskCompleted count — bind()/[unit:<id>] marker "
        "correlation requires this channel; 0 means only agent-channel FIFO "
        "name correlation above was exercised with genuine data)".format(
            label, len(task_channel_seen)
        )
    )
    other_worker_types_seen = sorted(
        {e.get("agent_type") for e in other_worker_events if e.get("agent_type")}
    )
    print(
        "NOTE[{}-tracker-pipeline] other_worker_role_events_outside_plan={} "
        "(agent_type set={!r} — code-reviewer/security-reviewer dispatches "
        "are legitimate barrier-procedure activity outside this 2-unit "
        "builder plan; excluded from the tracker feed above, not a false "
        "mismatch)".format(
            label, len(other_worker_events), other_worker_types_seen
        )
    )

    overall_ok = all(ok for ok, _ in checks)
    print(
        "SCENARIO_VERDICT[{}-tracker-pipeline] {} ({}/{} checks passed)".format(
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
# 헬퍼 — 워치독 타임아웃(darwin 에 `timeout`/`gtimeout` 부재 전제, 직접
# 구현). capture_dir 가 비어있지 않으면 캡처 전용 settings.json 을 얹는다.
# ---------------------------------------------------------------------------
invoke_claude_with_timeout() {
  # $1=workdir $2=prompt $3=outfile $4=errfile $5=timeout_secs $6=capture_dir(optional)
  local wd="$1" prompt="$2" outfile="$3" errfile="$4" secs="$5" capture_dir="${6:-}"
  (
    cd "$wd" || exit 1
    if [ -n "$capture_dir" ]; then
      export REIN_E2E_HOOK_CAPTURE_DIR="$capture_dir"
      # --permission-mode bypassPermissions rationale + risk bounds: see
      # script header "`--permission-mode bypassPermissions` 사용 근거" 절
      # (headless has no terminal for interactive prompts; risk bounded by
      # fixed hardcoded prompts + mktemp sandbox confinement +
      # --strict-mcp-config + trap cleanup).
      claude -p \
        --setting-sources project,local \
        --settings "$HOOK_CAPTURE_SETTINGS_JSON" \
        --output-format stream-json \
        --include-hook-events \
        --forward-subagent-text \
        --permission-mode bypassPermissions \
        --strict-mcp-config \
        --verbose \
        --model sonnet \
        --agents "$AGENTS_JSON" \
        "$prompt"
    else
      # --permission-mode bypassPermissions rationale + risk bounds: see
      # script header "`--permission-mode bypassPermissions` 사용 근거" 절
      # (headless has no terminal for interactive prompts; risk bounded by
      # fixed hardcoded prompts + mktemp sandbox confinement +
      # --strict-mcp-config + trap cleanup).
      claude -p \
        --setting-sources project,local \
        --output-format stream-json \
        --include-hook-events \
        --forward-subagent-text \
        --permission-mode bypassPermissions \
        --strict-mcp-config \
        --verbose \
        --model sonnet \
        --agents "$AGENTS_JSON" \
        "$prompt"
    fi
  ) > "$outfile" 2> "$errfile" &
  local pid=$!
  ( sleep "$secs" && kill -TERM "$pid" 2>/dev/null ) &
  local watchdog=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

# ---------------------------------------------------------------------------
# run_scenario — sandbox 생성 + 실제 claude -p 호출 + 파서 실행 + 집계.
# false-PASS 수정(round 8 HIGH #1): claude_rc/parse_rc 중 하나라도
# 비정상이면 시나리오당 최대 1 로 SCENARIO_FAILURES 를 올린다 — CHECK
# 라인이 0개인 침묵 실패도 최종 판정에 반영되도록.
# ---------------------------------------------------------------------------
run_scenario() {
  local label="$1" prompt="$2" role="$3" expected_depth2_agent="$4" \
        worker_min="$5" worker_max="$6" want_capture="$7"
  shift 7
  local file_checks=("$@")  # 짝수개: rel_path substring rel_path substring ...

  echo ""
  echo "--- Scenario [$label] ---"

  local sbox
  sbox=$(mktemp -d "${TMPDIR:-/tmp}/rein-orch-e2e-$label.XXXXXX") || {
    echo "CHECK[$label] FAIL sandbox_creation"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
    LAST_SBOX=""
    LAST_CAPTURE_DIR=""
    return
  }
  sbox=$(cd "$sbox" && pwd)
  SCENARIO_DIRS+=("$sbox")
  LAST_SBOX="$sbox"

  local capture_dir=""
  if [ "$want_capture" = "1" ]; then
    capture_dir="$sbox/.hookcap"
    mkdir -p "$capture_dir"
  fi
  LAST_CAPTURE_DIR="$capture_dir"

  local outfile="$sbox/.transcript.jsonl"
  local errfile="$sbox/.stderr.log"
  local start_ts end_ts
  start_ts=$(date +%s)
  invoke_claude_with_timeout "$sbox" "$prompt" "$outfile" "$errfile" \
    "$CLAUDE_INVOKE_TIMEOUT_SECS" "$capture_dir"
  local claude_rc=$?
  end_ts=$(date +%s)
  echo "  claude -p exit=$claude_rc duration=$((end_ts - start_ts))s"
  if [ "$claude_rc" != "0" ]; then
    echo "  stderr tail:"
    tail -n 20 "$errfile" 2>/dev/null | sed 's/^/    /'
  fi

  local parse_out parse_rc
  parse_out=$(python3 "$WORK_BASE/parse_and_check.py" "$outfile" "$sbox" "$label" \
    "$role" "$expected_depth2_agent" "$worker_min" "$worker_max" "${file_checks[@]}" 2>&1)
  parse_rc=$?
  echo "$parse_out"

  local n_pass n_fail
  n_pass=$(printf '%s\n' "$parse_out" | grep -c '^CHECK\[' | tr -d ' ')
  n_fail=$(printf '%s\n' "$parse_out" | grep -c '^CHECK\[[^]]*\] FAIL' | tr -d ' ')
  TOTAL_CHECKS=$((TOTAL_CHECKS + n_pass))
  FAILED_CHECKS=$((FAILED_CHECKS + n_fail))

  # false-PASS 수정 — claude 자체 실패 또는 parser 자체 실패(CHECK 라인이
  # 0개일 수 있는 경로 포함)를 시나리오 단위로 명시 집계한다. 시나리오당
  # 최대 1 (두 조건이 동시에 참이어도 이중 계상하지 않는다).
  if [ "$claude_rc" != "0" ] || [ "$parse_rc" != "0" ]; then
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# Scenario 1 — 소형 2-unit 작업 → 위임 구조 존재 / 자체편집0 / 깊이4=0 /
# depth3 워커 메시지 실존 (plan Task 5.6 Step 1 + round 8 지시 #2)
# ---------------------------------------------------------------------------
run_scenario "scenario1-delegation-structure" \
  "Use the Task tool exactly once, with subagent_type=orchestrator, to delegate this development task in the current working directory: implement two independent, non-trivial Python utility modules with no shared code — (1) calc.py must define a function add(a, b) that returns their sum, with a one-line docstring and a __main__ demo block that prints add(2, 3); (2) greet.py must define a function greet(name) that returns the string 'Hello, ' + name + '!', with a one-line docstring and a __main__ demo block that prints greet('World'). These are two unrelated, independently scoped pieces of development work — treat this as real non-trivial development work worth delegating to a builder, not a trivial text-file drop. After dispatching to orchestrator and receiving its final result, reply with exactly the text FINISHED. Do not write any code or files yourself — your only tool call should be the single Task dispatch to orchestrator." \
  orchestrator orchestrator 1 none 1 \
  "calc.py" "def add(a, b)" \
  "greet.py" "def greet(name)"

# Scenario 1 강화 — 실제 캡처 hook 이벤트를 실제 adapter+Tracker 파이프라인에.
if [ -n "$LAST_CAPTURE_DIR" ] && [ -d "$LAST_CAPTURE_DIR" ]; then
  TP_OUT=$(python3 "$WORK_BASE/check_tracker_pipeline.py" \
    "$LAST_CAPTURE_DIR" "scenario1-delegation-structure" "$PLUGIN_ROOT" 2>&1)
  TP_RC=$?
  echo "$TP_OUT"
  TP_PASS=$(printf '%s\n' "$TP_OUT" | grep -c '^CHECK\[' | tr -d ' ')
  TP_FAIL=$(printf '%s\n' "$TP_OUT" | grep -c '^CHECK\[[^]]*\] FAIL' | tr -d ' ')
  TOTAL_CHECKS=$((TOTAL_CHECKS + TP_PASS))
  FAILED_CHECKS=$((FAILED_CHECKS + TP_FAIL))
  if [ "$TP_RC" != "0" ]; then
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  fi
else
  echo "CHECK[scenario1-delegation-structure-tracker-pipeline] FAIL tracker_pipeline_capture_dir_missing"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 2 — 소형→단일: 트리비얼 작업은 분해하지 않고 단일 워커로
# (plan Task 5.6 Step 2, "6 시나리오 잔여 2종" 중 소형→단일)
# ---------------------------------------------------------------------------
run_scenario "scenario2-small-to-single" \
  "Use the Task tool exactly once, with subagent_type=orchestrator, to delegate this development task in the current working directory: implement a single small Python utility module slugify.py that defines a function slugify(text) returning text lowercased with internal whitespace runs replaced by single hyphens, with a one-line docstring and a __main__ demo block that prints slugify('Hello World'). This is one small, non-decomposable unit of real development work — there is nothing here to split across multiple parallel workers, so it must be handled by a single worker, not decomposed into several. After dispatching to orchestrator and receiving its final result, reply with exactly the text FINISHED. Do not write any code or files yourself — your only tool call should be the single Task dispatch to orchestrator." \
  orchestrator orchestrator 1 1 0 \
  "slugify.py" "def slugify(text)"

# ---------------------------------------------------------------------------
# Scenario 3 — 실패→강등: runtime-observed 상태 기계를 직접 조합
# (plan Task 5.6 Step 2, "6 시나리오 잔여 2종" 중 실패→fallback; 설계
# 근거는 파일 상단 헤더 "Scenario 3" 절 참조 — spec §5.1 이 강등을
# runtime-observed 로 정의하므로 CLI 를 띄우지 않는다. 강등 이후의 real
# CLI 검증은 이 블록 뒤에 이어지는 별도 run_scenario 호출로 강화됨)
# ---------------------------------------------------------------------------
echo ""
echo "--- Scenario [scenario3-failure-fallback] ---"
SCENARIO3_OUT=$(PYTHONPATH="$PLUGIN_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import sys
import traceback

label = "scenario3-failure-fallback"
checks = []


def check(ok, desc):
    checks.append((ok, desc))


try:
    from rein.orchestration import dispatch_env
    from rein.orchestration.tracker import Tracker

    # (a) 사전 감지 불가 → 즉시 강등 + 가시적 통지 + tracker 기록.
    tracker_a = Tracker(work_graph=[], project_root=None)
    env_a = dispatch_env.DispatchEnvironment(recorder=tracker_a.record_degradation)
    state_a = env_a.detect(probe=lambda: False)
    check(
        state_a == dispatch_env.STATE_INCAPABLE,
        "probe_incapable_degrades_state (state={})".format(state_a),
    )
    check(
        env_a.mode == dispatch_env.MODE_SINGLE_WORKER,
        "probe_incapable_mode_single_worker (mode={})".format(env_a.mode),
    )
    check(
        bool(env_a.notice) and "단일 워커" in env_a.notice,
        "visible_plain_text_notice_present (notice={!r})".format(env_a.notice),
    )
    check(
        tracker_a.degraded is not None
        and tracker_a.degraded.get("reason") == dispatch_env.REASON_PROBE_INCAPABLE,
        "tracker_records_degradation (degraded={!r})".format(tracker_a.degraded),
    )
    record_a = tracker_a.comparison_record()
    check(
        record_a.get("degraded") is not None,
        "comparison_record_exposes_degraded ({!r})".format(record_a.get("degraded")),
    )

    # (b) 세션 스코프 캐시 — 이미 결정된 세션은 probe 를 다시 부르지 않는다.
    calls = {"n": 0}

    def counting_probe():
        calls["n"] += 1
        return False

    env_a.detect(probe=counting_probe)
    check(
        calls["n"] == 0 and env_a.probe_consultations == 1,
        "session_scope_cache_no_reprobe (recount={}, probe_consultations={})".format(
            calls["n"], env_a.probe_consultations
        ),
    )

    # (c) 관측 우선 — 사전에 capable 이었어도 실제 실패 관측 시 즉시 강등,
    # 예외 없이(= 일반 작업 BLOCK 없이) 흐름이 계속된다.
    tracker_b = Tracker(work_graph=[], project_root=None)
    env_b = dispatch_env.DispatchEnvironment(recorder=tracker_b.record_degradation)
    state_pre = env_b.detect(probe=lambda: True)
    check(
        state_pre == dispatch_env.STATE_CAPABLE,
        "precondition_capable_before_failure (state={})".format(state_pre),
    )
    no_exception = True
    try:
        state_b = env_b.report_dispatch_failure(
            "simulated nested dispatch failure in e2e scenario 3"
        )
    except Exception:  # noqa: BLE001 - 이 자체가 실패 신호
        no_exception = False
        state_b = None
    check(
        no_exception,
        "observed_failure_raises_no_exception (no_exception={})".format(no_exception),
    )
    check(
        state_b == dispatch_env.STATE_INCAPABLE,
        "observed_failure_degrades_state (state={})".format(state_b),
    )
    check(
        env_b.mode == dispatch_env.MODE_SINGLE_WORKER,
        "observed_failure_mode_single_worker (mode={})".format(env_b.mode),
    )
    check(
        bool(env_b.notice),
        "observed_failure_visible_notice_present (notice={!r})".format(env_b.notice),
    )
    check(
        tracker_b.degraded is not None
        and tracker_b.degraded.get("reason") == dispatch_env.REASON_OBSERVED_FAILURE,
        "tracker_records_observed_failure_degradation (degraded={!r})".format(
            tracker_b.degraded
        ),
    )

    # (d) 일반 작업 BLOCK 없음의 실행 축 — 강등 이후에도 정상적으로 다음
    # 코드가 계속 실행된다(이 지점까지 도달 자체가 증거). 강등 이후 실제
    # CLI 로 단일 워커가 완주하는지는 이 블록 뒤의 별도 real-dispatch
    # scenario 가 증명한다(round 8 지시 #3).
    _ = env_b.to_dict()
    check(True, "flow_continues_after_degradation (reached post-degradation code)")

except Exception:  # noqa: BLE001 - 예상 밖 예외는 전부 실패로 기록
    traceback.print_exc()
    check(False, "unexpected_exception_in_scenario3 (see stderr above)")

overall_ok = all(ok for ok, _ in checks) if checks else False
for ok, desc in checks:
    print("CHECK[{}] {} {}".format(label, "PASS" if ok else "FAIL", desc))
print(
    "SCENARIO_VERDICT[{}] {} ({}/{} checks passed)".format(
        label,
        "PASS" if overall_ok else "FAIL",
        sum(1 for ok, _ in checks if ok),
        len(checks),
    )
)
sys.exit(0 if overall_ok else 1)
PYEOF
)
SCENARIO3_RC=$?
echo "$SCENARIO3_OUT"
S3_PASS=$(printf '%s\n' "$SCENARIO3_OUT" | grep -c '^CHECK\[' | tr -d ' ')
S3_FAIL=$(printf '%s\n' "$SCENARIO3_OUT" | grep -c '^CHECK\[[^]]*\] FAIL' | tr -d ' ')
TOTAL_CHECKS=$((TOTAL_CHECKS + S3_PASS))
FAILED_CHECKS=$((FAILED_CHECKS + S3_FAIL))
if [ "$SCENARIO3_RC" != "0" ]; then
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Scenario 3 강화 — 강등 이후 실제 단일 워커 direct dispatch (round 8 지시
# #3). orchestrator 를 거치지 않고 feature-builder 워커 하나에 직접
# dispatch — dispatch_env.mode == single_worker 이후 실제로 어떤 경로가
# 밟히는지(직접 단일 위임)를 모사한다. scenario 2 와 동일 harness
# (run_scenario/parse_and_check.py) 를 재사용하되 role=worker.
# Governance evaluator 배선은 scope 밖(파일 헤더 "Scenario 3" 절 참조).
# ---------------------------------------------------------------------------
run_scenario "scenario3-post-degradation-single-worker" \
  "Use the Task tool exactly once, with subagent_type=feature-builder, to delegate this task in the current working directory: create a file named degraded-mode-worker.txt containing exactly the single line SINGLE-WORKER-POST-DEGRADATION-OK. This models the fallback path taken after orchestration has degraded to single-worker mode (dispatch_env.mode == single_worker) — no orchestrator, no decomposition, a single direct worker dispatch. After dispatching and receiving the result, reply with exactly the text FINISHED. Do not write any files yourself — your only tool call should be the single Task dispatch to feature-builder." \
  worker feature-builder 0 0 0 \
  "degraded-mode-worker.txt" "SINGLE-WORKER-POST-DEGRADATION-OK"

# ---------------------------------------------------------------------------
# 요약
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "Total checks: $TOTAL_CHECKS"
echo "Failed:       $FAILED_CHECKS"
echo "Scenarios with failures: $SCENARIO_FAILURES"
echo "================================"

# false-PASS 수정(round 8 HIGH #1) — 세 조건 전부 요구: 실패한 체크 0건,
# 체크가 최소 1건 이상 기록됐음(침묵 실패 방지), 그리고 시나리오 단위
# 실패(claude 자체 비정상 종료 또는 parser 비정상 종료)가 0건.
if [ "$FAILED_CHECKS" -eq 0 ] && [ "$TOTAL_CHECKS" -gt 0 ] && [ "$SCENARIO_FAILURES" -eq 0 ]; then
  echo "E2E RESULT: PASS ($TOTAL_CHECKS checks)"
  exit 0
else
  echo "E2E RESULT: FAIL ($FAILED_CHECKS/$TOTAL_CHECKS checks failed; scenario_failures=$SCENARIO_FAILURES)"
  exit 1
fi
