"""Phase 6 Task 6.1 수리 워커 F — Medium C/D 재현 + 회귀 방지 (spec §3.4).

독립 리뷰어 지적(부모 판정 타당함) — `rein/cli/__init__.py::
_load_policy_version_fact()` 의 두 가지 결함:

- **Medium C**: `os.path.isfile()` 이 거짓인 모든 경우(파일이 아예 없는
  경우 *와* 그 경로에 디렉터리 등 다른 것이 있는 경우 둘 다)를 `None`
  ("미설정")으로 흡수한다. 손상된 상태(디렉터리)가 "그냥 없음"과 똑같이
  조용히 넘어간다.
- **Medium D**: 버전 파일이 아예 없으면(정상적인 "미설정" 상태) 항상
  `None` 을 반환한다. 하지만 code_review/security_review/tests_passed/
  user_approval 중 하나라도 요구하는 정책 세트에서는, `policy.version`
  fact 부재가 evidence 발급형 capability 의 v2 evaluate() 를 항상
  미충족(False)으로 만든다 — evidence 가 하나라도 ledger 에 있으면
  authority 가 그 False 를 "v2 가 안다"로 오인해 legacy PASS 를 부당하게
  뒤집는다(`rein/cli/__init__.py` 모듈 docstring "evidence_source 를
  의도적으로 배선하지 않는다" 절이 policy.version 도입 전 이미 경고한
  바로 그 landmine 이 policy.version 부재로 재점화된다). 그래서 이런
  정책 세트에서 버전 파일 부재는 "설정 오류"로 명시 차단돼야 한다.

두 테스트 모두 **수리 전에는 실패했어야 할** 재현 테스트다.
"""
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import _build_facts  # noqa: E402
from rein.kernel.policy import PolicyVersionError, VERSION_FILENAME  # noqa: E402


def _loaded_policy(requirement_names):
    return {
        "policy_id": "test-policy",
        "fields": {
            "trigger": "tool.pre",
            "when": {},
            "require": list(requirement_names),
            "failure_mode": "closed",
        },
    }


class VersionFileIsDirectoryTest(unittest.TestCase):
    """Medium C 재현 + 수리 고정 — 버전 파일 경로가 디렉터리면 손상으로 차단한다."""

    def test_version_path_as_directory_raises_instead_of_absorbing_as_absent(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            os.makedirs(os.path.join(policy_dir, VERSION_FILENAME))

            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            with self.assertRaises(
                PolicyVersionError,
                msg="a directory sitting at the reserved version filename "
                "must surface as a configuration error, not silently "
                "absorb into 'fact absent' (Medium C)",
            ):
                _build_facts(
                    event,
                    project_root=None,
                    policies=[_loaded_policy(["code_review"])],
                    policy_dir=policy_dir,
                )


class VersionFileMissingWithEvidenceIssuedRequirementTest(unittest.TestCase):
    """Medium D 재현 + 수리 고정 — 증거 발급형 요구가 선언됐는데 버전 파일이 없으면 설정 오류."""

    def test_missing_version_file_raises_when_code_review_declared(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            # _version.yaml 자체를 만들지 않는다 — 진짜 미설정 상태.
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            with self.assertRaises(
                PolicyVersionError,
                msg="a policy set that declares an evidence-issued "
                "requirement (code_review) but has no policy version "
                "metadata must fail closed instead of silently letting "
                "policy.version stay absent (Medium D)",
            ):
                _build_facts(
                    event,
                    project_root=None,
                    policies=[_loaded_policy(["code_review"])],
                    policy_dir=policy_dir,
                )

    def test_missing_version_file_raises_for_each_evidence_issued_capability(self):
        for capability in (
            "code_review",
            "security_review",
            "tests_passed",
            "user_approval",
        ):
            with self.subTest(capability=capability):
                with tempfile.TemporaryDirectory() as policy_dir:
                    event = {
                        "tool": "Bash",
                        "payload": {"command": "git commit -m x"},
                    }
                    with self.assertRaises(PolicyVersionError):
                        _build_facts(
                            event,
                            project_root=None,
                            policies=[_loaded_policy([capability])],
                            policy_dir=policy_dir,
                        )

    def test_missing_version_file_is_allowed_when_only_active_task_declared(self):
        """활성 작업만 요구하는 정책 세트는 버전 부재를 허용해도 된다(경계 명시)."""
        with tempfile.TemporaryDirectory() as policy_dir:
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            facts = _build_facts(
                event,
                project_root=None,
                policies=[_loaded_policy(["active_task"])],
                policy_dir=policy_dir,
            )
        self.assertNotIn("policy.version", facts)

    def test_missing_version_file_is_allowed_for_empty_policy_set(self):
        """빈 정책 세트는 버전 부재를 허용해도 된다(경계 명시)."""
        with tempfile.TemporaryDirectory() as policy_dir:
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            facts = _build_facts(
                event,
                project_root=None,
                policies=[],
                policy_dir=policy_dir,
            )
        self.assertNotIn("policy.version", facts)


if __name__ == "__main__":
    unittest.main()
