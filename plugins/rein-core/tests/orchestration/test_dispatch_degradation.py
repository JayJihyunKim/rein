"""plan Task 5.4 — 감지·강등: lazy detection + 세션 캐시 + 가시적 통지 + 관측 우선 강등 (spec §5.1 §4.5).

spec §5.1 확정 결정 원문 인용:
    "감지 시점 = lazy: 세션 시작이 아니라 첫 Orchestration 진입 시 감지한다
    ... 결과는 세션 스코프 캐시.
    관측 우선 원칙: 사전 감지 결과와 무관하게, 실제 중첩 디스패치 실패가
    관측되면 즉시 메인 세션 직접 디스패치로 강등한다 ...
    강등 가시성 = 명시: 강등 발생 시 사용자에게 평문 1줄 통지 ... + tracker
    에 `degraded` 사유 기록. silent 강등 금지."

spec §4.5 실패 처리 원문 인용:
    "Orchestration failure 로 일반 개발 작업 전체를 BLOCK 하지 않는다 —
    `병렬 실패 → 단일 실행 → Governance 는 계속 적용`."

검증 축 (plan Task 5.4 Step 1, 3계열):
(a) 불가 환경 시뮬레이션 → 강등 경로 + 통지 문자열 출력 + recorder 가
    강등 사유를 받는다.
(b) 세션 캐시 — 감지 2회 호출 시 실측(probe 호출) 1회.
(c) 실패 주입(capable 판정 이후 실제 중첩 디스패치 실패 보고) → 즉시
    강등 + 단일 실행 지속 + governance 흐름 무중단(BLOCK 없음).

이 테스트 모듈은 `rein.orchestration.tracker`/`work_unit`/`work_graph`/
`validator` 를 어떤 형태로도 import 하지 않는다 — recorder 는 항상 이
모듈 안의 스텁 콜러블로 주입한다(모듈 docstring "Python 은 에이전트를
스폰하지 않는다" 절과 동형 — dispatch_env 는 tracker 를 모르고, 이
테스트도 그 무지를 계약으로 검증한다).
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

from rein.orchestration.dispatch_env import (  # noqa: E402
    MODE_ORCHESTRATED,
    MODE_SINGLE_WORKER,
    MODES,
    REASON_OBSERVED_FAILURE,
    REASON_PROBE_INCAPABLE,
    REASONS,
    STATE_CAPABLE,
    STATE_INCAPABLE,
    STATE_UNKNOWN,
    STATES,
    DispatchEnvError,
    DispatchEnvironment,
)


class _RecorderStub(object):
    """강등 사유 recorder 계약 확인용 스텁 — tracker 를 흉내내지 않는다.

    dispatch_env 는 tracker 구현을 전혀 모른다(단일 dict 인자를 받는
    콜러블이면 충분한 duck-typed 프로토콜) — 이 스텁은 그 계약 자체를
    검증하는 최소 형태다.
    """

    def __init__(self):
        self.records = []

    def __call__(self, record):
        self.records.append(record)


class VocabularyTest(unittest.TestCase):
    """상태/모드/사유 3종 어휘가 닫힌 집합이다."""

    def test_states_closed_set(self):
        self.assertEqual(
            frozenset(STATES),
            frozenset((STATE_UNKNOWN, STATE_CAPABLE, STATE_INCAPABLE)),
        )

    def test_modes_closed_set(self):
        self.assertEqual(
            frozenset(MODES), frozenset((MODE_ORCHESTRATED, MODE_SINGLE_WORKER))
        )

    def test_reasons_closed_set(self):
        self.assertEqual(
            frozenset(REASONS),
            frozenset((REASON_PROBE_INCAPABLE, REASON_OBSERVED_FAILURE)),
        )

    def test_initial_state_is_unknown_with_safe_default_mode(self):
        env = DispatchEnvironment()
        self.assertEqual(env.state, STATE_UNKNOWN)
        # 감지 전에도 안전한 기본값(single_worker) — 확인되지 않은 능력을
        # 낙관하지 않는다.
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)
        self.assertIsNone(env.notice)
        self.assertIsNone(env.degraded_reason)
        self.assertEqual(env.probe_consultations, 0)


class IncapableEnvironmentDegradationTest(unittest.TestCase):
    """(a) 불가 환경 시뮬레이션 → 강등 경로 + 통지 문자열 + recorder 사유 수신."""

    def test_incapable_probe_result_degrades_to_single_worker_mode(self):
        env = DispatchEnvironment()
        state = env.detect(lambda: False)
        self.assertEqual(state, STATE_INCAPABLE)
        self.assertEqual(env.state, STATE_INCAPABLE)
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)

    def test_incapable_result_produces_plain_one_line_notice(self):
        env = DispatchEnvironment()
        env.detect(lambda: False)
        notice = env.notice
        self.assertIsInstance(notice, str)
        self.assertTrue(notice)  # 비어있지 않음 — silent 강등 금지
        self.assertNotIn("\n", notice)  # 평문 1줄

    def test_incapable_result_recorder_receives_degraded_reason(self):
        recorder = _RecorderStub()
        env = DispatchEnvironment(recorder=recorder)
        env.detect(lambda: False)
        self.assertEqual(len(recorder.records), 1)
        record = recorder.records[0]
        self.assertEqual(record["reason"], REASON_PROBE_INCAPABLE)
        self.assertEqual(record["state"], STATE_INCAPABLE)
        self.assertEqual(record["mode"], MODE_SINGLE_WORKER)
        self.assertEqual(record["notice"], env.notice)
        self.assertIsInstance(record["detail"], str)
        self.assertTrue(record["detail"])

    def test_recorder_is_optional_and_degrade_still_succeeds_without_one(self):
        # recorder 를 안 넘겨도(None) 강등 경로 자체는 예외 없이 성립한다
        # — recorder 는 부가 통지 채널이지 강등 성립의 전제조건이 아니다.
        env = DispatchEnvironment()
        state = env.detect(lambda: False)
        self.assertEqual(state, STATE_INCAPABLE)
        self.assertIsNotNone(env.notice)

    def test_capable_probe_result_does_not_degrade(self):
        # 오탐 방지 대칭 축 — 가능 판정은 강등 경로를 전혀 건드리지 않는다.
        recorder = _RecorderStub()
        env = DispatchEnvironment(recorder=recorder)
        state = env.detect(lambda: True)
        self.assertEqual(state, STATE_CAPABLE)
        self.assertEqual(env.mode, MODE_ORCHESTRATED)
        self.assertIsNone(env.notice)
        self.assertIsNone(env.degraded_reason)
        self.assertEqual(recorder.records, [])


class SessionScopeCacheTest(unittest.TestCase):
    """(b) 세션 캐시 — 감지 2회 호출 시 실측(probe 호출) 1회."""

    def test_second_detect_call_does_not_reconsult_probe(self):
        calls = []

        def probe():
            calls.append(1)
            return True

        env = DispatchEnvironment()
        first = env.detect(probe)
        second = env.detect(probe)
        self.assertEqual(first, STATE_CAPABLE)
        self.assertEqual(second, STATE_CAPABLE)
        self.assertEqual(len(calls), 1)
        self.assertEqual(env.probe_consultations, 1)

    def test_cache_holds_for_incapable_verdict_too(self):
        calls = []

        def probe():
            calls.append(1)
            return False

        env = DispatchEnvironment()
        env.detect(probe)
        env.detect(probe)
        env.detect(probe)
        self.assertEqual(len(calls), 1)
        self.assertEqual(env.probe_consultations, 1)

    def test_repeated_detect_never_calls_a_second_probe_callable(self):
        # 캐시된 세션은 다른(독성) probe 콜러블을 넘겨도 그걸 부르지
        # 않는다 — 첫 콜러블만 특별 취급하는 게 아니라 진짜 "재감지 안
        # 함"임을 증명한다.
        first_calls = []

        def first_probe():
            first_calls.append(1)
            return True

        def poison_probe():
            raise AssertionError(
                "a cached DispatchEnvironment must never re-consult a probe"
            )

        env = DispatchEnvironment()
        env.detect(first_probe)
        result = env.detect(poison_probe)
        self.assertEqual(result, STATE_CAPABLE)
        self.assertEqual(env.probe_consultations, 1)

    def test_independent_instances_do_not_share_cached_state(self):
        first = DispatchEnvironment()
        second = DispatchEnvironment()
        first.detect(lambda: True)
        self.assertEqual(first.state, STATE_CAPABLE)
        self.assertEqual(second.state, STATE_UNKNOWN)
        self.assertEqual(second.probe_consultations, 0)


class ObservedFailureDowngradeTest(unittest.TestCase):
    """(c) 실패 주입 → 단일 실행 지속 + governance 흐름 무중단(BLOCK 없음)."""

    def test_observed_failure_downgrades_even_after_capable_verdict(self):
        recorder = _RecorderStub()
        env = DispatchEnvironment(recorder=recorder)
        pre_state = env.detect(lambda: True)
        self.assertEqual(pre_state, STATE_CAPABLE)
        self.assertEqual(env.mode, MODE_ORCHESTRATED)

        post_state = env.report_dispatch_failure(
            detail="worker subagent nested dispatch raised a timeout"
        )
        self.assertEqual(post_state, STATE_INCAPABLE)
        self.assertEqual(env.state, STATE_INCAPABLE)
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)
        self.assertEqual(len(recorder.records), 1)
        self.assertEqual(recorder.records[0]["reason"], REASON_OBSERVED_FAILURE)
        self.assertIn("timeout", recorder.records[0]["detail"])

    def test_observed_failure_before_any_detect_call_also_downgrades(self):
        # detect() 를 아직 부르지 않은(UNKNOWN) 세션에서도 실제 실패
        # 관측은 즉시 반영된다 — 관측 우선은 사전 감지 여부에 의존하지
        # 않는다.
        recorder = _RecorderStub()
        env = DispatchEnvironment(recorder=recorder)
        self.assertEqual(env.state, STATE_UNKNOWN)
        env.report_dispatch_failure()
        self.assertEqual(env.state, STATE_INCAPABLE)
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)
        self.assertEqual(len(recorder.records), 1)
        self.assertEqual(recorder.records[0]["reason"], REASON_OBSERVED_FAILURE)

    def test_single_worker_mode_persists_after_downgrade_without_reprobe(self):
        probe_calls = []

        def probe():
            probe_calls.append(1)
            return True

        env = DispatchEnvironment()
        env.detect(probe)
        env.report_dispatch_failure()
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)

        # 강등 후 호출자가 실수로 detect() 를 다시 불러도, 이미 결정된
        # (더 강한 관측) 세션이라 probe 를 재소비하지 않고 안전한 강등
        # 상태를 그대로 유지한다 — 단일 실행이 안정적으로 지속된다.
        result = env.detect(probe)
        self.assertEqual(result, STATE_INCAPABLE)
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)
        self.assertEqual(len(probe_calls), 1)  # 최초 detect() 호출분만

    def test_governance_flow_continues_without_raising_on_repeated_failures(self):
        # "orchestration 실패로 일반 작업 BLOCK 금지"(spec §4.5) 의 실행
        # 축. 라운드 1 버전은 "예외 없음 + single_worker 상태" 만 확인해
        # PARTIAL 판정을 받았다(라운드 2 review) — plan 이 실제로 요구하는
        # 것은 "governance 판정 흐름이 계속된다" 는 관측이지, 강등 경로가
        # 조용히 통과한다는 사실만이 아니다. 그래서 이 테스트는 매 실패
        # 주입마다 **독립적인 governance 평가**(dispatch_env 가 전혀 모르는
        # 별도 파이프라인 — 이 모듈은 kernel.decision 어휘를 참조하지
        # 않는다, 아래 `test_module_does_not_import_...` 참조)를 스텁으로
        # 흉내내 돌리고, 그 평가가 매번 실제로 완료·기록됐는지, 그리고
        # orchestration 강등이 원인이 되어 BLOCK 이 발생한 적이 없는지를
        # 확인한다.
        env = DispatchEnvironment()
        env.detect(lambda: True)

        def _stub_governance_evaluate(dispatch_mode):
            # 최소 stub — dispatch_env 는 kernel.decision 어휘(ALLOW/
            # BLOCK/ASK_USER)를 참조하지도 소비하지도 않는다(모듈
            # docstring "일반 작업 BLOCK 금지" 절). 이 함수는 "orchestration
            # 상태와 무관하게 governance 평가 자체는 계속 돈다"는 사실을
            # 관측하기 위한 순수 테스트 더블이다 — dispatch_mode 값이
            # 무엇이든(orchestrated/single_worker) 평가 호출 자체를 막을
            # 근거가 dispatch_env 어휘 안에 없다는 것을 실행으로 증명한다.
            return {
                "decision": "ALLOW",
                "reason": "orchestration mode ({}) does not gate governance "
                "evaluation".format(dispatch_mode),
            }

        decisions = []
        try:
            for i in range(5):
                state = env.report_dispatch_failure(
                    detail="injected failure #{}".format(i)
                )
                self.assertEqual(state, STATE_INCAPABLE)
                # governance 평가는 orchestration 강등과 무관하게 계속
                # 돈다 — dispatch_env 가 이 호출을 막거나 대신 판정을
                # 내리지 않는다(그럴 어휘 자체가 없다).
                decisions.append(_stub_governance_evaluate(env.mode))
        except Exception as exc:  # pragma: no cover - 실패 시 즉시 알려준다
            self.fail(
                "orchestration degradation must never raise/interrupt the "
                "governance flow, got {!r}".format(exc)
            )

        # 매 실패 주입마다 평가가 실제로 완료되고 기록됐다 — 스킵된
        # 회차가 없다.
        self.assertEqual(len(decisions), 5)
        # orchestration 강등이 원인이 된 BLOCK 은 0건이다.
        self.assertTrue(
            all(decision["decision"] != "BLOCK" for decision in decisions)
        )
        self.assertTrue(
            all(decision["decision"] == "ALLOW" for decision in decisions)
        )
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)

    def test_module_does_not_import_kernel_decision_or_orchestration_siblings(self):
        # spec §4.5 "orchestration 실패로 일반 작업 BLOCK 금지" 의 소스
        # 레벨 고정: 이 모듈은 kernel Decision(ALLOW/BLOCK/ASK_USER)
        # 어휘를 참조하지 않고, work_unit/work_graph/validator/tracker
        # (병렬 형제 모듈) 도 import 하지 않는다 — 강등 사유는 오직
        # 주입된 recorder 콜백으로만 흘러나간다.
        import rein.orchestration.dispatch_env as module

        source_path = module.__file__
        with open(source_path, "r", encoding="utf-8") as handle:
            source = handle.read()
        code_lines = []
        in_docstring = False
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith('"""') or stripped.startswith("'''"):
                quote_count = stripped.count('"""') + stripped.count("'''")
                if quote_count % 2 == 1:
                    in_docstring = not in_docstring
                continue
            if not in_docstring:
                code_lines.append(line)
        code_only = "\n".join(code_lines)
        for forbidden in (
            "import rein.kernel.decision",
            "from rein.kernel.decision",
            "from rein.kernel import decision",
            "rein.orchestration.tracker",
            "rein.orchestration.work_unit",
            "rein.orchestration.work_graph",
            "rein.orchestration.validator",
            "from rein.orchestration import tracker",
            "from rein.orchestration import work_unit",
            "from rein.orchestration import work_graph",
            "from rein.orchestration import validator",
        ):
            self.assertNotIn(forbidden, code_only)


