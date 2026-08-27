"""testing capability — tests_passed Evidence 자격 4조건 (plan Task 4.3, spec §5.2).

spec §5.2 (원문 인용):
    "Evidence 자격 조건 4개 (모두 충족 시에만 `tests_passed` 발급):
    1. 선언된 명령: 실행 명령이 선언 목록의 `run` 과 일치 (exact 또는
       선언 prefix + 추가 인자). 미선언 명령 실행은 자격 없음.
    2. runtime_verified 만: Rein Runtime 이 실행을 직접 관측한 경우만
       (spawn + exit code 확인). Agent 의 '테스트 돌렸고 통과했다'
       보고(agent_attested)는 `tests_passed` 로 불인정.
    3. subject = 실행 시점 code digest: 실행 시작 시점의 ChangeSet
       digest 를 subject 로 기록.
    4. 실행 중 변경 무효: 실행 종료 시점 digest 가 시작 시점과 다르면
       Evidence 를 발급하지 않는다."

이 capability 는 `review`/`security` 와 **구조가 다르다** — 그 둘은
"Agent 가 이미 만든 structured response 를 Runtime 이 사후 파싱"하는
형태지만, tests_passed 의 조건 2(runtime_verified 만)는 애초에 사후
파싱으로는 충족될 수 없다: Runtime 이 스스로 spawn 하고 exit code 를
직접 관측해야만 그 결과가 runtime_verified 다. 그래서 이 모듈의 발급
함수(`observe_test_run`)는 review/security 의 `issue_*_evidence(response,
...)` 처럼 이미 만들어진 결과를 받아 검증만 하는 게 아니라, **스스로
명령을 spawn 한다** (stdlib `subprocess`, shell=True 미사용 — shlex 로
토큰화한 argv 그대로 실행해 셸 메타문자 재해석을 막는다). 조건 2는 이
구조 자체로 보장된다 — 이 모듈에는 "이미 실행됐다는 보고를 받아 그대로
Evidence 로 승격하는" 진입점이 없다.

조건 2 는 평가 시점에도 다시 강제한다(`TestsPassedRequirement.evaluate`
가 `producer == PRODUCER_RUNTIME_VERIFIED`를 명시 검사) — 발급 경로가
구조적으로 agent_attested 를 만들 수 없더라도, evidence 저장소에 다른
경로로 agent_attested 레코드가 섞여 들어오는 경우까지 방어한다
(review/security 의 evaluate 가 `result == PASS` 만 재확인하는 것과
달리, 이 requirement 는 producer 축도 재확인한다 — 조건 2 가 review/
security 에는 없는 이 capability 고유의 자격 조건이기 때문이다).

## Tag 결속 — 자기진술이 아니라 실제 경로 재분류로 확정 (사이클 B 리뷰 2회차 High 근본 수리)

`testing.commands[].tag` 는 "어느 Tag ChangeSet 에 대한 증거인가"라는
**범위 선언**이다(spec §5.2 YAML 주석). 1회차 시정은 호출자가 명시하는
`tag` 인자가 `declared.tag` 와 같은지만 문자열로 대조했는데, 이는
호출자의 **자기진술**을 그대로 신뢰하는 것과 다르지 않다 — 호출자가
`tag="docs"` 라고 선언만 하고 실제로는 `code` 경로를 `paths` 로 건네도
그 자기진술만으로 발급이 통과했다(2회차 리뷰 실증). 근본 수리는
자기진술 대신 **신뢰된 tag 분류 규칙(`rein.engine.tags.classify_path` +
호출자가 로드해 건네는 `tag_rules`)으로 `paths` 를 실제로 재분류**해,
전부 `declared.tag` 로 분류될 때만 발급을 진행하는 것이다
(`_verify_paths_classify_to_tag`). 분류 함수는 재구현하지 않고
`rein.engine.tags` 를 import 해 그대로 재사용한다(수정하지 않음 —
capability 는 engine 어휘의 소비자일 뿐 소유자가 아니다). 하나의 path
라도 다른 tag 로 분류되거나(혼합 ChangeSet) 아예 미분류(무매치)면
`ChangesetTagMismatch` — 혼합/불확실 상태를 보수적으로 거부한다.
`tag_rules` 자체가 주어지지 않으면(`None`) 재검증이 불가능하므로
마찬가지로 보수적으로 거부한다("확인 불가 ≠ 결속 확인됨", spec §3.4
"확인 불가 ≠ 충족" 원칙의 이 지점 적용).

평가 시점에도 대칭적으로 강제한다: `TestsPassedRequirement.evaluate` 가
`Evidence.metadata["tag"]` 와 평가 대상 ChangeSet 의 현재 tag
fact(`changeset.tag`)를 비교하는 4번째 축을 검사한다(digest/policy
version/producer 세 축에 추가). 발급 시점에 결속이 성립했더라도, 평가
시점에 그 결속이 지금 실제로 판정 대상인 ChangeSet 의 tag 와 다시
일치하는지 재확인하지 않으면 "결속"이 이름뿐인 metadata 저장에 그친다
(2회차 리뷰 지적 2) — review/security 의 "발급만으로 충족이 아니다,
평가 시점에 축을 재확인한다" 설계 원칙을 tag 축에도 동일하게 적용한
것이다.

## 설정 스키마 (spec §5.2 고정, plan D1 위치)

```yaml
testing:
  commands:
    - id: unit
      run: "pytest tests/unit"     # 선언 명령
      tag: code                     # 어느 Tag ChangeSet 에 대한 증거인가
```

파일 위치는 프로젝트 루트 기준 `.rein/policy/testing.yaml` (plan D1
확정 — `CONFIG_RELATIVE_PATH`). 프로젝트 루트 결합(실제 절대경로 조립)
은 이 모듈 소관이 아니다 — kernel/policy.py 의 `load_policy_file(path)`
와 동일하게, 이 모듈의 `load_testing_config(path)` 도 완성된 경로를
인자로 받는다 (project root 인지는 Runtime/platform 소관, spec §3.1
의존 규칙 — kernel/capability 는 파일시스템 루트 개념을 모른다).

로드는 D3 subset 파서(`kernel/yaml_subset.py`)로만 한다 — subset 밖
구문·폐쇄 스키마 밖 필드는 전부 로드 시점 명시 에러다 (fail-closed,
policy.py/tags.py 와 동일 규율). **파일 부재는 에러가 아니라 '미설정'
이다** — `None` 을 반환한다. 이는 `testing.configured` fact(plan Task
4.4 기본 policy 세트가 이 자격 조건을 게이팅하는 재료)가 조회할 원재료
이지, 이 모듈이 그 fact resolver 자체를 정의하지는 않는다 (등록·배선은
Task 4.4 소관).

`plugins/rein-core/schemas/testing-config.schema.json` 은 **문서 전용
(참조용)** 이다 — 런타임은 그 JSON 파일을 로드하지 않는다. 위 YAML 스키마
검증의 유일한 실행 경로는 이 모듈의 `parse_testing_config`(D3 subset
로더 기반)이다.

Capability 간 직접 의존 금지 (spec §3.1) — 이 모듈은 kernel/engine
어휘만 사용한다 (`rein.engine.tags` 의 TAG_NAMES 는 engine 어휘이지
capability 가 아니다). `review`/`security` capability 는 어떤 형태로도
import 하지 않는다.
"""
import shlex
import subprocess
from datetime import datetime, timezone

