"""Loop Controller — v1 Review Loop Budget + Circuit Breaker 통합 (plan Task 4.6 — spec §3.7 §22).

spec §3.7 원문 인용:
    "v1 Review Loop Budget(5회 + `[MAX_ROUNDS:]` extension, v1.6.5)과
    신규 Circuit Breaker 를 하나의 Loop Controller 로 통합 — 이중 운영
    금지, 마이그레이션 시 기존 budget 을 흡수한다.

    - No Progress Detection: `progress_digest = change_digest + missing
      requirements + evidence state + policy version`. 동일 상태 반복
      (기본 2회) → ASK_USER.
    - Absolute Attempt Budget: progress 는 있으나 반복 과다 → budget 에서
      중단. (조금씩 수정해 digest 만 바꾸는 무한 반복 차단.)"

spec §6.3 원문 인용 (v1.6.5 게이트 관련성 판정 계승 매핑, 4건 중 3번째):
    "리뷰 회차 상한 (5회 + `[MAX_ROUNDS:]` 연장, exit 6) | Loop Controller
    로 흡수 (§3.7) — 이중 운영 금지"

v1 행위 참고 (파일 조작 없이 계약만 읽음, `scripts/rein-codex-review.sh`
"Review round budget" 절): 미통과 회차만 누적, 통과는 카운터를 지운다,
상한 도달 후 호출은 수행 이전에 거부, 카운터를 읽거나 쓸 수 없는 상태는
예산 소진이 아니다, 연장은 항상 stderr 경고 + 이력에 남는다(조용한
연장 경로 없음). 이 v1 계약 중 "연장은 항상 기록에 남는다" 원칙을
`extend_budget`/`extension_history` 로 흡수한다. v1 의 리뷰 PASS/FAIL
판정 자체(카운터를 지우는 조건)는 이 모듈의 scope 밖이다 — 이 컨트롤러는
"진행이 있었는가"만 progress_digest 로 판정하고, 리뷰 통과 여부의 의미
해석은 호출자(Runtime/capability)가 missing_requirements 를 통해 반영한다.

## 두 halt 신호가 다른 이유 — ASK_USER 재사용 vs 전용 어휘

No Progress 는 kernel Decision 의 ASK_USER 값(`DECISION_ASK_USER`, spec
§3.4 Decision 3종 중 사람 개입을 요청하는 값)을 그대로 재사용한다 —
"같은 상태가 반복된다, 사람이 판단해야 한다"는 의미가 정확히 일치한다.

Budget Exhausted 는 **의도적으로 별도 상수**(`SIGNAL_BUDGET_EXHAUSTED`)를
쓴다. kernel `Decision.decision` 필드는 ALLOW/BLOCK/ASK_USER 폐쇄 3종
(`kernel/decision.py` 의 `DECISIONS`)만 허용하는 계약이라, 서로 다른
원인("교착"과 "예산 소진")을 그 3종 중 같은 값 뒤에 뭉치면 소비자가 둘을
구분할 수 없어진다. v1 도 이 구분을 exit code 로 이미 유지했다 (리뷰가
아직 안 끝나 "이번 회차는 실패, 다음 회차로" 인 정상 미통과와, "회차
상한 자체를 넘겨서 더 못 돈다"인 exit 6 은 다른 신호였다). No Progress
는 "다른 접근을 시도해야 한다"는 신호이고, Budget Exhausted 는 "조금씩
이라도 나아가고는 있지만 이 방식으로는 끝나지 않으니 리소스를 더 쓰기
전에 멈춘다"는 신호다 — 소비자가 둘에 다르게 반응할 여지(예: 후자만
사람에게 진행 요약을 붙여 보고)를 보존한다.

## progress_digest 4요소 결합 — 프레이밍 마커로 연접 충돌 방지

kernel `changeset.py` 의 `content_digest` 와 동일 원칙(그 모듈의
"프레이밍 마커" 절)을 따른다: 각 요소를 태그 + 길이 프리픽스로 감싸
직렬화한 뒤 이어붙인다 — `"ab"+"c"` 와 `"a"+"bc"` 가 같은 digest 로
충돌하는 것도, 필드 경계를 넘나드는 연접("change_digest 뒤가 그대로
missing_requirements 앞과 이어짐")도 막는다. `missing_requirements` 는
정렬·중복제거된 튜플로 정규화한다(순서 무관 — kernel
`Decision.missing_requirements` 정규화와 동일 원칙). `evidence_state`
는 `(requirement_name, state_token_또는_None)` 쌍의 정렬된 컬렉션으로
정규화한다 — `None`(해당 requirement 의 evidence 상태를 아직 확인할 수
없음/미보유)과 그 requirement 자체가 컬렉션에서 빠진 것은 다른 상태로
결속된다(부재 vs 빈 값을 구분하는 `changeset.py` 의 `_MARK_ABSENT` 원칙과
동형).

## 저장 — 순수 인메모리 + 직렬화 가능 스냅샷

controller 는 자기 상태(시도 횟수, 마지막 progress_digest, 연장 이력)를
인스턴스 필드로만 갖는다. 영속화는 이 모듈의 책무가 아니다(spec §3.8
Storage 는 platform/storage 계층 소관) — `snapshot()` / `from_snapshot()`
로 dict 왕복만 제공해 호출자가 원하는 저장소(SQLite Runtime State 등)에
얹을 수 있게 한다. 이 모듈은 파일도 SQLite 도 열지 않는다.

스냅샷은 신뢰된 입력이 아니다 — storage 계층을 거쳐 임의로 구성될 수
있는 데이터이므로, `from_snapshot()` 은 `budget` 이 `default_budget` +
`extension_history` 누적분과 정확히 일치하는지 재검증한다(코드리뷰
사이클 C 1차 High: `extension_history=[]` 인 채로 부풀린 `budget`
스냅샷이 조용히 복원되던 결함의 수리) — "연장은 항상 이력에 남는다"는
`extend_budget()` 의 계약이 스냅샷 왕복 경로에서도 그대로 유지된다.

**신뢰 기준선은 호출자가 공급한다 (코드리뷰 사이클 C 2차 High)**: 1차
수정은 `budget` 이 `extension_history` 와 정합하는지만 검증했는데,
그 정합성 검사의 기준이 되는 `default_budget` **자체**도 스냅샷
필드에서 그대로 읽고 있었다 — `default_budget`·`budget`·
`extension_history`(빈 배열) 를 **함께** 위조하면(예:
`default_budget=999`, `budget=999`, `extension_history=[]`) 위조된
기준선과 위조된 결과가 서로 들어맞으므로 정합성 검사를 그대로
통과한다. 검증 로직이 검증 대상과 같은(오염 가능한) 데이터에서 기준을
끌어오면 검증 자체가 무의미해진다 — "스냅샷은 신뢰된 입력이 아니다"라는
전제 자체와 모순이었다. 수정: `from_snapshot(snapshot, default_budget=…,
no_progress_threshold=…)` — 두 기준선 값은 **호출자(코드/정책)가 인자로
공급**하며 그 값이 정본이다(kernel `policy_version_valid` 가 "현재
policy version"을 항상 호출자 fact 에서 받고 Evidence 내부 필드를
재귀적으로 신뢰하지 않는 것과 동일 원칙 — 신뢰 기준은 검증 대상 바깥에
있어야 한다). 스냅샷에도 동일 이름의 필드가 남아있지만(자기서술적
왕복·감사 목적), 그 값은 이제 **호출자 인자와 반드시 일치해야 하는
감사 필드**로 강등된다 — 불일치는 관대한 승격이 아니라 명시 거부다.
"기준선 자체가 실제로 바뀌었다"는 시나리오는 이 함수로 옛 스냅샷을
복원하는 대신 새 기준으로 `LoopController(budget=…)` 를 새로 만드는
것이 맞다 — `from_snapshot` 은 "같은 기준선을 유지한 채 이어간다"만
책임진다.

**연장 이력의 시간 단조성**: `extension_history` 의 각 항목 `at_attempt`
는 비감소 수열이어야 한다(코드리뷰 사이클 C 2차 High: `[1, 0]` 같은
역행 수열이 1차 수정 이후에도 그대로 복원됐다) — 두 번째 연장이 첫
번째 연장보다 더 이른 시도 번호를 주장할 수 없다. 여전히 각 항목의
`at_attempt` 는 `attempt_count` 를 넘을 수 없다(1차 수정에서 이미
고정한 검증 유지).

**연장 권위도 호출자가 공급한다 (코드리뷰 사이클 C 3차 High)**: 1·2차
수정은 각각 `budget`↔`extension_history` 정합성과 `default_budget`
신뢰 기준선을 다뤘지만, `extension_history` **내용의 진위**는 여전히
스냅샷 내부 자기 일관성(체인 연속성·단조성)만으로 판정했다 — 신뢰
기준선(`default_budget=5`)과 일관되는 위조 이력(`{5→999}`)을 함께
구성하면, 자기 일관성 검사를 그대로 통과하면서 아무도 승인하지 않은
연장이 복원됐다. 자기 일관성(internally consistent)과 진위(authentic)
는 다른 속성이다 — kernel `evidence.py` 가 서명이 아니라 **원장 대조**로
Evidence 발급을 검증하는 것과 같은 이유로, `from_snapshot()` 도
`approved_extensions` 인자(호출자가 자신의 신뢰 기록에서 공급하는,
실제로 승인된 연장 목록)를 받아 `snapshot['extension_history']` 가 이
목록과 **완전히 일치**하는지 대조한다 — 불일치는 거부, 기본값(빈
목록)은 "연장 없는 스냅샷"만 통과시킨다. 최종 `budget`/
`extension_history` 는 스냅샷이 아니라 이 승인 목록에서 재계산한다
(`from_snapshot()` 메서드 docstring "연장 권위도 호출자가 공급" 절
참조).

**카운터(attempt/repeat) 신뢰 경계는 이 모듈이 닫을 수 없다**: 연장은
"승인"이라는 스냅샷 밖 사건이 있어 대조 가능하지만, `attempt_count`/
`repeat_count` 는 매 `record_attempt()` 호출 자체가 유일한 사건이라
대조할 외부 원장이 없다. 이 모듈의 신뢰 경계는 스냅샷 저장 파일이
Runtime 소유의 로컬 상태(spec §3.8: 0600 생성 — Evidence 정본 파일과
동일 신뢰 계급)라는 전제 위에 있다 — 그 파일의 직접 위조·삭제는 spec
§2.2 위협 모델("정직한 에이전트 규율") 밖이다. `from_snapshot()` 은
그 전제 위에서 **형식 하한(구조적 모순) 검증만** 추가한다(하향 위조
탐지가 아니라 자기모순 검출 — `from_snapshot()` 메서드 docstring
참조).

## 카운터 단일성 (plan Task 4.6 Step 1(c))

이 controller 인스턴스가 시도 계수의 유일한 소유자다 — 외부 카운터
파일(v1 의 `trail/dod/.review-rounds/` 류)을 읽거나 쓰지 않는다. v1
카운터 제거 자체는 Phase 7 소관이며, 여기서 고정하는 계약은 "v2
controller 가 자신의 계수를 스냅샷 왕복 후에도 스스로 이어간다 — 외부
카운터를 참조·증가시키지 않는다"는 범위다. 서로 다른 두 `LoopController`
인스턴스는 상태를 공유하지 않는다(모듈 전역 카운터 없음) — 계수는
언제나 해당 인스턴스(또는 그 스냅샷을 복원한 인스턴스)에만 귀속된다.

capability 간 직접 의존 금지 원칙(spec §3.1)과 동형으로, 이 모듈은
kernel 어휘(`kernel.decision`)만 소비한다 — 특정 capability(review,
security, testing, task, approval)를 import 하지 않는다. 어떤
requirement 가 missing 인지·evidence state 가 무엇인지는 호출자가
문자열/토큰으로 넘긴다.
"""
import hashlib

