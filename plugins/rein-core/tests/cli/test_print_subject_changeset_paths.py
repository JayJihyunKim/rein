"""Axis 3 (m1) — `issue_evidence.print_subject()` 3-tuple 반환 계약, in-process.

covers: print-subject-returns-changeset-paths-from-the-same-worktree-changeset-instance

`tests/cli/test_issue_evidence_subcommand.py` 는 CLI 표면(subprocess 를
거친 JSON 직렬화)만 검증하는 관례라 이 함수 자체의 반환값 계약(3-tuple,
세 번째 원소가 subject 를 계산한 것과 **같은** `worktree_changeset()`
인스턴스에서 파생됐는지, git 호출 수가 늘지 않았는지)은 in-process 로
분리해 검증한다(설계 §7 "(m1) 함수 반환 계약").

헬퍼(`_init_git_repo`/`_write_code_change`/`_ENV_VARS_TO_CLEAR`)는
`test_issue_evidence_subcommand.py` 에서 import 하지 않고 이 파일 안에
그대로 복제한다 — 공유 헬퍼 모듈이 없어 discover 경로의 테스트 모듈들이
이미 같은 헬퍼를 각자 반복하는 저장소 관례를 따른다(plan Task 1.3 Step 1
참조).
"""
import os, subprocess, sys, tempfile, unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import issue_evidence               # noqa: E402
from rein.platform.git import facts as git_facts  # noqa: E402

_ENV_VARS_TO_CLEAR = ("REIN_POLICY_DIR", "REIN_PROJECT_ROOT", "REIN_DB_PATH")


def _init_git_repo(base_dir):
    """test_issue_evidence_subcommand.py 와 동일 본문 (관례상 복제)."""
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"],
        cwd=base_dir,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "t"], cwd=base_dir, check=True
    )
    with open(
        os.path.join(base_dir, ".gitignore"), "w", encoding="utf-8"
    ) as handle:
        handle.write(".rein/\n")
    subprocess.run(["git", "add", ".gitignore"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "gitignore"], cwd=base_dir, check=True
    )
    with open(os.path.join(base_dir, "a.py"), "w", encoding="utf-8") as handle:
        handle.write("print('hi')\n")
    subprocess.run(["git", "add", "a.py"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True
    )


def _write_code_change(project_root, content="print('changed')\n"):
    """동일 본문 복제."""
    with open(
        os.path.join(project_root, "a.py"), "w", encoding="utf-8"
    ) as handle:
        handle.write(content)


def _write_note(project_root):
    with open(
        os.path.join(project_root, "notes.md"), "w", encoding="utf-8"
    ) as handle:
        handle.write("note\n")


def _in_process_env(project_root):
    env = {
        k: v for k, v in os.environ.items() if k not in _ENV_VARS_TO_CLEAR
    }
    env["REIN_PROJECT_ROOT"] = project_root
    return mock.patch.dict(os.environ, env, clear=True)


class PrintSubjectReturnsChangesetPathsTest(unittest.TestCase):
    def test_sentinel_case_third_element_is_full_changeset_paths(self):
        with tempfile.TemporaryDirectory() as root:
            _init_git_repo(root)
            _write_note(root)
            with _in_process_env(root):
                result = issue_evidence.print_subject("code_review")
                expected = git_facts.worktree_changeset(cwd=root).paths
        self.assertEqual(len(result), 3)
        subject, paths, changeset_paths = result
        self.assertEqual(subject, "empty:no-subject")
        self.assertEqual(tuple(paths), ())
        self.assertEqual(
            tuple(changeset_paths), tuple(expected)
        )  # ("notes.md",) — 허용목록 적용 전

    def test_digest_case_third_element_is_full_changeset_paths(self):
        with tempfile.TemporaryDirectory() as root:
            _init_git_repo(root)
            _write_code_change(root)  # a.py 미커밋 편집 (허용목록 밖)
            _write_note(root)  # notes.md 미추적 (허용목록 안)
            with _in_process_env(root):
                subject, paths, changeset_paths = issue_evidence.print_subject(
                    "code_review"
                )
                expected = git_facts.worktree_changeset(cwd=root).paths
        self.assertTrue(subject.startswith("sha256:"), subject)
        self.assertEqual(
            tuple(paths), ("a.py",)
        )  # 인증 경로 = 허용목록 밖만
        self.assertEqual(
            sorted(changeset_paths), ["a.py", "notes.md"]
        )  # 전체 = 허용목록 적용 전
        self.assertEqual(
            tuple(changeset_paths), tuple(expected)
        )  # 같은 관측의 ChangeSet.paths 그대로
        self.assertTrue(set(paths) <= set(changeset_paths))

    def test_security_review_third_element_is_none(self):
        with tempfile.TemporaryDirectory() as root:
            _init_git_repo(
                root
            )  # clean tree, 프로젝트 정책 없음 → 번들 기본(sensitive) 프로필
            with _in_process_env(root):
                result = issue_evidence.print_subject("security_review")
        self.assertEqual(len(result), 3)
        subject, paths, changeset_paths = result
        self.assertEqual(subject, "empty:no-subject")
        self.assertEqual(tuple(paths), ())
        self.assertIsNone(changeset_paths)

    def test_code_review_git_call_count_unchanged(self):
        real = git_facts._run_git
        with tempfile.TemporaryDirectory() as root:
            _init_git_repo(root)
            _write_code_change(root)
            with _in_process_env(root):
                with mock.patch.object(
                    git_facts, "_run_git", side_effect=real
                ) as spy:
                    issue_evidence.print_subject("code_review")
                    via_print_subject = spy.call_count
                with mock.patch.object(
                    git_facts, "_run_git", side_effect=real
                ) as spy:
                    issue_evidence._resolve_project_root()
                    cs = git_facts.worktree_changeset(cwd=root)
                    git_facts.review_digest(cs, cwd=root)
                    git_facts.review_subject_paths(cs)
                    baseline = spy.call_count
        self.assertEqual(via_print_subject, baseline)


if __name__ == "__main__":
    unittest.main()
