"""평가 런타임 배선 (plan Task 1.7 — walking-skeleton 파서 대체).

Task 1.1 의 자체 파서(_parse_policy)는 삭제됐다:
- policy 로드 = kernel/policy.py 폐쇄 스키마 로더 단일 경로.
  PolicyLoadError 도 kernel.policy 의 단일 클래스를 re-export 한다 —
  동명 클래스 2개가 있으면 except 절이 다른 쪽 클래스를 조용히 못 잡는
  함정이 생기므로 정의를 하나로 유지한다. 미지 requirement 이름의 로드
  시점 거부는 로더가 수행한다 (Task 1.5 계약).
- 평가 = engine/evaluator.py (kernel Decision 모델 사용).

cli/bin 왕복 계약(Task 1.1)은 보존한다: load_policies(policy_dir) /
evaluate(event_name, facts, policies) 시그니처와 dict 반환.

**소비 예약 commit — 성공한 원자적 claim 이 ALLOW 의 전제조건이다**
(plan Task 4.5 사이클 C 재리뷰 2·3회차 High 시정):
`EvaluationContext.reserve_consumption`(engine/context.py 참조)이 모아둔
"cycle 이 ALLOW 로 끝나면 실행할 부수효과"는 이 함수가 최종 decision 을
확인한 뒤에만 실행한다 — `evaluator.evaluate()` 자신은 이 슬롯을 읽지도
쓰지도 않는다(Decision 반환 계약 그대로 유지). ALLOW 가 아니면
(BLOCK/ASK_USER) 예약을 그대로 버린다 — 아무 것도 호출하지 않는다.

**2회차→3회차 방향 교정 (중요)**: 2회차 구현은 ALLOW 일 때 예약된
`store.claim(key)` 를 전부 호출하되 **반환값과 예외를 모두 무시**했다
— 리뷰어가 실증한 결함: 동시에 평가된 두 cycle 이 같은 fingerprint 를
각자 예약한 뒤 커밋하면, `claim()` 이 한쪽에서 `False`(경합 패배) 를
반환하거나 예외를 던져도 그 cycle 은 여전히 ALLOW 를 반환했다 — "실제로
승인이 소비되지 않았는데도 마치 소비된 것처럼 ALLOW 가 나가는" 구멍
이었다(그리고 예외를 잡지 않아 uncaught 로 새는 별도 결함도 있었다 —
"예외가 전파되지 않는다"는 애초에 의도가 아니라 단순 누락이었다).
이 함수는 이제 **"이 cycle 이 예약한 모든 consumption 이 원자적으로
commit 에 성공했을 때만 ALLOW 를 유지한다"** 는 전제조건을 강제한다
(`_commit_pending_consumptions` 참조) — 하나라도 실패(반환 `False`
또는 예외)하면 fail-closed `BLOCK` 으로 decision 을 교체한다.

이 함수는 `store`/`key` 가 무엇을 의미하는지 모른다 — `store.claim(key)`
/`store.release(key)`/`store.is_consumed(key)` 호출만 안다(어떤
capability 도 import 하지 않는다, spec §3.1). `reason` 문자열에
"user_approval" 같은 이름을 언급하는 것은 순전히 사람이 읽을 로그
품질을 위한 것이지, import 나 타입 의존을 만들지 않는다 — 현재 이
예약 메커니즘을 쓰는 유일한 capability 가 `user_approval` 이라는
사실을 반영한 문자열일 뿐이다.

**4회차→5회차 Medium 교정**: 4회차는 "trigger 로 실패한 예약"과 "이미
성공했다가 롤백된 다른 예약들"의 상태를 reason 문자열 하나에
뭉뚱그렸다 — 경합에서 진(claim() == False) trigger 항목은 롤백할
필요가 애초에 없는데도(그 항목은 한 번도 성공한 적이 없다), 롤백할
다른 항목이 없으면 무조건 "the approval itself is preserved" 라고
말해버려서, "경합 패배 = 이미 다른 쪽에 소비됨" 이라는 사실과
모순되는 보고를 냈다. 그리고 rollback 확인 로직(`_rollback_committed`)
은 `is_consumed()` 의 falsy-non-bool 반환(`None`/`0`/`""`)을 "확인된
미소비"로 승격했다 — `claim()` 의 `is True` 엄격 판정과 대칭이 깨진
지점이었다. 두 사실을 각각 `_commit_failed_reason`(trigger 절 +
rollback 절 분리)과 `_rollback_committed`(`is False` 엄격 판정)로
바로잡았다.

**Phase 6 3회차 재리뷰 High 1 — `fact_resolvers` 배선 (spec §3.2)**:
`EvaluationContext` 는 Task 2.2 부터 이미 lazy fact resolver 를
지원했지만(`rein/engine/context.py`, `tests/unit/
test_lazy_fact_resolution.py` 가 계약 명세), 이 함수는 그것을
`EvaluationContext` 생성자에 전달하지 않아 실질적으로 죽은 기능이었다
— 독립 리뷰어 실증: 배포 기본 policy 4개가 전부 같은 trigger
(`tool.pre`)를 공유해, `rein/cli/__init__.py::_build_facts()` 가
쓰던 "policy 가 이 requirement 를 선언했는가"(trigger 만 보고 `when`
은 무시하는 근사)만으로는 파일 편집(Edit/Write)에서도 changeset
해시(`changeset.digest` 등)가 계산됐다 — cost gating 이 실효가 없었다.
이 함수는 그 값을 이제 **값이 아니라 resolver** 로 받을 수 있다 —
호출자(`rein.cli._build_fact_resolvers()`)가 비싼 fact 를 lazy
resolver 로 등록해 넘기면, 실제로 매칭된 policy 의 `require:` 를
평가하는 capability 구현체가 `context.fact(key)` 를 호출할 때만
계산된다(그 구현체들은 이미 전부 `context.fact()` 로 조회한다 —
`rein/capabilities/*/capability.py`, 이 워커 이전에도 그랬으므로
capability 쪽은 변경 없음). `fact_resolvers=None`(기본값)은 하위
호환 — `EvaluationContext(fact_resolvers=None)` 과 동일하게 스냅샷
`facts` 만 쓰는 기존 동작 그대로다. "사이클당 1회만 계산" 계약은 이
함수가 새로 구현하지 않는다 — `EvaluationContext._resolve()` 의
request-scoped cache(성공·실패 모두 캐시)가 이미 보장하므로, 여기서는
그 resolver 를 그대로 passthrough 할 뿐이다(이 함수 자신은 어떤 fact
가 비싼지 모른다 — `registry`/`evidence_source` 와 동일하게 순수
배선 계층).
"""
from rein.engine import evaluator
from rein.engine.context import EvaluationContext
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK, Decision
from rein.kernel.policy import PolicyLoadError, load_policies

