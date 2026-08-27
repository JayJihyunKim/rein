"""Delta Review — Full Review 위에 실변경분 리뷰를 합성 (plan Task 3.2).

spec §3.6 Delta Review (§13, 원문 인용):
    "`Full Review(X) + Delta Review(X→Y) = Validated Review(Y)`. Delta
    대상은 X 이후 실제 변경분으로 제한. Base digest 불명확·중간 상태
    불신 시 Full Review fallback. 목표 = v1 review churn (작은 수정마다
    전체 재리뷰) 제거."

이 모듈이 고정하는 계약 세 가지:

1. **합성 발급** (`issue_delta_review_evidence`): Runtime 이 structured
   delta review response 를 직접 파싱하고 (spec §2.2 — Task 3.1 과 같은
   규율), 네 결합을 모두 통과할 때만 발급한다 — verdict == PASS /
   reviewed digest == Runtime 이 계산한 현재 digest / 리뷰가 봤다는
   변경 경로 집합 == Runtime 이 계산한 실제 X→Y 변경 경로 집합 (아래
   scope 결속) / base digest 가 검증 가능한 선행 review evidence 와
   매칭. 산출물은 **현재 digest 를 subject 로 갖는 일반 code_review
   Evidence** 다 — 별도 evidence 타입을 만들지 않으므로 기존
   `CodeReviewRequirement.evaluate` 가 수정 없이 Y 에서 충족 판정한다
   (spec 공식의 우변이 "Validated Review(Y)" 인 이유). 합성 이력
   (base digest·delta scope·결속 경로)은 metadata 에 기록한다 —
   kernel Evidence 필드 계약은 변경하지 않는다 (spec §3.5).

   **scope 결속** ("Delta 대상은 X 이후 실제 변경분으로 제한" 의 실행
   축): digest 결합은 "지금 코드가 리뷰가 본 상태 그대로인가" 만 답하고
   "리뷰가 실변경분을 봤는가" 는 답하지 못한다. 그래서 response 는
   리뷰가 봤다고 주장하는 변경 경로 목록(`reviewed_paths`)을 필수로
   싣고, 호출자(Runtime)는 platform diff 로 산출한 실제 X→Y 변경 경로
   집합(`actual_changed_paths`)을 주입한다 — 이 모듈은 **집합 비교만**
   한다 (경로 해석·정규화 의미론은 호출자 소관, kernel ChangeSet paths
   관례 = 저장소 상대 경로의 정렬·중복제거 tuple). 미달(실변경 일부
   미리뷰 = 검증 공백)이든 초과(변경되지 않은 경로를 봤다는 주장 =
   response 신뢰성 붕괴)든 DeltaScopeMismatch 로 발급 거부.
2. **합성 검증** (`validate_delta_base`): base 는 type == code_review /
   result == PASS / subject == base digest / policy version 유효(현재
   version 일치 또는 호환 명시 선언 — kernel `policy_version_valid`
   재사용, 재구현 금지)를 전부 충족하는 선행 evidence 여야 한다. 하나라도
   어긋나면 **FullReviewRequired** — 불명확 base·불신 중간 상태는 delta
   로 충족 불가이며 Full Review fallback 을 명시 신호로 요구한다 (침묵
   실패 금지). version 검사가 여기 있는 이유: 직접 평가라면 미충족일
   구식 evidence 가 delta 합성을 경유해 신품 version evidence 로 세탁
   되는 경로를 차단한다 (spec §3.4 두 무효화 축의 보존).
3. **체인 계약**: 합성 산출물 Validated(Y) 는 일반 code_review Evidence
   이므로 다음 delta 의 base 자격을 가진다 — 공식이 귀납 적용된다:
   `Validated(Y) + Delta(Y→Z) = Validated(Z)`. 끊긴 체인(base 가 어떤
   검증된 review 와도 매칭 안 됨)은 FullReviewRequired. 반대로 base 유효
   + target 결합만 성립하면 X→Z 처럼 중간을 건너뛰는 delta 도 허용한다
   ("X 이후 실변경분 전부"를 한 번에 리뷰했다는 주장 — 중간 경유 강제
   없음).

거부 어휘는 Task 3.1 을 재사용한다: 파싱 실패 → MalformedReviewResponse /
verdict ≠ PASS → ReviewVerdictNotPass / 현재 digest 불일치 →
ReviewDigestMismatch. 신규 사유는 FullReviewRequired(불명확·불신 base —
full review fallback 신호)와 DeltaScopeMismatch(scope 결속 불일치 —
올바른 범위의 delta 재리뷰로 해소 가능) 둘이며, 모두
`ReviewEvidenceRefusal` 하위라 호출자는 base 하나로 "발급되지 않았다"
부류 전체를 잡고 하위 타입으로 후속 경로만 구분한다.

Capability 간 직접 의존 금지 (spec §3.1) — 이 모듈은 같은 review
capability 내부의 Task 3.1 어휘와 kernel 순수 함수만 사용한다.
"""
from datetime import datetime, timezone

