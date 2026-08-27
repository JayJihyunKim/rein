"""platform.storage.approval_store.ApprovalConsumptionStore — user_approval
one-shot 소비 저장 프로토콜의 실제 구현체 (v2 Phase 6 worker D — spec
§3.6 §21, plan Task 4.5).

`rein.capabilities.approval.capability` 가 요구하는 duck-typed 프로토콜
(`is_consumed(fingerprint) -> bool`, `claim(fingerprint) -> bool` 원자적
check-and-set, `release(fingerprint) -> Any` best-effort 롤백)의 sqlite
기반 구현체를 검증한다. capability 모듈 자신은 이 클래스를 전혀 모른다
(import 하지 않는다) — 이 테스트가 "실제 구현이 그 계약을 만족하는가"를
고정한다.
"""
import os
import shutil
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.platform.storage import approval_store  # noqa: E402
from rein.platform.storage.local import LocalStateRoot  # noqa: E402


def _mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class BasicProtocolTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_path = os.path.join(tmp.name, "approval-consumption.sqlite3")
        self.store = approval_store.ApprovalConsumptionStore.open(
            self.db_path
        )
        self.addCleanup(self.store.close)

    def test_fresh_fingerprint_is_not_consumed(self):
        self.assertFalse(self.store.is_consumed("fp-1"))

    def test_claim_succeeds_and_marks_consumed(self):
        self.assertTrue(self.store.claim("fp-1"))
        self.assertTrue(self.store.is_consumed("fp-1"))

    def test_second_claim_of_same_fingerprint_fails(self):
        self.assertTrue(self.store.claim("fp-1"))
        self.assertFalse(self.store.claim("fp-1"))

    def test_unrelated_fingerprint_is_unaffected(self):
        self.store.claim("fp-1")
        self.assertFalse(self.store.is_consumed("fp-2"))
        self.assertTrue(self.store.claim("fp-2"))

    def test_release_unconsumes(self):
        self.store.claim("fp-1")
        released = self.store.release("fp-1")
        self.assertTrue(released)
        self.assertFalse(self.store.is_consumed("fp-1"))

    def test_release_of_unconsumed_fingerprint_is_false_not_error(self):
        released = self.store.release("never-claimed")
        self.assertFalse(released)

    def test_claim_after_release_succeeds_again(self):
        self.store.claim("fp-1")
        self.store.release("fp-1")
        self.assertTrue(self.store.claim("fp-1"))


class PersistenceAcrossReopenTest(unittest.TestCase):
    """프로세스 재시작을 흉내낸다 — close 후 새 인스턴스로 다시 연다."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db_path = os.path.join(tmp.name, "approval-consumption.sqlite3")

    def test_consumption_survives_close_and_reopen(self):
        first = approval_store.ApprovalConsumptionStore.open(self.db_path)
        first.claim("fp-1")
        first.close()

        second = approval_store.ApprovalConsumptionStore.open(self.db_path)
        try:
            self.assertTrue(second.is_consumed("fp-1"))
            self.assertFalse(second.claim("fp-1"))
        finally:
            second.close()

    def test_unconsumed_state_also_survives_reopen(self):
        first = approval_store.ApprovalConsumptionStore.open(self.db_path)
        first.close()

        second = approval_store.ApprovalConsumptionStore.open(self.db_path)
        try:
            self.assertFalse(second.is_consumed("fp-never-claimed"))
        finally:
            second.close()


@unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약 (spec §3.8)")
class FilePermissionTest(unittest.TestCase):
    def test_new_db_file_is_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous_umask = os.umask(0o000)
            try:
                db_path = os.path.join(tmp, "approval-consumption.sqlite3")
                store = approval_store.ApprovalConsumptionStore.open(db_path)
                try:
                    store.claim("fp-1")
                    self.assertEqual(_mode(db_path), 0o600)
                finally:
                    store.close()
            finally:
                os.umask(previous_umask)

    def test_default_path_lives_under_state_dir_and_is_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = LocalStateRoot(tmp)
            store = approval_store.open_default_approval_consumption_store(
                root
            )
            try:
                store.claim("fp-1")
                db_path = root.approval_consumption_path()
                self.assertTrue(db_path.startswith(root.state_dir))
                self.assertEqual(_mode(db_path), 0o600)
            finally:
                store.close()


@unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
@unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
class SymlinkGuardTest(unittest.TestCase):
    """Medium C 회귀 방지 — 미리 심어진 심볼릭 링크는 open() 을 거부한다.

    재리뷰 재현: `ApprovalConsumptionStore.open` 이 기존 경로를
    확인하지 않고 `sqlite3.connect` 로 그대로 넘겨, 미리 심어둔 심볼릭
    링크를 따라가 소비 기록을 외부 파일에 썼다. 이 store 는 캐시가
    아니라 권위 기록이라(지우면 승인이 되살아난다) 링크를 따라간 쓰기가
    특히 위험하다 — `platform.storage.local.SymlinkGuardTest` 와 동일
    패턴의 방어를 이 store 에도 고정한다.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp_dir = tmp.name
        self.outside_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.outside_dir, ignore_errors=True)

    def test_open_rejects_preplanted_symlink(self):
        outside_target = os.path.join(self.outside_dir, "outside.sqlite3")
        db_path = os.path.join(self.tmp_dir, "approval-consumption.sqlite3")
        os.symlink(outside_target, db_path)

        with self.assertRaises(OSError):
            approval_store.ApprovalConsumptionStore.open(db_path)

        # 링크를 따라가 대상에 쓰지 않았어야 한다 (권위 기록이 외부로
        # 새지 않는다)
        self.assertFalse(os.path.exists(outside_target))
        self.assertTrue(os.path.islink(db_path))

    def test_open_still_works_for_regular_existing_db(self):
        # 가드가 정상적인 재오픈(프로세스 재시작 시나리오)까지 막지
        # 않아야 한다.
        db_path = os.path.join(self.tmp_dir, "approval-consumption.sqlite3")
        first = approval_store.ApprovalConsumptionStore.open(db_path)
        first.claim("fp-1")
        first.close()

        second = approval_store.ApprovalConsumptionStore.open(db_path)
        try:
            self.assertTrue(second.is_consumed("fp-1"))
        finally:
            second.close()