__all__ = ["PolicyLoadError", "load_policies", "evaluate"]

# commit 이 원자적으로 전부 성공하지 못했을 때 fail-closed BLOCK 으로
# 교체하며 남기는 사유 문자열의 공통 접두부 — 어떤 (store, key) 조합에서
# 실패했는지 상세(store repr, 예외 메시지 등)는 담지 않는다(그 정보는
# store 구현이 알아서 로깅하는 게 맞고, 여기서는 정보 유출 표면을
# 넓히지 않는다). 뒷부분(트리거 항목의 실패 사유 + rollback 결과 요약)
# 은 `_commit_failed_reason` 이 관측된 결과에 따라 동적으로 붙인다
# (사이클 C 재리뷰 4·5회차 Medium 시정 — 아래 문단 참조).
_REASON_PREFIX = (
    "reserved one-shot consumption (e.g. user_approval) failed to commit "
    "atomically for this cycle — decision downgraded from ALLOW to BLOCK "
    "(fail-closed)"
)

# batch 를 깨뜨린 "트리거 항목"(처음으로 실패한 claim) 의 실패 종류 —
# 사이클 C 재리뷰 5회차 Medium 1 시정: 이 항목의 상태와 "이미 성공했다가
# 롤백된 다른 항목들"의 상태는 서로 다른 사실이므로 reason 에서 절대
# 섞이지 않는다("preserved" 는 후자에만 쓴다).
_TRIGGER_CONTESTED = "contested"  # claim() 이 정확히 False 반환 — 경합 패배
_TRIGGER_ERROR = "error"  # claim() 이 예외를 던짐 — 상태 불명
_TRIGGER_MALFORMED = "malformed"  # claim() 이 True/False 외의 값 반환 — 계약 위반

_TRIGGER_DESCRIPTIONS = {
    _TRIGGER_CONTESTED: (
        "the triggering reservation lost an atomic claim race — it is "
        "already consumed by a concurrent commit"
    ),
    _TRIGGER_ERROR: (
        "the triggering reservation's claim() raised an error — its "
        "consumption state could not be determined"
    ),
    _TRIGGER_MALFORMED: (
        "the triggering reservation's claim() returned a value other than "
        "True/False, violating the claim(fingerprint) -> bool contract — "
        "its consumption state could not be determined"
    ),
}