from rein.kernel.decision import DECISION_ASK_USER

# ---------------------------------------------------------------------------
# 기본값 (spec §3.7 "기본 2회" / v1 "5회" 흡수)
# ---------------------------------------------------------------------------

DEFAULT_NO_PROGRESS_THRESHOLD = 2
DEFAULT_ATTEMPT_BUDGET = 5

# ---------------------------------------------------------------------------
# halt 신호 어휘 (모듈 docstring "두 halt 신호가 다른 이유" 절)
# ---------------------------------------------------------------------------

SIGNAL_CONTINUE = "CONTINUE"
SIGNAL_ASK_USER = DECISION_ASK_USER  # kernel 어휘 재사용 — 교착(No Progress) halt
SIGNAL_BUDGET_EXHAUSTED = "BUDGET_EXHAUSTED"  # 전용 어휘 — 예산 소진 halt
SIGNALS = (SIGNAL_CONTINUE, SIGNAL_ASK_USER, SIGNAL_BUDGET_EXHAUSTED)


class LoopControllerError(ValueError):
    """Loop Controller 계약 위반 — 호출자 입력이 잘못된 형태."""


# ---------------------------------------------------------------------------
# progress_digest — 4요소 결합 (change_digest, missing_requirements,
# evidence_state, policy_version)
# ---------------------------------------------------------------------------

