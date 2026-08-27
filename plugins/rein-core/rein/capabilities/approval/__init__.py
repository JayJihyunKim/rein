"""Approval capability — user_approval 의 one-shot 발급 + action/digest 결속 (spec §3.6 §21).

spec §3.6 (§21): BLOCK 상황의 명시적 승인. 기본 scope = 현재 action +
현재 digest + one-shot. 사용된 Approval 재사용 금지. `.skip-review`/
`.skip-security` 류 marker 우회는 제거.

공개 표면 재노출만 한다 — import 는 어떤 등록 부작용도 만들지 않는다
(등록은 `register_user_approval` 명시 호출만, spec §3.1 §32).
"""
from rein.capabilities.approval.capability import (
    FACT_ACTION_CURRENT,
    FACT_APPROVAL_CONSUMPTION_STORE,
    FACT_CHANGESET_DIGEST,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    METADATA_KEY_ACTION,
    REQUIREMENT_NAME,
    RESULT_APPROVED,
    UserApprovalRequirement,
    issue_user_approval_evidence,
    register_user_approval,
)

__all__ = (
    "FACT_ACTION_CURRENT",
    "FACT_APPROVAL_CONSUMPTION_STORE",
    "FACT_CHANGESET_DIGEST",
    "FACT_POLICY_COMPATIBLE_VERSIONS",
    "FACT_POLICY_VERSION",
    "METADATA_KEY_ACTION",
    "REQUIREMENT_NAME",
    "RESULT_APPROVED",
    "UserApprovalRequirement",
    "issue_user_approval_evidence",
    "register_user_approval",
)
