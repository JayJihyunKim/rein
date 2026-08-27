"""code_review capability — Evidence 발급 주체는 Runtime (plan Task 3.1).

spec §2.2 위협 모델 (원문 인용):
    "Agent 가 Evidence 파일(JSON 등)을 직접 생성하는 것만으로는 어떤
    Requirement 도 충족되지 않는다 — Evidence 는 Rein Runtime 만
    발급한다." / "가능한 경우 external reviewer log, Codex output, tool
    execution result, structured review response 를 Runtime 이 직접
    파싱해 검증 강도를 높인다."

spec §3.6 code_review (§12, 원문 인용):
    "기본 subject = code digest. Reviewer PASS 반환만으로 Evidence 자동
    인정 안 됨 — Runtime 이 현재 digest 와 결합해 발급."

이 모듈이 고정하는 계약 두 가지:

1. **발급 게이트** (`issue_code_review_evidence`): Reviewer 의 structured
   review response 를 Runtime 이 직접 파싱해, 리뷰가 본 code digest 와
   Runtime 이 스스로 계산한 현재 digest 를 비교한다. verdict == PASS 이고
   두 digest 가 일치할 때만 Evidence 를 만든다. 리뷰 후 코드가 수정되면
   (digest 불일치) 발급하지 않는다.
2. **평가 결합** (`CodeReviewRequirement.evaluate`): 발급된 Evidence 라도
   존재만으로는 충족이 아니다 — 두 독립 무효화 축(spec §3.4)을 모두
   재확인한다. digest 축은 kernel `subject_matches`, policy version 축은
   kernel `policy_version_valid` — 둘 다 순수 함수 재사용이며 재구현하지
   않는다. 발급 함수는 version 을 판정하지 않고 기록만 한다 (생성 당시
   version 기록, 유효성은 평가 시점 판정 — kernel Evidence 계약과 동일
   방향).

**리뷰 digest 범위 전환 (spec §3.6 "리뷰 digest 범위 + 발급 배선 전환
계약", 2026-08-20 보강, Phase 7 웨이브 3 ③-a)**: subject/현재 digest 는
더 이상 WORKTREE ChangeSet 전체(`changeset.digest`)가 아니라 검토 면제
허용목록(문서/trail, 버전-only 특례는 미적용)을 제외한 `changeset.
review_digest` 다(`rein.platform.git.facts.review_digest()` 산정 —
`FACT_CHANGESET_REVIEW_DIGEST` 참조). 배선 전 구현은 trail/ 하위 도장·
기록 쓰기가 digest 를 바꿔 리뷰→기록→커밋 절차가 자기차단되는 결함이
있었다 — 이 fact 전환이 그 결함을 닫는다. 닫힌 값 계약 2상태
(`rein.kernel.changeset.SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`)를 END-STATE
의미론으로 소비한다: `SUBJECT_EMPTY`(변경 전부 허용목록)는 **충족**,
`SUBJECT_UNRESOLVED`(산정 실패)는 **보수적으로 미충족** — security
capability 의 동일 2상태 소비 패턴(`SecurityReviewRequirement.evaluate`)
을 그대로 미러링한다. **전환기 참고**: 이 END-STATE 의미론은 authority
dual-read 가 legacy 를 완전히 대체한 뒤에만 최종 판정으로 쓰인다 —
전환기 동안은 `rein.engine.evaluator._requirement_satisfied` 의
valid-evidence 게이팅(spec §3.6 판정 상태표)이 이 두 상태를 legacy
위임으로 라우팅한다(이 모듈 자신은 그 라우팅을 모른다 — 여기는 순수
end-state 판정만 제공, engine 층이 전환 여부를 결정).

거부는 예외다 — None 반환은 호출자가 조용히 넘겨 "미발급" 과 "발급 후
미조회" 가 섞이므로, 사유별로 구분 가능한 `ReviewEvidenceRefusal` 계열
예외로 명시 거부한다 (침묵 실패 금지). strict 파싱: 필수 필드 결손·형식
위반을 관대하게 보정하지 않는다.

Capability 간 직접 의존 금지 (spec §3.1) — 이 모듈은 kernel 어휘와
engine context 계약만 사용한다.
"""
from datetime import datetime, timezone

