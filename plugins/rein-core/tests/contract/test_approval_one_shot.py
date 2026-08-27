"""plan Task 4.5 — user_approval one-shot + action/digest/producer 결속 (spec §3.6 §21).

spec §3.6 (§21, 원문 인용):
    "BLOCK 상황의 명시적 승인. 기본 scope = 현재 action + 현재 digest +
    one-shot. 사용된 Approval 재사용 금지. `.skip-review`/`.skip-security`
    류 marker 우회는 제거."

검증 축 (plan Task 4.5 steps + 사이클 C 리뷰 1회차 High 1·2, 2회차 High 시정):

- **1회차 High 1(즉시 claim)의 재수정 — 2회차 High**: `evaluate()` 가
  유효한 미소비 승인을 찾자마자 그 자리에서 `store.claim()` 을 호출하는
  설계는 두 실증 경로에서 결함이었다: (a) 같은 cycle 에서 policy 2개가
  모두 `user_approval` 을 요구하면 첫 평가가 즉시 소비해버려 두 번째
  평가가 미충족으로 보였다(같은 승인인데 전체 decision 이 BLOCK 으로
  뒤집힘). (b) 한 policy 가 `[code_review, user_approval]` 을 요구하는데
  `code_review` 가 부재하면, `user_approval` 평가는 여전히 실행돼
  승인을 소비하지만 전체 decision 은 결국 BLOCK — 승인만 헛되이
  소모됨. 근본 원인: "승인 사용"과 "최종 허용"이 원자적 하나의
  사건이 아니었다. 수정: `evaluate()` 를 **무부수효과**로 되돌리고
  (`RequirementEvaluationIsSideEffectFreeTest`), 유효한 미소비 승인을
  찾으면 `context.reserve_consumption(store, fingerprint)` 로 예약만
  남긴다(`EvaluationContext`, `rein/engine/context.py`). 실제 commit
  (`store.claim()` 호출)은 cycle 종료 후 최종 decision 이 **ALLOW 일
  때만** Runtime(`rein/engine/runtime.py`)이 수행한다. `evaluator.
  evaluate()` 자신은 이 슬롯을 전혀 건드리지 않는다(Decision 반환
  계약 유지 — `EvaluatorLayerHasNoSideEffectsTest`).
- (a) 같은 cycle · policy 2개가 같은 승인을 요구 → 단일 평가 ALLOW +
  commit 은 정확히 1회 (`SameCycleSharedApprovalTest`).
- (b) 복합 요구(`code_review`+`user_approval`) 중 `code_review` 부재로
  최종 BLOCK → 승인은 소비되지 않고 재평가 시 여전히 유효
  (`ComplexRequirementBlockPreservesApprovalTest`).
- (c)+(d) `runtime.evaluate()` 관통 — 1차 ALLOW(그 호출이 commit) → 2차
  BLOCK(`StateTransitionThroughRuntimeTest`).
- **2회차→3회차 High 재교정**: 2회차는 commit 단계에서 `store.claim()`
  의 반환값과 예외를 모두 무시했다 — 리뷰어 실증: 동시 평가 2건이 모두
  ALLOW 를 반환할 수 있었고, `claim()` 예외는 uncaught 로 샜다. 수정:
  "성공한 원자적 claim = ALLOW 의 전제조건" — 하나라도 실패(반환
  `False`/예외)하면 fail-closed BLOCK 으로 downgrade 하고, 이미 성공한
  claim 은 `release()`(신규 프로토콜 메서드) 로 best-effort 롤백한다
  (`CommitFailureIsFailClosedTest`, `PartialFailureRollsBackAlreadyCommittedTest`,
  `ConcurrentEvaluationOnlyOneWinsTest`). "claim=False→ALLOW" 를
  정답으로 고정했던 구 테스트(`RuntimeCommitToleratesFailedClaimTest`)
  는 삭제하고 반대 방향(BLOCK)으로 대체했다.
- **3회차 Medium**: `EvaluationContext` 의 예약 슬롯이 `(store, key)`
  를 `set` 원소로 써서 store 의 숨은 hashability 요구를 만들었다 —
  `id(store)` 기반 dict 로 교체 + unhashable store 로도 전체 사이클이
  동작함을 확인(`ConsumptionStoreHashabilityTest`).
- **4회차 High**: commit 성공 판정이 `if not success:` 라 truthy
  non-bool(`"storage-error"`, `1`) 을 성공으로 오인정했다 — `success
  is True` 엄격 판정으로 교정(`_TruthyNonBoolClaimStore` 회귀 테스트,
  `CommitFailureIsFailClosedTest`).
- **4회차→5회차 Medium 재교정 (마지막 회차)**: 4회차는 두 가지를 더
  틀렸다 — (1) "경합에서 진 trigger 항목"과 "이미 성공했다가 롤백된
  다른 항목"의 상태를 reason 문자열 하나로 뭉뚱그려, 롤백할 항목이
  없는 흔한 단일 예약 경우에도 "the approval itself is preserved" 라고
  말해버렸다(경합 패배는 보존이 아니라 이미 다른 쪽 소비다). 이제
  `_commit_failed_reason` 이 trigger 절(contested/error/malformed, 절대
  "preserved" 를 쓰지 않음)과 rollback 절(전부 확인됐을 때만
  "preserved", 롤백할 항목이 없으면 이 절 자체를 생략)을 분리한다
  (`test_contested_single_reservation_reason_does_not_claim_preserved`).
  (2) 롤백 확인(`_rollback_committed`)이 `is_consumed()` 의 falsy-
  non-bool 반환(`None`/`0`/`""`)을 "확인된 미소비"로 승격했다 —
  `claim()` 의 `is True` 엄격 판정과 대칭으로 `is False` 엄격 판정으로
  교정(`test_falsy_non_bool_is_consumed_after_release_is_not_confirmed`).
(b') digest 변경 후 기존 승인 무효.
(c') action 불일치 무효.
(d') producer 불일치 무효(1회차 High 2 — agent_attested/
    runtime_verified 로 위장된 `type=user_approval` 레코드는 미충족).
(e') 소비 저장 프로토콜 확인 불가(주입 부재, `None`) → 보수적 미충족.
    프로토콜이 malformed(필수 메서드 결손)면 `FactResolutionError`.

marker 기반 우회(`.skip-review` 류)의 부재 검증은 별도 스위트
(`tests/bypass/test_marker_bypass_removed.py`)가 담당한다 — 이 파일은
승인 자체의 one-shot·결속 계약만 다룬다.

이 테스트 모듈은 `rein.capabilities.review`/`security`/`task`/`testing`
을 어떤 형태로도 import 하지 않는다(capability 간 직접 의존 금지, spec
§3.1).
"""
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.capabilities.approval.capability import (  # noqa: E402
    FACT_ACTION_CURRENT,
    FACT_APPROVAL_CONSUMPTION_STORE,
    FACT_CHANGESET_DIGEST,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    METADATA_KEY_ACTION,
    REQUIREMENT_NAME,
    RESULT_APPROVED,
    UserApprovalRequirement,
    issue_user_approval_evidence,
    register_user_approval,
)
from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import EvaluationContext, FactResolutionError  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.changeset import content_digest  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
    Decision,
)
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_RUNTIME_VERIFIED,
    PRODUCER_USER_APPROVED,
    evidence_fingerprint,
)