from rein.engine.tags import TAG_NAMES, classify_path
from rein.kernel.changeset import content_digest
from rein.kernel.evidence import (
    Evidence,
    PRODUCER_RUNTIME_VERIFIED,
    policy_version_valid,
    subject_matches,
)
from rein.kernel.requirement import Requirement
from rein.kernel.yaml_subset import YamlSubsetError, parse as _parse_yaml

# 고정 5종 계약 이름 (kernel REQUIREMENT_NAMES 원소, spec §3.4)
REQUIREMENT_NAME = "tests_passed"

# 발급 result 어휘 — review/security 와 동일 관례(strict, 변형 승격 없음)
VERDICT_PASS = "PASS"

# 현재 ChangeSet digest fact 키 — review capability 의 `changeset.digest`
# 관례를 따르되 import 로 공유하지 않는다 (capability 간 직접 의존 금지,
# spec §3.1 — 공유는 kernel/engine 어휘 경유만).
FACT_CHANGESET_DIGEST = "changeset.digest"

# 현재 policy version / 호환 선언 fact 키 (spec §3.4 Policy Versioning)
FACT_POLICY_VERSION = "policy.version"
FACT_POLICY_COMPATIBLE_VERSIONS = "policy.compatible_versions"

# 평가 대상 ChangeSet 의 현재 tag fact 키 — 사이클 B 리뷰 2회차 High 시정
# (평가 시점 tag 결속 재확인, 이 capability 고유의 4번째 축). 값 해석
# (경로 → tag 분류)은 review/security 의 `changeset.digest` 관례와
# 동일하게 platform/engine expensive fact resolver 소관이고, 이
# capability 는 값만 조회한다.
FACT_CHANGESET_TAG = "changeset.tag"