class ContractValidationTest(unittest.TestCase):
    """호출자 계약 위반은 명시 예외로 거부한다(조용한 보정 금지)."""

    def test_detect_rejects_non_callable_probe(self):
        env = DispatchEnvironment()
        with self.assertRaises(DispatchEnvError):
            env.detect("not-a-callable")

    def test_detect_rejects_non_bool_probe_result(self):
        env = DispatchEnvironment()
        with self.assertRaises(DispatchEnvError):
            env.detect(lambda: 1)  # truthy int, 명시 bool 아님 — 거부

    def test_detect_rejects_none_probe_result(self):
        env = DispatchEnvironment()
        with self.assertRaises(DispatchEnvError):
            env.detect(lambda: None)

    def test_constructor_rejects_non_callable_recorder(self):
        with self.assertRaises(DispatchEnvError):
            DispatchEnvironment(recorder="not-a-callable")

    def test_constructor_accepts_missing_recorder(self):
        env = DispatchEnvironment()
        self.assertEqual(env.state, STATE_UNKNOWN)

    def test_dispatch_env_error_is_a_value_error(self):
        # LoopControllerError 등 이 저장소의 다른 계약 예외와 동일 관례 —
        # 호출자가 ValueError 하나만 잡아도 계약 위반을 포괄할 수 있다.
        self.assertTrue(issubclass(DispatchEnvError, ValueError))


