"""Security capability — security_review Evidence 의 Runtime 발급 + sensitive digest 결합.

spec §3.6 (§14): sensitive ChangeSet digest 대상. code_review 와 상호
직접 호출 금지 — Policy 가 조합.

공개 표면 재노출만 한다 — import 는 어떤 등록 부작용도 만들지 않는다
(등록은 `register_security_review` 명시 호출만, spec §3.1 §32).
"""
from rein.capabilities.security.capability import (
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    MalformedSecurityReviewResponse,
    REQUIREMENT_NAME,
    SecurityReviewDigestMismatch,
    SecurityReviewEvidenceRefusal,
    SecurityReviewVerdictNotPass,
    VERDICT_PASS,
    SecurityReviewRequirement,
    issue_security_review_evidence,
    register_security_review,
)

__all__ = (
    "FACT_CHANGESET_SENSITIVE_DIGEST",
    "FACT_POLICY_COMPATIBLE_VERSIONS",
    "FACT_POLICY_VERSION",
    "MalformedSecurityReviewResponse",
    "REQUIREMENT_NAME",
    "SecurityReviewDigestMismatch",
    "SecurityReviewEvidenceRefusal",
    "SecurityReviewVerdictNotPass",
    "VERDICT_PASS",
    "SecurityReviewRequirement",
    "issue_security_review_evidence",
    "register_security_review",
)
