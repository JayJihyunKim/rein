"""plan Task 1.3 — kernel 데이터 모델 (event / fact / decision) 계약 테스트.

고정하는 계약 2개:
- spec §3.2: Event 는 작게 유지 — `commit.requested` 류 Domain Event type 생성은
  거부되고, 의미는 Fact 로 표현된다 (event=tool.pre, facts: command.type=git.commit).
- spec §3.4: Decision 직렬화는 `decision`·`reason`·`policy`·`missing_requirements`
  ·`evidence_refs` 5필드를 값이 비어도 항상 포함한다.
"""
import json
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
    DECISIONS,
    Decision,
)
from rein.kernel.event import EVENT_TYPES, DomainEventError, Event  # noqa: E402
from rein.kernel.fact import Fact  # noqa: E402

_DECISION_SERIALIZED_FIELDS = (
    "decision",
    "reason",
    "policy",
    "missing_requirements",
    "evidence_refs",
)


class EventDomainBanTest(unittest.TestCase):
    """spec §3.2 — Domain Event 금지 계약."""

    def test_domain_event_types_are_rejected(self):
        for domain_type in ("commit.requested", "push.requested", "review.completed"):
            with self.assertRaises(DomainEventError, msg=domain_type):
                Event(type=domain_type)

    def test_rejection_is_a_value_error_and_points_to_fact(self):
        with self.assertRaises(ValueError) as ctx:
            Event(type="commit.requested")
        message = str(ctx.exception)
        self.assertIn("commit.requested", message)
        self.assertIn("Fact", message)

    def test_domain_semantics_are_expressed_as_facts(self):
        # spec §3.2 예시 그대로: event = tool.pre,
        # facts: tool.type=bash, command.type=git.commit
        event = Event(type="tool.pre")
        facts = (
            Fact(key="tool.type", value="bash"),
            Fact(key="command.type", value="git.commit"),
        )
        self.assertEqual(event.type, "tool.pre")
        self.assertEqual(
            {(fact.key, fact.value) for fact in facts},
            {("tool.type", "bash"), ("command.type", "git.commit")},
        )

    def test_declared_kernel_vocabulary_is_accepted(self):
        for event_type in EVENT_TYPES:
            self.assertEqual(Event(type=event_type).type, event_type)

    def test_vocabulary_stays_small(self):
        # "Event 는 작게 유지" — 어휘가 커지면 이 테스트가 의도적 검토를 강제한다.
        self.assertLessEqual(len(EVENT_TYPES), 12)

    def test_payload_defaults_to_empty_dict(self):
        self.assertEqual(Event(type="tool.pre").payload, {})


class FactTest(unittest.TestCase):
    def test_fact_carries_key_value(self):
        fact = Fact(key="git.branch", value="dev")
        self.assertEqual(fact.key, "git.branch")
        self.assertEqual(fact.value, "dev")

    def test_fact_requires_nonempty_string_key(self):
        for bad_key in ("", None, 3):
            with self.assertRaises(ValueError, msg=repr(bad_key)):
                Fact(key=bad_key, value="x")


class DecisionSerializationTest(unittest.TestCase):
    """spec §3.4 — 최소 5필드 상시 포함."""

    def test_block_serialization_includes_all_five_fields(self):
        decision = Decision(
            decision=DECISION_BLOCK,
            reason="code_review evidence 부재",
            policy="require-review-on-bash",
            missing_requirements=["code_review"],
            evidence_refs=[],
        )
        payload = decision.to_dict()
        for field_name in _DECISION_SERIALIZED_FIELDS:
            self.assertIn(field_name, payload)
        self.assertEqual(payload["decision"], DECISION_BLOCK)
        self.assertEqual(payload["policy"], "require-review-on-bash")
        self.assertEqual(payload["missing_requirements"], ["code_review"])
        self.assertEqual(payload["evidence_refs"], [])

    def test_ask_user_serialization_includes_five_fields_even_when_empty(self):
        decision = Decision(
            decision=DECISION_ASK_USER, reason="사용자 판단 필요"
        )
        payload = decision.to_dict()
        for field_name in _DECISION_SERIALIZED_FIELDS:
            self.assertIn(field_name, payload)
        self.assertIsNone(payload["policy"])
        self.assertEqual(payload["missing_requirements"], [])
        self.assertEqual(payload["evidence_refs"], [])

    def test_serialization_is_json_ready(self):
        decision = Decision(
            decision=DECISION_BLOCK,
            reason="r",
            policy="p",
            missing_requirements=("tests_passed",),
            evidence_refs=("evidence:1",),
        )
        roundtrip = json.loads(json.dumps(decision.to_dict()))
        self.assertEqual(roundtrip["missing_requirements"], ["tests_passed"])
        self.assertEqual(roundtrip["evidence_refs"], ["evidence:1"])

    def test_to_dict_returns_fresh_lists(self):
        decision = Decision(
            decision=DECISION_BLOCK,
            reason="r",
            policy="p",
            missing_requirements=["code_review"],
        )
        decision.to_dict()["missing_requirements"].append("tampered")
        self.assertEqual(
            decision.to_dict()["missing_requirements"], ["code_review"]
        )

    def test_unknown_decision_value_is_rejected(self):
        with self.assertRaises(ValueError):
            Decision(decision="MAYBE", reason="x")

    def test_single_string_requirement_list_is_rejected(self):
        # tuple("abc") 의 문자 단위 분해를 조용히 직렬화하지 않는다
        with self.assertRaises(ValueError):
            Decision(
                decision=DECISION_BLOCK,
                reason="r",
                missing_requirements="code_review",
            )

    def test_decision_constants(self):
        self.assertEqual(
            DECISIONS, (DECISION_ALLOW, DECISION_BLOCK, DECISION_ASK_USER)
        )


if __name__ == "__main__":
    unittest.main()