# plan D1 — 프로젝트 루트 기준 상대경로. 절대경로 조립은 이 모듈 소관이
# 아니다(모듈 docstring 참조) — 호출자가 project root 와 결합해 사용한다.
CONFIG_RELATIVE_PATH = ".rein/policy/testing.yaml"

# testing.yaml 폐쇄 스키마 — spec §5.2 고정
_TOP_LEVEL_FIELDS = ("testing",)
_TESTING_SECTION_FIELDS = ("commands",)
_COMMAND_FIELDS = ("id", "run", "tag")


class TestingConfigError(ValueError):
    """testing.yaml 이 폐쇄 스키마를 벗어남 — source·원인을 담아 명시 실패."""

    # pytest 는 이름이 'Test' 로 시작하는 클래스를 테스트 클래스로 오인해
    # 수집을 시도한다(__init__ 이 있어 실패 + PytestCollectionWarning) —
    # 도메인 어휘(testing.yaml)상 불가피한 이름 충돌이라 개명 대신 이
    # 표준 pytest 관례로 수집 대상에서 명시 제외한다.
    __test__ = False


class TestsPassedEvidenceRefusal(Exception):
    """tests_passed Evidence 발급 거부 — 사유별 하위 타입의 공통 base.

    호출자(Runtime)는 이 base 하나로 "발급되지 않았다" 부류 전체를 잡을
    수 있고, 하위 타입으로 사유(미선언/실행실패/digest불일치/spawn실패)
    를 구분한다. review/security 의 `*EvidenceRefusal` 계열과 동일한
    설계 원칙 — None 반환으로 미발급을 조용히 넘기지 않는다.
    """

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)


class UndeclaredTestCommand(TestsPassedEvidenceRefusal):
    """실행 명령이 `testing.commands[].run` 어느 것과도 매칭되지 않음.

    exact 매칭도, "선언 prefix + 추가 인자" 매칭도 실패한 경우 (spec
    §5.2 조건 1). config 자체가 없는(미설정) 프로젝트도 이 경로로
    귀결된다 — 선언된 명령이 하나도 없으므로 어떤 실행도 자격이 없다.
    """


class TestRunSpawnError(TestsPassedEvidenceRefusal):
    """명령 spawn 자체가 실패 (명령 not found, 권한 없음 등).

    exit code 를 관측하지 못했으므로 "실행했지만 실패"(TestRunFailed)
    와 다른 사유로 구분한다 — 둘 다 미발급 결과는 같지만 원인이 다르다.
    """

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)


class TestRunFailed(TestsPassedEvidenceRefusal):
    """명령은 spawn 되어 종료했으나 exit code != 0."""

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)


class TestRunDigestMismatch(TestsPassedEvidenceRefusal):
    """실행 시작 시점 digest != 종료 시점 digest — 실행 중 변경 (spec §5.2 조건 4).

    exit code 가 0 이어도(테스트가 "통과"했어도) 발급하지 않는다 — 관측
    창 동안 대상 코드가 바뀌었으므로 그 통과가 무엇을 검증했는지 더 이상
    보장할 수 없다.
    """

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)


class ChangesetTagMismatch(TestsPassedEvidenceRefusal):
    """제공된 ChangeSet 재료가 선언 명령의 tag 와 결속되지 않음.

    `testing.commands[].tag` 는 "어느 Tag ChangeSet 에 대한 증거인가"를
    선언한다(spec §5.2 YAML 주석). 이 예외는 결속 확인 두 단계 중
    어느 쪽이 실패해도 발생한다(사이클 B 리뷰 1·2회차 시정 누적):

    1. **자기진술 축** (1회차): 호출자가 `observe_test_run` 에 명시
       전달하는 `tag` 인자가 매칭된 선언의 `declared.tag` 와 다르면
       — spawn 이전에 즉시 거부한다(가장 싼 확인, 먼저 검사).
    2. **실분류 축** (2회차 근본 수리): 1이 통과해도, `paths` 를 신뢰된
       `tag_rules` 로 실제 재분류했을 때 하나라도 `declared.tag` 가
       아니면(다른 tag 이거나 무매치) 거부한다 — 호출자가 `tag` 인자로
       "docs" 라고 자기진술만 하고 실제로는 code 경로를 건네는 것을
       막는 것이 이 축의 목적이다. `tag_rules` 자체가 없으면(재검증
       불가) 마찬가지로 보수적으로 거부한다.

    둘 중 어느 축에서 막혔는지는 이 예외의 메시지 문자열로만 구분된다 —
    두 축 모두 "선언 tag 와 결속되지 않은 ChangeSet 에 대해 발급하지
    않는다"는 동일한 거부 방향이므로 별도 하위 타입을 두지 않는다.
    """




