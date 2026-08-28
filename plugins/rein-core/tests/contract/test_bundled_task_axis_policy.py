"""배포 번들 task-axis 축 정책이 실제로 동봉·로드되는지 고정하는 계약 테스트.

2026-08-28 hotfix (docs/reports/[issues]_2026-08-28.md): active_task 축은
배포 기본값(rein/engine/authority.py DEFAULT_SWITCHED_CAPABILITIES)으로 v2
전환돼 있는데, 그 축이 요구하는 tool.pre 정책이 배포본에 동봉되지 않아
오버라이드 없는 사용자 프로젝트에서 위임이 매번 FAIL → 모든 편집이 복구
불가로 하드 차단됐다(위임의 정책 위치를 프로젝트 오버라이드에서만 찾던
결함). 근본 수리는 두 갈래다: (1) 위임이 프로젝트 오버라이드 → 배포 번들
순으로 정책 위치를 해소하고(hooks/lib/active-task-gate.sh, 훅 스위트가
행위로 고정), (2) 그 배포 번들 정책 자체를 plugins/rein-core/policies/
task-axis/ 에 동봉한다. 이 테스트는 (2)를 배포 경로 그대로 고정한다 —
배포본에서 이 폴더가 다시 사라지거나 스키마가 어긋나면 즉시 깨진다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel import policy as kernel_policy  # noqa: E402

_TASK_AXIS_DIR = os.path.join(_PLUGIN_ROOT, "policies", "task-axis")

# 정책 파일 stem → 그 파일이 고정하는 `when.tool` 값. active_task 축은
# Edit/Write/MultiEdit 세 tool 이벤트 전부를 요구하는데 kernel D3 YAML
# subset 의 `when:` 이 OR 를 지원하지 않아 도구별 파일 1개씩으로 나뉜다
# (policies/task-axis/_version.yaml 헤더 참조).
_TOOL_POLICIES = {
    "edit-task": "Edit",
    "write-task": "Write",
    "multiedit-task": "MultiEdit",
}


class BundledTaskAxisPolicyShipTest(unittest.TestCase):
    def test_directory_and_files_are_shipped(self):
        self.assertTrue(
            os.path.isdir(_TASK_AXIS_DIR),
            "배포 번들 task-axis 정책 폴더가 없음: {}".format(_TASK_AXIS_DIR),
        )
        for stem in _TOOL_POLICIES:
            path = os.path.join(_TASK_AXIS_DIR, stem + ".yaml")
            self.assertTrue(
                os.path.isfile(path), "누락된 배포 정책 파일: {}".format(path)
            )
        self.assertTrue(
            os.path.isfile(os.path.join(_TASK_AXIS_DIR, "_version.yaml")),
            "배포 정책 버전 메타(_version.yaml) 누락",
        )

    def test_version_file_loads(self):
        version = kernel_policy.load_policy_version(_TASK_AXIS_DIR)
        self.assertEqual(version.version, "1")

    def test_loaded_policy_ids_are_exactly_the_three_tools(self):
        policies = kernel_policy.load_policies(_TASK_AXIS_DIR)
        policy_ids = sorted(entry["policy_id"] for entry in policies)
        self.assertEqual(policy_ids, sorted(_TOOL_POLICIES))
        # 버전 예약 파일이 정책으로 새지 않음
        self.assertNotIn("_version", policy_ids)

    def test_each_tool_policy_requires_active_task_fail_closed(self):
        policies = {
            entry["policy_id"]: entry["fields"]
            for entry in kernel_policy.load_policies(_TASK_AXIS_DIR)
        }
        for stem, tool in _TOOL_POLICIES.items():
            fields = policies[stem]
            self.assertEqual(fields.get("trigger"), "tool.pre", stem)
            self.assertEqual(
                (fields.get("when") or {}).get("tool"), tool, stem
            )
            self.assertIn("active_task", fields.get("require") or [], stem)
            self.assertEqual(fields.get("failure_mode"), "closed", stem)

    def test_no_drift_from_committed_test_fixture(self):
        """번들 정책이 커밋된 테스트 픽스처와 의미가 동일한지(드리프트 가드).

        같은 정책이 세 곳에 사본으로 존재한다(배포 번들 / 훅 테스트 픽스처
        `tests/fixtures/policy/task-axis` / dogfood 오버라이드 `.rein/policy/
        task-axis`). 파서가 주석·헤더를 버리므로 로드된 필드 dict 를 직접
        비교해 그 사본들이 갈라졌는지 잡는다. repo-root 픽스처가 없는
        standalone plugin 추출 환경에서는 대조를 생략한다(그 환경엔 애초에
        픽스처가 동봉되지 않는다).
        """
        repo_root = os.path.dirname(os.path.dirname(_PLUGIN_ROOT))
        fixture_dir = os.path.join(
            repo_root, "tests", "fixtures", "policy", "task-axis"
        )
        if not os.path.isdir(fixture_dir):
            self.skipTest(
                "repo-root 테스트 픽스처 부재(standalone plugin 추출) — "
                "드리프트 대조 생략"
            )
        bundled = {
            e["policy_id"]: e["fields"]
            for e in kernel_policy.load_policies(_TASK_AXIS_DIR)
        }
        fixture = {
            e["policy_id"]: e["fields"]
            for e in kernel_policy.load_policies(fixture_dir)
        }
        self.assertEqual(
            bundled,
            fixture,
            "배포 번들 정책이 커밋된 테스트 픽스처와 의미가 다름(드리프트) — "
            "세 사본(번들/픽스처/dogfood override)을 동기화하라",
        )


if __name__ == "__main__":
    unittest.main()
