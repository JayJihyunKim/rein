"""Phase 6 Task 6.1 — run_event() 의 RequirementRegistry 실배선 (spec §7).

문제(실측 결함, `trail/dod/dod-2026-08-12-v2-phase6-authority.md` Task
6.1): v2 capability 5종(`review`/`security`/`task`/`testing`/`approval`)
은 각각 `register_*(registry)` 함수로 구현체를 등록할 수 있었지만, 그
함수를 실제로 호출해 `rein.engine.runtime.evaluate` 에 registry 를
넘기는 프로덕션 코드가 테스트 밖 어디에도 없었다 — `rein/cli/
__init__.py::run_event` 가 `registry` 인자 없이 `runtime.evaluate` 를
호출했고, 그 결과 `rein/engine/evaluator.py::_requirement_satisfied`
가 항상 `registry is None` 경로(단순 존재 검사 fallback)로 빠져 어떤
capability 판정도 실제로는 일어나지 않았다.

이 파일은 그 배선(`rein.cli._build_registry` + `run_event` 가 그 결과를
`runtime.evaluate(..., registry=...)` 에 넘기는 것)을 행위 기반으로
고정한다 — import 존재 확인이 아니라:

(a) `run_event` 가 실제로 5종 전부 등록된 registry 를 `runtime.evaluate`
    에 넘기는가.
(b) 그 registry 가 이름마다 올바른 구현체 클래스를 담고 있는가.
(c) 등록된 구현체가 **실제로 호출되어 판정에 관여**하는가 — 미등록
    fallback(`bool(context.evidence_for(requirement))`)과 다른 결과가
    나오는 두 방향의 시나리오로 증명한다:
      - fallback 이 잘못 차단하는 경우를 registry 가 올바르게 통과시킴
        (`active_task`: fact 만으로 충족 판정, evidence 저장소를 아예
        보지 않음).
      - fallback 이 잘못 통과시키는 경우를 registry 가 올바르게 차단함
        (`code_review`: evidence 가 "존재"만 해도 fallback 은 통과시키지만,
        registry 는 digest 불일치를 감지해 차단 — 리뷰 후 코드가 다시
        바뀐 stale evidence 를 fallback 은 못 잡는다).
(d) `_build_registry()` 를 두 번 독립 호출해도(재사용/재생성 어느 쪽이든)
    같은 facts·policies 에 대해 동일한 decision 을 낸다.
"""
import os
import sys
import unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import ENV_POLICY_DIR, _build_registry, run_event  # noqa: E402
from rein.engine import runtime  # noqa: E402
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402

from rein.capabilities.review.capability import (  # noqa: E402
    CodeReviewRequirement,
    FACT_CHANGESET_REVIEW_DIGEST as REVIEW_FACT_CHANGESET_DIGEST,
    FACT_POLICY_VERSION as REVIEW_FACT_POLICY_VERSION,
    REQUIREMENT_NAME as CODE_REVIEW_NAME,
    issue_code_review_evidence,
)
from rein.capabilities.security.capability import (  # noqa: E402
    SecurityReviewRequirement,
)
from rein.capabilities.task.capability import (  # noqa: E402
    ActiveTaskRequirement,
    FACT_TASK_ACTIVE,
    REQUIREMENT_NAME as ACTIVE_TASK_NAME,
)
from rein.capabilities.testing.capability import (  # noqa: E402
    TestsPassedRequirement,
)
from rein.capabilities.approval.capability import (  # noqa: E402
    UserApprovalRequirement,
)


class _StaticEvidenceSource:
    """`context.evidence_for()` 가 조회할 고정 evidence 레코드 test double."""

    def __init__(self, records_by_requirement):
        self._records = records_by_requirement

    def find(self, requirement_name):
        return self._records.get(requirement_name, ())


def _policy(policy_id, require, event_name="tool.pre", failure_mode="closed"):
    return {
        "policy_id": policy_id,
        "fields": {
            "trigger": event_name,
            "when": {},
            "require": tuple(require),
            "failure_mode": failure_mode,
        },
    }


def _tool_pre_payload(tool_name="Bash"):
    import json

    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": tool_name,
            "tool_input": {"command": "ls"},
        }
    )