from rein.kernel.changeset import SUBJECT_EMPTY, SUBJECT_UNRESOLVED
from rein.kernel.evidence import (
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    policy_version_valid,
    subject_matches,
)
from rein.kernel.requirement import Requirement

# 고정 5종 계약 이름 (kernel REQUIREMENT_NAMES 원소, spec §3.4)
REQUIREMENT_NAME = "code_review"

# 발급을 허용하는 유일한 verdict 어휘 — 변형(pass/Pass/공백 포함)을
# 승격하지 않는다 (strict, 관대한 해석 금지)
VERDICT_PASS = "PASS"

# structured review response 필수 필드 (spec §2.2 — Runtime 직접 파싱).
# reviewed_digest = 리뷰가 실제로 본 code digest. Runtime 이 계산한 현재
# digest 와의 비교가 발급 게이트다.
RESPONSE_FIELD_VERDICT = "verdict"
RESPONSE_FIELD_REVIEWED_DIGEST = "reviewed_digest"

# 현재 ChangeSet digest fact 키 — 기존 fact 명명 관례(`git.branch`,
# `command.type`)를 따른다. 해석(WORKTREE + 검토 면제 허용목록 제외)은
# platform/git 소관이고(spec §3.2 expensive fact, `rein.platform.git.
# facts.review_digest()`), 이 capability 는 값만 조회한다. **2026-08-20
# 개정(Phase 7 웨이브 3 ③-a)**: 이전에는 `changeset.digest`(WORKTREE
# 전체, trail/ 하위 운영 기록 포함)를 썼다 — 그 범위가 리뷰→기록→커밋
# 절차를 자기차단하는 결함의 원인이었다(모듈 docstring "리뷰 digest
# 범위 전환" 절). 값은 `rein.cli._git_changeset_facts()` 의 동명
# 로컬 상수(`FACT_CHANGESET_REVIEW_DIGEST`)와 반드시 일치해야 한다 —
# import 로 결합하지 않고 문자열 값으로만 대응하는 기존 관례를 그대로
# 따른다(cli 모듈이 이 capability 모듈을 import 하지 않는 것과 대칭).
FACT_CHANGESET_REVIEW_DIGEST = "changeset.review_digest"

# 현재 policy version / 호환 선언 fact 키 (spec §3.4 Policy Versioning:
# "기본 원칙 = Evidence version 과 현재 version 일치. 호환성을 명시
# 선언한 경우에만 이전 Evidence 인정"). 호환 선언 값은 version 문자열
# collection 이어야 한다 — 단일 문자열은 kernel `policy_version_valid`
# 가 문자 단위 분해 오인정을 막기 위해 명시 거부한다.
FACT_POLICY_VERSION = "policy.version"
FACT_POLICY_COMPATIBLE_VERSIONS = "policy.compatible_versions"


class ReviewEvidenceRefusal(Exception):
    """code_review Evidence 발급 거부 — 사유별 하위 타입의 공통 base.

    호출자(Runtime)는 이 base 하나로 "발급되지 않았다" 부류 전체를 잡을
    수 있고, 하위 타입으로 사유(파싱 실패/verdict/digest)를 구분한다.
    """


class MalformedReviewResponse(ReviewEvidenceRefusal):
    """structured response 파싱 불가·필수 필드 결손 — 관대한 해석 금지."""


class ReviewVerdictNotPass(ReviewEvidenceRefusal):
    """verdict 가 PASS 가 아님 (NEEDS-FIX 등) — digest 일치 여부와 무관."""


class ReviewDigestMismatch(ReviewEvidenceRefusal):
    """리뷰가 본 digest ≠ 현재 digest — 리뷰 후 코드가 수정된 상태."""