def _fs_reader(base):
    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


class _StubEvidenceSource:
    """조회는 항상 정상 수행되는 evidence 소스 (부재/존재만 제어)."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        if requirement_name == REQUIREMENT_NAME:
            return self._records
        return ()


class _InMemoryConsumptionStore:
    """소비 저장 프로토콜의 최소 참조 구현 — 테스트 전용 in-memory 더블.

    capability(`rein/capabilities/approval/capability.py`)는 이 클래스를
    전혀 모른다(import 하지 않는다) — 프로토콜(`is_consumed`/`claim`/
    `release` 콜러블)만 duck-type 으로 요구한다. `claim`/`release` 의
    "원자성"은 여기서는 단일 프로세스 GIL 하 한 논리 연산으로만
    보장한다 — 실제 동시성 안전은 저장 구현(파일 락·sqlite 트랜잭션
    등)의 책임이며 이 태스크의 scope 밖이다.
    """

    def __init__(self, already_consumed=()):
        self._consumed = set(already_consumed)
        self.claim_calls = []  # 호출 이력 — 부작용 발생 시점 검증용
        self.release_calls = []  # 롤백 호출 이력

    def is_consumed(self, fingerprint):
        return fingerprint in self._consumed

    def claim(self, fingerprint):
        self.claim_calls.append(fingerprint)
        if fingerprint in self._consumed:
            return False
        self._consumed.add(fingerprint)
        return True

    def release(self, fingerprint):
        self.release_calls.append(fingerprint)
        was_consumed = fingerprint in self._consumed
        self._consumed.discard(fingerprint)
        return was_consumed


class _NthClaimFailsStore(_InMemoryConsumptionStore):
    """N 번째 `claim()` 호출부터 실패하는 더블 — 부분 실패·롤백 시나리오용.

    여러 예약이 순차 commit 되는 도중 뒤쪽이 실패하는 상황(사이클 C
    재리뷰 3회차 "복수 예약의 부분 소비 방지")을 재현한다. 앞쪽 호출은
    정상적으로 `claim()` 이 성공(진짜로 소비)해야 "이미 성공한 claim
    들을 release 로 롤백" 하는 경로를 의미 있게 검증할 수 있다.
    """

    def __init__(self, fail_from_call_number, already_consumed=()):
        super().__init__(already_consumed=already_consumed)
        self._fail_from_call_number = fail_from_call_number

    def claim(self, fingerprint):
        call_number = len(self.claim_calls) + 1
        if call_number >= self._fail_from_call_number:
            self.claim_calls.append(fingerprint)
            return False
        return super().claim(fingerprint)


class _AlwaysFailingClaimStore:
    """`is_consumed` 는 미소비라고 답하지만 `claim` 은 항상 실패하는 더블.

    경쟁 상태(cycle 종료 후 commit 시점에 다른 프로세스가 먼저 소비)
    시뮬레이션 — commit 은 Runtime(`rein.engine.runtime._commit_pending_
    consumptions`)이 수행하며, 하나라도 실패(반환 `False`)하면 전체를
    fail-closed BLOCK 으로 downgrade 한다(사이클 C 재리뷰 3회차 High).
    이 더블로는 `UserApprovalRequirement.evaluate()` 자신의 반환값에
    영향이 없다 — `evaluate()` 는 `claim()` 을 아예 호출하지 않으므로
    (2단계 재설계).
    """

    def __init__(self):
        self.release_calls = []

    def is_consumed(self, fingerprint):
        return False

    def claim(self, fingerprint):
        return False

    def release(self, fingerprint):
        self.release_calls.append(fingerprint)


class _RaisingClaimStore:
    """`claim()` 이 예외를 던지는 더블 — commit 시 catch 후 BLOCK 확인용."""

    def __init__(self):
        self.release_calls = []

    def is_consumed(self, fingerprint):
        return False

    def claim(self, fingerprint):
        raise RuntimeError("simulated storage failure during claim")

    def release(self, fingerprint):
        self.release_calls.append(fingerprint)


class _TruthyNonBoolClaimStore:
    """`claim()` 이 `True` 가 아닌 truthy 값을 반환하는 malformed 더블.

    사이클 C 재리뷰 4회차 High 실증 — 프로토콜 문서 계약은
    "`claim(fingerprint) -> bool`" 인데, 이전 commit 판정(`if not
    success:`)은 `success` 가 truthy 이기만 하면(예: 에러를 뜻하는
    문자열 `"storage-error"`, 정수 `1`) 성공으로 오인정했다. 이 더블은
    실제로 아무것도 소비하지 않으면서 그런 오염된 반환값을 낸다 —
    `is_consumed()` 는 항상 `False` 를 유지하므로, 만약 commit 판정이
    이 반환값을 성공으로 잘못 받아들이면 "아무것도 소비 안 됐는데
    ALLOW" 라는 정확히 그 구멍이 재현된다.
    """

    def __init__(self, truthy_non_bool_value):
        assert truthy_non_bool_value and truthy_non_bool_value is not True
        self._return_value = truthy_non_bool_value
        self.claim_calls = []
        self.release_calls = []

    def is_consumed(self, fingerprint):
        return False

    def claim(self, fingerprint):
        self.claim_calls.append(fingerprint)
        return self._return_value

    def release(self, fingerprint):
        self.release_calls.append(fingerprint)


class _RaisingReleaseStore(_InMemoryConsumptionStore):
    """`release()` 자체가 예외를 던지는 더블 — 롤백 실패도 흡수되는지 확인용."""

    def release(self, fingerprint):
        raise RuntimeError("simulated storage failure during release")


class _NthClaimFailsAndReleaseRaisesStore(_NthClaimFailsStore):
    """부분 실패 + 롤백 자체 실패를 동시에 재현하는 더블.

    N 번째부터 `claim()` 이 실패하는 `_NthClaimFailsStore` 를 승계하되,
    `release()` 도 예외를 던지게 해 "이미 성공한 claim 을 되돌리려는
    시도 자체도 실패하는" 잔여 위험(모듈 docstring "부분 소비에 대한
    설계 판단" 절이 명시하는 경계)을 재현한다.
    """

    def release(self, fingerprint):
        raise RuntimeError("simulated storage failure during release")


class _FalsyNonBoolIsConsumedStore(_NthClaimFailsStore):
    """`is_consumed()` 가 정확한 `False` 대신 falsy-non-bool 을 반환하는 더블.

    사이클 C 재리뷰 5회차 Medium 2 재현 — `release()` 자체는 정상
    동작해 실제로 미소비 상태가 되지만(`self._consumed` 에서 실제로
    지워짐), `is_consumed()` 의 반환값만 오염시켜(`None`/`0`/`""` 등)
    "정확히 False" 계약을 어긴다. `_rollback_committed` 의 `is False`
    엄격 판정이 이 malformed 반환값을 "확인된 미소비"로 잘못 승격하지
    않는지 검증하는 데 쓴다.
    """

    def __init__(self, fail_from_call_number, falsy_value):
        super().__init__(fail_from_call_number=fail_from_call_number)
        assert not falsy_value and falsy_value is not False
        self._falsy_value = falsy_value

    def is_consumed(self, fingerprint):
        if fingerprint in self._consumed:
            return True  # 진짜 소비 상태는 정직하게(strict True) 보고
        return self._falsy_value  # 미소비 상태를 malformed 값으로 위장


class _UnhashableConsumptionStore:
    """`__eq__` 만 override 하고 `__hash__` 는 재정의하지 않은 store.

    Python 규약상 이런 클래스는 자동으로 unhashable(`__hash__ = None`)
    이 된다 — 흔한 실수 패턴. 프로토콜 문서(callable 3개만 요구)에는
    hashable 이어야 한다는 조건이 없으므로, 이 더블로 실제 평가 사이클
    전체가 정상 동작해야 한다(사이클 C 재리뷰 3회차 Medium 시정).
    """

    def __init__(self):
        self._consumed = set()
        self.claim_calls = []

    def __eq__(self, other):
        return isinstance(other, _UnhashableConsumptionStore)

    def is_consumed(self, fingerprint):
        return fingerprint in self._consumed

    def claim(self, fingerprint):
        self.claim_calls.append(fingerprint)
        if fingerprint in self._consumed:
            return False
        self._consumed.add(fingerprint)
        return True

    def release(self, fingerprint):
        self._consumed.discard(fingerprint)


class _MissingClaimMethodStore:
    """`is_consumed`/`release` 만 있고 `claim` 이 없는 malformed 더블."""

    def is_consumed(self, fingerprint):
        return False

    def release(self, fingerprint):
        pass


class _NonCallableClaimStore:
    """`claim` 속성은 있지만 콜러블이 아닌 malformed 더블."""

    def is_consumed(self, fingerprint):
        return False

    def release(self, fingerprint):
        pass

    claim = "not-callable"


class _MissingReleaseMethodStore:
    """`is_consumed`/`claim` 만 있고 `release` 가 없는 malformed 더블."""

    def is_consumed(self, fingerprint):
        return False

    def claim(self, fingerprint):
        return True


class _ApprovalFixtureMixin(unittest.TestCase):
    """승인 대상 파일 1개 + action 식별자를 마련하는 공통 준비."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "mod.py")
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")
        self.reader = _fs_reader(self.base)
        self.digest = self._current_digest()
        self.action = "tool.pre:bash:git-push"

    def _current_digest(self):
        return content_digest(("mod.py",), self.reader)

    def _edit_code(self):
        """승인 후 코드 수정 시뮬레이션 — 현재 digest 가 달라진다."""
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")

    def _issue(self, action=None, digest=None, policy_version="1"):
        return issue_user_approval_evidence(
            self.action if action is None else action,
            current_digest=self.digest if digest is None else digest,
            policy_version=policy_version,
        )

    def _context(
        self,
        records,
        digest="__default__",
        action="__default__",
        policy_version="1",
        compatible=None,
        store="__default__",
    ):
        """digest·action·version fact + evidence 소스를 담은 평가 컨텍스트.

        `store="__default__"` 는 신선한 `_InMemoryConsumptionStore()` 를
        새로 만들어 주입한다. `store=None` 을 명시하면 소비 저장
        프로토콜 fact 자체를 주입하지 않은 상태(확인 불가)를 표현한다
        — `context.fact()` 는 미주입 키에 대해 `None` 을 기본 반환하므로
        실제 "주입 부재" 와 동일한 모양이 된다.
        """
        facts = {}
        if digest != "__default__":
            if digest is not None:
                facts[FACT_CHANGESET_DIGEST] = digest
        else:
            facts[FACT_CHANGESET_DIGEST] = self.digest
        if action != "__default__":
            if action is not None:
                facts[FACT_ACTION_CURRENT] = action
        else:
            facts[FACT_ACTION_CURRENT] = self.action
        if policy_version is not None:
            facts[FACT_POLICY_VERSION] = policy_version
        if compatible is not None:
            facts[FACT_POLICY_COMPATIBLE_VERSIONS] = tuple(compatible)
        if store != "__default__":
            if store is not None:
                facts[FACT_APPROVAL_CONSUMPTION_STORE] = store
        else:
            facts[FACT_APPROVAL_CONSUMPTION_STORE] = (
                _InMemoryConsumptionStore()
            )
        return EvaluationContext(
            facts=facts, evidence_source=_StubEvidenceSource(records)
        )