def _patched_lstat_raising_at(target_path, error):
    """`os.lstat` 을 감싸 `target_path` 호출에서만 지정한 예외를 던진다.

    `tests/cli/test_open_approval_consumption_store_error_classification.py`
    의 동명 헬퍼와 동일 패턴 — 진입점 쪽 오류 분류 테스트와 이 저장소
    함수 자체의 오류 분류 테스트가 같은 검증 방식을 공유하게 한다.
    """
    original = os.lstat

    def _faulty(path, *args, **kwargs):
        if path == target_path:
            raise error
        return original(path, *args, **kwargs)

    return _faulty


class RejectSymlinkOrSpecialErrorClassificationTest(unittest.TestCase):
    """`_reject_symlink_or_special` 오류 분류 회귀 방지.

    진입점(`rein/cli/__init__.py::_open_approval_consumption_store`)의
    Medium 2 시정과 같은 클래스의 결함이 이 저장소 함수에도 있었다 —
    수리 전에는 `except OSError:` 로 lstat 실패를 전부 "아직 없음"으로
    흡수해, "파일이 정말 없음"(`FileNotFoundError`, 정상 — 아직 아무
    승인도 소비되지 않음)과 "lstat 자체가 다른 이유로 실패함"(예: 상위
    디렉터리 권한 거부 → `PermissionError`, 판단 불능)을 같게 취급했다.
    후자를 부재로 흡수하면 접근 불가 상태가 조용히 통과하는 fail-open
    이 된다 — 이 store 는 캐시가 아니라 권위 기록이다(모듈 docstring
    "저장 위치" 절).
    """

    def test_file_not_found_is_treated_as_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            # 부모 디렉터리조차 없다 — lstat 는 FileNotFoundError. 예외
            # 없이 그냥 반환해야 한다(다음 open_store 호출이 새로 만든다).
            db_path = os.path.join(
                tmp, "nested", "approval-consumption.sqlite3"
            )
            approval_store._reject_symlink_or_special(db_path)  # no raise

    def test_permission_error_during_lstat_propagates_not_absorbed(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "approval-consumption.sqlite3")
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(
                    PermissionError,
                    msg="a PermissionError while lstat-ing the db path "
                    "must not be silently absorbed as 'file absent' — "
                    "that would let an inaccessible consumption ledger "
                    "pass through as if no approval had ever been "
                    "consumed (fail-open on a authority record)",
                ):
                    approval_store._reject_symlink_or_special(db_path)


