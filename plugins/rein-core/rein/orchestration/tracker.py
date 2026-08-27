"""Tracker — planned WorkGraph vs 관측된 실행의 대조 기록 (plan Task 5.3, spec §4.4).

spec §4.4 원문 요지: 플랫폼 native 이벤트(작업 생성/완료, 에이전트
시작/종료 4종)로 실제 실행을 관찰하고, tracker 가 **planned WorkGraph
vs actual execution** 을 대조 기록한다 — Prompt 만으로 전부 통제하려
하지 않는다.

이 모듈이 소비하는 이벤트는 kernel 중립 어휘(`task.created`,
`agent.started`, `agent.stopped`, `task.completed` — `rein.kernel.event.
EVENT_TYPES` 의 부분집합)뿐이다. 플랫폼 native hook 이름은
`platform/claude` 경계 밖으로 새지 않는다(spec §3.1) — 이 모듈 소스는
native 이름을 문자열로도 담지 않는다(`tests/contract/
test_kernel_isolation.py` 가 rein/ 트리 전체에서 이를 고정한다). 이
모듈은 `platform.claude.adapter.normalize_event()` 의 출력 형태
(`{"name": ..., "tool": ..., "payload": {...}}`) 를 그대로 소비한다고
가정할 뿐 adapter 를 직접 import 하지 않는다(kernel/orchestration 이
플랫폼을 모르는 격리 원칙, spec §3.1 — Capability 는 서로 직접
의존하지 않는다 원칙과 동형으로 orchestration 도 platform 을 모른다).

## Import 경계 (worker 5.3 exclusive scope)

`orchestration/work_unit.py` / `work_graph.py` 를 import 하지 않는다 —
그 두 모듈은 같은 병렬 웨이브의 다른 작업자가 소유한다. Planned
WorkGraph 는 spec §4.3 이 정의한 WorkUnit **8필드**(`id`/`objective`/
`scope`/`dependencies`/`assigned_agent`/`status`/`expected_output`/
`mode` — `mode`(`edit_only`|`mutating`)는 2026-08-11 spec 정정으로
7필드 밖의 "확장"이 아니라 공식 8번째 필드, 닫힌 집합이다)을 가진
평범한 mapping 의 iterable 로만 받는다 — 필드명 계약이 두 워커가
공유하는 유일한 진실이다(클래스 타입은 공유하지 않는다). `mode` 는
`Tracker` 자신은 참조하지 않지만(스케줄링은 `work_graph.py` 소관),
plain mapping 을 그대로 `dict(raw_unit)` 로 보존하므로 이 필드를
포함해 받아도(WorkGraph.to_planned_units() 의 실제 출력이 그렇다)
거부하지 않는다 — "정확히 이 8필드만 허용" 이 아니라 "필수 2필드
(`id`/`assigned_agent`) 를 갖춘 mapping 이면 나머지는 무엇이든 통과"
가 이 모듈의 실제 계약이다.

## 상관관계(correlation) 설계 — 실제 hook payload 스키마 기준 (2026-08-11 정정)

**2026-08-11 정정 배경**: 이전 버전은 작업 생성/완료 계열(`task.created`/
`task.completed`) 페이로드에 `subagent_type` 필드가 있다고 가정했다
(공식 필드명이 미확정이라는 오해에 근거) — 실측 결과(공식 문서,
2026-08-11 context7 로 원문 JSON 예시 확인) 이 계열의 이벤트는
`task_id`/`task_subject`/`task_description`/`teammate_name`/`team_name`
5필드만 가지며 **agent 이름에 해당하는 필드가 전혀 없다**. `teammate_name`
은 "누가 이 작업을 만들었는가"(작업 **생성자**)이지 배정된 실행자가
아니다 — assigned_agent 로 오용하지 않는다(finding 1c). agent 이름 필드
(`agent_type`)는 서브에이전트 시작/종료 계열(`agent.started`/
`agent.stopped`)에만 실재한다.

결과적으로 이 모듈의 상관관계 신호는 이벤트 계열에 따라 근본적으로
다르다:

- **agent.started/agent.stopped**: `agent_type` 이 실재하는 이름 신호다.
  `_assigned_agent_hint()` 가 이를 읽어 `_claim_planned_unit()` FIFO
  이름 매칭에 쓴다(기존 계약 유지, `agent_id` 를 실행 인스턴스 key 로
  사용).
- **task.created/task.completed**: 이름 신호가 **존재하지 않는다**.
  이름 매칭이 원천적으로 불가능하므로, 아래 3가지 명시적 상관관계
  경로 중 하나로만 planned unit 에 연결된다(우선순위 순):

  1. **`bind_task(unit_id, task_key)`** (공개 API, finding 1b-i) — prompt
     레이어(Orchestrator)가 `TaskCreate` 로 실제 작업을 만든 직후 반환된
     `task_id` 를 특정 WorkUnit 에 명시적으로 묶어 알려준다. 가장 강한
     신호 — 확정적 매칭이며, 바인딩 시점에 즉시 그 unit 을 unclaimed
     풀에서 제거한다.
  2. **`[unit:<id>]` marker** (finding 1b-ii) — `task_subject` 안에
     `[unit:<id>]` 형태의 마커가 있으면(정규식 `_UNIT_MARKER_RE`),
     `<id>` 를 미claim planned unit id 로 시도한다. 명시적 bind 가 없을
     때의 대안 — Orchestrator 가 `TaskCreate` 호출 시 subject 문자열에
     마커를 심어두면 별도 API 호출 없이도 상관관계가 성립한다. **이
     마커는 Task 5.5 Orchestrator Prompt Contract 의 WorkUnit
     직렬화·전달 규약의 일부가 될 전방 참조다** — orchestrator.md 가
     Task 작성 시 이 마커를 관례로 채택하면, 이 모듈은 코드 변경 없이
     그 관례를 소비할 수 있다.
  3. 위 둘 다 없으면 **"unbound"** — `unit_id=None`, `correlation=
     "unbound"` 로 기록한다. 과거 버전은 이런 실행을 "관측됐지만
     계획에 없음"(confident mismatch)으로 단정했으나, 이는 틀렸다 —
     이름 신호 자체가 없어서 판단을 못 한 것이지, 계획과 실제로
     어긋난다고 confident 하게 말할 근거가 없다(finding 1b). 따라서
     `comparison_record()` 의 `mismatches.unplanned_observed` 에서
     제외하고 별도의 `mismatches.unbound_observed` 로 분리해
     노출한다 — "확신 있는 mismatch" 와 "정보 부족으로 판단 불가" 를
     섞지 않는다.

`agent.started`/`agent.stopped` 는 여전히 이름 매칭(`_claim_planned_unit`
FIFO)을 그대로 쓴다 — `agent_type` 은 실재하는 신뢰 가능한 필드이기
때문이다. 이름 매칭 실패(같은 `assigned_agent` 를 가진 미claim planned
unit 이 없음)는 여전히 confident mismatch 로 `unplanned_observed` 에
남는다 — "이름 신호가 있었는데 안 맞음"과 "이름 신호 자체가 없었음"은
다른 확신도를 가진 사실이다.

## unit-keyed 실행 병합 — 두 채널을 하나의 실행으로 (2026-08-11 round-3 구조 수정)

**배경**: round-2 는 task 채널(`bind_task()`/marker)과 agent 채널
(`agent_type` 이름 매칭)을 각각 독립적으로 unit 을 claim 하는 것으로
설계했다 — 그 결과 같은 논리적 작업이 두 채널 모두에서 관측되면(예:
`bind_task()` 로 unit-X 를 예약한 뒤 `task.created` 가 unit-X 를
claim 하고, 나중에 도착한 `agent.started` 가 이미 예약된 unit-X 를
이름 FIFO 로 찾지 못해 별도의 "unplanned" 실행을 만드는 오탐) 두
개의 서로 다른 실행 레코드가 생기거나 거짓 mismatch 가 발생했다.

**round-3 계약**: 일단 어느 채널이든 실행이 특정 `unit_id` 로
상관관계 맺어지면, 그 실행은 그 순간부터 **unit-keyed** 다 — 같은
`unit_id` 로 귀결되는 다른 채널의 이후 관측은 새 실행을 만들지 않고
**항상 기존 실행에 병합**한다(도착 순서 무관, 양방향). 병합된
레코드는 두 채널의 식별자를 모두 보존한다 — `_Execution.task_key`
(task 계열 instance key, 보통 `task_id`) 와 `_Execution.agent_key`
(agent 계열 instance key, `agent_id`) 가 각각 별도 필드로 존재하며
`to_dict()` 에 노출된다. 내부적으로 `self._executions_by_unit_id`
(unit_id → 실행)가 이 병합의 조회 테이블이다.

두 가지 도착 순서 모두 지원한다:

- **(a) bind_task → task.created → agent.started**: bind 가 unit-X 를
  예약하고, `task.created` 가 그 binding 을 찾아 새 실행을 만들며
  (`task_key` 채움) `self._executions_by_unit_id[X]` 에 등록한다.
  나중에 도착한 `agent.started` 의 `agent_type` 이 unit-X 의
  `assigned_agent` 와 일치하면(`_find_open_unit_execution_for_name`),
  새 실행을 만들지 않고 그 실행에 병합해 `agent_key` 를 채운다.
- **(b) agent.started → task.created(bound)**: `agent.started` 가
  먼저 도착했을 때, unit-X 가 이미 `bind_task()` 로 예약(binding 은
  있지만 아직 어떤 채널도 실행을 만들지 않은 상태)돼 있고 이름이
  일치하면(`_bound_unassociated_unit_for_name`), 그 unit 으로 첫
  실행을 만들며 `agent_key` 를 채운다. 나중에 도착한
  `task.created` 는 binding 을 통해 같은 unit 을 찾고, 이미 존재하는
  실행을 발견해 병합하며 `task_key` 를 채운다.

두 경우 모두 결과는 동일하다 — 실행 1개, unit 1회 소비, 거짓
`unplanned_observed` 0건.

**bind_task() 중복 방지(구조 계약 규칙 3)**: 같은 unit 을 서로 다른
`task_key` 에 두 번 바인딩하려 하면(`_unit_bindings` 역방향 조회로
검출) `TrackerError` 로 명시 거부한다 — 조용한 덮어쓰기 금지. 반면
이미 agent 채널로 상관관계 맺어진 unit 에 대한 바인딩은 거부하지
않는다 — 위 병합 계약대로 다음 `task.created` 관측 시 그 실행에
합류할 뿐이다(중복 실행을 만들지 않는다).

**`_attach_by_name()` 은 이 라운드에서 제거됐다** — round-2 는 이
메서드를 "cross-family 이름 매칭, 실제로는 도달 불가"로 유지했으나,
그 메커니즘이 풀려던 문제(서로 다른 채널이 같은 unit 을 가리킬 때
병합)를 위 unit-keyed 설계가 **정확하게**(`assigned_agent` 문자열
비교가 아니라 `unit_id` 신원 자체로) 대체한다. 옛 메서드를 남겨두면
두 메커니즘이 같은 문제를 서로 다른 방식으로 풀려다 충돌할 위험만
남는다.

이 설계의 알려진 한계: WorkUnit id 자체를 관측 payload 로 직접
왕복시키는 계약이 아직 없다(Orchestrator Prompt Contract, 계획서 Task
5.5 소관) — 그 계약이 생기면 `bind_task()`/marker 근사보다 더 정확한
공식 id round-trip 으로 교체할 수 있다.

## 소급 바인딩 + 채널 네임스페이스 키 + payload 검증 (2026-08-11 round-4)

**HIGH — `bind_task()` 소급 바인딩**: 공식 문서상 작업 생성 hook 은
`TaskCreate` 실행 **도중** 발화한다 — 즉 hook 기반 `task.created` 관측이
prompt 레이어가 `task_id` 를 돌려받아 `bind_task()` 를 호출하기 **전에**
이미 도착해 있는 흐름이 실무에서 흔하다(`task.created(task-1) →
bind_task(unit-1, task-1) → task.completed(task-1)` 순서). round-3
까지는 `bind_task()` 가 오직 "앞으로 도착할" 이벤트만 겨냥했다 — 이미
관측돼 `correlation="unbound"` 로 등록된 실행은 조회하지 않았고, 그
결과 위 순서에서 `unit_id=None` 인 채로 남아 `unbound_observed` 에
갇혔다(round-4 HIGH 재현). `bind_task()` 는 이제 호출 시점에
`self._executions_by_key.get(("task", task_key))` 로 이미 관측된 task
채널 실행이 있는지 먼저 확인하고, 있으면(그리고 아직 unbound 라면)
그 실행을 소급 확정한다 — unit_id/correlation 을 채우고, 이미 쌓인
이벤트가 있으면 `_executed_unit_ids` 에도 즉시 반영한다.

**MEDIUM — 채널 네임스페이스 키**: `_executions_by_key` 는 이제
`(family, instance_key)` 튜플로 색인된다("task" 또는 "agent"). 이전에는
raw instance_key 문자열 하나로만 색인해, `task_id` 와 `agent_id` 가
우연히 같은 문자열이면(예: 둘 다 `"abc123"`) 서로 다른 채널의 이벤트가
서로의 실행에 잘못 붙을 위험이 있었다 — `agent_key`/`assigned_agent`
가 유실되거나 엉뚱한 unit 이 소비될 수 있었다. 네임스페이스가 있으면
두 채널의 key 공간이 절대 겹치지 않는다.

**MEDIUM — `payload` falsy 마스킹**: `observe()` 의 `event.get("payload")
or {}` 는 falsy 지만 mapping 이 아닌 값(`False`/`0`/`[]`/`""`/`()`)을
타입 검사가 실행되기도 **전에** `{}` 로 바꿔버려, 잘못된 이벤트를
"빈(유효한) payload" 로 위장시켰다. 지금은 `None`(또는 키 누락) 만
`{}` 로 취급하고, `dict` 는 그대로 통과, 그 외 타입은 이 모듈의
기존 무효-이벤트 처리와 동일한 형태로 명시 거부한다.

## 방어적 타입 검증 (2026-08-11 round-3 MEDIUM)

`_instance_key_hint()`/`_assigned_agent_hint()` 는 payload 필드 값이
비어있지 않은 `str` 인지 검증한다 — 검증 실패(비문자열, 빈 문자열)는
"신호 없음"(`None`)으로 취급한다. adapter.py 가 이미 non-str 식별
필드를 top-level 로 승격하지 않지만(그쪽 finding — MEDIUM), 이 모듈은
adapter 를 신뢰하지 않고 독립적으로 방어한다(모듈 docstring 상단 —
adapter 출력 형태를 "가정"할 뿐 강제하지 않는다) — `instance_key` 는
`self._executions_by_key` 의 dict key 로 직접 쓰이므로, non-str 값이
여기까지 새어 들어오면 `TypeError: unhashable type` 으로 죽는다.

## 영속화 — 로컬 runtime state (spec §2.3)

기록은 Git 으로 동기화하지 않는 로컬 전용 runtime state 다.
`platform.storage.local.LocalStateRoot` 의 범용 `open_log()` 진입점을
그대로 재사용해 `orchestration-tracker.jsonl` 에 append-only, 0600 으로
쓴다(그 모듈을 수정하지 않는다 — 이미 이 목적을 위한 범용 진입점을
제공한다). `project_root` 없이 생성된 tracker 는 메모리 전용으로
동작한다(단위 테스트 등 파일시스템이 필요 없는 호출부를 위함).
"""
import datetime
import json
import re
from collections.abc import Mapping