class IssuanceTest(_ApprovalFixtureMixin):
    """발급 게이트 — action+digest 결속 + producer 등급."""

    def test_issues_evidence_bound_to_action_and_digest(self):
        evidence = self._issue()
        self.assertEqual(evidence.type, REQUIREMENT_NAME)
        self.assertEqual(evidence.subject, self.digest)
        self.assertEqual(evidence.result, RESULT_APPROVED)
        # 사용자 승인은 producer 3등급 중 최상위 (spec §3.5)
        self.assertEqual(evidence.producer, PRODUCER_USER_APPROVED)
        self.assertEqual(
            evidence.metadata.get(METADATA_KEY_ACTION), self.action
        )

    def test_missing_action_is_rejected(self):
        for bad_action in ("", None, 42):
            with self.assertRaises(ValueError):
                issue_user_approval_evidence(
                    bad_action,
                    current_digest=self.digest,
                    policy_version="1",
                )

    def test_missing_digest_is_rejected(self):
        for bad_digest in ("", None, 7):
            with self.assertRaises(ValueError):
                issue_user_approval_evidence(
                    self.action,
                    current_digest=bad_digest,
                    policy_version="1",
                )


class RequirementEvaluationIsSideEffectFreeTest(_ApprovalFixtureMixin):
    """`evaluate()` 는 외부 저장소를 건드리지 않는다 — 예약만 남긴다.

    사이클 C 재리뷰 2회차 High 시정: 1회차는 `evaluate()` 가 유효한
    미소비 승인을 찾자마자 `store.claim()` 을 직접 호출했다 — 이 클래스
    는 그 설계를 대체하는 "무부수효과 evaluate() + context 예약" 계약을
    고정한다. one-shot 소비의 실제 상태 전이(ALLOW 후 재차단)는 이제
    `SameCycleSharedApprovalTest`/`ComplexRequirementBlockPreservesApprovalTest`
    /`StateTransitionThroughRuntimeTest` 가 담당한다(Runtime commit 을
    거치는 경로).
    """

    def test_fresh_approval_satisfies_without_touching_external_store(self):
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        requirement = UserApprovalRequirement()
        fingerprint = evidence_fingerprint(evidence)

        self.assertFalse(store.is_consumed(fingerprint))
        satisfied = requirement.evaluate(
            self._context((evidence,), store=store)
        )
        self.assertTrue(satisfied)
        # evaluate() 는 store 를 전혀 변경하지 않는다 — claim() 을
        # 호출하지 않으므로 is_consumed()/claim_calls 모두 그대로다
        self.assertFalse(store.is_consumed(fingerprint))
        self.assertEqual(store.claim_calls, [])

    def test_satisfied_evaluation_reserves_pending_consumption_in_context(
        self,
    ):
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        requirement = UserApprovalRequirement()
        fingerprint = evidence_fingerprint(evidence)
        context = self._context((evidence,), store=store)

        # pending_consumptions() 는 tuple 을 반환한다(frozenset 아님) —
        # store 자체의 hashability 를 요구하지 않기 위한 설계(사이클 C
        # 재리뷰 3회차 Medium, `context.py` 참조). 원소 순서는 신경 쓰지
        # 않으므로 집합으로 변환해 비교한다.
        self.assertEqual(context.pending_consumptions(), ())
        self.assertTrue(requirement.evaluate(context))
        self.assertEqual(
            set(context.pending_consumptions()), {(store, fingerprint)}
        )

    def test_repeated_direct_evaluate_calls_stay_satisfied(self):
        # raw evaluate() 를 반복 호출해도(별도 context 든 같은 store 든)
        # 외부 상태가 절대 안 바뀌므로 매번 충족이다 — one-shot 소비는
        # evaluate() 층위의 책임이 아니라 Runtime commit 층위의 책임임을
        # 보여준다(케이스 (a)/(b) 의 근본 원인이었던 "즉시 claim" 이
        # 이제 존재하지 않는다).
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        requirement = UserApprovalRequirement()

        first = requirement.evaluate(self._context((evidence,), store=store))
        second = requirement.evaluate(
            self._context((evidence,), store=store)
        )
        third = requirement.evaluate(self._context((evidence,), store=store))

        self.assertTrue(first)
        self.assertTrue(second)
        self.assertTrue(third)
        self.assertEqual(store.claim_calls, [])

    def test_unconsumed_unrelated_fingerprint_does_not_block(self):
        # store 에 무관한 fingerprint 가 이미 소비돼 있어도 이 승인
        # 자체는 안 막힌다
        evidence = self._issue()
        store = _InMemoryConsumptionStore(
            already_consumed=("digest:unrelated-fp",)
        )
        requirement = UserApprovalRequirement()
        self.assertTrue(
            requirement.evaluate(self._context((evidence,), store=store))
        )

    def test_already_consumed_fingerprint_is_unmet_and_not_reserved(self):
        # is_consumed() 가 이미 True 면 그 후보는 건너뛴다 — 미충족이고,
        # 예약도 남기지 않는다(claim() 도 애초에 evaluate() 에서 호출되지
        # 않는다)
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _InMemoryConsumptionStore(already_consumed=(fingerprint,))
        requirement = UserApprovalRequirement()
        context = self._context((evidence,), store=store)
        self.assertFalse(requirement.evaluate(context))
        self.assertEqual(context.pending_consumptions(), ())
        self.assertEqual(store.claim_calls, [])


