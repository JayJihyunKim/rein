"""WorkUnit — Orchestration 최소 작업 단위 (spec §4.3, brainstorm §38).

WorkUnit 필드 계약(spec §4.3, 2026-08-11 spec 정정판): ``id`` /
``objective`` / ``scope`` / ``dependencies`` / ``assigned_agent`` /
``status`` / ``expected_output`` / ``mode`` — 8필드.

``mode``(closed set ``edit_only``|``mutating``)는 spec §4.3 의 8번째 공식
필드다(이전 초안은 "7필드 밖의 선택적 확장"으로 서술했으나, spec 정정으로
계약의 일부가 되었다 — 이 모듈·validator.py 양쪽의 관련 문구를 갱신한다).
스케줄러(`work_graph.py`)가 v1 parallel-execute 의 웨이브 유도 규칙 —
"mutating 단독 웨이브, edit_only 병렬" (spec §5.3 계승 표) — 을 재현하려면
이 구분이 반드시 필요하고, spec §5.3 은 "edit_only / mutating 모드 구분"
을 명시적 계승 대상으로 지정한다. 따라서 v1 스킬(`skills/
parallel-execute/SKILL.md`) 의 task 스키마 필드를 그대로 이식한다 — 신규
발명이 아니라 v1 자산 이식.

Python 은 Agent 를 spawn 하지 않는다(spec §4.1) — 이 모듈은 순수 데이터
모델이며 실행 주체(워커·오케스트레이터)를 가정하지 않는다.

``scope`` 는 non-empty 계약을 갖는다(codex review round 5 HIGH finding —
v1 계약 이식, `docs/exec-strategy-schema.md` §scope + `scripts/
rein-validate-coverage-matrix.py` fail-closed 조건 e). 빈/생략된 scope 는
"write-set 미상"(unknown write-set)을 뜻하며, 스케줄러가 이를 "아무
것도 안 겹침"으로 오판해 병렬 co-schedule 할 위험이 있다. `dependencies`
는 이 계약 밖이다(v1 `depends_on` 은 optional).
"""
from dataclasses import dataclass

# status 값 (v1 워커 결과 스키마 `status: completed|blocked` 계승, spec §5.3
# 계승 표 "워커 결과 스키마" 행 — 실행 전 초기 상태로 pending 을 추가한다.
WORK_UNIT_PENDING = "pending"
WORK_UNIT_COMPLETED = "completed"
WORK_UNIT_BLOCKED = "blocked"
WORK_UNIT_STATUSES = (WORK_UNIT_PENDING, WORK_UNIT_COMPLETED, WORK_UNIT_BLOCKED)

# mode 값 (v1 `mode: edit_only|mutating` 계승, spec §5.3).
WORK_UNIT_MODE_EDIT_ONLY = "edit_only"
WORK_UNIT_MODE_MUTATING = "mutating"
WORK_UNIT_MODES = (WORK_UNIT_MODE_EDIT_ONLY, WORK_UNIT_MODE_MUTATING)


class WorkUnitError(ValueError):
    """WorkUnit 필드 계약 위반 (spec §4.3 / v1 fail-closed 계승)."""


def _normalize_optional_sequence(value, field_name):
    """``scope``/``dependencies`` 필드를 tuple 로 정규화한다.

    계약: ``None`` 또는 non-string sequence(list/tuple)만 허용한다.
    ``None`` 은 "필드 생략" 으로 인정해 빈 tuple 로 취급한다. 그 외 모든
    타입은 명시적으로 `WorkUnitError` 를 던진다 — bare string/bytes 는
    `tuple("abc")` 문자 단위 분해 오인정 위험(kernel `Decision`
    missing_requirements/evidence_refs 와 동일한 방어 원칙)으로,
    list/tuple 이 아닌 나머지 전부(bool/int/float/dict/set/generator
    등)는 codex review round 3 MEDIUM finding 대상이다: 예전엔
    ``tuple(value or ())`` 트릭을 썼는데, `False`/`0` 같은 falsy-지만-
    not-None 값이 `value or ()` 에서 조용히 빈 tuple 로 격하되어(예외
    없이 입력을 버리고 성공 처리) 호출자가 실수를 알아챌 방법이 없었다.
    dict 도 같은 함정의 다른 얼굴이다 — 빈 dict 는 falsy 라 조용히
    사라지고, 내용 있는 dict 는 `tuple({...})` 가 키만 원소로 오인정
    한다. 이제는 타입을 명시적으로 검사해 이 모든 경우를 fail-closed
    로 거부한다.
    """
    if value is None:
        return ()
    if isinstance(value, (str, bytes)):
        raise WorkUnitError(
            "WorkUnit.{} 는 목록이어야 한다 (단일 문자열 금지): {!r}".format(
                field_name, value
            )
        )
    if not isinstance(value, (list, tuple)):
        raise WorkUnitError(
            "WorkUnit.{} 는 None 이거나 list/tuple 이어야 한다 (falsy "
            "값(False/0/빈 dict 등)도 예외 없이 거부한다 — silent data "
            "loss 방지): {!r}".format(field_name, value)
        )
    return tuple(value)


