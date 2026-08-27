"""`bin/rein issue-evidence` 서브커맨드 본체 (Phase 7 웨이브 3 ③-a).

## 배경 — "zero production callers" 갭

`rein.capabilities.review.capability.issue_code_review_evidence()` /
`rein.capabilities.security.capability.issue_security_review_evidence()`
는 Phase 3/4 부터 존재했지만, 이 저장소 어디에도 그 두 함수를 실제로
호출해 `LedgerVerifiedEvidenceSource.record_issued()` 까지 이어 붙이는
프로덕션 경로가 없었다 — 테스트만 두 함수를 직접 호출한다. 그 결과
v2 evidence 는 ledger 에 **한 번도 실제로 발급된 적이 없다**: 평가
(`evaluate()`)는 이미 실 ledger 를 조회하도록 배선됐지만(Phase 6 최종
조립, `rein/cli/__init__.py` 모듈 docstring "evidence_source 연결" 절),
그 ledger 를 채우는 shell 진입점이 아예 없었다. 이 모듈이 그 진입점이다
— codex-review/security-reviewer 스킬(또는 사람)이 review verdict 를
얻은 뒤 `bin/rein issue-evidence <capability> --verdict PASS
--reviewed-digest <D>` 를 호출해 실제로 evidence 를 ledger 에 적재한다.

## 세 진입점

1. `print_digest(capability)` — 지금 이 순간 evaluation 이 볼 subject
   digest 를 그대로 반환한다. 호출자(리뷰 스킬)가 리뷰 대상에게 "이
   digest 를 검토했다"고 결속시킬 값을 얻는 용도 — 리뷰 시작 시점에
   한 번 조회해 리뷰 응답에 `reviewed_digest` 로 그대로 실어 보낸다.
2. `print_subject(capability)` — **code_review/security_review 둘 다
   지원**(2026-08-20 code review round 3 정제 — 이전 `print_subject_
   paths()`, code_review 전용, `--print-subject-paths` 를 대체). subject
   digest 와 그 digest 가 실제로 흡수하는 인증된 경로 목록을 **같은
   changeset 조회 한 번**에서 함께 반환한다(원자적 스냅샷 — High-1,
   digest 캡처와 경로 목록 캡처를 별도 호출 2번으로 나누면 그 사이 트리가
   바뀔 수 있어 두 값이 서로 다른 상태를 증명할 위험이 있었다).
   `/codex-review` 래퍼(`scripts/rein-codex-review.sh`)가 이 값으로
   "다이제스트가 증명하는 파일 = 리뷰어가 실제로 보는 파일" 불변식을
   지킨다. security_review 축은 `agents/security-reviewer.md` 가 이
   값으로 "발급기가 실제로 증명하는 경로 집합"을 리뷰 대상 하한으로
   삼는다(sensitive∩allowlist 보존 요구, Finding 2).
3. `issue(capability, verdict, reviewed_digest)` — Runtime 발급 게이트
   (`issue_code_review_evidence`/`issue_security_review_evidence`)를
   그대로 호출해 evidence 를 만들고, `LedgerVerifiedEvidenceSource.
   record_issued()` 로 원장에 적재한다.

## digest 계산 재사용 — 중복 로직 금지

이 모듈은 digest 계산 로직을 새로 만들지 않는다. `rein.cli`(패키지
최상위 `__init__.py`)의 fact 배선이 이미 이 계산의 유일한 정본이다 —
`_git_changeset_facts()`(WORKTREE 기준 changeset digest 4종 —
digest/sensitive_digest/tag/review_digest — 함께 산출)와
`_security_digest_scope_profile()`(security_review 의 sensitive/strict
프로필 분기, spec §3.6)를 그대로 재사용한다. `_build_fact_resolvers()`
의 `_resolve_review_digest`/`_resolve_sensitive_digest` 가 evaluate()
시점에 계산하는 것과 **정확히 같은 함수 호출**이므로, 이 모듈이 발급
시점에 계산한 digest 와 evaluate() 가 재확인 시점에 계산한 digest 는
항상 같은 코드 경로에서 나온다 — 두 시점 사이에 실제로 코드가 바뀌지
않는 한 불일치가 있을 수 없다(있다면 그 자체가 "코드가 바뀌었다"는
정확한 신호다, spec §3.6 "리뷰 후 코드가 수정되면 발급하지 않는다"의
존재 이유).

**code_review 도 이제 닫힌 값 계약 2상태를 가진다** (spec §3.6 "리뷰
digest 범위" 절, 2026-08-20 보강, Phase 7 웨이브 3 ③-a) — 이전에는
`changeset.digest`(WORKTREE 전체)를 썼기 때문에 센티널 계약이 없었지만,
이제 `changeset.review_digest`(검토 면제 허용목록 제외)를 쓰므로
`SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`가 정당한 반환값이다 — security_
review 와 동일한 사유별 거부(`REASON_SUBJECT_EMPTY`/`REASON_SUBJECT_
UNRESOLVED`)를 이제 code_review 경로도 공유한다(아래 `issue()` 참조).

policy_version 도 마찬가지로 evaluate() 의 단일 스냅샷 경로
(`rein.cli._load_policy_version_fact()`)를 그대로 재사용한다 — Phase 7
웨이브 2가 고친 이중 읽기 버그(`policy_version_cache` 공유)의 대상이 된
바로 그 함수다.

## project_root 자립 규칙 — `hook` 서브커맨드와의 차이

`REIN_PROJECT_ROOT` 환경변수는 `hook` 서브커맨드와 **우선순위**는 같다
(명시 환경변수가 항상 우선) — 하지만 검증 여부는 다르다(Medium finding,
code review round 1 로 갈라짐). `hook` 서브커맨드의 `rein.cli.
_resolve_project_root(payload)` 는 명시 값을 git 검증 없이 그대로
반환한다(hook payload 기반 자동 판정 경로 — 그 함수 자신의 별도 계약).
이 서브커맨드는 명시 값이어도 **git 검증을 거친다** — non-git 경로를
명시하면 아래 자립 규칙(cwd 유도)의 "저장소 아님은 usage 결함" 원칙과
동일하게 `UsageError`(exit 1)로 거부한다. 이 서브커맨드 전체가 git
changeset digest 산정에 의존하므로, git 저장소가 아닌 곳을 가리키면
명시/자립 여부와 무관하게 애초에 할 일이 없다(계약서의 "not a git repo"
usage 결함 항목) — 검증 없이 통과시키면 하위 호출이 나중에
`subject-unresolved`(exit 2, "판정은 했지만 subject 를 못 정함")로
잘못 분류해버린다("저장소 자체가 없음"과 "저장소는 있는데 subject 를
못 구함"은 서로 다른 사건이다).

`REIN_POLICY_DIR` 은 `hook` 서브커맨드와 정확히 같은 방식으로 처리한다
(`rein.cli._resolve_policy_dir()` 를 그대로 재사용, 검증 없이 명시 값
신뢰) — 이 axis 는 이 함수의 관심사가 아니다.

project_root 자립 규칙(명시 값이 없을 때) 자체도 `hook` 서브커맨드
(`rein.cli._resolve_project_root(payload)`)와 다르다 — 그 함수는 hook
payload 의 `cwd` 필드에서 유도하고, git 저장소가 "확인된 저장소 아님"
으로 판정되면 **그 cwd 자체로 폴백**한다(hook 이벤트는 project_root 를
못 구해도 판정을 포기할 수 없으므로, 최후의 수단으로 payload cwd 를
받아들인다). 반면 이 서브커맨드는 사람/스킬이 셸에서 직접 호출하는
CLI 다 — 유도 출발점은 `payload["cwd"]` 가 아니라 프로세스의 실제
`os.getcwd()` 이고, git 저장소가 아니면(확인된 저장소 아님이든 판단
불능이든) **폴백하지 않고 usage/env 결함으로 명시 거부**한다(exit 1).
"""
import os

