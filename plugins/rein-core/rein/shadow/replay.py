"""Shadow Replay — v1 vs v2 decision 대조 + mismatch 4분류 (plan Task 3.4).

spec §6.4 / brainstorm §47:
    "Mismatch 4분류: v2 bug / v1 bug / intentional policy change /
    insufficient case data"
spec §6.4 / brainstorm §48 (Migration Acceptance):
    "고정 절대 수치 계약 금지. Contract/Bypass/E2E PASS + 위험한
    false-allow 불허 방향 + mismatch 원인 분류."

핵심 계약 — **리포트에 미분류 mismatch 0건**: 분류가 누락된 mismatch
가 하나라도 있으면 리포트 생성이 `UnclassifiedMismatchError` 로
실패한다. 조용한 부분 리포트(미분류 건을 빼고 만든 리포트)는 이 모듈
어디에도 존재하지 않는다 — 실패는 항상 명시 예외로 드러난다
(`corpus.py` 의 "거부는 조용한 필터링이 아니다" 철학과 동일).

분류 입력 계약:
- 분류 어휘 4종은 `CLASSIFICATIONS` 로 폐쇄 — 밖의 값은
  `UnknownClassificationError` (미지 분류값 거부).
- 분류 key 는 corpus JSONL 의 줄 번호 기반 `case_key(line_number)`
  (`"line:N"`). corpus 는 전환 판단 시점에 동결되므로(spec §48) 줄
  번호가 안정적인 식별자다.
- mismatch 가 아닌 case(match·부재 줄)를 가리키는 분류 key 는
  `DanglingClassificationError` — 분류 입력이 corpus 와 어긋난 채
  조용히 소비되는 드리프트를 막는다.
- 명시 분류는 자동 분류(insufficient case data)보다 우선한다 —
  리뷰어가 결손 case 의 원인을 다른 분류로 판정했으면 그쪽이 정본.

insufficient case data 자동 분류 기준 (이 모듈의 설계 결정 — v2 평가
`runtime.evaluate(event, facts, …)` 와 v1 대조에 필요한 최소 재료):
- `event` 부재 / 비문자열 / 빈 문자열
- `facts` 부재 / mapping 아님
- `v1_decision` 부재 / ALLOW·BLOCK·ASK_USER 밖의 값 (대조 불능)
결손 case 는 v2 평가를 수행하지 않고(`v2_decision=None`) mismatch 로
집계된다 — "모든 case 는 match 이거나 분류된 mismatch" 불변식으로
남김없음(spec §47)을 유지한다.

위험한 false-allow 방향 (spec §48): v1 BLOCK → v2 ALLOW 만 위험
방향이다 — v1 이 막던 것을 v2 가 통과시키는 방향. spec 이 이
방향(BLOCK ↔ ALLOW)만 명시하므로 ASK_USER → ALLOW 는 위험 집계에
넣지 않는다(일반 mismatch 로만 분류). 리포트는 이 방향을
`dangerous_false_allow` 로 별도 표기·집계한다.

Migration Acceptance 원칙 (spec §48): 이 모듈은 고정 절대 수치
임계(예: "일치율 N% 이상")를 갖지 않는다. 리포트는 집계·분류 사실만
담고 합격/불합격 판정 필드를 내지 않는다 — 전환 판단은 리포트를 읽는
사람/상위 절차의 몫이다.

corpus 파일은 **읽기 전용**이다 — 이 모듈은 어떤 경로로도 corpus 에
쓰지 않는다. 리포트에는 corpus 경로를 싣지 않는다(직렬화 산출물에
사적 절대경로가 흘러들어가는 것을 원천 차단 — `corpus.py` private
path 규율과 정합).

outcome 입력 신뢰 경계 (웨이브 3 코드 리뷰 1회차 High 수정):
`build_report()` 는 공개 표면이므로 호출자가 손수 조립한 outcome 도
받을 수 있다 — 호출자 제공 match 판정을 신뢰하면 "BLOCK→ALLOW 인데
matched=True" 주입으로 미분류 0건 계약이 조용히 우회된다(리뷰어
실증). 봉쇄는 두 겹이다:
1. outcome 스키마에 match 판정 슬롯 자체가 없다 — `_replay_case` 도
   `matched` 를 내지 않는다(capture.py 의 "raw command 필드 부재"
   와 같은 구조적 보장). match 는 `build_report()` 가 v1_decision vs
   v2_decision 으로 **항상 재계산**한다.
2. outcome 은 폐쇄 스키마(`_OUTCOME_FIELDS` 7필드)로 검증된다 —
   미지 필드(`matched` 포함)·결손 필드·decision 어휘 밖 값·중복
   case_key 전부 `OutcomeSchemaError` 명시 예외 (관대한 보정 금지,
   corpus 로더 규율과 동일).
"""
import json

