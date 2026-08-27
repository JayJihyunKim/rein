"""plan Task 1.8 — 전 매핑 표 + Stop 강등 계약 테스트 (spec §2.4, §3.1).

고정하는 계약 2개:
- 매핑 표: 채택 hook 전부가 kernel 중립 어휘(EVENT_TYPES) 안의 이벤트로
  1:1 매핑된다. Stop 은 필수 채택이다 (spec §2.4).
- Stop 강등: Stop hook 은 interactive ask 를 지원하지 않으므로, engine 이
  ASK_USER 를 내면 adapter 가 native 응답을 BLOCK + 안내로 강등한다.
  engine 출력 자체는 ASK_USER 를 유지한다 — 강등 규칙은 platform/claude
  경계 안에서만 존재한다.
"""
import copy
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import runtime  # noqa: E402
from rein.engine.context import EvidenceStorageError  # noqa: E402
from rein.kernel.event import EVENT_TYPES  # noqa: E402
from rein.kernel.policy import parse_policy  # noqa: E402
from rein.platform.claude import adapter  # noqa: E402

# plan Task 1.8 — 채택 hook 전 매핑 (spec §3.1 의 §34 채택 원칙,
# Stop 포함 필수). 표가 바뀌면 이 테스트가 의도적 검토를 강제한다.
_EXPECTED_HOOKS = frozenset(
    (
        "PreToolUse",
        "PostToolUse",
        "TaskCreated",
        "TaskCompleted",
        "SubagentStart",
        "SubagentStop",
        "SessionStart",
        "Stop",
        "SessionEnd",
    )
)

_STOP_POLICY_ID = "require-user-approval-on-stop"
_STOP_POLICY_TEXT = (
    "trigger: session.stop\n"
    "require:\n"
    "  - user_approval\n"
    "failure_mode: ask_user\n"
)


class _BrokenEvidenceSource:
    """조회 자체가 실패하는 storage — Evaluation Failure 유도용."""

    def find(self, requirement_name):
        raise EvidenceStorageError("simulated storage corruption")


def _stop_policies():
    return [
        {
            "policy_id": _STOP_POLICY_ID,
            "fields": parse_policy(
                _STOP_POLICY_TEXT, source="inline:" + _STOP_POLICY_ID
            ),
        }
    ]


class HookMappingTableTest(unittest.TestCase):
    """spec §3.1 — 전 매핑 표 단위 테스트."""

    def test_adopted_hooks_match_expected_table(self):
        self.assertEqual(frozenset(adapter.HOOK_EVENT_NAMES), _EXPECTED_HOOKS)

    def test_stop_hook_is_adopted(self):
        self.assertIn("Stop", adapter.HOOK_EVENT_NAMES)

    def test_mapping_targets_stay_inside_kernel_vocabulary(self):
        for hook_name, event_name in adapter.HOOK_EVENT_NAMES.items():
            self.assertIn(
                event_name,
                EVENT_TYPES,
                msg=(
                    "{} → {!r} 는 kernel 중립 어휘 밖이다".format(
                        hook_name, event_name
                    )
                ),
            )

    def test_mapping_is_one_to_one(self):
        targets = list(adapter.HOOK_EVENT_NAMES.values())
        self.assertEqual(len(targets), len(set(targets)))

    def test_normalize_stop_payload(self):
        event = adapter.normalize_event({"hook_event_name": "Stop"})
        self.assertEqual(event["name"], adapter.HOOK_EVENT_NAMES["Stop"])
        self.assertEqual(event["payload"], {})


class StopDowngradeE2ETest(unittest.TestCase):
    """spec §2.4 — Stop e2e: native 는 차단+안내, engine 은 ASK_USER 유지."""

    def test_stop_ask_user_downgrades_to_native_block_with_guidance(self):
        # e2e: native payload → normalize → 실로더 policy → 평가 → native 응답
        event = adapter.normalize_event({"hook_event_name": "Stop"})
        engine_output = runtime.evaluate(
            event["name"],
            facts={},
            policies=_stop_policies(),
            evidence_source=_BrokenEvidenceSource(),
        )
        self.assertEqual(engine_output["decision"], "ASK_USER")

        snapshot = copy.deepcopy(engine_output)
        native = adapter.to_native_response("Stop", engine_output)

        # native 응답: 차단 + 안내 (spec §2.4 강등 계약)
        self.assertEqual(native["decision"], "block")
        self.assertIn("현재 작업을 종료할 수 없습니다", native["reason"])
        self.assertIn("사용자 확인이 필요합니다", native["reason"])

        # engine 출력은 ASK_USER 그대로 — 변환은 adapter 경계 안에서만
        self.assertEqual(engine_output, snapshot)
        self.assertEqual(engine_output["decision"], "ASK_USER")

    def test_stop_block_passes_reason_through(self):
        native = adapter.to_native_response(
            "Stop", {"decision": "BLOCK", "reason": "code_review 미충족"}
        )
        self.assertEqual(native["decision"], "block")
        self.assertIn("code_review 미충족", native["reason"])

    def test_stop_allow_is_noninterfering(self):
        native = adapter.to_native_response(
            "Stop", {"decision": "ALLOW", "reason": "no policy matched event"}
        )
        self.assertEqual(native, {})


class PreToolUseNativeAskTest(unittest.TestCase):
    """spec §2.4 — PreToolUse 의 ASK_USER 는 native ask 로 그대로 매핑."""

    def test_ask_user_maps_to_native_ask(self):
        native = adapter.to_native_response(
            "PreToolUse", {"decision": "ASK_USER", "reason": "사용자 판단 필요"}
        )
        output = native["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "ask")
        self.assertEqual(output["permissionDecisionReason"], "사용자 판단 필요")

    def test_block_maps_to_native_deny(self):
        native = adapter.to_native_response(
            "PreToolUse",
            {"decision": "BLOCK", "reason": "required evidence is missing"},
        )
        output = native["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertEqual(
            output["permissionDecisionReason"], "required evidence is missing"
        )

    def test_allow_is_noninterfering(self):
        # governance ALLOW 는 native 권한 흐름을 대체하지 않는다 (비간섭)
        native = adapter.to_native_response(
            "PreToolUse", {"decision": "ALLOW", "reason": "ok"}
        )
        self.assertEqual(native, {})


class NativeResponseInputContractTest(unittest.TestCase):
    def test_unknown_hook_is_rejected(self):
        with self.assertRaises(adapter.UnknownHookEventError):
            adapter.to_native_response(
                "NotAHook", {"decision": "ALLOW", "reason": "x"}
            )

    def test_unknown_decision_value_is_rejected(self):
        for bad in ({"decision": "MAYBE", "reason": "x"}, {"reason": "x"}):
            with self.assertRaises(ValueError, msg=repr(bad)):
                adapter.to_native_response("Stop", bad)


if __name__ == "__main__":
    unittest.main()
