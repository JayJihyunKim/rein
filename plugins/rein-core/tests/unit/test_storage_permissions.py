"""plan Task 2.5 — 로컬 전용 저장 권한 + 비추적 계약 (spec §2.3, §3.8).

covers: local-runtime-storage-stays-untracked-and-new-files-created-mode-0600

Runtime State 는 Git 으로 동기화하지 않는다 (spec §2.3): state 루트는
사용자 프로젝트 `.rein/state/` 이며 이 repo 의 `.gitignore` 가 이미
`/.rein/state/` 패턴으로 비추적을 보장한다 — 그 사실을 테스트로 고정한다
(.gitignore 는 읽기 전용). 신규 생성되는 로그·ledger·db 파일은 0600,
state 디렉토리는 0700 이어야 한다. 모든 파일 생성은 temp 디렉토리에서만
수행한다.
"""
import os
import shutil
import stat
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

_REPO_ROOT = os.path.dirname(os.path.dirname(_PLUGIN_ROOT))

from rein.platform.sqlite import store as sqlite_store  # noqa: E402
from rein.platform.storage import local  # noqa: E402


def _mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


@unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약 (spec 대상 플랫폼)")
class PrivateFileModeTest(unittest.TestCase):
    """spec §3.8 — 신규 생성 로그·ledger·db 파일 stat 0600."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = local.LocalStateRoot(tmp.name)
        # 관대한 umask 아래에서도 0600 이 코드로 강제되는지 확인
        previous_umask = os.umask(0o000)
        self.addCleanup(os.umask, previous_umask)

    def test_new_db_file_is_0600(self):
        self.root.ensure()
        db_path = self.root.database_path()
        store = sqlite_store.SqliteStore.open(db_path)
        try:
            store.put(sqlite_store.SECTION_RUNTIME_STATE, "k", "v")
            self.assertEqual(_mode(db_path), 0o600)
            # WAL sidecar 가 생겼다면 group/other 접근 불가여야 한다
            for suffix in ("-wal", "-shm", "-journal"):
                sidecar = db_path + suffix
                if os.path.exists(sidecar):
                    self.assertEqual(
                        _mode(sidecar) & 0o077, 0, msg=sidecar
                    )
        finally:
            store.close()

    def test_new_ledger_file_is_0600(self):
        with self.root.open_ledger() as handle:
            handle.write("entry\n")
        self.assertEqual(_mode(self.root.ledger_path()), 0o600)

    def test_new_log_file_is_0600(self):
        with self.root.open_log("gate.log") as handle:
            handle.write("line\n")
        self.assertEqual(_mode(self.root.log_path("gate.log")), 0o600)

    def test_state_dir_is_0700(self):
        state_dir = self.root.ensure()
        self.assertEqual(_mode(state_dir), 0o700)

    def test_create_private_file_leaves_existing_files_alone(self):
        # 계약은 "신규 생성" 파일에만 적용된다 — 기존 파일 권한 불변
        self.root.ensure()
        path = self.root.log_path("existing.log")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("old\n")
        os.chmod(path, 0o644)
        created = local.create_private_file(path)
        self.assertFalse(created)
        self.assertEqual(_mode(path), 0o644)


@unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
@unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
class SymlinkGuardTest(unittest.TestCase):
    """Low 보안 시정 — 미리 심어진 심볼릭 링크는 append 를 거부한다.

    covers: local-runtime-storage-append-rejects-preplanted-symlink

    `create_private_file` 의 O_CREAT|O_EXCL 는 "파일이 아예 없던" 최초
    생성 경로를 이미 보호한다(대상이 심링크면 EEXIST). 이 테스트는 그
    다음 단계 — 파일(또는 로컬 공격자의 심링크)이 이미 존재하는 상태에서
    `open_private_append` 가 O_NOFOLLOW 로 링크를 거부하는지 고정한다.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = local.LocalStateRoot(tmp.name)
        self.root.ensure()
        self.outside_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.outside_dir, ignore_errors=True)

    def test_open_private_append_rejects_preplanted_symlink(self):
        outside_target = os.path.join(self.outside_dir, "outside.log")
        log_path = self.root.log_path("gate.log")
        os.symlink(outside_target, log_path)

        with self.assertRaises(OSError):
            local.open_private_append(log_path)

        # 링크를 따라가 대상에 쓰지 않았어야 한다
        self.assertFalse(os.path.exists(outside_target))
        # 링크 자체도 (append 시도로) 내용이 생기지 않는다
        self.assertTrue(os.path.islink(log_path))

    def test_open_ledger_rejects_preplanted_symlink(self):
        outside_target = os.path.join(self.outside_dir, "outside.jsonl")
        os.symlink(outside_target, self.root.ledger_path())

        with self.assertRaises(OSError):
            self.root.open_ledger()

        self.assertFalse(os.path.exists(outside_target))

    def test_open_log_rejects_preplanted_symlink(self):
        outside_target = os.path.join(self.outside_dir, "outside.log")
        os.symlink(outside_target, self.root.log_path("audit.log"))

        with self.assertRaises(OSError):
            self.root.open_log("audit.log")

        self.assertFalse(os.path.exists(outside_target))

    def test_open_private_append_still_works_for_regular_existing_file(self):
        # O_NOFOLLOW 추가가 정상 append 재사용 경로를 깨지 않아야 한다
        path = self.root.log_path("plain.log")
        with local.open_private_append(path) as handle:
            handle.write("first\n")
        with local.open_private_append(path) as handle:
            handle.write("second\n")
        with open(path, "r", encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "first\nsecond\n")


@unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
@unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
class SqliteStoreSymlinkGuardTest(unittest.TestCase):
    """Phase 6 마무리 수리 워커 H — `SqliteStore.open` 이 기존 경로를
    확인하지 않고 `sqlite3.connect` 로 그대로 넘겨, 미리 심어둔 심볼릭
    링크를 따라가 캐시 쓰기를 외부 파일에 하던 결함의 회귀 방지.

    `platform.storage.approval_store.ApprovalConsumptionStore.open` 이
    승인 소비 원장에 이미 적용한 것과 동일한 방어(`os.lstat` +
    `stat.S_ISREG`)를 이 store(5-section 캐시)에도 적용한다 — 직전
    수리 워커가 자기 scope 밖이라 보고만 하고 넘긴 항목. 이 store 는
    재구축 가능한 캐시라(spec §3.8) 승인 소비 원장(one-shot 계약,
    지우면 승인이 되살아남)보다 위험도는 낮지만, 같은 결함 클래스
    (심볼릭 링크를 그대로 따라가는 SQLite 파일 열기)이므로 같은 방어를
    고정한다 — `tests/unit/test_approval_consumption_store.py::
    SymlinkGuardTest` 와 동일 패턴.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp_dir = tmp.name
        self.outside_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.outside_dir, ignore_errors=True)

    def test_open_rejects_preplanted_symlink(self):
        outside_target = os.path.join(self.outside_dir, "outside.sqlite3")
        db_path = os.path.join(self.tmp_dir, "runtime.sqlite3")
        os.symlink(outside_target, db_path)

        with self.assertRaises(OSError):
            sqlite_store.SqliteStore.open(db_path)

        # 링크를 따라가 대상에 쓰지 않았어야 한다 (캐시 쓰기가 외부로
        # 새지 않는다)
        self.assertFalse(os.path.exists(outside_target))
        self.assertTrue(os.path.islink(db_path))

    def test_open_still_works_for_regular_existing_db(self):
        # 가드가 정상적인 재오픈(프로세스 재시작 시나리오)까지 막지
        # 않아야 한다.
        db_path = os.path.join(self.tmp_dir, "runtime.sqlite3")
        first = sqlite_store.SqliteStore.open(db_path)
        first.put(sqlite_store.SECTION_RUNTIME_STATE, "k", "v")
        first.close()

        second = sqlite_store.SqliteStore.open(db_path)
        try:
            self.assertEqual(
                second.get(sqlite_store.SECTION_RUNTIME_STATE, "k"), "v"
            )
        finally:
            second.close()

    def test_open_or_rebuild_does_not_silently_rebuild_through_symlink(self):
        # `open_or_rebuild` 는 sqlite3.DatabaseError 만 "손상 → 재구축"
        # 으로 처리한다 — 심볼릭 링크 거부는 OSError(비 DatabaseError)라
        # 조용히 재구축(=링크 대상을 지우고 새로 만듦)으로 흡수되지 않고
        # 그대로 전파돼야 한다(fail-closed 유지, 공격 경로를 자동으로
        # "복구"하지 않는다).
        outside_target = os.path.join(self.outside_dir, "outside.sqlite3")
        db_path = os.path.join(self.tmp_dir, "runtime.sqlite3")
        os.symlink(outside_target, db_path)

        with self.assertRaises(OSError):
            sqlite_store.SqliteStore.open_or_rebuild(db_path)

        self.assertTrue(os.path.islink(db_path))
        self.assertFalse(os.path.exists(outside_target))


def _patched_lstat_raising_at(target_path, error):
    """`os.lstat` 을 감싸 `target_path` 호출에서만 지정한 예외를 던진다.

    `tests/unit/test_approval_consumption_store.py` 의 동명 헬퍼와 동일
    패턴 — 승인 소비 원장 쪽 오류 분류 테스트와 이 캐시 저장소 함수
    자체의 오류 분류 테스트가 같은 검증 방식을 공유하게 한다.
    """
    original = os.lstat

    def _faulty(path, *args, **kwargs):
        if path == target_path:
            raise error
        return original(path, *args, **kwargs)

    return _faulty


@unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
class SqliteStoreErrorClassificationTest(unittest.TestCase):
    """`_reject_symlink_or_special` 오류 분류 회귀 방지 — Phase 6 5회차
    재리뷰 Medium.

    수리 전에는 `except OSError:` 로 lstat 실패를 전부 "아직 없음"으로
    흡수했다 — 이 저장소의 다른 세 lstat 판정 지점
    (`platform.storage.approval_store._reject_symlink_or_special`,
    `cli.__init__._open_approval_consumption_store`,
    `engine.authority` 의 전환 정책 로더)은 이미 `FileNotFoundError`
    (정말 없음)만 부재로 흡수하고 그 외 `OSError`(권한 거부 등 접근
    불가)는 전파하도록 좁혀져 있었다 — 이 캐시 저장소만 시정에서
    빠져 있었다. "접근 불가"를 "부재"로 흡수하면 판단 재료를 확보하지
    못한 상태가 조용히 "새로 만들면 된다"로 통과하는 fail-open 이
    된다(`tests/unit/test_approval_consumption_store.py::
    RejectSymlinkOrSpecialErrorClassificationTest` 와 동일 패턴).
    """

    def test_file_not_found_is_treated_as_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            # 부모 디렉터리조차 없다 — lstat 는 FileNotFoundError. 예외
            # 없이 그냥 반환해야 한다(다음 open_store 호출이 새로 만든다).
            db_path = os.path.join(tmp, "nested", "runtime.sqlite3")
            sqlite_store._reject_symlink_or_special(db_path)  # no raise

    def test_permission_error_during_lstat_propagates_not_absorbed(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "runtime.sqlite3")
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(
                    PermissionError,
                    msg="a PermissionError while lstat-ing the db path "
                    "must not be silently absorbed as 'file absent' — "
                    "that would let an inaccessible cache path pass "
                    "through as if nothing had ever been cached there",
                ):
                    sqlite_store._reject_symlink_or_special(db_path)

    def test_open_propagates_permission_error_from_reject_check(self):
        # end-to-end: `SqliteStore.open()` 이 이 lstat 판정을 거치므로,
        # 판정에서 propagate 된 PermissionError 가 `open()` 밖으로도
        # 그대로 나가야 한다(조용히 삼켜 새 db 를 여는 방향으로 새지
        # 않는다).
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "runtime.sqlite3")
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(PermissionError):
                    sqlite_store.SqliteStore.open(db_path)


@unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
@unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
class StateDirSymlinkGuardTest(unittest.TestCase):
    """Task 6.1 선행1 코드 리뷰 Medium 4 — `.rein/state` 자체가 미리 심어진
    심볼릭 링크면 `LocalStateRoot.ensure()` 가 거부한다.

    수리 전에는 `os.makedirs(exist_ok=True)` 가 심볼릭 링크를 그대로
    "이미 존재하는 디렉토리"로 인정해 통과하고, 뒤이은 `os.chmod` 는
    기본적으로 링크를 따라가 링크 타깃(외부 디렉토리)을 0700 으로
    chmod 했다 — 이후 이 루트 밑에서 열리는 모든 ledger/evidence/db/log
    파일이 실제로는 프로젝트 밖 디렉토리에 쓰였다(리뷰어 실측 재현).
    `platform.storage.approval_store._reject_symlink_or_special`/
    `platform.sqlite.store._reject_symlink_or_special` 와 동일한
    lstat + stat.S_IS* 패턴을 디렉토리에 적용해 고정한다.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.project_root = tmp.name
        self.outside_dir = tempfile.mkdtemp()
        os.chmod(self.outside_dir, 0o755)
        self.addCleanup(shutil.rmtree, self.outside_dir, ignore_errors=True)

    def test_ensure_rejects_preplanted_state_dir_symlink(self):
        root = local.LocalStateRoot(self.project_root)
        os.makedirs(os.path.dirname(root.state_dir), exist_ok=True)
        os.symlink(self.outside_dir, root.state_dir)

        with self.assertRaises(OSError):
            root.ensure()

        # 링크를 따라가 외부 디렉토리를 chmod 하지 않았어야 한다 — 여전히
        # setUp 에서 지정한 0755 여야 한다(0700 으로 바뀌었다면 링크를
        # 따라간 것).
        self.assertEqual(
            stat.S_IMODE(os.stat(self.outside_dir).st_mode), 0o755
        )
        # 링크 자체도 그대로 남아 있어야 한다 (교체/삭제되지 않음).
        self.assertTrue(os.path.islink(root.state_dir))

    def test_ensure_still_works_for_regular_existing_state_dir(self):
        # 가드가 정상 재사용(프로세스 재시작 시나리오)까지 막지 않아야 한다
        root = local.LocalStateRoot(self.project_root)
        first = root.ensure()
        second = root.ensure()
        self.assertEqual(first, second)
        self.assertEqual(_mode(root.state_dir), 0o700)


