"""Policy 폐쇄 스키마 로더 (plan Task 1.4 — spec §3.4, plan D3).

지원 필드는 trigger/when/require/failure_mode 4개뿐이다. 미지 키·
인라인 코드 구문·subset 밖 YAML 은 전부 로드 시점 명시 에러 (파일·원인
명시). 임의 Python/Shell·inline function·직접 ALLOW/BLOCK 반환은
비지원 — 필드 값을 폐쇄 문법(이벤트명/사실 비교값/요구 이름/enum)으로
제한해 코드성 값이 데이터로 위장해 들어오는 경로 자체를 막는다.

독립 완결 계약: engine/runtime.py 의 walking-skeleton 파서와
kernel/__init__ 에 의존하지 않는다 (Task 1.7 이 runtime 을 이 모듈로
재배선). YAML 파싱은 kernel/yaml_subset.py (D3 — Task 4.3 과 공유).

## Policy Versioning — 정책 세트 전체의 명시 버전 (Phase 6 Task 6.C, spec §3.4)

spec §3.4 원문: "Evidence 는 생성 당시 policy version 을 기록. 기본 원칙
= Evidence version 과 현재 version 일치. 호환성을 명시 선언한 경우에만
이전 Evidence 인정. Subject digest 는 policy version 과 독립."

네 개 evidence 발급형 capability(code_review/security_review/
tests_passed/user_approval, `rein/capabilities/*/capability.py`)는
전부 `context.fact("policy.version")` 을 **평가 사이클당 1개의 스칼라
문자열**로 조회하고 `context.fact("policy.compatible_versions")` 를
버전 문자열 collection 으로 조회한다(둘 다 단일 값 — 파일별로 흩어진
값이 아니다). 이 저장소에는 이전까지 "현재 policy version" 의 정의된
출처가 전혀 없었다(config 파일도, 상수도, resolver 도 없음 — 실측,
`rein/cli/__init__.py` 모듈 docstring "여전히 채우지 못한 fact" 절 참조)
— 그래서 이 네 capability 는 fact 결손으로 영구히 미충족이었다.

**설계 결정 — 파일별 독립 버전이 아니라 정책 세트 전체에 단일 버전.**
후보 (a) 정책 파일마다 `version:` 필드를 추가하는 방안은 기각한다 —
capability 가 읽는 `policy.version` fact 는 "지금 매칭된 그 policy 의
버전" 이 아니라 "지금 평가 사이클의 현재 버전" 단일 스칼라이므로, 파일별
버전이 서로 다르면 그 값을 어느 파일에서 가져올지 정의할 수 없다(release
tier 처럼 3개 requirement 가 한 evaluate() 안에서 동시에 검사될 때도
fact 는 하나뿐이다 — evaluator 가 policy 마다 다른 fact 스냅샷을 주입하는
구조가 아니다, `rein/engine/evaluator.py`/`context.py` 는 이 워커의 scope
밖이라 재구조화하지 않는다). 채택한 (b) 는 `load_policies(policy_dir)` 가
스캔하는 **같은 디렉토리**에 예약 파일(`VERSION_FILENAME`)을 두어 그
디렉토리가 표현하는 정책 세트 전체의 버전 하나를 선언하는 것이다 —
"policy version bump" 가 실제 운영에서 파일 하나를 고치는 단일 사건으로
남고(spec §3.4 의 "호환성을 명시 선언" 계약이 원자적으로 유지된다),
capability 가 기대하는 "평가 사이클당 스칼라 하나" 모양과 정확히 일치한다.

`VERSION_FILENAME` 은 4필드 policy 스키마와 다른 폐쇄 스키마
(`VERSION_FIELDS` — `version`/`compatible_versions`)를 쓴다 — 그래서
`load_policies()` 의 `*.yaml` 글롭에 걸리더라도 4필드 스키마로 파싱을
시도하지 않고 명시적으로 건너뛴다(아래 `load_policies` 참조). 버전은
**사람이 관리하는 명시 식별자**다(spec §3.4 "사람이 관리하는 명시
버전이어야 한다" — 내용 해시 자동 산출이면 "호환성 명시 선언"이 성립하지
않고, 오타 수정만으로도 전 evidence 가 무효화된다) — 그래서 이 모듈은
버전 값을 계산하지 않고 파일에 적힌 그대로만 읽는다.

**fail-closed**: 버전 파일 부재·`version` 필드 누락·형식 위반(빈 문자열/
인라인 코드 구문/패턴 불일치)·`compatible_versions` 형식 위반·자기 자신을
`compatible_versions` 에 포함(무의미한 선언 — `policy_version_valid` 는
이미 동등 비교로 자기 버전을 인정하므로 별도 선언은 항상 군더더기이며
이 모듈은 이를 "쓰레기 값"으로 명시 거부한다)은 전부 로드 시점 명시
에러다. 조용한 기본값 대입은 없다 — 확인 불가를 "버전 1로 가정"하는
관용은 spec §3.4 "확인 불가 ≠ 충족" 원칙과 정면 충돌한다.

## digest_scope — security_review subject digest 산정 범위 프로필 (spec §3.6, 2026-08-19)

spec §3.6 "digest scope 프로필" 절 원문(요지): "security_review 의
subject digest 산정 범위는 정책 폴더 스코프 설정으로 프로필 선택이
가능하다. 미선언 기본은 `sensitive`(민감 경로 분류 기반). 정책
폴더의 버전 선언 파일에 `digest_scope: strict` 를 선언하면 그 폴더의
정책 평가에서 digest 는 staged 변경 전체에서 검토 면제 허용목록을
제외한 집합으로 산정된다."

`digest_scope` 는 `VERSION_FILENAME` 예약 파일의 3번째 필드로 얹는다
(`version`/`compatible_versions` 와 물리적으로 같은 파일) — "이
policy_dir 이 표현하는 정책 세트의 성질" 이라는 점에서 policy version
과 동일한 위치에 속하고(둘 다 4필드 policy 스키마가 아니라 정책 세트
전체를 서술하는 메타데이터), `SecurityReviewRequirement.evaluate` 가
읽는 `policy.version`/`policy.compatible_versions` fact 와 마찬가지로
"평가 사이클당 스칼라 하나" 모양이기 때문이다(이 스코프의 subject
digest **산정 함수 자체**는 `rein/platform/git/facts.py` 소관이고,
이 모듈은 어느 프로필을 쓸지 로드만 한다 — kernel 은 git 을 모른다,
spec §3.1). 값 2종(`sensitive`/`strict`) 밖은 미지·malformed 값으로
로드 시점 명시 에러(fail-closed) — 오타 하나가 조용히 `sensitive` 로
격하돼 strict 저장소가 알아채지 못하고 과소검토로 새는 것을 막는다.
"""
import os
import re
from dataclasses import dataclass

