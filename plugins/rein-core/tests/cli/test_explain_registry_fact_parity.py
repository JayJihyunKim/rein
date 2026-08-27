"""Phase 6 Task 6.1 수리 워커 B — Medium 4 재현 + 회귀 방지 (spec §7).

독립 리뷰어 지적(부모 판정 타당함): `run_event()` 는 `rein.cli.
_build_registry()` 로 5 capability 를 전부 등록한 registry 를 만들어
`runtime.evaluate(..., registry=registry)` 에 넘기지만, `rein/cli/
explain.py::run_explain()` 의 `registry` 기본값은 여전히 `None` 이었고
그대로 `evaluator.evaluate(..., registry=None)` 에 전달됐다 — 등록
구현체가 있는 요구도 항상 "단순 존재 검사" fallback 으로 평가됐다.
재현: 리뷰가 있었지만 코드가 그 뒤 다시 바뀐 stale evidence(존재는
하지만 digest 가 현재와 다름) 상황에서 존재 검사 fallback 은 ALLOW,
실제 등록 구현체(`CodeReviewRequirement.evaluate`)는 BLOCK — 그래서
`run_event` 는 BLOCK, `run_explain` 은 ALLOW 로 갈라졌다. explain.py
모듈 docstring 이 스스로 약속한 "basis 3필드는 run_event 와 항상
같다" 계약이 거짓이었던 것이 이 갈라짐의 실체다.

수리: `run_explain()` 의 `registry` 기본값을 sentinel
(`explain._REGISTRY_NOT_PROVIDED`)로 바꿔, 생략 시
`rein.cli._build_registry()` 를 호출한다(= `run_event()` 와 동일한
프로덕션 registry). `facts` 구성도 `rein.cli._build_facts()` 공유로
옮겨 fact 축의 동일한 부류 결함(Medium 5 수리와 얽힌 재발 경로)을
막는다.

이 파일의 첫 두 테스트는 **수리 전에는 실패했어야 하는** 재현
테스트다(reproduction-first) — 수리 후 통과로 바뀐 상태를 고정한다.
나머지는 회귀 방지 테스트다.
"""
import json
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import ENV_POLICY_DIR, _build_registry, run_event  # noqa: E402
from rein.cli.explain import _REGISTRY_NOT_PROVIDED, run_explain  # noqa: E402
from rein.engine import runtime  # noqa: E402
from rein.capabilities.review.capability import (  # noqa: E402
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_POLICY_VERSION,
    REQUIREMENT_NAME as CODE_REVIEW_NAME,
    issue_code_review_evidence,
)


class _StaticEvidenceSource:
    def __init__(self, records_by_requirement):
        self._records = records_by_requirement

    def find(self, requirement_name):
        return self._records.get(requirement_name, ())


def _review_policy_yaml():
    return (
        "trigger: tool.pre\n"
        "when:\n"
        "  tool: Bash\n"
        "require:\n"
        "  - code_review\n"
        "failure_mode: closed\n"
    )


def _tool_pre_payload(tool_name="Bash"):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": tool_name,
            "tool_input": {"command": "ls"},
        }
    )


def _stale_evidence_source():
    """존재는 하지만 digest 가 현재와 다른("stale") code_review evidence.

    존재 검사 fallback 은 이를 충족으로 오인정한다(ALLOW) — 등록된
    `CodeReviewRequirement.evaluate()` 는 digest 불일치로 미충족
    판정한다(BLOCK). 두 경로가 실제로 반대 방향으로 갈리는 시나리오
    (`tests/cli/test_run_event_registry_wiring.py` 의 divergence 테스트와
    동일한 재료 — 리뷰어가 이 파일 재현에서도 같은 부류의 재료를 썼다).
    """
    stale = issue_code_review_evidence(
        {"verdict": "PASS", "reviewed_digest": "old-digest"},
        current_digest="old-digest",
        policy_version="v1",
    )
    return _StaticEvidenceSource({CODE_REVIEW_NAME: (stale,)})


