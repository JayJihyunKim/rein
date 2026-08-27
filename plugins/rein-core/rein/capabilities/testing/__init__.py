"""Testing capability — tests_passed Evidence 자격 4조건 (spec §5.2).

spec §5.2: 선언된 명령 / runtime_verified 만(spawn + exit code 직접
관측) / subject=실행 시점 digest / 실행 중 변경 무효 — 4조건 전부 충족
시에만 발급.

공개 표면 재노출만 한다 — import 는 어떤 등록 부작용도 만들지 않는다
(등록은 `register_tests_passed` 명시 호출만, spec §3.1 §32).
"""
from rein.capabilities.testing.capability import (
    CONFIG_RELATIVE_PATH,
    FACT_CHANGESET_DIGEST,
    FACT_CHANGESET_TAG,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    REQUIREMENT_NAME,
    ChangesetTagMismatch,
    TestCommand,
    TestingConfig,
    TestingConfigError,
    TestRunDigestMismatch,
    TestRunFailed,
    TestRunSpawnError,
    TestsPassedEvidenceRefusal,
    TestsPassedRequirement,
    UndeclaredTestCommand,
    VERDICT_PASS,
    find_declared_command,
    load_testing_config,
    observe_test_run,
    parse_testing_config,
    register_tests_passed,
)

__all__ = (
    "CONFIG_RELATIVE_PATH",
    "FACT_CHANGESET_DIGEST",
    "FACT_CHANGESET_TAG",
    "FACT_POLICY_COMPATIBLE_VERSIONS",
    "FACT_POLICY_VERSION",
    "REQUIREMENT_NAME",
    "ChangesetTagMismatch",
    "TestCommand",
    "TestingConfig",
    "TestingConfigError",
    "TestRunDigestMismatch",
    "TestRunFailed",
    "TestRunSpawnError",
    "TestsPassedEvidenceRefusal",
    "TestsPassedRequirement",
    "UndeclaredTestCommand",
    "VERDICT_PASS",
    "find_declared_command",
    "load_testing_config",
    "observe_test_run",
    "parse_testing_config",
    "register_tests_passed",
)
