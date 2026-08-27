"""Phase 6 마무리 수리 워커 H — hot path 비용 게이팅 정확도 수리.

부모 지적: `_declared_requirements(policies)` 가 trigger 를 전혀 보지
않고 로드된 policy 전체의 `require:` 합집합을 냈다 — 기본 배포 정책
세트(`policies/default/commit.yaml`/`push.yaml`/`push-testing.yaml`/
`release.yaml`)가 전부 code_review(증거 발급형)를 요구하므로, 사실상
모든 이벤트(파일 편집 포함)에서 changeset digest 가 계산되는 hot path
비용 회귀였다.

수리 방향(당시 부모 지시): `require:` 를 훑을 때 **현재 이벤트의
trigger 와 일치하는 policy 만** 본다(`when` 은 fact 순환 의존 때문에
계속 무시).

## Phase 6 3회차 재리뷰 이후 — 이 파일의 범위가 좁혀졌다

독립 리뷰어 3회차가 위 narrowing 근사 자체의 실효성을 반박했다: trigger
만 보고 `when` 은 무시하는 한, 배포 기본 policy 4개가 전부 같은
trigger(`tool.pre`)를 공유해 narrowing 이 그 사이에서는 아무것도
걸러내지 못했다(파일 편집에서도 changeset 해시가 계산되던 실제 문제).
그래서 changeset 해시 3종(`changeset.digest`/`changeset.sensitive_
digest`/`changeset.tag`)의 계산 여부는 이제 이 함수의 근사가 아니라
`_build_fact_resolvers()` 의 **진짜 lazy resolver**(`rein/engine/
runtime.py` 모듈 docstring "fact_resolvers 배선" 절)가 결정한다 — 실제
매칭된 policy 의 `require:` 를 평가하는 capability 구현체가
`context.fact()` 를 호출할 때만 계산된다.

이 파일에 남아 있던 "narrowing 이 `_build_facts()` 의 digest-in-dict
출력에 미치는 영향" 절(구 2·3번 섹션)은 그래서 전제 자체가 무효화됐다
— `_build_facts()` 는 이제 어떤 조합에서도 이 3개 fact 를 값으로
반환하지 않는다(`tests/cli/test_changeset_fact_dependency_gating.py::
BuildFactsNeverComputesChangesetHashesTest`). 그 파일이 이제 "실제
호출 여부"를 계측으로 직접 고정한다(같은 파일의
`LazyResolverInvocationTest` — 다른 trigger 의 policy 는 evaluator
loop 최상단에서 걸러져 require: 순회 자체가 없다는, 이 절이 원래
증명하려던 것보다 더 근본적인 사실까지 포함한다).

`_declared_requirements()` 함수 자체는 폐기되지 않았다 — `policy.
version` 설정 오류 조기 감지와 `active_task`/`user_approval` fact
게이팅에는 여전히 이 trigger narrowing 근사가 쓰인다(`rein/cli/
__init__.py::_declared_requirements` docstring "Phase 6 3회차 재리뷰
이후 소비처" 절). 아래 1번 섹션(`_declared_requirements` 자체의 단위
테스트)은 그 용도에 대해 여전히 유효하므로 그대로 유지한다.

`_build_facts()` 를 직접 부르는 이 스위트의 event dict 는 프로덕션
경로(`rein.platform.claude.adapter.normalize_event`)와 동일하게
`"name"` 키를 채운다 — 그래야 trigger narrowing 이 실제로 발동한다
(이름을 안 채우면 `_declared_requirements` 의 하위호환 fallback
(trigger=None → 필터링 없음)으로 흡수돼 이 스위트가 의도한 경로를
지나지 않는다).
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import _declared_requirements  # noqa: E402


def _loaded_policy(requirement_names, trigger="tool.pre", when=None):
    return {
        "policy_id": "test-policy",
        "fields": {
            "trigger": trigger,
            "when": when or {},
            "require": list(requirement_names),
            "failure_mode": "closed",
        },
    }


# ===========================================================================
# 1. `_declared_requirements` 자체 — trigger narrowing 단위 테스트
#    (policy.version 설정 오류 조기 감지 + active_task/user_approval fact
#    게이팅 용도로 여전히 유효, 위 모듈 docstring "소비처" 절 참조)
# ===========================================================================


class DeclaredRequirementsTriggerFilterTest(unittest.TestCase):
    def test_trigger_none_keeps_backward_compatible_union(self):
        # 기존 호출자(트리거 인자 없음)는 여전히 전체 합집합을 낸다 —
        # 하위호환 fallback (모듈 docstring 참조).
        policies = [
            _loaded_policy(["code_review"], trigger="tool.pre"),
            _loaded_policy(["active_task"], trigger="task.completed"),
        ]
        self.assertEqual(
            _declared_requirements(policies),
            {"code_review", "active_task"},
        )

    def test_matching_trigger_only_is_included(self):
        policies = [
            _loaded_policy(["code_review"], trigger="tool.pre"),
            _loaded_policy(["active_task"], trigger="task.completed"),
        ]
        self.assertEqual(
            _declared_requirements(policies, "tool.pre"),
            {"code_review"},
        )

    def test_no_policy_matches_trigger_yields_empty_set(self):
        policies = [_loaded_policy(["code_review"], trigger="task.completed")]
        self.assertEqual(_declared_requirements(policies, "tool.pre"), set())

    def test_when_is_still_ignored_within_a_matching_trigger(self):
        # trigger 만 좁힌다 — `when: tool: Write` 가 실제 이벤트와
        # 맞지 않아도(Bash) trigger 가 같으면 여전히 declared 에 포함된다
        # (정확도 경계, 모듈 docstring "trigger narrowing 의 정확도
        # 경계" 절).
        policies = [
            _loaded_policy(
                ["tests_passed"], trigger="tool.pre", when={"tool": "Write"}
            )
        ]
        self.assertEqual(
            _declared_requirements(policies, "tool.pre"), {"tests_passed"}
        )


if __name__ == "__main__":
    unittest.main()
