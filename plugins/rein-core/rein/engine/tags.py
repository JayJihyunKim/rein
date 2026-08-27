"""Change Tag 분류기 (plan Task 2.4 — spec §3.3).

경로 → Tag 3종(code/docs/sensitive) 분류만 담당한다. Tag 는 행동을
직접 결정하지 않는다 — decision/block/allow 류 API 는 이 모듈에
존재하지 않으며 (공개 표면 계약 테스트로 고정), Requirement 연결은
항상 Tag → Policy → Requirements 경유다 (Tag 직접 차단 경로 없음).

분류 규칙의 배포 기본값은 plugins/rein-core/policies/tags.yaml —
plan D7 의 신설 복수 디렉토리로, v1 운영 데이터용 단수 policy/ 와
별개다. 로드는 D3 subset 파서 (kernel/yaml_subset.py) 로만 하고,
subset 밖 구문·폐쇄 스키마 밖 필드는 전부 로드 시점 명시 에러다
(fail-closed — 규칙에 decision 류 필드가 실리는 경로 자체를 차단).

매칭 의미론:
- '/' 없는 pattern 은 경로의 basename 과 매칭 (fnmatch, 대소문자 구분)
- '/' 있는 pattern 은 repo-relative 전체 경로와 매칭 ('*' 는 '/' 포함)
- 위에서 아래로 첫 매치가 이긴다 — 겹침(우선순위)은 선언 순서로 해소
"""
import fnmatch
import os
import posixpath
from collections import namedtuple

from rein.kernel.yaml_subset import YamlSubsetError, parse as _parse_yaml

TAG_CODE = "code"
TAG_DOCS = "docs"
TAG_SENSITIVE = "sensitive"
# spec §3.3 — Tag 는 이 3종뿐
TAG_NAMES = (TAG_CODE, TAG_DOCS, TAG_SENSITIVE)

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
DEFAULT_RULES_PATH = os.path.join(_PLUGIN_ROOT, "policies", "tags.yaml")

# 폐쇄 스키마 — 규칙당 이 2필드뿐. decision/action 류 필드는 로드 에러
_RULE_FIELDS = ("tag", "pattern")

TagRule = namedtuple("TagRule", _RULE_FIELDS)


class TagRulesError(ValueError):
    """tags.yaml 이 폐쇄 스키마를 벗어남 — source·원인을 담아 명시 실패."""


def parse_tag_rules(text, source):
    """tags 규칙 본문을 파싱·검증해 선언 순서 그대로 tuple 로 반환한다.

    source 는 에러 메시지에 붙는 파일 경로/이름 (원인 위치 명시 계약).
    """
    try:
        document = _parse_yaml(text, source)
    except YamlSubsetError as error:
        raise TagRulesError(str(error))
    for key in document:
        if key != "rules":
            raise TagRulesError(
                "{}: unsupported top-level field {!r} (allowed: rules)".format(
                    source, key
                )
            )
    if "rules" not in document:
        raise TagRulesError(
            "{}: tag rules file must declare 'rules'".format(source)
        )
    entries = document["rules"]
    if not isinstance(entries, list):
        raise TagRulesError(
            "{}: field 'rules' must be a block sequence".format(source)
        )
    rules = []
    seen = set()
    for position, entry in enumerate(entries, start=1):
        rules.append(_validate_rule(entry, position, seen, source))
    return tuple(rules)


def load_tag_rules(path=None):
    """규칙 파일 로드 — 미지정 시 배포 기본값 policies/tags.yaml."""
    if path is None:
        path = DEFAULT_RULES_PATH
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise TagRulesError(
            "{}: unreadable tag rules file: {}".format(path, error)
        )
    return parse_tag_rules(text, source=path)


def classify_path(path, rules):
    """repo-relative 경로를 첫 매치 규칙의 Tag 로 분류한다.

    반환값은 평문 태그 이름(str) 또는 무매치 None 그 자체다 — Tag 만으로
    decision 이 나오는 API 는 이 모듈에 없다 (spec §3.3 경유 계약).
    """
    normalized = _normalize_path(path)
    if not normalized:
        return None
    basename = posixpath.basename(normalized)
    for rule in rules:
        if _matches(normalized, basename, rule.pattern):
            return rule.tag
    return None


def _validate_rule(entry, position, seen, source):
    label = "rules[{}]".format(position)
    if not isinstance(entry, dict):
        raise TagRulesError(
            "{}: {} must be a mapping with fields tag, pattern".format(
                source, label
            )
        )
    for key in entry:
        if key not in _RULE_FIELDS:
            raise TagRulesError(
                "{}: {} has unsupported field {!r} (allowed: tag, pattern — "
                "tag rules never carry decision fields)".format(
                    source, label, key
                )
            )
    for field in _RULE_FIELDS:
        if field not in entry:
            raise TagRulesError(
                "{}: {} is missing required field {!r}".format(
                    source, label, field
                )
            )
    tag = entry["tag"]
    if not isinstance(tag, str) or tag not in TAG_NAMES:
        raise TagRulesError(
            "{}: {} field 'tag' must be one of {} (got {!r})".format(
                source, label, ", ".join(TAG_NAMES), tag
            )
        )
    pattern = entry["pattern"]
    if not isinstance(pattern, str) or not pattern.strip():
        raise TagRulesError(
            "{}: {} field 'pattern' must be a non-empty scalar".format(
                source, label
            )
        )
    rule_key = (tag, pattern)
    if rule_key in seen:
        raise TagRulesError(
            "{}: {} is a duplicate rule ({} / {!r})".format(
                source, label, tag, pattern
            )
        )
    seen.add(rule_key)
    return TagRule(tag=tag, pattern=pattern)


def _normalize_path(path):
    """backslash 구분자·'./' 접두어·중복 구분자를 posix 형태로 정규화."""
    if not path:
        return ""
    normalized = posixpath.normpath(path.replace("\\", "/"))
    if normalized in (".", ".."):
        return ""
    return normalized


def _matches(path, basename, pattern):
    if "/" in pattern:
        return fnmatch.fnmatchcase(path, pattern)
    return fnmatch.fnmatchcase(basename, pattern)
