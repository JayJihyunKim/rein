"""RequirementRegistry — 명시적 코드 등록 (spec §3.1 §32).

Registry 는 명시적이다: capability 구현체는 코드에서 `register()` 로 직접
등록한다. dynamic external plugin discovery 는 v2.x — 여기서는 지원하지
않는다. Phase 1 시점에는 어떤 구현체도 등록되어 있지 않다 (stub 등록
금지) — 등록은 각 capability 태스크가 수행한다.

계약 이름 조회(고정 5종, 항상 존재)와 구현체 조회(미등록 구분)는 다른
질의다: 전자는 kernel 어휘(REQUIREMENT_NAMES), 후자는 이 registry 의
등록 상태를 본다.
"""
from ..kernel.requirement import (
    REQUIREMENT_NAMES,
    UnknownRequirementError,
    validate_requirement_names,
)


class UnregisteredRequirementError(LookupError):
    """계약 이름은 유효하나 구현체가 아직 등록되지 않음.

    5종 밖 이름(UnknownRequirementError)과는 다른 부류다 — 이 에러는
    "계약은 존재하지만 해당 capability 가 아직 배선되지 않았다" 를 뜻한다.
    """

    def __init__(self, name):
        self.name = name
        super(UnregisteredRequirementError, self).__init__(
            "requirement {!r} is a valid contract name but has no "
            "registered implementation — registration is explicit and "
            "performed by each capability (spec §3.1 §32)".format(name)
        )


class RequirementRegistry:
    """고정 5종 계약에 대한 구현체의 명시적 등록·조회."""

    def __init__(self):
        self._implementations = {}

    # -- 계약 어휘 질의 (항상 성공하는 비발생 질의) ---------------------

    def contract_names(self):
        """고정 5종 계약 이름 (spec §3.4) — 등록 여부와 무관하게 존재."""
        return REQUIREMENT_NAMES

    def has_contract(self, name):
        """이름이 고정 5종 계약에 속하는지 (bool, raise 없음)."""
        return name in REQUIREMENT_NAMES

    # -- 구현체 등록·조회 (폐쇄 강제) -----------------------------------

    def register(self, name, implementation):
        """capability 구현체를 명시적으로 등록한다.

        - 5종 밖 이름 → UnknownRequirementError (폐쇄 계약)
        - 중복 등록 → ValueError (silent override 금지)
        - 구현체가 name 속성을 가지면 등록 이름과 일치해야 한다
        """
        validate_requirement_names((name,), source="registry.register")
        if name in self._implementations:
            raise ValueError(
                "requirement {!r} already has a registered implementation "
                "— duplicate registration is rejected (no silent "
                "override)".format(name)
            )
        implementation_name = getattr(implementation, "name", name)
        if implementation_name != name:
            raise ValueError(
                "implementation name {!r} does not match registration "
                "name {!r}".format(implementation_name, name)
            )
        self._implementations[name] = implementation

    def is_registered(self, name):
        """유효 계약 이름의 등록 여부. 5종 밖 이름은 명시 에러."""
        if name not in REQUIREMENT_NAMES:
            raise UnknownRequirementError((name,), source="registry")
        return name in self._implementations

    def resolve(self, name):
        """등록된 구현체를 반환한다.

        - 5종 밖 이름 → UnknownRequirementError
        - 유효하나 미등록 → UnregisteredRequirementError (구분 계약)
        """
        if name not in REQUIREMENT_NAMES:
            raise UnknownRequirementError((name,), source="registry")
        if name not in self._implementations:
            raise UnregisteredRequirementError(name)
        return self._implementations[name]

    def registered_names(self):
        """현재 등록된 구현체 이름 tuple (REQUIREMENT_NAMES 순서)."""
        return tuple(
            name for name in REQUIREMENT_NAMES
            if name in self._implementations
        )
