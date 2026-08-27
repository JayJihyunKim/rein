"""Review capability — code_review Evidence 의 Runtime 발급 + digest 결합.

spec §3.6 (§12): 기본 subject = code digest. Reviewer PASS 반환만으로
Evidence 자동 인정 안 됨 — Runtime 이 현재 digest 와 결합해 발급.

공개 표면 재노출만 한다 — import 는 어떤 등록 부작용도 만들지 않는다
(등록은 `register_code_review` 명시 호출만, spec §3.1 §32).
"""
from rein.capabilities.review.capability import (
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    MalformedReviewResponse,
    REQUIREMENT_NAME,
    ReviewDigestMismatch,
    ReviewEvidenceRefusal,
    ReviewVerdictNotPass,
    VERDICT_PASS,
    CodeReviewRequirement,
    issue_code_review_evidence,
    register_code_review,
)

__all__ = (
    "FACT_CHANGESET_REVIEW_DIGEST",
    "FACT_POLICY_COMPATIBLE_VERSIONS",
    "FACT_POLICY_VERSION",
    "MalformedReviewResponse",
    "REQUIREMENT_NAME",
    "ReviewDigestMismatch",
    "ReviewEvidenceRefusal",
    "ReviewVerdictNotPass",
    "VERDICT_PASS",
    "CodeReviewRequirement",
    "issue_code_review_evidence",
    "register_code_review",
)