from rein import cli as rein_cli
from rein.capabilities.review.capability import (
    MalformedReviewResponse,
    REQUIREMENT_NAME as CAPABILITY_CODE_REVIEW,
    ReviewDigestMismatch,
    ReviewVerdictNotPass,
    issue_code_review_evidence,
)
from rein.capabilities.security.capability import (
    MalformedSecurityReviewResponse,
    REQUIREMENT_NAME as CAPABILITY_SECURITY_REVIEW,
    SecurityReviewDigestMismatch,
    SecurityReviewVerdictNotPass,
    issue_security_review_evidence,
)
from rein.kernel.changeset import SUBJECT_EMPTY, SUBJECT_UNRESOLVED
from rein.kernel.policy import DIGEST_SCOPE_STRICT, PolicyLoadError
from rein.platform.git.facts import (
    review_digest,
    review_subject_paths,
    sensitive_security_subject,
    strict_security_digest,
    strict_security_subject,
    worktree_changeset,
)
from rein.platform.sqlite.store import LedgerVerifiedEvidenceSource
from rein.platform.storage.local import LocalStateRoot

# 이 서브커맨드가 지원하는 capability 2종 — 고정 5종 Requirement Contract
# (`rein.kernel.requirement.REQUIREMENT_NAMES`) 의 부분집합이다. 나머지
# 3종(active_task/tests_passed/user_approval)은 이 서브커맨드의 범위 밖
# (task 6.1 wave 3 ③-a DoD 는 code_review/security_review 만 지정).
SUPPORTED_CAPABILITIES = (CAPABILITY_CODE_REVIEW, CAPABILITY_SECURITY_REVIEW)