def _parse_structured_response(response):
    """structured review response 를 strict 파싱한다 (spec §2.2).

    mapping + 필수 필드 2종(verdict, reviewed_digest)이 비어 있지 않은
    문자열이어야 한다. 어긋나면 MalformedReviewResponse — 자유 텍스트나
    필드 결손 응답을 발급 재료로 승격하지 않는다.
    """
    if not isinstance(response, dict):
        raise MalformedReviewResponse(
            "structured review response must be a mapping, got "
            "{!r}".format(type(response).__name__)
        )
    parsed = []
    for field_name in (
        RESPONSE_FIELD_VERDICT,
        RESPONSE_FIELD_REVIEWED_DIGEST,
    ):
        value = response.get(field_name)
        if not isinstance(value, str) or not value:
            raise MalformedReviewResponse(
                "review response field {!r} must be a non-empty string, "
                "got {!r}".format(field_name, value)
            )
        parsed.append(value)
    return tuple(parsed)


def issue_code_review_evidence(
    response, current_digest, policy_version, created_at=None
):
    """Runtime 발급 함수 — verdict 와 현재 digest 를 결합해서만 발급한다.

    - `response`: Reviewer 가 반환한 structured review response (dict).
      Runtime 이 직접 파싱한다 — Reviewer 의 자기 신고를 그대로 Evidence
      로 승격하지 않는다 (spec §2.2, §3.6).
    - `current_digest`: Runtime 이 스스로 계산한 현재 code digest
      (`changeset.review_digest`, spec §3.6 "리뷰 digest 범위" 절).
      Evidence 의 subject 가 된다. 닫힌 값 계약 2상태
      (`rein.kernel.changeset.SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`)는
      여기서 발급 대상이 될 수 없다 — 둘 다 거부가 아니라 호출자 계약
      위반(ValueError)이다: `SUBJECT_EMPTY`("확인했더니 대상 없음")는
      `CodeReviewRequirement.evaluate()` 가 evidence 없이 이미 충족으로
      판정하므로 애초에 발급을 시도할 이유가 없고, `SUBJECT_UNRESOLVED`
      ("산정 불가")는 무엇에 대한 evidence 인지조차 정의되지 않는다 —
      security capability 의 동일 계약(`issue_security_review_evidence`
      docstring)과 대칭.
    - `created_at`: 발급 시각 주입 (None 이면 현재 UTC) — 테스트 결정성.

    발급 조건 전부 충족 시 Evidence 반환, 아니면 사유별
    ReviewEvidenceRefusal 하위 예외 (침묵 실패 금지):
    파싱 실패 → MalformedReviewResponse / verdict ≠ PASS →
    ReviewVerdictNotPass / digest 불일치 → ReviewDigestMismatch.
    """
    if (
        not isinstance(current_digest, str)
        or not current_digest
        or current_digest in (SUBJECT_EMPTY, SUBJECT_UNRESOLVED)
    ):
        # 거부 부류가 아니라 호출자(Runtime) 계약 위반 — digest 를 확보하지
        # 못했거나(빈 값), 닫힌 값 계약의 센티널을 실제 digest 로 착각해
        # 넘겼으면 발급 시도 자체가 성립하지 않는다 (위 docstring 참조)
        raise ValueError(
            "current_digest must be a non-empty digest string computed by "
            "the runtime, not the SUBJECT_EMPTY/SUBJECT_UNRESOLVED "
            "sentinel — got {!r}".format(current_digest)
        )
    verdict, reviewed_digest = _parse_structured_response(response)
    if verdict != VERDICT_PASS:
        raise ReviewVerdictNotPass(
            "review verdict {!r} is not {!r} — no evidence is issued "
            "(spec §3.6)".format(verdict, VERDICT_PASS)
        )
    if reviewed_digest != current_digest:
        raise ReviewDigestMismatch(
            "reviewed digest {!r} does not match current digest {!r} — "
            "code changed after review, no evidence is issued "
            "(spec §3.6)".format(reviewed_digest, current_digest)
        )
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return Evidence(
        type=REQUIREMENT_NAME,
        subject=current_digest,
        result=VERDICT_PASS,
        created_at=created_at,
        # 리뷰 판단은 Agent 의 것 — runtime_verified 로 승격하지 않는다
        # (spec §3.5 producer 3등급, §2.2 신뢰 위계)
        producer=PRODUCER_AGENT_ATTESTED,
        policy_version=policy_version,
    )


