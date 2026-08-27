"""Phase 6 Task 6.C — policy version 메타데이터 로더 테스트 (spec §3.4).

kernel/policy.py 의 Policy Versioning 확장(`PolicyVersion`/
`parse_policy_version`/`load_policy_version`)을 고정한다. fixture 는
tempfile 로 실 로더 경로에 태운다 (저장소 트리에 fixture 파일을 남기지
않는다 — `test_policy_loader_closure.py` 관례 계승, 워커 scope 계약).

이 파일이 특히 고정하는 계약(활성 DoD 검증 기준의 핵심 문구):
"policy version bump 후 기존 evidence 재평가 → 미충족 판정" —
`PolicyVersionBumpInvalidatesEvidenceTest` 가 `kernel.evidence.
policy_version_valid` 를 실제로 호출해(재구현하지 않고 그대로 조합)
이 계약을 end-to-end 로 고정한다. 이것이 code_review/security_review/
tests_passed/user_approval 4개 capability 가 evaluate() 에서 실제로
수행하는 것과 동일한 순서(현재 버전 로드 → evidence.policy_version 과
대조)다.
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

from rein.kernel import policy  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    policy_version_valid,
)


class _TempVersionDir(object):
    """`_version.yaml` fixture(옵션)를 임시 디렉토리에 써서 실 로더에 태운다.

    `text=None` 이면 파일 자체를 만들지 않는다 — "버전 파일 부재" 케이스
    fixture.
    """

    def __init__(self, text=None):
        self._text = text
        self._tempdir = None

    def __enter__(self):
        self._tempdir = tempfile.TemporaryDirectory()
        if self._text is not None:
            path = os.path.join(self._tempdir.name, policy.VERSION_FILENAME)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(self._text)
        return self._tempdir.name

    def __exit__(self, *exc_info):
        self._tempdir.cleanup()


class ParsePolicyVersionTest(unittest.TestCase):
    """`parse_policy_version(text, source)` — 인라인 문자열 직결 경로."""

    def test_version_only_parses(self):
        result = policy.parse_policy_version("version: 1\n", source="<test>")
        self.assertEqual(
            result, policy.PolicyVersion(version="1", compatible_versions=())
        )

    def test_compatible_versions_parses_in_declared_order(self):
        text = "version: 3\ncompatible_versions:\n  - 1\n  - 2\n"
        result = policy.parse_policy_version(text, source="<test>")
        self.assertEqual(result.version, "3")
        self.assertEqual(result.compatible_versions, ("1", "2"))

    def test_missing_version_field_is_load_time_error(self):
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "compatible_versions:\n  - 1\n", source="<test>"
            )
        self.assertIn("version", str(caught.exception))

    def test_empty_version_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.parse_policy_version('version: ""\n', source="<test>")

    def test_inline_code_in_version_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "version: $(evil)\n", source="<test>"
            )
        self.assertIn("inline code", str(caught.exception))

    def test_version_pattern_mismatch_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.parse_policy_version(
                'version: "has space"\n', source="<test>"
            )

    def test_unsupported_field_is_load_time_error(self):
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "version: 1\nextra: yes\n", source="<test>"
            )
        self.assertIn("extra", str(caught.exception))

    def test_compatible_versions_must_be_a_block_sequence(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.parse_policy_version(
                "version: 1\ncompatible_versions: notalist\n",
                source="<test>",
            )

    def test_compatible_versions_entry_must_be_nonempty_string(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.parse_policy_version(
                'version: 2\ncompatible_versions:\n  - ""\n',
                source="<test>",
            )

    def test_compatible_versions_entry_inline_code_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "version: 2\ncompatible_versions:\n  - $(evil)\n",
                source="<test>",
            )
        self.assertIn("inline code", str(caught.exception))

    def test_compatible_versions_entry_pattern_mismatch_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.parse_policy_version(
                'version: 2\ncompatible_versions:\n  - "has space"\n',
                source="<test>",
            )

    def test_compatible_versions_duplicate_entry_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "version: 3\ncompatible_versions:\n  - 1\n  - 1\n",
                source="<test>",
            )
        self.assertIn("duplicate", str(caught.exception))

    def test_compatible_versions_self_reference_is_rejected(self):
        # 모듈 docstring "fail-closed" 절 — 자기 자신을 compatible_versions
        # 에 포함하는 것은 무의미한 선언이므로 "쓰레기 값"으로 거부한다.
        with self.assertRaises(policy.PolicyVersionError) as caught:
            policy.parse_policy_version(
                "version: 1\ncompatible_versions:\n  - 1\n", source="<test>"
            )
        self.assertIn("itself", str(caught.exception))


class LoadPolicyVersionTest(unittest.TestCase):
    """`load_policy_version(policy_dir)` — 파일 시스템 경로."""

    def test_loads_from_directory(self):
        with _TempVersionDir("version: 5\n") as policy_dir:
            result = policy.load_policy_version(policy_dir)
        self.assertEqual(
            result, policy.PolicyVersion(version="5", compatible_versions=())
        )

    def test_missing_version_file_is_load_time_error(self):
        with _TempVersionDir(None) as policy_dir:
            with self.assertRaises(policy.PolicyVersionError) as caught:
                policy.load_policy_version(policy_dir)
            self.assertIn(policy.VERSION_FILENAME, str(caught.exception))

    def test_none_policy_dir_is_rejected(self):
        # 모듈 docstring — 빈 policy_dir 은 load_policies([]) 의 "정책
        # 0개" 관례와 의도적으로 다르다. 버전 부재를 조용히 흡수하지
        # 않는다.
        with self.assertRaises(policy.PolicyVersionError):
            policy.load_policy_version(None)

    def test_empty_string_policy_dir_is_rejected(self):
        with self.assertRaises(policy.PolicyVersionError):
            policy.load_policy_version("")

    def test_error_names_the_version_file_path(self):
        with _TempVersionDir("compatible_versions:\n  - 1\n") as policy_dir:
            with self.assertRaises(policy.PolicyVersionError) as caught:
                policy.load_policy_version(policy_dir)
            expected_path = os.path.join(policy_dir, policy.VERSION_FILENAME)
            self.assertIn(expected_path, str(caught.exception))


class PolicyVersionValueObjectTest(unittest.TestCase):
    """`PolicyVersion` 값 객체 자체의 방어 계약."""

    def test_single_string_compatible_versions_is_rejected(self):
        # kernel.evidence.policy_version_valid 와 동일한 방어 —
        # tuple("1.0") == ("1", ".", "0") 오인정을 값 객체 생성 시점에도
        # 차단한다.
        with self.assertRaises(TypeError):
            policy.PolicyVersion(version="2", compatible_versions="1")

    def test_compatible_versions_normalizes_to_tuple(self):
        result = policy.PolicyVersion(version="2", compatible_versions=["1"])
        self.assertEqual(result.compatible_versions, ("1",))

    def test_default_compatible_versions_is_empty_tuple(self):
        result = policy.PolicyVersion(version="1")
        self.assertEqual(result.compatible_versions, ())

    def test_policy_version_error_is_a_policy_load_error(self):
        # 호출자가 "policy 설정이 뭔가 깨졌다"를 단일 except 로 뭉뚱그려
        # 잡을 수 있는 catch 표면을 유지한다 (load_policies/
        # load_policy_file 과 동일 원칙).
        self.assertTrue(
            issubclass(policy.PolicyVersionError, policy.PolicyLoadError)
        )


class LoadPoliciesSkipsReservedVersionFileTest(unittest.TestCase):
    """`load_policies(policy_dir)` 는 예약 버전 파일을 정책으로 파싱하지 않는다.

    `policies/default/` 처럼 4필드 policy 파일과 `_version.yaml` 이 같은
    디렉토리에 물리적으로 공존해도, `load_policies()` 는 버전 파일을
    건너뛰고(정책 목록에 나타나지 않는다) 나머지 실 정책 파일은 정상
    로드한다.
    """

    _VALID_POLICY = (
        "trigger: tool.pre\n"
        "when:\n"
        "  command.type: git.commit\n"
        "require:\n"
        "  - code_review\n"
        "failure_mode: closed\n"
    )

    def test_version_file_is_excluded_from_loaded_policies(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            with open(
                os.path.join(policy_dir, "commit.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(self._VALID_POLICY)
            # 이 버전 파일은 4필드 스키마로는 명백히 깨져 있다(version
            # 필드는 policy 스키마에 없는 필드) — load_policies() 가
            # 실제로 "건너뛴다"(파싱을 시도하지 않는다)는 것을, 만약
            # 파싱을 시도했다면 반드시 실패했을 내용으로 실증한다.
            with open(
                os.path.join(policy_dir, policy.VERSION_FILENAME),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("version: 1\n")

            loaded = policy.load_policies(policy_dir)

        self.assertEqual(
            [entry["policy_id"] for entry in loaded], ["commit"]
        )


class PolicyVersionBumpInvalidatesEvidenceTest(unittest.TestCase):
    """활성 DoD 검증 기준 — "policy version bump 후 기존 evidence 재평가
    → 미충족 판정" 을 실 로더(`load_policy_version`) + 실 kernel 판정
    함수(`policy_version_valid`)를 조합해 end-to-end 로 고정한다.

    `load_policy_version()` 자체는 evidence 를 모른다(kernel.policy 는
    versioning 메타 데이터만 다룬다, spec §3.1) — 이 테스트가 검증하는
    것은 두 kernel 모듈(policy.py + evidence.py)이 capability 코드와
    동일한 순서(현재 버전 로드 → evidence.policy_version 과 대조)로
    조합됐을 때 실제로 계약대로 동작하는가이다.
    """

    def _evidence(self, version):
        return Evidence(
            type="code_review",
            subject="digest-abc",
            result="PASS",
            created_at="2026-08-12T00:00:00+00:00",
            producer=PRODUCER_AGENT_ATTESTED,
            policy_version=version,
        )

    def test_evidence_from_before_bump_is_invalid_without_compat_declaration(
        self,
    ):
        # v1 하에서 발급된 evidence.
        evidence = self._evidence("1")
        # 운영자가 v2 로 bump — compatible_versions 를 선언하지 않았다
        # (spec §3.4 "기본 원칙" — 명시 선언이 없으면 무효).
        with _TempVersionDir("version: 2\n") as policy_dir:
            current = policy.load_policy_version(policy_dir)
        self.assertFalse(
            policy_version_valid(
                evidence, current.version, current.compatible_versions
            )
        )

    def test_evidence_from_before_bump_stays_valid_with_explicit_compat(
        self,
    ):
        evidence = self._evidence("1")
        with _TempVersionDir(
            "version: 2\ncompatible_versions:\n  - 1\n"
        ) as policy_dir:
            current = policy.load_policy_version(policy_dir)
        self.assertTrue(
            policy_version_valid(
                evidence, current.version, current.compatible_versions
            )
        )

    def test_evidence_matching_current_version_is_always_valid(self):
        evidence = self._evidence("2")
        with _TempVersionDir("version: 2\n") as policy_dir:
            current = policy.load_policy_version(policy_dir)
        self.assertTrue(
            policy_version_valid(
                evidence, current.version, current.compatible_versions
            )
        )

    def test_second_bump_drops_first_bump_compat_unless_redeclared(self):
        # v1 evidence, v2 가 v1 을 compat 선언했지만, v3 로 다시 bump
        # 하면서 compat 선언을 v2 만 남기고 v1 을 빠뜨리면 v1 evidence
        # 는 다시 무효가 된다 — "한 번 호환 선언되면 영구히 유효"가
        # 아니라 매 bump 시점의 명시 선언이 그때그때 정본이다.
        evidence = self._evidence("1")
        with _TempVersionDir(
            "version: 3\ncompatible_versions:\n  - 2\n"
        ) as policy_dir:
            current = policy.load_policy_version(policy_dir)
        self.assertFalse(
            policy_version_valid(
                evidence, current.version, current.compatible_versions
            )
        )


if __name__ == "__main__":
    unittest.main()