def _split(text):
    """shlex 토큰화 — 파싱 불가(짝 안맞는 인용 등)는 None (안전측 실패).

    호출자는 None 을 "매칭 재료로 쓸 수 없음"으로 취급한다 — 예외로
    전파하지 않는 이유: 매칭 판정(선언 여부)의 실패 방향은 항상
    "미선언"(자격 없음)이어야 하고, 파싱 불가한 명령 문자열도 결국
    "선언된 명령과 확인할 수 없다"는 동일한 결론으로 수렴하기 때문이다.
    """
    try:
        return shlex.split(text)
    except ValueError:
        return None


def _validate_command_entry(entry, position, seen_ids, source):
    label = "testing.commands[{}]".format(position)
    if not isinstance(entry, dict):
        raise TestingConfigError(
            "{}: {} must be a mapping with fields {}".format(
                source, label, ", ".join(_COMMAND_FIELDS)
            )
        )
    for key in entry:
        if key not in _COMMAND_FIELDS:
            raise TestingConfigError(
                "{}: {} has unsupported field {!r} (allowed: {})".format(
                    source, label, key, ", ".join(_COMMAND_FIELDS)
                )
            )
    for field_name in _COMMAND_FIELDS:
        if field_name not in entry:
            raise TestingConfigError(
                "{}: {} is missing required field {!r}".format(
                    source, label, field_name
                )
            )
    command_id = entry["id"]
    if not isinstance(command_id, str) or not command_id:
        raise TestingConfigError(
            "{}: {} field 'id' must be a non-empty string".format(
                source, label
            )
        )
    if command_id in seen_ids:
        raise TestingConfigError(
            "{}: {} has duplicate id {!r}".format(source, label, command_id)
        )
    seen_ids.add(command_id)
    run = entry["run"]
    if not isinstance(run, str) or not run.strip():
        raise TestingConfigError(
            "{}: {} field 'run' must be a non-empty string".format(
                source, label
            )
        )
    tag = entry["tag"]
    if not isinstance(tag, str) or tag not in TAG_NAMES:
        raise TestingConfigError(
            "{}: {} field 'tag' must be one of {} (got {!r})".format(
                source, label, ", ".join(TAG_NAMES), tag
            )
        )
    return TestCommand(id=command_id, run=run, tag=tag)


class TestCommand(object):
    """단일 선언 명령 — spec §5.2 YAML `testing.commands[]` 항목 1개.

    namedtuple 대신 명시 클래스를 쓰지 않는 이유는 review/security 가
    이미 dataclass/namedtuple 없이 필드 dict 를 직접 다루기 때문이 아니라
    — 오히려 이 모듈에서는 반복 필드 접근(id/run/tag)의 가독성을 위해
    작은 값 객체가 필요해 별도로 도입한다. 동등성은 필드 값 기준이다.
    """

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)
    __slots__ = ("id", "run", "tag")

    def __init__(self, id, run, tag):  # noqa: A002 - spec 필드명 그대로
        self.id = id
        self.run = run
        self.tag = tag

    def __eq__(self, other):
        if not isinstance(other, TestCommand):
            return NotImplemented
        return (self.id, self.run, self.tag) == (
            other.id,
            other.run,
            other.tag,
        )

    def __hash__(self):
        return hash((self.id, self.run, self.tag))

    def __repr__(self):
        return "TestCommand(id={!r}, run={!r}, tag={!r})".format(
            self.id, self.run, self.tag
        )


class TestingConfig(object):
    """`testing.yaml` 로드 결과 — 선언 명령 tuple 하나를 담는다.

    빈 `commands: []` 도 유효한 TestingConfig다 (파일은 있으나 아직
    명령을 선언하지 않은 상태) — 이는 파일이 아예 없는 경우(`None` 반환,
    '미설정')와 다른 상태다. 두 상태 모두 "선언된 명령이 없으므로 어떤
    실행도 자격 없음" 이라는 같은 결과로 귀결되지만, `testing.configured`
    fact 재료로서는 서로 다른 값이다 (파일 존재 여부가 그 fact 의 본질).
    """

    __test__ = False  # pytest 이름 오인 방지 (TestingConfigError 주석 참조)
    __slots__ = ("commands",)

    def __init__(self, commands):
        self.commands = tuple(commands)

    def __eq__(self, other):
        if not isinstance(other, TestingConfig):
            return NotImplemented
        return self.commands == other.commands

    def __repr__(self):
        return "TestingConfig(commands={!r})".format(self.commands)


