"""배포 번들이 전환 축(DEFAULT_SWITCHED_CAPABILITIES) 전부에 대해
"오버라이드 없는 프로젝트에서도 그 축을 요구하는 정책이 번들만으로
해소된다"를 고정하는 계약 테스트.

`test_bundled_task_axis_policy.py` 는 active_task 축 하나에 대해서만 이
계약을 고정한다. 축 하나씩 사후에 계약을 추가하는 방식은 다음 축이 같은
방식으로 새는 것을 막지 못하므로, 이 테스트는
`rein.engine.authority.DEFAULT_SWITCHED_CAPABILITIES` 를 직접 순회해
**그 집합에 속하는 모든 capability** 에 대해 계약을 고정하고, 아래
`_AXIS_BUNDLE_DIRS` 맵의 key 집합이 `DEFAULT_SWITCHED_CAPABILITIES` 와
정확히 같음을 별도로 단언한다 — 새 축이 배포 기본값에 편입되는데 이 맵이
갱신되지 않으면 그 축의 번들 부재가 조용히 넘어가는 대신 이 테스트가
즉시 깨진다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine.authority import DEFAULT_SWITCHED_CAPABILITIES  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402

# capability -> 배포 번들 정책 디렉토리(절대경로). 이 딕셔너리 자체가
# 계약의 SSOT 다: `DEFAULT_SWITCHED_CAPABILITIES` 에 이름이 추가됐는데
# 여기 매핑이 안 생기면 아래 키집합 테스트가, 매핑은 있는데 그 폴더가
# 배포본에 없으면 아래 존재 테스트가, 폴더는 있는데 그 축을 요구하는
# 정책이 하나도 없으면 아래 require 테스트가 각각 깨진다.
_AXIS_BUNDLE_DIRS = {
    "code_review": os.path.join(_PLUGIN_ROOT, "policies", "default"),
    "security_review": os.path.join(
        _PLUGIN_ROOT, "policies", "security-axis"
    ),
    "active_task": os.path.join(_PLUGIN_ROOT, "policies", "task-axis"),
}

# repo-root 훅 테스트 픽스처(tests/fixtures/policy/<axis>/) — 드리프트
# 가드 대상. code_review(policies/default)는 대응하는 repo-root 픽스처가
# 없어 제외한다 — `test_bundled_task_axis_policy.py` 의 동명 테스트와
# 동일하게 "픽스처가 있는 축만" 대조한다.
_REPO_ROOT = os.path.dirname(os.path.dirname(_PLUGIN_ROOT))
_FIXTURES_ROOT = os.path.join(_REPO_ROOT, "tests", "fixtures", "policy")
_FIXTURE_DIRS = {
    "security_review": os.path.join(_FIXTURES_ROOT, "security-axis"),
    "active_task": os.path.join(_FIXTURES_ROOT, "task-axis"),
}

# 이 저장소(플러그인 원본 repo)의 프로젝트 오버라이드(.rein/policy/<axis>/)
# — 존재할 때만 대조한다. main 브랜치·standalone 추출 트리에는 이 폴더가
# 없으므로 부재는 skip 이지 실패가 아니다. 오버라이드가 번들과 의미가
# 갈라지면 dogfood 환경만 다른 규율로 돌게 되어 배포본 결함을 못 느낀다.
_DOGFOOD_OVERRIDE_ROOT = os.path.join(_REPO_ROOT, ".rein", "policy")
_DOGFOOD_OVERRIDE_DIRS = {
    "security_review": os.path.join(_DOGFOOD_OVERRIDE_ROOT, "security-axis"),
    "active_task": os.path.join(_DOGFOOD_OVERRIDE_ROOT, "task-axis"),
}


class BundledSwitchedAxesMapCompletenessTest(unittest.TestCase):
    """맵 자체가 `DEFAULT_SWITCHED_CAPABILITIES` 와 어긋나면 즉시 실패."""

    def test_map_key_set_equals_default_switched_capabilities(self):
        self.assertEqual(
            set(_AXIS_BUNDLE_DIRS),
            set(DEFAULT_SWITCHED_CAPABILITIES),
            "capability -> 번들 디렉토리 매핑이 DEFAULT_SWITCHED_CAPABILITIES "
            "와 어긋남 — 새 축이 배포 기본 전환 목록에 추가(또는 제거)됐는데 "
            "이 테스트 파일의 매핑이 갱신되지 않았다",
        )


class BundledSwitchedAxesShipTest(unittest.TestCase):
    """전환 3축 전부 — 번들 폴더 실재 + 로드 가능 + 버전 메타 로드 가능."""

    def test_bundle_dir_exists_for_every_switched_capability(self):
        for capability, bundle_dir in _AXIS_BUNDLE_DIRS.items():
            with self.subTest(capability=capability):
                self.assertTrue(
                    os.path.isdir(bundle_dir),
                    "배포 번들 정책 폴더가 없음 ({}): {}".format(
                        capability, bundle_dir
                    ),
                )

    def test_bundle_policies_load_without_error(self):
        for capability, bundle_dir in _AXIS_BUNDLE_DIRS.items():
            with self.subTest(capability=capability):
                policies = kernel_policy.load_policies(bundle_dir)
                self.assertGreater(
                    len(policies),
                    0,
                    "{}: 번들 정책 폴더에 로드 가능한 정책이 0개 — {}".format(
                        capability, bundle_dir
                    ),
                )

    def test_bundle_version_metadata_loads(self):
        for capability, bundle_dir in _AXIS_BUNDLE_DIRS.items():
            with self.subTest(capability=capability):
                version = kernel_policy.load_policy_version(bundle_dir)
                self.assertTrue(
                    version.version,
                    "{}: 번들 버전 메타데이터의 version 값이 비어있음".format(
                        capability
                    ),
                )


class BundledSwitchedAxesRequireOwnCapabilityTest(unittest.TestCase):
    """전환 3축 전부 — 번들 세트 중 최소 1개 정책이 그 axis 를 require."""

    def test_at_least_one_bundled_policy_requires_its_capability(self):
        for capability, bundle_dir in _AXIS_BUNDLE_DIRS.items():
            with self.subTest(capability=capability):
                policies = kernel_policy.load_policies(bundle_dir)
                matches = [
                    entry
                    for entry in policies
                    if capability in (entry["fields"].get("require") or [])
                ]
                self.assertGreater(
                    len(matches),
                    0,
                    "{}: 번들 정책 세트 어디에도 이 capability 를 require 하는 "
                    "정책이 없음 — 오버라이드 없는 프로젝트에서 이 축이 조용히 "
                    "'요구 없음'으로 통과한다(08-28/09-02 사고와 동일 클래스)"
                    .format(capability),
                )


class BundledFixtureParityTest(unittest.TestCase):
    """번들 정책이 커밋된 훅 테스트 픽스처와 의미가 동일한지(드리프트 가드).

    `test_bundled_task_axis_policy.py::test_no_drift_from_committed_test_fixture`
    와 같은 이유 — 같은 정책이 배포 번들 / 훅 테스트 픽스처(tests/fixtures/
    policy) / (security_review 한정) dogfood 오버라이드(.rein/policy) 여러
    곳에 사본으로 존재한다. 파서가 주석·헤더를 버리므로 로드된 필드 dict
    를 직접 비교해(trigger/when/require/failure_mode 전체 구조 비교) 사본이
    갈라졌는지 잡는다 — `when` 절 일부만 비교하면 두 사본이 다른 조건에서
    매칭되는데도 통과할 수 있다. repo-root 픽스처 트리 자체가 없는
    standalone plugin 추출 환경에서는 대조를 생략한다.
    """

    def test_bundle_matches_fixture_for_each_axis_with_a_fixture(self):
        if not os.path.isdir(_FIXTURES_ROOT):
            self.skipTest(
                "repo-root 테스트 픽스처 부재(standalone plugin 추출) — "
                "드리프트 대조 생략"
            )
        for capability, fixture_dir in _FIXTURE_DIRS.items():
            with self.subTest(capability=capability):
                self.assertTrue(
                    os.path.isdir(fixture_dir),
                    "{}: fixture 디렉토리 없음: {}".format(
                        capability, fixture_dir
                    ),
                )
                bundle_dir = _AXIS_BUNDLE_DIRS[capability]
                bundled = {
                    entry["policy_id"]: entry["fields"]
                    for entry in kernel_policy.load_policies(bundle_dir)
                }
                fixture = {
                    entry["policy_id"]: entry["fields"]
                    for entry in kernel_policy.load_policies(fixture_dir)
                }
                self.assertEqual(
                    bundled,
                    fixture,
                    "{}: 배포 번들 정책이 커밋된 테스트 픽스처와 의미가 "
                    "다름(드리프트) — 사본들을 동기화하라".format(capability),
                )


class DogfoodOverrideParityTest(unittest.TestCase):
    """이 저장소의 프로젝트 오버라이드가 존재하면 번들과 의미가 같아야 한다."""

    def test_bundle_matches_dogfood_override_when_present(self):
        compared = 0
        for capability, override_dir in _DOGFOOD_OVERRIDE_DIRS.items():
            if not os.path.isdir(override_dir):
                continue
            with self.subTest(capability=capability):
                bundled = {
                    entry["policy_id"]: entry["fields"]
                    for entry in kernel_policy.load_policies(
                        _AXIS_BUNDLE_DIRS[capability]
                    )
                }
                override = {
                    entry["policy_id"]: entry["fields"]
                    for entry in kernel_policy.load_policies(override_dir)
                }
                self.assertEqual(
                    bundled,
                    override,
                    "{}: 배포 번들 정책이 이 저장소의 프로젝트 오버라이드와 "
                    "의미가 다름(드리프트) — 사본들을 동기화하라".format(
                        capability
                    ),
                )
                compared += 1
        if compared == 0:
            self.skipTest("프로젝트 오버라이드 부재(main/standalone) — 대조 생략")


if __name__ == "__main__":
    unittest.main()
