"""plan Task 4.2 — active_task 관련성 판정 (spec §3.6 §10, §6.3 표 1행).

spec §3.6 (원문 인용):
    "현재 변경이 정의된 Task/DoD 에 속하는지 검증. DoD 전체 생성
    시스템과는 분리 — v2.0 Core 에는 검증만 포함. '무관 파일 편집은
    막히지 않는다' 는 v1.6.5 관련성 판정 행위를 계승한다 (§6.3)."

spec §6.3 표 1행 (원문 인용):
    "미리뷰 문서가 있어도 무관 파일 편집 비차단 (활성 작업이 참조하는
    문서만 차단)" → "active_task 관련성 판정 — ChangeSet 과 활성 Task 의
    참조 범위 결합 (§3.6)"

검증 축 (plan Task 4.2 steps — task 유/무 × 관련/무관 경로 4분면):
(a) task 있음 + 관련 경로 → 충족.
(b) task 있음 + 무관 경로 → **충족** (무관 편집 비차단 — v1.6.5 계승의
    핵심. 활성 task 존재 자체가 충족 조건이고, 그 task 의 참조 범위와의
    매칭을 추가로 요구하지 않는다).
(c) task 없음 + 코드(관련) 변경 → **미충족** (policy 가 요구하는 상황의
    BLOCK 재료).
(d) task 없음 + 무관/비코드 경로 → 충족 (과차단 금지).
(e) 관련성 fact 미확보(None) 시 보수적으로 "관련" 취급 — 판정 불능을
    무관(충족) 방향으로 승격하지 않는다.
(f) 실제 `engine.evaluator.evaluate(..., registry=...)` 관통 1건 —
    BLOCK(task 없음+관련) / ALLOW(task 있음, 또는 task 없음+무관).
(g) **strict 타입 계약** (사이클 A 리뷰 1회차 High 지적 수정) —
    `changeset.task_relevant` 가 `bool` 이 아닌 falsy 값(`""`/`0`/
    `[]`)이나 `bool` 이 아닌 truthy 값(`"true"`)이면 관대한 `bool()`
    강제 변환으로 삼키지 않고 `FactResolutionError` 로 승격한다 —
    최초 구현은 이 값들을 "무관"으로 오인정해 task 없는 변경이 ALLOW
    로 새는 경로였다. `task.active` 도 `str`/`None` 외의 malformed
    타입에 동일 규율을 적용한다. `None`(미확보)은 기존대로 보수적
    방향(관련 취급)을 유지 — malformed 는 아니다.

이 테스트 모듈은 `rein.capabilities.review`/`rein.capabilities.security`
를 어떤 형태로도 import 하지 않는다 — active_task 는 두 capability 와
달리 Evidence 발급형이 아니라 fact 결합 판정형이므로, evidence 저장소는
전혀 관여하지 않는다(모든 컨텍스트가 evidence 없이 구성된다).
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.capabilities.task.capability import (  # noqa: E402
    ActiveTaskRequirement,
    FACT_CHANGESET_TASK_RELEVANT,
    FACT_TASK_ACTIVE,
    REQUIREMENT_NAME,
    register_active_task,
)
from rein.engine import evaluator, runtime  # noqa: E402
from rein.engine.context import (  # noqa: E402
    EvaluationContext,
    FactResolutionError,
)
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
)


def _context(task_active=None, relevant=None):
    """task.active / changeset.task_relevant fact 로만 구성된 컨텍스트.

    evidence 소스는 배선하지 않는다(기본 NullEvidenceSource) — 이
    Requirement 는 evidence_for 를 조회하지 않으므로 무관하다.
    """
    facts = {}
    if task_active is not None:
        facts[FACT_TASK_ACTIVE] = task_active
    if relevant is not None:
        facts[FACT_CHANGESET_TASK_RELEVANT] = relevant
    return EvaluationContext(facts=facts)


class RelevanceMatrixTest(unittest.TestCase):
    """(a)~(d) — task 유/무 × 관련/무관 4분면, Requirement.evaluate 직접."""

    def setUp(self):
        self.requirement = ActiveTaskRequirement()

    def test_task_present_and_relevant_change_is_satisfied(self):
        # (a) task 있음 + 관련 경로 → 충족
        self.assertTrue(
            self.requirement.evaluate(
                _context(task_active="dod-2026-08-11-foo", relevant=True)
            )
        )

    def test_task_present_and_irrelevant_change_is_still_satisfied(self):
        # (b) task 있음 + 무관 경로 → 충족 (v1.6.5 관련성 판정 계승의
        # 핵심 — 활성 task 의 참조 범위 밖 파일도 차단하지 않는다)
        self.assertTrue(
            self.requirement.evaluate(
                _context(task_active="dod-2026-08-11-foo", relevant=False)
            )
        )

    def test_task_absent_and_relevant_change_is_unmet(self):
        # (c) task 없음 + 코드(관련) 변경 → 미충족 (BLOCK 재료)
        self.assertFalse(
            self.requirement.evaluate(
                _context(task_active=None, relevant=True)
            )
        )

    def test_task_absent_and_irrelevant_change_is_satisfied(self):
        # (d) task 없음 + 무관/비코드 경로 → 충족 (과차단 금지)
        self.assertTrue(
            self.requirement.evaluate(
                _context(task_active=None, relevant=False)
            )
        )

    def test_empty_string_task_identifier_counts_as_absent(self):
        # 빈 문자열은 "활성 task 없음"과 동일 취급 (falsy 판정)
        self.assertFalse(
            self.requirement.evaluate(_context(task_active="", relevant=True))
        )


class ConservativeDefaultTest(unittest.TestCase):
    """(e) — 관련성 fact 미확보 시 보수적으로 '관련' 취급 (BLOCK 방향 고정)."""

    def setUp(self):
        self.requirement = ActiveTaskRequirement()

    def test_missing_relevance_fact_without_active_task_is_unmet(self):
        # task 없음 + relevant fact 자체가 없음(None) → 확인 불가를
        # 무관(충족)으로 승격하지 않는다 — 보수적으로 미충족
        self.assertFalse(
            self.requirement.evaluate(_context(task_active=None, relevant=None))
        )

    def test_missing_relevance_fact_with_active_task_is_still_satisfied(self):
        # task 있음이면 relevant fact 부재와 무관하게 충족 (short-circuit)
        self.assertTrue(
            self.requirement.evaluate(
                _context(task_active="dod-2026-08-11-foo", relevant=None)
            )
        )

    def test_no_facts_at_all_is_conservatively_unmet(self):
        # 둘 다 완전히 미기재 — 가장 보수적인 방향(BLOCK 재료)으로 고정
        self.assertFalse(self.requirement.evaluate(EvaluationContext()))


class MalformedFactStrictnessTest(unittest.TestCase):
    """(g) — bool/str 이 아닌 오염된 fact 값은 관대히 보정하지 않고 raise.

    사이클 A 리뷰 1회차 High 지적: 최초 구현이 `changeset.task_relevant`
    를 `bool(value)` 로 강제 변환해 `""`/`0`/`[]` 같은 falsy-but-not-bool
    값을 "무관"으로 오인정했다 — task 가 없는 상태의 변경이 조용히
    ALLOW 로 새는 경로였다. 이 클래스는 그 값들이 이제 malformed 로
    거부됨을 고정한다.
    """

    def setUp(self):
        self.requirement = ActiveTaskRequirement()

    def test_falsy_non_bool_relevant_values_are_rejected_not_coerced(self):
        # 리뷰 지적의 핵심 재현 케이스 — 예전엔 이 값들이 bool(x)==False
        # 로 "무관"으로 오인정되어 task 없는 변경을 ALLOW 로 새게 했다.
        for bad_value in ("", 0, [], 0.0):
            with self.subTest(bad_value=bad_value):
                with self.assertRaises(FactResolutionError):
                    self.requirement.evaluate(
                        _context(task_active=None, relevant=bad_value)
                    )

    def test_truthy_non_bool_relevant_value_is_rejected(self):
        # 진리값이 True 방향이어도 bool 타입이 아니면 여전히 malformed —
        # "우연히 맞는 방향"이라도 관대한 보정을 허용하지 않는다
        # (계약은 값이 아니라 타입에 있다).
        with self.assertRaises(FactResolutionError):
            self.requirement.evaluate(
                _context(task_active=None, relevant="true")
            )

    def test_relevant_malformed_value_is_ignored_when_task_is_active(self):
        # task 가 있으면 relevant 를 아예 조회하지 않으므로(설계상
        # 판정에 영향 없음) malformed 여도 raise 하지 않는다 — 실제로
        # 읽어 쓰는 지점에서만 계약을 검사한다는 docstring 설계와 일치.
        self.assertTrue(
            self.requirement.evaluate(
                _context(task_active="dod-2026-08-11-foo", relevant="true")
            )
        )

    def test_none_relevant_is_not_treated_as_malformed(self):
        # None(미확보)은 malformed 가 아니라 기존 보수 방향(관련 취급)
        # 그대로 — strict 화가 기존 (e) 축의 방향을 바꾸지 않는다.
        self.assertFalse(
            self.requirement.evaluate(_context(task_active=None, relevant=None))
        )

    def test_malformed_task_active_values_are_rejected(self):
        # task.active 도 str/None 이 아닌 타입은 bool() 강제 변환으로
        # 우연히 "없음"/"있음"을 오인정하지 않도록 거부한다.
        for bad_value in (0, 1, [], {}, True, False, 3.5):
            with self.subTest(bad_value=bad_value):
                with self.assertRaises(FactResolutionError):
                    self.requirement.evaluate(
                        _context(task_active=bad_value, relevant=True)
                    )

    def test_malformed_task_active_is_checked_before_relevant(self):
        # task_active 검사가 relevant 조회보다 먼저 일어난다 — malformed
        # task_active 는 relevant 값과 무관하게 항상 raise.
        with self.assertRaises(FactResolutionError):
            self.requirement.evaluate(
                _context(task_active=[], relevant=None)
            )


class EvaluatorMalformedFactFailureModeTest(unittest.TestCase):
    """(g) 계속 — malformed fact 가 evaluator 관통 시 failure_mode 로 분기."""

    def setUp(self):
        self.policy = {
            "policy_id": "active-task-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - active_task\n"
                "failure_mode: closed\n",
                source="<test:active-task-gate-malformed>",
            ),
        }
        self.registry = RequirementRegistry()
        register_active_task(self.registry)

    def test_malformed_relevant_fact_yields_failure_mode_block(self):
        # relevant 가 malformed 이면 Requirement.evaluate 가
        # FactResolutionError 를 던지고, evaluator 는 이를 evidence_for
        # 경로와 동일하게 failure_mode 분기로 처리한다(EvidenceStorageError
        # 계열) — policy 의 failure_mode: closed 이므로 BLOCK.
        context = _context(task_active=None, relevant="not-a-bool")
        decision = evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "active-task-gate")
        # 정상 평가 BLOCK(REASON_MISSING_EVIDENCE)이 아니라 판단 불능
        # 경로임을 구분 — missing_requirements 튜플이 아니라 별도 reason.
        self.assertNotEqual(
            decision.reason, evaluator.REASON_MISSING_EVIDENCE
        )


class RegistrationTest(unittest.TestCase):
    """등록은 명시적 코드 등록만 — import 부작용 등록 금지 (spec §3.1 §32)."""

    def test_registration_is_explicit_not_import_side_effect(self):
        registry = RequirementRegistry()
        self.assertFalse(registry.is_registered(REQUIREMENT_NAME))
        implementation = register_active_task(registry)
        self.assertTrue(registry.is_registered(REQUIREMENT_NAME))
        self.assertIs(registry.resolve(REQUIREMENT_NAME), implementation)
        self.assertEqual(implementation.name, REQUIREMENT_NAME)
        self.assertIsInstance(implementation, ActiveTaskRequirement)

    def test_evidence_source_is_never_consulted(self):
        # active_task 는 fact 결합 판정형 — evidence 저장소 조회가
        # 전혀 없다는 것을 증명하는 가드. find() 가 호출되면 즉시 실패.
        class _ExplodingEvidenceSource:
            def find(self, requirement_name):
                raise AssertionError(
                    "active_task Requirement must not consult evidence "
                    "storage — it is a pure fact-combination judgment "
                    "(spec §3.6, DoD 생성 시스템과 분리)"
                )

        context = EvaluationContext(
            facts={
                FACT_TASK_ACTIVE: "dod-2026-08-11-foo",
                FACT_CHANGESET_TASK_RELEVANT: False,
            },
            evidence_source=_ExplodingEvidenceSource(),
        )
        self.assertTrue(ActiveTaskRequirement().evaluate(context))


class EvaluatorIntegrationTest(unittest.TestCase):
    """(f) — 실제 evaluator 관통 (registry 배선), BLOCK/ALLOW 양쪽."""

    def setUp(self):
        self.policy = {
            "policy_id": "active-task-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - active_task\n"
                "failure_mode: closed\n",
                source="<test:active-task-gate>",
            ),
        }
        self.registry = RequirementRegistry()
        register_active_task(self.registry)

    def _evaluate(self, task_active=None, relevant=None):
        context = _context(task_active=task_active, relevant=relevant)
        return evaluator.evaluate(
            "tool.pre", context, [self.policy], registry=self.registry
        )

    def test_no_active_task_with_relevant_change_yields_block(self):
        decision = self._evaluate(task_active=None, relevant=True)
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))
        self.assertEqual(decision.policy, "active-task-gate")
        self.assertEqual(decision.reason, evaluator.REASON_MISSING_EVIDENCE)

    def test_no_active_task_with_irrelevant_change_yields_allow(self):
        decision = self._evaluate(task_active=None, relevant=False)
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.missing_requirements, ())

    def test_active_task_yields_allow_regardless_of_relevance(self):
        for relevant in (True, False, None):
            with self.subTest(relevant=relevant):
                decision = self._evaluate(
                    task_active="dod-2026-08-11-foo", relevant=relevant
                )
                self.assertEqual(decision.decision, DECISION_ALLOW)
                self.assertEqual(decision.missing_requirements, ())

    def test_missing_relevance_fact_without_task_yields_block(self):
        # (e) 의 evaluator 관통 확인 — 확인 불가는 BLOCK 방향으로 고정
        decision = self._evaluate(task_active=None, relevant=None)
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, (REQUIREMENT_NAME,))

    def test_runtime_passes_registry_through(self):
        # runtime dict 인터페이스(cli 계약)의 registry passthrough
        result = runtime.evaluate(
            "tool.pre",
            {FACT_TASK_ACTIVE: None, FACT_CHANGESET_TASK_RELEVANT: True},
            [self.policy],
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_BLOCK)

        result = runtime.evaluate(
            "tool.pre",
            {
                FACT_TASK_ACTIVE: "dod-2026-08-11-foo",
                FACT_CHANGESET_TASK_RELEVANT: False,
            },
            [self.policy],
            registry=self.registry,
        )
        self.assertEqual(result["decision"], DECISION_ALLOW)


if __name__ == "__main__":
    unittest.main()