# 발급 거부 사유 — 고정 어휘 (인터페이스 계약, 다른 두 워커가 이 문자열
# 그대로를 소비한다. 임의로 이름을 바꾸지 않는다).
REASON_DIGEST_MISMATCH = "digest-mismatch"
REASON_SUBJECT_EMPTY = "subject-empty"
REASON_SUBJECT_UNRESOLVED = "subject-unresolved"
REASON_VERDICT_NOT_PASS = "verdict-not-pass"
REASON_MALFORMED = "malformed"


class UsageError(Exception):
    """usage/env 결함 — 호출자(`bin/rein`)가 exit 1 로 매핑한다.

    unknown capability / missing args(`bin/rein` 의 인자 파싱 소관) /
    not a git repo / policy version 메타데이터를 읽을 수 없음(손상·
    모호한 git 상태) 이 여기 속한다 — 전부 "리뷰 판정 자체를 시작할 수
    없는" 환경 결함이지, "리뷰는 진행했지만 조건이 안 맞아 거부"인
    `RefusalError` 와는 다른 사건이다.
    """


class RefusalError(Exception):
    """발급 거부 — 호출자가 exit 2 + `{"issued": false, "reason": ...}` 로 매핑한다.

    `reason` 은 위 5종 고정 어휘 중 하나. `detail` 은 사람이 읽는
    원인(stderr 전용, stdout JSON 에는 싣지 않는다 — 인터페이스 계약).
    """

    def __init__(self, reason, detail):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def _validate_capability(capability):
    if capability not in SUPPORTED_CAPABILITIES:
        raise UsageError(
            "unknown capability {!r} (supported: {})".format(
                capability, ", ".join(SUPPORTED_CAPABILITIES)
            )
        )


