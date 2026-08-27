"""plan Task 4.6 — Loop Controller: No Progress Detection + Attempt Budget (spec §3.7 §22).

spec §3.7 원문 인용:
    "v1 Review Loop Budget(5회 + `[MAX_ROUNDS:]` extension, v1.6.5)과
    신규 Circuit Breaker 를 하나의 Loop Controller 로 통합 — 이중 운영
    금지, 마이그레이션 시 기존 budget 을 흡수한다.

    - No Progress Detection: `progress_digest = change_digest + missing
      requirements + evidence state + policy version`. 동일 상태 반복
      (기본 2회) → ASK_USER.
    - Absolute Attempt Budget: progress 는 있으나 반복 과다 → budget 에서
      중단."

검증 축 (plan Task 4.6 steps):
(a) 동일 progress_digest 2회 연속 → ASK_USER.
(b) progress 있음(다른 digest)이지만 budget(기본 5) 소진 → 중단 신호
    (ASK_USER 와 구분되는 전용 어휘 `SIGNAL_BUDGET_EXHAUSTED`).
(c) 명시 연장(정수 한도) 허용 + 기본 상한 초과 연장은 `extension_history`
    로 노출.
(d) 카운터 단일성 — controller 인스턴스가 유일한 계수 주체. 스냅샷
    왕복(직렬화→재구성) 후에도 계수가 이어지고, 서로 다른 인스턴스는
    상태를 공유하지 않는다. 소스 정적 검사로 외부 카운터 파일 미참조도
    함께 고정한다.
(e) progress_digest 4요소 각각이 결과에 기여 — 한 요소만 바뀌어도 다른
    digest, 프레이밍 마커로 연접 충돌 없음.

이 테스트 모듈은 `rein.capabilities.*` 를 어떤 형태로도 import 하지
않는다(모듈 docstring "capability 간 직접 의존 금지" 원칙과 동형 —
Loop Controller 는 kernel 어휘만 소비한다).
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine.loop_controller import (  # noqa: E402
    DEFAULT_ATTEMPT_BUDGET,
    DEFAULT_NO_PROGRESS_THRESHOLD,
    SIGNAL_ASK_USER,
    SIGNAL_BUDGET_EXHAUSTED,
    SIGNAL_CONTINUE,
    SIGNALS,
    LoopController,
    LoopControllerError,
    LoopSignal,
    progress_digest,
)
from rein.kernel.decision import DECISION_ASK_USER  # noqa: E402


class ProgressDigestVocabularyTest(unittest.TestCase):
    """모듈 상수 어휘가 kernel Decision 과 의도한 지점에서만 겹친다."""

    def test_ask_user_signal_reuses_kernel_decision_vocabulary(self):
        self.assertEqual(SIGNAL_ASK_USER, DECISION_ASK_USER)

    def test_budget_exhausted_signal_is_distinct_from_ask_user(self):
        # 두 halt 신호가 다른 이유 — 모듈 docstring 참조
        self.assertNotEqual(SIGNAL_BUDGET_EXHAUSTED, SIGNAL_ASK_USER)
        self.assertNotIn(SIGNAL_BUDGET_EXHAUSTED, (SIGNAL_ASK_USER,))

    def test_signals_closed_set(self):
        self.assertEqual(
            frozenset(SIGNALS),
            frozenset((SIGNAL_CONTINUE, SIGNAL_ASK_USER, SIGNAL_BUDGET_EXHAUSTED)),
        )


class NoProgressDetectionTest(unittest.TestCase):
    """(a) 동일 progress_digest 2회 연속 → ASK_USER."""

    def test_two_identical_digests_trigger_ask_user(self):
        controller = LoopController()
        first = controller.record_attempt("digestA", ("code_review",), {}, "1")
        self.assertEqual(first.signal, SIGNAL_CONTINUE)
        second = controller.record_attempt("digestA", ("code_review",), {}, "1")
        self.assertEqual(second.signal, SIGNAL_ASK_USER)
        self.assertEqual(second.repeat_count, 2)
        self.assertEqual(second.attempt, 2)

    def test_single_repeat_does_not_trigger_by_default(self):
        controller = LoopController()
        result = controller.record_attempt("digestA", ("code_review",), {}, "1")
        self.assertEqual(result.signal, SIGNAL_CONTINUE)
        self.assertEqual(result.repeat_count, 1)

    def test_progress_between_repeats_resets_repeat_count(self):
        controller = LoopController()
        controller.record_attempt("digestA", ("code_review",), {}, "1")
        changed = controller.record_attempt("digestB", ("code_review",), {}, "1")
        self.assertEqual(changed.signal, SIGNAL_CONTINUE)
        self.assertEqual(changed.repeat_count, 1)
        # 진행 후 다시 반복이 시작되면 repeat_count 는 1부터 다시 샌다
        repeat_again = controller.record_attempt(
            "digestB", ("code_review",), {}, "1"
        )
        self.assertEqual(repeat_again.signal, SIGNAL_ASK_USER)
        self.assertEqual(repeat_again.repeat_count, 2)

    def test_custom_threshold_requires_more_repeats(self):
        controller = LoopController(no_progress_threshold=3)
        first = controller.record_attempt("digestA", (), {}, "1")
        second = controller.record_attempt("digestA", (), {}, "1")
        third = controller.record_attempt("digestA", (), {}, "1")
        self.assertEqual(first.signal, SIGNAL_CONTINUE)
        self.assertEqual(second.signal, SIGNAL_CONTINUE)
        self.assertEqual(third.signal, SIGNAL_ASK_USER)

    def test_default_no_progress_threshold_constant(self):
        self.assertEqual(DEFAULT_NO_PROGRESS_THRESHOLD, 2)


class AttemptBudgetTest(unittest.TestCase):
    """(b) progress 있으나 budget 소진 → BUDGET_EXHAUSTED (ASK_USER 아님)."""

    def _distinct_digests_controller(self, budget=None):
        controller = (
            LoopController() if budget is None else LoopController(budget=budget)
        )
        return controller

    def test_budget_exhausted_when_every_attempt_makes_progress(self):
        controller = self._distinct_digests_controller(budget=5)
        results = []
        for index in range(5):
            results.append(
                controller.record_attempt(
                    "digest-{}".format(index), (), {}, "1"
                )
            )
        for result in results[:4]:
            self.assertEqual(result.signal, SIGNAL_CONTINUE)
        self.assertEqual(results[-1].signal, SIGNAL_BUDGET_EXHAUSTED)
        self.assertEqual(results[-1].attempt, 5)
        self.assertEqual(results[-1].budget, 5)

    def test_budget_exhausted_is_not_ask_user(self):
        controller = LoopController(budget=2)
        controller.record_attempt("digest-0", (), {}, "1")
        result = controller.record_attempt("digest-1", (), {}, "1")
        self.assertEqual(result.signal, SIGNAL_BUDGET_EXHAUSTED)
        self.assertNotEqual(result.signal, SIGNAL_ASK_USER)

    def test_default_attempt_budget_constant(self):
        self.assertEqual(DEFAULT_ATTEMPT_BUDGET, 5)

    def test_default_controller_absorbs_v1_five_round_budget(self):
        # v1 Review Loop Budget 기본값(5회) 흡수 — spec §3.7/§6.3
        controller = LoopController()
        self.assertEqual(controller.budget, 5)

    def test_no_progress_takes_priority_over_budget_on_same_call(self):
        # 같은 digest 가 반복되면서 그 시도가 마침 budget 도 소진하는
        # 경계 — 더 구체적인 원인(교착)이 우선한다 (모듈 docstring 참조)
        controller = LoopController(budget=2, no_progress_threshold=2)
        controller.record_attempt("digestA", (), {}, "1")
        result = controller.record_attempt("digestA", (), {}, "1")
        self.assertEqual(result.signal, SIGNAL_ASK_USER)

    def test_budget_must_be_positive_int(self):
        with self.assertRaises(LoopControllerError):
            LoopController(budget=0)
        with self.assertRaises(LoopControllerError):
            LoopController(budget=-1)
        with self.assertRaises(LoopControllerError):
            LoopController(budget=True)  # bool은 int 서브클래스 — 명시 거부
        with self.assertRaises(LoopControllerError):
            LoopController(budget="5")

    def test_threshold_must_be_at_least_two(self):
        with self.assertRaises(LoopControllerError):
            LoopController(no_progress_threshold=1)
        with self.assertRaises(LoopControllerError):
            LoopController(no_progress_threshold=0)


class ExtendBudgetTest(unittest.TestCase):
    """(c) 명시 연장(정수 한도) 허용 + 기본 상한 초과 연장은 이력 노출."""

    def test_extend_budget_allows_more_attempts(self):
        controller = LoopController(budget=2)
        controller.record_attempt("d0", (), {}, "1")
        exhausted = controller.record_attempt("d1", (), {}, "1")
        self.assertEqual(exhausted.signal, SIGNAL_BUDGET_EXHAUSTED)

        controller.extend_budget(4, reason="user asked to continue")
        continued = controller.record_attempt("d2", (), {}, "1")
        self.assertEqual(continued.signal, SIGNAL_CONTINUE)
        self.assertEqual(continued.budget, 4)
        self.assertTrue(continued.extended)

    def test_extension_history_exposes_extension_above_default(self):
        controller = LoopController(budget=5)
        entry = controller.extend_budget(8, reason="explicit user extension")
        self.assertEqual(entry["previous_budget"], 5)
        self.assertEqual(entry["new_budget"], 8)
        self.assertTrue(entry["exceeds_default"])
        self.assertEqual(entry["reason"], "explicit user extension")
        history = controller.extension_history
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0], entry)

    def test_extension_history_is_immutable_copy(self):
        controller = LoopController(budget=5)
        controller.extend_budget(6)
        history = controller.extension_history
        history[0]["new_budget"] = 999  # 반환된 사본을 변경해도 내부는 불변
        self.assertEqual(controller.extension_history[0]["new_budget"], 6)

    def test_extend_budget_rejects_non_increasing_value(self):
        controller = LoopController(budget=5)
        with self.assertRaises(LoopControllerError):
            controller.extend_budget(5)
        with self.assertRaises(LoopControllerError):
            controller.extend_budget(3)

    def test_extend_budget_within_default_still_recorded_but_not_flagged(self):
        # budget 은 항상 __init__ 시점의 default_budget 에서 시작하므로
        # 정상 연장은 반드시 default 를 넘는다 — exceeds_default=False 인
        # 경로가 실제로 존재하려면 연장 자체가 기본값 이하로는 불가능함을
        # 확인한다 (연장은 항상 현재 budget 보다 커야 하고, 현재 budget
        # 은 최소 default_budget 이므로).
        controller = LoopController(budget=5)
        entry = controller.extend_budget(6)
        self.assertTrue(entry["exceeds_default"])

    def test_no_silent_extension_without_explicit_call(self):
        # extend_budget 을 호출하지 않으면 budget 은 절대 바뀌지 않는다
        controller = LoopController(budget=3)
        for index in range(3):
            controller.record_attempt("d{}".format(index), (), {}, "1")
        self.assertEqual(controller.budget, 3)
        self.assertEqual(controller.extension_history, ())


class CounterSingularityTest(unittest.TestCase):
    """(d) controller 인스턴스가 유일한 계수 주체 — 스냅샷 왕복 후에도 계수 연속."""

    def test_independent_instances_do_not_share_state(self):
        first = LoopController()
        second = LoopController()
        first.record_attempt("d0", (), {}, "1")
        first.record_attempt("d1", (), {}, "1")
        first.record_attempt("d2", (), {}, "1")
        self.assertEqual(first.attempt_count, 3)
        self.assertEqual(second.attempt_count, 0)

    def test_snapshot_round_trip_preserves_attempt_count(self):
        controller = LoopController(budget=5)
        controller.record_attempt("d0", (), {}, "1")
        controller.record_attempt("d1", (), {}, "1")
        snapshot = controller.snapshot()

        restored = LoopController.from_snapshot(snapshot)
        self.assertEqual(restored.attempt_count, 2)
        self.assertEqual(restored.budget, 5)

        # 계수는 복원 이후에도 이어진다 — 새로 0부터 시작하지 않는다
        third = restored.record_attempt("d2", (), {}, "1")
        self.assertEqual(third.attempt, 3)

    def test_snapshot_round_trip_preserves_repeat_count_and_no_progress(self):
        controller = LoopController()
        controller.record_attempt("dup", (), {}, "1")
        snapshot = controller.snapshot()
        restored = LoopController.from_snapshot(snapshot)
        # 복원된 controller 에 같은 digest 를 한번 더 넣으면 원본에서
        # 이어 넣은 것과 동일하게 반복이 감지되어야 한다
        result = restored.record_attempt("dup", (), {}, "1")
        self.assertEqual(result.signal, SIGNAL_ASK_USER)
        self.assertEqual(result.repeat_count, 2)

    def test_snapshot_round_trip_preserves_extension_history(self):
        controller = LoopController(budget=5)
        controller.extend_budget(7, reason="continue")
        snapshot = controller.snapshot()
        # 연장 권위는 호출자 공급(approved_extensions) — 이 테스트에서는
        # 같은 controller 가 실제로 승인한 이력을 그대로 신뢰 근거로
        # 넘긴다 (코드리뷰 사이클 C 3차 High 수정 이후 계약).
        restored = LoopController.from_snapshot(
            snapshot, approved_extensions=controller.extension_history
        )
        self.assertEqual(restored.budget, 7)
        self.assertEqual(len(restored.extension_history), 1)
        self.assertEqual(restored.extension_history[0]["new_budget"], 7)

    def test_snapshot_is_plain_serializable_dict(self):
        import json

        controller = LoopController()
        controller.record_attempt("d0", (), {}, "1")
        snapshot = controller.snapshot()
        # 직렬화 가능해야 한다 (spec §3.8 storage 계층이 얹을 수 있게)
        json.dumps(snapshot)

    def test_from_snapshot_rejects_missing_keys(self):
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot({})

    def test_from_snapshot_rejects_non_dict_snapshot_none(self):
        # 코드리뷰 사이클 C 4차 Low — None 은 원시 TypeError 가 아니라
        # LoopControllerError 로 통일 거부돼야 한다
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(None)

    def test_from_snapshot_rejects_non_dict_snapshot_int(self):
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(42)

    def test_from_snapshot_rejects_non_dict_snapshot_str(self):
        # str 은 `in` 연산 자체는 TypeError 없이 통과하지만(부분 문자열
        # 검사) 이후 인덱싱에서 다른 형태의 원시 오류가 샐 수 있었다 —
        # dict 가 아니면 앞단에서 통일 거부한다
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot("not-a-snapshot")

    def test_from_snapshot_rejects_non_dict_snapshot_list(self):
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(["not", "a", "dict"])

    def test_module_does_not_reference_external_v1_counter_paths(self):
        # v1 카운터 경로(trail/dod/.review-rounds 류)를 참조하지 않는다는
        # 정적 검사 — 카운터 단일성 계약의 소스 레벨 고정
        import rein.engine.loop_controller as module

        source_path = module.__file__
        with open(source_path, "r", encoding="utf-8") as handle:
            source = handle.read()
        # 코드 blob 내 실제 경로 리터럴만 금지한다 — docstring 안의
        # "행위 참고" 산문 인용은 예외로 허용해야 하므로, 코드 라인
        # (docstring 밖)에 아래 리터럴이 등장하지 않는지 확인한다.
        code_lines = []
        in_docstring = False
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith('"""') or stripped.startswith("'''"):
                # 라인 자체에서 여는·닫는 따옴표가 짝수개면 한 줄 docstring
                quote_count = stripped.count('"""') + stripped.count("'''")
                if quote_count % 2 == 1:
                    in_docstring = not in_docstring
                continue
            if not in_docstring:
                code_lines.append(line)
        code_only = "\n".join(code_lines)
        self.assertNotIn("trail/dod/.review-rounds", code_only)
        self.assertNotIn("open(", code_only)
        self.assertNotIn("sqlite3", code_only)


