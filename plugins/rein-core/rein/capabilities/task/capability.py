"""active_task capability — task 유무 × 관련성 결합 판정 (spec §3.6, §6.3).

spec §3.6 active_task (§10, 원문 인용):
    "현재 변경이 정의된 Task/DoD 에 속하는지 검증. DoD 전체 생성
    시스템과는 분리 — v2.0 Core 에는 검증만 포함. '무관 파일 편집은
    막히지 않는다' 는 v1.6.5 관련성 판정 행위를 계승한다 (§6.3)."

spec §6.3 v1.6.5 게이트 관련성 판정 표 1행 (원문 인용):
    "미리뷰 문서가 있어도 무관 파일 편집 비차단 (활성 작업이 참조하는
    문서만 차단)" → "active_task 관련성 판정 — ChangeSet 과 활성 Task 의
    참조 범위 결합 (§3.6)"

이 capability 는 `review`/`security` 와 **구조가 다르다**. 두 sibling
capability 는 "Evidence 발급형" — Reviewer/Security Agent 의 structured
response 를 Runtime 이 파싱해 Evidence 를 만들고, 평가 시점에 그
Evidence 의 validity(digest·policy version)를 재확인한다. active_task 는
그 형태를 승계하지 않는다:

- spec §3.6 이 명시하듯 DoD 전체 생성 시스템(누가 task 를 만드는가)은
  v2.0 Core 밖이다. 이 capability 가 검증할 대상은 "Evidence 로 발급되는
  판정 결과"가 아니라 "현재 fact 상태 자체"다 — 활성 task 가 있는가,
  그리고 있다면/없다면 현재 ChangeSet 이 그와 관련 있는가.
- 따라서 `evaluate()` 는 evidence 저장소(`context.evidence_for`)를 전혀
  조회하지 않는다. fact 만으로 충족 여부를 직접 판정한다 — Evidence
  레코드도, 발급 함수도, producer 등급도 없다.

## Fact 계약 (spec §3.2 Lazy Fact Resolution)

- `task.active` — 활성 task 식별자(비어있지 않은 str) 또는 falsy(None
  등, 활성 task 없음). "expensive fact" 목록의 "active task" 항목이
  이 값의 해석에 대응한다 (spec §3.2: "expensive(git status, ChangeSet,
  digest, active task, review state) 구분").
- `changeset.task_relevant` — 현재 ChangeSet 이 task 거버넌스를 필요로
  하는 변경인지의 **이미 결합된** boolean. spec §6.3 표의 "ChangeSet 과
  활성 Task 의 참조 범위 결합" 그 자체가 이 fact 의 산출물이다 — 결합
  연산(태그 분류·활성 task 참조 범위 대조)은 Platform 의 expensive fact
  resolver 소관이고 (기존 capability 들의 "해석은 platform, capability
  는 값만 조회" 패턴과 동일, review capability 의 `changeset.digest`
  주석 참조), 이 capability 는 그 결과값만 읽는다.

## 결합 판정 (spec §6.3 표 1행 그대로)

| task.active | changeset.task_relevant | 충족? |
|---|---|---|
| 있음 | 관련(True) | 충족 — ALLOW 방향 |
| 있음 | 무관(False) | **충족** — 무관 편집 비차단 (v1.6.5 계승 핵심) |
| 없음 | 관련(True) | **미충족** — BLOCK 재료 (policy 가 요구하는 상황) |
| 없음 | 무관(False) | 충족 — 과차단 금지 |

활성 task 가 있으면 관련성과 무관하게 항상 충족이다. 만약 "활성 task 의
declared scope 안의 파일만 충족" 처럼 범위를 좁혀 재판정하면, 바로
v1.6.5 GSD-2 가 고친 버그("무관 문서 1건이 소스 전체 잠금 28회", 실제
v1 hook `pre-edit-dod-gate.sh` 의 `_spec_related_to_active_work` 도입
배경)가 v2 에서 재발한다 — 활성 task 존재 자체가 이 Requirement 의
충족 조건이고, "이 파일이 그 task 의 범위 안인가"는 별도 강제 대상이
아니다 (v1 의 실제 `DOD_FOUND` 게이트도 특정 DoD 범위 매칭 없이 활성
DoD 존재만으로 소스 편집을 허용했다 — 관련성 축소는 spec-review 계열의
별도 관심사였고 이 Requirement 의 전신이 아니다).

`changeset.task_relevant` 가 확보되지 않으면(None) 보수적으로
관련(True)으로 취급한다 — "확인 불가 ≠ 충족" 원칙(spec §3.4)의 이
capability 판이다. 판정 불능을 완화(무관) 방향으로 승격하면 실제로는
task 를 필요로 하는 변경이 조용히 통과하는 false-ALLOW 가 된다
(게이트 계열에서 FN 이 FP 보다 나쁘다는 원칙, spec §2.2 위협모델과
정합).

## strict 타입 계약 (사이클 A 리뷰 1회차 High 지적 수정)

최초 구현은 `changeset.task_relevant` 를 `bool(value)` 로 관대하게
강제 변환했다 — `""`/`0`/`[]` 같은 **falsy 이지만 bool 이 아닌** 값이
"무관(False)"으로 오인정되어, task 가 없는 상태의 변경이 ALLOW 로
새는 경로였다. 이 저장소의 일반 규율("malformed 입력의 관대한 보정
금지" — security/review capability 의 `_parse_structured_response`
strict 파싱과 동일 원칙, spec §2.2)에 따라 두 fact 모두 **값 자체가
오염**이면 관대히 보정하지 않고 `FactResolutionError` 로 승격한다
(`rein.engine.context`, `EvidenceStorageError` 하위 타입 — 판단
재료를 확보하지 못한 것과 동일 계층). `context.fact()` 가 스스로
던지는 것이 아니라 이 모듈이 값을 받은 뒤 계약 위반을 직접 검사해
던진다 — resolver 예외가 아니라 "resolver 가 계약을 어긴 값을 준
경우"이므로 검사 책임은 이 capability 에 있다.

- **`changeset.task_relevant`**: 유효 값은 `bool` 인스턴스(`True`/
  `False`) 또는 `None`(fact 미확보 — 위 문단대로 보수적으로 관련
  취급) 뿐이다. 그 외 타입은 malformed → `FactResolutionError`.
- **`task.active`**: 같은 관점에서 점검한 결과, 이 fact 도 동일 규율을
  적용한다. 유효 값은 `str`(빈 문자열 포함 — "빈 문자열 = 활성 task
  없음"은 malformed 가 아니라 정상적인 "없음" 표현이다) 또는
  `None`(fact 미확보 — 마찬가지로 "없음") 뿐이다. `int`/`list`/`dict`
  또는 `bool`(`bool` 은 `int` 의 하위형이라 `isinstance(x, str)` 로
  자연히 배제된다) 같은 다른 타입이 오면 `bool(value)` 진리값 강제
  변환이 `0`/`[]` 를 "task 없음"으로, 다른 무의미한 객체를 "task
  있음"으로 우연히 오인정할 수 있으므로 — `changeset.task_relevant`
  와 동일하게 malformed 로 거부한다.
"""
from rein.engine.context import FactResolutionError
from rein.kernel.requirement import Requirement