def _resolve_project_root():
    """`REIN_PROJECT_ROOT` 우선, 없으면 `os.getcwd()` 에서 git toplevel 유도.

    모듈 docstring "project_root 자립 규칙" 절 참조 — `hook` 서브커맨드의
    `rein.cli._resolve_project_root(payload)` 와 달리 non-git cwd 로
    폴백하지 않는다. `_run_git_show_toplevel`/`_GitInvocationError` 는
    `rein.cli` 가 이미 "실행 자체 실패"와 "확인된 저장소 아님"을 구분해
    둔 것을 그대로 재사용한다(중복 구현 없음) — 이 함수는 그 결과를
    "확인된 저장소" 만 받아들이는 더 좁은 정책으로 소비할 뿐이다.

    **명시 `REIN_PROJECT_ROOT` 도 이 git 검증을 거친다** (Medium finding,
    code review round 1 — 이전에는 명시 값을 검증 없이 그대로 반환했다.
    그 결과 non-git 경로를 명시하면 이 함수 자체는 실패하지 않고 통과해
    버렸고, 하위 호출(`_current_subject_digest` 등)이 그 경로에서 git
    조회에 실패하며 `subject-unresolved`(exit 2, "판정은 진행했지만
    subject 를 못 정함")로 귀결됐다 — 모듈 docstring이 명시한 이 서브
    커맨드 자신의 계약("git 저장소가 아니면 usage/env 결함으로 명시
    거부", exit 1)과 어긋난다. `hook` 서브커맨드의 `_resolve_project_root
    (payload)` 는 명시 값을 검증 없이 신뢰하는 별도 계약을 갖지만(hook
    payload 기반 자동 판정 경로 — 이 함수의 관심사가 아니다), 이 CLI
    서브커맨드는 사람/스킬이 셸에서 직접 호출하므로 "저장소 아님은
    usage 결함" 원칙을 명시 값에도 동일하게 적용한다. 반환값은 검증에
    성공한 `explicit` 그대로다(git toplevel 로 치환하지 않는다) — 호출자가
    명시한 경로가 저장소 내부의 서브디렉터리여도 그 값 자체를 존중한다,
    비-명시(cwd 유도) 분기가 `toplevel` 을 반환하는 것과는 다른 정책이다.
    """
    explicit = os.environ.get(rein_cli.ENV_PROJECT_ROOT)
    if explicit:
        try:
            explicit_toplevel = rein_cli._run_git_show_toplevel(explicit)
        except rein_cli._GitInvocationError as error:
            raise UsageError(
                "cannot resolve project root from explicit {}={!r}: "
                "{}".format(rein_cli.ENV_PROJECT_ROOT, explicit, error)
            ) from error
        if not explicit_toplevel or not os.path.isdir(explicit_toplevel):
            raise UsageError(
                "not a git repository (or any parent up to the mount "
                "point): {!r} (from explicit {}={!r})".format(
                    explicit, rein_cli.ENV_PROJECT_ROOT, explicit
                )
            )
        return explicit
    cwd = os.getcwd()
    try:
        toplevel = rein_cli._run_git_show_toplevel(cwd)
    except rein_cli._GitInvocationError as error:
        raise UsageError(
            "cannot resolve project root from cwd {!r}: {}".format(
                cwd, error
            )
        ) from error
    if not toplevel or not os.path.isdir(toplevel):
        raise UsageError(
            "not a git repository (or any parent up to the mount point): "
            "{!r}".format(cwd)
        )
    return toplevel


def _current_subject_digest(capability, project_root, policy_dir):
    """evaluate() 가 조회할 것과 동일한 subject digest 를 계산한다.

    `_build_fact_resolvers()` 의 `_resolve_digest`/`_resolve_sensitive_
    digest` 와 같은 함수 호출로 구성된다(모듈 docstring "digest 계산
    재사용" 절) — `policy_version_cache` 공유는 evaluate() 내부의 단일
    cycle I/O 최적화일 뿐 값에 영향이 없으므로 여기서는 재현하지 않는다
    (캐시 없이 `_security_digest_scope_profile(policy_dir)` 를 직접
    호출 — 그 함수 자신의 하위호환 무캐시 경로).
    """
    if capability == CAPABILITY_CODE_REVIEW:
        _digest, _sensitive, _tag, _paths, review_digest = (
            rein_cli._git_changeset_facts(project_root)
        )
        return review_digest

    digest_scope = rein_cli._security_digest_scope_profile(policy_dir)
    if digest_scope == DIGEST_SCOPE_STRICT:
        return strict_security_digest(cwd=project_root)
    (
        _digest,
        sensitive_digest,
        _tag,
        _paths,
        _review_digest,
    ) = rein_cli._git_changeset_facts(project_root)
    return sensitive_digest