from rein.engine import runtime
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK, DECISIONS

__all__ = [
    "CLASSIFICATION_V2_BUG",
    "CLASSIFICATION_V1_BUG",
    "CLASSIFICATION_INTENTIONAL_POLICY_CHANGE",
    "CLASSIFICATION_INSUFFICIENT_CASE_DATA",
    "CLASSIFICATIONS",
    "ReplayError",
    "CorpusFormatError",
    "OutcomeSchemaError",
    "UnknownClassificationError",
    "DanglingClassificationError",
    "UnclassifiedMismatchError",
    "case_key",
    "load_corpus",
    "replay_corpus",
    "build_report",
    "generate_report",
]

# spec §6.4 / brainstorm §47 — mismatch 4분류. 이 4종 밖의 분류값은
# 어디서도 만들어지지 않고(`build_report` 가 거부), 여기 정의가 유일한
# 정본이다 (폐쇄 어휘 — kernel/decision.py DECISIONS 와 같은 패턴).
CLASSIFICATION_V2_BUG = "v2 bug"
CLASSIFICATION_V1_BUG = "v1 bug"
CLASSIFICATION_INTENTIONAL_POLICY_CHANGE = "intentional policy change"
CLASSIFICATION_INSUFFICIENT_CASE_DATA = "insufficient case data"
CLASSIFICATIONS = (
    CLASSIFICATION_V2_BUG,
    CLASSIFICATION_V1_BUG,
    CLASSIFICATION_INTENTIONAL_POLICY_CHANGE,
    CLASSIFICATION_INSUFFICIENT_CASE_DATA,
)


class ReplayError(ValueError):
    """replay/리포트 생성 계약 위반의 공통 기반 — 전부 명시 실패."""


class CorpusFormatError(ReplayError):
    """corpus JSONL 줄이 JSON object 가 아님 — 조용한 부분 로드 금지."""


class OutcomeSchemaError(ReplayError):
    """outcome 이 폐쇄 스키마를 벗어남 — 리포트를 만들지 않고 명시 실패.

    미지 필드(구 `matched` 슬롯 포함)·결손 필드·decision 어휘 밖 값·
    중복 case_key 가 여기 걸린다 (모듈 docstring "outcome 입력 신뢰
    경계" 참조).
    """


class UnknownClassificationError(ReplayError):
    """분류 입력 값이 폐쇄 4분류(`CLASSIFICATIONS`) 밖 — 거부."""


class DanglingClassificationError(ReplayError):
    """분류 입력 key 가 어떤 mismatch 에도 대응하지 않음 — 입력 드리프트."""


class UnclassifiedMismatchError(ReplayError):
    """분류 없는 mismatch 존재 — 리포트 생성 실패 (핵심 계약, spec §47).

    `case_keys` 에 미분류 mismatch 의 식별 key 목록을 담아 올린다 —
    호출부가 어떤 case 의 분류가 빠졌는지 바로 알 수 있게.
    """

    def __init__(self, case_keys):
        self.case_keys = sorted(case_keys)
        super().__init__(
            "report generation refused — {} unclassified mismatch(es): "
            "{}".format(len(self.case_keys), ", ".join(self.case_keys))
        )


def case_key(line_number):
    """corpus JSONL 줄 번호(1-기반) → mismatch 식별 key (`"line:N"`).

    corpus 는 전환 판단 시점에 동결되므로(spec §48) 줄 번호가 안정적인
    식별자다 — 동결 이후의 edge case 는 corpus 수정이 아니라 regression
    테스트로 추가된다.
    """
    return "line:{}".format(int(line_number))