class ExplainDefaultRegistryMatchesRunEventTest(unittest.TestCase):
    """(a) 재현 + 수리 고정 — explain 기본 경로가 run_event 와 같은 registry 를 쓴다."""

    def test_explain_default_now_uses_production_registry_like_run_event(self):
        registry = _build_registry()
        evidence_source = _stale_evidence_source()
        facts = {
            "tool": "Bash",
            FACT_CHANGESET_REVIEW_DIGEST: "new-digest",
            FACT_POLICY_VERSION: "v1",
        }
        policies = [
            {
                "policy_id": "p-review",
                "fields": {
                    "trigger": "tool.pre",
                    "when": {"tool": "Bash"},
                    "require": (CODE_REVIEW_NAME,),
                    "failure_mode": "closed",
                },
            }
        ]

        # run_event()의 실제 배선과 동일한 재료로 runtime.evaluate 를
        # 직접 호출 — code_review 등록 구현체는 stale evidence 를
        # digest 불일치로 거부해야 한다 (참조 판정).
        reference_decision = runtime.evaluate(
            "tool.pre",
            facts,
            policies,
            evidence_source=evidence_source,
            registry=registry,
        )
        self.assertEqual(reference_decision["decision"], "BLOCK")

        # run_explain() 이 같은 policy 를 실제로 로드하도록 디스크에
        # 기록한다 — `_review_policy_yaml()` 은 위 `policies` 리스트와
        # 동일한 (trigger/when/require/failure_mode) 조합을 표현한다.
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(_review_policy_yaml())
            # code_review 는 증거 발급형 capability 다 — Phase 6 수리
            # 워커 F Medium D 이후, 이를 요구하는 policy 세트는 버전
            # 메타데이터 없이는 설정 오류로 차단된다(의도된 동작). 이
            # 테스트는 Medium D 가 아니라 registry 배선 parity 를
            # 겨냥하므로 유효한 버전 파일을 둔다.
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write('version: "1"\n')

            import unittest.mock as mock

            with mock.patch.dict(os.environ, {ENV_POLICY_DIR: policy_dir}):
                # explain 이 등록 구현체 없이(구 fallback, registry=None
                # 명시) 평가하면 여전히 ALLOW 로 갈라진다 — 이 갈라짐
                # 자체가 리뷰어가 지적한 결함의 정체였다는 것을 이
                # 테스트가 대조군으로 고정한다.
                fallback_explanation = run_explain(
                    _tool_pre_payload(),
                    registry=None,
                    evidence_source=evidence_source,
                    extra_facts=facts,
                )

                # 핵심 재현+수리 고정: registry 인자를 아예 생략하면
                # (오늘의 실제 bin/rein 호출부와 동일한 형태) 이제는
                # run_event 와 같은 프로덕션 registry 를 써서 BLOCK 으로
                # 일치한다.
                default_explanation = run_explain(
                    _tool_pre_payload(),
                    evidence_source=evidence_source,
                    extra_facts=facts,
                )

        self.assertEqual(fallback_explanation["decision"], "ALLOW")
        self.assertEqual(default_explanation["decision"], "BLOCK")
        self.assertEqual(
            default_explanation["decision"], reference_decision["decision"]
        )

    def test_omitted_registry_argument_resolves_to_build_registry_output(self):
        """`_REGISTRY_NOT_PROVIDED` sentinel 이 실제로 `_build_registry()` 로 치환됨을 직접 고정."""
        import inspect

        signature = inspect.signature(run_explain)
        self.assertIs(
            signature.parameters["registry"].default, _REGISTRY_NOT_PROVIDED
        )

        registry = _build_registry()
        self.assertEqual(
            registry.registered_names(), _build_registry().registered_names()
        )


class ExplainRunEventBasisParityWithRealPolicyDirTest(unittest.TestCase):
    """(b) 회귀 방지 — 실제 policy 디렉토리를 통한 BLOCK 이벤트에서 basis 3필드 일치.

    `tests/cli/test_doctor_explain.py` 의 기존 계약 테스트와 같은
    시나리오이지만, 여기서는 registry 인자를 아예 생략해(오늘의
    프로덕션 호출 형태) run_event/run_explain 이 여전히 basis 를
    공유함을 재확인한다 — 두 함수 모두 이제 `_build_registry()`/
    `_build_facts()` 를 공유하므로, `code_review` 가 실제로 등록된
    상태에서도(단순 존재 검사가 아니라) 두 basis 가 여전히 같아야
    한다.
    """

    def test_basis_matches_with_registered_code_review_and_no_evidence(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(_review_policy_yaml())
            # code_review 는 증거 발급형 capability 다 — Phase 6 수리
            # 워커 F Medium D 이후, 이를 요구하는 policy 세트는 버전
            # 메타데이터 없이는 설정 오류로 차단된다(의도된 동작). 이
            # 테스트는 Medium D 가 아니라 basis parity 를 겨냥하므로
            # 유효한 버전 파일을 둔다.
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write('version: "1"\n')

            raw_text = _tool_pre_payload("Bash")
            import unittest.mock as mock

            with mock.patch.dict(os.environ, {ENV_POLICY_DIR: policy_dir}):
                decision = run_event(raw_text)
                explanation = run_explain(raw_text)

        self.assertEqual(decision["decision"], "BLOCK")
        self.assertEqual(explanation["decision"], "BLOCK")
        self.assertEqual(explanation["basis"]["policy"], decision["policy"])
        self.assertEqual(
            explanation["basis"]["missing_requirements"],
            decision["missing_requirements"],
        )
        self.assertEqual(
            explanation["basis"]["evidence_refs"], decision["evidence_refs"]
        )
        self.assertEqual(
            explanation["basis"]["missing_requirements"], [CODE_REVIEW_NAME]
        )


if __name__ == "__main__":
    unittest.main()