def _resolve_policy_version(capability, policy_dir):
    """evaluate() 의 단일 스냅샷 policy.version 로더를 그대로 재사용한다.

    `declared={capability}` — 이 서브커맨드는 정확히 그 capability 하나만
    발급하려는 것이므로, `_load_policy_version_fact()` 의 Medium D
    랜드마인 가드(증거 발급형 capability 가 declared 인데 버전 파일이
    진짜 없으면 조용히 넘기지 않고 설정 오류로 명시 차단)가 그대로
    적용된다 — evaluate() 와 같은 기준으로 "버전 없이 발급 시도"를
    막는다.
    """
    declared = frozenset((capability,))
    try:
        return rein_cli._load_policy_version_fact(policy_dir, declared)
    except PolicyLoadError as error:
        raise UsageError(str(error)) from error


def print_digest(capability):
    """`--print-digest` 본체 — 현재 subject digest 문자열을 반환한다.

    두 capability 모두 닫힌 값 계약 2상태(`SUBJECT_EMPTY`/
    `SUBJECT_UNRESOLVED`, spec §3.6)는 정당한 반환값이다 — 그대로
    돌려준다(호출자가 그 값을 `--reviewed-digest` 에 그대로 실어 보내면
    `issue()` 가 사유별로 거부한다). **2026-08-20 개정(Phase 7 웨이브 3
    ③-a)**: code_review 는 이전에는 `changeset.digest`(센티널 계약
    없음)를 썼지만, 이제 `changeset.review_digest` 를 쓰므로 security_
    review 와 동일하게 두 센티널을 낼 수 있다 — 더 이상 "code_review 는
    센티널 계약이 없다"는 구분이 성립하지 않는다. 아래 `if not digest`
    는 두 capability 모두 이론상 도달하지 않는 방어적 fallback 이다(둘
    다 지금은 항상 실제 digest 아니면 두 센티널 중 하나를 낸다) — 미래에
    새 산정 경로가 진짜 `None`/빈 문자열을 낼 가능성에 대비해 남긴다.
    """
    _validate_capability(capability)
    project_root = _resolve_project_root()
    policy_dir = rein_cli._resolve_policy_dir()
    try:
        digest = _current_subject_digest(capability, project_root, policy_dir)
    except PolicyLoadError as error:
        raise UsageError(str(error)) from error
    if not digest:
        raise UsageError(
            "could not compute current {!r} subject digest (project root "
            "{!r} did not yield a resolvable git changeset)".format(
                capability, project_root
            )
        )
    return digest


