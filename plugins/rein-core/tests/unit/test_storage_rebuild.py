"""plan Task 2.5 — SQLite 재구축 가능성 계약 (spec §3.8).

covers: runtime-state-rebuilds-equivalent-decisions-after-sqlite-deletion

SQLite 는 Source of Truth 가 아니다 — Fact Cache / Evidence Index /
Digest Cache / Runtime State / Ledger Index 용 캐시·인덱스일 뿐이다.
따라서 sqlite 파일을 삭제(또는 손상)한 뒤 동일 시나리오를 다시 돌리면
동일한 decision 이 나와야 한다: 판단 재료의 정본은 프로젝트 상태(권위
소스)이고, store 는 그로부터 언제든 재구축된다.

decision 산출은 기존 runtime.evaluate 경로를 그대로 쓴다 (evaluator /
runtime 은 읽기 전용 — 이 태스크는 storage 계층만 추가한다).
"""
import os
import sqlite3
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import runtime  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
)
from rein.platform.sqlite import store as sqlite_store  # noqa: E402
from rein.platform.storage import local  # noqa: E402


def _load_inline_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태로 policy fixture 를 만든다."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


_REVIEW_POLICY = _load_inline_policy(
    "require-review-on-bash",
    "trigger: tool.pre\n"
    "when:\n"
    "  tool: Bash\n"
    "require:\n"
    "  - code_review\n"
    "failure_mode: closed\n",
)

_REVIEW_EVIDENCE = {
    "type": "code_review",
    "subject": "digest:abc123",
    "result": "pass",
    "created_at": "2026-08-08T00:00:00",
    "producer": "agent_attested",
    "policy_version": "1",
}


class _CountingAuthority:
    """권위 소스 스텁 — 프로젝트 상태를 다시 읽는 역할 + 호출 횟수 기록."""

    def __init__(self, records_by_requirement=None):
        self._records = dict(records_by_requirement or {})
        self.calls = 0

    def find(self, requirement_name):
        self.calls += 1
        return tuple(self._records.get(requirement_name, ()))


