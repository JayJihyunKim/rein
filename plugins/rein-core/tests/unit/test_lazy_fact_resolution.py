"""plan Task 2.2 — Lazy Fact Resolution + request-scoped cache (spec §3.2).

covers: fact-resolver-computes-only-policy-demanded-facts-once-per-cycle

spec §3.2 원문 계약:
    "Policy 가 요구하는 Fact 만 계산한다. Cheap(tool.type, path, 기본
    명령 분류) / Expensive(git status, ChangeSet, digest, active task,
    review state) 구분. 동일 Evaluation Cycle 에서 Fact 는 1회만 계산
    (request-scoped cache)."

고정하는 계약:
- 미요구 fact (특히 expensive) 는 계산 0회 — 등록만으로 실행되지 않는다.
- 요구된 fact 는 동일 EvaluationContext (= Evaluation Cycle) 안에서
  정확히 1회 계산 — 재조회·복수 policy 요구 모두 cache hit.
- resolver 는 cheap/expensive cost 로 구분 등록되고 미지 cost 는 거부.
- 스냅샷 fact 가 resolver 보다 우선한다 (기존 계약 불변 — 사전 해석된
  스냅샷은 그대로, resolver 는 스냅샷에 없는 키만 담당).
- fact 해석 실패 = 판단 불능 승격: FactResolutionError 는
  EvidenceStorageError 하위 타입 (evidence 부재 = default 반환과 절대
  섞이지 않는다 — spec §3.4 경계의 fact 측 대칭).
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
    FACT_COST_EXPENSIVE,
    EvaluationContext,
    EvidenceStorageError,
    FactRegistrationError,
    FactResolutionError,
    FactResolverRegistry,
)
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK  # noqa: E402


class _CountingResolver:
    """계산 횟수 계측 resolver — lazy/1회 계약을 카운터로 검증한다."""

    def __init__(self, value=None, error=None):
        self.calls = 0
        self._value = value
        self._error = error

    def __call__(self, context):
        self.calls += 1
        if self._error is not None:
            raise self._error
        return self._value


def _load_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태의 policy fixture."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


class LazyOncePerCycleTest(unittest.TestCase):
    """미요구 계산 0회 + 요구 fact 는 cycle 내 정확 1회."""

    def setUp(self):
        self.cheap = _CountingResolver(value="bash")
        self.expensive = _CountingResolver(value="digest-abc")
        self.registry = FactResolverRegistry()
        self.registry.register("command.type", self.cheap, FACT_COST_CHEAP)
        self.registry.register(
            "changeset.digest", self.expensive, FACT_COST_EXPENSIVE
        )
        self.context = EvaluationContext(fact_resolvers=self.registry)

    def test_registration_alone_computes_nothing(self):
        self.assertEqual(self.cheap.calls, 0)
        self.assertEqual(self.expensive.calls, 0)

    def test_undemanded_expensive_fact_is_never_computed(self):
        self.assertEqual(self.context.fact("command.type"), "bash")
        self.assertEqual(self.expensive.calls, 0)

    def test_demanded_fact_is_computed_exactly_once(self):
        first = self.context.fact("changeset.digest")
        second = self.context.fact("changeset.digest")
        self.assertEqual(first, "digest-abc")
        self.assertEqual(second, "digest-abc")
        self.assertEqual(self.expensive.calls, 1)

    def test_new_context_is_a_new_cycle(self):
        # request-scoped: cache 는 컨텍스트(=cycle) 단위, 전역이 아니다
        self.context.fact("changeset.digest")
        other = EvaluationContext(fact_resolvers=self.registry)
        other.fact("changeset.digest")
        self.assertEqual(self.expensive.calls, 2)

    def test_snapshot_fact_shadows_resolver(self):
        # 사전 해석된 스냅샷이 우선 — resolver 는 실행조차 안 된다
        context = EvaluationContext(
            facts={"command.type": "git.commit"},
            fact_resolvers=self.registry,
        )
        self.assertEqual(context.fact("command.type"), "git.commit")
        self.assertEqual(self.cheap.calls, 0)

    def test_unregistered_fact_falls_back_to_default(self):
        self.assertIsNone(self.context.fact("no.such.fact"))
        self.assertEqual(self.context.fact("no.such.fact", "fallback"), "fallback")

    def test_resolved_none_is_a_value_not_default(self):
        # 해석 결과 None 도 값이다 — default 로 대체되지 않고 cache 된다
        registry = FactResolverRegistry()
        none_resolver = _CountingResolver(value=None)
        registry.register("maybe.fact", none_resolver, FACT_COST_CHEAP)
        context = EvaluationContext(fact_resolvers=registry)
        self.assertIsNone(context.fact("maybe.fact", "fallback"))
        self.assertIsNone(context.fact("maybe.fact", "fallback"))
        self.assertEqual(none_resolver.calls, 1)

    def test_resolver_may_derive_from_other_facts_via_context(self):
        # 파생 fact — resolver 간 공유는 Fact 경유 (context 인자)
        registry = FactResolverRegistry()
        command = _CountingResolver(value="git commit -m x")
        registry.register("command", command, FACT_COST_CHEAP)
        registry.register(
            "command.kind",
            lambda context: context.fact("command").split()[0],
            FACT_COST_CHEAP,
        )
        context = EvaluationContext(fact_resolvers=registry)
        self.assertEqual(context.fact("command.kind"), "git")
        self.assertEqual(command.calls, 1)

    def test_facts_copy_does_not_force_resolution(self):
        # facts() 사본은 스냅샷 + 이미 해석된 값만 — 강제 해석 금지
        context = EvaluationContext(
            facts={"tool": "Bash"}, fact_resolvers=self.registry
        )
        context.fact("command.type")
        snapshot = context.facts()
        self.assertEqual(
            snapshot, {"tool": "Bash", "command.type": "bash"}
        )
        self.assertEqual(self.expensive.calls, 0)
        # 사본 변조가 컨텍스트 내부에 새어 들어가지 않는다
        snapshot["tool"] = "mutated"
        self.assertEqual(context.fact("tool"), "Bash")


class PolicyDemandDrivenTest(unittest.TestCase):
    """Policy 가 요구하는 Fact 만 계산 — evaluator 경유 검증."""

    def setUp(self):
        self.demanded = _CountingResolver(value="git.commit")
        self.undemanded = _CountingResolver(value="digest-abc")
        self.registry = FactResolverRegistry()
        self.registry.register("command.type", self.demanded, FACT_COST_CHEAP)
        self.registry.register(
            "changeset.digest", self.undemanded, FACT_COST_EXPENSIVE
        )

    def _evaluate(self, policies):
        return evaluator.evaluate(
            "tool.pre",
            EvaluationContext(fact_resolvers=self.registry),
            policies,
        )

    def test_policy_when_pulls_only_demanded_facts(self):
        gate = _load_policy(
            "gate",
            "trigger: tool.pre\nwhen:\n  command.type: git.commit\n",
        )
        decision = self._evaluate([gate])
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(decision.policy, "gate")
        self.assertEqual(self.demanded.calls, 1)
        self.assertEqual(self.undemanded.calls, 0)

    def test_multiple_policies_share_one_computation(self):
        first = _load_policy(
            "first",
            "trigger: tool.pre\nwhen:\n  command.type: git.commit\n",
        )
        second = _load_policy(
            "second",
            "trigger: tool.pre\nwhen:\n  command.type: git.commit\n",
        )
        self._evaluate([first, second])
        self.assertEqual(self.demanded.calls, 1)

    def test_no_policy_demand_means_no_computation(self):
        log_only = _load_policy("log-only", "trigger: tool.pre\n")
        decision = self._evaluate([log_only])
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertEqual(self.demanded.calls, 0)
        self.assertEqual(self.undemanded.calls, 0)


class RegistryContractTest(unittest.TestCase):
    """cheap/expensive 구분 등록 + 등록 시점 명시 거부."""

    def test_cost_classes_are_distinct_and_queryable(self):
        registry = FactResolverRegistry()
        registry.register("tool.type", lambda context: "Bash", FACT_COST_CHEAP)
        registry.register(
            "git.status", lambda context: "clean", FACT_COST_EXPENSIVE
        )
        self.assertNotEqual(FACT_COST_CHEAP, FACT_COST_EXPENSIVE)
        self.assertEqual(registry.cost("tool.type"), FACT_COST_CHEAP)
        self.assertEqual(registry.cost("git.status"), FACT_COST_EXPENSIVE)
        self.assertEqual(
            registry.registered(),
            {
                "tool.type": FACT_COST_CHEAP,
                "git.status": FACT_COST_EXPENSIVE,
            },
        )

    def test_unknown_cost_is_rejected(self):
        registry = FactResolverRegistry()
        with self.assertRaises(FactRegistrationError):
            registry.register("tool.type", lambda context: "Bash", "medium")

    def test_duplicate_registration_is_rejected(self):
        registry = FactResolverRegistry()
        registry.register("tool.type", lambda context: "Bash", FACT_COST_CHEAP)
        with self.assertRaises(FactRegistrationError):
            registry.register(
                "tool.type", lambda context: "Read", FACT_COST_CHEAP
            )

    def test_non_callable_resolver_is_rejected(self):
        registry = FactResolverRegistry()
        with self.assertRaises(FactRegistrationError):
            registry.register("tool.type", "not-a-callable", FACT_COST_CHEAP)


class ResolutionFailureEscalationTest(unittest.TestCase):
    """fact 해석 실패 = 판단 불능 승격 (spec §3.4 경계의 fact 측 대칭)."""

    def setUp(self):
        self.broken = _CountingResolver(
            error=RuntimeError("git backend unreachable")
        )
        self.registry = FactResolverRegistry()
        self.registry.register(
            "changeset.digest", self.broken, FACT_COST_EXPENSIVE
        )
        self.context = EvaluationContext(fact_resolvers=self.registry)

    def test_resolver_failure_raises_not_returns_default(self):
        # 실패를 default(부재 위장)로 삼키면 정상 평가와 판단 불능이
        # 섞인다 — 반드시 예외로 승격한다
        with self.assertRaises(FactResolutionError):
            self.context.fact("changeset.digest", "fallback")

    def test_failure_is_an_evaluation_failure_type(self):
        # EvidenceStorageError 하위 = evaluator 가 인정하는 판단 불능 계열
        self.assertTrue(issubclass(FactResolutionError, EvidenceStorageError))

    def test_failure_is_cached_within_cycle(self):
        # 실패도 request-scoped cache — 동일 cycle 재시도 없이 재승격
        for _ in range(2):
            with self.assertRaises(FactResolutionError):
                self.context.fact("changeset.digest")
        self.assertEqual(self.broken.calls, 1)

    def test_failure_message_names_the_fact_and_cause(self):
        try:
            self.context.fact("changeset.digest")
        except FactResolutionError as error:
            self.assertIn("changeset.digest", str(error))
            self.assertIn("git backend unreachable", str(error))
        else:
            self.fail("FactResolutionError not raised")

    def test_cyclic_resolution_escalates_instead_of_hanging(self):
        registry = FactResolverRegistry()
        registry.register(
            "a", lambda context: context.fact("b"), FACT_COST_CHEAP
        )
        registry.register(
            "b", lambda context: context.fact("a"), FACT_COST_CHEAP
        )
        context = EvaluationContext(fact_resolvers=registry)
        with self.assertRaises(FactResolutionError):
            context.fact("a")

    def test_when_matching_failure_no_longer_propagates_to_caller(self):
        # Phase 6 4회차 리뷰 Medium 3 시정 — 이 테스트는 이전에 "미해결
        # 상태의 기록"이었다(resolver 가 실배선되기 전까지는 무해했지만,
        # 실배선된 뒤에는 policy 가 선언한 failure_mode 의 의미를 통째로
        # 없애고 raw 예외를 강제했다). `evaluator.evaluate()` 는 이제
        # when 조건 계산 경로도 requirement 평가와 동일하게
        # `EvidenceStorageError` 계열을 잡아 failure_mode 3분기로
        # 수렴시킨다 — 예외가 아니라 Decision 이 나온다. failure_mode
        # 미선언은 kernel 폐쇄 스키마 기본값(closed)이므로 BLOCK 이다.
        # 이 정확한 재현·경계의 전체 스위트는
        # `tests/unit/test_policy_condition_failure_mode.py` 참조 —
        # 이 테스트는 lazy fact resolution 스위트 안에서 "이 파일이
        # 문서화하던 미해결 상태가 해소됐다"는 사실만 확인한다.
        gate = _load_policy(
            "gate",
            "trigger: tool.pre\nwhen:\n  changeset.digest: digest-abc\n",
        )
        decision = evaluator.evaluate("tool.pre", self.context, [gate])
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertNotEqual(decision.reason, evaluator.REASON_NO_MATCH)


if __name__ == "__main__":
    unittest.main()