def _commit_failed_reason(trigger_kind, prior_commit_count, unrolled_back_count):
    """commit 실패 BLOCK 의 reason 문자열 — 두 서로 다른 사실을 분리해 보고한다.

    사이클 C 재리뷰 5회차 Medium 1 시정: 4회차 구현은 "trigger 항목(이번에
    실패한 claim)의 상태"와 "이미 성공했다가 롤백된 다른 항목들의 상태"
    를 하나의 문구로 뭉뚱그렸다 — trigger 가 경합 패배(claim() == False,
    이미 다른 쪽이 소비함)인데 rollback 할 다른 항목이 없으면(단일
    예약뿐인 흔한 경우), "the approval itself is preserved" 라고
    말해버렸다. 하지만 경합에서 진 승인은 **보존된 게 아니라 이미 다른
    cycle 에 소비된 것**이다 — "preserved" 는 오직 "이 batch 안에서
    먼저 성공했다가 이번 실패로 인해 롤백된 항목"에만 붙는 표현이어야
    한다. 그래서 이 함수는 두 절을 항상 분리해서 구성한다:

    1. **trigger 절** (`_TRIGGER_DESCRIPTIONS[trigger_kind]`): 이번에
       처음 실패한 그 예약 자체의 상태. 경합 패배(contested)/예외
       (error)/계약 위반(malformed) 세 가지뿐이고, 어느 쪽도 "preserved"
       라는 단어를 쓰지 않는다.
    2. **rollback 절**: trigger 이전에 이미 성공했던 다른 예약이 있을
       때만(`prior_commit_count > 0`) 등장한다 — 전부 롤백이 확인되면
       (`unrolled_back_count == 0`) 그때만 "preserved" 를 말하고, 하나
       라도 미확인이면 그 사실을 명시한다. 애초에 롤백할 항목이 없었으면
       (`prior_commit_count == 0`, 예약이 1건뿐이었던 흔한 경우) 이 절
       자체를 생략한다 — "아무것도 안 굴렸는데 preserved" 라는 공허한
       주장을 만들지 않는다.
    """
    trigger_clause = _TRIGGER_DESCRIPTIONS[trigger_kind]
    if prior_commit_count == 0:
        return _REASON_PREFIX + "; " + trigger_clause
    if unrolled_back_count == 0:
        rollback_clause = (
            "all {} already-committed consumption(s) earlier in this batch "
            "were rolled back and are preserved for a later "
            "attempt".format(prior_commit_count)
        )
    else:
        rollback_clause = (
            "rollback of {} of {} already-committed consumption(s) "
            "earlier in this batch could not be confirmed — they may "
            "remain consumed despite this BLOCK".format(
                unrolled_back_count, prior_commit_count
            )
        )
    return _REASON_PREFIX + "; " + trigger_clause + "; " + rollback_clause


