"""plan Task 2.1 — ChangeSet + 내용 기반 digest 테스트 (spec §3.3).

고정하는 계약:
- Digest 는 내용 기반 — 동일 내용 재계산은 동일값, mtime 변경(touch)은
  digest 를 바꾸지 못하고, 1바이트 수정은 digest 를 바꾼다 (v1 게이트
  freshness 교훈의 계약화: content 기준 > 시각 기준).
- kernel 은 git 을 모른다 — 내용은 주입된 read_content 공급자가 준다.
- platform/git/facts 가 WORKTREE/STAGED 해석을 담당하고, STAGED digest
  는 index 내용 기준이다 (worktree 후속 편집·touch 에 불변).
"""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

# self-locating sys.path 주입 — discover top-level 이 tests/unit 이어도
# plugin root 의 rein 패키지를 import 할 수 있게 한다 (관례 계승).
_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel.changeset import (  # noqa: E402
    SCOPE_COMMIT,
    SCOPE_STAGED,
    SCOPE_TASK,
    SCOPE_WORKTREE,
    SCOPES,
    ChangeSet,
    changeset_digest,
    content_digest,
)
from rein.platform.git import facts  # noqa: E402


def _dict_reader(mapping):
    """kernel 주입 계약 그대로의 최소 공급자 — path -> bytes | None."""

    def read_content(path):
        return mapping.get(path)

    return read_content


def _fs_reader(base):
    """파일시스템 공급자 — mtime 을 전혀 보지 않는다 (내용만 읽음)."""

    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


class ChangeSetModelTest(unittest.TestCase):
    """spec §3.3 — Scope 4종 폐쇄 집합 + 경로 정규화."""

    def test_scope_closed_set_is_spec_3_3(self):
        self.assertEqual(
            SCOPES,
            (SCOPE_WORKTREE, SCOPE_STAGED, SCOPE_COMMIT, SCOPE_TASK),
        )

    def test_unknown_scope_is_rejected(self):
        with self.assertRaises(ValueError):
            ChangeSet(scope="BRANCH", paths=("a.txt",))

    def test_paths_are_sorted_and_deduplicated(self):
        changeset = ChangeSet(
            scope=SCOPE_WORKTREE, paths=["b.txt", "a.txt", "b.txt"]
        )
        self.assertEqual(changeset.paths, ("a.txt", "b.txt"))

    def test_empty_or_non_string_path_is_rejected(self):
        with self.assertRaises(ValueError):
            ChangeSet(scope=SCOPE_WORKTREE, paths=("",))
        with self.assertRaises(ValueError):
            ChangeSet(scope=SCOPE_WORKTREE, paths=(b"a.txt",))


