"""Requirement — 고정 5종 Runtime Contract 어휘 (spec §3.4).

v2.0 의 Requirement 이름은 아래 5종으로 폐쇄된다. 프로젝트 YAML 이 임의
Requirement 이름을 선언하는 것은 비지원 — policy `require:` 에 5종 밖
이름이 등장하면 로드 시점에 명시 에러를 낸다 (`validate_requirement_names`).

kernel 은 구현체·플랫폼을 모른다 (spec §3.1 의존 규칙) — 여기에는 이름
계약, 인터페이스, 로드 시점 검증 API 만 둔다. 구현체 배선은
`rein.engine.registry` 의 명시적 코드 등록으로만 이루어진다 (§32).
"""
import abc

# Runtime Contract 고정 5종 (spec §3.4). 순서도 계약의 일부로 고정한다.
REQUIREMENT_NAMES = (
    "active_task",
    "tests_passed",
    "code_review",
    "security_review",
    "user_approval",
)


class UnknownRequirementError(ValueError):
    """policy `require:` 에 5종 밖 이름 등장 — 로드 시점 명시 에러.

    unknown_names: 거부된 이름 tuple (등장 순서 유지).
    source: 원인 위치 라벨 (예: policy 파일 경로). 에러 메시지에 포함된다.
    """

    def __init__(self, unknown_names, source=None):
        self.unknown_names = tuple(unknown_names)
        self.source = source
        prefix = "{}: ".format(source) if source else ""
        super(UnknownRequirementError, self).__init__(
            "{}unknown requirement name(s): {} — v2.0 supports only the "
            "fixed contract set [{}] (spec §3.4); project-declared custom "
            "requirement names are not supported".format(
                prefix,
                ", ".join(repr(name) for name in self.unknown_names),
                ", ".join(REQUIREMENT_NAMES),
            )
        )


def is_requirement_name(name):
    """이름이 고정 5종 계약에 속하는지 — 비발생(raise 없는) 어휘 질의."""
    return name in REQUIREMENT_NAMES


def validate_requirement_names(names, source=None):
    """policy `require:` 목록의 로드 시점 검증 API (spec §3.4).

    5종 밖 이름이 하나라도 있으면 전부 모아 UnknownRequirementError 를
    던진다. 통과 시 입력 순서를 보존한 tuple 로 정규화해 반환한다.
    로더(Task 1.7 runtime 배선)는 policy 파싱 직후 이 함수를 호출한다.
    """
    names = tuple(names)
    unknown = tuple(
        name for name in names if name not in REQUIREMENT_NAMES
    )
    if unknown:
        raise UnknownRequirementError(unknown, source=source)
    return names


class Requirement(abc.ABC):
    """Capability 가 구현하는 Requirement 인터페이스 (Runtime Contract).

    Requirement 별 세부 계약(spec §3.6 — subject digest, producer 등급 등)
    은 각 capability 태스크에서 구체화된다. kernel 은 이름과 평가 진입점
    만 계약한다.
    """

    @property
    @abc.abstractmethod
    def name(self):
        """고정 5종 중 자신의 계약 이름 (REQUIREMENT_NAMES 원소)."""

    @abc.abstractmethod
    def evaluate(self, context):
        """평가 컨텍스트를 받아 requirement 충족 여부를 판단한다."""