class SameCycleSharedApprovalTest(_ApprovalFixtureMixin):
    """(a) 리뷰어 실증 케이스 — 같은 cycle 에서 policy 2개가 같은 승인을 요구.

    사이클 C 재리뷰 2회차 High: 1회차 구현은 첫 policy 평가가 승인을
    즉시 소비해 두 번째 policy 평가에서 미충족으로 보이는 바람에 전체
    decision 이 BLOCK 으로 뒤집혔다. 같은 승인 하나로 두 policy 를 함께
    충족시키는 것이 맞는 동작이다 — `runtime.evaluate()` 관통으로
    확인한다(commit 이 실제로 일어나는 유일한 층위).
    """

    def setUp(self):
        super().setUp()
        self.policy_a = {
            "policy_id": "approval-gate-a",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:approval-gate-a>",
            ),
        }
        self.policy_b = {
            "policy_id": "approval-gate-b",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:approval-gate-b>",
            ),
        }
        self.registry = RequirementRegistry()
        register_user_approval(self.registry)

    def test_single_evaluation_allows_and_consumes_exactly_once(self):
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _InMemoryConsumptionStore()
        facts = {
            FACT_CHANGESET_DIGEST: self.digest,
            FACT_ACTION_CURRENT: self.action,
            FACT_POLICY_VERSION: "1",
            FACT_APPROVAL_CONSUMPTION_STORE: store,
        }

        result = runtime.evaluate(
            "tool.pre",
            facts,
            [self.policy_a, self.policy_b],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )

        self.assertEqual(result["decision"], DECISION_ALLOW)
        # 같은 fingerprint 가 두 policy 평가에서 반복 예약돼도 commit 은
        # 정확히 한 쌍에 대해 한 번만 일어난다 (context 의 집합 멱등성)
        self.assertTrue(store.is_consumed(fingerprint))
        self.assertEqual(store.claim_calls, [fingerprint])


class ComplexRequirementBlockPreservesApprovalTest(_ApprovalFixtureMixin):
    """(b) 리뷰어 실증 케이스 — 복합 요구 중 다른 requirement 부재로 BLOCK.

    사이클 C 재리뷰 2회차 High: 1회차 구현은 `user_approval` 평가 자체는
    통과했다는 이유로 그 자리에서 승인을 소비했지만, 같은 policy 가 함께
    요구하는 `code_review` evidence 가 없어 전체 decision 은 결국
    BLOCK 이었다 — 승인만 헛되이 소모됐다. `code_review` capability 는
    import 하지 않는다(capability 간 직접 의존 금지, spec §3.1) —
    registry 에 `user_approval` 만 등록해 `code_review` 를 "미등록
    requirement"(존재 검사 fallback, 언제나 부재) 로 취급시킨다.
    """

    def setUp(self):
        super().setUp()
        self.policy = {
            "policy_id": "code-review-and-approval-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - code_review\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:code-review-and-approval-gate>",
            ),
        }
        self.registry = RequirementRegistry()
        register_user_approval(self.registry)  # code_review 는 미등록

    def test_block_from_missing_code_review_preserves_the_approval(self):
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _InMemoryConsumptionStore()
        facts = {
            FACT_CHANGESET_DIGEST: self.digest,
            FACT_ACTION_CURRENT: self.action,
            FACT_POLICY_VERSION: "1",
            FACT_APPROVAL_CONSUMPTION_STORE: store,
        }

        result = runtime.evaluate(
            "tool.pre",
            facts,
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )

        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertIn("code_review", result["missing_requirements"])
        # user_approval 자체는 이 cycle 안에서 충족됐으므로 missing 목록에
        # 없어야 한다 — 그리고 그럼에도 BLOCK 이므로 승인은 소비되지
        # 않아야 한다(케이스 (b) 의 핵심 주장)
        self.assertNotIn("user_approval", result["missing_requirements"])
        self.assertFalse(store.is_consumed(fingerprint))
        self.assertEqual(store.claim_calls, [])

    def test_approval_remains_valid_on_a_subsequent_clean_evaluation(self):
        # "재평가 시 여전히 유효" — 위 BLOCK cycle 이후, code_review 요구
        # 없이 같은 승인으로 다시 평가하면 정상적으로 ALLOW 된다
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        blocked_facts = {
            FACT_CHANGESET_DIGEST: self.digest,
            FACT_ACTION_CURRENT: self.action,
            FACT_POLICY_VERSION: "1",
            FACT_APPROVAL_CONSUMPTION_STORE: store,
        }
        first = runtime.evaluate(
            "tool.pre",
            blocked_facts,
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(first["decision"], DECISION_BLOCK)

        approval_only_policy = {
            "policy_id": "approval-only-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:approval-only-gate>",
            ),
        }
        second = runtime.evaluate(
            "tool.pre",
            blocked_facts,
            [approval_only_policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(second["decision"], DECISION_ALLOW)


class DigestBindingTest(_ApprovalFixtureMixin):
    """(b) — digest 변경 후 기존 승인은 무효."""

    def test_digest_change_invalidates_existing_approval(self):
        evidence = self._issue()
        self._edit_code()
        current = self._current_digest()
        self.assertNotEqual(current, self.digest)
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((evidence,), digest=current)
            )
        )

    def test_matching_digest_after_reissue_is_met(self):
        # 대칭 확인 — 새 digest 로 다시 발급하면 그 digest 에 대해서는 충족
        self._edit_code()
        current = self._current_digest()
        evidence = issue_user_approval_evidence(
            self.action, current_digest=current, policy_version="1"
        )
        requirement = UserApprovalRequirement()
        self.assertTrue(
            requirement.evaluate(
                self._context((evidence,), digest=current)
            )
        )


