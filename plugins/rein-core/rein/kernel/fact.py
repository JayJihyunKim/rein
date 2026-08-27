"""Fact — key=value 사실 (spec §3.2).

도메인 의미는 Event 가 아니라 Fact 에 실린다:
`commit.requested` 라는 Domain Event 대신 `command.type=git.commit` Fact.

Lazy Fact Resolution(cheap/expensive 구분·request-scoped cache)은 engine 의
resolver 소관 — kernel 은 값 운반 계약만 정의한다.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Fact:
    """단일 사실. key 는 `tool.type` 처럼 점 표기 네임스페이스 문자열."""

    key: str
    value: object = None

    def __post_init__(self):
        if not isinstance(self.key, str) or not self.key:
            raise ValueError(
                "Fact.key 는 비어 있지 않은 문자열이어야 한다: {!r}".format(
                    self.key
                )
            )