class SnapshotBudgetIntegrityTest(unittest.TestCase):
    """코드리뷰 사이클 C High — 스냅샷 복원이 조용한 예산 연장을 허용하면 안 된다.

    리뷰어 실증: `budget=999` + `extension_history=[]` 스냅샷이 그대로
    복원되던 결함. `from_snapshot` 은 이제 `budget ==
    default_budget + Σ(extension_history 의 연장분)` 을 재검증하고,
    이력 항목 자체의 shape(양의 정수 등)도 검증한다 — 불일치는 명시
    예외로 거부한다(조용한 보정 금지).
    """

    def _valid_snapshot(self):
        controller = LoopController(budget=5)
        controller.record_attempt("d0", (), {}, "1")
        return controller.snapshot()

    def test_inflated_budget_with_empty_history_is_rejected(self):
        # 리뷰어가 실증한 정확한 공격 형태 — budget 만 부풀리고 이력은 비움
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 999
        snapshot["extension_history"] = []
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_budget_not_matching_history_sum_is_rejected(self):
        # 이력은 있지만 선언된 budget 이 이력 누적 결과와 다르다
        controller = LoopController(budget=5)
        controller.extend_budget(7, reason="legit extension")
        snapshot = controller.snapshot()
        snapshot["budget"] = 20  # 이력은 7까지만 정당화하는데 20으로 위조
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_valid_extension_history_snapshot_round_trips(self):
        # 정상 연장 이력은 그대로 왕복 성립해야 한다 (오탐 방지 대칭 축)
        controller = LoopController(budget=5)
        controller.extend_budget(7, reason="first extension")
        controller.record_attempt("d0", (), {}, "1")
        controller.extend_budget(9, reason="second extension")
        snapshot = controller.snapshot()
        restored = LoopController.from_snapshot(
            snapshot, approved_extensions=controller.extension_history
        )
        self.assertEqual(restored.budget, 9)
        self.assertEqual(len(restored.extension_history), 2)
        self.assertEqual(
            [entry["new_budget"] for entry in restored.extension_history],
            [7, 9],
        )

    def test_extension_entry_new_budget_not_greater_than_previous_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 5
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 5,  # 증가 없음 — extend_budget 규약 위반
                "exceeds_default": False,
                "reason": None,
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_entry_negative_new_budget_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = -1
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": -1,
                "exceeds_default": False,
                "reason": None,
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_entry_missing_key_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 7
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 7,
                "exceeds_default": True,
                # "reason" key 누락
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_entry_wrong_type_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 7
        snapshot["extension_history"] = [
            {
                "previous_budget": "5",  # str 이 아니라 int 여야 한다
                "new_budget": 7,
                "exceeds_default": True,
                "reason": None,
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_entry_exceeds_default_mismatch_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 7
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 7,
                "exceeds_default": False,  # 7 > default(5) 인데 False 로 위조
                "reason": None,
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_chain_broken_previous_budget_mismatch_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 12
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 7,
                "exceeds_default": True,
                "reason": "first",
                "at_attempt": 0,
            },
            {
                # 직전 항목의 new_budget(7) 이 아니라 임의의 값으로 이어짐
                "previous_budget": 10,
                "new_budget": 12,
                "exceeds_default": True,
                "reason": "second",
                "at_attempt": 0,
            },
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_at_attempt_exceeds_attempt_count_rejected(self):
        snapshot = self._valid_snapshot()  # attempt_count == 1
        snapshot["budget"] = 7
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 7,
                "exceeds_default": True,
                "reason": None,
                "at_attempt": 999,  # 아직 일어나지 않은 시도에서 연장됐다고 주장
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_history_not_a_list_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["extension_history"] = "not-a-list"
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_extension_entry_not_a_dict_rejected(self):
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 7
        snapshot["extension_history"] = ["not-a-dict"]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)