class ActionBindingTest(_ApprovalFixtureMixin):
    """(c) — action 불일치 시 무효."""

    def test_action_mismatch_invalidates(self):
        evidence = self._issue(action="tool.pre:bash:git-push")
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context(
                    (evidence,), action="tool.pre:bash:git-force-push"
                )
            )
        )

    def test_matching_action_is_met(self):
        evidence = self._issue(action="tool.pre:bash:git-push")
        requirement = UserApprovalRequirement()
        self.assertTrue(
            requirement.evaluate(
                self._context((evidence,), action="tool.pre:bash:git-push")
            )
        )


class ProducerBindingTest(_ApprovalFixtureMixin):
    """(d) — producer 불일치 시 무효 (사이클 C 리뷰 1회차 High 2)."""

    def _record(self, producer):
        return Evidence(
            type=REQUIREMENT_NAME,
            subject=self.digest,
            result=RESULT_APPROVED,
            created_at="2026-08-10T00:00:00+00:00",
            producer=producer,
            policy_version="1",
            metadata={METADATA_KEY_ACTION: self.action},
        )

    def test_agent_attested_impersonation_does_not_satisfy(self):
        # 리뷰가 "PASS" 로 판정한 뒤 그 결과가 실수로/의도적으로
        # type=user_approval bucket 에 들어와도 producer 축이 막는다
        record = self._record(PRODUCER_AGENT_ATTESTED)
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((record,)))
        )

    def test_runtime_verified_impersonation_does_not_satisfy(self):
        record = self._record(PRODUCER_RUNTIME_VERIFIED)
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((record,)))
        )

    def test_genuine_user_approved_producer_is_met(self):
        # 대칭 확인 — 정상 producer 는 (다른 축이 다 맞으면) 충족
        record = self._record(PRODUCER_USER_APPROVED)
        requirement = UserApprovalRequirement()
        self.assertTrue(requirement.evaluate(self._context((record,))))


class ConsumptionStoreUncertaintyTest(_ApprovalFixtureMixin):
    """(e) — 소비 저장 프로토콜 확인 불가/malformed 처리."""

    def test_missing_store_is_conservatively_unmet(self):
        # 승인 자체는 유효(action+digest+producer 결속, 소비 이력 없음)
        # 해도, 소비 여부를 재확인할 저장 프로토콜이 아예 주입되지
        # 않으면(None) 미충족이다 — "확인 불가"를 "아직 안 썼다"로
        # 낙관하지 않는다.
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((evidence,), store=None))
        )

    def test_store_missing_claim_method_is_malformed(self):
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        with self.assertRaises(FactResolutionError):
            requirement.evaluate(
                self._context(
                    (evidence,), store=_MissingClaimMethodStore()
                )
            )

    def test_store_non_callable_claim_is_malformed(self):
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        with self.assertRaises(FactResolutionError):
            requirement.evaluate(
                self._context((evidence,), store=_NonCallableClaimStore())
            )

    def test_store_missing_release_method_is_malformed(self):
        # release() 는 evaluate() 자신은 안 쓰지만(runtime commit 소관),
        # 프로토콜 전체를 발급 시점(evaluate)에 fail fast 로 검증한다
        # (사이클 C 재리뷰 3회차 — release 를 프로토콜에 추가한 결과)
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        with self.assertRaises(FactResolutionError):
            requirement.evaluate(
                self._context(
                    (evidence,), store=_MissingReleaseMethodStore()
                )
            )

    def test_store_as_bare_object_without_any_method_is_malformed(self):
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        with self.assertRaises(FactResolutionError):
            requirement.evaluate(
                self._context((evidence,), store=object())
            )

    def test_absent_action_or_digest_fact_is_conservatively_unmet(self):
        evidence = self._issue()
        requirement = UserApprovalRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((evidence,), digest=None)
            )
        )
        self.assertFalse(
            requirement.evaluate(
                self._context((evidence,), action=None)
            )
        )

    def test_non_pass_result_record_does_not_satisfy(self):
        record = Evidence(
            type=REQUIREMENT_NAME,
            subject=self.digest,
            result="REJECTED",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_USER_APPROVED,
            policy_version="1",
            metadata={METADATA_KEY_ACTION: self.action},
        )
        requirement = UserApprovalRequirement()
        self.assertFalse(requirement.evaluate(self._context((record,))))


class RegistrationTest(_ApprovalFixtureMixin):
    def test_registration_is_explicit_not_import_side_effect(self):
        registry = RequirementRegistry()
        self.assertFalse(registry.is_registered(REQUIREMENT_NAME))
        implementation = register_user_approval(registry)
        self.assertTrue(registry.is_registered(REQUIREMENT_NAME))
        self.assertIs(registry.resolve(REQUIREMENT_NAME), implementation)
        self.assertEqual(implementation.name, REQUIREMENT_NAME)
        self.assertIsInstance(implementation, UserApprovalRequirement)


class _ApprovalGateFixture(_ApprovalFixtureMixin):
    """`user_approval` 단독 요구 policy + registry 공통 준비."""

    def setUp(self):
        super().setUp()
        self.policy = {
            "policy_id": "approval-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:approval-gate>",
            ),
        }
        self.registry = RequirementRegistry()
        register_user_approval(self.registry)

    def _facts(self, store):
        facts = {
            FACT_CHANGESET_DIGEST: self.digest,
            FACT_ACTION_CURRENT: self.action,
            FACT_POLICY_VERSION: "1",
        }
        if store is not None:
            facts[FACT_APPROVAL_CONSUMPTION_STORE] = store
        return facts