from rein.capabilities.review.capability import (
    MalformedReviewResponse,
    REQUIREMENT_NAME,
    RESPONSE_FIELD_REVIEWED_DIGEST,
    RESPONSE_FIELD_VERDICT,
    ReviewDigestMismatch,
    ReviewEvidenceRefusal,
    ReviewVerdictNotPass,
    VERDICT_PASS,
)
from rein.kernel.evidence import (
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    policy_version_valid,
    subject_matches,
)

# structured delta review response 의 delta 고유 필수 필드 — 리뷰가
# 출발점으로 삼은 base digest (spec §3.6 의 X) + 리뷰가 봤다고 주장하는
# 변경 경로 목록 (scope 결속 재료). verdict/reviewed_digest 는 Task 3.1
# 상수 재사용.
RESPONSE_FIELD_BASE_DIGEST = "base_digest"
RESPONSE_FIELD_REVIEWED_PATHS = "reviewed_paths"

# 합성 이력 metadata 키 (kernel Evidence.metadata 슬롯 — 필드 계약 불변).
# base digest 를 남겨 "이 evidence 가 어느 검증 상태 위에 합성됐는가" 를,
# 결속 경로를 남겨 "무엇을 실변경분으로 리뷰했는가" 를 사후 추적 가능하게
# 한다. 경로는 `_is_repo_relative_path` 화이트리스트로 **강제된** 저장소
# 상대 경로만이다 (kernel ChangeSet paths 관례) — corpus 반입 검증이
# 거부하는 홈 절대경로 류는 발급 전에 거부되어 metadata 에 실릴 수 없다.
METADATA_BASE_DIGEST = "base_digest"
METADATA_REVIEW_SCOPE = "review_scope"
METADATA_REVIEWED_PATHS = "reviewed_paths"
REVIEW_SCOPE_DELTA = "delta"

# 저장소 상대 경로 화이트리스트 재료 (재리뷰 3회차 시정) — 경로에
# 등장하면 무조건 거부하는 문자와, `/` 분해 후 허용되지 않는 세그먼트.
# NUL = 경로 위조 프레이밍 / 백슬래시 = 미정규화 Windows 구분자 /
# 콜론 = 드라이브 문자(`C:` 류) 부류 전체 (개별 패턴 열거 대신 문자
# 단위로 닫는다 — 경계는 열거로 못 닫는다).
_PATH_FORBIDDEN_CHARS = ("\x00", "\\", ":")
# 빈 세그먼트 = POSIX 절대(`/x`)·이중 슬래시·트레일링 슬래시 전부 /
# `..` = 저장소 탈출 / `.` = 비정규 표기 (동일 경로의 복수 표기 금지)
_PATH_FORBIDDEN_SEGMENTS = ("", ".", "..")


class FullReviewRequired(ReviewEvidenceRefusal):
    """delta 로 충족 불가 — Full Review fallback 명시 신호 (spec §3.6).

    base digest 불명확(매칭 evidence 부재·빈 값)이거나 중간 상태 불신
    (비PASS·타입 불일치·policy version 무효)일 때 발급 대신 이 예외로
    "full review 를 다시 받으라" 를 요구한다. 다른 거부 사유(파싱·verdict
    ·digest)와 달리 응답을 고쳐 재시도할 수 없는 부류다 — 선행 검증
    상태 자체가 없다.
    """


class DeltaScopeMismatch(ReviewEvidenceRefusal):
    """리뷰가 봤다는 경로 집합 ≠ 실제 X→Y 변경 경로 집합 — 발급 거부.

    "Delta 대상은 X 이후 실제 변경분으로 제한" (spec §3.6) 의 scope
    결속 위반. 미달(실변경 일부 미리뷰 = 검증 공백)과 초과(변경되지
    않은 경로를 봤다는 주장 = response 신뢰성 붕괴)를 대칭으로 거부한다.

    FullReviewRequired 가 아니라 별도 사유인 근거: base 검증 상태는
    유효하므로 Full Review fallback 까지 갈 일이 아니다 — 올바른 범위로
    delta 리뷰를 다시 수행하면 해소 가능한, 응답 측 결함 부류다.
    """