def _reject_invalid_elements(value, field_name):
    """``scope``/``dependencies`` 의 개별 원소가 비어 있지 않은 문자열인지
    검증한다 (codex review round 2 MEDIUM finding).

    dict/list/``object()`` 같은 값이 원소로 조용히 통과하면, WorkUnit
    자신은 문제없이 생성되지만 다운스트림에서 예측 불가능한 시점에
    터진다 — 예: `WorkGraph.__post_init__` 의 ``dep not in id_set``
    (set 멤버십 판정은 hashable 을 요구, unhashable list/dict 는
    TypeError), `work_graph.py` 의 스케줄러가 scope 로 만드는 set
    comprehension(같은 이유), `WorkGraph.to_planned_units()` 의 결과를
    ``json.dumps`` 할 때(``object()`` 는 JSON 직렬화 불가). 이 함수는
    가장 이른 경계인 WorkUnit 생성 시점에 fail-closed 로 거부해, 잘못된
    WorkUnit 이 애초에 존재하지 못하게 한다 — 다운스트림 코드가 각자
    방어할 필요가 없어진다.
    """
    for item in value:
        if not isinstance(item, str) or not item:
            raise WorkUnitError(
                "WorkUnit.{} 의 각 원소는 비어 있지 않은 문자열이어야 "
                "한다: {!r}".format(field_name, item)
            )


@dataclass(frozen=True)
class WorkUnit:
    """단일 작업 단위. ``scope``/``dependencies`` 는 tuple 로 정규화한다."""

    id: str
    objective: str
    scope: tuple = ()
    dependencies: tuple = ()
    assigned_agent: str = None
    status: str = WORK_UNIT_PENDING
    expected_output: str = ""
    mode: str = WORK_UNIT_MODE_EDIT_ONLY

    def __post_init__(self):
        if not isinstance(self.id, str) or not self.id:
            raise WorkUnitError(
                "WorkUnit.id 는 비어 있지 않은 문자열이어야 한다: {!r}".format(
                    self.id
                )
            )
        if not isinstance(self.objective, str) or not self.objective:
            raise WorkUnitError(
                "WorkUnit.objective 는 비어 있지 않은 문자열이어야 한다: "
                "{!r}".format(self.objective)
            )

        object.__setattr__(
            self, "scope", _normalize_optional_sequence(self.scope, "scope")
        )
        if not self.scope:
            # codex review round 5 HIGH finding — v1 계약 이식
            # (`docs/exec-strategy-schema.md` §scope, `scripts/
            # rein-validate-coverage-matrix.py` fail-closed 조건 e):
            # scope 는 반드시 non-empty literal file path list 여야
            # 한다. 빈/생략된 scope 는 "아무 것도 안 건드림" 이 아니라
            # "write-set 을 선언하지 않음"(unknown write-set) 을
            # 의미한다 — work_graph.py 의 scheduler 가 이런 유닛을
            # 다른 어떤 유닛과도 scope 가 안 겹치는 것으로 오판해
            # 병렬 co-schedule 하면 실제로는 알 수 없는 파일을 건드릴
            # 수 있는 유닛이 안전하다고 낙인찍히는 위험이 있다.
            # dependencies 는 이 계약 대상이 아니다 — v1 `depends_on`
            # 은 optional(기본 `[]`)이므로 비대칭이 맞다.
            raise WorkUnitError(
                "WorkUnit.scope 는 비어 있을 수 없다 (v1 계약 이식 — "
                "exec-strategy-schema.md §scope, fail-closed e): 최소 "
                "1개 이상의 literal file path 를 선언해야 한다: "
                "{!r}".format(self.scope)
            )
        _reject_invalid_elements(self.scope, "scope")

        object.__setattr__(
            self,
            "dependencies",
            _normalize_optional_sequence(self.dependencies, "dependencies"),
        )
        _reject_invalid_elements(self.dependencies, "dependencies")
        if self.id in self.dependencies:
            raise WorkUnitError(
                "WorkUnit '{}' 은 자기 자신을 dependencies 로 선언할 수 "
                "없다".format(self.id)
            )

        if self.assigned_agent is not None and not isinstance(
            self.assigned_agent, str
        ):
            raise WorkUnitError(
                "WorkUnit.assigned_agent 는 문자열이거나 None 이어야 한다: "
                "{!r}".format(self.assigned_agent)
            )

        if self.status not in WORK_UNIT_STATUSES:
            raise WorkUnitError(
                "WorkUnit.status 는 {} 중 하나여야 한다: {!r}".format(
                    "/".join(WORK_UNIT_STATUSES), self.status
                )
            )

        if not isinstance(self.expected_output, str):
            raise WorkUnitError(
                "WorkUnit.expected_output 은 문자열이어야 한다: {!r}".format(
                    self.expected_output
                )
            )

        if self.mode not in WORK_UNIT_MODES:
            raise WorkUnitError(
                "WorkUnit.mode 는 {} 중 하나여야 한다: {!r}".format(
                    "/".join(WORK_UNIT_MODES), self.mode
                )
            )
