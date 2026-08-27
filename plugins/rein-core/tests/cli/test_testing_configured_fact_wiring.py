"""Phase 6 Task 6.1 수리 워커 F — High A 재현 + 회귀 방지 (spec §5.2).

독립 리뷰어 지적(부모 판정 타당함): `rein/cli/__init__.py::_build_facts()`
는 `.rein/policy/testing.yaml` 을 읽지도, `testing.configured` fact 를
만들지도 않는다. `policies/default/push-testing.yaml` 은 `when:
testing.configured: "true"` 일 때만 매칭되므로(모듈 주석 참조), 이 fact
가 영원히 부재이면 그 정책은 **한 번도 매칭되지 않는다** — 프로젝트에
`.rein/policy/testing.yaml` 이 실제로 존재해 테스트 명령을 선언해도,
`git push` 가 `tests_passed` 없이 통과한다(코드 리뷰 evidence 만 있으면).

이 파일의 첫 테스트(`TestingConfiguredMissingAllowsPushWithoutTestsTest`)
는 **수리 전에는 실패했어야 할** 재현 테스트다 — fact 를 직접 주입하지
않고, 실제 `.rein/policy/testing.yaml` 픽스처 + 실제 `run_event()` 진입점
으로 재현한다(리뷰어가 지적한 "기본 정책 세트의 계약 테스트가 fact 를
직접 주입해 이 배선 결함을 가려왔다"는 문제를 피하기 위함).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import ENV_POLICY_DIR, ENV_PROJECT_ROOT, run_event  # noqa: E402
from rein.capabilities.testing.capability import (  # noqa: E402
    CONFIG_RELATIVE_PATH as TESTING_CONFIG_RELATIVE_PATH,
)
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402

_DEFAULT_POLICY_DIR = os.path.join(_PLUGIN_ROOT, "policies", "default")

_TESTING_YAML = (
    "testing:\n"
    "  commands:\n"
    "    - id: unit\n"
    '      run: "true"\n'
    "      tag: code\n"
)


def _init_git_repo(base_dir):
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
    with open(
        os.path.join(base_dir, ".gitignore"), "w", encoding="utf-8"
    ) as handle:
        handle.write(".rein/\ntrail/\n")
    subprocess.run(["git", "add", ".gitignore"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "gitignore"], cwd=base_dir, check=True
    )
    with open(os.path.join(base_dir, "a.py"), "w", encoding="utf-8") as handle:
        handle.write("print('hi')\n")
    subprocess.run(["git", "add", "a.py"], cwd=base_dir, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True)


def _bash_payload(command):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_codex_stamp(project_root, verdict="PASS", reviewed_at="2026-08-12T00:00:00Z", cycle="1"):
    dod_dir = _dod_dir(project_root)
    os.makedirs(dod_dir, exist_ok=True)
    with open(
        os.path.join(dod_dir, ".codex-reviewed"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "verdict: {}\nreviewed_at: {}\ncycle: {}\n".format(
                verdict, reviewed_at, cycle
            )
        )


def _write_testing_yaml(project_root):
    path = os.path.join(project_root, TESTING_CONFIG_RELATIVE_PATH)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(_TESTING_YAML)


def _write_authority_policy(project_root, switched_names=REQUIREMENT_NAMES):
    # Phase 7 결정 4(2026-08-19)로 배포 기본값이 5축→3축(code_review/
    # security_review/active_task)으로 좁혀져 tests_passed 는 기본
    # 미전환이 됐다. evaluator 의 "정책 단위 사전 필터"(rein/engine/
    # evaluator.py 모듈 docstring)는 한 policy 의 require 가 **전부**
    # 미전환이면 그 policy 를 when 조건조차 계산하지 않고 완전히
    # 건너뛴다 — push-testing.yaml 은 require 가 tests_passed 하나뿐
    # 이므로, 미전환 상태에서는 이 재현 테스트가 실제로 겨냥하는
    # 시나리오(testing.yaml 선언 + evidence 없음 → BLOCK)와 무관하게
    # 그 policy 자체가 "matched" 조차 되지 못해 ALLOW(no policy
    # matched)로 새어버린다(실측: opt-in 없이 실행하면 reason='no
    # policy matched event'). opt-in override 로 tests_passed 를 전환해
    # 옛 동작(push-testing.yaml 이 실제로 평가되어 evidence 부재를
    # BLOCK 으로 판정)을 재현한다 — 원 단언(테스트 목적인 testing.
    # configured 배선 자체)은 변경하지 않는다.
    policy_dir = os.path.join(project_root, ".rein", "policy")
    os.makedirs(policy_dir, exist_ok=True)
    with open(
        os.path.join(policy_dir, "authority.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "switched:\n"
            + "".join("  - {}\n".format(name) for name in switched_names)
        )


class TestingConfiguredMissingAllowsPushWithoutTestsTest(unittest.TestCase):
    """재현 + 수리 고정 — `.rein/policy/testing.yaml` 이 있어도 push-testing.yaml
    이 매칭되지 않으면 `tests_passed` 없이 `git push` 가 통과한다.

    이 픽스처는 활성 task(`_write_active_dod`)를 만들지 않으므로
    `task.exists` fact 가 "true" 가 아니다 — `push.yaml`(code_review
    하한선, `when: task.exists: "true"`)은 애초에 매칭되지 않고,
    `push-testing.yaml`(tests_passed, task.exists 조건 없음)만 매칭된다.
    즉 이 시나리오에서 code_review 는 처음부터 요구 축이 아니다 —
    `_write_codex_stamp()` 호출은 하위호환을 위해 남긴 inert fixture
    일 뿐 이 테스트의 통과/실패에 영향을 주지 않는다(Phase 7 웨이브 3
    ③-d 로 legacy marker dual-read 자체가 제거되며 그 사실이 더 이상
    우연이 아니라 구조적으로 자명해졌다 — code_review 가 요구됐더라도
    이 표식은 더 이상 읽히지 않는다). 수리 전에는 `testing.configured`
    fact 부재로 push-testing.yaml 자체가 매칭되지 않아 ALLOW 였다.
    수리 후에는 그 fact 가 "true" 로 채워져 push-testing.yaml 이
    매칭되고, `tests_passed` 가 missing_requirements 에 나타나 BLOCK
    이어야 한다.
    """

    def test_push_with_declared_testing_config_but_no_test_evidence_blocks(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_testing_yaml(project_root)
            _write_codex_stamp(project_root, verdict="PASS")
            _write_authority_policy(project_root)

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git push"))

        self.assertEqual(
            response["decision"],
            "BLOCK",
            msg="a project with a declared testing.yaml but zero test "
            "evidence must not be allowed to push just because code "
            "review evidence exists — testing.configured wiring is "
            "the bug under test: reason={!r} facts={!r}".format(
                response["reason"], response["facts"]
            ),
        )
        self.assertIn("tests_passed", response["missing_requirements"])
        self.assertEqual(response["facts"].get("testing.configured"), "true")

    def test_push_without_testing_yaml_is_not_gated_by_tests(self):
        """대조군 — testing.yaml 자체가 없으면(온보딩 마찰 방지) tests_passed 를
        요구하지 않는다(spec §5.2 확정 방향, 변경 없음을 확인).
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_codex_stamp(project_root, verdict="PASS")
            # testing.yaml 을 만들지 않는다.

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git push"))

        self.assertEqual(response["decision"], "ALLOW")
        self.assertNotIn("testing.configured", response["facts"])

    def test_push_with_test_evidence_present_allows(self):
        """testing.yaml 이 있고 tests_passed evidence 도 있으면 통과 — 과차단이 아님을 확인."""
        from rein.capabilities.testing.capability import (
            REQUIREMENT_NAME as TESTS_PASSED_NAME,
            observe_test_run,
        )
        from rein.platform.sqlite.store import LedgerVerifiedEvidenceSource
        from rein.platform.storage.local import LocalStateRoot
        from rein.engine import tags as tag_rules
        from rein.platform.git import facts as git_changeset_facts
        from rein.kernel.policy import load_policy_version

        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_testing_yaml(project_root)
            _write_codex_stamp(project_root, verdict="PASS")
            # 실제 uncommitted 코드 변경이 있어야 WORKTREE changeset 이
            # 비어 있지 않고 단일 tag("code")로 분류된다 — 빈 changeset
            # 은 changeset.tag fact 자체가 채워지지 않아(무의미) 이
            # 테스트의 목적(실제 evidence 로 tests_passed 충족)과
            # 무관한 이유로 BLOCK 될 수 있다.
            with open(
                os.path.join(project_root, "a.py"), "w", encoding="utf-8"
            ) as handle:
                handle.write("print('hi')\nprint('updated')\n")

            changeset = git_changeset_facts.worktree_changeset(cwd=project_root)
            rules = tag_rules.load_tag_rules()

            def _read_content(path):
                try:
                    with open(
                        os.path.join(project_root, path), "rb"
                    ) as handle:
                        return handle.read()
                except FileNotFoundError:
                    return None

            policy_version = load_policy_version(_DEFAULT_POLICY_DIR)
            from rein.capabilities.testing.capability import load_testing_config

            config = load_testing_config(
                os.path.join(project_root, TESTING_CONFIG_RELATIVE_PATH)
            )
            evidence = observe_test_run(
                "true",
                config,
                tag="code",
                paths=changeset.paths,
                read_content=_read_content,
                tag_rules=rules,
                policy_version=policy_version.version,
                cwd=project_root,
            )

            state_root = LocalStateRoot(project_root)
            evidence_source = LedgerVerifiedEvidenceSource(state_root)
            evidence_source.record_issued(TESTS_PASSED_NAME, evidence)

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git push"))

        self.assertEqual(
            response["decision"],
            "ALLOW",
            msg="real tests_passed evidence must satisfy the requirement "
            "once testing.configured is wired: reason={!r} "
            "missing={!r}".format(
                response["reason"], response.get("missing_requirements")
            ),
        )


if __name__ == "__main__":
    unittest.main()
