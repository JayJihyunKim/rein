"""Claude Native Hook 이름 ↔ 내부 이벤트·native 응답 변환.

kernel/engine 은 Claude 심볼을 import 하지 않는다 — Hook 이름과 native
응답 형태는 이 모듈 경계 안에서만 존재한다 (spec §3.1). Stop 강등
(spec §2.4) 도 이 경계 소유다: engine 출력은 ASK_USER 를 유지하고,
native 응답만 BLOCK + 안내로 변환된다.
"""
from rein.kernel.decision import (
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
    DECISIONS,
)

# Hook 채택 원칙 (spec §3.1 의 §34): Capability/Orchestration 이 요구하는
# Fact 에 따라 채택한다 — 개수 축소 자체는 목표가 아니다. 현재 채택분:
# 게이트 2종(tool.*), orchestration 추적 4종(task.*/agent.*), 세션
# 수명주기 + Stop 강등 계약 3종(session.*). 미채택 후보(PostToolBatch/
# ConfigChange/Worktree 계열)는 Fact 수요가 생기는 시점에 이 표의
# 의도적 편집으로 추가한다 (kernel EVENT_TYPES 확장과 함께).
HOOK_EVENT_NAMES = {
    "PreToolUse": "tool.pre",
    "PostToolUse": "tool.post",
    "TaskCreated": "task.created",
    "TaskCompleted": "task.completed",
    "SubagentStart": "agent.started",
    "SubagentStop": "agent.stopped",
    "SessionStart": "session.started",
    "Stop": "session.stop",
    "SessionEnd": "session.ended",
}

_HOOK_NAME_KEY = "hook_event_name"
_TOOL_NAME_KEY = "tool_name"
_TOOL_INPUT_KEY = "tool_input"

# orchestration 추적 4종 (spec §4.4, plan Task 5.3) — task.*/agent.* 로
# 매핑되는 hook. 이 hook 들은 tool_name/tool_input 형태가 아니라
# 이벤트별 고유 필드를 싣는다. 필드 스키마는 2026-08-11 공식 문서
# (https://code.claude.com/docs/en/hooks#taskcreated, #subagentstart 등,
# context7 인덱스로 원문 JSON 예시 + TypeScript 타입 정의 확인 — round-2
# 코드 리뷰 finding 1 로 실측됨)로 실측 확정됐다:
#   - TaskCreated/TaskCompleted: task_id, task_subject, task_description?,
#     teammate_name?, team_name?(deprecated). `subagent_type` 필드는
#     **존재하지 않는다** — 이전 버전은 이 필드가 있다고 잘못 가정했다.
#     `teammate_name` 은 작업 **생성자**이지 배정된 실행자가 아니다.
#   - SubagentStart: agent_id, agent_type.
#   - SubagentStop: agent_id, agent_type, agent_transcript_path,
#     last_assistant_message?, background_tasks?, session_crons?,
#     stop_hook_active.
# 아래 공통 기본 필드를 제외한 나머지는 여전히 통째로 이벤트 payload 로
# 넘긴다(정보 손실 방지) — 다만 확인된 식별 필드만 top-level 로 유지하고
# 나머지는 bounded `"extras"` 로 격리한다(finding 4, `_agent_lifecycle_
# payload` 참조). orchestration/tracker.py 가 이 payload 에서 상관관계
# key·이름을 뽑아 쓴다.
_AGENT_LIFECYCLE_HOOKS = frozenset(
    name
    for name, event in HOOK_EVENT_NAMES.items()
    if event.startswith("task.") or event.startswith("agent.")
)

# 모든 hook 입력에 공통으로 실리는 기본 필드 — 식별 정보가 아니므로
# agent 계열 payload 추출에서 제외한다.
_COMMON_HOOK_BASE_FIELDS = frozenset(
    (
        _HOOK_NAME_KEY,
        "session_id",
        "transcript_path",
        "cwd",
        "permission_mode",
    )
)

# 확인된 식별 필드 — agent 계열 payload 에서 top-level 로 유지한다
# (finding 4, 2026-08-11 round-2 finding 1d 로 실제 스키마 대비 재검증).
# 이벤트 계열마다 실제로 존재하는 필드가 다르지만(위 주석 참조), 이
# 화이트리스트는 두 계열의 합집합이다 — `if key in payload` presence
# check 로 자연히 계열별로 걸러진다(TaskCreated 페이로드에는 애초에
# `agent_id`/`agent_type` 가 없으므로 안전).
#   - `agent_id`/`agent_type`: SubagentStart/SubagentStop 전용.
#   - `task_id`/`task_subject`: TaskCreated/TaskCompleted 전용.
#     `task_subject` 는 orchestration/tracker.py 의 `[unit:<id>]` marker
#     추출(finding 1b-ii)이 구조적으로 의존하므로 반드시 top-level 이어야
#     한다 — extras 로 가면 256자 절단/16-key 상한에 걸려 마커가 조용히
#     손실될 수 있다.
#   - `teammate_name`/`team_name`: TaskCreated/TaskCompleted 전용(작업
#     생성자 식별 — tracker.py 는 assigned_agent 로 오용하지 않는다,
#     finding 1c). `team_name` 은 공식 문서상 deprecated 지만 아직 실재
#     하므로 유지한다 — 제거되면 presence check 가 자연히 걸러낸다.
# `subagent_type`/`tool_use_id` 는 제거했다 — 채택된 4개 hook 의 실제
# 페이로드 어디에도 존재하지 않는 필드였다(전자는 애초에 가상, 후자는
# 근거 없이 미리 포함해뒀던 것).
_AGENT_IDENTITY_FIELDS = (
    "agent_id",
    "agent_type",
    "task_id",
    "task_subject",
    "teammate_name",
    "team_name",
)