def print_subject(capability):
    """`--print-subject` 본체 — **원자적** (subject digest, 인증된 경로 목록)
    스냅샷을 한 번의 changeset 조회로 함께 반환한다.

    **Phase 7 웨이브 3 ③-a code review round 3, High-1** — 이전
    `--print-subject-paths`(code_review 전용, 이 함수가 대체)와 `--print-
    digest` 를 래퍼가 별도 호출 2번으로 얻으면, 두 호출 사이에 트리가
    바뀔 수 있어(비원자적) digest 가 실제로 흡수하는 경로와 래퍼가
    "인증됐다"고 믿는 경로가 갈라질 수 있었다 — 그 갈라짐이 실제로 발생
    하면 아직 검토되지 않은(두 번째 호출 시점에 새로 나타난) untracked
    코드가 "인증된 경로" 목록에서 누락된 채로 리뷰 통과 후 evidence 만
    발급되는 구멍이 생긴다. 이 함수는 두 값 모두 **같은 changeset 조회
    한 번**에서 파생시켜 그 구멍을 막는다 — 아래 두 capability 분기가
    각각 정확히 하나의 changeset-정의 git 호출(`worktree_changeset()`
    또는 `strict_security_subject_paths()` 내부의 `git diff --cached`)만
    수행하고, paths 는 그 결과에 대한 순수 계산(허용목록/태그 필터)이다.

    두 capability 모두 지원한다(이전 `--print-subject-paths` 는 code_
    review 전용으로 표면을 최소화했었다 — security 축도 이제 이 진입점을
    통해 인증된 경로 목록을 노출해야 `agents/security-reviewer.md` 가
    "허용목록 배제"가 아니라 "발급기가 실제로 증명하는 경로 집합"을 리뷰
    대상으로 삼을 수 있다, spec §3.6/§14 sensitive∩allowlist 보존 요구
    — Finding 2).

    반환: `(subject, paths)` 2-tuple.
    - `subject` — `print_digest()` 가 내는 것과 정확히 같은 값 공간
      (`SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`/`"sha256:<hex>"`).
    - `paths` — `subject` 가 실제 digest 문자열일 때만 그 digest 가
      흡수한 경로 tuple 이고, `subject` 가 센티널(두 상태 중 하나)이면
      **항상 빈 tuple** — "센티널 subject → paths 빈 값" 은 이 CLI 모드의
      값 공간 계약이다(호출자가 paths 만 보고 "인증된 대상 있음"을
      추론하는 실수를 막는다 — 센티널일 때 paths 가 비어 있지 않으면
      그 자체가 이 함수의 버그다).

    capability 별 계산 경로 (둘 다 각자의 profile 전용 조합 함수 —
    `rein.platform.git.facts` 의 `review_digest`/`review_subject_paths`,
    `strict_security_subject`, `sensitive_security_subject` — 를 그대로
    호출할 뿐, 새 판정 로직을 여기서 도입하지 않는다):
    - code_review: `worktree_changeset()` 한 번 → `review_digest(changeset)`
      로 subject, `review_subject_paths(changeset)` 로 paths(같은
      `changeset` 인스턴스에서 파생 — 두 번째 git 호출 없음).
    - security_review: `_security_digest_scope_profile()` 로 프로필을 먼저
      확인한 뒤, strict 면 `strict_security_subject()`, 아니면(sensitive
      기본값) `sensitive_security_subject()` 를 호출한다 — 두 함수 모두
      이미 (subject, paths) 원자적 반환 계약을 내부에서 지킨다(각 함수
      자신의 docstring 참조).
    """
    _validate_capability(capability)
    project_root = _resolve_project_root()

    if capability == CAPABILITY_CODE_REVIEW:
        changeset = worktree_changeset(cwd=project_root)
        if changeset is None:
            raise UsageError(
                "could not compute current {!r} subject (project root "
                "{!r} did not yield a resolvable git changeset)".format(
                    capability, project_root
                )
            )
        subject = review_digest(changeset, cwd=project_root)
        if subject in (SUBJECT_EMPTY, SUBJECT_UNRESOLVED):
            return subject, ()
        return subject, review_subject_paths(changeset)

    policy_dir = rein_cli._resolve_policy_dir()
    try:
        digest_scope = rein_cli._security_digest_scope_profile(policy_dir)
    except PolicyLoadError as error:
        raise UsageError(str(error)) from error
    if digest_scope == DIGEST_SCOPE_STRICT:
        return strict_security_subject(cwd=project_root)
    return sensitive_security_subject(cwd=project_root)