from rein.platform.storage.local import LocalStateRoot
from rein.shadow import masking

__all__ = [
    "TRACKED_EVENT_NAMES",
    "TRACKER_LOG_FILENAME",
    "WORK_UNIT_ASSIGNED_AGENT_FIELD",
    "WORK_UNIT_ID_FIELD",
    "Tracker",
    "TrackerError",
]

# tracker 가 반응하는 이벤트 4종 — kernel 중립 어휘(spec §4.4). 이 밖의
# 이벤트는 조용히 무시한다(tracker 는 orchestration 관찰에 scope 가
# 한정된다).
TRACKED_EVENT_NAMES = (
    "task.created",
    "agent.started",
    "agent.stopped",
    "task.completed",
)

_LIFECYCLE_BEGIN = frozenset(("task.created", "agent.started"))
_LIFECYCLE_END = frozenset(("task.completed", "agent.stopped"))

# spec §4.3 WorkUnit 필드명 — orchestration/work_unit.py 를 import 하지
# 않고 이 상수로만 계약을 공유한다(모듈 docstring "Import 경계" 절).
WORK_UNIT_ID_FIELD = "id"
WORK_UNIT_ASSIGNED_AGENT_FIELD = "assigned_agent"

TRACKER_LOG_FILENAME = "orchestration-tracker.jsonl"

# round-5 HIGH (round-10 MEDIUM 으로 적용 범위가 degraded.reason/detail
# 두 필드에서 flush() 가 쓰는 전체 레코드로 넓어졌다, 아래
# `_masked_persistable_record()` 참조) — degraded.reason/detail 필드는
# dispatch_env 의 예외 텍스트(예: 프로브/recorder 호출이 던진 예외의
# `str(exc)`)를 그대로 담을 수 있고, planned WorkUnit 의 `objective`/
# `expected_output` 은 애초에 자유 텍스트 필드라 Orchestrator·사용자가
# 실수로 토큰을 붙여넣을 수 있다. 그런 텍스트에 우연히 토큰/자격증명
# 형태 문자열이 섞이면 `flush()` 가 그대로 JSONL 로그 파일에 영구
# 기록한다 — 저장소 보안 규칙("로그에 민감정보 금지", "의심스러우면
# 널리 마스킹") 위반. 길이 상한은 로그 라인이 거대한 자유 텍스트로
# 무한정 커지는 것도 함께 막는다.
_PERSISTED_STRING_MAX_CHARS = 2048
_PERSISTED_STRING_TRUNCATION_MARKER = "...<TRUNCATED>"