class SnapshotTrustAnchorTest(unittest.TestCase):
    """코드리뷰 사이클 C 2차 High — 신뢰 기준선(default_budget) 도 스냅샷이 아니라 호출자가 정본.

    리뷰어 실증: 1차 수정(SnapshotBudgetIntegrityTest)은 `budget` 이
    `extension_history` 와 정합하는지만 검증했는데, 그 정합성의 기준이
    되는 `default_budget` 자체도 스냅샷에서 읽고 있어서
    `default_budget=999` + `budget=999` + `extension_history=[]` 를
    함께 위조하면 검증을 통과했다. 또한 `extension_history` 의
    `at_attempt` 역행(`[1, 0]`)도 이전 검증을 통과했다. 이 클래스는
    두 잔존 결함을 각각 고정한다.
    """

    def _valid_snapshot(self, budget=5):
        controller = LoopController(budget=budget)
        controller.record_attempt("d0", (), {}, "1")
        controller.record_attempt("d1", (), {}, "1")
        return controller.snapshot()

    def test_reviewer_repro_forged_default_budget_and_budget_together_rejected(self):
        # 리뷰어 재현 그대로 — default_budget/budget 을 함께 999로,
        # extension_history 는 빈 채로 위조
        snapshot = self._valid_snapshot()
        snapshot["default_budget"] = 999
        snapshot["budget"] = 999
        snapshot["extension_history"] = []
        with self.assertRaises(LoopControllerError):
            # 호출자는 코드가 아는 진짜 기준선(5)을 그대로 넘긴다 —
            # 스냅샷 안의 위조된 999 는 무시되지 않고 불일치로 거부된다
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_forged_default_budget_alone_rejected_even_with_default_caller_arg(self):
        # from_snapshot() 인자를 아예 생략해도(모듈 DEFAULT_ATTEMPT_BUDGET=5
        # 가 caller 기준선) 스냅샷의 위조된 default_budget 은 거부된다
        snapshot = self._valid_snapshot()
        snapshot["default_budget"] = 999
        snapshot["budget"] = 999
        snapshot["extension_history"] = []
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot)

    def test_no_progress_threshold_trust_anchor_mismatch_rejected(self):
        controller = LoopController(budget=5, no_progress_threshold=2)
        controller.record_attempt("d0", (), {}, "1")
        snapshot = controller.snapshot()
        snapshot["no_progress_threshold"] = 999  # 위조 — 실질적으로 무력화 시도
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(
                snapshot, default_budget=5, no_progress_threshold=2
            )

    def test_caller_supplied_default_budget_mismatching_legit_snapshot_rejected(self):
        # 위조가 아니라 단순히 호출자가 다른 기준선을 넘긴 경우도 —
        # "같은 기준선을 유지한 채 이어간다"는 계약이므로 거부돼야 한다
        snapshot = self._valid_snapshot(budget=5)
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=10)

    def test_extension_history_at_attempt_regression_rejected(self):
        # 리뷰어가 지적한 정확한 역행 수열 — [1, 0]
        snapshot = self._valid_snapshot()
        snapshot["budget"] = 9
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 7,
                "exceeds_default": True,
                "reason": "first",
                "at_attempt": 1,
            },
            {
                "previous_budget": 7,
                "new_budget": 9,
                "exceeds_default": True,
                "reason": "second, but claims to precede the first",
                "at_attempt": 0,
            },
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_extension_history_equal_at_attempt_is_allowed(self):
        # 같은 attempt 에서 연속 extend_budget 을 호출하면(중간에
        # record_attempt 없이) at_attempt 값이 같을 수 있다 — 이건
        # 역행이 아니라 동시성이므로 허용돼야 한다(비감소, 감소 아님)
        controller = LoopController(budget=5)
        controller.extend_budget(7, reason="first")
        controller.extend_budget(9, reason="second, same attempt")
        snapshot = controller.snapshot()
        restored = LoopController.from_snapshot(
            snapshot,
            default_budget=5,
            approved_extensions=controller.extension_history,
        )
        self.assertEqual(restored.budget, 9)
        self.assertEqual(
            [entry["at_attempt"] for entry in restored.extension_history],
            [0, 0],
        )

    def test_legitimate_round_trip_with_explicit_trust_anchors_succeeds(self):
        controller = LoopController(budget=5, no_progress_threshold=2)
        controller.record_attempt("d0", (), {}, "1")
        controller.extend_budget(8, reason="user approved more rounds")
        controller.record_attempt("d1", (), {}, "1")
        snapshot = controller.snapshot()

        restored = LoopController.from_snapshot(
            snapshot,
            default_budget=5,
            no_progress_threshold=2,
            approved_extensions=controller.extension_history,
        )
        self.assertEqual(restored.budget, 8)
        self.assertEqual(restored.attempt_count, 2)
        self.assertEqual(len(restored.extension_history), 1)

        # 계수는 여전히 이어진다 (카운터 단일성 유지 확인)
        third = restored.record_attempt("d2", (), {}, "1")
        self.assertEqual(third.attempt, 3)

    def test_default_caller_args_match_module_defaults_for_plain_controller(self):
        # 인자를 생략했을 때의 기본값(DEFAULT_ATTEMPT_BUDGET/
        # DEFAULT_NO_PROGRESS_THRESHOLD)이 LoopController() 기본 생성과
        # 정확히 맞물려야 인자 생략이 실무적으로 쓸모 있다
        controller = LoopController()
        controller.record_attempt("d0", (), {}, "1")
        snapshot = controller.snapshot()
        restored = LoopController.from_snapshot(snapshot)  # 인자 생략
        self.assertEqual(restored.budget, DEFAULT_ATTEMPT_BUDGET)
        self.assertEqual(
            restored.no_progress_threshold, DEFAULT_NO_PROGRESS_THRESHOLD
        )


