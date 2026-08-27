"""Evidence 모델 + policy version 결속 (spec §3.5, §3.4 Policy Versioning).

spec §3.5 필드 계약: `type`, `subject`, `result`, `created_at`, `producer`,
`policy_version`, `metadata`.

spec §3.5 Producer 3등급 (원문 인용):
    "Producer 3등급: `runtime_verified`(Rein 이 직접 확인 — exit code,
    git state, digest) / `agent_attested`(Reviewer/Security Agent 판단) /
    `user_approved`(명시적 사용자 승인). 신뢰 위계는 §2.2 위협 모델
    계약을 따른다."

spec §3.4 Policy Versioning (원문 인용):
    "Evidence 는 생성 당시 policy version 을 기록. 기본 원칙 = Evidence
    version 과 현재 version 일치. 호환성을 명시 선언한 경우에만 이전
    Evidence 인정. Subject digest 는 policy version 과 독립."

spec §2.2 위협 모델 (plan Task 3.3 — 발급 무결성):
    "Agent 가 Evidence 파일(JSON 등)을 직접 생성하는 것만으로는 어떤
    Requirement 도 충족되지 않는다 — Evidence 는 Rein Runtime 만
    발급한다."

이를 고정하는 장치는 **원장(runtime ledger) 대조**다 (사용자 결정:
서명 방식 대비 원장 대조 우선 — fingerprint 는 암호학적 서명이 아니라
발급 레코드와의 대응을 판정하는 canonical 대조 키다). 발급 시 원장에
발급 레코드(`issuance_entry`)를 남기고, 평가(조회) 시 evidence 를
원장과 대조(`issuance_matches`)한다. 대응 발급 레코드가 없는 evidence
는 형식이 완전해도 불인정이다. 원장의 저장·조회는 platform 소관이고
(kernel 은 storage 를 모른다), 여기에는 대응 판정 순수 함수만 둔다.

이 모듈은 kernel 이다 — Claude·Git·SQLite·특정 agent 를 모른다
(spec §3.1 의존 규칙). validity 판정은 전부 순수 함수로 제공하고
storage 접근은 하지 않는다 (storage 는 Phase 2 소관).
"""
import hashlib
import json
from dataclasses import dataclass, field

PRODUCER_RUNTIME_VERIFIED = "runtime_verified"  # Rein 이 직접 확인 — exit code, git state, digest
PRODUCER_AGENT_ATTESTED = "agent_attested"  # Reviewer/Security Agent 판단
PRODUCER_USER_APPROVED = "user_approved"  # 명시적 사용자 승인

# 3등급 폐쇄 집합 — 신뢰 위계 순 (spec §2.2: runtime_verified 와
# agent_attested 의 신뢰 수준은 동일하지 않다).
PRODUCERS = (
    PRODUCER_RUNTIME_VERIFIED,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_USER_APPROVED,
)


@dataclass(frozen=True)
class Evidence:
    """spec §3.5 필드 계약 그대로의 불변 Evidence 레코드.

    `policy_version` 은 생성 당시의 policy version 이다 — 이후 version 이
    bump 되어도 레코드는 갱신되지 않으며, 유효성은 `policy_version_valid`
    가 현재 version 과 비교해 판정한다 (spec §3.4).
    """

    type: str
    subject: str
    result: object
    created_at: str
    producer: str
    policy_version: str
    metadata: dict = field(default_factory=dict)

    def __post_init__(self):
        for name in ("type", "subject", "policy_version"):
            if not getattr(self, name):
                raise ValueError(
                    "Evidence.{} must be a non-empty value".format(name)
                )
        if self.producer not in PRODUCERS:
            raise ValueError(
                "Evidence.producer must be one of {} (spec §3.5 producer "
                "3등급), got {!r}".format(PRODUCERS, self.producer)
            )


def policy_version_valid(evidence, current_version, compatible_versions=()):
    """Evidence 의 policy version 결속 판정 — 순수 함수 (spec §3.4).

    기본 원칙 = Evidence version 과 현재 version 일치. 불일치 시
    `compatible_versions` 에 해당 version 이 **명시 선언**된 경우에만
    이전 Evidence 를 인정한다. 선언이 없으면 무효.
    """
    if isinstance(compatible_versions, (str, bytes)):
        # tuple("1.0") == ("1", ".", "0") — 문자 단위 분해가 오인정을 만들므로
        # governance 판정 입력에서 단일 문자열은 명시 거부한다
        raise TypeError(
            "compatible_versions must be a collection of version strings, "
            "not a single string: {!r}".format(compatible_versions)
        )
    if evidence.policy_version == current_version:
        return True
    return evidence.policy_version in tuple(compatible_versions)