class ContentDigestPurityTest(unittest.TestCase):
    """내용 기반 digest 의 순수 계산 계약 — 파일시스템 비의존."""

    def test_same_content_recomputes_to_same_value(self):
        reader = _dict_reader({"a.txt": b"alpha\n", "b.txt": b"beta\n"})
        first = content_digest(("a.txt", "b.txt"), reader)
        second = content_digest(("a.txt", "b.txt"), reader)
        self.assertEqual(first, second)

    def test_path_order_does_not_change_digest(self):
        reader = _dict_reader({"a.txt": b"alpha\n", "b.txt": b"beta\n"})
        self.assertEqual(
            content_digest(("a.txt", "b.txt"), reader),
            content_digest(("b.txt", "a.txt"), reader),
        )

    def test_single_byte_change_changes_digest(self):
        before = content_digest(("a.txt",), _dict_reader({"a.txt": b"alpha"}))
        after = content_digest(("a.txt",), _dict_reader({"a.txt": b"alphb"}))
        self.assertNotEqual(before, after)

    def test_absent_and_empty_content_are_distinct(self):
        # 삭제된 파일(None)과 빈 파일(b"")은 다른 상태다 — 같은 digest 면
        # "삭제를 빈 파일로 되돌린" 변경이 만료를 비켜간다
        absent = content_digest(("a.txt",), _dict_reader({}))
        empty = content_digest(("a.txt",), _dict_reader({"a.txt": b""}))
        self.assertNotEqual(absent, empty)

    def test_path_identity_is_bound_into_digest(self):
        # 동일 내용이라도 다른 경로면 다른 ChangeSet 이다
        left = content_digest(("a.txt",), _dict_reader({"a.txt": b"same"}))
        right = content_digest(("b.txt",), _dict_reader({"b.txt": b"same"}))
        self.assertNotEqual(left, right)

    def test_framing_prevents_concatenation_collision(self):
        # 길이 프리픽스 프레이밍 부재 시 "ab"+"c" 와 "a"+"bc" 가 충돌한다
        left = content_digest(("ab",), _dict_reader({"ab": b"c"}))
        right = content_digest(("a",), _dict_reader({"a": b"bc"}))
        self.assertNotEqual(left, right)

    def test_non_bytes_content_is_rejected(self):
        with self.assertRaises(TypeError):
            content_digest(("a.txt",), _dict_reader({"a.txt": "text"}))

    def test_changeset_digest_delegates_to_normalized_paths(self):
        reader = _dict_reader({"a.txt": b"alpha", "b.txt": b"beta"})
        changeset = ChangeSet(
            scope=SCOPE_STAGED, paths=("b.txt", "a.txt", "a.txt")
        )
        self.assertEqual(
            changeset_digest(changeset, reader),
            content_digest(("a.txt", "b.txt"), reader),
        )