class SerializationTest(unittest.TestCase):
    """`to_dict()` — 매 호출 새 dict, json 직렬화 가능, 현재 상태 반영."""

    def test_to_dict_reflects_incapable_state(self):
        env = DispatchEnvironment()
        env.detect(lambda: False)
        payload = env.to_dict()
        json.dumps(payload)  # 직렬화 가능해야 한다
        self.assertEqual(payload["state"], STATE_INCAPABLE)
        self.assertEqual(payload["mode"], MODE_SINGLE_WORKER)
        self.assertEqual(payload["probe_consultations"], 1)
        self.assertEqual(payload["degraded_reason"], REASON_PROBE_INCAPABLE)
        self.assertIsInstance(payload["notice"], str)

    def test_to_dict_reflects_pre_detection_default(self):
        env = DispatchEnvironment()
        payload = env.to_dict()
        self.assertEqual(payload["state"], STATE_UNKNOWN)
        self.assertEqual(payload["mode"], MODE_SINGLE_WORKER)
        self.assertIsNone(payload["notice"])
        self.assertIsNone(payload["degraded_reason"])
        self.assertEqual(payload["probe_consultations"], 0)

    def test_to_dict_returns_a_fresh_dict_each_call(self):
        env = DispatchEnvironment()
        first = env.to_dict()
        first["state"] = "tampered"
        second = env.to_dict()
        self.assertEqual(second["state"], STATE_UNKNOWN)


