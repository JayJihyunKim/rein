"""plan Task 1.7 — evaluator 기본 ALLOW 경계 (spec §3.4).

covers: evaluator-returns-allow-with-reason-when-no-requirement-matches-event

requirement 미매칭 이벤트(정책 0개 / trigger 불일치 / when 불일치)는 기본
ALLOW 이며 reason 을 항상 동반한다. runtime 재배선 계약도 여기서 고정한다:
- policy 로드는 kernel/policy.py 폐쇄 로더 단일 경로 (walking-skeleton
  자체 파서 제거, PolicyLoadError 동일 클래스 — except 절이 조용히 안
  잡히는 동명 클래스 2개 함정 방지)
- 미지 requirement 이름은 로드 시점 명시 거부 유지
- runtime.evaluate 는 cli 왕복 계약(dict + 5필드)을 보존
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

from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, Decision  # noqa: E402

_DECISION_SERIALIZED_FIELDS = (
    "decision",
    "reason",
    "policy",
    "missing_requirements",
    "evidence_refs",
)


def _load_inline_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태로 policy fixture 를 만든다."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


_BASH_REVIEW_POLICY = _load_inline_policy(
    "require-review-on-bash",
    "trigger: tool.pre\n"
    "when:\n"
    "  tool: Bash\n"
    "require:\n"
    "  - code_review\n"
    "failure_mode: closed\n",
)


class DefaultAllowTest(unittest.TestCase):
    """spec §3.4 — requirement 미매칭 이벤트는 기본 ALLOW + reason."""

    def test_no_policies_returns_allow_with_reason(self):
        decision = evaluator.evaluate(
            "tool.pre", EvaluationContext(facts={"tool": "Bash"}), []
        )
        self.assertIsInstance(decision, Decision)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertTrue(decision.reason)
        self.assertIsNone(decision.policy)
        self.assertEqual(decision.missing_requirements, ())

    def test_trigger_mismatch_returns_allow_with_reason(self):
        decision = evaluator.evaluate(
            "task.completed",
            EvaluationContext(facts={"tool": "Bash"}),
            [_BASH_REVIEW_POLICY],
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertTrue(decision.reason)
        self.assertIsNone(decision.policy)

    def test_when_mismatch_returns_allow_with_reason(self):
        decision = evaluator.evaluate(
            "tool.pre",
            EvaluationContext(facts={"tool": "Read"}),
            [_BASH_REVIEW_POLICY],
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertTrue(decision.reason)
        self.assertIsNone(decision.policy)

    def test_matched_policy_without_requirements_allows_with_policy_id(self):
        log_only = _load_inline_policy("log-only", "trigger: tool.pre\n")
        decision = evaluator.evaluate(
            "tool.pre", EvaluationContext(facts={"tool": "Bash"}), [log_only]
        )
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.policy, "log-only")
        self.assertTrue(decision.reason)

    def test_default_allow_serializes_all_contract_fields(self):
        decision = evaluator.evaluate(
            "tool.pre", EvaluationContext(facts={}), []
        )
        payload = decision.to_dict()
        for field in _DECISION_SERIALIZED_FIELDS:
            self.assertIn(field, payload)


class RuntimeRewiringTest(unittest.TestCase):
    """plan Task 1.7 — runtime 이 kernel 로더·evaluator 로 재배선됨."""

    def test_policy_load_error_is_the_kernel_class(self):
        # 동명 클래스 2개면 except 절이 조용히 안 잡힌다 — 동일성으로 고정
        self.assertIs(runtime.PolicyLoadError, kernel_policy.PolicyLoadError)

    def test_walking_skeleton_parser_is_removed(self):
        self.assertFalse(hasattr(runtime, "_parse_policy"))

    def test_load_policies_rejects_unknown_requirement_name(self):
        # 미지 requirement 이름 로드 시점 거부 유지 확인 (Task 1.5 계약)
        with tempfile.TemporaryDirectory() as policy_dir:
            path = os.path.join(policy_dir, "custom.yaml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "trigger: tool.pre\nrequire:\n  - custom_gate\n"
                )
            with self.assertRaises(runtime.PolicyLoadError) as caught:
                runtime.load_policies(policy_dir)
            self.assertIn("custom_gate", str(caught.exception))

    def test_evaluate_keeps_dict_interface_for_cli(self):
        # cli/__init__ 는 dict 를 받아 facts 를 동봉한다 — 인터페이스 보존
        result = runtime.evaluate("tool.pre", {"tool": "Bash"}, [])
        self.assertIsInstance(result, dict)
        self.assertEqual(result["decision"], DECISION_ALLOW)
        for field in _DECISION_SERIALIZED_FIELDS:
            self.assertIn(field, result)


if __name__ == "__main__":
    unittest.main()