class RunEventPassesPopulatedRegistryTest(unittest.TestCase):
    """(a) run_event 가 5종 전부 등록된 registry 를 runtime.evaluate 에 넘긴다."""

    def test_run_event_calls_evaluate_with_fully_registered_registry(self):
        with mock.patch(
            "rein.engine.runtime.evaluate", wraps=runtime.evaluate
        ) as spy:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_POLICY_DIR, None)
                response = run_event(_tool_pre_payload())

        spy.assert_called_once()
        _, kwargs = spy.call_args
        registry = kwargs.get("registry")
        self.assertIsNotNone(
            registry,
            msg="run_event must pass a non-None registry to "
            "runtime.evaluate — otherwise evaluator falls back to the "
            "unregistered existence-check path (spec §7 wiring gap)",
        )
        self.assertEqual(registry.registered_names(), REQUIREMENT_NAMES)
        # 회귀 확인 — 배선 이전 계약(무정책 환경은 ALLOW)이 깨지지 않음
        self.assertEqual(response["decision"], "ALLOW")

    def test_repeated_calls_each_get_their_own_registry_instance(self):
        """매 이벤트 평가마다 독립된 registry — cycle 간 상태를 공유하지 않는다."""
        seen_registries = []
        with mock.patch(
            "rein.engine.runtime.evaluate", wraps=runtime.evaluate
        ) as spy:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_POLICY_DIR, None)
                run_event(_tool_pre_payload())
                run_event(_tool_pre_payload())
        for call in spy.call_args_list:
            seen_registries.append(call.kwargs["registry"])
        self.assertEqual(len(seen_registries), 2)
        self.assertIsNot(seen_registries[0], seen_registries[1])


class BuildRegistryContentTest(unittest.TestCase):
    """(b) `_build_registry()` 가 이름마다 올바른 구현체 클래스를 등록한다."""

    def test_all_five_contract_names_are_registered(self):
        registry = _build_registry()
        for name in REQUIREMENT_NAMES:
            self.assertTrue(
                registry.is_registered(name),
                msg="{!r} must have a registered implementation".format(name),
            )
        self.assertEqual(registry.registered_names(), REQUIREMENT_NAMES)

    def test_each_name_resolves_to_its_own_capability_class_not_a_swap(self):
        registry = _build_registry()
        expected_classes = {
            "code_review": CodeReviewRequirement,
            "security_review": SecurityReviewRequirement,
            "active_task": ActiveTaskRequirement,
            "tests_passed": TestsPassedRequirement,
            "user_approval": UserApprovalRequirement,
        }
        for name, expected_class in expected_classes.items():
            implementation = registry.resolve(name)
            self.assertIsInstance(implementation, expected_class)
            self.assertEqual(implementation.name, name)