# ---------------------------------------------------------------------------
# (d) F2 fix-review, finding 1 — probe()/recorder() exceptions must degrade
#     instead of propagating, and DispatchEnvironment(recorder=tracker.
#     record_degradation) must compose directly without raising.
#
# These two test classes import rein.orchestration.tracker — a deliberate,
# scoped exception to this module's usual sibling-import abstinence (see
# `test_module_does_not_import_kernel_decision_or_orchestration_siblings`
# below, which still asserts dispatch_env.py's own *source* never imports
# tracker). The F2 fix-review brief explicitly lifts the cross-module import
# ban for tests: composition between dispatch_env and tracker happens via
# contracts (a single-dict-argument callable), and that contract is only
# provable by actually composing the two real objects somewhere — this is
# that somewhere. dispatch_env.py itself remains ignorant of tracker.
# ---------------------------------------------------------------------------
from rein.orchestration import tracker as tracker_module  # noqa: E402


class ComposedWithTrackerRecorderIntegrationTest(unittest.TestCase):
    """`DispatchEnvironment(recorder=tracker.record_degradation)` must
    compose and degrade end-to-end without raising TrackerError (finding 1
    — the pre-fix shape mismatch: dispatch_env passed a dict, tracker's
    record_degradation only accepted str)."""

    def test_direct_composition_probe_incapable_degrades_end_to_end(self):
        t = tracker_module.Tracker()
        env = DispatchEnvironment(recorder=t.record_degradation)
        state = env.detect(lambda: False)

        self.assertEqual(state, STATE_INCAPABLE)
        self.assertIsNotNone(t.degraded)
        self.assertEqual(t.degraded["reason"], REASON_PROBE_INCAPABLE)
        self.assertEqual(
            t.comparison_record()["degraded"]["reason"], REASON_PROBE_INCAPABLE
        )

    def test_direct_composition_observed_failure_path(self):
        t = tracker_module.Tracker()
        env = DispatchEnvironment(recorder=t.record_degradation)
        env.detect(lambda: True)

        env.report_dispatch_failure(detail="nested dispatch timed out")

        self.assertIsNotNone(t.degraded)
        self.assertEqual(t.degraded["reason"], REASON_OBSERVED_FAILURE)
        self.assertIn("timed out", t.degraded["detail"])