_DIGEST_ALGORITHM = "sha256"
_LENGTH_PREFIX_BYTES = 8

# 필드별 프레이밍 마커 — 필드 경계를 넘나드는 연접 충돌을 막는다
# (모듈 docstring "progress_digest 4요소 결합" 절).
_MARK_CHANGE_DIGEST = b"C"
_MARK_MISSING = b"M"
_MARK_EVIDENCE = b"E"
_MARK_POLICY_VERSION = b"V"
_MARK_ITEM = b"I"
_MARK_STATE_PRESENT = b"S"
_MARK_STATE_ABSENT = b"N"


def _require_nonempty_str(name, value):
    if not isinstance(value, str) or not value:
        raise LoopControllerError(
            "{} must be a non-empty str, got {!r}".format(name, value)
        )
    return value


def _encode(value):
    return value.encode("utf-8", "surrogateescape")


def _feed_length_prefixed(hasher, marker, payload):
    """마커 + 길이 프리픽스 + 내용을 hasher 에 먹인다 (자기서술 프레이밍)."""
    hasher.update(marker)
    hasher.update(len(payload).to_bytes(_LENGTH_PREFIX_BYTES, "big"))
    hasher.update(payload)


def _normalize_missing_requirements(value):
    """missing_requirements 를 정렬·중복제거된 str 튜플로 정규화한다.

    kernel `Decision.missing_requirements` 정규화와 동일 원칙: 순서는
    상태를 바꾸지 않는다(같은 집합 = 같은 digest). `str`/`bytes` 자체를
    컬렉션으로 그대로 받으면 `tuple("abc")` 가 문자 단위로 분해되는
    함정이 열리므로(kernel `changeset`/`policy` 가드와 동일 원칙) 명시
    거부한다.
    """
    if isinstance(value, (str, bytes)):
        raise LoopControllerError(
            "missing_requirements must be a collection of requirement name "
            "strings, not a single str/bytes value: {!r}".format(value)
        )
    try:
        items = tuple(value or ())
    except TypeError:
        raise LoopControllerError(
            "missing_requirements must be an iterable of requirement name "
            "strings, got {!r} (type {})".format(value, type(value).__name__)
        )
    for item in items:
        if not isinstance(item, str) or not item:
            raise LoopControllerError(
                "missing_requirements entries must be non-empty strings, "
                "found {!r}".format(item)
            )
    return tuple(sorted(set(items)))


def _normalize_evidence_state(value):
    """evidence_state 를 `(name, state_token)` 정렬 튜플로 정규화한다.

    `dict` 또는 `(name, state)` 쌍의 iterable 을 받는다. `state` 는
    `None`(해당 requirement 의 evidence 상태를 확인할 수 없음/미보유)
    또는 비어있지 않은 `str` 이어야 한다. `None` 인 requirement 를
    컬렉션에서 아예 빼는 것과 `None` 값으로 명시하는 것은 다른
    digest 를 만든다 — 둘 다 최종 결과가 "그 requirement 의 상태를
    특정 못 함"이라는 점에서 실질적으로는 같은 정보지만, 이 함수는
    호출자가 넘긴 컬렉션의 키 존재 여부를 그대로 반영한다(암묵적 보정
    없음 — kernel `changeset.content_digest` 의 "부재 vs 빈 내용은 다른
    상태" 원칙과 동형: 이 함수는 "키 부재"와 "키 존재 + None 값"을
    구분해 다르게 인코딩한다).
    """
    if value is None:
        raise LoopControllerError(
            "evidence_state must not be None — pass an empty mapping/"
            "collection to represent 'no evidence tracked yet'"
        )
    if isinstance(value, (str, bytes)):
        raise LoopControllerError(
            "evidence_state must be a mapping or a collection of "
            "(name, state) pairs, not a single str/bytes value: "
            "{!r}".format(value)
        )
    if hasattr(value, "items"):
        raw_items = tuple(value.items())
    else:
        try:
            raw_items = tuple(value)
        except TypeError:
            raise LoopControllerError(
                "evidence_state must be a mapping or an iterable of "
                "(name, state) pairs, got {!r} (type {})".format(
                    value, type(value).__name__
                )
            )
    normalized = []
    seen_names = set()
    for entry in raw_items:
        if (
            not isinstance(entry, tuple)
            or len(entry) != 2
        ):
            raise LoopControllerError(
                "evidence_state entries must be (name, state) pairs, "
                "found {!r}".format(entry)
            )
        name, state = entry
        if not isinstance(name, str) or not name:
            raise LoopControllerError(
                "evidence_state requirement name must be a non-empty "
                "string, found {!r}".format(name)
            )
        if state is not None and (not isinstance(state, str) or not state):
            raise LoopControllerError(
                "evidence_state state token for {!r} must be None or a "
                "non-empty string, found {!r}".format(name, state)
            )
        if name in seen_names:
            raise LoopControllerError(
                "evidence_state has duplicate requirement name "
                "{!r} — ambiguous which state applies".format(name)
            )
        seen_names.add(name)
        normalized.append((name, state))
    normalized.sort(key=lambda pair: pair[0])
    return tuple(normalized)