from rein.kernel.requirement import (
    UnknownRequirementError,
    validate_requirement_names,
)
from rein.kernel.yaml_subset import YamlSubsetError, parse as _parse_yaml

# spec §3.4 폐쇄 스키마 — 이 4개 밖의 키는 로드 시점 에러
POLICY_FIELDS = ("trigger", "when", "require", "failure_mode")
# spec §3.4 — 판단 실패 시 처리 3종
FAILURE_MODES = ("closed", "open", "ask_user")
# failure_mode 미선언 시 fail-closed 기본값
_DEFAULT_FAILURE_MODE = "closed"

_POLICY_SUFFIX = ".yaml"

# Policy Versioning 폐쇄 스키마 (spec §3.4, 모듈 docstring 참조) — 4필드
# policy 스키마와는 다른 독립 스키마다. `digest_scope` 는 spec §3.6
# "digest scope 프로필" 절(모듈 docstring 하단) 추가 필드.
VERSION_FIELDS = ("version", "compatible_versions", "digest_scope")

# digest_scope 폐쇄 값 2종 (spec §3.6) — 미선언 시 기본은 민감 경로
# 분류 기반(`sensitive`, 기존 의미론). `strict` 는 staged 전체에서 검토
# 면제 허용목록을 제외한 집합으로 subject digest 를 산정한다(산정
# 함수는 `rein/platform/git/facts.py` 소관).
DIGEST_SCOPE_SENSITIVE = "sensitive"
DIGEST_SCOPE_STRICT = "strict"
DIGEST_SCOPES = (DIGEST_SCOPE_SENSITIVE, DIGEST_SCOPE_STRICT)
_DEFAULT_DIGEST_SCOPE = DIGEST_SCOPE_SENSITIVE