class _SchemaFailingConnection:
    """진짜 sqlite3 connection 을 감싸 `CREATE TABLE` 문에서만 강제로
    실패시키는 테스트 더블 — `ConnectionLeakOnInitFailureTest` 전용.

    `sqlite3.Connection` 인스턴스는 속성이 read-only 라 메서드를 직접
    monkeypatch 할 수 없다(실측 확인) — 그래서 진짜 connection 을
    감싸는 duck-typed 래퍼로 우회한다. `close()` 호출 여부를 관찰해
    Low D(초기화 실패 시 연결 누수) 회귀를 고정한다.
    """

    def __init__(self, real_connection):
        self._real = real_connection
        self.closed = False

    def execute(self, sql, *args, **kwargs):
        if "CREATE TABLE" in sql:
            raise sqlite3.OperationalError("forced failure for test")
        return self._real.execute(sql, *args, **kwargs)

    def close(self):
        self.closed = True
        self._real.close()

    def __enter__(self):
        self._real.__enter__()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return self._real.__exit__(exc_type, exc_value, traceback)


class ConnectionLeakOnInitFailureTest(unittest.TestCase):
    """Low D 회귀 방지 — 초기화(스키마 생성) 도중 예외가 나면 이미 연
    connection 이 새지 않고(닫히고) 나서 예외가 전파돼야 한다.

    수리 전에는 `_ensure_schema` 의 `CREATE TABLE` 실패가
    `__init__` -> `cls(connection, ...)` 체인을 그대로 뚫고 `open()`
    밖으로 전파되는 동안, 이미 성공적으로 연 sqlite3 connection 을
    참조할 방법이 호출자에게 전혀 남지 않아(반환되지 못한 로컬 변수만
    존재) 그대로 누수됐다.
    """

    def test_schema_creation_failure_closes_connection_not_leak(self):
        created = []

        def _fake_open_store(db_path):
            real_connection = sqlite3.connect(db_path)
            real_connection.execute("PRAGMA user_version").fetchone()
            fake = _SchemaFailingConnection(real_connection)
            created.append(fake)
            return fake

        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "approval-consumption.sqlite3")
            with mock.patch.object(
                approval_store, "open_store", _fake_open_store
            ):
                with self.assertRaises(sqlite3.OperationalError):
                    approval_store.ApprovalConsumptionStore.open(db_path)

            self.assertEqual(len(created), 1)
            self.assertTrue(created[0].closed)


class ProtocolShapeTest(unittest.TestCase):
    """capability 의 duck-type 검증기가 실제 구현체를 인정하는지 확인.

    `rein.capabilities.approval.capability._validate_consumption_store`
    를 그대로 통과해야 한다 — 이 테스트는 capability 모듈을 수정하지
    않고 소비만 한다(consumer contract 검증, capability 는 여전히 이
    구현체를 import 하지 않는다).
    """

    def test_store_satisfies_capability_duck_type_validator(self):
        from rein.capabilities.approval import capability as approval_cap

        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "approval-consumption.sqlite3")
            store = approval_store.ApprovalConsumptionStore.open(db_path)
            try:
                # 예외를 던지지 않으면 통과 (내부 함수, 반환값 없음)
                approval_cap._validate_consumption_store(store)
            finally:
                store.close()


class EndToEndRequirementIntegrationTest(unittest.TestCase):
    """실제 store + 실제 UserApprovalRequirement + runtime.evaluate 관통.

    contract 테스트(`tests/contract/test_approval_one_shot.py`)는 테스트
    전용 in-memory 더블만 쓴다 — 이 테스트는 이 워커가 만든 실제 sqlite
    구현체가 같은 계약을 만족함을 별도로 고정한다.
    """

    def test_first_call_allows_and_commits_second_call_blocks(self):
        from rein.engine import runtime
        from rein.engine.registry import RequirementRegistry
        from rein.kernel import policy as kernel_policy
        from rein.kernel.decision import DECISION_ALLOW, DECISION_BLOCK
        from rein.capabilities.approval.capability import (
            FACT_ACTION_CURRENT,
            FACT_APPROVAL_CONSUMPTION_STORE,
            FACT_CHANGESET_DIGEST,
            FACT_POLICY_VERSION,
            issue_user_approval_evidence,
            register_user_approval,
        )

        class _StubEvidenceSource:
            def __init__(self, records):
                self._records = tuple(records)

            def find(self, requirement_name):
                return self._records

        digest = "digest-abc"
        action = "tool.pre:Bash:git push"
        evidence = issue_user_approval_evidence(
            action, current_digest=digest, policy_version="1"
        )

        policy = {
            "policy_id": "approval-gate",
            "fields": kernel_policy.parse_policy(
                "trigger: tool.pre\n"
                "require:\n"
                "  - user_approval\n"
                "failure_mode: closed\n",
                source="<test:approval-gate>",
            ),
        }
        registry = RequirementRegistry()
        register_user_approval(registry)

        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "approval-consumption.sqlite3")
            store = approval_store.ApprovalConsumptionStore.open(db_path)
            try:
                facts = {
                    FACT_CHANGESET_DIGEST: digest,
                    FACT_ACTION_CURRENT: action,
                    FACT_POLICY_VERSION: "1",
                    FACT_APPROVAL_CONSUMPTION_STORE: store,
                }
                first = runtime.evaluate(
                    "tool.pre",
                    facts,
                    [policy],
                    evidence_source=_StubEvidenceSource((evidence,)),
                    registry=registry,
                )
                self.assertEqual(first["decision"], DECISION_ALLOW)

                second = runtime.evaluate(
                    "tool.pre",
                    facts,
                    [policy],
                    evidence_source=_StubEvidenceSource((evidence,)),
                    registry=registry,
                )
                self.assertEqual(second["decision"], DECISION_BLOCK)
            finally:
                store.close()


