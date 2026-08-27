"""plan Task 1.7 — failure_mode 경계 계약 (spec §3.4).

covers: failure-mode-triggers-only-on-evaluation-failure-never-on-missing-evidence

spec §3.4 원문 계약:
    "`failure_mode` 는 **판단 자체를 수행하지 못했을 때만** 적용
    (`closed`/`open`/`ask_user`): Evidence 부재 → 정상 평가 BLOCK
    (failure_mode 아님) / Evidence Storage parse 실패 → Evaluation
    Failure → failure_mode."

고정하는 경계:
- evidence 부재 = 정상 평가 BLOCK. policy 가 open/ask_user 를 선언해도
  절대 적용되지 않는다 (부재는 판단 불능이 아니다).
- failure_mode 는 판단 불능(EvidenceStorageError — storage 손상 등)에만
  적용되어 closed/open/ask_user 3분기 한다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import (  # noqa: E402
    EvaluationContext,
    EvidenceStorageError,
    FactResolutionError,
)
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
)

_FACTS = {"tool": "Bash"}
_REQUIREMENT = "code_review"


def _load_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태의 policy fixture."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


def _policy_with_failure_mode(policy_id, failure_mode):
    text = (
        "trigger: tool.pre\n"
        "when:\n"
        "  tool: Bash\n"
        "require:\n"
        "  - {}\n"
        "failure_mode: {}\n"
    ).format(_REQUIREMENT, failure_mode)
    return _load_policy(policy_id, text)


class _CorruptedEvidenceSource:
    """storage 손상 주입 — 조회 자체가 실패한다 (판단 불능)."""

    def find(self, requirement_name):
        raise EvidenceStorageError(
            "evidence storage is corrupted: unreadable index"
        )


class _PresentEvidenceSource:
    """모든 requirement 에 evidence 레코드 1건이 존재하는 소스."""

    def find(self, requirement_name):
        return ({"type": requirement_name},)


class _SelectiveEvidenceSource:
    """requirement 별 상태를 지정하는 소스 — 복수 policy 상호작용용.

    present 목록은 레코드 1건 존재, broken 목록은 조회 실패(판단 불능),
    나머지는 정상 조회 결과 0건(부재).
    """

    def __init__(self, present=(), broken=()):
        self._present = frozenset(present)
        self._broken = frozenset(broken)

    def find(self, requirement_name):
        if requirement_name in self._broken:
            raise EvidenceStorageError(
                "evidence storage is corrupted for {}".format(requirement_name)
            )
        if requirement_name in self._present:
            return ({"type": requirement_name},)
        return ()


class MissingEvidenceIsNormalBlockTest(unittest.TestCase):
    """evidence 부재는 정상 평가 BLOCK — failure_mode 미적용."""

    def _evaluate_with_absent_evidence(self, failure_mode):
        # 기본 evidence source = 전부 '부재' (판단은 정상 수행됨)
        return evaluator.evaluate(
            "tool.pre",
            EvaluationContext(facts=_FACTS),
            [_policy_with_failure_mode("gate", failure_mode)],
        )

    def test_missing_evidence_blocks_even_with_fail_open_policy(self):
        decision = self._evaluate_with_absent_evidence("open")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (_REQUIREMENT,))

    def test_missing_evidence_blocks_even_with_ask_user_policy(self):
        decision = self._evaluate_with_absent_evidence("ask_user")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (_REQUIREMENT,))

    def test_missing_evidence_reason_is_normal_evaluation_not_failure(self):
        decision = self._evaluate_with_absent_evidence("closed")
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_present_evidence_satisfies_requirement(self):
        decision = evaluator.evaluate(
            "tool.pre",
            EvaluationContext(
                facts=_FACTS, evidence_source=_PresentEvidenceSource()
            ),
            [_policy_with_failure_mode("gate", "closed")],
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())


class NormalBlockAttributionTest(unittest.TestCase):
    """정상 평가 BLOCK 의 policy 귀속 — missing 을 만든 policy 로 (M-1).

    첫 trigger/when 매칭 policy 가 아니라 **첫 missing requirement 를
    만든 policy** 가 BLOCK 을 소유한다 — 판단 불능 경로의
    _resolve_failure 귀속(실패한 policy)과 대칭.
    """

    def test_block_skips_requirementless_first_match(self):
        # (a) require 없는 a-log 가 먼저 매칭돼도 BLOCK 은 b-gate 소유
        a_log = _load_policy("a-log", "trigger: tool.pre\n")
        b_gate = _load_policy(
            "b-gate",
            "trigger: tool.pre\nrequire:\n  - code_review\n",
        )
        decision = evaluator.evaluate(
            "tool.pre", EvaluationContext(facts=_FACTS), [a_log, b_gate]
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "b-gate")
        self.assertEqual(decision.missing_requirements, ("code_review",))

    def test_block_skips_satisfied_first_match(self):
        # (b) 요구 충족한 a-gate 가 먼저 매칭돼도 BLOCK 은 부재 b-gate 소유
        a_gate = _load_policy(
            "a-gate",
            "trigger: tool.pre\nrequire:\n  - code_review\n",
        )
        b_gate = _load_policy(
            "b-gate",
            "trigger: tool.pre\nrequire:\n  - tests_passed\n",
        )
        context = EvaluationContext(
            facts=_FACTS,
            evidence_source=_SelectiveEvidenceSource(present=("code_review",)),
        )
        decision = evaluator.evaluate("tool.pre", context, [a_gate, b_gate])
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "b-gate")
        self.assertEqual(decision.missing_requirements, ("tests_passed",))


class MultiPolicyInteractionTest(unittest.TestCase):
    """복수 policy 상호작용 경계 (L-1)."""

    def test_mixed_failure_modes_converge_to_closed_with_attribution(self):
        # open+closed 혼재 판단 불능 → closed 수렴 + closed policy 귀속
        aux_log = _load_policy(
            "aux-log",
            "trigger: tool.pre\nrequire:\n  - tests_passed\n"
            "failure_mode: open\n",
        )
        critical_gate = _load_policy(
            "critical-gate",
            "trigger: tool.pre\nrequire:\n  - code_review\n"
            "failure_mode: closed\n",
        )
        context = EvaluationContext(
            facts=_FACTS,
            evidence_source=_SelectiveEvidenceSource(
                broken=("tests_passed", "code_review")
            ),
        )
        decision = evaluator.evaluate(
            "tool.pre", context, [aux_log, critical_gate]
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "critical-gate")
        self.assertIn("closed", decision.reason)

    def test_missing_evidence_block_survives_other_policy_fail_open(self):
        # 부재 BLOCK + 타 policy fail-open 판단 불능 → BLOCK 유지
        gate = _load_policy(
            "gate",
            "trigger: tool.pre\nrequire:\n  - code_review\n"
            "failure_mode: closed\n",
        )
        aux_log = _load_policy(
            "aux-log",
            "trigger: tool.pre\nrequire:\n  - tests_passed\n"
            "failure_mode: open\n",
        )
        context = EvaluationContext(
            facts=_FACTS,
            evidence_source=_SelectiveEvidenceSource(broken=("tests_passed",)),
        )
        decision = evaluator.evaluate("tool.pre", context, [gate, aux_log])
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "gate")
        self.assertEqual(decision.missing_requirements, ("code_review",))
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)


class EvaluationFailureBranchTest(unittest.TestCase):
    """판단 불능(storage 손상)일 때만 failure_mode 3분기."""

    def _evaluate_with_corrupted_storage(self, failure_mode):
        context = EvaluationContext(
            facts=_FACTS, evidence_source=_CorruptedEvidenceSource()
        )
        return evaluator.evaluate(
            "tool.pre",
            context,
            [_policy_with_failure_mode("critical-gate", failure_mode)],
        )

    def test_failure_mode_closed_blocks(self):
        decision = self._evaluate_with_corrupted_storage("closed")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        # 부재 BLOCK 과 구분: 판단 불능은 missing 목록이 아니라 실패 사유
        self.assertEqual(decision.missing_requirements, ())
        self.assertNotEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)
        self.assertIn(_REQUIREMENT, decision.reason)
        self.assertEqual(decision.policy, "critical-gate")

    def test_failure_mode_open_allows_with_warning_reason(self):
        decision = self._evaluate_with_corrupted_storage("open")
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertIn("warning", decision.reason)
        self.assertIn(_REQUIREMENT, decision.reason)

    def test_failure_mode_ask_user_defers_to_user(self):
        decision = self._evaluate_with_corrupted_storage("ask_user")
        self.assertEqual(decision.decision, DECISION_ASK_USER)
        self.assertIn(_REQUIREMENT, decision.reason)

    def test_unknown_failure_mode_fails_closed(self):
        # 로더를 우회한 fields 라도 evaluator 는 fail-closed 로 처리한다
        bypassed = {
            "policy_id": "bypassed",
            "fields": {
                "trigger": "tool.pre",
                "when": {"tool": "Bash"},
                "require": ["code_review"],
                "failure_mode": "banana",
            },
        }
        context = EvaluationContext(
            facts=_FACTS, evidence_source=_CorruptedEvidenceSource()
        )
        decision = evaluator.evaluate("tool.pre", context, [bypassed])
        self.assertEqual(decision.decision, DECISION_BLOCK)

    def test_runtime_forwards_evidence_source_to_evaluator(self):
        # runtime dict 인터페이스로도 failure 분기가 그대로 도달해야 한다
        result = runtime.evaluate(
            "tool.pre",
            dict(_FACTS),
            [_policy_with_failure_mode("critical-gate", "ask_user")],
            evidence_source=_CorruptedEvidenceSource(),
        )
        self.assertEqual(result["decision"], DECISION_ASK_USER)


class _StubRequirementImplementation:
    """registry 위임 경계 검증용 스텁 — 지정된 결과/예외를 그대로 낸다."""

    name = _REQUIREMENT

    def __init__(self, outcome):
        self._outcome = outcome

    def evaluate(self, context):
        if isinstance(self._outcome, Exception):
            raise self._outcome
        return self._outcome


class RegistryDelegationBoundaryTest(unittest.TestCase):
    """Task 3.1 배선 (리뷰 1회차 시정) — registry 주입 위임 경계.

    registry 에 등록 구현체가 있는 requirement 는 충족 판정이
    `implementation.evaluate(context)` 로 위임된다 — '존재 = 충족'
    단순화는 등록 구현체에 더 이상 적용되지 않는다. 위임 evaluate 가
    던지는 EvidenceStorageError 계열(FactResolutionError 포함)은 기존
    evidence_for 경로와 동일하게 failure_mode 로 분기한다 (판단 불능 ≠
    부재 경계 유지, spec §3.4). registry=None(기본)·미등록 requirement
    는 기존 존재 검사 fallback 을 유지한다.
    """

    def _registry_with(self, outcome):
        registry = RequirementRegistry()
        registry.register(
            _REQUIREMENT, _StubRequirementImplementation(outcome)
        )
        return registry

    def _evaluate(self, outcome, failure_mode="closed", evidence_source=None):
        context = EvaluationContext(
            facts=_FACTS, evidence_source=evidence_source
        )
        return evaluator.evaluate(
            "tool.pre",
            context,
            [_policy_with_failure_mode("gate", failure_mode)],
            registry=self._registry_with(outcome),
        )

    def test_delegated_true_allows(self):
        decision = self._evaluate(True)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_delegated_false_overrides_evidence_existence(self):
        # 레코드가 '존재' 해도 위임 판정이 False 면 정상 평가 BLOCK —
        # 존재 검사 단순화가 등록 구현체를 우회하지 못한다
        decision = self._evaluate(
            False, evidence_source=_PresentEvidenceSource()
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (_REQUIREMENT,))
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_delegated_storage_error_takes_failure_mode_branch(self):
        # 위임 evaluate 의 판단 불능은 failure_mode 3분기 대상이다 —
        # FactResolutionError(EvidenceStorageError 하위)로 계열 포함 검증
        decision = self._evaluate(
            FactResolutionError("digest fact resolution failed"),
            failure_mode="ask_user",
        )
        self.assertEqual(decision.decision, DECISION_ASK_USER)
        self.assertEqual(decision.missing_requirements, ())
        self.assertNotEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)
        self.assertIn(_REQUIREMENT, decision.reason)

    def test_unregistered_requirement_falls_back_to_existence_check(self):
        # registry 가 주입돼도 미등록 requirement 는 기존 존재 검사 유지
        # (다른 4종 capability 미배선 보존)
        empty_registry = RequirementRegistry()
        context = EvaluationContext(
            facts=_FACTS, evidence_source=_PresentEvidenceSource()
        )
        decision = evaluator.evaluate(
            "tool.pre",
            context,
            [_policy_with_failure_mode("gate", "closed")],
            registry=empty_registry,
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)


if __name__ == "__main__":
    unittest.main()