class EvaluatorLayerHasNoSideEffectsTest(_ApprovalGateFixture):
    """evaluator.evaluate() 는 Decision 만 반환한다 — commit 은 하지 않는다.

    사이클 C 재리뷰 2회차 지시: "evaluator.evaluate 는 무변경 (Decision
    반환 계약 유지)". 이 클래스는 그 불변을 직접 고정한다 — commit(=
    `store.claim()` 실제 호출)은 오직 `rein.engine.runtime.evaluate`
    에서만 일어난다(`StateTransitionThroughRuntimeTest` 참조).
    """

    def test_absent_evidence_yields_block(self):
        context = EvaluationContext(
            facts=self._facts(_InMemoryConsumptionStore()),
            evidence_source=_StubEvidenceSource(()),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))

    def test_fresh_approval_yields_allow(self):
        evidence = self._issue()
        context = EvaluationContext(
            facts=self._facts(_InMemoryConsumptionStore()),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)

    def test_repeated_evaluator_only_calls_never_commit_and_stay_allow(self):
        # evaluator.evaluate() 를 반복 호출해도(같은 evidence + 같은
        # store) 매번 ALLOW 다 — commit 하는 층위가 아니므로 store 는
        # 절대 안 바뀐다. 이것이 `evaluator.evaluate()` 자체만으로는
        # one-shot 이 강제되지 않는 이유이자, 그 강제를 Runtime 층위로
        # 미룬 설계의 직접 증거다.
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        fingerprint = evidence_fingerprint(evidence)

        for _ in range(3):
            context = EvaluationContext(
                facts=self._facts(store),
                evidence_source=_StubEvidenceSource((evidence,)),
            )
            decision = evaluator.evaluate(
                "tool.pre", context, [self.policy], registry=self.registry
            )
            self.assertEqual(decision.decision, DECISION_ALLOW)

        self.assertFalse(store.is_consumed(fingerprint))
        self.assertEqual(store.claim_calls, [])


class StateTransitionThroughRuntimeTest(_ApprovalGateFixture):
    """(c)+(d) — runtime.evaluate() 관통: 1차 ALLOW(+commit) → 2차 BLOCK.

    "소비됨" 상태를 테스트가 밖에서 만들어 넣지 않는다 — 1차
    `runtime.evaluate()` 호출 자체가(그 호출이 최종 ALLOW 를 확인한
    뒤) store 에 소비를 commit 하고, 2차 호출은 그 결과를 그대로
    재확인한다.
    """

    def test_first_call_allows_and_commits_second_call_blocks(self):
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _InMemoryConsumptionStore()

        first = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(first["decision"], DECISION_ALLOW)
        self.assertTrue(store.is_consumed(fingerprint))
        self.assertEqual(store.claim_calls, [fingerprint])

        second = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(second["decision"], DECISION_BLOCK)
        self.assertEqual(second["missing_requirements"], ["user_approval"])
        # 2차 호출 시점에는 evaluate() 가 애초에 이 fingerprint 를
        # 후보로 채택하지 않으므로(is_consumed() == True) 추가
        # claim() 호출도 없다 — commit 시도 자체가 없다
        self.assertEqual(store.claim_calls, [fingerprint])

    def test_a_second_distinct_approval_still_works_after_the_first_is_spent(
        self,
    ):
        # 소비된 승인 1개가 완전히 새로운(다른 발급 시각의) 승인까지
        # 막지는 않는다 — 새 승인을 다시 발급하면 정상 ALLOW
        first_evidence = self._issue()
        store = _InMemoryConsumptionStore()
        first = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((first_evidence,)),
            registry=self.registry,
        )
        self.assertEqual(first["decision"], DECISION_ALLOW)

        second_evidence = issue_user_approval_evidence(
            self.action,
            current_digest=self.digest,
            policy_version="1",
            created_at="2026-08-11T00:00:00+00:00",
        )
        self.assertNotEqual(
            evidence_fingerprint(second_evidence),
            evidence_fingerprint(first_evidence),
        )
        second = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((second_evidence,)),
            registry=self.registry,
        )
        self.assertEqual(second["decision"], DECISION_ALLOW)


class CommitFailureIsFailClosedTest(_ApprovalGateFixture):
    """사이클 C 재리뷰 3회차 High — 성공한 원자적 claim 은 ALLOW 의 전제조건.

    2회차 구현은 commit 단계에서 `store.claim()` 의 반환값과 예외를
    모두 무시했다 — 리뷰어 실증: 동시 평가 2건이 모두 ALLOW 를 반환할
    수 있었고(경합 패배 쪽도 ALLOW), `claim()` 이 예외를 던지면
    uncaught 로 새어나갔다. 이 클래스는 방향을 교정한 계약을 고정한다:
    claim 이 `False` 를 반환하거나 예외를 던지면 그 즉시 그 cycle 의
    decision 은 fail-closed `BLOCK` 으로 downgrade 되고, 이미 성공한
    claim 은 best-effort 로 `release()` 롤백된다.
    """

    def test_failing_claim_downgrades_allow_to_block(self):
        # 2회차의 "claim=False → ALLOW" 는 오답이었다 — 이제는 BLOCK.
        evidence = self._issue()
        store = _AlwaysFailingClaimStore()
        result = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertIn(
            "consumption", result["reason"].lower()
        )  # 승인 소비 실패임을 사람이 읽을 수 있어야 한다

    def test_contested_single_reservation_reason_does_not_claim_preserved(
        self,
    ):
        # 사이클 C 재리뷰 5회차 Medium 1 회귀 테스트 — 예약이 1건뿐이라
        # 롤백할 다른 항목이 없는 흔한 경우(경합 패배 = claim() 이 정확히
        # False), reason 이 "the approval itself is preserved" 라고
        # 말하면 틀린 보고다 — 경합에서 진 승인은 다른 쪽에 이미
        # 소비됐지, 보존된 게 아니다. "preserved" 는 이 batch 안에서
        # 먼저 성공했다가 롤백된 항목에만 붙어야 한다(여기는 그런
        # 항목이 아예 없다).
        evidence = self._issue()
        store = _AlwaysFailingClaimStore()
        result = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)
        self.assertNotIn("preserved", result["reason"])
        self.assertIn("already consumed", result["reason"])
        self.assertIn("claim race", result["reason"])

    def test_raising_claim_is_caught_and_downgrades_to_block(self):
        # "예외가 전파되지 않는다"는 ALLOW 로 삼키라는 뜻이 아니었다 —
        # 2회차는 애초에 catch 조차 없어 uncaught 로 샜다(별도 결함).
        # 이제는 잡아서 BLOCK 으로 명시 변환한다 — 두 실패 형태(반환
        # False / 예외)가 같은 방향(BLOCK)으로 수렴한다.
        evidence = self._issue()
        store = _RaisingClaimStore()
        result = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)

    def test_failing_claim_does_not_leave_a_phantom_consumption(self):
        # commit 실패 시 store 상태는 "소비 안 됨" 이어야 한다 — 승인은
        # 보존된다(그래야 사용자가 재시도할 수 있다)
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _AlwaysFailingClaimStore()
        runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertFalse(store.is_consumed(fingerprint))

    def test_truthy_non_bool_claim_return_is_treated_as_failure(self):
        # 사이클 C 재리뷰 4회차 High 회귀 테스트 — claim() 이 True 가
        # 아닌 truthy 값을 반환해도(에러를 뜻하는 문자열·정수 등) 성공
        # 으로 오인정하지 않는다. 리뷰어 실증 그대로 "storage-error"
        # 문자열과, 참고로 정수 1 도 함께 확인한다.
        for malformed_return in ("storage-error", 1, [1], "True"):
            with self.subTest(malformed_return=malformed_return):
                evidence = self._issue()
                store = _TruthyNonBoolClaimStore(malformed_return)
                result = runtime.evaluate(
                    "tool.pre",
                    self._facts(store),
                    [self.policy],
                    evidence_source=_StubEvidenceSource((evidence,)),
                    registry=self.registry,
                )
                self.assertEqual(result["decision"], DECISION_BLOCK)
                self.assertEqual(store.claim_calls, [evidence_fingerprint(evidence)])

    def test_actual_bool_true_is_still_required_for_success(self):
        # 대칭 확인 — 진짜 True 는 여전히 정상적으로 ALLOW 를 유지한다
        # (엄격화가 정상 경로까지 막지 않는다)
        evidence = self._issue()
        store = _InMemoryConsumptionStore()
        result = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_ALLOW)