def progress_digest(change_digest, missing_requirements, evidence_state, policy_version):
    """진행 상태 지문 — 4요소 결합 (spec §3.7 `progress_digest` 정의).

    같은 4요소 조합은 항상 같은 문자열을 반환하는 순수 함수다(입력
    순서 무관 — `missing_requirements`/`evidence_state` 는 내부에서
    정규화한다). 프레이밍 마커 + 길이 프리픽스로 각 요소·각 원소를
    감싸 연접 충돌을 막는다(모듈 docstring 참조).

    - `change_digest`: 현재 ChangeSet digest 문자열(형태는 검증하지
      않는다 — kernel `changeset.changeset_digest` 산출물을 그대로
      받는 것을 기대하지만, 이 함수 자체는 비어있지 않은 str 이기만
      요구한다).
    - `missing_requirements`: requirement 이름의 컬렉션(순서 무관).
    - `evidence_state`: `{requirement_name: state_token_또는_None}` 매핑
      또는 동등한 쌍의 컬렉션.
    - `policy_version`: 현재 policy version 문자열.
    """
    change_digest = _require_nonempty_str("change_digest", change_digest)
    policy_version = _require_nonempty_str("policy_version", policy_version)
    missing = _normalize_missing_requirements(missing_requirements)
    evidence = _normalize_evidence_state(evidence_state)

    hasher = hashlib.new(_DIGEST_ALGORITHM)
    _feed_length_prefixed(hasher, _MARK_CHANGE_DIGEST, _encode(change_digest))

    hasher.update(_MARK_MISSING)
    hasher.update(len(missing).to_bytes(_LENGTH_PREFIX_BYTES, "big"))
    for item in missing:
        _feed_length_prefixed(hasher, _MARK_ITEM, _encode(item))

    hasher.update(_MARK_EVIDENCE)
    hasher.update(len(evidence).to_bytes(_LENGTH_PREFIX_BYTES, "big"))
    for name, state in evidence:
        _feed_length_prefixed(hasher, _MARK_ITEM, _encode(name))
        if state is None:
            hasher.update(_MARK_STATE_ABSENT)
        else:
            hasher.update(_MARK_STATE_PRESENT)
            hasher.update(len(_encode(state)).to_bytes(_LENGTH_PREFIX_BYTES, "big"))
            hasher.update(_encode(state))

    _feed_length_prefixed(hasher, _MARK_POLICY_VERSION, _encode(policy_version))

    return "{}:{}".format(_DIGEST_ALGORITHM, hasher.hexdigest())


# ---------------------------------------------------------------------------
# LoopSignal — record_attempt() 단일 반환값
# ---------------------------------------------------------------------------


class LoopSignal(object):
    """`record_attempt()` 1회 호출의 판정 결과.

    `signal` 은 `SIGNALS` 폐쇄 3종 중 하나다. 이 클래스는 kernel
    `Decision` 과 달리 `frozen dataclass` 로 만들지 않는다 — Decision
    의 폐쇄 3종(ALLOW/BLOCK/ASK_USER) 계약과 이 클래스의 폐쇄 3종
    (CONTINUE/ASK_USER/BUDGET_EXHAUSTED) 계약이 이름은 겹치되(ASK_USER)
    의미 지붕이 다르므로(Decision 은 "이 행동을 허용할지", LoopSignal 은
    "이 반복을 계속할지"), 별도 타입으로 유지해 혼동을 막는다.
    """

    __slots__ = (
        "signal",
        "attempt",
        "reason",
        "progress_digest",
        "repeat_count",
        "budget",
        "extended",
    )

    def __init__(
        self,
        signal,
        attempt,
        reason,
        progress_digest,
        repeat_count,
        budget,
        extended,
    ):
        if signal not in SIGNALS:
            raise LoopControllerError(
                "signal must be one of {} (LoopSignal SIGNALS), got "
                "{!r}".format(SIGNALS, signal)
            )
        self.signal = signal
        self.attempt = attempt
        self.reason = reason
        self.progress_digest = progress_digest
        self.repeat_count = repeat_count
        self.budget = budget
        self.extended = extended

    def to_dict(self):
        """직렬화 — 매 호출 새 dict (kernel `Decision.to_dict` 와 동일 관례)."""
        return {
            "signal": self.signal,
            "attempt": self.attempt,
            "reason": self.reason,
            "progress_digest": self.progress_digest,
            "repeat_count": self.repeat_count,
            "budget": self.budget,
            "extended": self.extended,
        }

    def __eq__(self, other):
        if not isinstance(other, LoopSignal):
            return NotImplemented
        return self.to_dict() == other.to_dict()

    def __repr__(self):
        return "LoopSignal({!r})".format(self.to_dict())


# ---------------------------------------------------------------------------
# 공유 정수 검증 헬퍼 — LoopController 와 스냅샷 복원(from_snapshot) 양쪽이
# 같은 규칙을 쓴다 (아래 참조).
# ---------------------------------------------------------------------------