class LocalOnlyPathTest(unittest.TestCase):
    """spec §2.3 — state 경로는 프로젝트 루트 밑 고정, 탈출 금지."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp_name = tmp.name
        self.root = local.LocalStateRoot(tmp.name)

    def test_state_dir_is_under_project_root(self):
        expected = os.path.join(
            os.path.abspath(self.tmp_name), ".rein", "state"
        )
        self.assertEqual(self.root.state_dir, expected)

    def test_log_name_rejects_path_separators(self):
        for bad_name in ("../escape.log", "a/b.log", "", ".", ".."):
            with self.assertRaises(ValueError, msg=repr(bad_name)):
                self.root.log_path(bad_name)

    def test_ensure_does_not_touch_shared_rein_dir_mode(self):
        # `.rein/` 부모는 공유 디렉토리(project.json ship 대상) —
        # ensure 는 state/ 만 0700 으로 만들고 부모 권한은 건드리지 않는다
        rein_dir = os.path.join(os.path.abspath(self.tmp_name), ".rein")
        os.mkdir(rein_dir, 0o755)
        before = _mode(rein_dir)
        self.root.ensure()
        self.assertEqual(_mode(rein_dir), before)


class UntrackedContractTest(unittest.TestCase):
    """spec §2.3 — 기본 state 경로가 이 repo 의 gitignore 패턴에 포함."""

    def test_gitignore_pattern_matches_declared_state_root(self):
        expected = "/{}/".format(
            local.STATE_DIR_RELATIVE.replace(os.sep, "/")
        )
        self.assertEqual(local.GITIGNORE_PATTERN, expected)

    def test_repo_gitignore_contains_state_pattern(self):
        gitignore_path = os.path.join(_REPO_ROOT, ".gitignore")
        with open(gitignore_path, "r", encoding="utf-8") as handle:
            lines = [line.strip() for line in handle]
        self.assertIn(local.GITIGNORE_PATTERN, lines)

    def test_git_reports_state_path_as_ignored(self):
        if shutil.which("git") is None:
            self.skipTest("git 비가용 환경")
        if not os.path.isdir(os.path.join(_REPO_ROOT, ".git")):
            self.skipTest("git repo 밖 실행 (배포 트리 등)")
        probe = os.path.join(
            local.STATE_DIR_RELATIVE.replace(os.sep, "/"), "probe.db"
        )
        completed = subprocess.run(
            ["git", "check-ignore", "-q", "--", probe],
            cwd=_REPO_ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # 0 = ignored, 1 = not ignored — 비추적 계약의 행위 검증
        self.assertEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main()
