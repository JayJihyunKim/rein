"""plan Task 1.5 — Requirement 5종 고정 registry 폐쇄 테스트.

spec §3.4: Requirement 는 고정 5종 Runtime Contract. 프로젝트가 선언한
커스텀 이름은 로드 시점 명시 에러로 거부한다.
spec §3.1 (§32): Registry 는 명시적 코드 등록 — dynamic discovery 비지원.
Phase 1 시점 capability 구현체는 미등록 상태다 (stub 등록 금지) — 계약
이름 조회(성공)와 구현체 조회(미등록)는 구분되어야 한다.

로드 경로 배선(Task 1.7 runtime)과 무관하게 검증 API 를 직접 호출해 고정.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine.registry import (  # noqa: E402
    RequirementRegistry,
    UnregisteredRequirementError,
)
from rein.kernel.requirement import (  # noqa: E402
    REQUIREMENT_NAMES,
    Requirement,
    UnknownRequirementError,
    validate_requirement_names,
)

_CONTRACT_FIVE = (
    "active_task",
    "tests_passed",
    "code_review",
    "security_review",
    "user_approval",
)


class _DummyRequirement(Requirement):
    """테스트 전용 구현체 — 명시 등록 경로 검증용 (production stub 아님)."""

    def __init__(self, name):
        self._name = name

    @property
    def name(self):
        return self._name

    def evaluate(self, context):
        return None


class RequirementContractClosureTest(unittest.TestCase):
    """kernel 어휘 — 고정 5종 + 로드 시점 검증 API."""

    def test_contract_names_are_exactly_the_fixed_five(self):
        self.assertEqual(REQUIREMENT_NAMES, _CONTRACT_FIVE)

    def test_each_of_the_five_names_validates(self):
        for name in _CONTRACT_FIVE:
            self.assertEqual(validate_requirement_names([name]), (name,))
        self.assertEqual(
            validate_requirement_names(list(_CONTRACT_FIVE)), _CONTRACT_FIVE
        )

    def test_unknown_name_raises_explicit_load_time_error(self):
        with self.assertRaises(UnknownRequirementError) as caught:
            validate_requirement_names(
                ["code_review", "custom_gate"],
                source="policies/my-policy.yaml",
            )
        error = caught.exception
        self.assertEqual(error.unknown_names, ("custom_gate",))
        message = str(error)
        # 명시 에러: 원인 이름 + 출처 + 허용 집합이 전부 드러나야 한다
        self.assertIn("custom_gate", message)
        self.assertIn("policies/my-policy.yaml", message)
        for name in _CONTRACT_FIVE:
            self.assertIn(name, message)

    def test_multiple_unknown_names_are_reported_together(self):
        with self.assertRaises(UnknownRequirementError) as caught:
            validate_requirement_names(
                ["lint_passed", "tests_passed", "deploy_approved"]
            )
        self.assertEqual(
            caught.exception.unknown_names, ("lint_passed", "deploy_approved")
        )

    def test_project_declared_plausible_custom_name_is_still_rejected(self):
        # 그럴듯한 이름도 5종 밖이면 거부 — 프로젝트 커스텀 선언 비지원
        for custom in ("lint_passed", "docs_review", "qa_signoff"):
            with self.assertRaises(UnknownRequirementError):
                validate_requirement_names([custom])

    def test_requirement_interface_is_abstract(self):
        with self.assertRaises(TypeError):
            Requirement()  # pylint: disable=abstract-class-instantiated
        # name + evaluate 를 갖춘 구현체는 생성 가능
        impl = _DummyRequirement("code_review")
        self.assertEqual(impl.name, "code_review")


class RequirementRegistryClosureTest(unittest.TestCase):
    """engine registry — 명시적 코드 등록, Phase 1 미등록 상태."""

    def setUp(self):
        self.registry = RequirementRegistry()

    def test_contract_lookup_succeeds_for_each_of_the_five(self):
        self.assertEqual(self.registry.contract_names(), _CONTRACT_FIVE)
        for name in _CONTRACT_FIVE:
            self.assertTrue(self.registry.has_contract(name))

    def test_contract_lookup_fails_for_unknown_name(self):
        self.assertFalse(self.registry.has_contract("custom_gate"))

    def test_phase1_default_state_has_no_registered_implementations(self):
        # stub 등록 금지 — 새 registry 는 구현체 0개로 시작해야 한다
        self.assertEqual(self.registry.registered_names(), ())
        for name in _CONTRACT_FIVE:
            with self.assertRaises(UnregisteredRequirementError):
                self.registry.resolve(name)

    def test_unregistered_is_distinct_from_unknown(self):
        # 계약은 있으나 미등록 → UnregisteredRequirementError
        with self.assertRaises(UnregisteredRequirementError) as unregistered:
            self.registry.resolve("code_review")
        self.assertNotIsInstance(
            unregistered.exception, UnknownRequirementError
        )
        # 계약 자체가 없는 이름 → UnknownRequirementError (미등록과 다른 부류)
        with self.assertRaises(UnknownRequirementError) as unknown:
            self.registry.resolve("custom_gate")
        self.assertNotIsInstance(
            unknown.exception, UnregisteredRequirementError
        )

    def test_explicit_registration_then_resolve(self):
        impl = _DummyRequirement("code_review")
        self.registry.register("code_review", impl)
        self.assertIs(self.registry.resolve("code_review"), impl)
        self.assertTrue(self.registry.is_registered("code_review"))
        self.assertEqual(self.registry.registered_names(), ("code_review",))
        # 다른 4종은 여전히 미등록
        for name in _CONTRACT_FIVE:
            if name == "code_review":
                continue
            self.assertFalse(self.registry.is_registered(name))

    def test_register_rejects_name_outside_the_contract(self):
        with self.assertRaises(UnknownRequirementError):
            self.registry.register(
                "custom_gate", _DummyRequirement("custom_gate")
            )
        self.assertEqual(self.registry.registered_names(), ())

    def test_register_rejects_duplicate_registration(self):
        self.registry.register(
            "tests_passed", _DummyRequirement("tests_passed")
        )
        with self.assertRaises(ValueError):
            self.registry.register(
                "tests_passed", _DummyRequirement("tests_passed")
            )

    def test_register_rejects_implementation_name_mismatch(self):
        with self.assertRaises(ValueError):
            self.registry.register(
                "code_review", _DummyRequirement("tests_passed")
            )
        self.assertEqual(self.registry.registered_names(), ())

    def test_is_registered_enforces_contract_closure(self):
        with self.assertRaises(UnknownRequirementError):
            self.registry.is_registered("custom_gate")


if __name__ == "__main__":
    unittest.main()