def load_corpus(corpus_path):
    """corpus JSONL 을 읽기 전용으로 로드 — `(line_number, case)` 목록.

    빈 줄(공백뿐인 줄)은 데이터가 아니므로 건너뛴다. JSON 파싱 실패
    또는 object 아닌 줄은 `CorpusFormatError` — 깨진 줄을 조용히 빼고
    로드하면 그 줄의 mismatch 가능성이 리포트에서 증발하므로(부분
    리포트 금지 계약의 로드 단계 대응) 전체 로드를 명시 실패시킨다.
    """
    entries = []
    with open(corpus_path, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                case = json.loads(text)
            except ValueError as error:
                raise CorpusFormatError(
                    "corpus line {} is not valid JSON: {}".format(
                        line_number, error
                    )
                )
            if not isinstance(case, dict):
                raise CorpusFormatError(
                    "corpus line {} must be a JSON object, got {}".format(
                        line_number, type(case).__name__
                    )
                )
            entries.append((line_number, case))
    return entries


def _insufficiency(case):
    """v2 평가·대조 최소 재료 검사 — 결손 사유 문자열 또는 None.

    기준은 모듈 docstring "insufficient case data 자동 분류 기준" 참조.
    사유 문자열은 고정 문구만 담는다 — case 의 값 원문을 반사하지
    않는다 (거부/결손 사유가 유출 경로가 되지 않게, corpus.py 라벨
    규율과 동일).
    """
    event = case.get("event")
    if not isinstance(event, str) or not event:
        return "event field is missing or not a non-empty string"
    if not isinstance(case.get("facts"), dict):
        return "facts field is missing or not a mapping"
    if case.get("v1_decision") not in DECISIONS:
        return "v1_decision is missing or outside {}".format(
            "/".join(DECISIONS)
        )
    return None


def _replay_case(line_number, case, policies, evidence_source, registry):
    """case 1건 replay — 대조 재료(outcome dict, 폐쇄 7필드) 반환.

    재료 결손 case 는 v2 평가를 수행하지 않는다(`v2_decision=None`) —
    자동 분류(insufficient case data) 대상 mismatch 로 집계된다.
    v2 평가 자체가 예외를 내면(판단 불능 전파 등) 그대로 올라간다 —
    조용히 삼켜 특정 분류로 위장하지 않는다.

    match 판정 필드는 여기 없다 — 판정은 `build_report()` 의 재계산
    단일 경로다 (모듈 docstring "outcome 입력 신뢰 경계").
    """
    key = case_key(line_number)
    reason = _insufficiency(case)
    if reason is not None:
        v1 = case.get("v1_decision")
        return {
            "case_key": key,
            "event": case.get("event") if isinstance(case.get("event"), str) else None,
            "v1_decision": v1 if v1 in DECISIONS else None,
            "v2_decision": None,
            "v2_reason": None,
            "insufficient": True,
            "insufficient_reason": reason,
        }
    result = runtime.evaluate(
        case["event"],
        dict(case["facts"]),
        policies,
        evidence_source=evidence_source,
        registry=registry,
    )
    return {
        "case_key": key,
        "event": case["event"],
        "v1_decision": case["v1_decision"],
        "v2_decision": result["decision"],
        "v2_reason": result["reason"],
        "insufficient": False,
        "insufficient_reason": None,
    }


def replay_corpus(corpus_path, policies, evidence_source=None, registry=None):
    """corpus 전 case 를 v2 로 replay 해 outcome 목록을 반환한다.

    `policies` 는 kernel/policy.py 로더 산출물 형태
    (`{"policy_id", "fields"}` 목록). v2 평가는 `runtime.evaluate`
    단일 진입점만 쓴다 — replay 가 자체 평가 경로를 만들지 않는다.
    """
    return [
        _replay_case(line_number, case, policies, evidence_source, registry)
        for line_number, case in load_corpus(corpus_path)
    ]


def _dangerous_false_allow(outcome):
    """위험한 false-allow 방향 판정 — v1 BLOCK → v2 ALLOW (spec §48)."""
    return (
        outcome["v1_decision"] == DECISION_BLOCK
        and outcome["v2_decision"] == DECISION_ALLOW
    )


# outcome 폐쇄 스키마 — `_replay_case` 산출 7필드가 유일한 형태다.
# match 판정 슬롯은 의도적으로 없다 (모듈 docstring "outcome 입력 신뢰
# 경계"). 미지 필드를 허용하면 `matched` 류 거짓 판정 필드가 다시
# 들어올 문을 열어두는 것이므로 집합 일치로 닫는다 (policy 로더의
# POLICY_FIELDS 폐쇄와 같은 패턴).
_OUTCOME_FIELDS = frozenset(
    {
        "case_key",
        "event",
        "v1_decision",
        "v2_decision",
        "v2_reason",
        "insufficient",
        "insufficient_reason",
    }
)


def _validate_outcome(outcome, position):
    """outcome 1건의 폐쇄 스키마 검증 — 위반은 `OutcomeSchemaError`.

    에러 라벨에는 위치 번호와 스키마 고정 필드명만 쓴다 — 호출자
    데이터(미지 key 원문·필드 값)는 반사하지 않는다 (`corpus.py` 의
    "라벨에는 caller 데이터가 절대 들어가지 않는다" 규율. 예외:
    case_key 는 분류 입력의 대응 key 라 진단에 필수인 식별자이며,
    `UnclassifiedMismatchError` 도 이미 반사하는 어휘다).
    """
    if not isinstance(outcome, dict):
        raise OutcomeSchemaError(
            "outcome #{} must be a mapping, got {}".format(
                position, type(outcome).__name__
            )
        )
    keys = set(outcome)
    missing = sorted(_OUTCOME_FIELDS - keys)
    unknown_count = len(keys - _OUTCOME_FIELDS)
    if missing or unknown_count:
        raise OutcomeSchemaError(
            "outcome #{} violates the closed schema — missing: {} / "
            "{} unknown field(s) (allowed fields: {})".format(
                position,
                missing or "none",
                unknown_count,
                ", ".join(sorted(_OUTCOME_FIELDS)),
            )
        )
    key = outcome["case_key"]
    if not isinstance(key, str) or not key:
        raise OutcomeSchemaError(
            "outcome #{}: case_key must be a non-empty string".format(position)
        )
    if not isinstance(outcome["insufficient"], bool):
        raise OutcomeSchemaError(
            "outcome #{}: insufficient must be a boolean".format(position)
        )
    if outcome["insufficient"]:
        # 결손 case 는 v2 평가를 수행하지 않았다는 뜻이다 — 평가 결과를
        # 실은 채 결손을 주장하면(실제 mismatch 은폐 시도 형태) 거부.
        if outcome["v2_decision"] is not None:
            raise OutcomeSchemaError(
                "outcome #{}: insufficient outcome must not carry a "
                "v2_decision".format(position)
            )
        if outcome["v1_decision"] is not None and (
            outcome["v1_decision"] not in DECISIONS
        ):
            raise OutcomeSchemaError(
                "outcome #{}: v1_decision must be None or one of {}".format(
                    position, "/".join(DECISIONS)
                )
            )
        reason = outcome["insufficient_reason"]
        if not isinstance(reason, str) or not reason:
            raise OutcomeSchemaError(
                "outcome #{}: insufficient outcome requires a non-empty "
                "insufficient_reason".format(position)
            )
    else:
        if outcome["v1_decision"] not in DECISIONS:
            raise OutcomeSchemaError(
                "outcome #{}: v1_decision must be one of {}".format(
                    position, "/".join(DECISIONS)
                )
            )
        if outcome["v2_decision"] not in DECISIONS:
            raise OutcomeSchemaError(
                "outcome #{}: v2_decision must be one of {}".format(
                    position, "/".join(DECISIONS)
                )
            )
        if outcome["insufficient_reason"] is not None:
            raise OutcomeSchemaError(
                "outcome #{}: insufficient_reason must be None when the "
                "outcome is not insufficient".format(position)
            )


def _validate_outcomes(outcomes):
    """전 outcome 스키마 검증 + case_key 중복 거부 (분류 대응 모호화 방지)."""
    seen = set()
    for position, outcome in enumerate(outcomes, start=1):
        _validate_outcome(outcome, position)
        key = outcome["case_key"]
        if key in seen:
            raise OutcomeSchemaError(
                "duplicate case_key {!r} — classification input would be "
                "ambiguous".format(key)
            )
        seen.add(key)


def _outcome_matched(outcome):
    """match 재계산 단일 경로 — 결손 case 는 항상 mismatch (자동 분류 대상).

    호출자 제공 판정 필드는 존재하지 않는다 — 스키마 검증이 이미
    거부했다 (웨이브 3 코드 리뷰 1회차 High 수정).
    """
    if outcome["insufficient"]:
        return False
    return outcome["v1_decision"] == outcome["v2_decision"]


def build_report(outcomes, classifications=None):
    """outcome 목록 + 분류 입력 → 직렬화 가능한 리포트 dict.

    match 는 호출자 판정이 아니라 이 함수의 v1_decision vs v2_decision
    **재계산**으로만 정해진다 (모듈 docstring "outcome 입력 신뢰 경계").

    실패 경로 (전부 명시 예외 — 리포트를 만들지 않는다):
    - outcome 폐쇄 스키마 위반(미지/결손 필드·decision 어휘 밖 값·
      중복 case_key) → `OutcomeSchemaError`
    - 폐쇄 4분류 밖의 분류값 → `UnknownClassificationError`
    - mismatch 아닌 case 를 가리키는 분류 key → `DanglingClassificationError`
    - 분류 없는 mismatch (자동 분류 불가 건) → `UnclassifiedMismatchError`

    리포트 필드: total_cases / matches / mismatches(분류 포함 상세) /
    classification_counts(4분류 key 항상 전부 존재) /
    dangerous_false_allow(위험 방향 별도 집계) /
    unclassified_mismatches(계약상 항상 0 — 0 이 아닐 수 있는 경로는
    존재하지 않고, 그 전에 예외로 실패한다). 합격/불합격 판정 필드는
    없다 (spec §48 — 고정 절대 수치 계약 금지).
    """
    outcomes = list(outcomes)
    classifications = dict(classifications or {})

    _validate_outcomes(outcomes)

    # 분류값 membership 검증이 어떤 정렬/집계보다 먼저다 (2회차 리뷰
    # Medium 수정): 이전엔 미지 raw 값을 set()+sorted() 로 모아 비문자열
    # (unhashable 포함)·혼합 타입 입력에서 명시 예외 대신 TypeError 가
    # 났다. membership 은 tuple `in` (== 비교, hash 불요)이라 어떤
    # 타입이든 안전하고, 보고용 수집·정렬은 raw 값이 아니라 repr 문자열
    # 로만 한다 — 항상 비교 가능하므로 어떤 입력에서도
    # `UnknownClassificationError` 가 보장된다.
    unknown_reprs = sorted(
        {
            repr(value)
            for value in classifications.values()
            if value not in CLASSIFICATIONS
        }
    )
    if unknown_reprs:
        raise UnknownClassificationError(
            "unknown classification value(s) {} — allowed: {}".format(
                ", ".join(unknown_reprs), ", ".join(CLASSIFICATIONS)
            )
        )

    mismatch_outcomes = [o for o in outcomes if not _outcome_matched(o)]
    mismatch_keys = {o["case_key"] for o in mismatch_outcomes}
    # key 측도 같은 TypeError 클래스 방어 — 비문자열 key 는 어떤
    # case_key(문자열)와도 불일치라 항상 dangling 인데, 문자열 dangling
    # 과 섞이면 raw 정렬이 깨진다. repr 로만 정렬·보고한다.
    dangling = sorted(
        (key for key in classifications if key not in mismatch_keys),
        key=repr,
    )
    if dangling:
        raise DanglingClassificationError(
            "classification key(s) {} do not refer to any mismatch".format(
                ", ".join(repr(key) for key in dangling)
            )
        )

    entries = []
    unclassified = []
    counts = {name: 0 for name in CLASSIFICATIONS}
    danger_keys = []
    for outcome in mismatch_outcomes:
        key = outcome["case_key"]
        explicit = classifications.get(key)
        if explicit is not None:
            classification = explicit
            auto_classified = False
        elif outcome["insufficient"]:
            classification = CLASSIFICATION_INSUFFICIENT_CASE_DATA
            auto_classified = True
        else:
            unclassified.append(key)
            continue
        dangerous = _dangerous_false_allow(outcome)
        if dangerous:
            danger_keys.append(key)
        counts[classification] += 1
        entries.append(
            {
                "case_key": key,
                "event": outcome["event"],
                "v1_decision": outcome["v1_decision"],
                "v2_decision": outcome["v2_decision"],
                "v2_reason": outcome["v2_reason"],
                "classification": classification,
                "auto_classified": auto_classified,
                "dangerous_false_allow": dangerous,
                "insufficient_reason": outcome["insufficient_reason"],
            }
        )
    if unclassified:
        raise UnclassifiedMismatchError(unclassified)

    return {
        "total_cases": len(outcomes),
        "matches": sum(1 for o in outcomes if _outcome_matched(o)),
        "mismatches": entries,
        "classification_counts": counts,
        "dangerous_false_allow": {
            "count": len(danger_keys),
            "case_keys": danger_keys,
        },
        "unclassified_mismatches": 0,
    }


def generate_report(
    corpus_path,
    policies,
    classifications=None,
    evidence_source=None,
    registry=None,
):
    """replay + 리포트 생성 단일 진입점 — `build_report` 계약 그대로."""
    return build_report(
        replay_corpus(
            corpus_path,
            policies,
            evidence_source=evidence_source,
            registry=registry,
        ),
        classifications=classifications,
    )