class CodeReviewRequirement(Requirement):
    """code_review Requirement 구현체 — 평가 시점 validity 결합 (spec §3.6).

    evidence 존재만으로 충족이 아니다: 레코드의 result 가 PASS 어휘이고
    두 독립 무효화 축(spec §3.4)을 모두 통과해야 충족이다 —
    - digest 축: subject 가 **평가 시점의** 현재 digest 와 일치. 발급
      이후 코드가 또 수정되면 같은 Evidence 로는 충족되지 않는다
      (tests/contract/test_evidence_digest_expiry.py 와 동일 계약).
    - policy version 축: 레코드의 policy_version 이 현재 version 과
      일치하거나 호환 선언에 **명시**된 경우만 인정.
    """

    @property
    def name(self):
        return REQUIREMENT_NAME

    def evaluate(self, context):
        """충족 여부(bool) — digest·version 두 축이 결합된 PASS 레코드가 있는가.

        `changeset.review_digest` fact 는 닫힌 값 계약 2상태를 포함한
        세 형태 중 하나다(spec §3.6 "리뷰 digest 범위" 절, 2026-08-20
        보강):

        - `SUBJECT_EMPTY`("확인했더니 대상 없음" — 변경 전부 검토 면제
          허용목록): **충족** 방향. evidence 순회 없이 곧바로 True 를
          반환한다 — 문서·기록-only 커밋은 코드리뷰가 요구되지 않는다
          (security capability 의 동일 2상태 소비 패턴을 그대로
          미러링, `SecurityReviewRequirement.evaluate` 참조).
        - `SUBJECT_UNRESOLVED`("산정 불가") 또는 fact 부재(`None`)/빈
          값: 재확인 자체가 불가능하므로 **보수적으로 미충족**이다 —
          확인 불가를 충족으로 승격하지 않는다(spec §3.4).
        - 그 밖(실제 digest 문자열): 기존 로직 그대로 — 그 digest 에
          결합된 유효 PASS evidence 가 있는지 확인한다.

        (전환기 동안 이 end-state 판정이 최종 authority 결과로 곧바로
        쓰이지는 않는다 — `rein.engine.evaluator._requirement_satisfied`
        의 valid-evidence 게이팅이 `SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`
        를 legacy 위임으로 라우팅한다, spec §3.6 판정 상태표. 이 메서드
        자신은 그 라우팅을 모른다 — engine 층의 관심사.)

        version fact 미확보 시에도 보수적 미충족이다. fact 해석 실패
        (FactResolutionError)는 context 계약대로 전파된다 (판단 불능 ≠
        부재, spec §3.4) — registry 배선 시 evaluator 가 failure_mode 로
        분기한다.
        """
        current_digest = context.fact(FACT_CHANGESET_REVIEW_DIGEST)
        if current_digest == SUBJECT_EMPTY:
            return True
        if not current_digest or current_digest == SUBJECT_UNRESOLVED:
            return False
        current_version = context.fact(FACT_POLICY_VERSION)
        if not current_version:
            return False
        compatible_versions = context.fact(FACT_POLICY_COMPATIBLE_VERSIONS)
        if compatible_versions is None:
            compatible_versions = ()
        for record in context.evidence_for(REQUIREMENT_NAME):
            if record.type != REQUIREMENT_NAME:
                continue
            if record.result != VERDICT_PASS:
                continue
            if not subject_matches(record, current_digest):
                continue
            if not policy_version_valid(
                record, current_version, compatible_versions
            ):
                continue
            return True
        return False


def register_code_review(registry):
    """RequirementRegistry 에 code_review 구현체를 명시 등록한다.

    등록은 이 함수 호출로만 일어난다 — import 부작용 등록 금지
    (spec §3.1 §32: Registry 는 명시적 코드 등록). 등록된 구현체를
    반환한다 (호출자가 동일 인스턴스를 재사용할 수 있게).
    """
    implementation = CodeReviewRequirement()
    registry.register(REQUIREMENT_NAME, implementation)
    return implementation