# 정책 세트 버전 메타데이터의 예약 파일명 — `load_policies(policy_dir)`
# 의 "*.yaml" 글롭 범위 안에 있어도 4필드 policy 스키마로 파싱하지 않고
# 건너뛴다(모듈 docstring "Policy Versioning" 절). 정책 파일들과 물리적으로
# 같은 디렉토리에 공존시키기 위한 이름 예약이다 — `tags.yaml` 을
# `policies/default/` 밖으로 분리한 것(DirectoryIsolationTest)과 같은
# 문제의 다른 해법: 거기서는 스키마가 다른 파일을 아예 다른 디렉토리로
# 뺐고, 여기서는 로더가 이름으로 명시 인지해 건너뛴다 — 버전 파일은
# "이 policy_dir 이 표현하는 세트가 무엇인가"에 본질적으로 속해 있어
# 디렉토리를 분리하면 오히려 policy_dir 하나만으로 버전을 못 찾는
# 문제가 생기기 때문이다.
VERSION_FILENAME = "_version.yaml"

# version / compatible_versions 스칼라 형태 — spec §3.4 "사람이 관리하는
# 명시 버전"(세미버전 강제 없음, "1"/"2"/"1.0.0"/"v3" 전부 허용). 인라인
# 코드 지표(`_reject_inline_code`)와 별개로, 순수 식별자 형태만 허용해
# 임의 문자열이 값으로 위장해 들어오는 것을 막는다.
_VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# 이벤트명: tool.pre / task.completed 류 평문 식별자만
_EVENT_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]*$")
# 형태 사전검증 — 고정 5종 폐쇄는 아래에서 requirement.validate_requirement_names
# 로 로드 시점에 강제한다 (plan Task 1.5 "로드 시점 명시 에러" 계약)
_REQUIREMENT_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")

# 인라인 코드 구문 지표 — 치환/체이닝/호출/함수 리터럴 (spec §3.4 비지원)
_CODE_INDICATORS = ("$(", "${", "`", ";", "&&", "||", "(", ")", "lambda ")


class PolicyLoadError(ValueError):
    """policy 가 폐쇄 스키마를 벗어남 — 파일·원인을 담아 명시 실패."""


def parse_policy(text, source):
    """policy 본문을 파싱·검증해 4필드 dict 를 반환한다.

    반환 dict 는 4필드를 항상 전부 갖는다 (미선언 필드는 안전 기본값).
    """
    try:
        document = _parse_yaml(text, source)
    except YamlSubsetError as error:
        raise PolicyLoadError(str(error))
    for key in document:
        if key not in POLICY_FIELDS:
            raise PolicyLoadError(
                "{}: unsupported policy field {!r} (allowed: {})".format(
                    source, key, ", ".join(POLICY_FIELDS)
                )
            )
    return {
        "trigger": _validate_trigger(document, source),
        "when": _validate_when(document, source),
        "require": _validate_require(document, source),
        "failure_mode": _validate_failure_mode(document, source),
    }


