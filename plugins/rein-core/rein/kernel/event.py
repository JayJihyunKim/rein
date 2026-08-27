"""Event — 플랫폼 중립 이벤트 (spec §3.2).

Event 는 작게 유지한다: `commit.requested` 류 Domain Event 는 kernel 어휘에
추가하지 않는다. 도메인 의미는 Fact 로 표현한다 —

    event = tool.pre
    facts: tool.type=bash, command.type=git.commit

kernel 은 Claude·Git·SQLite 를 모른다 (spec §3.1). 플랫폼 hook 이름의 중립
이벤트 변환은 platform adapter 소관이다 — native 이름은 kernel 소스에
문자열로도 존재하지 않는다 (plan Task 1.8 격리 계약).
"""
from dataclasses import dataclass, field

# kernel 이 아는 중립 이벤트 어휘 전부 (spec §3.1 의 명시 매핑).
# 확장은 이 tuple 의 의도적 편집으로만 한다 — runtime 등록 API 는 두지 않는다
# (Domain Event 금지 계약을 코드로 고정하기 위함).
EVENT_TYPES = (
    "tool.pre",
    "tool.post",
    "task.created",
    "task.completed",
    "agent.started",
    "agent.stopped",
    # 세션 계열 (plan Task 1.8) — 세션 수명주기 2종 + 세션의 실행 정지
    # 시도 1종. session.stop 은 정지 시도 가로채기 지점이다 — 플랫폼별
    # 응답 강등 규칙(spec §2.4)은 platform adapter 소유이고 kernel 은
    # 그 존재를 모른다.
    "session.started",
    "session.stop",
    "session.ended",
)


class DomainEventError(ValueError):
    """kernel 어휘 밖 event type 생성 시도 (spec §3.2 Domain Event 금지)."""


@dataclass(frozen=True)
class Event:
    """중립 이벤트. payload 는 platform adapter 가 정규화해 넘긴 원시 입력."""

    type: str
    payload: dict = field(default_factory=dict)

    def __post_init__(self):
        if self.type not in EVENT_TYPES:
            raise DomainEventError(
                "event type {!r} 는 kernel 이벤트 어휘가 아니다 — Domain Event "
                "는 만들지 않는다 (spec §3.2). 의미는 Fact 로 표현하라 (예: "
                "event=tool.pre, facts: command.type=git.commit). 허용 type: "
                "{}".format(self.type, ", ".join(EVENT_TYPES))
            )