class ConcurrentEvaluationOnlyOneWinsTest(_ApprovalGateFixture):
    """리뷰어 요구 시나리오 — 두 context 가 각각 is_consumed=False 를 관측한 뒤 commit.

    실제 동시성(스레드)이 아니라, "두 evaluate() 사이클이 커밋 전에는
    서로의 상태를 보지 못한다"는 조건을 순서대로 재현한다: 두 context
    모두 evaluator 층위(무부수효과)에서 독립적으로 승인을 찾아 예약하고
    ALLOW 를 받는다(이 시점까지는 store 가 전혀 안 바뀌었으므로 둘 다
    안전하게 같은 결론에 도달한다) — 그 다음에야 각자 commit 을
    시도한다. 원자적 `claim()` 덕분에 한쪽만 성공해야 한다.
    """

    def test_only_one_of_two_racing_commits_survives(self):
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _InMemoryConsumptionStore()

        context_a = EvaluationContext(
            facts=self._facts(store),
            evidence_source=_StubEvidenceSource((evidence,)),
        )
        context_b = EvaluationContext(
            facts=self._facts(store),
            evidence_source=_StubEvidenceSource((evidence,)),
        )

        # 두 cycle 모두 evaluator 층위에서는 ALLOW — commit 전이라 store
        # 는 아직 안 바뀌었다(둘 다 같은 미소비 상태를 관측했다)
        decision_a = evaluator.evaluate(
            "tool.pre", context_a, [self.policy], registry=self.registry
        )
        decision_b = evaluator.evaluate(
            "tool.pre", context_b, [self.policy], registry=self.registry
        )
        self.assertEqual(decision_a.decision, DECISION_ALLOW)
        self.assertEqual(decision_b.decision, DECISION_ALLOW)
        self.assertFalse(store.is_consumed(fingerprint))

        # 이제 각자 commit 을 시도한다 — 원자적 claim() 은 한쪽만 통과
        final_a = runtime._commit_pending_consumptions(context_a, decision_a)
        final_b = runtime._commit_pending_consumptions(context_b, decision_b)

        outcomes = sorted([final_a.decision, final_b.decision])
        self.assertEqual(outcomes, [DECISION_ALLOW, DECISION_BLOCK])
        self.assertTrue(store.is_consumed(fingerprint))
        # 패배한 쪽의 claim 실패가 승리한 쪽의 소비를 롤백하지 않았다
        self.assertEqual(store.claim_calls.count(fingerprint), 2)