def load_policy_file(path):
    """단일 policy 파일 로드 — 에러 메시지의 source 는 파일 경로."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise PolicyLoadError("{}: unreadable policy file: {}".format(path, error))
    return parse_policy(text, source=path)


def load_policies(policy_dir):
    """디렉토리의 *.yaml policy 전부 로드.

    policy_dir 미설정(None/빈 값)은 policy 0개 — 평가는 기본 ALLOW 로
    간다 (spec §3.4). 반환 형태는 engine 평가기가 쓰는
    {"policy_id", "fields"} 목록 (Task 1.7 재배선 대상).
    """
    if not policy_dir:
        return []
    try:
        entries = sorted(os.listdir(policy_dir))
    except OSError as error:
        raise PolicyLoadError(
            "{}: unreadable policy directory: {}".format(policy_dir, error)
        )
    loaded = []
    for name in entries:
        if not name.endswith(_POLICY_SUFFIX):
            continue
        if name == VERSION_FILENAME:
            # 버전 메타데이터 예약 파일 — 4필드 policy 스키마 대상이
            # 아니다 (모듈 docstring "Policy Versioning" 절). 이 파일의
            # 값은 `load_policy_version(policy_dir)` 로만 읽는다.
            continue
        path = os.path.join(policy_dir, name)
        loaded.append(
            {
                "policy_id": name[: -len(_POLICY_SUFFIX)],
                "fields": load_policy_file(path),
            }
        )
    return loaded


def _reject_inline_code(value, field_path, source, error_cls=PolicyLoadError):
    """4필드 policy 검증기와 Policy Versioning 검증기가 공유하는 검사.

    `error_cls` 로 호출자가 어떤 예외 타입으로 실패해야 하는지 고른다 —
    기본값은 4필드 policy 스키마의 `PolicyLoadError`, 버전 검증기
    (`_validate_version`/`_validate_compatible_versions`)는
    `PolicyVersionError` 를 넘겨 "버전 메타데이터 문제는 전부
    PolicyVersionError" 라는 이 모듈의 계약을 재구현 없이 유지한다.
    """
    for indicator in _CODE_INDICATORS:
        if indicator in value:
            raise error_cls(
                "{}: inline code syntax is not supported in policy field "
                "{!r} (found {!r})".format(source, field_path, indicator)
            )


def _validate_trigger(document, source):
    if "trigger" not in document:
        raise PolicyLoadError(
            "{}: policy must declare a trigger".format(source)
        )
    value = document["trigger"]
    if not isinstance(value, str):
        raise PolicyLoadError(
            "{}: field 'trigger' must be a scalar event name".format(source)
        )
    _reject_inline_code(value, "trigger", source)
    if not _EVENT_NAME_PATTERN.match(value):
        raise PolicyLoadError(
            "{}: field 'trigger' must be a plain event name, got {!r}".format(
                source, value
            )
        )
    return value


def _validate_when(document, source):
    value = document.get("when", {})
    if not isinstance(value, dict):
        raise PolicyLoadError(
            "{}: field 'when' must be a nested mapping".format(source)
        )
    conditions = {}
    for key, entry in value.items():
        field_path = "when.{}".format(key)
        _reject_inline_code(key, "when", source)
        if not isinstance(entry, str):
            raise PolicyLoadError(
                "{}: field {!r} must be a scalar comparison value".format(
                    source, field_path
                )
            )
        _reject_inline_code(entry, field_path, source)
        conditions[key] = entry
    return conditions


def _validate_require(document, source):
    value = document.get("require", [])
    if not isinstance(value, list):
        raise PolicyLoadError(
            "{}: field 'require' must be a block sequence".format(source)
        )
    requirements = []
    for item in value:
        if not isinstance(item, str):
            raise PolicyLoadError(
                "{}: field 'require' entries must be scalar requirement "
                "names".format(source)
            )
        _reject_inline_code(item, "require", source)
        if not _REQUIREMENT_NAME_PATTERN.match(item):
            raise PolicyLoadError(
                "{}: field 'require' entry {!r} is not a plain requirement "
                "name".format(source, item)
            )
        requirements.append(item)
    try:
        validate_requirement_names(requirements, source=source)
    except UnknownRequirementError as error:
        # 로더 소비자는 단일 예외 타입(PolicyLoadError)만 전제한다
        raise PolicyLoadError(str(error))
    return requirements


def _validate_failure_mode(document, source):
    value = document.get("failure_mode", _DEFAULT_FAILURE_MODE)
    if not isinstance(value, str) or value not in FAILURE_MODES:
        raise PolicyLoadError(
            "{}: field 'failure_mode' must be one of {} (got {!r})".format(
                source, ", ".join(FAILURE_MODES), value
            )
        )
    return value


# ---------------------------------------------------------------------------
# Policy Versioning — 모듈 docstring "Policy Versioning" 절 참조.


class PolicyVersionError(PolicyLoadError):
    """policy version 메타데이터가 폐쇄 스키마를 벗어남 — 파일·원인 명시.

    `PolicyLoadError` 의 하위 타입이다 — 호출자가 "policy 설정이 뭔가
    깨졌다"를 단일 `except PolicyLoadError`로 뭉뚱그려 잡을 수 있으면서도
    (`load_policies`/`load_policy_file` 과 동일한 catch 표면), 필요하면
    `except PolicyVersionError`로 버전 메타데이터 문제만 구분해 잡을 수
    있다.
    """


@dataclass(frozen=True)
class PolicyVersion:
    """정책 세트 전체의 명시 버전 — `load_policy_version()` 의 반환 형태.

    - `version`: 현재 버전 식별자 (비어 있지 않은 str). capability 가
      조회하는 `policy.version` fact 에 그대로 주입되는 값이다 (호출자
      계약 — 이 클래스 자체는 fact 배선을 모른다, kernel 은 platform 을
      모른다).
    - `compatible_versions`: 이전 버전 중 여전히 유효한 것으로 명시
      선언된 식별자들의 tuple (기본값 빈 tuple — 선언 없으면 정확히
      일치하는 버전만 유효, spec §3.4 "기본 원칙"). `kernel.evidence.
      policy_version_valid(evidence, current_version, compatible_versions)`
      세 번째 인자에 그대로 전달할 수 있는 모양이다 — 그 함수는 단일
      문자열을 명시 거부하므로(문자 단위 분해 오인정 방지), 여기서도
      항상 tuple 로 정규화한다.
    - `digest_scope`: security_review subject digest 산정 범위 프로필
      (spec §3.6, 모듈 docstring "digest_scope" 절). 기본값
      `_DEFAULT_DIGEST_SCOPE`(=`"sensitive"`) — 버전 파일에 필드
      자체가 없던 기존 fixture/테스트가 계속 같은 값으로 비교되도록
      (`DIGEST_SCOPES` 폐쇄 값이지만, 이 값 객체 자체는 파서가 이미
      검증한 값을 전달받는다는 전제로 재검증하지 않는다 — `version`
      필드가 이 dataclass 안에서 `_VERSION_PATTERN` 을 재검증하지
      않는 것과 동일한 방향, 검증은 `parse_policy_version`/
      `_validate_digest_scope` 소관).
    """

    version: str
    compatible_versions: tuple = ()
    digest_scope: str = _DEFAULT_DIGEST_SCOPE

    def __post_init__(self):
        if isinstance(self.compatible_versions, (str, bytes)):
            # kernel.evidence.policy_version_valid 와 동일한 방어 —
            # tuple("1.0") == ("1", ".", "0") 오인정을 이 값 객체
            # 생성 시점에도 차단한다 (호출자가 실수로 단일 문자열을
            # 넘겨도 여기서 즉시 드러난다).
            raise TypeError(
                "compatible_versions must be a collection of version "
                "strings, not a single string: {!r}".format(
                    self.compatible_versions
                )
            )
        object.__setattr__(
            self, "compatible_versions", tuple(self.compatible_versions)
        )


def parse_policy_version(text, source):
    """policy version 메타데이터 본문을 파싱·검증해 `PolicyVersion` 을 반환한다.

    허용 필드는 `version`(필수)·`compatible_versions`(선택, 기본 빈
    목록)·`digest_scope`(선택, 기본 `sensitive` — spec §3.6) 뿐이다 —
    그 밖의 키는 4필드 policy 스키마와 동일한 원칙으로 로드 시점 명시
    에러다 (미지 필드는 절대 조용히 무시되지 않는다).
    """
    try:
        document = _parse_yaml(text, source)
    except YamlSubsetError as error:
        raise PolicyVersionError(str(error))
    for key in document:
        if key not in VERSION_FIELDS:
            raise PolicyVersionError(
                "{}: unsupported policy version field {!r} (allowed: "
                "{})".format(source, key, ", ".join(VERSION_FIELDS))
            )
    version = _validate_version(document, source)
    compatible_versions = _validate_compatible_versions(
        document, source, version
    )
    digest_scope = _validate_digest_scope(document, source)
    return PolicyVersion(
        version=version,
        compatible_versions=compatible_versions,
        digest_scope=digest_scope,
    )


def load_policy_version(policy_dir):
    """`policy_dir` 의 예약 버전 파일(`VERSION_FILENAME`)을 로드한다 (spec §3.4).

    `policy_dir` 은 `load_policies(policy_dir)` 에 넘기는 것과 **같은
    디렉토리**여야 한다 — 그 디렉토리가 표현하는 정책 세트 전체의 버전을
    선언하는 것이 이 파일의 역할이다 (모듈 docstring "설계 결정" 절).

    호출자 계약 (다음 계층 — cli/engine fact 배선 — 이 이 함수를 쓴다):
    반환된 `PolicyVersion.version`/`.compatible_versions` 를 각각
    `policy.version`/`policy.compatible_versions` fact 값으로 그대로
    주입하면 된다. 이 함수는 fact 이름도, EvaluationContext 도 모른다
    (kernel 은 platform/engine 을 모른다, spec §3.1).

    fail-closed — 아래 전부 `PolicyVersionError`(파일·원인 명시), 조용한
    기본값 대입 없음:
    - `policy_dir` 미설정(None/빈 값) — "현재 버전"의 암묵적 기본값은
      없다(빈 policy_dir 이 `load_policies([])`처럼 "정책 0개"로 흡수
      되는 것과 의도적으로 다른 방향이다 — 정책이 0개인 것과 버전을
      모르는 것은 서로 다른 실패이고, 후자를 전자처럼 조용히 넘기면
      capability 의 "확인 불가 ≠ 충족" 판정이 우회 없이도 시작부터
      말이 안 되는 상태로 실행된다).
    - 버전 파일 자체가 없거나 읽을 수 없음(권한 등).
    - `version` 필드 누락·빈 문자열·인라인 코드 구문·패턴 불일치.
    - `compatible_versions` 형식 위반·항목 패턴 불일치·중복 항목·자기
      자신(`version`)을 포함.
    """
    if not policy_dir:
        raise PolicyVersionError(
            "policy_dir must be provided to load policy version metadata "
            "— there is no implicit default version (spec §3.4, "
            "fail-closed)"
        )
    path = os.path.join(policy_dir, VERSION_FILENAME)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise PolicyVersionError(
            "{}: unreadable policy version file: {}".format(path, error)
        )
    return parse_policy_version(text, source=path)


def _validate_version(document, source):
    if "version" not in document:
        raise PolicyVersionError(
            "{}: policy version file must declare 'version' (spec §3.4 "
            "— no implicit default)".format(source)
        )
    value = document["version"]
    if not isinstance(value, str) or not value:
        raise PolicyVersionError(
            "{}: field 'version' must be a non-empty scalar string".format(
                source
            )
        )
    _reject_inline_code(value, "version", source, error_cls=PolicyVersionError)
    if not _VERSION_PATTERN.match(value):
        raise PolicyVersionError(
            "{}: field 'version' must match {} (got {!r})".format(
                source, _VERSION_PATTERN.pattern, value
            )
        )
    return value


def _validate_compatible_versions(document, source, current_version):
    value = document.get("compatible_versions", [])
    if not isinstance(value, list):
        raise PolicyVersionError(
            "{}: field 'compatible_versions' must be a block "
            "sequence".format(source)
        )
    versions = []
    seen = set()
    for item in value:
        if not isinstance(item, str) or not item:
            raise PolicyVersionError(
                "{}: field 'compatible_versions' entries must be "
                "non-empty scalar version strings, got {!r}".format(
                    source, item
                )
            )
        _reject_inline_code(
            item, "compatible_versions", source, error_cls=PolicyVersionError
        )
        if not _VERSION_PATTERN.match(item):
            raise PolicyVersionError(
                "{}: field 'compatible_versions' entry {!r} does not "
                "match {}".format(source, item, _VERSION_PATTERN.pattern)
            )
        if item == current_version:
            raise PolicyVersionError(
                "{}: field 'compatible_versions' must not list the "
                "current version {!r} itself — a version is trivially "
                "valid against itself already (kernel.evidence."
                "policy_version_valid's exact-match branch), so "
                "declaring self-compatibility is meaningless and is "
                "rejected as a garbage entry".format(source, current_version)
            )
        if item in seen:
            raise PolicyVersionError(
                "{}: field 'compatible_versions' has duplicate entry "
                "{!r}".format(source, item)
            )
        seen.add(item)
        versions.append(item)
    return tuple(versions)


def _validate_digest_scope(document, source):
    """`digest_scope` 필드 검증 (spec §3.6 "digest scope 프로필" 절).

    미선언 → `_DEFAULT_DIGEST_SCOPE`(`sensitive`, 기존 의미론 유지).
    명시 `sensitive`/`strict` → 그 값 그대로. 그 외(오타·미지 값)는
    로드 시점 명시 에러 — fail-closed. 조용히 `sensitive` 로 격하하면
    strict 를 의도한 저장소가 실수로 관대한 프로필로 새는 것을 알아채지
    못한다(모듈 docstring "digest_scope" 절의 근거).
    """
    value = document.get("digest_scope", _DEFAULT_DIGEST_SCOPE)
    if not isinstance(value, str) or value not in DIGEST_SCOPES:
        raise PolicyVersionError(
            "{}: field 'digest_scope' must be one of {} (got {!r}) — spec "
            "§3.6 digest scope 프로필, unknown values fail closed at load "
            "time".format(source, ", ".join(DIGEST_SCOPES), value)
        )
    return value