def subject_matches(evidence, current_digest):
    """Subject digest 일치 판정 — policy version 과 독립 (spec §3.4).

    version bump 는 이 판정에 어떤 영향도 주지 않는다. digest 판정과
    version 판정은 서로 다른 무효화 축이다.
    """
    return evidence.subject == current_digest


# ---------------------------------------------------------------------------
# 발급 원장(runtime ledger) 대조 — spec §2.2, plan Task 3.3.
# 전부 순수 함수: 원장 레코드의 저장·조회는 platform 소관이다.

# §3.5 필드 계약 이름 — fingerprint 정규화·직렬화의 단일 어휘
EVIDENCE_FIELD_NAMES = (
    "type",
    "subject",
    "result",
    "created_at",
    "producer",
    "policy_version",
    "metadata",
)

# 발급 레코드(원장 entry)의 대조 키 필드 이름
LEDGER_FIELD_FINGERPRINT = "fingerprint"
LEDGER_FIELD_TYPE = "type"


def _record_field(record, name, default=None):
    """Evidence 인스턴스와 저장 형식(mapping) 양쪽에서 필드를 읽는다."""
    if isinstance(record, dict):
        return record.get(name, default)
    return getattr(record, name, default)


def evidence_fields(record):
    """§3.5 필드 계약으로 정규화한 dict — fingerprint·직렬화 공용 형태.

    Evidence 인스턴스와 저장 형식(mapping)을 같은 모양으로 수렴시킨다.
    metadata 부재는 빈 dict 로 정규화한다 (Evidence dataclass 기본값과
    동일) — 부재와 빈 metadata 가 다른 fingerprint 를 만들지 않게.
    """
    fields = {
        name: _record_field(record, name) for name in EVIDENCE_FIELD_NAMES
    }
    if fields["metadata"] is None:
        fields["metadata"] = {}
    return fields


def evidence_fingerprint(record):
    """발급 원장 대조용 canonical fingerprint — 순수 함수 (spec §2.2).

    §3.5 필드 전부를 canonical JSON(sort_keys, 고정 구분자)으로 직렬화해
    해시한다 — 어떤 필드든 달라지면 대응이 끊긴다 (변조 = 불인정).
    JSON 직렬화를 쓰므로 tuple/list 구분 없이 저장 왕복(dict → JSON →
    dict) 전후 fingerprint 가 안정적이다.

    **서명이 아니다**: 위조자가 같은 함수로 fingerprint 를 재계산할 수
    있다. 방어 대상은 "evidence 형식 파일 생성만으로 충족" 이라는 저비용
    우회 한 클래스다 — 원장에까지 발급 레코드를 함께 위조하는 적대적
    시나리오는 위협 모델 밖이다 (spec §2.2: 적대적 우회 하드닝 비범위,
    정직한 Agent 규율이 목적).
    """
    canonical = json.dumps(
        evidence_fields(record),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def issuance_entry(record):
    """발급 시 원장에 남길 발급 레코드 유도 — 순수 함수.

    저장은 platform 소관이다 (kernel 은 storage 를 모른다). type 은
    진단·설명용 참고 정보이고, 대응 판정은 fingerprint 로만 한다.
    """
    return {
        LEDGER_FIELD_FINGERPRINT: evidence_fingerprint(record),
        LEDGER_FIELD_TYPE: _record_field(record, "type"),
    }


def issuance_matches(record, ledger_entry):
    """evidence ↔ 원장 발급 레코드 대응 판정 — 순수 함수 (spec §2.2).

    대응 = 원장 entry 의 fingerprint 가 record 의 fingerprint 와 일치.
    entry 부재(None)·비 mapping·fingerprint 결손은 전부 불인정이다 —
    확인 불가를 인정으로 승격하지 않는다 (보수적 판정, spec §3.4 의
    "확인 불가 ≠ 충족" 방향과 동일).
    """
    if not isinstance(ledger_entry, dict):
        return False
    fingerprint = ledger_entry.get(LEDGER_FIELD_FINGERPRINT)
    if not fingerprint:
        return False
    return fingerprint == evidence_fingerprint(record)