class PartialFailureRollsBackAlreadyCommittedTest(_ApprovalGateFixture):
    """복수 예약 중 일부만 실패해도 이미 성공한 claim 을 롤백한다.

    사이클 C 재리뷰 3회차 지시 "복수 예약의 부분 소비 방지" — 이
    구현은 `release(key)` 를 프로토콜에 추가해 best-effort 전체 롤백을
    수행한다(설계 판단 근거는 `runtime._commit_pending_consumptions`
    docstring 참조). 이 테스트는 `context.reserve_consumption` 을 직접
    호출해 "한 store 에 서로 다른 fingerprint 2개가 예약된" 상태를
    인위적으로 구성한다 — 실제 capability 사용 패턴(승인 1건 = 예약
    1건)보다 넓지만, batch commit 의 원자성 자체를 독립적으로 검증하기
    위해 필요하다.

    4회차 Medium 추가: 롤백이 **실제로 관측 가능하게 성공했는지**
    (`store.is_consumed()` 재확인)와 그 결과가 `reason` 문자열에
    정직하게 반영되는지(전부 확인되면 "preserved", 하나라도 미확인이면
    "could not be confirmed")를 검증한다 — 예외 없이 반환됐다는 사실
    만으로 롤백 성공을 낙관하지 않는다.
    """

    def test_second_reservation_failure_rolls_back_the_first(self):
        store = _NthClaimFailsStore(fail_from_call_number=2)
        context = EvaluationContext(facts={})
        context.reserve_consumption(store, "fingerprint-1")
        context.reserve_consumption(store, "fingerprint-2")

        original = Decision(DECISION_ALLOW, reason="test")

        final = runtime._commit_pending_consumptions(context, original)

        self.assertEqual(final.decision, DECISION_BLOCK)
        # 1번째는 성공했다가 롤백됐다 — 최종적으로 "소비 안 됨"
        self.assertFalse(store.is_consumed("fingerprint-1"))
        self.assertEqual(store.release_calls, ["fingerprint-1"])
        # 롤백이 실제로(관측 가능하게) 성공했으므로 reason 은 "보존됨"
        # 이라고 정직하게 말해도 된다(사이클 C 재리뷰 4회차 Medium —
        # 이 경우는 무조건 "preserved" 가 아니라 "확인된 preserved").
        self.assertIn("preserved", final.reason)
        self.assertNotIn("could not be confirmed", final.reason)

    def test_all_succeeding_reservations_keep_the_allow(self):
        store = _InMemoryConsumptionStore()
        context = EvaluationContext(facts={})
        context.reserve_consumption(store, "fingerprint-1")
        context.reserve_consumption(store, "fingerprint-2")

        original = Decision(DECISION_ALLOW, reason="test")

        final = runtime._commit_pending_consumptions(context, original)

        self.assertEqual(final.decision, DECISION_ALLOW)
        self.assertTrue(store.is_consumed("fingerprint-1"))
        self.assertTrue(store.is_consumed("fingerprint-2"))
        self.assertEqual(store.release_calls, [])

    def test_rollback_failure_does_not_raise_but_is_reported_honestly(self):
        # 사이클 C 재리뷰 4회차 Medium 회귀 테스트 — 리뷰어 실증 시나리오
        # 그대로: 2번째 claim 실패 후 1번째의 release() 도 실패하면,
        # fingerprint-1 은 실제로 소비된 채 남는다. 예외로 새지 않는 것
        # 만으로는 부족하다 — reason 이 "preserved" 라고 무조건 주장하면
        # 조용한 부정확 보고다. 이제는 "복구를 확인하지 못했다"를
        # 명시해야 한다.
        store = _NthClaimFailsAndReleaseRaisesStore(fail_from_call_number=2)
        context = EvaluationContext(facts={})
        context.reserve_consumption(store, "fingerprint-1")
        context.reserve_consumption(store, "fingerprint-2")

        original = Decision(DECISION_ALLOW, reason="test")
        final = runtime._commit_pending_consumptions(context, original)

        self.assertEqual(final.decision, DECISION_BLOCK)
        # release() 가 예외를 던졌어도 그 시도 자체는 있었다 — 그리고
        # 실패했으므로 fingerprint-1 은 여전히 소비된 상태로 남는다
        self.assertEqual(store.claim_calls, ["fingerprint-1", "fingerprint-2"])
        self.assertTrue(store.is_consumed("fingerprint-1"))
        # reason 이 더 이상 "preserved" 라고 부정확하게 주장하지 않고,
        # 미확인 롤백 사실을 명시한다
        self.assertNotIn("preserved", final.reason)
        self.assertIn("could not be confirmed", final.reason)

    def test_release_succeeds_without_exception_but_leaves_key_consumed(self):
        # 사이클 C 재리뷰 4회차 Medium — release() 가 예외를 던지지
        # 않고 정상 반환해도, `is_consumed()` 로 재확인했을 때 여전히
        # True 면(구현이 조용히 실패한 경우) 그것도 "미확인"으로
        # 집계돼야 한다 — 예외 부재만으로 성공을 낙관하지 않는다.
        class _ReleaseNoOpStore(_NthClaimFailsStore):
            """release() 가 예외 없이 반환하지만 실제로는 아무것도 안 지운다."""

            def release(self, fingerprint):
                return None  # 성공한 척하지만 self._consumed 는 그대로

        store = _ReleaseNoOpStore(fail_from_call_number=2)
        context = EvaluationContext(facts={})
        context.reserve_consumption(store, "fingerprint-1")
        context.reserve_consumption(store, "fingerprint-2")

        original = Decision(DECISION_ALLOW, reason="test")
        final = runtime._commit_pending_consumptions(context, original)

        self.assertEqual(final.decision, DECISION_BLOCK)
        self.assertTrue(store.is_consumed("fingerprint-1"))
        self.assertNotIn("preserved", final.reason)
        self.assertIn("could not be confirmed", final.reason)

    def test_falsy_non_bool_is_consumed_after_release_is_not_confirmed(self):
        # 사이클 C 재리뷰 5회차 Medium 2 회귀 테스트 — release() 는
        # 정상 동작해 실제로 미소비 상태가 됐어도(store 내부적으로는
        # 진짜 풀렸다), is_consumed() 가 정확한 False 대신 falsy-non-bool
        # (None/0/"") 을 반환하면 "확인된 미소비"로 승격하지 않는다 —
        # claim() 의 is True 엄격 판정과 대칭.
        for falsy_value in (None, 0, ""):
            with self.subTest(falsy_value=repr(falsy_value)):
                store = _FalsyNonBoolIsConsumedStore(
                    fail_from_call_number=2, falsy_value=falsy_value
                )
                context = EvaluationContext(facts={})
                context.reserve_consumption(store, "fingerprint-1")
                context.reserve_consumption(store, "fingerprint-2")

                original = Decision(DECISION_ALLOW, reason="test")
                final = runtime._commit_pending_consumptions(
                    context, original
                )

                self.assertEqual(final.decision, DECISION_BLOCK)
                # release() 자체는 실제로 성공했다(내부적으로 미소비로
                # 되돌아갔다) — 그럼에도 malformed 반환값 때문에 "확인
                # 안 됨"으로 집계돼야 한다
                self.assertNotIn(
                    "fingerprint-1", store._consumed
                )  # 실제 상태는 진짜 풀림
                self.assertNotIn("preserved", final.reason)
                self.assertIn("could not be confirmed", final.reason)


class ConsumptionStoreHashabilityTest(_ApprovalGateFixture):
    """Medium — 예약 슬롯이 store 의 hashability 를 요구하지 않는다.

    `__eq__` 만 override 하고 `__hash__` 를 재정의하지 않은 store 는
    Python 규약상 자동으로 unhashable 이 된다 — 프로토콜 문서(콜러블
    3개만 요구)에는 없는 숨은 요구사항이었다(사이클 C 재리뷰 3회차
    Medium). `context.py` 가 `(store, key)` 를 직접 `set` 원소로 쓰던
    이전 구현이면 아래 두 테스트 모두 `TypeError: unhashable type` 로
    깨졌을 것이다.
    """

    def test_unhashable_store_is_actually_unhashable(self):
        # 전제 가드 — 이 더블이 실제로 unhashable 인지 먼저 확인한다
        # (그래야 아래 성공이 "우연히 hashable 이라 통과" 가 아니다)
        store = _UnhashableConsumptionStore()
        with self.assertRaises(TypeError):
            hash(store)

    def test_reserve_and_commit_work_with_an_unhashable_store(self):
        evidence = self._issue()
        fingerprint = evidence_fingerprint(evidence)
        store = _UnhashableConsumptionStore()

        result = runtime.evaluate(
            "tool.pre",
            self._facts(store),
            [self.policy],
            evidence_source=_StubEvidenceSource((evidence,)),
            registry=self.registry,
        )

        self.assertEqual(result["decision"], DECISION_ALLOW)
        self.assertTrue(store.is_consumed(fingerprint))

    def test_direct_reserve_consumption_accepts_unhashable_store(self):
        # EvaluationContext API 를 직접 겨냥한 최소 재현
        context = EvaluationContext(facts={})
        store = _UnhashableConsumptionStore()
        context.reserve_consumption(store, "fp-1")
        # store 가 unhashable 이므로 `set(...)` 로 비교하면 이 assertion
        # 자체가 TypeError 로 깨진다 — tuple 그대로 비교한다(원소 1개라
        # 순서 문제도 없다). `pending_consumptions()` 가 tuple 을 반환
        # 하도록 설계한 것도 바로 이 이유다(모듈 docstring 참조).
        self.assertEqual(context.pending_consumptions(), ((store, "fp-1"),))


if __name__ == "__main__":
    unittest.main()