def _claim_in_subprocess(db_path, fingerprint, result_queue):
    """multiprocessing worker — 자기 연결로 claim 을 시도한다."""
    import sys as _sys

    _plugin_root = os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    if _plugin_root not in _sys.path:
        _sys.path.insert(0, _plugin_root)
    from rein.platform.storage import approval_store as _approval_store

    store = _approval_store.ApprovalConsumptionStore.open(db_path)
    try:
        result_queue.put(store.claim(fingerprint))
    finally:
        store.close()


class ConcurrentClaimTest(unittest.TestCase):
    """같은 fingerprint 를 서로 다른 프로세스가 동시에 claim 하면 하나만 이긴다.

    SQLite 의 PRIMARY KEY 제약 + writer 잠금이 실제로 두 프로세스 경합을
    직렬화하는지 확인한다 — 단일 프로세스 GIL 하의 순차 호출만으로는
    검증할 수 없는 보장이라 별도 프로세스로 재현한다.
    """

    def test_concurrent_claims_of_same_fingerprint_only_one_wins(self):
        import multiprocessing

        with tempfile.TemporaryDirectory() as tmp:
            db_path = os.path.join(tmp, "approval-consumption.sqlite3")
            # 스키마를 미리 만들어 둔다 (두 프로세스가 동시에 CREATE TABLE
            # IF NOT EXISTS 를 실행해도 안전해야 하지만, 순서 결정성 확보
            # 를 위해 여기서 먼저 만든다).
            setup = approval_store.ApprovalConsumptionStore.open(db_path)
            setup.close()

            ctx = multiprocessing.get_context("spawn")
            result_queue = ctx.Queue()
            processes = [
                ctx.Process(
                    target=_claim_in_subprocess,
                    args=(db_path, "fp-race", result_queue),
                )
                for _ in range(2)
            ]
            for process in processes:
                process.start()

            # 결정성 시정: 이전 구현은 join(timeout=30) 결과를 확인하지
            # 않고 곧장 result_queue.get() 으로 넘어갔다 — 자식이
            # 타임아웃까지 끝나지 않으면(행/데드락) 살아있는 프로세스가
            # 남거나, 자식이 결과를 큐에 넣기 전에 죽으면(비정상 종료)
            # get() 이 잡아내지 못한 원인으로 queue.Empty 가 나 진단이
            # 모호했다. join 직후 생존 여부·exitcode 를 명시적으로
            # 검사해 실패 원인을 바로 드러내고, 살아남은 프로세스는
            # 정리한다 (드문 hang 이 테스트를 무기한 흔들지 않는다).
            try:
                for process in processes:
                    process.join(timeout=30)
                    if process.is_alive():
                        process.terminate()
                        process.join(timeout=5)
                        self.fail(
                            "claim subprocess pid={!r} did not finish "
                            "within the 30s join timeout — terminated to "
                            "keep the test deterministic".format(
                                process.pid
                            )
                        )
                    self.assertEqual(
                        process.exitcode,
                        0,
                        "claim subprocess pid={!r} exited with code {!r} "
                        "instead of 0 (crashed before reporting its "
                        "result)".format(process.pid, process.exitcode),
                    )

                results = [result_queue.get(timeout=5) for _ in processes]
            finally:
                for process in processes:
                    if process.is_alive():
                        process.terminate()
                        process.join(timeout=5)

            self.assertEqual(sorted(results), [False, True])

            verifier = approval_store.ApprovalConsumptionStore.open(db_path)
            try:
                self.assertTrue(verifier.is_consumed("fp-race"))
            finally:
                verifier.close()


if __name__ == "__main__":
    unittest.main()