def _is_repo_relative_path(path):
    """저장소 상대 경로 화이트리스트 판정 — 순수 함수 (재리뷰 3회차).

    허용 형태를 정의하고 나머지 전부 거부한다 (금지 패턴 열거가 아니라
    화이트리스트 방향): 비어 있지 않은 문자열이, 금지 문자(NUL·백슬래시
    ·콜론) 없이, `/` 로 구분된 세그먼트가 모두 비어 있지 않은 일반
    이름(`.`/`..` 아님)일 때만 참이다. 이로써 POSIX 절대경로(선두 빈
    세그먼트)·드라이브 문자·이중/트레일링 슬래시·상위 탈출이 한 판정
    으로 닫힌다 — kernel ChangeSet 의 "저장소 상대 경로" 관례를 검사
    가능한 계약으로 강제한다 (검사 없는 방향 채택은 계약이 아니다 —
    절대경로가 발급 metadata 에 실리는 사적 경로 유출 재현의 시정).
    """
    if not isinstance(path, str) or not path:
        return False
    if any(forbidden in path for forbidden in _PATH_FORBIDDEN_CHARS):
        return False
    for segment in path.split("/"):
        if segment in _PATH_FORBIDDEN_SEGMENTS:
            return False
    return True


def _parse_delta_response(response):
    """structured delta review response 를 strict 파싱한다 (spec §2.2).

    mapping + 문자열 필수 필드 3종(verdict, base_digest, reviewed_digest)
    이 비어 있지 않은 문자열, `reviewed_paths` 는 비어 있지 않은 문자열
    들의 비어 있지 않은 collection 이어야 하고 (문자열 단일값은 문자
    단위 분해 오인정 위험이 있어 명시 거부 — kernel
    `policy_version_valid` 의 compatible_versions 규율과 동일 방향),
    base ≠ reviewed 여야 한다 — base == reviewed 는 변경분이 없다는
    뜻이므로 "Delta 대상은 X 이후 실제 변경분으로 제한" (spec §3.6) 을
    구조적으로 위반한 응답이다. 어긋나면 MalformedReviewResponse —
    관대한 보정 없음 (Task 3.1 과 동일 규율).

    반환하는 reviewed_paths 는 정렬·중복제거된 tuple 로 정규화된다
    (kernel ChangeSet paths 관례와 같은 형태 — 집합 비교·metadata 기록
    양쪽에 순서·중복이 개입하지 않게).
    """
    if not isinstance(response, dict):
        raise MalformedReviewResponse(
            "structured delta review response must be a mapping, got "
            "{!r}".format(type(response).__name__)
        )
    parsed = []
    for field_name in (
        RESPONSE_FIELD_VERDICT,
        RESPONSE_FIELD_BASE_DIGEST,
        RESPONSE_FIELD_REVIEWED_DIGEST,
    ):
        value = response.get(field_name)
        if not isinstance(value, str) or not value:
            raise MalformedReviewResponse(
                "delta review response field {!r} must be a non-empty "
                "string, got {!r}".format(field_name, value)
            )
        parsed.append(value)
    verdict, base_digest, reviewed_digest = parsed
    if base_digest == reviewed_digest:
        raise MalformedReviewResponse(
            "delta review must span an actual change — base digest and "
            "reviewed digest are identical ({!r}); delta scope is limited "
            "to real changes since base (spec §3.6)".format(base_digest)
        )
    raw_paths = response.get(RESPONSE_FIELD_REVIEWED_PATHS)
    if isinstance(raw_paths, (str, bytes)) or not isinstance(
        raw_paths, (list, tuple)
    ):
        raise MalformedReviewResponse(
            "delta review response field {!r} must be a list of reviewed "
            "change paths, got {!r}".format(
                RESPONSE_FIELD_REVIEWED_PATHS, raw_paths
            )
        )
    for path in raw_paths:
        if not _is_repo_relative_path(path):
            # 절대경로·드라이브 문자·`..` 류가 metadata 까지 흘러가는
            # 사적 경로 유출 경로를 파싱 단계에서 닫는다 (3회차 시정)
            raise MalformedReviewResponse(
                "delta review response field {!r} must contain repo-"
                "relative path strings (non-empty '/'-separated plain "
                "segments; no absolute paths, drive letters, "
                "backslashes, NUL, '.'/'..' or empty segments), got "
                "{!r}".format(RESPONSE_FIELD_REVIEWED_PATHS, path)
            )
    reviewed_paths = tuple(sorted(set(raw_paths)))
    if not reviewed_paths:
        raise MalformedReviewResponse(
            "delta review response field {!r} must not be empty — a delta "
            "review that reviewed no paths reviewed no change "
            "(spec §3.6)".format(RESPONSE_FIELD_REVIEWED_PATHS)
        )
    return verdict, base_digest, reviewed_digest, reviewed_paths