class RegisteredCapabilityDivergesFromFallbackTest(unittest.TestCase):
    """(c) 등록된 구현체가 실제로 호출되어, 존재검사 fallback과 다른 결과를 낸다.

    두 시나리오 모두 fallback(`registry=None`)과 registry 배선 결과가
    반대 방향으로 갈린다 — 우연히 같은 판정으로 수렴할 여지가 없다.
    """

    def test_active_task_fact_alone_satisfies_where_fallback_would_block(self):
        """fallback: evidence 부재 → BLOCK. registry: fact 만으로 충족 → ALLOW."""
        policies = [_policy("p-task", require=[ACTIVE_TASK_NAME])]
        facts = {FACT_TASK_ACTIVE: "task-123"}

        fallback_decision = runtime.evaluate(
            "tool.pre", facts, policies, registry=None
        )
        self.assertEqual(fallback_decision["decision"], "BLOCK")
        self.assertEqual(
            fallback_decision["missing_requirements"], [ACTIVE_TASK_NAME]
        )

        original_evaluate = ActiveTaskRequirement.evaluate
        calls = []

        def _spying_evaluate(self, context):
            calls.append(context)
            return original_evaluate(self, context)

        registry = _build_registry()
        with mock.patch.object(
            ActiveTaskRequirement, "evaluate", _spying_evaluate
        ):
            registered_decision = runtime.evaluate(
                "tool.pre", facts, policies, registry=registry
            )

        self.assertEqual(
            len(calls),
            1,
            msg="the registered ActiveTaskRequirement.evaluate() must "
            "actually be invoked — not bypassed by the fallback path",
        )
        self.assertEqual(registered_decision["decision"], "ALLOW")
        self.assertEqual(registered_decision["missing_requirements"], [])

    def test_code_review_digest_mismatch_blocks_where_fallback_would_allow(
        self,
    ):
        """fallback: evidence '존재' 만으로 통과. registry: digest 불일치 → 차단.

        review 후 코드가 다시 바뀐 stale evidence 는 v1 류 존재 검사로는
        걸러지지 않는다 — 이게 바로 registry 배선이 닫아야 하는 구멍이다
        (spec §3.6 code_review: "Reviewer PASS 반환만으로 Evidence 자동
        인정 안 됨 — Runtime 이 현재 digest 와 결합해 발급").
        """
        stale_evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": "old-digest"},
            current_digest="old-digest",
            policy_version="v1",
        )
        evidence_source = _StaticEvidenceSource(
            {CODE_REVIEW_NAME: (stale_evidence,)}
        )
        policies = [_policy("p-review", require=[CODE_REVIEW_NAME])]
        # 코드가 리뷰 이후 다시 바뀐 상태 — 현재 digest != 리뷰 시점 digest
        facts = {
            REVIEW_FACT_CHANGESET_DIGEST: "new-digest",
            REVIEW_FACT_POLICY_VERSION: "v1",
        }

        fallback_decision = runtime.evaluate(
            "tool.pre",
            facts,
            policies,
            evidence_source=evidence_source,
            registry=None,
        )
        self.assertEqual(
            fallback_decision["decision"],
            "ALLOW",
            msg="sanity check — the naive existence-check fallback "
            "treats any present evidence record as satisfying, "
            "regardless of digest validity",
        )

        original_evaluate = CodeReviewRequirement.evaluate
        calls = []

        def _spying_evaluate(self, context):
            calls.append(context)
            return original_evaluate(self, context)

        registry = _build_registry()
        with mock.patch.object(
            CodeReviewRequirement, "evaluate", _spying_evaluate
        ):
            registered_decision = runtime.evaluate(
                "tool.pre",
                facts,
                policies,
                evidence_source=evidence_source,
                registry=registry,
            )

        self.assertEqual(len(calls), 1)
        self.assertEqual(registered_decision["decision"], "BLOCK")
        self.assertEqual(
            registered_decision["missing_requirements"], [CODE_REVIEW_NAME]
        )


class RegistryRebuildDeterminismTest(unittest.TestCase):
    """(d) registry 를 재생성해도(캐시하지 않아도) decision 은 동일하다."""

    def test_two_independently_built_registries_yield_identical_decisions(
        self,
    ):
        stale_evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": "old-digest"},
            current_digest="old-digest",
            policy_version="v1",
        )
        evidence_source = _StaticEvidenceSource(
            {CODE_REVIEW_NAME: (stale_evidence,)}
        )
        policies = [
            _policy(
                "p-review-and-task",
                require=[CODE_REVIEW_NAME, ACTIVE_TASK_NAME],
            )
        ]
        facts = {
            REVIEW_FACT_CHANGESET_DIGEST: "new-digest",
            REVIEW_FACT_POLICY_VERSION: "v1",
            FACT_TASK_ACTIVE: "task-123",
        }

        registry_a = _build_registry()
        registry_b = _build_registry()
        self.assertIsNot(
            registry_a,
            registry_b,
            msg="sanity check — the two builds must be independent "
            "instances, not the same cached object",
        )

        decision_a = runtime.evaluate(
            "tool.pre",
            facts,
            policies,
            evidence_source=evidence_source,
            registry=registry_a,
        )
        decision_b = runtime.evaluate(
            "tool.pre",
            facts,
            policies,
            evidence_source=evidence_source,
            registry=registry_b,
        )

        self.assertEqual(decision_a, decision_b)
        # 구체값도 고정 — active_task 는 fact 로 충족, code_review 는
        # digest 불일치로 미충족이어야 한다 (부분 충족의 대표 케이스)
        self.assertEqual(decision_a["decision"], "BLOCK")
        self.assertEqual(
            decision_a["missing_requirements"], [CODE_REVIEW_NAME]
        )


if __name__ == "__main__":
    unittest.main()