class SnapshotExtensionAuthorityTest(unittest.TestCase):
    """코드리뷰 사이클 C 3차 High — 자기 일관 이력만으로는 연장을 승인할 수 없다.

    리뷰어 실증: `default_budget=5`(신뢰 기준과 일치) + 자기 일관된
    `extension_history={5→999}` + `budget=999` 를 함께 구성하면 1·2차
    수정을 모두 통과했다 — 내부 일관성 검사는 "말이 되는 이야기"인지만
    보고 "실제로 있었던 일"인지는 보지 않기 때문이다.
    `from_snapshot(..., approved_extensions=...)` 가 스냅샷 밖의 근거를
    요구하도록 고쳤다. 이 클래스는 그 수정 + 카운터 구조적 하한 검증을
    고정한다.
    """

    def _valid_snapshot(self, budget=5):
        controller = LoopController(budget=budget)
        controller.record_attempt("d0", (), {}, "1")
        return controller.snapshot()

    def test_reviewer_repro_self_consistent_forged_history_without_approval_rejected(
        self,
    ):
        # 리뷰어 재현 그대로 — default_budget=5(진짜 기준선과 일치),
        # extension_history={5→999}(내부적으로는 말이 되는 체인),
        # budget=999. approved_extensions 를 넘기지 않으면(기본값 빈
        # 목록) 이 이력을 뒷받침할 스냅샷 밖 근거가 없으므로 거부돼야
        # 한다.
        snapshot = self._valid_snapshot(budget=5)
        snapshot["budget"] = 999
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 999,
                "exceeds_default": True,
                "reason": "self-consistent but nobody actually approved this",
                "at_attempt": 0,
            }
        ]
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_same_forged_history_rejected_even_with_unrelated_approved_extensions(
        self,
    ):
        # approved_extensions 를 아예 안 넘긴 게 아니라, 다른(진짜)
        # 연장 목록을 넘겨도 스냅샷의 위조 이력과 일치하지 않으면 거부
        snapshot = self._valid_snapshot(budget=5)
        snapshot["budget"] = 999
        snapshot["extension_history"] = [
            {
                "previous_budget": 5,
                "new_budget": 999,
                "exceeds_default": True,
                "reason": "forged",
                "at_attempt": 0,
            }
        ]
        legit_extension = {
            "previous_budget": 5,
            "new_budget": 7,
            "exceeds_default": True,
            "reason": "actually approved",
            "at_attempt": 0,
        }
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(
                snapshot,
                default_budget=5,
                approved_extensions=(legit_extension,),
            )

    def test_extension_matching_caller_approved_list_restores_successfully(self):
        # 스냅샷의 연장 이력이 호출자가 공급한 승인 목록과 정확히
        # 일치하면 복원이 성립해야 한다 (오탐 방지 대칭 축) — 리뷰어가
        # 지적한 정확한 공격 형태와 같은 숫자({5→999})라도, 그 연장이
        # 진짜 호출자의 신뢰 기록에 있다면 허용된다.
        snapshot = self._valid_snapshot(budget=5)
        snapshot["budget"] = 999
        approved_entry = {
            "previous_budget": 5,
            "new_budget": 999,
            "exceeds_default": True,
            "reason": "genuinely approved by the caller's own audit trail",
            "at_attempt": 0,
        }
        snapshot["extension_history"] = [dict(approved_entry)]
        restored = LoopController.from_snapshot(
            snapshot, default_budget=5, approved_extensions=(approved_entry,)
        )
        self.assertEqual(restored.budget, 999)
        self.assertEqual(len(restored.extension_history), 1)

    def test_attempt_count_zero_with_nonzero_repeat_count_rejected(self):
        snapshot = self._valid_snapshot(budget=5)
        snapshot["attempt_count"] = 0
        snapshot["repeat_count"] = 1  # attempt 가 하나도 없는데 반복이 있다고 주장
        snapshot["last_digest"] = None
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_attempt_count_zero_with_nonnull_last_digest_rejected(self):
        snapshot = self._valid_snapshot(budget=5)
        snapshot["attempt_count"] = 0
        snapshot["repeat_count"] = 0
        # attempt 가 없는데 last_digest 가 남아있다고 주장 — 모순
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_repeat_count_exceeding_attempt_count_rejected(self):
        snapshot = self._valid_snapshot(budget=5)  # attempt_count == 1
        snapshot["repeat_count"] = 5  # 시도는 1번인데 반복은 5번이라고 주장
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_repeat_count_zero_with_positive_attempt_count_rejected(self):
        snapshot = self._valid_snapshot(budget=5)  # attempt_count == 1
        snapshot["repeat_count"] = 0  # 시도가 있었는데 반복 계수가 0 — 모순
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_positive_attempt_count_with_null_last_digest_rejected(self):
        snapshot = self._valid_snapshot(budget=5)  # attempt_count == 1
        snapshot["last_digest"] = None  # 시도가 있었는데 마지막 digest 가 없다고 주장
        with self.assertRaises(LoopControllerError):
            LoopController.from_snapshot(snapshot, default_budget=5)

    def test_structurally_consistent_snapshot_round_trips_normally(self):
        # 구조적 하한 검증이 정상 스냅샷까지 거부하면 안 된다 (오탐
        # 방지 대칭 축)
        controller = LoopController(budget=5)
        controller.record_attempt("d0", (), {}, "1")
        controller.record_attempt("d0", (), {}, "1")  # 반복 — repeat_count=2
        snapshot = controller.snapshot()
        restored = LoopController.from_snapshot(snapshot, default_budget=5)
        self.assertEqual(restored.attempt_count, 2)