def validate_delta_base(
    base_digest, prior_records, policy_version, compatible_versions=()
):
    """합성 검증 — base 가 검증 가능한 review 상태와 매칭되는지 판정한다.

    매칭 조건 (전부 충족해야 base 자격):
    - `type == code_review` — 같은 digest 를 subject 로 가진 다른 타입
      evidence (tests_passed 등)는 review 검증 상태가 아니다.
    - `result == PASS` — 비PASS 레코드는 불신 중간 상태다.
    - `subject == base_digest` — kernel `subject_matches` 재사용.
    - policy version 유효 — kernel `policy_version_valid` 재사용 (현재
      version 일치 또는 호환 명시 선언만, spec §3.4). 구식 version base
      를 delta 합성으로 세탁하는 경로를 여기서 차단한다.

    매칭 레코드를 반환한다 (Full Review 산출물이든 이전 delta 합성
    산출물이든 — 체인 귀납의 근거). 매칭이 없거나 base digest 자체가
    불명확(빈 값·비문자열)하면 FullReviewRequired — delta 로 충족 불가,
    Full Review fallback 요구 (spec §3.6).
    """
    if not isinstance(base_digest, str) or not base_digest:
        raise FullReviewRequired(
            "delta base digest is unclear ({!r}) — cannot anchor a delta "
            "review; a full review is required (spec §3.6 fallback)".format(
                base_digest
            )
        )
    for record in prior_records:
        if record.type != REQUIREMENT_NAME:
            continue
        if record.result != VERDICT_PASS:
            continue
        if not subject_matches(record, base_digest):
            continue
        if not policy_version_valid(
            record, policy_version, compatible_versions
        ):
            continue
        return record
    raise FullReviewRequired(
        "no validated review evidence matches delta base digest {!r} — "
        "the chain is broken or the base state is untrusted; a full "
        "review is required (spec §3.6 fallback)".format(base_digest)
    )


def _normalize_actual_changed_paths(actual_changed_paths):
    """호출자(Runtime)가 주입한 실제 변경 경로 집합의 계약 검증.

    reviewer response 측 결함(→ ReviewEvidenceRefusal 부류)과 달리 이건
    Runtime 자기 입력이다 — 어긋나면 발급 시도 자체가 성립하지 않는
    호출자 계약 위반으로 TypeError/ValueError 를 낸다 (current_digest
    미확보와 동일 방향). 문자열 단일값은 문자 단위 분해 오인정 위험으로
    명시 거부 (kernel `policy_version_valid` 규율). 각 경로는
    `_is_repo_relative_path` 화이트리스트를 통과해야 한다 — platform
    diff 산출물이 저장소 상대 경로가 아니라면(절대경로 등) 그건 diff
    쪽 결함이고, 여기서 침묵 수용하면 metadata 유출로 이어진다 (3회차
    시정). 정렬·중복제거 tuple 로 정규화해 반환한다 (kernel ChangeSet
    paths 관례).
    """
    if isinstance(actual_changed_paths, (str, bytes)):
        raise TypeError(
            "actual_changed_paths must be a collection of changed path "
            "strings, not a single string: {!r}".format(actual_changed_paths)
        )
    paths = tuple(actual_changed_paths)
    for path in paths:
        if not _is_repo_relative_path(path):
            raise ValueError(
                "actual_changed_paths must contain repo-relative path "
                "strings (non-empty '/'-separated plain segments; no "
                "absolute paths, drive letters, backslashes, NUL, "
                "'.'/'..' or empty segments), got {!r}".format(path)
            )
    normalized = tuple(sorted(set(paths)))
    if not normalized:
        raise ValueError(
            "actual_changed_paths must not be empty — without an actual "
            "change there is no delta to review (spec §3.6)"
        )
    return normalized


