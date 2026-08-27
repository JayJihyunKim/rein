"""Task capability — active_task 의 fact 결합 판정 (spec §3.6, §6.3).

spec §3.6 (§10): 현재 변경이 정의된 Task/DoD 에 속하는지 검증. DoD 전체
생성 시스템과는 분리 — v2.0 Core 에는 검증만 포함. "무관 파일 편집은
막히지 않는다" 는 v1.6.5 관련성 판정 행위를 계승한다 (§6.3).

공개 표면 재노출만 한다 — import 는 어떤 등록 부작용도 만들지 않는다
(등록은 `register_active_task` 명시 호출만, spec §3.1 §32).
"""
from rein.capabilities.task.capability import (
    ActiveTaskRequirement,
    FACT_CHANGESET_TASK_RELEVANT,
    FACT_TASK_ACTIVE,
    REQUIREMENT_NAME,
    register_active_task,
)

__all__ = (
    "ActiveTaskRequirement",
    "FACT_CHANGESET_TASK_RELEVANT",
    "FACT_TASK_ACTIVE",
    "REQUIREMENT_NAME",
    "register_active_task",
)
