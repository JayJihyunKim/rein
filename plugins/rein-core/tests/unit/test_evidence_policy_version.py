"""plan Task 1.6 — Evidence 모델 + policy version 결속 테스트.

spec §3.5 (필드 계약·producer 3등급) + §3.4 Policy Versioning:
Evidence 는 생성 당시 policy version 을 기록하고, 현재 version 과
불일치하면 호환 명시 선언이 없는 한 무효다. Subject digest 는
policy version 과 독립이다. validity 판정은 순수 로직 (storage 비의존).
"""
import dataclasses
import io
import os
import sys
import tokenize
import unittest

# self-locating sys.path 주입 — discover top-level 이 tests/unit 이어도
# plugin root 의 rein 패키지를 import 할 수 있게 한다
# (test_scaffold_roundtrip.py 의 _PLUGIN_ROOT 관례 계승).
_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_RUNTIME_VERIFIED,
    PRODUCER_USER_APPROVED,
    PRODUCERS,
    policy_version_valid,
    subject_matches,
)


def _make_evidence(**overrides):
    fields = {
        "type": "code_review",
        "subject": "digest-abc123",
        "result": "PASS",
        "created_at": "2026-08-08T00:00:00+00:00",
        "producer": PRODUCER_RUNTIME_VERIFIED,
        "policy_version": "1",
    }
    fields.update(overrides)
    return Evidence(**fields)


class EvidenceFieldContractTest(unittest.TestCase):
    def test_field_contract_is_exactly_spec_3_5(self):
        # spec §3.5: type/subject/result/created_at/producer/policy_version/metadata
        names = [f.name for f in dataclasses.fields(Evidence)]
        self.assertEqual(
            names,
            [
                "type",
                "subject",
                "result",
                "created_at",
                "producer",
                "policy_version",
                "metadata",
            ],
        )

    def test_metadata_defaults_to_empty_dict(self):
        self.assertEqual(_make_evidence().metadata, {})

    def test_metadata_instances_are_not_shared(self):
        first = _make_evidence()
        second = _make_evidence()
        self.assertIsNot(first.metadata, second.metadata)

    def test_evidence_is_immutable(self):
        evidence = _make_evidence()
        with self.assertRaises(dataclasses.FrozenInstanceError):
            evidence.policy_version = "2"

    def test_records_policy_version_at_creation(self):
        self.assertEqual(_make_evidence(policy_version="7").policy_version, "7")

    def test_empty_required_fields_are_rejected(self):
        for field in ("type", "subject", "policy_version"):
            with self.assertRaises(ValueError, msg=field):
                _make_evidence(**{field: ""})


class ProducerGradeTest(unittest.TestCase):
    def test_exactly_three_producer_grades(self):
        # spec §3.5: runtime_verified / agent_attested / user_approved
        self.assertEqual(
            PRODUCERS,
            (
                PRODUCER_RUNTIME_VERIFIED,
                PRODUCER_AGENT_ATTESTED,
                PRODUCER_USER_APPROVED,
            ),
        )
        self.assertEqual(PRODUCER_RUNTIME_VERIFIED, "runtime_verified")
        self.assertEqual(PRODUCER_AGENT_ATTESTED, "agent_attested")
        self.assertEqual(PRODUCER_USER_APPROVED, "user_approved")

    def test_each_grade_is_accepted(self):
        for producer in PRODUCERS:
            self.assertEqual(_make_evidence(producer=producer).producer, producer)

    def test_unknown_producer_is_rejected(self):
        with self.assertRaises(ValueError):
            _make_evidence(producer="self_asserted")


class PolicyVersionBindingTest(unittest.TestCase):
    def test_matching_version_is_valid(self):
        evidence = _make_evidence(policy_version="1")
        self.assertTrue(policy_version_valid(evidence, current_version="1"))

    def test_version_bump_invalidates_existing_evidence(self):
        # spec §3.4: 기본 원칙 = Evidence version 과 현재 version 일치.
        evidence = _make_evidence(policy_version="1")
        self.assertFalse(policy_version_valid(evidence, current_version="2"))

    def test_explicit_compat_declaration_keeps_evidence_valid(self):
        # spec §3.4: 호환성을 명시 선언한 경우에만 이전 Evidence 인정.
        evidence = _make_evidence(policy_version="1")
        self.assertTrue(
            policy_version_valid(
                evidence, current_version="2", compatible_versions=("1",)
            )
        )

    def test_compat_declaration_for_other_versions_does_not_help(self):
        evidence = _make_evidence(policy_version="1")
        self.assertFalse(
            policy_version_valid(
                evidence, current_version="3", compatible_versions=("2",)
            )
        )

    def test_no_implicit_compat_from_empty_declaration(self):
        evidence = _make_evidence(policy_version="1")
        self.assertFalse(
            policy_version_valid(
                evidence, current_version="2", compatible_versions=()
            )
        )

    def test_single_string_compat_declaration_is_rejected(self):
        # tuple("1.0") == ("1",".","0") — 문자 단위 오인정 방지 (fail-closed)
        evidence = _make_evidence(policy_version="1")
        with self.assertRaises(TypeError):
            policy_version_valid(
                evidence, current_version="2", compatible_versions="1.0"
            )


class SubjectDigestIndependenceTest(unittest.TestCase):
    def test_subject_digest_is_independent_of_policy_version(self):
        # spec §3.4: Subject digest 는 policy version 과 독립.
        before_bump = _make_evidence(subject="digest-abc123", policy_version="1")
        after_bump = _make_evidence(subject="digest-abc123", policy_version="2")
        self.assertTrue(subject_matches(before_bump, "digest-abc123"))
        self.assertTrue(subject_matches(after_bump, "digest-abc123"))

    def test_subject_mismatch_is_detected_regardless_of_version(self):
        evidence = _make_evidence(subject="digest-abc123", policy_version="1")
        self.assertFalse(subject_matches(evidence, "digest-def456"))
        # version 이 유효해도 subject 판정은 바뀌지 않는다
        self.assertTrue(policy_version_valid(evidence, current_version="1"))
        self.assertFalse(subject_matches(evidence, "digest-def456"))


class KernelPurityTest(unittest.TestCase):
    def test_validity_logic_has_no_storage_or_platform_imports(self):
        # spec §3.1 kernel 의존 규칙 + plan Task 1.6: validity 판정은
        # 순수 로직 — storage 는 Phase 2 소관.
        import rein.kernel.evidence as evidence_module

        source_path = evidence_module.__file__
        with open(source_path, "rb") as handle:
            source = handle.read()
        forbidden = ("sqlite3", "subprocess", "socket", "urllib")
        imported = set()
        tokens = tokenize.tokenize(io.BytesIO(source).readline)
        take_next = False
        for token in tokens:
            if token.type == tokenize.NAME and token.string in ("import", "from"):
                take_next = True
                continue
            if take_next and token.type == tokenize.NAME:
                imported.add(token.string)
            take_next = False
        for name in forbidden:
            self.assertNotIn(name, imported)


if __name__ == "__main__":
    unittest.main()
