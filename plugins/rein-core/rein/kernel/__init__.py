"""Kernel — 모든 레이어가 공유하는 플랫폼 중립 어휘.

kernel 은 Claude·Git·SQLite·특정 agent 를 모른다 (spec §3.1 의존 규칙).

값 정의의 단일 소스는 하위 모듈이다 — 여기는 re-export 만 한다 (plan
Task 1.7 통합 정리: 동일 상수의 이중 정의가 값 divergence 를 만들지
않게). 구 make_decision 헬퍼는 유일 호출부(walking-skeleton runtime)가
Decision 모델로 대체되며 제거됐다 — Decision(...).to_dict() 를 쓴다.
"""
from rein.kernel.decision import (
    DECISION_ALLOW,
    DECISION_ASK_USER,
    DECISION_BLOCK,
    DECISIONS,
    Decision,
)
from rein.kernel.policy import FAILURE_MODES, POLICY_FIELDS

__all__ = [
    "DECISION_ALLOW",
    "DECISION_ASK_USER",
    "DECISION_BLOCK",
    "DECISIONS",
    "Decision",
    "FAILURE_MODES",
    "POLICY_FIELDS",
]