# 고정 5종 계약 이름 (kernel REQUIREMENT_NAMES 원소, spec §3.4)
REQUIREMENT_NAME = "active_task"

# 활성 task 식별자 fact — 비어있지 않은 문자열이면 "활성 task 있음",
# None/빈 문자열은 "활성 task 없음". 유효 타입은 str 또는 None 뿐이다 —
# 다른 타입은 evaluate() 에서 FactResolutionError 로 거부한다 (모듈
# docstring "strict 타입 계약" 절).
FACT_TASK_ACTIVE = "task.active"

# ChangeSet × 활성 Task 참조 범위의 결합 산출물 — boolean (spec §6.3).
# 결합 연산 자체는 Platform 의 expensive fact resolver 가 수행한다
# (spec §3.2 "expensive(... active task ...)"). 이 capability 는 결과
# 값만 조회한다.
FACT_CHANGESET_TASK_RELEVANT = "changeset.task_relevant"


class ActiveTaskRequirement(Requirement):
    """active_task Requirement 구현체 — fact 결합만으로 판정한다 (spec §3.6).

    review/security 의 `evaluate()`와 달리 evidence 저장소를 전혀
    조회하지 않는다 — Evidence 발급 개념 자체가 이 Requirement 에는
    없다(DoD 생성 시스템 분리, 모듈 docstring 참조). 판정 재료는
    `task.active` 와 `changeset.task_relevant` 두 fact 뿐이다.
    """

    @property
    def name(self):
        return REQUIREMENT_NAME

    def evaluate(self, context):
        """충족 여부(bool) — 모듈 docstring 표의 4행을 그대로 코드화.

        1. `task.active` 값을 먼저 strict 타입 검사한다(`str` 또는
           `None` 만 유효) — 모듈 docstring "strict 타입 계약" 절.
           malformed 값은 즉시 `FactResolutionError` 로 승격한다.
           활성 task 가 있으면(비어있지 않은 문자열) 관련성과 무관하게
           항상 충족이다 — v1.6.5 관련성 판정 계승의 핵심 지점(활성
           task 의 declared scope 매칭을 추가로 요구하지 않는다, 모듈
           docstring "결합 판정" 절 참조). 이 분기에서는
           `changeset.task_relevant` 를 아예 조회하지 않으므로, 그
           값이 malformed 여도 이 경로의 판정에는 영향이 없다 — 실제로
           읽어 판정에 쓰는 지점에서만 계약을 검사한다(아래 3).
        2. 활성 task 가 없으면 `changeset.task_relevant` 로 판가름한다:
           관련(True) → 미충족(BLOCK 재료) / 무관(False) → 충족.
        3. `changeset.task_relevant` 도 strict 타입 검사한다(`bool` 또는
           `None` 만 유효). `None`(미확보)은 보수적으로 관련(True)으로
           취급 — 확인 불가를 무관(충족)으로 승격하지 않는다. `bool`
           이 아닌 다른 값(`""`/`0`/`[]`/`"true"` 등)은 관대한
           `bool()` 강제 변환으로 삼키지 않고 `FactResolutionError` 로
           승격한다 — 이 값들은 "판단 재료가 오염된 상태"이지 정상적인
           "무관" 표현이 아니다 (사이클 A 리뷰 1회차 High: falsy-but-
           not-bool 값이 무관으로 오인정되어 task 없는 변경이 ALLOW 로
           새는 경로였다).

        fact 해석 실패(resolver 가 던지는 `FactResolutionError`)는
        `context.fact()` 계약대로 그대로 전파되고, 이 메서드가 값을 받은
        뒤 계약 위반을 발견해 직접 던지는 `FactResolutionError` 도 같은
        타입이므로 호출자 입장에서는 동일하게 처리된다 — 어느 경로든
        판단 불능은 evaluator 의 failure_mode 분기가 처리한다 (판단
        불능 ≠ 부재, spec §3.4).
        """
        task_active = context.fact(FACT_TASK_ACTIVE)
        if task_active is not None and not isinstance(task_active, str):
            raise FactResolutionError(
                "fact {!r} must be a str task identifier or None, got "
                "{!r} (type {})".format(
                    FACT_TASK_ACTIVE, task_active, type(task_active).__name__
                )
            )
        if task_active:
            return True
        relevant = context.fact(FACT_CHANGESET_TASK_RELEVANT)
        if relevant is None:
            relevant = True
        elif not isinstance(relevant, bool):
            raise FactResolutionError(
                "fact {!r} must be a bool or None, got {!r} (type {})"
                .format(
                    FACT_CHANGESET_TASK_RELEVANT,
                    relevant,
                    type(relevant).__name__,
                )
            )
        return not relevant


def register_active_task(registry):
    """RequirementRegistry 에 active_task 구현체를 명시 등록한다.

    등록은 이 함수 호출로만 일어난다 — import 부작용 등록 금지
    (spec §3.1 §32: Registry 는 명시적 코드 등록). 등록된 구현체를
    반환한다 (호출자가 동일 인스턴스를 재사용할 수 있게).
    """
    implementation = ActiveTaskRequirement()
    registry.register(REQUIREMENT_NAME, implementation)
    return implementation