def parse_testing_config(text, source):
    """testing.yaml 본문을 파싱·검증해 `TestingConfig` 를 반환한다.

    source 는 에러 메시지에 붙는 파일 경로/이름 (원인 위치 명시 계약).
    폐쇄 스키마: 최상위는 `testing` 하나뿐, 그 아래는 `commands` 하나뿐,
    각 명령 항목은 `id`/`run`/`tag` 셋뿐 — 그 밖의 필드는 전부 로드
    시점 명시 에러다 (policy.py/tags.py 와 동일 D3 규율).
    """
    try:
        document = _parse_yaml(text, source)
    except YamlSubsetError as error:
        raise TestingConfigError(str(error))
    for key in document:
        if key not in _TOP_LEVEL_FIELDS:
            raise TestingConfigError(
                "{}: unsupported top-level field {!r} (allowed: {})".format(
                    source, key, ", ".join(_TOP_LEVEL_FIELDS)
                )
            )
    if "testing" not in document:
        raise TestingConfigError(
            "{}: testing config file must declare 'testing'".format(source)
        )
    testing_section = document["testing"]
    if not isinstance(testing_section, dict):
        raise TestingConfigError(
            "{}: field 'testing' must be a mapping".format(source)
        )
    for key in testing_section:
        if key not in _TESTING_SECTION_FIELDS:
            raise TestingConfigError(
                "{}: field 'testing' has unsupported key {!r} "
                "(allowed: {})".format(
                    source, key, ", ".join(_TESTING_SECTION_FIELDS)
                )
            )
    if "commands" not in testing_section:
        raise TestingConfigError(
            "{}: field 'testing' must declare 'commands'".format(source)
        )
    commands_raw = testing_section["commands"]
    if not isinstance(commands_raw, list):
        raise TestingConfigError(
            "{}: field 'testing.commands' must be a block sequence".format(
                source
            )
        )
    seen_ids = set()
    commands = tuple(
        _validate_command_entry(entry, position, seen_ids, source)
        for position, entry in enumerate(commands_raw, start=1)
    )
    return TestingConfig(commands=commands)