# task_subject 안의 명시적 WorkUnit-id 마커 (finding 1b-ii, 모듈 docstring
# "상관관계 설계" 절). `[unit:<id>]` — id 는 공백/']' 를 포함하지 않는
# 문자열. Task 5.5 Orchestrator Prompt Contract 의 WorkUnit 직렬화 규약이
# 이 표기를 채택할 전방 참조 — orchestrator.md 가 TaskCreate 호출 시
# subject 에 이 마커를 심으면, 이 모듈은 코드 변경 없이 그 관례를 그대로
# 소비한다.
_UNIT_MARKER_RE = re.compile(r"\[unit:([^\]\s]+)\]")


class TrackerError(ValueError):
    """Tracker 계약 위반 — planned unit/event 입력이 잘못된 형태."""


def _utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%S"
    )


def _assigned_agent_hint(payload):
    """관측 payload 에서 에이전트 이름을 뽑는다 (모듈 docstring 상관관계 절).

    `agent_type` 만 읽는다 — 서브에이전트 시작/종료 계열(`agent.started`/
    `agent.stopped`) 페이로드에만 실재하는 필드다(2026-08-11 공식
    문서로 확인, finding 1). 과거 버전은 `agent_type` 이 없으면
    `subagent_type` 을 대신 읽었으나, `subagent_type` 은 어떤 채택 hook
    4종의 실제 페이로드에도 존재하지 않는 가상의 필드였다 — 작업
    생성/완료 계열(`task.created`/`task.completed`)은 애초에 agent
    이름에 해당하는 필드를 전혀 갖지 않는다. task 계열 이벤트는 이
    함수가 항상 `None` 을 반환하며, 그 경우의 상관관계는
    `bind_task()`/`[unit:<id>]` marker 가 담당한다(모듈 docstring 참조).

    비어있지 않은 `str` 만 유효한 이름으로 인정한다(round-3 MEDIUM
    방어적 타입 검증, 모듈 docstring 참조) — 다른 타입(리스트 등)이거나
    빈 문자열이면 "이름 신호 없음"(`None`)으로 취급한다.
    """
    value = payload.get("agent_type")
    if isinstance(value, str) and value:
        return value
    return None