# 나머지 비식별 필드를 담는 bounded sub-dict — "strip base fields, pass
# everything else through" 가 상위 hook payload 의 임의 필드로 kernel
# 이벤트를 무제한 오염시키던 문제의 시정(finding 4). 스칼라만 유지하고
# (dict/list 등 중첩 구조는 드롭), 문자열은 길이 상한, 키 개수도 상한
# + 결정적(정렬) 순서로 자른다.
_EXTRAS_KEY = "extras"
_EXTRAS_MAX_KEYS = 16
_EXTRAS_STRING_MAX_LEN = 256

# engine Decision 직렬화 필드 (kernel spec §3.4 — 항상 존재 계약)
_ENGINE_DECISION_KEY = "decision"
_ENGINE_REASON_KEY = "reason"

# native 응답 어휘 — decision/reason 계열 (Stop 등 non-permission hook)
_NATIVE_DECISION_KEY = "decision"
_NATIVE_REASON_KEY = "reason"
_NATIVE_BLOCK = "block"

# native 응답 어휘 — permission 계열 (PreToolUse)
_HOOK_SPECIFIC_OUTPUT_KEY = "hookSpecificOutput"
_HOOK_EVENT_NAME_KEY = "hookEventName"
_PERMISSION_DECISION_KEY = "permissionDecision"
_PERMISSION_REASON_KEY = "permissionDecisionReason"

# native interactive ask 를 지원하는 hook — PreToolUse 만 확인됨
# (spec §2.4, 2026-08-07 공식 문서 검증). ASK_USER 는 여기서만 native
# ask 로 그대로 나간다.
_ASK_CAPABLE_HOOKS = frozenset(("PreToolUse",))

_PERMISSION_DECISIONS = {
    DECISION_BLOCK: "deny",
    DECISION_ASK_USER: "ask",
}

# spec §2.4 — interactive ask 미지원 hook(Stop 등)의 ASK_USER 강등 안내
ASK_USER_DOWNGRADE_GUIDANCE = (
    "현재 작업을 종료할 수 없습니다. 사용자 확인이 필요합니다."
)


class UnknownHookEventError(ValueError):
    """지원하지 않는 hook 이벤트 — 조용한 오분류 대신 명시 실패."""


def normalize_event(payload):
    """Claude hook payload 를 내부 이벤트 dict 로 변환한다.

    orchestration 추적 4종(agent 계열, 모듈 상단 `_AGENT_LIFECYCLE_HOOKS`
    주석 참조)은 tool_name/tool_input 이 아니라 이벤트별 고유 필드를
    싣는다. 확인된 식별 필드(`_AGENT_IDENTITY_FIELDS`)는 top-level 로
    유지하고, 나머지 비식별 필드는 bounded `"extras"` sub-dict 로
    격리한다(finding 4, F2 fix review) — 이전에는 공통 기본 필드만
    제외한 나머지 전부를 통째로 payload 로 넘겨, 상위 hook 이 싣는
    임의 필드가 무제한으로 kernel 이벤트 payload 를 오염시킬 수
    있었다. 그 외 hook(PreToolUse 등)은 기존과 동일하게
    tool_name/tool_input 을 추출한다 — 이 분기는 그 동작을 바꾸지
    않는다.
    """
    hook_name = payload.get(_HOOK_NAME_KEY)
    try:
        event_name = HOOK_EVENT_NAMES[hook_name]
    except KeyError:
        raise UnknownHookEventError(
            "unsupported hook event: {!r}".format(hook_name)
        ) from None
    if hook_name in _AGENT_LIFECYCLE_HOOKS:
        return {
            "name": event_name,
            "tool": None,
            "payload": _agent_lifecycle_payload(payload),
        }
    return {
        "name": event_name,
        "tool": payload.get(_TOOL_NAME_KEY),
        "payload": payload.get(_TOOL_INPUT_KEY) or {},
    }