class FilesystemMtimeIndependenceTest(unittest.TestCase):
    """plan Task 2.1 (a) — 실제 파일에서 touch 불변·1바이트 변화."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "mod.py")
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")

    def test_recompute_touch_and_one_byte_edit(self):
        reader = _fs_reader(self.base)
        first = content_digest(("mod.py",), reader)

        # 동일 내용 재계산 — 동일값
        self.assertEqual(content_digest(("mod.py",), reader), first)

        # touch (mtime 변경) — digest 불변 (mtime 은 validity 근거 금지)
        stat = os.stat(self.path)
        os.utime(self.path, (stat.st_atime + 3600, stat.st_mtime + 3600))
        self.assertEqual(content_digest(("mod.py",), reader), first)

        # 1바이트 수정 — digest 변화
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")
        self.assertNotEqual(content_digest(("mod.py",), reader), first)


@unittest.skipIf(shutil.which("git") is None, "git 실행파일 부재")
class GitFactsTest(unittest.TestCase):
    """platform/git/facts — WORKTREE/STAGED 해석 + 내용 기반 결합."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = tmp.name
        self._git("init", "-q")
        self._git("config", "user.email", "rein-test@example.invalid")
        self._git("config", "user.name", "rein-test")
        self._write("tracked.txt", b"base\n")
        self._git("add", "tracked.txt")
        self._git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")

    def _git(self, *args):
        subprocess.run(
            ("git",) + args,
            cwd=self.repo,
            check=True,
            capture_output=True,
            timeout=30,
        )

    def _write(self, name, data):
        with open(os.path.join(self.repo, name), "wb") as handle:
            handle.write(data)

    def test_worktree_changeset_lists_modified_and_untracked(self):
        self._write("tracked.txt", b"changed\n")
        self._write("untracked.txt", b"new\n")
        changeset = facts.worktree_changeset(cwd=self.repo)
        self.assertIsNotNone(changeset)
        self.assertEqual(changeset.scope, SCOPE_WORKTREE)
        self.assertEqual(changeset.paths, ("tracked.txt", "untracked.txt"))

    def test_worktree_digest_ignores_touch_but_not_content(self):
        self._write("tracked.txt", b"changed\n")
        changeset = facts.worktree_changeset(cwd=self.repo)
        first = facts.changeset_digest(changeset, cwd=self.repo)
        self.assertIsNotNone(first)

        # touch — 내용 불변이면 digest 불변
        path = os.path.join(self.repo, "tracked.txt")
        stat = os.stat(path)
        os.utime(path, (stat.st_atime + 3600, stat.st_mtime + 3600))
        self.assertEqual(
            facts.changeset_digest(
                facts.worktree_changeset(cwd=self.repo), cwd=self.repo
            ),
            first,
        )

        # 1바이트 수정 — digest 변화
        self._write("tracked.txt", b"changed!\n")
        self.assertNotEqual(
            facts.changeset_digest(
                facts.worktree_changeset(cwd=self.repo), cwd=self.repo
            ),
            first,
        )

    def test_staged_digest_tracks_index_not_worktree(self):
        self._write("tracked.txt", b"staged\n")
        self._git("add", "tracked.txt")
        staged = facts.staged_changeset(cwd=self.repo)
        self.assertIsNotNone(staged)
        self.assertEqual(staged.scope, SCOPE_STAGED)
        self.assertEqual(staged.paths, ("tracked.txt",))
        first = facts.changeset_digest(staged, cwd=self.repo)
        self.assertIsNotNone(first)

        # worktree 후속 편집 — index 내용이 그대로면 STAGED digest 불변
        self._write("tracked.txt", b"worktree-after\n")
        self.assertEqual(
            facts.changeset_digest(
                facts.staged_changeset(cwd=self.repo), cwd=self.repo
            ),
            first,
        )

        # 같은 경로 집합이라도 WORKTREE digest 는 worktree 내용을 본다
        worktree = facts.worktree_changeset(cwd=self.repo)
        self.assertEqual(worktree.paths, staged.paths)
        self.assertNotEqual(
            facts.changeset_digest(worktree, cwd=self.repo), first
        )

    def test_clean_tree_yields_empty_changesets(self):
        self.assertEqual(facts.worktree_changeset(cwd=self.repo).paths, ())
        self.assertEqual(facts.staged_changeset(cwd=self.repo).paths, ())

    def test_outside_repo_resolves_to_none(self):
        # repo 부재는 fact 의 부재일 뿐 예외가 아니다 (current_branch 관례)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        outside = tmp.name
        self.assertIsNone(facts.worktree_changeset(cwd=outside))
        self.assertIsNone(facts.staged_changeset(cwd=outside))
        changeset = ChangeSet(scope=SCOPE_WORKTREE, paths=("a.txt",))
        self.assertIsNone(facts.changeset_digest(changeset, cwd=outside))

    def test_unsupported_scope_digest_is_none(self):
        # v2.0 enforcement scope 는 WORKTREE/STAGED — 그 밖은 fact 부재
        changeset = ChangeSet(scope=SCOPE_COMMIT, paths=("tracked.txt",))
        self.assertIsNone(facts.changeset_digest(changeset, cwd=self.repo))

    def test_worktree_reader_raises_on_oversized_file_not_silent_truncate(
        self,
    ):
        # Medium 보안 시정 — 대용량 파일은 조용히 잘라 digest 를 내지
        # 않고 명시 에러로 실패한다 (절단은 서로 다른 내용을 같은
        # digest 로 만들 수 있어 근거 만료 계약을 깬다).
        self._write("tracked.txt", b"x" * 5000)
        reader = facts.worktree_content_reader(cwd=self.repo, max_bytes=10)
        with self.assertRaises(facts.ContentSizeExceededError):
            reader("tracked.txt")

    def test_worktree_reader_exact_cap_boundary_succeeds(self):
        # 상한과 정확히 같은 크기는 초과가 아니다 (경계값)
        self._write("tracked.txt", b"y" * 10)
        reader = facts.worktree_content_reader(cwd=self.repo, max_bytes=10)
        self.assertEqual(reader("tracked.txt"), b"y" * 10)

    def test_staged_reader_raises_on_oversized_blob_not_silent_truncate(
        self,
    ):
        self._write("tracked.txt", b"z" * 5000)
        self._git("add", "tracked.txt")
        reader = facts.staged_content_reader(cwd=self.repo, max_bytes=10)
        with self.assertRaises(facts.ContentSizeExceededError):
            reader("tracked.txt")

    def test_staged_reader_exact_cap_boundary_succeeds(self):
        self._write("tracked.txt", b"w" * 10)
        self._git("add", "tracked.txt")
        reader = facts.staged_content_reader(cwd=self.repo, max_bytes=10)
        self.assertEqual(reader("tracked.txt"), b"w" * 10)

    def test_changeset_digest_propagates_size_cap_error(self):
        # kernel content_digest 를 통해서도 상한 초과가 그대로 전파된다
        # (부재로 조용히 흡수되지 않음)
        self._write("tracked.txt", b"v" * 5000)
        changeset = facts.worktree_changeset(cwd=self.repo)
        with self.assertRaises(facts.ContentSizeExceededError):
            facts.changeset_digest(changeset, cwd=self.repo, max_bytes=10)

    @unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
    def test_worktree_reader_does_not_follow_symlink_outside_repo(self):
        # 보안 리뷰 참고 항목 — repo 밖을 가리키는 심링크를 follow 하면
        # digest 에 repo 밖 내용이 섞인다. git 의 심링크 blob 의미론과
        # 같이 타깃 경로 문자열만 해싱해야 한다.
        outside_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, outside_dir, ignore_errors=True)
        outside_file = os.path.join(outside_dir, "secret.txt")
        with open(outside_file, "wb") as handle:
            handle.write(b"outside-repo-content\n")
        link_path = os.path.join(self.repo, "link.txt")
        os.symlink(outside_file, link_path)

        reader = facts.worktree_content_reader(cwd=self.repo)
        content = reader("link.txt")
        self.assertIsNotNone(content)
        self.assertNotIn(b"outside-repo-content", content)
        self.assertEqual(content, os.fsencode(outside_file))

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "mkfifo"),
        "FIFO(mkfifo) 는 POSIX 전용",
    )
    def test_worktree_reader_does_not_block_on_fifo(self):
        # 재리뷰 시정 — 심링크를 거치지 않고 작업 트리에 FIFO(named
        # pipe)가 직접 놓이면 islink() 는 False 라 그대로 open() 에
        # 진입한다. writer 없는 FIFO 의 open 은 무기한 블로킹돼 위
        # "심볼릭 링크" 절의 DoS 가 그대로 재발한다 — reader 는 open
        # 이전에 파일 종류를 확인해 즉시 반환해야 한다.
        #
        # 스레드 + join(timeout) 으로 감지한다: 블로킹이 재발해도 이
        # 테스트 프로세스 자체가 무기한 멈추지 않도록(백그라운드 스레드는
        # daemon 이라 프로세스 종료를 막지 않는다), join 이 timeout 안에
        # 끝나지 않으면 "블로킹 발생"으로 판정해 실패시킨다.
        fifo_path = os.path.join(self.repo, "pipe.fifo")
        os.mkfifo(fifo_path)

        reader = facts.worktree_content_reader(cwd=self.repo)
        result = {}

        def call_reader():
            result["value"] = reader("pipe.fifo")
            result["done"] = True

        thread = threading.Thread(target=call_reader, daemon=True)
        thread.start()
        thread.join(timeout=3)

        self.assertFalse(
            thread.is_alive(),
            "worktree reader blocked on FIFO open() — writer 없는 FIFO 는 "
            "무기한 대기하므로 open 이전에 파일 종류를 확인해야 한다",
        )
        self.assertTrue(result.get("done"))
        self.assertIsNone(result.get("value"))


if __name__ == "__main__":
    unittest.main()