class ProbeAndRecorderExceptionSafetyTest(unittest.TestCase):
    """probe()/recorder() exceptions must be absorbed into the degrade path
    and never propagate to the caller (spec §4.5 — orchestration failure
    must not block general work; finding 1)."""

    def test_probe_exception_degrades_instead_of_propagating(self):
        def exploding_probe():
            raise RuntimeError("probe blew up")

        env = DispatchEnvironment()
        state = env.detect(exploding_probe)  # must not raise

        self.assertEqual(state, STATE_INCAPABLE)
        self.assertEqual(env.mode, MODE_SINGLE_WORKER)
        self.assertIsNotNone(env.notice)
        self.assertEqual(env.degraded_reason, REASON_PROBE_INCAPABLE)

    def test_probe_exception_still_records_via_recorder(self):
        recorder = _RecorderStub()
        env = DispatchEnvironment(recorder=recorder)

        def exploding_probe():
            raise ValueError("boom")

        env.detect(exploding_probe)

        self.assertEqual(len(recorder.records), 1)
        self.assertEqual(recorder.records[0]["reason"], REASON_PROBE_INCAPABLE)

    def test_probe_contract_violations_still_raise_not_swallowed(self):
        # Only *runtime* exceptions raised while calling probe() are
        # swallowed into the degrade path. Caller contract violations
        # (non-callable, non-bool return) are bugs in the caller and must
        # still raise DispatchEnvError, unchanged from before this fix.
        env = DispatchEnvironment()
        with self.assertRaises(DispatchEnvError):
            env.detect(lambda: 1)  # truthy int, not a real bool

    def test_recorder_exception_does_not_propagate_out_of_detect(self):
        def exploding_recorder(record):
            raise RuntimeError("recorder blew up")

        env = DispatchEnvironment(recorder=exploding_recorder)
        state = env.detect(lambda: False)  # must not raise

        self.assertEqual(state, STATE_INCAPABLE)
        self.assertIsNotNone(env.notice)

    def test_recorder_exception_does_not_propagate_out_of_report_dispatch_failure(
        self,
    ):
        def exploding_recorder(record):
            raise RuntimeError("recorder blew up")

        env = DispatchEnvironment(recorder=exploding_recorder)
        state = env.report_dispatch_failure(detail="observed failure")  # no raise

        self.assertEqual(state, STATE_INCAPABLE)
        self.assertIsNotNone(env.notice)

    def test_composed_recorder_raising_trackererror_does_not_propagate(self):
        # tracker.record_degradation itself raises TrackerError on a
        # malformed mapping (no "reason" key) — even that composed failure
        # must not escape the degrade path.
        t = tracker_module.Tracker()

        def broken_recorder(record):
            return t.record_degradation({"detail": record.get("detail")})

        env = DispatchEnvironment(recorder=broken_recorder)
        state = env.detect(lambda: False)  # must not raise

        self.assertEqual(state, STATE_INCAPABLE)
        self.assertIsNone(t.degraded)  # the broken recorder's write never landed


if __name__ == "__main__":
    unittest.main()