def _validate_positive_int(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise LoopControllerError(
            "{} must be a positive int, got {!r}".format(label, value)
        )
    return value


def _validate_non_negative_int(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise LoopControllerError(
            "{} must be a non-negative int, got {!r}".format(label, value)
        )
    return value


def _validate_extension_history_entry(entry, index, default_budget, label):
    """extension 목록 항목 1건의 shape + `exceeds_default` 정합성 검증.

    코드리뷰 사이클 C 1차 High 대응 — "스냅샷 복원이 조용한 예산 연장을
    허용한다"(`budget=999` + `extension_history=[]` 스냅샷이 그대로
    복원됨)의 항목 단위 방어. 각 항목이 스스로 말이 되는지(양의 정수,
    `new_budget > previous_budget`)와 `exceeds_default` 필드가 실제
    `new_budget`/`default_budget` 관계와 일치하는지를 확인한다 —
    불일치는 관대하게 재계산해 덮어쓰지 않고 명시 예외로 거부한다
    (이 저장소의 "조용한 보정 금지" 규율, `_normalize_evidence_state`
    등 이 모듈의 다른 strict 검증과 동일 방향).

    `label` 은 에러 메시지에 쓰이는 소속 목록의 이름(예:
    `"snapshot['extension_history']"` 또는 `"approved_extensions"`) —
    3차 High 수정으로 이 함수가 스냅샷의 이력뿐 아니라 호출자가 공급하는
    승인 목록에도 동일 규율로 적용되면서 하드코딩을 없앴다.

    체인 연속성(이 항목의 `previous_budget` 이 직전 항목의 `new_budget`
    과 이어지는지)과 시간 단조성(at_attempt 비감소)은 항목 하나만으로는
    판정할 수 없으므로 호출자(`_validate_and_chain_extension_history`)가
    순회하며 검증한다. 검증을 통과한 필드만 담은 새 dict 를 반환한다 —
    호출자가 원본 미검증 dict 를 그대로 내부 상태에 흘려보내지 않게.
    """
    if not isinstance(entry, dict):
        raise LoopControllerError(
            "{}[{}] must be a dict, got {!r}".format(label, index, entry)
        )
    required_keys = {
        "previous_budget",
        "new_budget",
        "exceeds_default",
        "reason",
        "at_attempt",
    }
    missing = required_keys - set(entry)
    if missing:
        raise LoopControllerError(
            "{}[{}] is missing keys: {}".format(label, index, sorted(missing))
        )
    previous_budget = _validate_positive_int(
        entry["previous_budget"],
        "{}[{}]['previous_budget']".format(label, index),
    )
    new_budget = _validate_positive_int(
        entry["new_budget"], "{}[{}]['new_budget']".format(label, index)
    )
    if new_budget <= previous_budget:
        raise LoopControllerError(
            "{}[{}] must have new_budget > previous_budget (extension "
            "only ever increases the budget), got previous={} "
            "new={}".format(label, index, previous_budget, new_budget)
        )
    at_attempt = _validate_non_negative_int(
        entry["at_attempt"], "{}[{}]['at_attempt']".format(label, index)
    )
    exceeds_default = entry["exceeds_default"]
    if not isinstance(exceeds_default, bool):
        raise LoopControllerError(
            "{}[{}]['exceeds_default'] must be a bool, got "
            "{!r}".format(label, index, exceeds_default)
        )
    expected_exceeds_default = new_budget > default_budget
    if exceeds_default != expected_exceeds_default:
        raise LoopControllerError(
            "{}[{}]['exceeds_default'] ({}) does not match the "
            "recomputed value ({}) for new_budget={} vs "
            "default_budget={} — forged/stale metadata is rejected "
            "rather than silently recomputed".format(
                label,
                index,
                exceeds_default,
                expected_exceeds_default,
                new_budget,
                default_budget,
            )
        )
    reason = entry["reason"]
    if reason is not None and not isinstance(reason, str):
        raise LoopControllerError(
            "{}[{}]['reason'] must be None or a str, got "
            "{!r}".format(label, index, reason)
        )
    return {
        "previous_budget": previous_budget,
        "new_budget": new_budget,
        "exceeds_default": exceeds_default,
        "reason": reason,
        "at_attempt": at_attempt,
    }


def _validate_and_chain_extension_history(raw_history, label, default_budget):
    """extension 목록 하나를 shape + 체인 연속성 + 시간 단조성으로 검증한다.

    `_validate_extension_history_entry` 로 항목 각각을 검증한 뒤, 이
    함수가 항목 사이의 관계를 검증한다: 각 항목의 `previous_budget`
    이 직전 항목의 `new_budget`(첫 항목은 `default_budget`)과 이어지는
    체인 연속성, 그리고 `at_attempt` 가 비감소(non-decreasing)하는
    시간 단조성. `attempt_count` 상한 검사는 호출 시점에 그 값을 아직
    모를 수 있으므로 이 함수의 책임이 아니다 — 호출자
    (`LoopController.from_snapshot`)가 반환된 정규화 리스트를 다시
    순회하며 검사한다.

    반환값: `(정규화된 리스트, 최종 budget, 최종 at_attempt)`. 빈
    `raw_history` 는 `(  (), default_budget, 0  )` — 연장이 없는
    기준선 그대로.
    """
    if not isinstance(raw_history, (list, tuple)):
        raise LoopControllerError(
            "{} must be a list of extension entries, got {!r}".format(
                label, raw_history
            )
        )
    running_budget = default_budget
    running_at_attempt = 0
    normalized = []
    for index, raw_entry in enumerate(raw_history):
        entry = _validate_extension_history_entry(
            raw_entry, index, default_budget, label
        )
        if entry["previous_budget"] != running_budget:
            raise LoopControllerError(
                "{}[{}]['previous_budget'] ({}) does not match the "
                "running budget after prior entries ({}) — {} must "
                "form an unbroken chain starting from default_budget "
                "({})".format(
                    label,
                    index,
                    entry["previous_budget"],
                    running_budget,
                    label,
                    default_budget,
                )
            )
        if entry["at_attempt"] < running_at_attempt:
            raise LoopControllerError(
                "{}[{}]['at_attempt'] ({}) is less than the previous "
                "entry's at_attempt ({}) — {} must be chronologically "
                "non-decreasing (an extension cannot be recorded before "
                "an earlier one)".format(
                    label, index, entry["at_attempt"], running_at_attempt, label
                )
            )
        running_budget = entry["new_budget"]
        running_at_attempt = entry["at_attempt"]
        normalized.append(entry)
    return tuple(normalized), running_budget, running_at_attempt


# ---------------------------------------------------------------------------
# LoopController
# ---------------------------------------------------------------------------


class LoopController(object):
    """No Progress Detection + Absolute Attempt Budget 통합 (spec §3.7 §22).

    인스턴스 상태만 사용한다 — 외부 카운터 파일을 참조/증가시키지 않는다
    (모듈 docstring "카운터 단일성" 절, plan Task 4.6 Step 1(c)).

    판정 우선순위(같은 `record_attempt` 호출에서 두 조건이 동시에
    성립하는 경계 — 같은 digest 가 반복되면서 그 시도가 마침 budget
    도 소진하는 경우): No Progress(교착)가 Budget Exhausted 보다
    **먼저** 확인된다. 교착은 "다음 시도를 반복해도 소용없다"는 더
    구체적인 원인이고, 예산 소진은 "반복 자체는 유효했으나 리소스를
    다 썼다"는 덜 구체적인 원인이므로, 더 구체적인 진단을 우선
    보고한다.

    budget 소진 판정 시점: attempt 번호가 현재 budget 에 **도달한
    시점의 그 호출 자체**가 `SIGNAL_BUDGET_EXHAUSTED` 를 반환한다(예:
    budget=5 면 5번째 `record_attempt` 호출이 예산 소진을 보고한다) —
    "budget 개까지 시도를 허용하고, 그 마지막 시도 결과에서 더 이상
    갈 곳이 없음을 즉시 알린다"는 설계다. budget+1 번째의 별도
    "낭비되는" 호출을 요구하지 않는다(v1 이 "상한 도달 후 호출은 수행
    이전에 거부"했던 것과 동일 방향 — 상한을 넘는 실질적인 추가
    시도를 만들지 않는다).
    """

    def __init__(
        self,
        budget=DEFAULT_ATTEMPT_BUDGET,
        no_progress_threshold=DEFAULT_NO_PROGRESS_THRESHOLD,
    ):
        self._default_budget = self._validate_budget(budget, "budget")
        self._budget = self._default_budget
        self._no_progress_threshold = self._validate_threshold(
            no_progress_threshold
        )
        self._attempt_count = 0
        self._last_digest = None
        self._repeat_count = 0
        self._extension_history = []

    @staticmethod
    def _validate_budget(value, label):
        return _validate_positive_int(value, label)

    @staticmethod
    def _validate_threshold(value):
        if isinstance(value, bool) or not isinstance(value, int) or value < 2:
            raise LoopControllerError(
                "no_progress_threshold must be an int >= 2 (a single "
                "observation cannot be a 'repeat'), got {!r}".format(value)
            )
        return value

    # -- 조회 전용 프로퍼티 --------------------------------------------

    @property
    def attempt_count(self):
        return self._attempt_count

    @property
    def budget(self):
        return self._budget

    @property
    def default_budget(self):
        return self._default_budget

    @property
    def no_progress_threshold(self):
        return self._no_progress_threshold

    @property
    def extension_history(self):
        """연장 이력의 읽기 전용 사본 (조용한 연장 경로 없음 원칙)."""
        return tuple(dict(entry) for entry in self._extension_history)

    # -- 연장 -------------------------------------------------------------

    def extend_budget(self, new_budget, reason=None):
        """명시 연장 — 정수 한도, 기본 상한 초과분은 이력에 노출한다.

        v1 관례(`scripts/rein-codex-review.sh` "Review round budget"
        절의 `[MAX_ROUNDS:]` 마커)의 "연장은 항상 stderr 경고 + 카운터
        파일 이력으로 남는다 — 조용한 연장 경로 없음" 원칙을 흡수한다
        — 여기서는 `extension_history` 로 노출한다. 환경변수 등 다른
        경로로 조용히 budget 을 올리는 진입점은 이 클래스에 없다
        (v1 의 "REIN_ROUND_LIMIT_DEFAULT=999" 조용한 무력화 실증과
        같은 함정을 반복하지 않는다).
        """
        new_budget = self._validate_budget(new_budget, "new_budget")
        if new_budget <= self._budget:
            raise LoopControllerError(
                "extend_budget must increase the budget — current={}, "
                "requested={}".format(self._budget, new_budget)
            )
        entry = {
            "previous_budget": self._budget,
            "new_budget": new_budget,
            "exceeds_default": new_budget > self._default_budget,
            "reason": reason,
            "at_attempt": self._attempt_count,
        }
        self._extension_history.append(entry)
        self._budget = new_budget
        return dict(entry)

    # -- 시도 기록 ----------------------------------------------------

    def record_attempt(
        self, change_digest, missing_requirements, evidence_state, policy_version
    ):
        """시도 1건을 기록하고 `LoopSignal` 판정을 반환한다 (spec §3.7).

        계수는 이 인스턴스 안에서만 증가한다(카운터 단일성). 매 호출은
        `attempt_count` 를 1 증가시키고, 이번 호출의 `progress_digest`
        가 직전 호출과 같으면 `repeat_count` 를 이어서 증가시키고,
        다르면 1로 리셋한다(새 진행이 관측됐으므로 교착 관측이
        끊긴다).
        """
        digest = progress_digest(
            change_digest, missing_requirements, evidence_state, policy_version
        )
        self._attempt_count += 1
        if digest == self._last_digest:
            self._repeat_count += 1
        else:
            self._last_digest = digest
            self._repeat_count = 1

        if self._repeat_count >= self._no_progress_threshold:
            return LoopSignal(
                signal=SIGNAL_ASK_USER,
                attempt=self._attempt_count,
                reason=(
                    "identical progress_digest observed {} times in a row "
                    "(no-progress threshold {})".format(
                        self._repeat_count, self._no_progress_threshold
                    )
                ),
                progress_digest=digest,
                repeat_count=self._repeat_count,
                budget=self._budget,
                extended=bool(self._extension_history),
            )

        if self._attempt_count >= self._budget:
            return LoopSignal(
                signal=SIGNAL_BUDGET_EXHAUSTED,
                attempt=self._attempt_count,
                reason=(
                    "attempt budget exhausted ({} of {}) — progress digest "
                    "kept changing but the absolute attempt limit was "
                    "reached".format(self._attempt_count, self._budget)
                ),
                progress_digest=digest,
                repeat_count=self._repeat_count,
                budget=self._budget,
                extended=bool(self._extension_history),
            )

        return LoopSignal(
            signal=SIGNAL_CONTINUE,
            attempt=self._attempt_count,
            reason="attempt {} of {} within budget, progress observed".format(
                self._attempt_count, self._budget
            ),
            progress_digest=digest,
            repeat_count=self._repeat_count,
            budget=self._budget,
            extended=bool(self._extension_history),
        )

    # -- 스냅샷 왕복 (모듈 docstring "저장" 절) --------------------------

    def snapshot(self):
        """직렬화 가능 dict 스냅샷 — 영속화는 storage 계층 소관(spec §3.8)."""
        return {
            "default_budget": self._default_budget,
            "budget": self._budget,
            "no_progress_threshold": self._no_progress_threshold,
            "attempt_count": self._attempt_count,
            "last_digest": self._last_digest,
            "repeat_count": self._repeat_count,
            "extension_history": [
                dict(entry) for entry in self._extension_history
            ],
        }

    @classmethod
    def from_snapshot(
        cls,
        snapshot,
        default_budget=DEFAULT_ATTEMPT_BUDGET,
        no_progress_threshold=DEFAULT_NO_PROGRESS_THRESHOLD,
        approved_extensions=(),
    ):
        """스냅샷 dict 로부터 controller 를 재구성한다 — 계수는 이어진다.

        카운터 단일성(plan Task 4.6 Step 1(c)) 계약의 왕복 축: 스냅샷을
        만들고 이 클래스로 복원해도 `attempt_count`/`repeat_count` 는
        저장 시점 값에서 그대로 이어진다 — 외부 카운터가 별도로
        진행되는 경로가 없다는 것을 직렬화 왕복으로도 보인다.

        **조용한 예산 위조 방어, 1차 (코드리뷰 사이클 C 1차 High)**:
        `snapshot['budget']` 은 `default_budget` 에서 시작해
        `extension_history` 를 순서대로 적용한 결과와 정확히 일치해야
        한다.

        **신뢰 기준선은 호출자가 공급, 2차 (코드리뷰 사이클 C 2차
        High)**: `default_budget`/`no_progress_threshold` 인자가 이
        controller 의 기준선 **정본**이다 — `snapshot` 안의 동명
        필드는 감사용으로만 남아있고, 이 인자와 일치하지 않으면 거부한다.

        **연장 권위도 호출자가 공급, 3차 (코드리뷰 사이클 C 3차 High)**:
        1·2차 수정은 `budget`·`default_budget` 을 각각 외부 기준과
        대조했지만, `extension_history` **내용 자체**의 정당성은 여전히
        스냅샷 내부 자기 일관성(체인 연속성·단조성)만으로 판정하고
        있었다 — 공격자가 `default_budget=5`(신뢰 기준과 일치) +
        자기 일관된 `extension_history=[{previous_budget:5,
        new_budget:999, ...}]` + `budget=999` 를 함께 구성하면, 모든
        내부 정합성 검사를 통과하면서도 실제로는 아무도 승인하지 않은
        연장이 복원됐다. 자기 일관성은 진위(authenticity)를 보장하지
        않는다 — kernel `evidence.py` 가 "서명이 아니라 원장 대조"로
        Evidence 발급을 검증하듯, 여기서도 스냅샷 내부 데이터만으로는
        부족하고 **스냅샷 밖의 근거**가 있어야 한다. `approved_extensions`
        인자가 그 근거다 — 호출자(Runtime/storage 배선 코드)가 자신의
        신뢰 기록(예: `extend_budget()` 호출을 실제로 수행한 시점에
        별도로 남긴 감사 로그)에서 공급하는, 실제로 승인된 연장 목록이다.
        `snapshot['extension_history']` 는 이 목록과 **정규화 후
        완전히 일치**해야 복원되고(길이·순서·모든 필드 값 동일), 불일치는
        명시 거부한다. 기본값 `()`(빈 목록)는 "이 세션에서 승인된 연장이
        없다"를 뜻하므로, 연장이 전혀 없었던 스냅샷만 인자 생략으로
        복원할 수 있다 — 연장이 있었던 세션은 호출자가 반드시
        `approved_extensions` 를 명시해야 한다. 최종 `_budget`/
        `_extension_history` 는 스냅샷이 아니라 이 **승인 목록에서
        재계산**한 값을 쓴다(`snapshot['budget']`/`extension_history`
        필드는 그 재계산값과 **일치하는지 검증하는 용도로만** 소비된다) —
        스냅샷 필드를 직접 신뢰하는 경로를 아예 남기지 않는다.

        **카운터(attempt_count/repeat_count) 신뢰 경계**: 위 세 차례
        수정과 달리 `attempt_count`/`repeat_count` 자체의 하향 위조는
        이 함수가 검증할 수 없다 — `record_attempt()` 가 실제로 몇 번
        호출됐는지에 대한 외부 원장이 없다(연장은 "승인"이라는 별도
        사건이 있어 캡처할 수 있지만, 매 시도는 그 자체가 유일한
        사건이라 스냅샷 밖에 대조할 것이 없다). 이 모듈의 신뢰 경계는
        스냅샷 저장 파일이 **Runtime 소유의 로컬 상태**라는 전제에
        있다(spec §3.8: 로컬 로그·ledger 는 0600 으로 생성 — Evidence
        정본 파일과 동일한 신뢰 계급) — 그 파일을 직접 위조·삭제하는
        행위는 spec §2.2 위협 모델("정직한 에이전트 규율")이 다루는
        범위 밖이다. 대신 이 함수는 **형식 하한(구조적 모순) 검증**만
        수행한다: `attempt_count == 0` 이면 `repeat_count`/`last_digest`
        도 미시작 상태여야 하고, `attempt_count > 0` 이면
        `1 <= repeat_count <= attempt_count` 여야 하며(반복은 전체
        시도 수를 넘을 수 없고, 시도가 있었다면 반복 계수는 최소
        1이다), 모든 `extension_history` 항목의 `at_attempt` 는
        `attempt_count` 를 넘을 수 없다(`attempt_count ≥ max(at_attempt)`
        — 자기 자신과 모순되는 스냅샷은 거부하지만, 진짜 낮은 값으로
        조작된 스냅샷을 탐지하지는 못한다는 한계는 그대로 남는다).

        불일치·malformed 데이터는 관대하게 보정하지 않고 명시 예외로
        거부한다(이 저장소의 "조용한 보정 금지" 규율).

        **snapshot 타입 검증 (코드리뷰 사이클 C 4차 Low)**: `snapshot`
        이 `dict` 가 아니면(`None`·정수·문자열 등) 아래 키 조회에서
        `LoopControllerError` 가 아닌 원시 `TypeError`(`argument of
        type 'X' is not iterable` 류)가 새어나갔다 — 이 모듈의 다른
        모든 malformed-입력 경로와 달리 호출자가 `LoopControllerError`
        하나만 잡으면 되는 계약이 깨지는 지점이었다. 맨 앞에서
        `isinstance(snapshot, dict)` 를 확인해 항상 `LoopControllerError`
        로 통일한다.
        """
        if not isinstance(snapshot, dict):
            raise LoopControllerError(
                "snapshot must be a dict, got {!r} (type {})".format(
                    snapshot, type(snapshot).__name__
                )
            )

        default_budget = _validate_positive_int(default_budget, "default_budget")
        no_progress_threshold = cls._validate_threshold(no_progress_threshold)

        # 호출자가 공급하는 승인 연장 목록 — 이 목록 자체도(호출자의
        # 버그 방어 차원에서) shape·체인·단조성을 검증한다. 이 값이
        # 이후 budget/extension_history 의 유일한 정본이다.
        normalized_approved, approved_final_budget, _approved_final_at_attempt = (
            _validate_and_chain_extension_history(
                approved_extensions, "approved_extensions", default_budget
            )
        )

        required_keys = (
            "default_budget",
            "no_progress_threshold",
            "budget",
            "attempt_count",
            "last_digest",
            "repeat_count",
            "extension_history",
        )
        missing_keys = [key for key in required_keys if key not in snapshot]
        if missing_keys:
            raise LoopControllerError(
                "snapshot is missing required key(s): {}".format(
                    ", ".join(repr(key) for key in missing_keys)
                )
            )

        # 신뢰 기준선 일치 검증 — 스냅샷 필드는 감사용, 정본은 호출자
        # 인자다 (모듈 docstring "신뢰 기준선은 호출자가 공급" 절).
        if snapshot["default_budget"] != default_budget:
            raise LoopControllerError(
                "snapshot['default_budget'] ({!r}) does not match the "
                "trusted default_budget supplied by the caller ({!r}) "
                "— the baseline budget is a code/policy value, not a "
                "snapshot field the snapshot itself can redefine. If "
                "the configured budget genuinely changed, construct a "
                "fresh LoopController with the new default instead of "
                "restoring this snapshot.".format(
                    snapshot["default_budget"], default_budget
                )
            )
        if snapshot["no_progress_threshold"] != no_progress_threshold:
            raise LoopControllerError(
                "snapshot['no_progress_threshold'] ({!r}) does not "
                "match the trusted no_progress_threshold supplied by "
                "the caller ({!r}) — same trust-anchor principle as "
                "default_budget.".format(
                    snapshot["no_progress_threshold"], no_progress_threshold
                )
            )

        declared_budget = _validate_positive_int(
            snapshot["budget"], "snapshot['budget']"
        )
        attempt_count = _validate_non_negative_int(
            snapshot["attempt_count"], "snapshot['attempt_count']"
        )
        repeat_count = _validate_non_negative_int(
            snapshot["repeat_count"], "snapshot['repeat_count']"
        )
        last_digest = snapshot["last_digest"]

        # 카운터 구조적 하한 검증 (모듈 docstring "카운터 신뢰 경계" 절
        # — 진위 검증이 아니라 자기모순 검출).
        if attempt_count == 0:
            if repeat_count != 0:
                raise LoopControllerError(
                    "snapshot['repeat_count'] ({}) must be 0 when "
                    "snapshot['attempt_count'] is 0 — no attempt has "
                    "happened yet, so there is nothing to "
                    "repeat".format(repeat_count)
                )
            if last_digest is not None:
                raise LoopControllerError(
                    "snapshot['last_digest'] ({!r}) must be None when "
                    "snapshot['attempt_count'] is 0 — no attempt has "
                    "been recorded yet".format(last_digest)
                )
        else:
            if not (1 <= repeat_count <= attempt_count):
                raise LoopControllerError(
                    "snapshot['repeat_count'] ({}) is structurally "
                    "inconsistent with snapshot['attempt_count'] ({}) "
                    "— repeat_count must be between 1 and "
                    "attempt_count once at least one attempt has been "
                    "recorded".format(repeat_count, attempt_count)
                )
            if not isinstance(last_digest, str) or not last_digest:
                raise LoopControllerError(
                    "snapshot['last_digest'] must be a non-empty str "
                    "once snapshot['attempt_count'] > 0, got "
                    "{!r}".format(last_digest)
                )

        # 스냅샷의 이력 자체도 독립적으로 shape·체인·단조성 검증한다
        # (승인 목록과 별개로 — 구체적인 malformed-entry 진단을 위해).
        normalized_snapshot_history, _snapshot_final_budget, _snapshot_final_at_attempt = (
            _validate_and_chain_extension_history(
                snapshot["extension_history"],
                "snapshot['extension_history']",
                default_budget,
            )
        )

        for label, normalized_list in (
            ("approved_extensions", normalized_approved),
            ("snapshot['extension_history']", normalized_snapshot_history),
        ):
            for index, entry in enumerate(normalized_list):
                if entry["at_attempt"] > attempt_count:
                    raise LoopControllerError(
                        "{}[{}]['at_attempt'] ({}) exceeds "
                        "snapshot['attempt_count'] ({}) — an extension "
                        "cannot be recorded at an attempt that hasn't "
                        "happened yet".format(
                            label, index, entry["at_attempt"], attempt_count
                        )
                    )

        # 핵심 3차 수정 — 자기 일관성만으로는 부족하다. 스냅샷의 이력이
        # 호출자가 실제로 승인한 목록과 정확히 같아야만 복원을 허용한다.
        if normalized_snapshot_history != normalized_approved:
            raise LoopControllerError(
                "snapshot['extension_history'] does not match the "
                "caller-approved extensions ({!r} vs {!r}) — internal "
                "self-consistency is not sufficient corroboration for "
                "an extension; it must also appear in the caller's own "
                "trusted approved_extensions record. A snapshot with no "
                "corroborating approved_extensions can only restore an "
                "empty extension_history.".format(
                    normalized_snapshot_history, normalized_approved
                )
            )

        # budget 은 승인 목록에서 재계산한 값이 정본 — snapshot['budget']
        # 필드는 그 값과 일치하는지 검증하는 용도로만 쓰인다.
        if declared_budget != approved_final_budget:
            raise LoopControllerError(
                "snapshot['budget'] ({}) does not match default_budget "
                "({}) plus the caller-approved extension_history chain "
                "result ({}) — a budget value not backed by a recorded, "
                "caller-approved extension is rejected (no silent "
                "extension via snapshot restore, mirrors "
                "extend_budget's 'no silent extension' "
                "contract)".format(
                    declared_budget, default_budget, approved_final_budget
                )
            )

        controller = cls(
            budget=default_budget, no_progress_threshold=no_progress_threshold
        )
        controller._budget = approved_final_budget
        controller._attempt_count = attempt_count
        controller._last_digest = last_digest
        controller._repeat_count = repeat_count
        controller._extension_history = list(normalized_approved)
        return controller