class ProgressDigestElementsTest(unittest.TestCase):
    """(e) 4요소 각각이 결과에 기여 — 프레이밍 마커로 연접 충돌 없음."""

    def _base_kwargs(self):
        return dict(
            change_digest="sha256:aaa",
            missing_requirements=("code_review", "tests_passed"),
            evidence_state={"code_review": "issued", "tests_passed": None},
            policy_version="1",
        )

    def test_same_inputs_produce_same_digest(self):
        kwargs = self._base_kwargs()
        self.assertEqual(progress_digest(**kwargs), progress_digest(**kwargs))

    def test_change_digest_difference_changes_result(self):
        base = self._base_kwargs()
        other = dict(base, change_digest="sha256:bbb")
        self.assertNotEqual(progress_digest(**base), progress_digest(**other))

    def test_missing_requirements_difference_changes_result(self):
        base = self._base_kwargs()
        other = dict(base, missing_requirements=("code_review",))
        self.assertNotEqual(progress_digest(**base), progress_digest(**other))

    def test_evidence_state_difference_changes_result(self):
        base = self._base_kwargs()
        other = dict(
            base,
            evidence_state={"code_review": "issued", "tests_passed": "issued"},
        )
        self.assertNotEqual(progress_digest(**base), progress_digest(**other))

    def test_policy_version_difference_changes_result(self):
        base = self._base_kwargs()
        other = dict(base, policy_version="2")
        self.assertNotEqual(progress_digest(**base), progress_digest(**other))

    def test_missing_requirements_order_independent(self):
        base = self._base_kwargs()
        reordered = dict(
            base, missing_requirements=("tests_passed", "code_review")
        )
        self.assertEqual(progress_digest(**base), progress_digest(**reordered))

    def test_evidence_state_order_independent_dict_vs_pairs(self):
        base = self._base_kwargs()
        as_pairs = dict(
            base,
            evidence_state=(
                ("tests_passed", None),
                ("code_review", "issued"),
            ),
        )
        self.assertEqual(progress_digest(**base), progress_digest(**as_pairs))

    def test_missing_requirements_concatenation_collision_is_avoided(self):
        # 프레이밍 마커 부재 시 흔한 함정: ["ab","c"] vs ["a","bc"]
        digest_ab_c = progress_digest(
            "d", ("ab", "c"), {}, "1"
        )
        digest_a_bc = progress_digest(
            "d", ("a", "bc"), {}, "1"
        )
        self.assertNotEqual(digest_ab_c, digest_a_bc)

    def test_evidence_state_absent_key_differs_from_none_value(self):
        digest_absent = progress_digest("d", (), {}, "1")
        digest_none_value = progress_digest(
            "d", (), {"code_review": None}, "1"
        )
        self.assertNotEqual(digest_absent, digest_none_value)

    def test_cross_field_boundary_collision_is_avoided(self):
        # change_digest="AB" + missing=("C",) 대 change_digest="A" +
        # missing=("BC",) 가 같은 바이트열로 우연히 합쳐지지 않는지
        first = progress_digest("AB", ("C",), {}, "1")
        second = progress_digest("A", ("BC",), {}, "1")
        self.assertNotEqual(first, second)

    def test_change_digest_must_be_nonempty_str(self):
        with self.assertRaises(LoopControllerError):
            progress_digest("", (), {}, "1")
        with self.assertRaises(LoopControllerError):
            progress_digest(None, (), {}, "1")

    def test_policy_version_must_be_nonempty_str(self):
        with self.assertRaises(LoopControllerError):
            progress_digest("d", (), {}, "")

    def test_missing_requirements_rejects_bare_string(self):
        with self.assertRaises(LoopControllerError):
            progress_digest("d", "code_review", {}, "1")

    def test_evidence_state_rejects_none(self):
        with self.assertRaises(LoopControllerError):
            progress_digest("d", (), None, "1")

    def test_evidence_state_rejects_duplicate_names(self):
        with self.assertRaises(LoopControllerError):
            progress_digest(
                "d",
                (),
                (("code_review", "issued"), ("code_review", None)),
                "1",
            )

    def test_evidence_state_rejects_bare_string(self):
        with self.assertRaises(LoopControllerError):
            progress_digest("d", (), "code_review", "1")