def load_testing_config(path):
    """단일 testing.yaml 파일 로드.

    파일 부재는 에러가 아니라 `None`("미설정", `testing.configured` fact
    재료 — 모듈 docstring 참조). 존재하지만 읽기 실패(권한 등)나 폐쇄
    스키마 위반은 `TestingConfigError` — 관대한 보정 없이 명시 실패
    (fail-closed 규율, policy.py `load_policy_file` 과 동일 방향이되
    파일 부재만은 policy 의 "0개" 관례와 달리 명시적으로 `None` 을 반환
    해 '설정 파일이 아예 없다'와 '있지만 0개 명령이다'를 구분한다).
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise TestingConfigError(
            "{}: unreadable testing config file: {}".format(path, error)
        )
    return parse_testing_config(text, source=path)


def find_declared_command(config, command):
    """`command` 가 `config` 의 선언 명령 중 하나와 매칭되는지 판정한다.

    매칭 = 토큰화된 `command` 가 어느 선언 `run` 의 토큰 목록을 **접두어
    (prefix)로 포함**하는 경우 (spec §5.2 조건 1 "exact 또는 선언 prefix
    + 추가 인자"). exact 매칭은 토큰 목록 전체가 같은 경우로, prefix
    매칭의 특수(길이 0의 추가 인자) 사례로 자연히 포함된다. 토큰 단위
    비교이므로 공백 개수 차이 등 문자열 표면 차이에 영향받지 않는다 —
    반대로 "pytest"(선언) 가 "pytest2"(실행)의 접두 **문자열**이라는
    이유만으로 오매칭되는 것도 막는다(토큰 "pytest" != 토큰 "pytest2").

    `config` 가 `None`(미설정 프로젝트) 이거나 `command`/선언 `run` 이
    shlex 로 토큰화 불가능하면(짝 안맞는 인용 등) 매칭 재료가 없으므로
    미선언으로 판정한다(안전측 — `_split` 문서 참조).

    첫 매치를 반환한다(`TestCommand` 또는 `None`) — 선언 순서가 둘 이상
    매칭 가능해도 모호성 해소 규칙은 두지 않는다(첫 선언 우선, tags.py
    의 "위에서 아래로 첫 매치가 이긴다" 관례와 동형).
    """
    if config is None:
        return None
    command_tokens = _split(command)
    if command_tokens is None:
        return None
    for declared in config.commands:
        declared_tokens = _split(declared.run)
        if declared_tokens is None:
            continue
        if not declared_tokens:
            continue
        if command_tokens[: len(declared_tokens)] == declared_tokens:
            return declared
    return None


def _spawn(tokens, cwd, timeout):
    """stdlib subprocess 로 spawn 하고 exit code 를 직접 관측한다 (spec §5.2 조건 2).

    `shell=True` 를 쓰지 않는다 — argv 를 그대로 실행해 셸 메타문자
    재해석(연결·파이프·치환)이 개입할 여지를 없앤다. spawn 자체가
    실패하면(명령 not found, 권한 없음) `TestRunSpawnError` 로 구분해
    올린다 — exit code 를 아예 관측하지 못한 상태다.
    """
    try:
        completed = subprocess.run(
            tokens,
            cwd=cwd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TestRunSpawnError(
            "failed to spawn test command {!r}: {}".format(tokens, error)
        )
    return completed.returncode


def _verify_paths_classify_to_tag(paths, tag_rules, expected_tag, command):
    """`paths` 전부가 `tag_rules` 로 `expected_tag` 로 재분류되는지 검증한다.

    사이클 B 리뷰 2회차 High 근본 수리 — 호출자의 `tag` 자기진술
    (1회차 시정)만으로는 "docs 로 선언된 명령이 code 경로를 건네도
    통과"하는 우회가 가능했다(리뷰어 실증). 이 함수는 자기진술을
    신뢰하지 않고, `rein.engine.tags.classify_path`(재구현하지 않고
    그대로 재사용)로 각 path 를 실제 재분류해 결과를 `expected_tag` 와
    대조한다.

    거부 방향(모두 `ChangesetTagMismatch`):
    - `tag_rules` 가 `None` — 재검증 자체가 불가능하다. "확인 불가"를
      "결속 확인됨"으로 승격하지 않고 보수적으로 거부한다(spec §3.4
      "확인 불가 ≠ 충족" 원칙).
    - 어느 path 든 분류 결과가 `expected_tag` 가 아님(다른 Tag 이거나
      규칙 무매치로 `None`) — 혼합/불확실 ChangeSet 에 대한 실행은
      보수적으로 거부한다. 하나라도 걸리면 즉시 멈춘다(전부 통과해야
      함 — 부분 일치로 완화하지 않는다).

    `paths` 가 빈 튜플이면 검사할 대상이 없으므로 통과한다(공허하게
    참) — kernel `ChangeSet`/`content_digest` 도 빈 경로 집합을 유효한
    입력으로 받아들이는 것과 같은 방향이다.
    """
    if tag_rules is None:
        raise ChangesetTagMismatch(
            "no tag classification rules were provided to verify command "
            "{!r}'s ChangeSet paths against declared tag {!r} — "
            "re-verification is impossible so the request is rejected "
            "conservatively (spec §3.4 확인 불가 ≠ 충족)".format(
                command, expected_tag
            )
        )
    for path in paths:
        actual_tag = classify_path(path, tag_rules)
        if actual_tag != expected_tag:
            raise ChangesetTagMismatch(
                "path {!r} classifies as {!r} per tag_rules, not declared "
                "tag {!r} for command {!r} — mixed or misclassified "
                "ChangeSets are rejected conservatively (spec §5.2, "
                "cycle B round 2 High fix)".format(
                    path, actual_tag, expected_tag, command
                )
            )


def observe_test_run(
    command,
    config,
    tag,
    paths,
    read_content,
    tag_rules,
    policy_version,
    cwd=None,
    created_at=None,
    timeout=None,
):
    """Runtime 관측 함수 — 4조건을 전부 결합해서만 Evidence 를 발급한다.

    유일한 tests_passed 발급 진입점이다 — review/security 의
    `issue_*_evidence(response, ...)` 처럼 이미 만들어진 판단(agent 의
    자기 보고)을 받아 검증만 하는 함수가 이 모듈에는 없다(조건 2가
    이 capability 고유의 요구이기 때문 — 모듈 docstring 참조). 항상
    다음 순서로 spawn 을 직접 수행한다:

    1. **선언 확인** (조건 1): `command` 가 `config` 의 어느 선언과도
       매칭되지 않으면 spawn 조차 하지 않고 `UndeclaredTestCommand`.
    2. **Tag 결속 확인 — 자기진술 축** (사이클 B 리뷰 1회차 High):
       호출자가 `tag` 인자로 "이 `paths`/`read_content` 는 어느 Tag 의
       ChangeSet 인가"를 명시한다. 이 값이 매칭된 선언의 `declared.tag`
       와 다르면 `ChangesetTagMismatch` — 가장 싼 확인이라 먼저 한다.
    3. **Tag 결속 확인 — 실분류 축** (사이클 B 리뷰 2회차 High 근본
       수리): 2를 통과해도 `tag` 인자는 호출자의 자기진술일 뿐이다 —
       호출자가 "docs" 라고 선언만 하고 실제로는 `code` 경로를 `paths`
       로 건네는 것은 자기진술 축만으로는 막히지 않는다(2회차 리뷰
       실증). `_verify_paths_classify_to_tag` 가 신뢰된 `tag_rules` 로
       `paths` 전부를 실제 재분류해 `declared.tag` 와 대조한다 — 하나
       라도 다르면(다른 tag 이거나 무매치) `ChangesetTagMismatch`.
       `tag_rules` 가 없으면(`None`) 재검증 불가이므로 마찬가지로
       보수적으로 거부한다. 두 축 모두 spawn **이전**에 확인한다.
    4. **시작 digest** (조건 3 준비): `paths`/`read_content` 로 kernel
       `content_digest` 를 호출한다 — digest 계산 자체는 재구현하지
       않고 kernel 함수를 그대로 재사용한다.
    5. **spawn + exit code 관측** (조건 2): `_spawn` 이 직접 관측한다.
    6. **종료 digest**: 같은 `paths`/`read_content` 로 다시 계산한다.
    7. exit code != 0 → `TestRunFailed` (spawn 자체 실패는 이미 5에서
       `TestRunSpawnError` 로 갈라짐).
    8. 종료 digest != 시작 digest → `TestRunDigestMismatch` (조건 4).
    9. 전부 통과 → `Evidence(subject=시작 digest, producer=
       runtime_verified, metadata={"tag": declared.tag}, ...)` (조건 3
       완성 + 결속 tag 기록 — 이 시점의 `declared.tag` 는 이미 실분류로
       검증된 값이다).

    `paths`/`read_content` 는 시작·종료 두 시점 모두 동일한 주입 공급자로
    호출된다 — kernel `changeset.py` 의 "digest 계산은 주입된
    read_content 로만" 계약을 그대로 따른다(테스트 결정성 확보, kernel
    모듈 docstring 참조). `read_content` 가 매 호출마다 파일시스템의
    현재 내용을 그대로 반영하는 한(테스트에서는 실제 tmp 파일을 읽는
    공급자), spawn 된 명령이 `paths` 안의 파일을 스스로 변경하는 경우도
    "실행 중 변경"으로 정확히 감지된다.

    `tag_rules` 는 `rein.engine.tags.TagRule` tuple(예:
    `parse_tag_rules`/`load_tag_rules` 산출물)이다 — 이 모듈은 규칙을
    해석·소유하지 않고 `classify_path` 호출에 그대로 전달만 한다.
    """
    declared = find_declared_command(config, command)
    if declared is None:
        raise UndeclaredTestCommand(
            "command {!r} does not match any declared testing.commands[] "
            "entry — undeclared commands are not eligible for tests_passed "
            "(spec §5.2 condition 1)".format(command)
        )
    if tag != declared.tag:
        raise ChangesetTagMismatch(
            "provided ChangeSet tag {!r} does not match declared command "
            "{!r}'s tag {!r} — tests_passed is only issued for the "
            "ChangeSet tag the declared command is bound to".format(
                tag, command, declared.tag
            )
        )
    _verify_paths_classify_to_tag(paths, tag_rules, declared.tag, command)
    start_digest = content_digest(paths, read_content)
    tokens = _split(command)
    exit_code = _spawn(tokens, cwd, timeout)
    end_digest = content_digest(paths, read_content)
    if exit_code != 0:
        raise TestRunFailed(
            "declared command {!r} exited with code {} — no evidence is "
            "issued (spec §5.2)".format(command, exit_code)
        )
    if end_digest != start_digest:
        raise TestRunDigestMismatch(
            "code changed during test execution (start digest {!r} != end "
            "digest {!r}) — no evidence is issued (spec §5.2 condition 4)"
            .format(start_digest, end_digest)
        )
    if created_at is None:
        created_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return Evidence(
        type=REQUIREMENT_NAME,
        subject=start_digest,
        result=VERDICT_PASS,
        created_at=created_at,
        # Runtime 이 직접 spawn+exit code 를 관측했다 — agent_attested 로
        # 격하하지 않는다 (spec §5.2 조건 2, PRODUCER 3등급 중 최고 신뢰).
        producer=PRODUCER_RUNTIME_VERIFIED,
        policy_version=policy_version,
        # 이 evidence 가 결속된 Tag ChangeSet — 사이클 B 리뷰 1회차 High
        # 시정. declared.tag 를 그대로 기록한다(호출자가 제공한 `tag` 는
        # 이미 위에서 declared.tag 와 동일함이 확인됐다).
        metadata={"tag": declared.tag},
    )


class TestsPassedRequirement(Requirement):
    """tests_passed Requirement 구현체 — 평가 시점 3축 재확인 (spec §5.2, §3.6).

    evidence 존재만으로 충족이 아니다 — review/security 의 두 축(digest·
    policy version)에 더해 **producer 축**을 추가로 검사한다:
    - digest 축: subject 가 평가 시점의 현재 digest 와 일치.
    - policy version 축: 레코드의 policy_version 이 현재 version 과
      일치하거나 호환 선언에 명시된 경우만 인정.
    - **producer 축** (이 requirement 고유, spec §5.2 조건 2): 레코드의
      producer 가 정확히 `runtime_verified` 여야 한다. 발급 함수
      (`observe_test_run`)는 구조적으로 이 producer 만 만들 수 있지만,
      evidence 저장소에 다른 경로로 만들어진 agent_attested 레코드가
      섞여 들어와도 이 축이 방어한다 — "Agent 의 보고는 tests_passed 로
      불인정" 을 발급 시점뿐 아니라 평가 시점에도 다시 강제한다.
    - **tag 축** (이 requirement 고유, 사이클 B 리뷰 2회차 High 시정):
      레코드의 `metadata["tag"]`(발급 시점에 실분류로 검증된
      `declared.tag`)가 **지금 이 평가가 대상으로 하는 ChangeSet 의
      현재 tag**(`changeset.tag` fact)와 일치해야 한다. 발급 시점의
      tag 결속이 아무리 견고해도, 평가 시점에 재확인하지 않으면
      "docs 로 결속돼 발급된 evidence 를 code ChangeSet 평가에 재사용"
      하는 것을 막을 방법이 없다 — digest/version 축이 "그때 검증된
      것이 지금도 유효한가"를 재확인하는 것과 동일한 이유로, tag 축도
      평가 시점에 다시 확인한다.
    """

    @property
    def name(self):
        return REQUIREMENT_NAME

    def evaluate(self, context):
        """충족 여부(bool) — digest·producer·policy version·tag 4축이 결합된 PASS 레코드가 있는가.

        review/security 의 evaluate 와 마찬가지로, 현재 digest/version
        fact 를 확보하지 못하면(부재) 재확인이 불가능하므로 보수적으로
        미충족이다 — 확인 불가를 충족으로 승격하지 않는다. tag 축도
        동일한 방향: 현재 tag fact(`changeset.tag`)를 확보하지 못하면
        레코드의 결속 tag 를 무엇과도 비교할 수 없으므로 보수적으로
        미충족이다.
        """
        current_digest = context.fact(FACT_CHANGESET_DIGEST)
        if not current_digest:
            return False
        current_version = context.fact(FACT_POLICY_VERSION)
        if not current_version:
            return False
        current_tag = context.fact(FACT_CHANGESET_TAG)
        if not current_tag:
            return False
        compatible_versions = context.fact(FACT_POLICY_COMPATIBLE_VERSIONS)
        if compatible_versions is None:
            compatible_versions = ()
        for record in context.evidence_for(REQUIREMENT_NAME):
            if record.type != REQUIREMENT_NAME:
                continue
            if record.result != VERDICT_PASS:
                continue
            if record.producer != PRODUCER_RUNTIME_VERIFIED:
                # agent_attested(또는 그 외 producer) 레코드는 결과·
                # digest 가 모두 일치해도 충족 재료가 아니다 — spec §5.2
                # 조건 2 의 평가 시점 재확인 (클래스 docstring 참조)
                continue
            metadata = record.metadata or {}
            if metadata.get("tag") != current_tag:
                # 결속 tag 가 지금 평가 대상 ChangeSet 의 tag 와 다르면
                # digest/version/producer 가 전부 일치해도 충족 재료가
                # 아니다 — 사이클 B 리뷰 2회차 High 시정 (클래스
                # docstring "tag 축" 참조)
                continue
            if not subject_matches(record, current_digest):
                continue
            if not policy_version_valid(
                record, current_version, compatible_versions
            ):
                continue
            return True
        return False


def register_tests_passed(registry):
    """RequirementRegistry 에 tests_passed 구현체를 명시 등록한다.

    등록은 이 함수 호출로만 일어난다 — import 부작용 등록 금지
    (spec §3.1 §32: Registry 는 명시적 코드 등록). 등록된 구현체를
    반환한다 (호출자가 동일 인스턴스를 재사용할 수 있게).
    """
    implementation = TestsPassedRequirement()
    registry.register(REQUIREMENT_NAME, implementation)
    return implementation