def issue(capability, verdict, reviewed_digest):
    """`--verdict`/`--reviewed-digest` 본체 — 발급 성공 시 `Evidence` 를 반환한다.

    실패는 전부 예외다(침묵 실패 금지, capability 모듈들의 관례와
    동일) — `UsageError`(exit 1 대상) 또는 `RefusalError`(exit 2 대상,
    `reason` 이 고정 5종 어휘 중 하나).

    security_review 의 두 센티널(`SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`)은
    `issue_security_review_evidence()` 자신도 거부하지만(단일
    `ValueError`, 사유 구분 없음) — 이 함수는 그 함수를 호출하기 전에
    먼저 현재 subject 값을 확인해 두 사유를 구분한다(호출자 계약
    브리프의 "distinguish by the recomputed current subject value" 지시
    그대로). 이 사전 확인은 `issue_security_review_evidence()` 자신의
    검증 순서(먼저 subject, 그 다음 response 파싱)와 같은 순서이므로
    이중 판정이 아니라 같은 판정을 더 이른 지점에서 사유까지 붙여
    반복하는 것뿐이다.
    """
    _validate_capability(capability)
    project_root = _resolve_project_root()
    policy_dir = rein_cli._resolve_policy_dir()

    policy_version = _resolve_policy_version(capability, policy_dir)
    if policy_version is None:
        raise UsageError(
            "policy version metadata is unavailable for {!r} (policy_dir="
            "{!r}) — cannot issue evidence without a resolvable policy."
            "version fact".format(capability, policy_dir)
        )

    try:
        current_digest = _current_subject_digest(
            capability, project_root, policy_dir
        )
    except PolicyLoadError as error:
        raise UsageError(str(error)) from error

    response = {"verdict": verdict, "reviewed_digest": reviewed_digest}

    if capability == CAPABILITY_CODE_REVIEW:
        # 2026-08-20 개정(Phase 7 웨이브 3 ③-a) — code_review 의 subject
        # 가 `changeset.review_digest` 로 전환되며 security_review 와
        # 동일한 닫힌 값 계약 2상태를 낼 수 있게 됐다. `issue_code_review_
        # evidence()` 자신은 이 두 센티널을 구분하지 않는(단일
        # `ValueError`) 호출자 계약 위반으로 처리하므로, security_review
        # 분기와 동일하게 여기서 먼저 사유를 구분한다(호출자 계약 브리프
        # "distinguish by the recomputed current subject value" 지시,
        # security 분기와 대칭).
        if current_digest == SUBJECT_EMPTY:
            raise RefusalError(
                REASON_SUBJECT_EMPTY,
                "current review changeset is empty — every changed path "
                "is on the review-exemption allowlist, there is no "
                "subject to attach evidence to (code_review is already "
                "satisfied without evidence in this state, spec §3.6 "
                "리뷰 digest 범위 절 closed-value contract)",
            )
        if not current_digest or current_digest == SUBJECT_UNRESOLVED:
            raise RefusalError(
                REASON_SUBJECT_UNRESOLVED,
                "current review changeset digest could not be resolved — "
                "refusing to issue evidence for an undefined subject",
            )
        try:
            evidence = issue_code_review_evidence(
                response, current_digest, policy_version.version
            )
        except MalformedReviewResponse as error:
            raise RefusalError(REASON_MALFORMED, str(error)) from error
        except ReviewVerdictNotPass as error:
            raise RefusalError(REASON_VERDICT_NOT_PASS, str(error)) from error
        except ReviewDigestMismatch as error:
            raise RefusalError(REASON_DIGEST_MISMATCH, str(error)) from error
    else:
        if current_digest == SUBJECT_EMPTY:
            raise RefusalError(
                REASON_SUBJECT_EMPTY,
                "current sensitive changeset is empty — there is no "
                "subject to attach evidence to (security_review is "
                "already satisfied without evidence in this state, spec "
                "§3.6 digest scope profile closed-value contract)",
            )
        if not current_digest or current_digest == SUBJECT_UNRESOLVED:
            raise RefusalError(
                REASON_SUBJECT_UNRESOLVED,
                "current sensitive changeset digest could not be "
                "resolved — refusing to issue evidence for an undefined "
                "subject",
            )
        try:
            evidence = issue_security_review_evidence(
                response, current_digest, policy_version.version
            )
        except MalformedSecurityReviewResponse as error:
            raise RefusalError(REASON_MALFORMED, str(error)) from error
        except SecurityReviewVerdictNotPass as error:
            raise RefusalError(REASON_VERDICT_NOT_PASS, str(error)) from error
        except SecurityReviewDigestMismatch as error:
            raise RefusalError(REASON_DIGEST_MISMATCH, str(error)) from error

    source = LedgerVerifiedEvidenceSource(LocalStateRoot(project_root))
    return source.record_issued(capability, evidence)