def _instance_key_hint(payload):
    """관측 payload 에서 실행 인스턴스 key 를 뽑는다 (모듈 docstring 참조).

    `agent_id`(서브에이전트 시작/종료 계열) 와 `task_id`(작업 생성/완료
    계열) 모두 실재하는 필드다 — 이 둘은 finding 1 정정의 영향을 받지
    않는다.

    비어있지 않은 `str` 만 유효한 key 로 인정한다(round-3 MEDIUM 방어적
    타입 검증) — 이 반환값은 `self._executions_by_key` 의 dict key 로
    직접 쓰이므로, non-str 값(예: 리스트)을 그대로 반환하면 나중에
    `TypeError: unhashable type` 으로 죽는다. 검증 실패는 "instance key
    없음"(`None`, 익명 처리 경로)으로 안전하게 강등한다.
    """
    for key in ("agent_id", "task_id"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _unit_marker_from_subject(task_subject):
    """`task_subject` 에서 `[unit:<id>]` 마커를 추출한다 (finding 1b-ii).

    `task_subject` 가 아니거나(다른 이벤트 계열은 이 필드가 없다) 마커가
    없으면 `None`. 이 함수 자체는 추출한 id 가 실제로 알려진 planned
    unit 인지, 이미 claim 됐는지는 판단하지 않는다 — 그 검증은 호출부
    (`_start_execution`)의 책임이다.
    """
    if not isinstance(task_subject, str):
        return None
    match = _UNIT_MARKER_RE.search(task_subject)
    if not match:
        return None
    return match.group(1)


# round-6 finding 3 — 재귀 순회 깊이 상한. `record_degradation()` 은
# 호출자가 넘긴 Mapping 의 `reason` 키 외 나머지 키·값을 전혀 검증하지
# 않고 그대로 보존한다(자체 docstring 참조) — 즉 임의의 추가 키, 그리고
# 그 값으로 중첩 dict/list 가 원칙적으로 올 수 있다. 실사용 경로
# (`dispatch_env._degrade()` 의 record)는 항상 얕은 평면 dict(모든 값이
# 문자열)이므로 이 깊이에 도달할 일이 없다 — 이 상한은 병적으로 깊은
# 중첩 구조에서도 무한 재귀로 죽지 않기 위한 방어적 안전장치일 뿐이다.
# 사이클(자기 참조 구조)에 대해서도 이 상한이 무한루프를 막는다 —
# 상한 없는 순회는 사이클 검출을 별도로 구현해야 하는데, 실사용
# 경로가 항상 평면 dict 인 현재로서는 그 복잡도가 정당화되지 않는다.
#
# round-9 HIGH 정정: 5 → 6 (`_masked_degradation_fields()`(현재는
# `_masked_persistable_record()`) 가 `degraded` dict **전체**를 이
# walker 에 태우기 시작해, 최상위 dict 자신이 재귀 예산을 1단계
# 소비하게 됐다 — 상수를 1 올려 필드당 실질 중첩 허용치를 유지했다).
#
# round-10 MEDIUM 정정: 6 → 7. 마스킹 적용 범위가 `degraded` 서브트리
# 하나에서 `flush()` 가 실제로 쓰는 **전체 persistable record**(`planned`/
# `observed`/`mismatches`/`degraded`/`recorded_at` 모두)로 넓어졌다 —
# `degraded` 는 이제 그 record 안에 **한 단계 더 중첩된** 필드가 됐다
# (예전: `_masked_persistable_value(degraded, depth=6)` 로 `degraded`
# 자신이 walker 의 최상위였다. 지금: `_masked_persistable_value(record,
# depth=7)` 이 최상위이고, `record["degraded"]` 로 내려가는 재귀 호출이
# `depth=6` 을 받는다 — `degraded` 안쪽(예: `context` 필드)이 받는 예산은
# 그대로 6이다, round-9 시점과 동일). 산수: `record`(1단계 소비) +
# `degraded`(이전과 동일하게 6이 필요) = 7. `planned`/`observed` 서브트리
# (WorkUnit/실행 dict → 필드 값 → 기껏해야 scope/dependencies 리스트
# 안의 문자열, 실측 최대 중첩 3~4단계)는 이 예산에 여유 있게 들어간다 —
# 별도 보정이 필요 없다.
_PERSISTED_VALUE_MAX_DEPTH = 7

# round-7 HIGH — 깊이 상한을 넘긴 컨테이너를 대체하는 고정 placeholder.
# 값 자체가 항상 이 문자열이므로 "masked-by-construction" — 원본 내용을
# 단 한 글자도 포함할 수 없다(round-6 결함: `depth <= 0` 인 컨테이너를
# 그대로 반환해, 그 안의 문자열 리프가 전혀 마스킹되지 않은 채
# 새어나갔다 — 6단계 이상 중첩된 Bearer 토큰으로 재현됨).
_PERSISTED_DEPTH_LIMIT_MARKER = "<DEPTH-LIMIT-REDACTED>"


def _masked_persistable_value(value, depth=_PERSISTED_VALUE_MAX_DEPTH):
    """`flush()` 가 실제로 파일에 쓰는 persistable record 안의 값 하나에
    마스킹 + 길이 상한을 적용한다(round-5~10, 영속화 경계 전용 —
    `flush()` 참조. round-10 이전 이름은 `_masked_degradation_value` —
    당시엔 `degraded` 서브트리에만 적용됐으나, 지금은 record 전체에
    적용되므로 이름을 넓혔다).

    `record_degradation()` 은 `reason`/`detail` 두 알려진 키만 다루는
    게 아니라 호출자가 넘긴 Mapping 의 **모든** 키·값을 그대로 보존한다
    — round-5 는 `reason`/`detail` 두 필드만 마스킹해, 그 외 키(예:
    `context`)에 토큰이 실리면 그대로 새어나갔다(round-6 finding 3).
    round-10 은 여기서 한 걸음 더 나아간다 — planned WorkUnit 의
    `objective`/`expected_output` 은 자유 텍스트 필드라 토큰이 실릴 수
    있는데, round-9 까지는 `flush()` 가 `record["degraded"]` 만
    마스킹하고 `record["planned"]`/`record["observed"]` 는 원본 그대로
    썼다(저장소 보안 규칙 "의심스러우면 널리 마스킹" 위반). 이 함수는
    키 이름을 가리지 않고 값의 **타입**으로 판단한다 — 문자열이면
    마스킹+상한, dict/list 면 재귀, 그 외(숫자·bool·None 등)는 그대로
    통과시킨다. 패턴 기반 마스킹이므로 `unit-1` 같은 평범한 id·status
    값은 어떤 규칙과도 매치하지 않아 그대로 통과한다 — 자격증명
    "형태"의 문자열만 실제로 치환된다.

    - **문자열**: 마스킹을 먼저 적용하고 그 결과를 자른다 — 순서를
      뒤집으면 절단이 비밀 문자열 중간을 잘라 종결자 의존적인 마스킹
      규칙(예: `Bearer <token>` 패턴)을 깨뜨릴 수 있다. 이 순서는
      `rein.shadow.capture.build_redacted_command()` 가 이미 정착시킨
      관례 그대로다. 최종 길이는 마커를 **포함해도** 상한을 넘지
      않는다(round-6 finding 2 — 이전에는 마커를 슬라이스 뒤에
      덧붙여 상한+마커 길이만큼 초과했다).
    - **dict/list/tuple**: 재귀적으로 각 원소에 이 함수를 다시 적용한다.
      깊이 상한(`_PERSISTED_VALUE_MAX_DEPTH`)을 넘으면 더 내려가지
      않는다 — **그러나 원본을 그대로 반환하지 않는다**(round-7 HIGH
      정정. round-6 은 `depth <= 0` 인 컨테이너를 그대로 반환했는데,
      그 안의 문자열 리프가 마스킹을 전혀 거치지 못한 채 그대로
      새어나갔다 — 6단계 이상 중첩된 Bearer 토큰으로 재현됨). 대신
      고정 placeholder(`_PERSISTED_DEPTH_LIMIT_MARKER`)로 그 서브트리
      전체를 치환한다 — 이 값은 상수 문자열이라 "masked-by-construction",
      어떤 경로로도 원본 내용을 단 한 글자도 포함할 수 없다. 상한
      **안쪽**(정확히 상한 깊이까지 중첩된 문자열)은 여전히 정상적으로
      마스킹된다 — 위 문자열 분기가 깊이 값과 무관하게 항상 먼저
      검사되기 때문이다.
    - **그 외 타입(문자열이 아닌 스칼라 — 숫자·bool·None)**: 깊이 상한과
      무관하게 그대로 반환한다(마스킹·상한 대상 아님 — 민감정보가 될
      수 없는 타입).

    **Mapping 의 키도 마스킹한다** (round-8 HIGH 정정). round-7 까지는
    dict 컴프리헨션이 `value` 만 재귀 처리하고 `key` 는 원본 그대로
    썼다 — `record_degradation()` 은 호출자가 넘긴 Mapping 의 키·값
    어느 쪽도 검증하지 않으므로, 자격증명 형태의 문자열이 키 자리에
    오면(`{"Bearer raw-secret-token": "safe"}`) 그대로 새어나갔다.
    키에도 이 함수를 그대로 적용한다 — `record_degradation()` 의
    JSON-safety 입력 검증(round-8 HIGH (b), 그 메서드 docstring 참조)
    이 이미 dict 키를 `str`/`int`/`float`/`bool`/`None` 으로 제한해
    두므로(그 외 타입은 애초에 `json.dumps()` 가 키로 거부한다), 이
    함수 안에서는 키가 컨테이너일 가능성을 걱정할 필요가 없다 — 문자열
    키는 마스킹되고, 그 외(숫자·bool·None) 키는 그대로 통과한다(같은
    "문자열만 마스킹 대상" 규칙이 값과 동일하게 적용될 뿐이다). `planned`/
    `observed`/`mismatches` 쪽 dict 는 이 함수가 아니라 `Tracker`/
    `_Execution` 이 직접 만드므로 키가 항상 알려진 str 리터럴이지만,
    이 함수 자체는 그 사실에 기대지 않는다 — 어떤 Mapping 이 와도 동일
    규칙을 적용한다.

    마스킹 규칙 자체는 이 저장소의 SSOT(`rein.shadow.masking`, v2
    Phase 2 `plan Task 2.6` 에서 확립)를 import 로 그대로 재사용한다 —
    이 함수가 새로 하는 일은 dict/list 순회뿐, 마스킹 규칙을 새로
    구현하지 않는다.
    """
    if isinstance(value, str):
        if not value:
            return value
        masked_value = masking.sanitize(value)
        if len(masked_value) > _PERSISTED_STRING_MAX_CHARS:
            keep = max(
                _PERSISTED_STRING_MAX_CHARS
                - len(_PERSISTED_STRING_TRUNCATION_MARKER),
                0,
            )
            masked_value = (
                masked_value[:keep] + _PERSISTED_STRING_TRUNCATION_MARKER
            )
        return masked_value
    if depth <= 0:
        if isinstance(value, (Mapping, list, tuple)):
            # round-7 HIGH — 컨테이너를 원본 그대로 반환하지 않는다.
            # 그 안에 아직 마스킹되지 않은 문자열 리프가 남아있을 수
            # 있으므로, 통째로 안전한 placeholder 로 치환한다.
            return _PERSISTED_DEPTH_LIMIT_MARKER
        return value
    if isinstance(value, Mapping):
        # round-8 HIGH — key 도 value 와 동일하게 마스킹 대상이다(문자열
        # 키만 실질적으로 변형되고, 그 외 스칼라 키는 이 함수의 str-only
        # 마스킹 분기를 그냥 통과한다). depth 는 감소시키지 않는다 —
        # key 는 value 처럼 "한 단계 더 들어가는" 것이 아니라 같은
        # 레벨의 형제 항목이다(그리고 애초에 컨테이너일 수 없다, 위
        # docstring 참조).
        return {
            _masked_persistable_value(key, depth): _masked_persistable_value(
                val, depth - 1
            )
            for key, val in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [
            _masked_persistable_value(item, depth - 1) for item in value
        ]
    return value


def _masked_persistable_record(record):
    """`flush()` 가 실제로 파일에 쓰는 전체 persistable record 에
    마스킹 + 길이 상한을 적용한 **새** dict 를 반환한다(round-10 MEDIUM
    — 영속화 경계에서만 적용, `flush()` 참조. 원본 `record`/그 값은
    변경하지 않는다 — `flush()` 가 **반환**하는 in-memory 값은 이
    함수의 대상이 아니다).

    **round-10 MEDIUM 정정**: round-9 까지는 이 함수(당시 이름
    `_masked_degradation_fields`)가 `record["degraded"]` 서브트리
    하나만 받아 마스킹했다 — 보안 검토에서, `flush()` 가 쓰는 나머지
    필드(`planned` — WorkUnit 의 자유 텍스트 필드 `objective`/
    `expected_output` 포함, `observed` — `assigned_agent`/`task_key`/
    `agent_key`/`events` 등)는 전혀 마스킹 대상이 아니었다는 지적을
    받았다. 저장소 보안 규칙("의심스러우면 널리 마스킹")에 따라, 지금은
    `record` 전체를 `_masked_persistable_value()` 에 넘긴다 — `degraded`
    뿐 아니라 `planned`/`observed`/`mismatches`/`recorded_at` 모두 같은
    재귀 walker 를 통과한다. 패턴 기반 마스킹이라 `unit-1` 같은 평범한
    id·status 값은 그대로 남고, 자격증명 형태의 문자열만 실제로
    바뀐다 — 정상적인 필드가 손상되지 않는다는 사실은
    `_masked_persistable_value()`의 문서·테스트가 보장한다.

    `record` 자신이 재귀 예산을 1단계 소비하므로(round-9 시점에는
    `degraded` 자신이 최상위였다), `_PERSISTED_VALUE_MAX_DEPTH` 를 1 더
    올려(모듈 상단 상수 정의의 산수 설명 참조) `degraded` 서브트리의
    실질 중첩 허용치를 그대로 유지했다.
    """
    return _masked_persistable_value(record)


class _Execution(object):
    """관측된 실행 1건 — 매칭된 planned unit id(있으면) + 이벤트 이력.

    **unit-keyed 병합** (round-3 구조 계약, 모듈 docstring 참조): 일단
    `unit_id` 가 결정되면 이 실행은 그 unit 의 유일한 대표 레코드다 —
    task 채널과 agent 채널이 같은 unit 으로 귀결되면 새 실행을 만들지
    않고 이 레코드에 병합된다. `task_key`(task 계열 instance key,
    보통 `task_id`) 와 `agent_key`(agent 계열 instance key, `agent_id`)
    는 병합된 두 채널의 식별자를 각각 보존한다 — 한쪽만 관측됐으면
    그쪽만 채워지고 다른 쪽은 `None` 이다.

    `correlation` (finding 1/3, 여러 라운드에 걸쳐 확장된 닫힌 어휘) —
    이 실행의 unit_id 가 "어떻게"(또는 왜 못) 결정됐는지 기록한다.
    기본값은 `None`(이름 신호가 있었는데 FIFO 로 즉시 매칭된 경우 —
    "특별히 설명할 사유가 없는 평범한 경로"). 그 외 값:

    - `"bound"` — `Tracker.bind_task()` 로 명시적 바인딩됨(finding 1b-i).
    - `"unit-marker"` — `task_subject` 의 `[unit:<id>]` 마커로 매칭됨
      (finding 1b-ii).
    - `"unbound"` — unit_id 를 전혀 결정하지 못했고(`unit_id is None`),
      그 이유가 "이름 신호 자체가 없었음"(예: task 계열 이벤트, bind/
      marker 도 없음)일 때(finding 1b). 이름 신호가 있었는데 매칭
      실패한 경우(agent 계열, 미claim 후보 없음)는 `correlation=None`
      으로 남아 confident mismatch 로 취급된다 — "정보가 없어서 모름"
      과 "정보가 있었는데 안 맞음"은 서로 다른 확신도를 갖는다.

    `ambiguous`: 후보가 둘 이상인 상태에서 FIFO 로 하나를 골랐을 때만
    `True` — id round-trip 계약(Task 5.5) 이전까지 이름/바인딩 기반
    최선의 근사이고, 그 근사가 흔들리는 지점을 조용히 숨기지 않는다.

    `_event_ordinals` (round-6 HIGH, 내부 전용 — `to_dict()` 에 노출되지
    않는다): `events` 와 정확히 같은 길이의 병렬 리스트로, 각 이벤트가
    `Tracker.observe()` 에 의해 실제로 관측된 전역 순번(monotonic,
    `Tracker._next_event_ordinal()`)을 담는다. task 채널과 agent 채널이
    독립적으로 각자의 이벤트를 누적하다가 나중에 하나로 병합되는 경우
    (`Tracker._merge_task_execution_into_agent_execution()`), 이 순번이
    있어야 두 실행의 이벤트를 실제 관측 순서대로 정확히 인터리빙할 수
    있다 — 단순히 "실행이 먼저 생성된 쪽의 이벤트를 통째로 앞에 둔다"
    는 근사(round-5)는 두 실행이 서로 번갈아 이벤트를 받은 경우
    (예: task.created → agent.started → agent.stopped → task.completed)
    시간 순서를 깨뜨린다(round-6 finding 1 재현).
    """

    __slots__ = (
        "instance_key",
        "assigned_agent",
        "unit_id",
        "events",
        "correlation",
        "ambiguous",
        "task_key",
        "agent_key",
        "_event_ordinals",
    )

    def __init__(self, instance_key, assigned_agent, unit_id):
        self.instance_key = instance_key
        self.assigned_agent = assigned_agent
        self.unit_id = unit_id
        self.events = []
        self.correlation = None
        self.ambiguous = False
        self.task_key = None
        self.agent_key = None
        self._event_ordinals = []

    @property
    def closed(self):
        """END 계열 이벤트(task.completed/agent.stopped)를 이미 받았는가.

        닫힌 실행은 채널 병합(`_find_open_unit_execution_for_name`)의
        후보에서 제외한다 — 이미 종료된 실행에 새 이벤트를 잘못 붙이지
        않는다.
        """
        return any(name in _LIFECYCLE_END for name in self.events)

    def record_event(self, name, ordinal):
        """이벤트 1건을 전역 관측 순번과 함께 기록한다(round-6 HIGH).
        `events`/`_event_ordinals` 는 반드시 이 메서드로만 함께
        추가한다 — 두 리스트가 길이·인덱스 면에서 어긋나면 병합 시
        순서 복원이 깨진다.
        """
        self.events.append(name)
        self._event_ordinals.append(ordinal)

    def to_dict(self):
        return {
            "unit_id": self.unit_id,
            "assigned_agent": self.assigned_agent,
            "events": list(self.events),
            "started": any(name in _LIFECYCLE_BEGIN for name in self.events),
            "stopped": any(name in _LIFECYCLE_END for name in self.events),
            "correlation": self.correlation,
            "ambiguous": self.ambiguous,
            "task_key": self.task_key,
            "agent_key": self.agent_key,
        }


class Tracker(object):
    """Planned WorkGraph vs 관측 실행 대조 기록기 (spec §4.4, plan Task 5.3).

    생성 시 planned WorkGraph(plain mapping 의 iterable, spec §4.3
    필드명)를 받고, 이후 `observe()` 로 정규화된 내부 이벤트를 하나씩
    반영한다. `comparison_record()` 가 현재까지의 대조 결과를 순수
    계산해 반환하고, `flush()` 가 그 결과를 로컬 runtime state 에
    append 한다.
    """

    def __init__(self, work_graph=(), project_root=None, clock=None):
        self._planned = []
        self._planned_by_id = {}
        for raw_unit in work_graph:
            if not isinstance(raw_unit, dict):
                raise TrackerError(
                    "planned work unit must be a mapping (spec §4.3 "
                    "WorkUnit field names), got {!r}".format(raw_unit)
                )
            unit_id = raw_unit.get(WORK_UNIT_ID_FIELD)
            if not isinstance(unit_id, str) or not unit_id:
                raise TrackerError(
                    "planned work unit must have a non-empty string "
                    "{!r} field, got {!r}".format(
                        WORK_UNIT_ID_FIELD, raw_unit
                    )
                )
            if unit_id in self._planned_by_id:
                raise TrackerError(
                    "duplicate planned work unit id {!r} — WorkGraph "
                    "unit ids must be unique".format(unit_id)
                )
            unit = dict(raw_unit)
            self._planned.append(unit)
            self._planned_by_id[unit_id] = unit

        # FIFO claim 대기열 — WorkGraph 원래 순서를 유지한다(dict 는
        # Python 3.7+ 에서 삽입 순서를 보존한다).
        self._unclaimed_ids = list(self._planned_by_id)
        self._executions = []
        self._executions_by_key = {}
        # unit-keyed 병합 조회 테이블 (round-3 구조 계약) — unit_id 가
        # 결정된 모든 실행이 채널과 무관하게 여기 등록된다. 새 이벤트가
        # 같은 unit_id 로 귀결되면 이 테이블에서 기존 실행을 찾아
        # 병합한다(새 실행을 만들지 않는다).
        self._executions_by_unit_id = {}
        self._executed_unit_ids = set()
        # 명시적 WorkUnit-id 바인딩 (finding 1b-i) — instance_key(대개
        # task_id) → unit_id. `bind_task()` 로만 채워진다.
        self._task_bindings = {}
        # 역방향 바인딩 조회 (round-3 구조 계약 규칙 3) — unit_id →
        # task_key. 같은 unit 을 서로 다른 task_key 에 중복 바인딩하는
        # 시도를 검출한다(조용한 덮어쓰기 금지).
        self._unit_bindings = {}
        self._anon_counter = 0
        # 전역 이벤트 관측 순번 (round-6 HIGH) — `observe()` 가 반영하는
        # 모든 이벤트에 monotonic 하게 매겨진다. task/agent 두 채널이
        # 독립적으로 이벤트를 누적하다 나중에 병합될 때
        # (`_merge_task_execution_into_agent_execution`), 이 순번으로
        # 실제 관측 순서를 정확히 복원한다 — `self._executions` 등록
        # 순서(어느 실행이 먼저 "생성"됐는가)만으로는 두 실행이 서로
        # 번갈아 이벤트를 받은 경우의 참 시간순을 재구성할 수 없다.
        self._event_seq = 0
        self._degraded = None
        self._project_root = project_root
        self._clock = clock or _utc_now_iso

    def _next_event_ordinal(self):
        ordinal = self._event_seq
        self._event_seq += 1
        return ordinal

    # -- 관측 -----------------------------------------------------------

    def observe(self, event):
        """정규화된 내부 이벤트 1건을 반영한다.

        `event` 는 `platform.claude.adapter.normalize_event()` 의 출력
        형태(`{"name": ..., "tool": ..., "payload": {...}}`)를
        기대한다. `TRACKED_EVENT_NAMES` 밖의 이벤트는 조용히 무시하고
        `None` 을 반환한다 — 이 tracker 는 orchestration 관찰에 scope
        가 한정된다(spec §4.4). 반영된 이벤트는 그 실행의 현재 상태
        dict 를 반환한다.
        """
        if not isinstance(event, dict) or "name" not in event:
            raise TrackerError(
                "event must be a mapping with a 'name' key (expects "
                "adapter.normalize_event() 출력 형태), got {!r}".format(
                    event
                )
            )
        name = event["name"]
        if name not in TRACKED_EVENT_NAMES:
            return None

        # round-4 MEDIUM: `event.get("payload") or {}` let a falsy
        # non-mapping (False/0/[]/""/()) silently become {} *before* the
        # type check ran, so the check never saw the bad value — masking
        # a malformed event as an empty (valid) payload. Explicit chain:
        # None (or missing key) -> {}, dict -> itself, anything else ->
        # structured rejection (same TrackerError shape the rest of this
        # module already uses for invalid-event handling).
        raw_payload = event.get("payload")
        if raw_payload is None:
            payload = {}
        elif isinstance(raw_payload, dict):
            payload = raw_payload
        else:
            raise TrackerError(
                "event['payload'] must be a mapping, got {!r}".format(
                    raw_payload
                )
            )

        instance_key = _instance_key_hint(payload)
        agent_name = _assigned_agent_hint(payload)
        unit_marker = _unit_marker_from_subject(payload.get("task_subject"))
        family = name.split(".", 1)[0]  # "task" | "agent"

        # round-4 MEDIUM: keyed by (family, instance_key), not just
        # instance_key — a task_id and an agent_id can collide as raw
        # strings (e.g. both happen to be "abc123"). Without the channel
        # in the key, an agent event would attach to a task execution (or
        # vice versa) purely on string coincidence, silently discarding
        # the correct channel's agent_key/assigned_agent and potentially
        # mis-consuming a different unit than either channel intended.
        execution = None
        if instance_key is not None:
            execution = self._executions_by_key.get((family, instance_key))

        if execution is None:
            if family == "task":
                execution = self._correlate_task_event(instance_key, unit_marker)
            else:
                execution = self._correlate_agent_event(instance_key, agent_name)

        execution.record_event(name, self._next_event_ordinal())
        if execution.unit_id is not None:
            self._executed_unit_ids.add(execution.unit_id)
        return execution.to_dict()

    # -- unit-keyed 상관관계 (round-3 구조 계약) --------------------------

    def _correlate_task_event(self, instance_key, unit_marker):
        """task 채널 상관관계 — unit_id 결정 우선순위(finding 1b): (1)
        `bind_task()` 바인딩, (2) `[unit:<id>]` marker. 결정된 unit_id 가
        이미 agent 채널 실행을 갖고 있으면(구조 계약 규칙 1, "agent.
        started 가 먼저 도착" 순서) 새 실행을 만들지 않고 그 실행에
        병합한다 — `task_key` 를 채운다. 아무 것도 결정하지 못하면
        `correlation="unbound"` 로 명시 표시한다(모듈 docstring
        "unit-keyed 실행 병합" 절 — confident mismatch 와 구분).
        """
        unit_id = None
        correlation = None
        if instance_key is not None and instance_key in self._task_bindings:
            unit_id = self._task_bindings[instance_key]
            correlation = "bound"
        elif unit_marker is not None and unit_marker in self._planned_by_id:
            existing_for_marker = self._executions_by_unit_id.get(unit_marker)
            if existing_for_marker is not None:
                # 이미 다른 task_key 로 task 채널이 확정돼 있으면 이
                # 마커는 충돌을 피해 무시한다(unbound 로 떨어진다).
                # agent 채널만 있고 task_key 가 비어있으면 병합 대상.
                if existing_for_marker.task_key is None:
                    unit_id = unit_marker
                    correlation = "unit-marker"
            elif unit_marker in self._unclaimed_ids:
                unit_id = unit_marker
                correlation = "unit-marker"

        if unit_id is None:
            execution = _Execution(instance_key, None, None)
            execution.correlation = "unbound"
            execution.task_key = instance_key
            self._register_new_execution("task", instance_key, execution)
            return execution

        existing = self._executions_by_unit_id.get(unit_id)
        if existing is not None:
            # 구조 계약 규칙 1 — agent 채널이 먼저 이 unit 으로 실행을
            # 열어뒀다. 새 실행을 만들지 않고 병합한다.
            if existing.task_key is not None and existing.task_key != instance_key:
                # 서로 다른 task_key 두 개가 같은 unit 을 가리키는
                # 충돌 — 조용히 덮어쓰지 않고 ambiguous 로 표시한다.
                existing.ambiguous = True
            else:
                existing.task_key = instance_key
            if instance_key is not None:
                self._executions_by_key[("task", instance_key)] = existing
            return existing

        execution = _Execution(instance_key, None, unit_id)
        execution.correlation = correlation
        execution.task_key = instance_key
        if unit_id in self._unclaimed_ids:
            self._unclaimed_ids.remove(unit_id)
        self._executions_by_unit_id[unit_id] = execution
        self._register_new_execution("task", instance_key, execution)
        return execution

    def _correlate_agent_event(self, instance_key, agent_name):
        """agent 채널 상관관계 — 우선순위: (1) 이미 task 채널로 열려
        있고(`agent_key` 미설정) 이름이 일치하는 실행에 병합(구조 계약
        규칙 1, "task.created 가 먼저 도착" 순서), (2) 기존 이름 기반
        FIFO(`_claim_planned_unit`) 로 **아직 어떤 channel 도 건드리지
        않은 순수 unclaimed** unit 을 claim 한다, (3) 위 둘 다 없으면
        `bind_task()` 로 예약만 되고 아직 실행이 없는 unit 에 첫 실행을
        연다(구조 계약 규칙 1, "agent.started 가 먼저 도착" 순서).

        (2) 를 (3) 보다 먼저 시도하는 순서가 중요하다 — 이름이 같은 두
        unit 중 하나가 이미 `bind_task()` 로 특정 task 에 예약돼 있고
        다른 하나는 순수 미claim 이면, 이름만 같을 뿐 그 bind 와 무관한
        agent.started 가 예약된 unit 을 가로채지 않고 자유로운 unit 을
        먼저 가져가야 한다 — 예약은 "이 이름을 가진 아무 실행에나
        붙어도 된다"는 뜻이 아니라 "이 특정 task 와 짝지어질 unit"이라는
        더 좁은 신호다. `_bound_unassociated_unit_for_name` 은 그 이름을
        가진 순수 unclaimed 후보가 하나도 없을 때만(즉 이 agent.started
        가 그 예약 외에는 달리 갈 곳이 없을 때) 예약된 unit 에 합류한다.
        """
        existing = self._find_open_unit_execution_for_name(agent_name)
        if existing is not None:
            if existing.agent_key is not None and existing.agent_key != instance_key:
                existing.ambiguous = True
            else:
                existing.agent_key = instance_key
            if existing.assigned_agent is None:
                existing.assigned_agent = agent_name
            if instance_key is not None:
                self._executions_by_key[("agent", instance_key)] = existing
            return existing

        unit_id = self._claim_planned_unit(agent_name)
        if unit_id is not None:
            execution = _Execution(instance_key, agent_name, unit_id)
            execution.agent_key = instance_key
            self._executions_by_unit_id[unit_id] = execution
            self._register_new_execution("agent", instance_key, execution)
            return execution

        bound_unit_id, ambiguous = self._bound_unassociated_unit_for_name(agent_name)
        if bound_unit_id is not None:
            execution = _Execution(instance_key, agent_name, bound_unit_id)
            execution.correlation = "bound"
            execution.agent_key = instance_key
            execution.ambiguous = ambiguous
            self._executions_by_unit_id[bound_unit_id] = execution
            self._register_new_execution("agent", instance_key, execution)
            return execution

        execution = _Execution(instance_key, agent_name, None)
        execution.agent_key = instance_key
        self._register_new_execution("agent", instance_key, execution)
        return execution

    def _find_open_unit_execution_for_name(self, agent_name):
        """이미 `unit_id` 를 가진(채널 무관) 실행 중, `agent_key` 가 아직
        없고 닫히지 않았으며 그 unit 의 `assigned_agent` 가 `agent_name`
        과 일치하는 것을 찾는다(구조 계약 규칙 1 — 채널 병합). 후보가
        둘 이상이면 `self._executions` 순서(관측 순서) 로 가장 먼저
        생긴 것을 고르고 ambiguous 로 표시한다.
        """
        if not agent_name:
            return None
        candidates = [
            execution
            for execution in self._executions
            if execution.unit_id is not None
            and execution.agent_key is None
            and not execution.closed
            and self._planned_by_id.get(execution.unit_id, {}).get(
                WORK_UNIT_ASSIGNED_AGENT_FIELD
            )
            == agent_name
        ]
        if not candidates:
            return None
        chosen = candidates[0]
        if len(candidates) > 1:
            chosen.ambiguous = True
        return chosen

    def _bound_unassociated_unit_for_name(self, agent_name):
        """`bind_task()` 로 예약됐지만 아직 어떤 채널로도 실행이 생성되지
        않은 unit 중 `assigned_agent` 가 `agent_name` 과 일치하는 것을
        찾는다(구조 계약 규칙 1, "agent.started 가 task.created(bound)
        보다 먼저 도착" 순서). WorkGraph 선언 순서로 결정적이다.

        반환: `(unit_id 또는 None, ambiguous bool)`.
        """
        if not agent_name:
            return None, False
        candidates = [
            unit[WORK_UNIT_ID_FIELD]
            for unit in self._planned
            if unit[WORK_UNIT_ID_FIELD] in self._unit_bindings
            and unit[WORK_UNIT_ID_FIELD] not in self._executions_by_unit_id
            and unit.get(WORK_UNIT_ASSIGNED_AGENT_FIELD) == agent_name
        ]
        if not candidates:
            return None, False
        return candidates[0], len(candidates) > 1

    def _register_new_execution(self, family, instance_key, execution):
        """새 실행을 `_executions`/`_executions_by_key` 에 등록한다.
        `instance_key` 가 없으면(관측 payload 에 유효한 key 가 전혀
        없었던 경우) 서로 다른 익명 실행을 하나로 뭉치지 않도록 합성
        key 를 발급한다. `_executions_by_key` 는 `(family, key)` 튜플로
        네임스페이스된다(round-4 MEDIUM) — `family` 는 항상 호출부가
        알고 있는 값("task"/"agent")을 그대로 넘긴다.
        """
        key = instance_key
        if key is None:
            self._anon_counter += 1
            key = "anon-{}".format(self._anon_counter)
            execution.instance_key = key
        self._executions_by_key[(family, key)] = execution
        self._executions.append(execution)

    def _claim_planned_unit(self, agent_name):
        if not agent_name:
            return None
        for unit_id in self._unclaimed_ids:
            unit = self._planned_by_id[unit_id]
            if unit.get(WORK_UNIT_ASSIGNED_AGENT_FIELD) == agent_name:
                self._unclaimed_ids.remove(unit_id)
                return unit_id
        return None

    # -- 명시적 WorkUnit-id 바인딩 (finding 1b-i) -------------------------

    def bind_task(self, unit_id, task_key):
        """prompt 레이어(Orchestrator)가 `TaskCreate` 로 실제 작업을
        만든 직후, 반환된 task id 를 이 WorkUnit 에 묶어 명시적으로
        알려주는 공개 진입점이다(finding 1b-i — task 계열 이벤트는
        `agent_type` 같은 이름 신호가 없어 이름 기반 FIFO 로 절대
        매칭될 수 없다, 모듈 docstring "상관관계 설계" 절).

        `task_key` 는 이후 `observe()` 가 받을 이벤트에서
        `_instance_key_hint()` 가 뽑아낼 값과 정확히 같아야 한다(보통
        task 계열이므로 `task_id`). 바인딩 즉시 해당 unit 을 이름 기반
        FIFO(`_claim_planned_unit`)의 unclaimed 후보 풀에서 제거한다 —
        아직 이 task 의 관측 이벤트가 도착하지 않았더라도, 다른 이름
        매칭이 먼저 이 unit 을 가로채지 않도록 예약한다.

        `unit_id` 가 이 Tracker 가 아는 planned unit 이 아니거나,
        `task_key` 가 이미 바인딩돼 있거나, `unit_id` 가 이미 **다른**
        `task_key` 에 바인딩돼 있으면(구조 계약 규칙 3, round-3) 조용한
        덮어쓰기 대신 `TrackerError` 로 명시 거부한다. 반대로 `unit_id`
        가 이미 agent 채널로 상관관계 맺어져 있는 것(바인딩이 아니라
        관측된 실행)은 거부하지 않는다 — 모듈 docstring "unit-keyed
        실행 병합" 절대로 다음 관측이 그 실행에 합류할 뿐, 중복을
        만들지 않는다.

        **소급 바인딩 (round-4 HIGH)**: 공식 문서상 실제 흐름은
        `TaskCreate` 실행 **도중** hook 이 발화한다 — 즉 hook 기반
        `task.created` 관측이 prompt 레이어가 `task_id` 를 돌려받아 이
        메서드를 호출하기 **전에** 이미 도착해 있는 경우가 흔하다. 이미
        관측돼(그때는 correlation="unbound" 로) 등록된 task 채널 실행이
        있으면, 이 호출이 그 실행을 소급 확정한다 — unit_id/correlation
        을 채우고, 이미 쌓인 이벤트가 있으면 `_executed_unit_ids` 에도
        즉시 반영한다(그 이벤트들은 실제로 이 unit 에 대한 실행이었다).
        그 실행이 이미 **다른** unit_id 로 확정돼 있으면(예: 그 사이에
        `[unit:<id>]` marker 로 먼저 해소됨) 충돌이므로 명시 거부한다.

        **소급 바인딩 + 기존 agent-채널 실행 병합 (round-5 HIGH)**: 위
        소급 바인딩 시나리오에서, `task.created` 뿐 아니라 `agent.
        started` 도 bind 이전에 먼저 도착해 있었을 수 있다(예:
        `task.created(task-t) → agent.started(agent-a, 이름으로 unit-u
        FIFO 매칭) → bind_task(unit-u, task-t)`). 이 경우 `unit-u` 는
        이미 agent-채널 실행이 `self._executions_by_unit_id` 에 등록해둔
        상태다 — 단순히 task-채널 실행에 `unit_id` 를 부여하고
        `_executions_by_unit_id[unit_id]` 를 덮어쓰면, agent-채널 실행이
        색인에서만 유실될 뿐 `self._executions` 목록에는 그대로 남아
        **같은 unit 에 대한 실행 레코드가 2개** 가 되는 결함이 있었다.
        지금은 그 대신 `_merge_task_execution_into_agent_execution()`
        으로 두 실행을 하나로 합친다 — task-채널 실행은 모든 색인/목록
        (`_executions`, `_executions_by_key`, 그리고 `unit_id is None`
        조건으로 계산되는 unbound 버킷 — 이 목록에서 빠지는 것만으로
        자동 해소된다)에서 제거되고, agent-채널 실행이 유일하게
        살아남아 두 채널의 식별자(`task_key`/`agent_key`)와 이벤트
        이력을 모두 보존한다. "unit 하나 = 실행 하나" 는 세 액션(`bind_
        task`/`task.created`/`agent.started`)의 어떤 도착 순서에서도
        성립한다.
        """
        if not isinstance(unit_id, str) or unit_id not in self._planned_by_id:
            raise TrackerError(
                "bind_task unit_id must reference a known planned unit "
                "id, got {!r}".format(unit_id)
            )
        if not isinstance(task_key, str) or not task_key:
            raise TrackerError(
                "bind_task task_key must be a non-empty str, got "
                "{!r}".format(task_key)
            )
        if task_key in self._task_bindings:
            raise TrackerError(
                "task_key {!r} is already bound to unit {!r}".format(
                    task_key, self._task_bindings[task_key]
                )
            )
        existing_task_key = self._unit_bindings.get(unit_id)
        if existing_task_key is not None and existing_task_key != task_key:
            raise TrackerError(
                "unit {!r} is already bound to task_key {!r} — refusing "
                "to also bind it to {!r} (no silent overwrite, round-3 "
                "structural contract rule 3)".format(
                    unit_id, existing_task_key, task_key
                )
            )

        # round-4 HIGH — 소급 바인딩: 이미 관측된(그러나 그때는 unbound
        # 였던) task 채널 실행을 지금 확정한다. `(family, key)` 네임스페
        # 이스(round-4 MEDIUM, `_register_new_execution` 참조)를 그대로
        # 써서 조회한다.
        existing_execution = self._executions_by_key.get(("task", task_key))
        if existing_execution is not None:
            if existing_execution.unit_id is None:
                # round-5 HIGH — 새 unit_id 를 부여하기 전에, 이 unit 을
                # agent 채널이 이미 선점했는지(다른 실행 객체로) 먼저
                # 확인한다. 확인 없이 그냥 덮어쓰면 실행이 중복된다.
                agent_side_execution = self._executions_by_unit_id.get(unit_id)
                if (
                    agent_side_execution is not None
                    and agent_side_execution is not existing_execution
                ):
                    self._merge_task_execution_into_agent_execution(
                        task_execution=existing_execution,
                        agent_execution=agent_side_execution,
                        task_key=task_key,
                    )
                else:
                    existing_execution.unit_id = unit_id
                    existing_execution.correlation = "bound"
                    self._executions_by_unit_id[unit_id] = existing_execution
                    if existing_execution.events:
                        # 이미 관측된 이벤트들은 실제로 이 unit 에 대한
                        # 실행이었다 — 소급 확정 시점에 즉시 반영한다.
                        self._executed_unit_ids.add(unit_id)
            elif existing_execution.unit_id != unit_id:
                raise TrackerError(
                    "task_key {!r} already correlates to unit {!r} (e.g. "
                    "via a [unit:<id>] marker observed before this "
                    "bind_task() call) — cannot also bind it to {!r} (no "
                    "silent overwrite)".format(
                        task_key, existing_execution.unit_id, unit_id
                    )
                )
            # else: existing_execution.unit_id == unit_id — 이미 같은
            # unit 으로 확정돼 있다. idempotent, 추가 조치 불필요.

        self._task_bindings[task_key] = unit_id
        self._unit_bindings[unit_id] = task_key
        if unit_id in self._unclaimed_ids:
            self._unclaimed_ids.remove(unit_id)

    def _merge_task_execution_into_agent_execution(
        self, task_execution, agent_execution, task_key
    ):
        """소급 바인딩이 이미 agent 채널 실행을 가진 unit 을 가리킬 때
        (round-5 HIGH) `task_execution` 을 `agent_execution` 에 병합하고
        `task_execution` 자체를 모든 색인/목록에서 제거한다 —
        `agent_execution` 이 유일하게 살아남는 레코드다.

        **이벤트 순서 (round-6 HIGH 정정)**: round-5 는 "실행이 먼저
        생성된 쪽의 이벤트를 통째로 앞에 둔다"(`self._executions` 등록
        순서 기준 연결)는 근사를 썼다 — 두 실행이 서로 **번갈아**
        이벤트를 받은 경우(예: `task.created → agent.started →
        agent.stopped → task.completed → bind`) 이 근사는 실제 순서
        (`task.created, agent.started, agent.stopped, task.completed`)
        를 `task.created, task.completed, agent.started, agent.stopped`
        로 뒤섞었다(재현: round-6 finding 1). 지금은 각 이벤트에 매겨진
        전역 관측 순번(`_Execution._event_ordinals`,
        `Tracker._next_event_ordinal()`)으로 두 실행의 이벤트를 정확히
        병합 정렬한다 — 어느 실행이 먼저 "생성"됐는지와 무관하게 항상
        참 시간순이 복원된다.
        """
        combined = sorted(
            zip(
                list(task_execution.events) + list(agent_execution.events),
                list(task_execution._event_ordinals)
                + list(agent_execution._event_ordinals),
            ),
            key=lambda pair: pair[1],
        )
        agent_execution.events = [name for name, _ordinal in combined]
        agent_execution._event_ordinals = [
            ordinal for _name, ordinal in combined
        ]

        # task_key 병합 — 충돌(이미 다른 task_key 로 확정돼 있음)이면
        # 조용히 덮어쓰지 않고 ambiguous 로 표시한다(기존 병합 규약과
        # 동형 — `_correlate_task_event`/`_correlate_agent_event` 참조).
        if (
            agent_execution.task_key is not None
            and agent_execution.task_key != task_key
        ):
            agent_execution.ambiguous = True
        else:
            agent_execution.task_key = task_key

        if agent_execution.unit_id is not None and task_execution.events:
            self._executed_unit_ids.add(agent_execution.unit_id)

        # task_execution 자체를 모든 색인/목록에서 제거한다 — 살아남는
        # 레코드는 agent_execution 하나뿐이다. `self._executions` 에서
        # 빠지는 순간 comparison_record() 의 unbound/unplanned 버킷
        # 계산(리스트 컴프리헨션, 매 호출 새로 계산)에서도 자동으로
        # 사라진다 — 별도의 "unbound 버킷" 저장소는 없다.
        self._executions_by_key[("task", task_key)] = agent_execution
        if task_execution in self._executions:
            self._executions.remove(task_execution)

    # -- 강등 사유 (Task 5.4 가 채우는 공개 진입점) -----------------------

    def record_degradation(self, reason):
        """강등 사유를 기록한다 — Task 5.4(감지·강등) 모듈이 호출하는
        공개 진입점이다(계획서 Task 5.4 "tracker degraded 필드"). 이
        모듈은 감지·강등 로직 자체를 구현하지 않는다 — 사유를 받아
        기록만 한다. 마지막 호출이 최종값이다(강등은 세션당 1개의
        최종 상태를 나타낸다).

        `reason` 은 둘 중 하나다(finding 1, F2 fix review):

        - 비어있지 않은 `str` — 원래 계약. 그대로 `{"reason": reason}`
          으로 저장한다.
        - `"reason"` 키(비어있지 않은 str)를 포함한 Mapping —
          `dispatch_env.DispatchEnvironment._degrade()` 가 만드는 record
          형태(`{"reason":..., "detail":..., "state":..., "mode":...,
          "notice":...}`)를 그대로 받아들이기 위한 것이다. 이 형태를
          받아야 `DispatchEnvironment(recorder=tracker.record_degradation)`
          가 예외 없이 직접 조립된다 — 그 전에는 dispatch_env 가 dict 를
          넘기는데 이 메서드가 str 만 받아 TrackerError 로 깨졌다. 두
          입력 형태 모두 저장 shape 는 항상 dict 이고 `"reason"`/
          `"recorded_at"` 두 키는 항상 존재한다(Mapping 입력은 나머지
          키도 함께 보존한다).

        **JSON-safety 는 여기서 검증한다 (round-8 HIGH (b))**: Mapping
        입력의 값(또는 키)에 `json.dumps()` 가 직렬화할 수 없는 것(예:
        임의의 객체 인스턴스)이 섞이면, 이 메서드 호출 시점에 즉시
        `TrackerError` 로 거부한다 — round-7 까지는 이 검증이 없어서
        `flush()` 가 실제로 파일에 쓰려는 순간에야 처리되지 않은
        `TypeError` 로 죽었다(호출부에서 멀리 떨어진, 예측하기 어려운
        실패 지점). 이 검증을 통과하면 이후 어떤 값도 dict/list/str/
        int/float/bool/None 뿐임이 보장되므로, `_masked_degradation_
        value()` 의 재귀 순회(모듈 상단 참조)도 안전하게 그 타입
        가정 위에서 동작한다(예: dict 키가 컨테이너일 수 없다는 전제).
        """
        if isinstance(reason, str):
            if not reason:
                raise TrackerError(
                    "degradation reason must be a non-empty str, got "
                    "{!r}".format(reason)
                )
            payload = {"reason": reason}
        elif isinstance(reason, Mapping):
            candidate = reason.get("reason")
            if not isinstance(candidate, str) or not candidate:
                raise TrackerError(
                    "degradation reason mapping must have a non-empty "
                    "str 'reason' key, got {!r}".format(reason)
                )
            payload = dict(reason)
        else:
            raise TrackerError(
                "degradation reason must be a non-empty str or a mapping "
                "with a 'reason' key, got {!r}".format(reason)
            )
        payload["recorded_at"] = self._clock()

        try:
            # `sort_keys=True` matters here, not just serializability —
            # `flush()` calls `json.dumps(..., sort_keys=True)`
            # (finding 5, F2 fix review), and a dict with mutually
            # incomparable key types (e.g. `int` mixed with `None`) is
            # plain-serializable but still raises `TypeError` under
            # `sort_keys=True` specifically. Matching flush()'s exact
            # call here is what makes this check a real guarantee —
            # checking plain `json.dumps()` alone would still let that
            # narrower failure slip through to flush() (round-8 HIGH
            # (b): "never deferred to flush()").
            json.dumps(payload, sort_keys=True)
        except (TypeError, ValueError) as exc:
            raise TrackerError(
                "degradation reason mapping must be JSON-serializable — "
                "{}".format(exc)
            ) from exc

        self._degraded = payload
        return dict(self._degraded)

    @property
    def degraded(self):
        return dict(self._degraded) if self._degraded is not None else None

    # -- 대조 레코드 ------------------------------------------------------

    def comparison_record(self):
        """현재까지의 planned vs actual 대조 레코드 (순수 계산, 비영속).

        `mismatches.unplanned_observed` 는 **confident** mismatch 만
        담는다 — 이름 신호가 있었는데 매칭에 실패한 실행(finding 1b).
        이름 신호 자체가 없어 애초에 판단할 근거가 없었던 실행
        (`correlation == "unbound"`, 전형적으로 bind/marker 없는 task
        계열 이벤트)은 여기서 제외하고 `mismatches.unbound_observed` 로
        따로 노출한다 — "계획과 어긋남을 확신함" 과 "정보 부족으로 모름"
        을 같은 버킷에 섞으면 오탐(false mismatch)이 된다.
        """
        planned_unexecuted = [
            unit_id
            for unit_id in self._planned_by_id
            if unit_id not in self._executed_unit_ids
        ]
        unplanned_observed = [
            execution.to_dict()
            for execution in self._executions
            if execution.unit_id is None and execution.correlation != "unbound"
        ]
        unbound_observed = [
            execution.to_dict()
            for execution in self._executions
            if execution.unit_id is None and execution.correlation == "unbound"
        ]
        return {
            "planned": [dict(unit) for unit in self._planned],
            "observed": [
                execution.to_dict() for execution in self._executions
            ],
            "mismatches": {
                "planned_unexecuted": planned_unexecuted,
                "unplanned_observed": unplanned_observed,
                "unbound_observed": unbound_observed,
            },
            "degraded": self.degraded,
            "recorded_at": self._clock(),
        }

    def flush(self):
        """현재 대조 레코드를 로컬 runtime state 에 1줄(JSONL) append 한다.

        `project_root` 없이 생성된 tracker 는 메모리 전용이다 — 파일
        시스템에 아무것도 쓰지 않고 레코드만 반환한다.

        JSON 본문과 개행을 하나의 문자열로 합쳐 `write()` 를 정확히
        한 번만 호출한다(finding 5, F2 fix review) — 이전에는 본문/개행을
        별도의 두 `write()` 호출로 나눠서, 같은 로그 파일에 동시에
        append 하는 다른 hook 프로세스의 쓰기와 인터리빙될 위험이
        있었다(두 write 사이에 다른 프로세스의 write 가 끼어들면 JSONL
        한 줄이 깨진다).

        **영속화 경계 마스킹 (round-5~10 HIGH/MEDIUM)**: 실제로 파일에
        쓰는 바이트만 마스킹 + 길이 상한 처리한다 — 이 메서드가
        **반환**하는 `record`(호출자가 in-memory 로 받는 값)는 원본
        그대로다. dispatch_env 쪽에서 detail 을 미리 다듬어 넘길 수도
        있지만(보조적 조치), 이 지점이 **보장된 최종 관문**이다 — 파일에
        쓰는 모든 경로가 반드시 이 메서드를 거치기 때문이다.

        **round-10 MEDIUM 정정**: round-9 까지는 `record["degraded"]`
        서브트리만 마스킹했다 — `record["planned"]`(WorkUnit 의 자유
        텍스트 필드 `objective`/`expected_output` 포함)와
        `record["observed"]`(`assigned_agent`/`task_key`/`agent_key`
        등)는 원본 그대로 썼다. 보안 검토 지적에 따라 이제
        `_masked_persistable_record(record)` 로 **record 전체**를
        마스킹한다 — 저장소 보안 규칙 "의심스러우면 널리 마스킹" 을
        따른다. 마스킹은 패턴 기반이라(SSOT `rein.shadow.masking`)
        `unit-1` 같은 평범한 id/status/mode 값은 어떤 규칙과도 매치하지
        않아 그대로 통과한다.
        """
        record = self.comparison_record()
        if self._project_root is None:
            return record
        root = LocalStateRoot(self._project_root)
        persistable = _masked_persistable_record(record)
        line = json.dumps(persistable, sort_keys=True) + "\n"
        with root.open_log(TRACKER_LOG_FILENAME) as handle:
            handle.write(line)
        return record