def _agent_lifecycle_payload(payload):
    """agent 계열 payload 추출 — 식별 필드는 top-level, 나머지는 bounded
    `"extras"` sub-dict 로 (finding 4).

    Top-level 로 승격하는 식별 필드는 값이 비어있지 않은 `str` 일 때만
    받아들인다(round-3 MEDIUM 방어적 타입 검증) — 상위 hook 페이로드가
    기대와 다른 타입(예: `agent_id=["bad"]`)을 실어도, 그 필드는
    top-level 로 승격되지 않고 드롭된다. tracker.py 는 top-level
    `agent_id`/`task_id` 를 dict key 로 직접 쓰므로, 검증되지 않은
    값이 여기를 통과하면 `TypeError: unhashable type` 으로 죽는다 —
    이 검증이 그 경계를 지킨다. 드롭된 필드가 스칼라(str 아닌
    int/float/bool 등, 또는 빈 문자열)라면 `excluded` 집합에서 빠지므로
    아래 `_bounded_extras()` 의 통상 규칙(스칼라만 유지)에 따라 extras
    로는 여전히 흘러들어갈 수 있다 — 완전히 버려지는 것은 non-scalar
    값(리스트/딕셔너리 등)뿐이다.
    """
    identity = {}
    for key in _AGENT_IDENTITY_FIELDS:
        if key not in payload:
            continue
        value = payload[key]
        if isinstance(value, str) and value:
            identity[key] = value
        # else: 검증 실패 — top-level 로 승격하지 않는다(드롭). 아래
        # excluded 집합이 identity.keys() 기준이라, 여기서 드롭된 키는
        # 자동으로 extras 후보로 남는다.
    excluded = _COMMON_HOOK_BASE_FIELDS | frozenset(identity.keys())
    result = dict(identity)
    result[_EXTRAS_KEY] = _bounded_extras(payload, excluded)
    return result


def _bounded_extras(payload, excluded_keys):
    """비식별 필드 → bounded dict.

    - 스칼라만 유지한다(`str`/`int`/`float`/`bool`/`None`) — 중첩 구조
      (dict/list/tuple 등)는 통째로 드롭한다.
    - 문자열 값은 256자로 절단한다.
    - 최대 16 키만 유지하며, 순서는 결정적이다(키 이름 정렬 후 상한
      적용 — 같은 입력이면 항상 같은 16개가 뽑힌다).
    """
    scalars = []
    for key, value in payload.items():
        if key in excluded_keys:
            continue
        if value is not None and not isinstance(value, (str, int, float, bool)):
            continue
        if isinstance(value, str) and len(value) > _EXTRAS_STRING_MAX_LEN:
            value = value[:_EXTRAS_STRING_MAX_LEN]
        scalars.append((key, value))
    scalars.sort(key=lambda item: item[0])
    return dict(scalars[:_EXTRAS_MAX_KEYS])


def to_native_response(hook_name, decision):
    """engine decision dict → Claude native hook 응답 dict 변환.

    입력 decision 은 변경하지 않는다 — engine 출력은 ASK_USER 를 그대로
    유지하고, Stop 강등(spec §2.4)은 반환되는 native 응답에만 존재한다.

    - ALLOW: 모든 hook 에서 빈 응답 (비간섭 — governance ALLOW 는 native
      권한 흐름을 대체하지 않는다).
    - PreToolUse: BLOCK → native deny, ASK_USER → native ask (지원 확인됨).
    - 그 외 hook: BLOCK → 차단 + 사유. ASK_USER → interactive ask 미지원
      이므로 차단 + 안내로 강등한다 (Stop 계약의 보수 일반화 — 조용한
      allow 로 새지 않는다).
    """
    if hook_name not in HOOK_EVENT_NAMES:
        raise UnknownHookEventError(
            "unsupported hook event: {!r}".format(hook_name)
        )
    verdict = decision.get(_ENGINE_DECISION_KEY)
    if verdict not in DECISIONS:
        raise ValueError(
            "engine decision 은 {} 중 하나여야 한다: {!r}".format(
                "/".join(DECISIONS), verdict
            )
        )
    reason = decision.get(_ENGINE_REASON_KEY) or ""
    if verdict == DECISION_ALLOW:
        return {}
    if hook_name in _ASK_CAPABLE_HOOKS:
        return {
            _HOOK_SPECIFIC_OUTPUT_KEY: {
                _HOOK_EVENT_NAME_KEY: hook_name,
                _PERMISSION_DECISION_KEY: _PERMISSION_DECISIONS[verdict],
                _PERMISSION_REASON_KEY: reason,
            }
        }
    if verdict == DECISION_BLOCK:
        return {
            _NATIVE_DECISION_KEY: _NATIVE_BLOCK,
            _NATIVE_REASON_KEY: reason,
        }
    # DECISION_ASK_USER + interactive ask 미지원 hook → 강등 (spec §2.4)
    guidance = ASK_USER_DOWNGRADE_GUIDANCE
    if reason:
        guidance = "{} ({})".format(guidance, reason)
    return {
        _NATIVE_DECISION_KEY: _NATIVE_BLOCK,
        _NATIVE_REASON_KEY: guidance,
    }