def evaluate(
    event_name,
    facts,
    policies,
    evidence_source=None,
    registry=None,
    project_root=evaluator.PROJECT_ROOT_NOT_PROVIDED,
    fact_resolvers=None,
):
    """이벤트를 평가하고 직렬화 가능한 dict 를 반환한다 (cli 계약).

    evidence_source 미지정 시 NullEvidenceSource — 모든 requirement 가
    '부재'(정상 평가 BLOCK 재료)로 조회된다 (spec §3.4). storage 배선은
    Phase 2 소관.

    registry 미지정(None) 시 기존 존재 검사 동작 그대로 (cli 왕복 계약
    하위호환). 지정 시 evaluator 로 passthrough — 등록 구현체가 있는
    requirement 는 충족 판정을 구현체 evaluate 에 위임한다 (Task 3.1).

    project_root 는 순수 passthrough 다 (plan Task 6.1 — spec §7) —
    이 함수는 authority 를 전혀 모른다, `evaluator.evaluate()` 에 그대로
    넘길 뿐이다. 기본값은 `evaluator` 의 sentinel
    (`PROJECT_ROOT_NOT_PROVIDED`) — 호출자가 인자를 주지 않으면 Task 6.1
    이전과 완전히 동일하게 동작한다(`evaluator.evaluate()` 모듈 docstring
    "Authority 배선" 절의 세 값 의미 그대로 적용됨).

    fact_resolvers 도 순수 passthrough 다 (Phase 6 3회차 재리뷰 High 1
    — 모듈 docstring "fact_resolvers 배선" 절). 이 함수는 어떤 fact 가
    비싼지, 누가 그것을 요구하는지 전혀 모른다 — `EvaluationContext` 에
    그대로 전달할 뿐이다. `facts`(사전 해석된 스냅샷)에 이미 있는 키는
    같은 이름의 resolver 가 등록돼 있어도 항상 스냅샷 값이 우선한다
    (`EvaluationContext.fact()` 기존 계약, 값·resolver 혼재 시에도
    동일하게 적용된다). resolver 호출이 예외를 던지면
    `FactResolutionError`(`EvidenceStorageError` 하위 타입)로 승격돼
    `evaluator.evaluate()` 의 evidence 경로가 판단 불능으로 분기한다 —
    부재로 삼켜지지 않는다(`rein/engine/context.py` 모듈 docstring
    "fact 해석 실패의 지위" 절, 이 함수는 그 승격 로직을 재구현하지
    않고 그대로 상속한다). 기본값 `None` 은 하위호환 — 호출자가
    인자를 주지 않으면 이 워커 이전과 완전히 동일하게 동작한다.

    decision 이 ALLOW 면 이 cycle 동안 예약된 소비를 commit 하려 시도
    한다 — 전부 성공해야 ALLOW 가 유지된다(모듈 docstring 참조,
    `_commit_pending_consumptions`).
    """
    context = EvaluationContext(
        facts=facts,
        evidence_source=evidence_source,
        fact_resolvers=fact_resolvers,
    )
    decision = evaluator.evaluate(
        event_name, context, policies, registry=registry, project_root=project_root
    )
    decision = _commit_pending_consumptions(context, decision)
    return decision.to_dict()


def _commit_pending_consumptions(context, decision):
    """예약된 소비를 원자적으로 commit 하거나, 실패 시 fail-closed BLOCK.

    `decision` 이 이미 `DECISION_ALLOW` 가 아니면(BLOCK/ASK_USER) 아무
    것도 하지 않고 그대로 반환한다 — 예약은 폐기되고 외부 저장소는
    전혀 건드리지 않는다(승인 등 one-shot 자원 보존, 사이클 C 재리뷰
    2회차 케이스 (b) 시정). 예약이 하나도 없어도(빈 tuple) 그대로
    반환한다.

    ALLOW 이고 예약이 있으면, `context.pending_consumptions()` 순서대로
    각 `(store, key)` 의 `store.claim(key)` 를 시도한다:

    - **성공 판정은 `success is True` 로 엄격하다** (사이클 C 재리뷰
      4회차 High 시정 — 리뷰어 실증: `claim()` 이 `"storage-error"`
      같은 truthy-non-bool 을 반환해도 예전 `if not success:` 는
      이를 성공으로 오인정해 ALLOW 를 그대로 내보냈다). 프로토콜
      문서 계약이 "`claim(fingerprint) -> bool`" 이므로, 그 계약을
      어긴 반환값(=malformed) 은 성공이 아니라 **실패 방향**으로
      취급한다 — 관대한 truthy 해석을 허용하면 store 구현이 실수로
      비-bool 값(예외 객체, 에러 문자열)을 반환했을 때 이를 성공으로
      착각해 실제로는 소비되지 않은 승인으로 ALLOW 가 나가는 구멍이
      다시 열린다.
    - `True` 가 아닌 값을 반환하거나 **예외를 던지면**(사이클 C 재리뷰
      3회차 High: "claim 예외 시 catch 부재" 시정 — 여기서 잡아 동일하게
      다룬다) 그 즉시 시도를 멈추고, **이미 성공한 claim 들을
      best-effort 로 `store.release(key)` 롤백**한 뒤
      (`_rollback_committed` 참조), fail-closed `BLOCK` Decision 을
      새로 만들어 반환한다 — 원래 `decision.policy` 는 추적성을 위해
      보존하지만 `missing_requirements` 는 채우지 않는다(이 BLOCK 은
      "어떤 requirement 가 미충족"이 아니라 "충족은 됐으나 commit 이
      원자적으로 실패"라는 별개의 사유이기 때문 — reason 문자열이
      그 구분을 담당한다).

    **부분 소비에 대한 설계 판단** (사이클 C 재리뷰 3회차 지시 — 근거
    명시): 여러 예약이 순차 commit 되는 도중 뒤쪽이 실패하면, 앞쪽은
    이미 진짜로 소비된 상태다. 이를 그대로 두면(문서화만 하고 방치)
    "실패한 cycle 인데도 앞쪽 승인 등은 조용히 소모된다"는, 바로 이
    2회차에서 고친 것과 같은 부류의 자원 낭비가 재발한다. 그래서
    `release(key)` 를 프로토콜에 추가해 **best-effort 전체 롤백**을
    시도한다 — 완전한 분산 트랜잭션은 아니다(release 자체가 실패할
    잔여 위험은 존재하고, 예외를 흡수할 뿐 재시도하지 않는다), 그러나
    "실패해도 시도조차 안 한다"보다는 훨씬 낫고, 이 저장소가 반복
    채택해 온 "정직한 실패 처리 우선, 완전한 분산 합의는 비범위" 원칙
    (spec §2.2 위협 모델과 동일 결의 — 적대적 상황의 완전한 보장이
    아니라 정상 경로의 정직한 처리)과 정합한다. 롤백의 실제 성패는
    (사이클 C 재리뷰 4회차 Medium 시정) `_rollback_committed` 가
    관측해 `reason` 문자열에 정직하게 반영한다 — 무조건 "preserved"
    라고 말하지 않는다.
    """
    if decision.decision != DECISION_ALLOW:
        return decision
    pending = context.pending_consumptions()
    if not pending:
        return decision
    committed = []
    for store, key in pending:
        try:
            success = store.claim(key)
        except Exception:
            trigger_kind = _TRIGGER_ERROR
        else:
            if success is True:
                committed.append((store, key))
                continue
            trigger_kind = (
                _TRIGGER_CONTESTED if success is False else _TRIGGER_MALFORMED
            )
        unrolled_back = _rollback_committed(committed)
        return Decision(
            DECISION_BLOCK,
            reason=_commit_failed_reason(
                trigger_kind, len(committed), len(unrolled_back)
            ),
            policy=decision.policy,
        )
    return decision


