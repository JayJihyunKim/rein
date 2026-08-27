"""plan Task 4.7 — CLI doctor/explain 출력 계약 (spec §5.2, §3.1 cli/).

covers: cli-doctor-reports-config-policy-storage-health-and-explain-shows-last-decision-basis

spec §3.1 커버리지 표 원문: "`rein doctor` 가 설정·policy·storage 상태와
미설정 안내(예: testing 미선언)를 출력하고, `rein explain` 이 최근
decision 의 policy·missing_requirements·evidence 근거를 보여준다."

검증 축 (plan Task 4.7 Steps 1):
(a) doctor 필드 계약 — 설정/policy/storage/미설정 안내 필드가 항상 존재.
(b) 대표 BLOCK 이벤트에서 `explain` 출력의 basis(policy/missing_requirements/
    evidence_refs)가 같은 입력을 `run_event` 로 재평가한 decision 레코드와
    정확히 일치.
(c) `bin/rein` 하위호환 — 인자 없는 기존 이벤트 평가 왕복이 그대로다
    (`tests/unit/test_scaffold_roundtrip.py` 가 이미 고정한 계약의 회귀
    확인 + `doctor`/`explain` 서브커맨드 end-to-end).
(d) 미포착 예외 주입(테스트용 오염 입력) → BLOCK JSON + 판단 불능
    reason(조용한 ALLOW 아님). 이 축은 subprocess 를 쓰지 않는다 — 오염
    입력을 실제 하위 프로세스에 넘기는 대신, in-process 로
    `rein.cli.run_event` 를 mock 해 예외를 주입한다(worker 지침 —
    subprocess 로 bin/rein 실행하는 테스트는 무해 입력만).

2026-08-11 사이클 C 리뷰 1회차(High 1 + Medium 2) 반영 축 추가:
(e) High — `PolicyLoadError`(`ValueError` 하위 타입이지만 "판단 재료
    실패"이지 "순수 입력 결함"이 아님)가 exit 1(조용한 ALLOW)로 새던
    구멍을 리뷰어 재현 경로 그대로(malformed policy 주입) 재현해 BLOCK
    + exit 0 으로 수정됐음을 고정한다. 이 축은 subprocess 를 쓴다 —
    손상된 policy YAML 텍스트는 악성/오염 입력이 아니라 단순 스키마
    위반이라 worker 지침의 "무해 입력만" 제약에 저촉되지 않는다.
(f) Medium 2 — BLOCK reason 에 실리는 예외 문자열이 기존 마스킹 SSOT
    (`rein.shadow.masking`)를 거쳐 나가는지 — 민감 패턴을 포함한 예외를
    주입해 마스킹된 형태로만 노출됨을 고정한다(in-process, worker
    지침과 동일한 이유로 subprocess 미사용).

2026-08-11 사이클 C 재리뷰(4회차) Medium 1 + Medium 2 반영 축 추가:
(g) Medium 1 — doctor 의 sqlite 검사가 실제로는 스키마를 생성하던 결함
    (리뷰어 실증: 0바이트 db 가 doctor 실행 후 45KB·5테이블로 바뀜)을
    "doctor 실행 전후 파일 바이트 불변" 으로 고정한다 — 빈 파일/정상
    초기화된 db 양쪽 다.
(h) Medium 2 — `explain` 이 commit 경로(`run_event`/`runtime.evaluate`)
    를 타지 않는지: 소비 저장 프로토콜을 실제로 주입한 뒤 `run_explain`
    을 호출해도 `claim()` 이 0 회 호출됨을 고정한다.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import run_event  # noqa: E402
from rein.cli.doctor import run_doctor  # noqa: E402
from rein.cli.explain import run_explain  # noqa: E402

_BIN_REIN = os.path.join(_PLUGIN_ROOT, "bin", "rein")
_SUBPROCESS_TIMEOUT_SECONDS = 30
_ENV_POLICY_DIR = "REIN_POLICY_DIR"
_ENV_DB_PATH = "REIN_DB_PATH"

_VALID_TESTING_YAML = (
    "testing:\n"
    "  commands:\n"
    "    - id: unit\n"
    "      run: pytest tests/unit\n"
    "      tag: code\n"
)

# 미지 필드(extra) — kernel/policy.py 와 동일 D3 규율로 로드 시점 거부되는
# fixture (tests/contract/test_tests_passed_eligibility.py 와 동일 형태)
_INVALID_TESTING_YAML = (
    "testing:\n"
    "  commands:\n"
    "    - id: unit\n"
    "      run: pytest\n"
    "      tag: code\n"
    "      extra: nope\n"
)

_BLOCK_POLICY_YAML = (
    "trigger: tool.pre\n"
    "when:\n"
    "  tool: Bash\n"
    "require:\n"
    "  - code_review\n"
    "failure_mode: closed\n"
)

# 손상된 policy — 미지 최상위 필드(kernel/policy.py POLICY_FIELDS 밖) 로
# 로드 시점 PolicyLoadError 를 유발한다. 리뷰어의 malformed policy 재현
# 경로 그대로(High 1) — 내용 자체는 악성이 아니라 단순 스키마 위반이라
# subprocess 로 실행해도 worker 지침의 "무해 입력만" 을 어기지 않는다.
_MALFORMED_POLICY_YAML = "trigger: tool.pre\nbogus_field: 1\n"


def _tool_pre_payload(tool_name="Bash"):
    return {
        "hook_event_name": "PreToolUse",
        "tool_name": tool_name,
        "tool_input": {"command": "ls"},
    }


def _load_bin_rein_module():
    """bin/rein 을 실행 없이 모듈로 로드한다 (in-process 예외 주입용).

    `bin/rein` 은 확장자가 없는 실행 스크립트라
    `spec_from_file_location` 이 로더를 확장자로 추론하지 못한다
    (`.py` 전제) — `SourceFileLoader` 를 명시로 넘긴다.
    """
    loader = importlib.machinery.SourceFileLoader(
        "rein_bin_rein_under_test", _BIN_REIN
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class DoctorFieldContractTest(unittest.TestCase):
    """(a) doctor 필드 계약."""

    def test_reports_all_top_level_and_nested_fields(self):
        with tempfile.TemporaryDirectory() as project_root:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(_ENV_POLICY_DIR, None)
                report = run_doctor(project_root)
        for key in ("project_root", "config", "policy", "storage"):
            self.assertIn(key, report)
        for key in ("path", "configured", "commands", "error", "guidance"):
            self.assertIn(key, report["config"])
        for key in ("dir", "count", "loaded", "error"):
            self.assertIn(key, report["policy"])
        for key in ("state_dir", "exists", "ledger", "evidence", "sqlite"):
            self.assertIn(key, report["storage"])
        for key in ("path", "exists"):
            self.assertIn(key, report["storage"]["ledger"])
            self.assertIn(key, report["storage"]["evidence"])
        for key in ("path", "exists", "ok", "error"):
            self.assertIn(key, report["storage"]["sqlite"])

    def test_missing_testing_config_yields_onboarding_guidance(self):
        with tempfile.TemporaryDirectory() as project_root:
            report = run_doctor(project_root)
        config = report["config"]
        self.assertFalse(config["configured"])
        self.assertIsNone(config["commands"])
        self.assertIsNone(config["error"])
        self.assertIsInstance(config["guidance"], str)
        self.assertGreater(len(config["guidance"]), 0)

    def test_configured_testing_reports_command_count_and_no_guidance(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, ".rein", "policy")
            os.makedirs(policy_dir)
            with open(
                os.path.join(policy_dir, "testing.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(_VALID_TESTING_YAML)
            report = run_doctor(project_root)
        config = report["config"]
        self.assertTrue(config["configured"])
        self.assertEqual(config["commands"], 1)
        self.assertIsNone(config["guidance"])
        self.assertIsNone(config["error"])

    def test_broken_testing_config_reports_error_and_guidance(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, ".rein", "policy")
            os.makedirs(policy_dir)
            with open(
                os.path.join(policy_dir, "testing.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(_INVALID_TESTING_YAML)
            report = run_doctor(project_root)
        config = report["config"]
        self.assertFalse(config["configured"])
        self.assertIsNotNone(config["error"])
        self.assertIsInstance(config["guidance"], str)
        self.assertGreater(len(config["guidance"]), 0)

    def test_policy_dir_unset_reports_zero_count_without_error(self):
        with tempfile.TemporaryDirectory() as project_root:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(_ENV_POLICY_DIR, None)
                report = run_doctor(project_root)
        policy = report["policy"]
        self.assertIsNone(policy["dir"])
        self.assertEqual(policy["count"], 0)
        self.assertTrue(policy["loaded"])
        self.assertIsNone(policy["error"])

    def test_policy_dir_set_reports_loaded_count(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(_BLOCK_POLICY_YAML)
            with mock.patch.dict(os.environ, {_ENV_POLICY_DIR: policy_dir}):
                report = run_doctor(project_root)
        policy = report["policy"]
        self.assertEqual(policy["dir"], policy_dir)
        self.assertEqual(policy["count"], 1)
        self.assertTrue(policy["loaded"])
        self.assertIsNone(policy["error"])

    def test_storage_uninitialized_project_reports_absent_read_only(self):
        with tempfile.TemporaryDirectory() as project_root:
            report = run_doctor(project_root)
            storage = report["storage"]
            self.assertFalse(storage["exists"])
            self.assertFalse(storage["sqlite"]["exists"])
            self.assertIsNone(storage["sqlite"]["ok"])
            self.assertFalse(storage["ledger"]["exists"])
            self.assertFalse(storage["evidence"]["exists"])
            # 읽기 전용 계약 — doctor 호출이 .rein/ 을 새로 만들지 않는다
            self.assertFalse(
                os.path.exists(os.path.join(project_root, ".rein"))
            )

    def test_storage_initialized_project_reports_sqlite_openable(self):
        from rein.platform.sqlite.store import SqliteStore
        from rein.platform.storage.local import LocalStateRoot

        with tempfile.TemporaryDirectory() as project_root:
            root = LocalStateRoot(project_root)
            root.ensure()
            store = SqliteStore.open(root.database_path())
            store.close()

            report = run_doctor(project_root)
        storage = report["storage"]
        self.assertTrue(storage["exists"])
        self.assertTrue(storage["sqlite"]["exists"])
        self.assertTrue(storage["sqlite"]["ok"])
        self.assertIsNone(storage["sqlite"]["error"])


class DoctorSqliteReadOnlyTest(unittest.TestCase):
    """(g) 2026-08-11 사이클 C 재리뷰 4회차 Medium 1 — sqlite 검사는 read-only.

    리뷰어 실증 재현: `SqliteStore.open()` 을 doctor 진단에 그대로 쓰면
    생성자의 `_ensure_schema()` 가 무조건 5개 테이블을 만든다 — 0바이트
    db 가 doctor 호출 한 번으로 45KB·5테이블 db 로 바뀌었다. 이 클래스는
    "doctor 실행 전후 DB 파일 바이트 불변" 을 여러 초기 상태(빈 파일/
    정상 초기화된 db/손상된 파일)에서 고정한다.
    """

    def _file_bytes(self, path):
        with open(path, "rb") as handle:
            return handle.read()

    def test_empty_file_stays_empty_after_doctor(self):
        """리뷰어의 정확한 재현 경로 — 0바이트 db 가 doctor 후에도 0바이트."""
        from rein.platform.storage.local import LocalStateRoot

        with tempfile.TemporaryDirectory() as project_root:
            root = LocalStateRoot(project_root)
            root.ensure()
            db_path = root.database_path()
            open(db_path, "wb").close()  # 0바이트 — SqliteStore 미경유
            self.assertEqual(os.path.getsize(db_path), 0)

            report = run_doctor(project_root)

            self.assertEqual(
                os.path.getsize(db_path),
                0,
                msg="doctor must not write to an existing db file",
            )
        storage = report["storage"]
        # 0바이트 파일은 sqlite 상 유효한 빈 db 다 — integrity_check 통과.
        self.assertTrue(storage["sqlite"]["exists"])
        self.assertTrue(storage["sqlite"]["ok"])

    def test_initialized_db_bytes_unchanged_after_doctor(self):
        from rein.platform.sqlite.store import SqliteStore
        from rein.platform.storage.local import LocalStateRoot

        with tempfile.TemporaryDirectory() as project_root:
            root = LocalStateRoot(project_root)
            root.ensure()
            db_path = root.database_path()
            store = SqliteStore.open(db_path)
            store.close()
            before = self._file_bytes(db_path)
            self.assertGreater(len(before), 0)

            run_doctor(project_root)
            run_doctor(project_root)  # 반복 호출도 멱등해야 한다

            after = self._file_bytes(db_path)
        self.assertEqual(
            before,
            after,
            msg="doctor must not mutate an already-initialized db file",
        )

    def test_corrupted_file_reports_not_ok_without_mutating_bytes(self):
        from rein.platform.storage.local import LocalStateRoot

        with tempfile.TemporaryDirectory() as project_root:
            root = LocalStateRoot(project_root)
            root.ensure()
            db_path = root.database_path()
            with open(db_path, "wb") as handle:
                handle.write(b"not a real sqlite file" * 5)
            before = self._file_bytes(db_path)

            report = run_doctor(project_root)

            after = self._file_bytes(db_path)
        self.assertEqual(before, after)
        storage = report["storage"]
        self.assertTrue(storage["sqlite"]["exists"])
        self.assertFalse(storage["sqlite"]["ok"])
        self.assertIsNotNone(storage["sqlite"]["error"])

    def test_doctor_does_not_import_sqlite_store_write_path(self):
        """모듈 네임스페이스에 `SqliteStore` 심볼이 없음을 정적으로 고정.

        이 클래스의 나머지 테스트는 행위(바이트 불변)를 검증하지만,
        구현이 다시 `SqliteStore.open()` 경로로 회귀해도 대부분의
        입력(정상 초기화된 db)에서는 우연히 바이트가 안 바뀔 수 있다
        (스키마가 이미 존재하면 `CREATE TABLE IF NOT EXISTS` 가
        no-op). 회귀를 더 확실히 잡기 위해 모듈이 실제로 그 심볼을
        import 하지 않았음을 같이 고정한다(모듈 docstring 은 옛 구현을
        설명하려 `SqliteStore` 라는 이름을 텍스트로 언급할 수 있으므로,
        source 문자열 grep 대신 모듈 네임스페이스 자체를 검사한다).
        """
        from rein.cli import doctor as doctor_module

        self.assertFalse(hasattr(doctor_module, "SqliteStore"))


class ExplainBasisMatchesDecisionTest(unittest.TestCase):
    """(b) 대표 BLOCK 이벤트 → explain 출력이 decision 레코드와 일치.

    2026-08-11 사이클 C 리뷰 Medium 1: explain 이 "재평가" 방식임을
    나타내는 명시 필드(`method`)와 그 사실을 설명하는 `note` 문구도
    함께 고정한다(부모 결정 — decision 영속화는 이연, DoD 이연 추적
    항목 참조).
    """

    def test_explain_basis_matches_fresh_decision_for_block_event(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-review.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write(_BLOCK_POLICY_YAML)
            # code_review 는 증거 발급형 capability 다 — Phase 6 수리
            # 워커 F Medium D 이후, 이를 요구하는 policy 세트는 버전
            # 메타데이터 없이는 설정 오류로 차단된다(의도된 동작). 이
            # 테스트는 Medium D 가 아니라 explain/run_event basis 일치를
            # 겨냥하므로 유효한 버전 파일을 둔다.
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write('version: "1"\n')
            db_path = os.path.join(project_root, "runtime.sqlite3")
            raw_text = json.dumps(_tool_pre_payload("Bash"))

            with mock.patch.dict(
                os.environ,
                {_ENV_POLICY_DIR: policy_dir, _ENV_DB_PATH: db_path},
            ):
                decision = run_event(raw_text)
                explanation = run_explain(raw_text)

        self.assertEqual(decision["decision"], "BLOCK")
        self.assertEqual(explanation["decision"], "BLOCK")
        self.assertEqual(explanation["basis"]["policy"], decision["policy"])
        self.assertEqual(
            explanation["basis"]["missing_requirements"],
            decision["missing_requirements"],
        )
        self.assertEqual(
            explanation["basis"]["evidence_refs"], decision["evidence_refs"]
        )
        self.assertIsInstance(explanation["note"], str)
        self.assertGreater(len(explanation["note"]), 0)
        # Medium 1 — 재평가 방식 명시 필드 + "다를 수 있음" 안내 + DoD
        # 이연 추적 참조가 note 에 있어야 사람이 note 를 안 읽어도(필드만
        # 봐도), 또는 note 를 읽으면 왜 이연됐는지 둘 다 확인 가능하다.
        self.assertEqual(explanation["method"], "re-evaluation")
        self.assertIn("다를 수 있습니다", explanation["note"])
        self.assertIn("이연 추적", explanation["note"])

    def test_explain_basis_matches_decision_for_allow_event(self):
        with tempfile.TemporaryDirectory() as project_root:
            raw_text = json.dumps(_tool_pre_payload("Read"))
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(_ENV_POLICY_DIR, None)
                os.environ.pop(_ENV_DB_PATH, None)
                decision = run_event(raw_text)
                explanation = run_explain(raw_text)
        self.assertEqual(decision["decision"], "ALLOW")
        self.assertEqual(explanation["basis"]["policy"], decision["policy"])
        self.assertEqual(
            explanation["basis"]["missing_requirements"],
            decision["missing_requirements"],
        )
        self.assertEqual(explanation["method"], "re-evaluation")


class ExplainDoesNotCommitApprovalConsumptionTest(unittest.TestCase):
    """(h) 2026-08-11 사이클 C 재리뷰 4회차 Medium 2 — explain 은 commit 하지 않는다.

    승인 capability 를 실제로 registry 에 등록하고, 유효한 미소비 승인
    evidence 를 evidence_source 에 심어 `UserApprovalRequirement.evaluate`
    가 실제로 `context.reserve_consumption()` 을 거쳐 충족 판정을 내도록
    만든다(정책이 ALLOW 로 끝나는 조건 — 그래야 `runtime.evaluate` 였다면
    commit 이 실제로 시도됐을 상황임을 보장한다). 그런 뒤
    `run_explain()` 을 호출해도 소비 저장 프로토콜의 `claim()` 이 한 번도
    불리지 않아야 한다 — 불렸다면 "진단 명령이 실제 승인을 소모"하는
    사고가 재현된 것이다.
    """

    class _StaticEvidenceSource:
        def __init__(self, records_by_requirement):
            self._records = records_by_requirement

        def find(self, requirement_name):
            return self._records.get(requirement_name, ())

    class _RecordingConsumptionStore:
        """소비 저장 프로토콜 test double — 호출 여부를 그대로 기록한다."""

        def __init__(self):
            self.is_consumed_calls = []
            self.claim_calls = []
            self.release_calls = []

        def is_consumed(self, fingerprint):
            self.is_consumed_calls.append(fingerprint)
            return False

        def claim(self, fingerprint):
            self.claim_calls.append(fingerprint)
            return True

        def release(self, fingerprint):
            self.release_calls.append(fingerprint)

    def test_wired_approval_capability_never_commits_via_explain(self):
        from rein.capabilities.approval.capability import (
            FACT_ACTION_CURRENT,
            FACT_APPROVAL_CONSUMPTION_STORE,
            FACT_CHANGESET_DIGEST,
            FACT_POLICY_COMPATIBLE_VERSIONS,
            FACT_POLICY_VERSION,
            REQUIREMENT_NAME,
            issue_user_approval_evidence,
            register_user_approval,
        )
        from rein.engine.registry import RequirementRegistry

        action = "bash:ls"
        digest = "digest-abc123"
        policy_version = "v1"
        evidence = issue_user_approval_evidence(action, digest, policy_version)

        evidence_source = self._StaticEvidenceSource(
            {REQUIREMENT_NAME: (evidence,)}
        )
        store = self._RecordingConsumptionStore()

        registry = RequirementRegistry()
        register_user_approval(registry)

        policy_yaml = (
            "trigger: tool.pre\n"
            "when:\n"
            "  tool: Bash\n"
            "require:\n"
            "  - user_approval\n"
            "failure_mode: closed\n"
        )

        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-approval.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(policy_yaml)
            # user_approval 은 증거 발급형 capability 다 — Phase 6 수리
            # 워커 F Medium D 이후, 이를 요구하는 policy 세트는 버전
            # 메타데이터 없이는 설정 오류로 차단된다(의도된 동작). 이
            # 테스트는 Medium D 가 아니라 "explain 은 commit 하지 않는다"
            # 를 겨냥하므로 유효한 버전 파일을 둔다.
            with open(
                os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
            ) as handle:
                handle.write('version: "1"\n')

            raw_text = json.dumps(_tool_pre_payload("Bash"))
            extra_facts = {
                FACT_CHANGESET_DIGEST: digest,
                FACT_ACTION_CURRENT: action,
                FACT_POLICY_VERSION: policy_version,
                FACT_POLICY_COMPATIBLE_VERSIONS: (),
                FACT_APPROVAL_CONSUMPTION_STORE: store,
            }
            with mock.patch.dict(os.environ, {_ENV_POLICY_DIR: policy_dir}):
                explanation = run_explain(
                    raw_text,
                    registry=registry,
                    evidence_source=evidence_source,
                    extra_facts=extra_facts,
                )

        # sanity — 이 시나리오가 실제로 "충족되어 ALLOW" 조건을 만족해야
        # claim 0회가 의미 있는 단언이 된다(그렇지 않으면 애초에 예약도
        # 안 됐을 수 있어 "0회"가 약한 신호가 된다).
        self.assertEqual(explanation["decision"], "ALLOW")
        self.assertEqual(explanation["basis"]["missing_requirements"], [])
        # 핵심 단언 — commit 경로(runtime._commit_pending_consumptions)
        # 를 타지 않았으므로 claim()/release() 0회.
        self.assertEqual(store.claim_calls, [])
        self.assertEqual(store.release_calls, [])
        # evaluate() 자신은 여전히 is_consumed()(순수 조회)는 호출한다 —
        # 그건 판정에 필요한 peek 이지 commit 이 아니다.
        self.assertEqual(len(store.is_consumed_calls), 1)


class BinReinBackwardCompatibilityTest(unittest.TestCase):
    """(c) bin/rein 하위호환 + 서브커맨드 end-to-end (subprocess, 무해 입력만)."""

    def _run_rein(self, argv, payload_text, cwd, extra_env=None):
        env = dict(os.environ)
        env.pop(_ENV_POLICY_DIR, None)
        env.pop(_ENV_DB_PATH, None)
        env.update(extra_env or {})
        return subprocess.run(
            [sys.executable, _BIN_REIN] + list(argv),
            input=payload_text,
            capture_output=True,
            text=True,
            cwd=cwd,
            env=env,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
        )

    def test_no_args_event_evaluation_contract_unchanged(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = self._run_rein(
                [], json.dumps(_tool_pre_payload("Bash")), cwd=workdir
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            response = json.loads(proc.stdout)
            for field in (
                "decision",
                "reason",
                "policy",
                "missing_requirements",
                "evidence_refs",
                "facts",
            ):
                self.assertIn(field, response)
            self.assertEqual(response["decision"], "ALLOW")
            # 기본 실행은 산출물을 남기지 않는다 (Task 1.1 계약 회귀 확인)
            self.assertEqual(os.listdir(workdir), [])

    def test_doctor_subcommand_end_to_end(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = self._run_rein(["doctor"], "", cwd=workdir)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        report = json.loads(proc.stdout)
        self.assertIn("config", report)
        self.assertIn("policy", report)
        self.assertIn("storage", report)
        self.assertFalse(report["config"]["configured"])

    def test_explain_subcommand_end_to_end(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = self._run_rein(
                ["explain", json.dumps(_tool_pre_payload("Read"))],
                "",
                cwd=workdir,
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        report = json.loads(proc.stdout)
        self.assertIn("basis", report)
        self.assertEqual(report["decision"], "ALLOW")
        self.assertEqual(report["method"], "re-evaluation")

    def test_unknown_subcommand_is_rejected(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = self._run_rein(["bogus"], "", cwd=workdir)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("bogus", proc.stderr)


class FailClosedMappingTest(unittest.TestCase):
    """(d) 미포착 예외 주입 → BLOCK JSON + 판단 불능 reason.

    subprocess 를 쓰지 않는다 — `rein.cli.run_event` 를 in-process 로
    mock 해 예외를 주입한다(worker 지침 — subprocess 로 bin/rein 을
    실행하는 테스트는 무해 입력만 사용). malformed policy 를 통한 실제
    `PolicyLoadError` 재현(리뷰어 repro 그대로)은 아래
    `PolicyLoadErrorMapsToBlockTest`(subprocess, 무해 YAML)가 담당한다 —
    이 클래스는 순수 in-process 예외 주입만 다룬다.
    """

    def _run_main_with_stdin(self, payload_text):
        bin_rein = _load_bin_rein_module()
        buffer = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(payload_text)):
            # 인자 없는 이벤트 평가 경로를 시뮬레이션 — pytest 자신의
            # argv(테스트 파일 경로 등)가 서브커맨드로 오인되지 않게
            # 명시적으로 무인자 상태로 고정한다.
            with mock.patch.object(sys, "argv", ["rein"]):
                with redirect_stdout(buffer):
                    exit_code = bin_rein.main()
        return exit_code, buffer.getvalue()

    def test_unhandled_exception_maps_to_block_not_silent_allow(self):
        payload_text = json.dumps(_tool_pre_payload("Bash"))
        with mock.patch("rein.cli.run_event", side_effect=RuntimeError("boom")):
            exit_code, stdout_text = self._run_main_with_stdin(payload_text)
        # exit 0 — BLOCK 은 exit code 가 아니라 JSON 본문으로 표현되는
        # 기존 decision 왕복 계약과 일치해야 hook 소비자가 그대로 파싱한다.
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response["decision"], "BLOCK")
        self.assertIn("judgement failure", response["reason"])
        self.assertIn("boom", response["reason"])
        for field in ("policy", "missing_requirements", "evidence_refs"):
            self.assertIn(field, response)
        self.assertIsNone(response["policy"])
        self.assertEqual(response["missing_requirements"], [])
        self.assertEqual(response["evidence_refs"], [])

    def test_json_decode_error_keeps_existing_nonzero_exit_contract(self):
        """순수 JSON 파싱 실패는 기존 계약(exit 1, stdout 비움) 그대로.

        (2026-08-11 리뷰 High 이후에도 이 두 예외 — JSONDecodeError /
        UnknownHookEventError — 만은 exit 1 범위에 남는다. 회귀 확인.)
        """
        exit_code, stdout_text = self._run_main_with_stdin("not valid json")
        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout_text, "")

    def test_unknown_hook_event_keeps_existing_nonzero_exit_contract(self):
        """미지원 hook_event_name 도 순수 입력 결함 — exit 1 그대로."""
        payload_text = json.dumps(
            {"hook_event_name": "TotallyUnsupportedHook"}
        )
        exit_code, stdout_text = self._run_main_with_stdin(payload_text)
        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout_text, "")

    def test_policy_load_error_no_longer_falls_into_exit_one_bucket(self):
        """PolicyLoadError(ValueError 하위) 는 이제 exit 1 이 아니라 BLOCK.

        리뷰 High 이 지적한 핵심: `except ValueError` 로 넓게 잡으면
        `PolicyLoadError` 도 여기 걸려 exit 1(조용한 ALLOW)로 샜다. 실제
        subprocess 재현은 `PolicyLoadErrorMapsToBlockTest` 가 맡고, 이
        테스트는 in-process 로 그 예외 타입 자체가 더는 exit-1 분기를
        타지 않음을 빠르게 고정한다.
        """
        from rein.kernel.policy import PolicyLoadError

        payload_text = json.dumps(_tool_pre_payload("Bash"))
        with mock.patch(
            "rein.cli.run_event",
            side_effect=PolicyLoadError("<test>: unsupported policy field"),
        ):
            exit_code, stdout_text = self._run_main_with_stdin(payload_text)
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response["decision"], "BLOCK")

    def test_exception_message_is_masked_before_emission(self):
        """Medium 2 — BLOCK reason 의 예외 문자열이 마스킹 SSOT 를 거친다.

        `rein.shadow.masking` 이 이미 마스킹 대상으로 고정한 형태
        (`KEYWORD=value`, tests/unit/test_masking_engine.py 의 v1 case 2
        와 동일 클래스)를 예외 메시지에 심어, BLOCK reason 에는 원문
        토큰이 아니라 `<REDACTED>` 만 남는지 확인한다.
        """
        from rein.shadow.masking import MASK_TOKEN

        secret_value = "ghp_abcdef1234567890"
        payload_text = json.dumps(_tool_pre_payload("Bash"))
        with mock.patch(
            "rein.cli.run_event",
            side_effect=RuntimeError(
                "upstream call failed: GITHUB_TOKEN=" + secret_value
            ),
        ):
            exit_code, stdout_text = self._run_main_with_stdin(payload_text)
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response["decision"], "BLOCK")
        self.assertNotIn(secret_value, response["reason"])
        self.assertIn(MASK_TOKEN, response["reason"])


class PolicyLoadErrorMapsToBlockTest(unittest.TestCase):
    """High 1 — 리뷰어 재현 경로(malformed policy 주입) 그대로 subprocess 로 확인.

    손상된 policy YAML 은 악성 입력이 아니라 단순 스키마 위반이므로
    subprocess 로 실행해도 worker 지침의 "무해 입력만" 제약과 충돌하지
    않는다(`_MALFORMED_POLICY_YAML` 상수 주석 참조).
    """

    def test_malformed_policy_injection_maps_to_block_not_exit_one(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            os.mkdir(policy_dir)
            with open(
                os.path.join(policy_dir, "10-broken.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(_MALFORMED_POLICY_YAML)

            env = dict(os.environ)
            env.pop(_ENV_DB_PATH, None)
            env[_ENV_POLICY_DIR] = policy_dir
            proc = subprocess.run(
                [sys.executable, _BIN_REIN],
                input=json.dumps(_tool_pre_payload("Bash")),
                capture_output=True,
                text=True,
                cwd=project_root,
                env=env,
                timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            )
        # 리뷰 이전 결함: exit 1 + 빈 stdout(조용한 ALLOW). 수정 후에는
        # exit 0 + BLOCK JSON 이어야 한다.
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response["decision"], "BLOCK")
        self.assertIn("judgement failure", response["reason"])


if __name__ == "__main__":
    unittest.main()