def issue_delta_review_evidence(
    response,
    prior_records,
    current_digest,
    actual_changed_paths,
    policy_version,
    compatible_versions=(),
    created_at=None,
):
    """Runtime 합성 발급 — Full(X) + Delta(X→Y) 를 Validated(Y) 로 만든다.

    - `response`: Delta Reviewer 의 structured delta review response
      (dict). Runtime 이 직접 파싱한다 — Reviewer 의 자기 신고를 그대로
      Evidence 로 승격하지 않는다 (spec §2.2, Task 3.1 과 같은 규율).
    - `prior_records`: base 후보가 될 선행 evidence collection. 이 안에서
      `validate_delta_base` 가 검증 가능한 review 상태를 찾는다.
    - `current_digest`: Runtime 이 스스로 계산한 현재 code digest —
      리뷰가 봤다는 reviewed digest 와 일치해야 하고, 산출물의 subject
      가 된다 (delta 리뷰 후 코드가 또 수정되면 발급하지 않는다).
    - `actual_changed_paths`: Runtime 이 platform diff 로 산출한 실제
      X→Y 변경 경로 집합 (저장소 상대 경로 — kernel ChangeSet paths
      관례). 리뷰가 봤다는 `reviewed_paths` 와 집합으로 일치해야 한다
      — 이 모듈은 단순 집합 비교만 하고 경로 해석은 호출자 소관이다.
    - `created_at`: 발급 시각 주입 (None 이면 현재 UTC) — 테스트 결정성.

    발급 조건 전부 충족 시 code_review Evidence (subject = 현재 digest,
    metadata 에 base digest + delta scope + 결속 경로 기록) 반환. 아니면
    사유별 ReviewEvidenceRefusal 하위 예외 (침묵 실패 금지): 파싱 실패·
    변경분 없음 → MalformedReviewResponse / verdict ≠ PASS →
    ReviewVerdictNotPass / 현재 digest 불일치 → ReviewDigestMismatch /
    scope 결속 불일치(미달·초과) → DeltaScopeMismatch / base 불명확·불신
    → FullReviewRequired (Full Review fallback 신호).
    """
    if not isinstance(current_digest, str) or not current_digest:
        # 거부 부류가 아니라 호출자(Runtime) 계약 위반 — digest 를 확보
        # 하지 못했으면 발급 시도 자체가 성립하지 않는다 (Task 3.1 동일)
        raise ValueError(
            "current_digest must be a non-empty digest string computed by "
            "the runtime, got {!r}".format(current_digest)
        )
    actual_paths = _normalize_actual_changed_paths(actual_changed_paths)
    verdict, base_digest, reviewed_digest, reviewed_paths = (
        _parse_delta_response(response)
    )
    if verdict != VERDICT_PASS:
        raise ReviewVerdictNotPass(
            "delta review verdict {!r} is not {!r} — no evidence is "
            "issued (spec §3.6)".format(verdict, VERDICT_PASS)
        )
    if reviewed_digest != current_digest:
        raise ReviewDigestMismatch(
            "delta reviewed digest {!r} does not match current digest "
            "{!r} — code changed after the delta review, no evidence is "
            "issued (spec §3.6)".format(reviewed_digest, current_digest)
        )
    if reviewed_paths != actual_paths:
        # 집합 비교 (양쪽 모두 정렬·중복제거 정규화 완료) — 미달·초과를
        # 대칭으로 거부한다 ("실변경분 한정" 결속, spec §3.6)
        missed = sorted(set(actual_paths) - set(reviewed_paths))
        phantom = sorted(set(reviewed_paths) - set(actual_paths))
        raise DeltaScopeMismatch(
            "delta review scope does not match the actual changes since "
            "base — unreviewed actual changes: {!r} / claimed but "
            "unchanged: {!r}; delta scope is limited to real changes "
            "since base (spec §3.6)".format(missed, phantom)
        )
    base = validate_delta_base(
        base_digest, prior_records, policy_version, compatible_versions
    )
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return Evidence(
        type=REQUIREMENT_NAME,
        subject=current_digest,
        result=VERDICT_PASS,
        created_at=created_at,
        # delta 리뷰 판단도 Agent 의 것 — runtime_verified 로 승격하지
        # 않는다 (spec §3.5 producer 3등급, §2.2 신뢰 위계)
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=policy_version,
        metadata={
            METADATA_BASE_DIGEST: base.subject,
            METADATA_REVIEW_SCOPE: REVIEW_SCOPE_DELTA,
            # 결속 경로는 화이트리스트 검사를 통과한 저장소 상대 경로만
            # — 절대경로 류 사적 경로는 여기 도달하기 전에 거부된다
            METADATA_REVIEWED_PATHS: reviewed_paths,
        },
    )