def _rollback_committed(committed):
    """이미 성공한 claim 들을 best-effort 로 되돌리고, 결과를 관측해 반환한다.

    사이클 C 재리뷰 4회차 Medium 시정: 이전 구현은 `release()` 가
    예외 없이 반환하면 그냥 "롤백 성공"으로 간주했다 — 하지만
    `release(key) -> Any` 는 (`claim` 과 달리) bool 반환을 강제하는
    계약이 아니므로, 예외가 없다는 사실만으로 "그 fingerprint 가 실제로
    다시 미소비 상태가 됐다"를 보장할 수 없다. 그래서 이 함수는
    `release()` 호출 후 **`store.is_consumed(key)` 로 실제 상태를
    재확인**한다 — `is_consumed` 는 이미 프로토콜의 필수 멤버이자
    read-only 조회이므로 새로운 요구를 추가하지 않는다.

    반환값은 **복구를 확인하지 못한 `(store, key)` 목록**이다(빈 리스트
    = 전부 확인됨) — 아래 상황 전부 "미확인"으로 집계한다(확인 불가를
    성공으로 승격하지 않는다, 이 저장소의 반복 원칙과 동일 방향):

    1. `release()` 자체가 예외를 던짐.
    2. 재확인용 `is_consumed(key)` 호출 자체가 예외를 던짐(확인 불가).
    3. `is_consumed(key)` 가 정확히 `False` 가 아닌 값을 반환함 — 사이클
       C 재리뷰 5회차 Medium 2 시정: 이전 구현은 `if still_consumed:`
       로 판정해 falsy-non-bool(`None`/`0`/`""`)을 "확인된 미소비"로
       오인정했다. `claim(fingerprint) -> bool` 에 적용한 `is True`
       엄격 판정과 대칭으로, 여기서도 **`is_consumed(fingerprint) ->
       bool` 계약을 어긴 반환값은 성공(=확인됨)으로 승격하지 않는다** —
       `is False` 로 정확히 일치할 때만 "복구 확인됨"이다.

    이 함수는 fail-closed BLOCK 결정 자체를 바꾸지 않는다(롤백은
    자원을 아끼려는 best-effort 시도이지 decision 판정의 일부가
    아니다) — 다만 그 결과가 `reason` 문자열의 정확도를 결정한다.
    """
    unrolled_back = []
    for store, key in committed:
        try:
            store.release(key)
        except Exception:
            unrolled_back.append((store, key))
            continue
        try:
            still_consumed = store.is_consumed(key)
        except Exception:
            unrolled_back.append((store, key))
            continue
        if still_consumed is not False:
            unrolled_back.append((store, key))
    return unrolled_back
