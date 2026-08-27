"""plan Task 1.7/2.2 — Phase 6 4회차 리뷰 Medium 3 시정 (spec §3.2/§3.4).

`evaluator.evaluate()` 의 policy 매칭 단계(`when:` 조건 계산, `context.
fact(key)` 호출)는 requirement 평가 단계(`_requirement_satisfied` →
`context.evidence_for`)와 마찬가지로 `EvidenceStorageError` 계열
(`FactResolutionError` 포함)에 대해 failure_mode 3분기를 타야 한다.

이전 구현은 이 조건 계산을 try/except 밖에 두었다 — requirement 평가
경로만 판단 불능을 잡았다. `tests/unit/test_lazy_fact_resolution.py` 의
`ResolutionFailureEscalationTest.test_when_matching_failure_propagates_to_caller`
가 이 상태를 "미해결 위험"으로 명시적으로 문서화하고 있었다(그 테스트
자신의 docstring: "이 전파 자체는 안전 계약이 아니라 미해결 상태의
기록이다 ... resolver 실배선 전 봉합 대상"). resolver 가 실제로 배선된
지금(`rein.cli._build_fact_resolvers`), 그 예외는 policy 가 선언한
failure_mode 를 완전히 무시하고 evaluate() 밖까지 raw 예외로 전파됐다 —
호출자가 어떤 failure_mode 를 선언했든(예: 'open' = 경고와 함께 ALLOW)
그 의미가 소실되고 대신 Python 예외 처리를 강제했다.

리뷰어 재현: 실패 모드가 'open' 인 정책 + resolver 오류 → (수정 전)
Decision 대신 예외.

이 스위트는 `rein.engine.evaluator.evaluate()`가 이제 이 실패도
requirement 판단 불능과 동일하게 Decision 으로 수렴시키는지, 그리고
기존 spec §3.4 경계("정상 평가 BLOCK 이 다른 policy 의 판단 불능(fail-open
포함)보다 우선한다")가 조건 계산 경로에서 나는 실패에도 그대로 유지되는지
고정한다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import evaluator  # noqa: E402
from rein.engine.context import (  # noqa: E402
    FACT_COST_CHEAP,
    EvaluationContext,
    FactResolverRegistry,
)
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
)

_FACT_KEY = "changeset.digest"


def _load_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태의 policy fixture."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


def _when_policy(policy_id, failure_mode=None):
    text = "trigger: tool.pre\nwhen:\n  {}: abc\n".format(_FACT_KEY)
    if failure_mode is not None:
        text += "failure_mode: {}\n".format(failure_mode)
    return _load_policy(policy_id, text)


def _broken_resolver_registry(fact_key=_FACT_KEY):
    def _boom(context):
        raise RuntimeError("git backend unreachable")

    registry = FactResolverRegistry()
    registry.register(fact_key, _boom, FACT_COST_CHEAP)
    return registry


class ConditionFailureTakesFailureModeBranchTest(unittest.TestCase):
    """when 조건 계산 중 예외 → Decision(failure_mode 분기). 예외 전파 아님."""

    def test_open_failure_mode_allows_with_warning_instead_of_raising(self):
        gate = _when_policy("gate", failure_mode="open")
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate("tool.pre", context, [gate])
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertIn("warning", decision.reason)
        self.assertIn("gate", decision.reason)

    def test_closed_failure_mode_blocks_instead_of_raising(self):
        gate = _when_policy("gate", failure_mode="closed")
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate("tool.pre", context, [gate])
        self.assertEqual(decision.decision, DECISION_BLOCK)
        # REASON_NO_MATCH 로 삼켜지지 않았다는 사실을 직접 고정한다 — 이
        # policy 는 `when` 계산 실패로 절대 matched_policy_id 를 채우지
        # 못하므로, 이 재정렬이 없으면 "무관한 이벤트"로 오인됐을 것.
        self.assertNotEqual(decision.reason, evaluator.REASON_NO_MATCH)
        self.assertIn("gate", decision.reason)

    def test_ask_user_failure_mode_defers_instead_of_raising(self):
        gate = _when_policy("gate", failure_mode="ask_user")
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate("tool.pre", context, [gate])
        self.assertEqual(decision.decision, DECISION_ASK_USER)

    def test_default_failure_mode_is_closed_when_omitted(self):
        # failure_mode 미선언 → kernel 폐쇄 스키마 기본값(closed)
        gate = _when_policy("gate", failure_mode=None)
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate("tool.pre", context, [gate])
        self.assertEqual(decision.decision, DECISION_BLOCK)

    def test_missing_evidence_block_from_other_policy_still_wins(self):
        # spec §3.4 경계 보존 — 정상 평가 BLOCK 은 다른 policy 의 판단
        # 불능(fail-open 포함)에 흔들리지 않는다. 이 판단 불능이
        # requirement 평가가 아니라 when 조건 계산에서 나도 동일해야
        # 한다 (MultiPolicyInteractionTest.
        # test_missing_evidence_block_survives_other_policy_fail_open 의
        # when-조건 판 대응).
        blocked = _load_policy(
            "blocked", "trigger: tool.pre\nrequire:\n  - code_review\n"
        )
        broken_when = _when_policy("broken-when", failure_mode="open")
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate(
            "tool.pre", context, [blocked, broken_when]
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "blocked")
        self.assertEqual(decision.missing_requirements, ("code_review",))
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_multiple_condition_failures_converge_to_most_conservative_mode(self):
        open_gate = _when_policy("open-gate", failure_mode="open")
        closed_gate = _when_policy("closed-gate", failure_mode="closed")
        context = EvaluationContext(fact_resolvers=_broken_resolver_registry())
        decision = evaluator.evaluate(
            "tool.pre", context, [open_gate, closed_gate]
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "closed-gate")

    def test_working_resolver_is_unaffected_by_the_new_try_except(self):
        # 대조군 — 정상 resolver 는 새 try/except 의 영향을 받지 않는다
        # (조건이 실제로 불일치하면 그냥 스킵).
        registry = FactResolverRegistry()
        registry.register(_FACT_KEY, lambda context: "xyz", FACT_COST_CHEAP)
        gate = _when_policy("gate", failure_mode="closed")
        decision = evaluator.evaluate(
            "tool.pre", EvaluationContext(fact_resolvers=registry), [gate]
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.reason, evaluator.REASON_NO_MATCH)


if __name__ == "__main__":
    unittest.main()