class RebuildEquivalenceTest(unittest.TestCase):
    """spec §3.8 — sqlite 삭제·손상 전/후 동일 시나리오 → 동일 decision."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = local.LocalStateRoot(tmp.name)
        self.root.ensure()
        self.db_path = self.root.database_path()

    def _decide(self, store, authority):
        source = sqlite_store.CachedEvidenceSource(store, authority)
        return runtime.evaluate(
            "tool.pre",
            {"tool": "Bash"},
            [_REVIEW_POLICY],
            evidence_source=source,
        )

    def test_deletion_preserves_allow_decision(self):
        authority = _CountingAuthority({"code_review": (_REVIEW_EVIDENCE,)})
        store = sqlite_store.SqliteStore.open(self.db_path)
        before = self._decide(store, authority)
        store.close()
        self.assertEqual(before["decision"], DECISION_ALLOW)

        sqlite_store.remove_store_files(self.db_path)
        self.assertFalse(os.path.exists(self.db_path))

        rebuilt = sqlite_store.SqliteStore.open(self.db_path)
        after = self._decide(rebuilt, authority)
        rebuilt.close()
        self.assertEqual(before, after)

    def test_deletion_preserves_block_decision(self):
        authority = _CountingAuthority({})  # evidence 부재 = 정상 평가 BLOCK
        store = sqlite_store.SqliteStore.open(self.db_path)
        before = self._decide(store, authority)
        store.close()
        self.assertEqual(before["decision"], DECISION_BLOCK)

        sqlite_store.remove_store_files(self.db_path)

        rebuilt = sqlite_store.SqliteStore.open(self.db_path)
        after = self._decide(rebuilt, authority)
        rebuilt.close()
        self.assertEqual(before, after)

    def test_corrupted_db_is_discarded_and_rebuilt(self):
        authority = _CountingAuthority({"code_review": (_REVIEW_EVIDENCE,)})
        with open(self.db_path, "wb") as handle:
            handle.write(b"this is not a sqlite database")

        store = sqlite_store.SqliteStore.open_or_rebuild(self.db_path)
        decision = self._decide(store, authority)
        store.close()
        self.assertEqual(decision["decision"], DECISION_ALLOW)

    def test_cache_serves_hits_and_rebuild_rereads_authority(self):
        authority = _CountingAuthority({"code_review": (_REVIEW_EVIDENCE,)})
        store = sqlite_store.SqliteStore.open(self.db_path)
        source = sqlite_store.CachedEvidenceSource(store, authority)

        first = source.find("code_review")
        second = source.find("code_review")
        self.assertEqual(len(first), 1)
        self.assertEqual(tuple(first), tuple(second))
        self.assertEqual(authority.calls, 1)  # 2회차는 캐시 히트
        store.close()

        # 삭제 후 재구축 — 캐시가 사라졌으므로 권위 소스를 다시 읽는다
        sqlite_store.remove_store_files(self.db_path)
        rebuilt = sqlite_store.SqliteStore.open(self.db_path)
        rebuilt_source = sqlite_store.CachedEvidenceSource(rebuilt, authority)
        third = rebuilt_source.find("code_review")
        rebuilt.close()
        self.assertEqual(tuple(first), tuple(third))
        self.assertEqual(authority.calls, 2)

    def test_authority_errors_propagate_not_swallowed(self):
        # 캐시 오류는 miss 로 강등되지만, 권위 소스의 실패(판단 불능
        # 재료)는 그대로 전파돼야 failure_mode 경계가 유지된다 (spec §3.4)
        class _FailingAuthority:
            def find(self, requirement_name):
                raise RuntimeError("authority storage exploded")

        store = sqlite_store.SqliteStore.open(self.db_path)
        source = sqlite_store.CachedEvidenceSource(store, _FailingAuthority())
        with self.assertRaises(RuntimeError):
            source.find("code_review")
        store.close()


class StoreContractTest(unittest.TestCase):
    """spec §3.8 — WAL·busy timeout·짧은 transaction·retry·폐쇄 section."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = local.LocalStateRoot(tmp.name)
        self.root.ensure()
        self.store = sqlite_store.SqliteStore.open(self.root.database_path())
        self.addCleanup(self.store.close)

    def test_wal_mode_and_busy_timeout_applied(self):
        journal_mode = self.store.connection.execute(
            "PRAGMA journal_mode"
        ).fetchone()[0]
        self.assertEqual(journal_mode.lower(), "wal")
        busy_timeout = self.store.connection.execute(
            "PRAGMA busy_timeout"
        ).fetchone()[0]
        self.assertEqual(busy_timeout, sqlite_store.DEFAULT_BUSY_TIMEOUT_MS)

    def test_put_get_roundtrip_per_section(self):
        for section in sqlite_store.SECTIONS:
            self.store.put(section, "k", {"n": 1})
            self.assertEqual(self.store.get(section, "k"), {"n": 1})
        self.assertIsNone(self.store.get(sqlite_store.SECTION_FACT_CACHE, "x"))

    def test_unknown_section_is_rejected(self):
        with self.assertRaises(ValueError):
            self.store.put("trail", "k", "v")
        with self.assertRaises(ValueError):
            self.store.get("trail", "k")

    def test_delete_removes_key(self):
        self.store.put(sqlite_store.SECTION_RUNTIME_STATE, "k", "v")
        self.store.delete(sqlite_store.SECTION_RUNTIME_STATE, "k")
        self.assertIsNone(
            self.store.get(sqlite_store.SECTION_RUNTIME_STATE, "k")
        )


class RetryContractTest(unittest.TestCase):
    """spec §3.8 retry — locked 만 재시도, 그 외는 즉시 전파."""

    def test_retries_locked_error_then_succeeds(self):
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) < 3:
                raise sqlite3.OperationalError("database is locked")
            return "ok"

        result = sqlite_store.run_with_retry(
            flaky, attempts=3, delay_seconds=0
        )
        self.assertEqual(result, "ok")
        self.assertEqual(len(calls), 3)

    def test_non_locked_operational_error_raises_immediately(self):
        calls = []

        def broken():
            calls.append(1)
            raise sqlite3.OperationalError("no such table: nope")

        with self.assertRaises(sqlite3.OperationalError):
            sqlite_store.run_with_retry(broken, attempts=3, delay_seconds=0)
        self.assertEqual(len(calls), 1)

    def test_exhausted_retries_reraise_locked_error(self):
        calls = []

        def always_locked():
            calls.append(1)
            raise sqlite3.OperationalError("database is locked")

        with self.assertRaises(sqlite3.OperationalError):
            sqlite_store.run_with_retry(
                always_locked, attempts=2, delay_seconds=0
            )
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