class LoopSignalTest(unittest.TestCase):
    """LoopSignal 자체의 계약 — 폐쇄 어휘 + 직렬화."""

    def test_rejects_unknown_signal(self):
        with self.assertRaises(LoopControllerError):
            LoopSignal(
                signal="UNKNOWN",
                attempt=1,
                reason="x",
                progress_digest="d",
                repeat_count=1,
                budget=5,
                extended=False,
            )

    def test_to_dict_contains_all_fields(self):
        controller = LoopController()
        result = controller.record_attempt("d0", (), {}, "1")
        payload = result.to_dict()
        self.assertEqual(
            set(payload),
            {
                "signal",
                "attempt",
                "reason",
                "progress_digest",
                "repeat_count",
                "budget",
                "extended",
            },
        )


class EndToEndLoopTest(unittest.TestCase):
    """v1 이중 운영 금지 — 단일 컨트롤러가 no-progress/budget 을 함께 담당."""

    def test_realistic_review_loop_hits_budget_then_extends(self):
        controller = LoopController(budget=3)
        # 세 번의 서로 다른(진행이 있는) 시도 — review 가 매번 다른 지점
        # 에서 걸려 missing_requirements 조합이 바뀌는 상황을 흉내낸다.
        r1 = controller.record_attempt(
            "sha256:v1", ("code_review",), {"code_review": None}, "1"
        )
        r2 = controller.record_attempt(
            "sha256:v2", ("code_review",), {"code_review": "NEEDS_FIX"}, "1"
        )
        r3 = controller.record_attempt(
            "sha256:v3", ("code_review",), {"code_review": "NEEDS_FIX_AGAIN"}, "1"
        )
        self.assertEqual(r1.signal, SIGNAL_CONTINUE)
        self.assertEqual(r2.signal, SIGNAL_CONTINUE)
        self.assertEqual(r3.signal, SIGNAL_BUDGET_EXHAUSTED)

        # +1 로 연장하면 그 다음 시도(4번째) 자체가 새 budget(4) 에 다시
        # 도달해 즉시 BUDGET_EXHAUSTED 를 반환한다 — "budget 도달 시점의
        # 그 호출 자체가 신호를 낸다" 설계이므로 여유 1회를 더 얻으려면
        # 최소 +2 가 필요하다.
        controller.extend_budget(5, reason="user approved more rounds")
        r4 = controller.record_attempt(
            "sha256:v4", (), {"code_review": "PASS"}, "1"
        )
        self.assertEqual(r4.signal, SIGNAL_CONTINUE)


if __name__ == "__main__":
    unittest.main()
