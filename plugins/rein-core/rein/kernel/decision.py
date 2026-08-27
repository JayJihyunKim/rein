"""Decision — 평가 결과 (spec §3.4).

Decision 값은 ALLOW / BLOCK / ASK_USER 3종. 직렬화는 `decision`·`reason`·
`policy`·`missing_requirements`·`evidence_refs` 5필드를 값이 비어도 항상
포함한다 — 소비자(platform adapter·shadow record)가 필드 존재를 전제할 수
있게 하는 계약이다.
"""
from dataclasses import dataclass

DECISION_ALLOW = "ALLOW"
DECISION_BLOCK = "BLOCK"
DECISION_ASK_USER = "ASK_USER"
DECISIONS = (DECISION_ALLOW, DECISION_BLOCK, DECISION_ASK_USER)


@dataclass(frozen=True)
class Decision:
    """단일 평가 결과. missing_requirements / evidence_refs 는 tuple 로 정규화."""

    decision: str
    reason: str
    policy: str = None
    missing_requirements: tuple = ()
    evidence_refs: tuple = ()

    def __post_init__(self):
        if self.decision not in DECISIONS:
            raise ValueError(
                "decision 은 {} 중 하나여야 한다: {!r}".format(
                    "/".join(DECISIONS), self.decision
                )
            )
        for name in ("missing_requirements", "evidence_refs"):
            value = getattr(self, name)
            if isinstance(value, (str, bytes)):
                # tuple("abc") == ("a","b","c") — 문자 단위 분해를 조용히
                # 직렬화하는 대신 명시 거부한다
                raise ValueError(
                    "{} 는 이름의 목록이어야 한다 (단일 문자열 금지): {!r}".format(
                        name, value
                    )
                )
        object.__setattr__(
            self, "missing_requirements", tuple(self.missing_requirements or ())
        )
        object.__setattr__(self, "evidence_refs", tuple(self.evidence_refs or ()))

    def to_dict(self):
        """직렬화 — 최소 5필드를 항상 포함한다 (spec §3.4). 매 호출 새 객체."""
        return {
            "decision": self.decision,
            "reason": self.reason,
            "policy": self.policy,
            "missing_requirements": list(self.missing_requirements),
            "evidence_refs": list(self.evidence_refs),
        }
