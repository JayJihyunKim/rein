"""YAML subset 파서 (plan D3 — 구현 단계 이관 노트 2).

지원 범위는 의도적으로 좁다 (fail-closed governance 데이터 전용):
- 블록 스타일 중첩 매핑
- 매핑 값 위치의 block sequence (스칼라 항목 또는 매핑 항목)
- 스칼라: plain / 한 줄 quoted ('...' / "...") + 주석(#)

그 밖의 YAML 구문은 전부 로드 시점 명시 에러다 — anchor, alias,
merge key, multi-document, flow style, block scalar, 명시 tag,
tab 들여쓰기 (D3 거부 목록). 조용한 fallback 경로를 만들지 않기 위해
파싱 불가는 어떤 경우에도 None/부분 결과가 아니라 예외로 끝난다.

policy 로더(kernel/policy.py, Task 1.4)와 testing 설정 로더(Task 4.3)가
이 모듈을 공유한다. stdlib only — 외부 YAML 라이브러리 의존 금지.
"""

_QUOTE_CHARS = ("\"", "'")
_COMMENT_MARKER = " #"
_SEQUENCE_MARKER = "- "

# 스칼라 선두 문자 기준 거부 목록 — D3 fail-closed
_REJECTED_SCALAR_PREFIXES = (
    ("&", "YAML anchor is not supported"),
    ("*", "YAML alias is not supported"),
    ("|", "block scalar is not supported"),
    (">", "block scalar is not supported"),
    ("!", "explicit tag is not supported"),
    ("{", "flow style is not supported"),
    ("[", "flow style is not supported"),
)


class YamlSubsetError(ValueError):
    """subset 밖 구문 — source:line 위치와 원인을 담아 명시 실패."""


def parse(text, source):
    """text 를 subset 문법으로 파싱해 최상위 매핑(dict)을 반환한다.

    source 는 에러 메시지에 붙는 파일 경로/이름 (원인 위치 명시 계약).
    """
    tokens = _tokenize(text, source)
    if not tokens:
        return {}
    lineno, indent, content = tokens[0]
    if indent != 0:
        raise YamlSubsetError(
            "{}:{}: top-level content must start at column 0".format(source, lineno)
        )
    if _is_sequence_item(content):
        raise YamlSubsetError(
            "{}:{}: top-level must be a mapping, not a sequence".format(
                source, lineno
            )
        )
    mapping, _ = _parse_mapping(tokens, 0, 0, source)
    return mapping


def _tokenize(text, source):
    """(lineno, indent, content) 목록으로 변환. 문서 단위 거부는 여기서."""
    tokens = []
    for lineno, raw_line in enumerate(text.split("\n"), start=1):
        if "\t" in raw_line:
            raise YamlSubsetError(
                "{}:{}: tab character is not supported".format(source, lineno)
            )
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if (
            stripped == "---"
            or stripped.startswith("--- ")
            or stripped == "..."
        ):
            raise YamlSubsetError(
                "{}:{}: multi-document stream is not supported".format(
                    source, lineno
                )
            )
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        tokens.append((lineno, indent, stripped))
    return tokens


def _is_sequence_item(content):
    return content == "-" or content.startswith(_SEQUENCE_MARKER)


def _parse_block(tokens, index, source):
    """현재 토큰의 형태로 매핑/시퀀스 블록을 판별해 파싱한다."""
    _, indent, content = tokens[index]
    if _is_sequence_item(content):
        return _parse_sequence(tokens, index, indent, source)
    return _parse_mapping(tokens, index, indent, source)


def _parse_mapping(tokens, index, block_indent, source):
    mapping = {}
    while index < len(tokens):
        lineno, indent, content = tokens[index]
        if indent < block_indent:
            break
        if indent > block_indent:
            raise YamlSubsetError(
                "{}:{}: unexpected indentation".format(source, lineno)
            )
        if _is_sequence_item(content):
            raise YamlSubsetError(
                "{}:{}: sequence item where a mapping entry was expected".format(
                    source, lineno
                )
            )
        key, value_text = _split_entry(content, source, lineno)
        if key == "<<":
            raise YamlSubsetError(
                "{}:{}: merge key is not supported".format(source, lineno)
            )
        _check_plain_key(key, source, lineno)
        if key in mapping:
            raise YamlSubsetError(
                "{}:{}: duplicate mapping key {!r}".format(source, lineno, key)
            )
        if value_text:
            mapping[key] = _parse_scalar(value_text, source, lineno)
            index += 1
        else:
            index += 1
            if index >= len(tokens) or tokens[index][1] <= block_indent:
                raise YamlSubsetError(
                    "{}:{}: key {!r} expects an indented block or an inline "
                    "scalar".format(source, lineno, key)
                )
            mapping[key], index = _parse_block(tokens, index, source)
    return mapping, index


def _parse_sequence(tokens, index, block_indent, source):
    items = []
    while index < len(tokens):
        lineno, indent, content = tokens[index]
        if indent < block_indent:
            break
        if indent > block_indent:
            raise YamlSubsetError(
                "{}:{}: unexpected indentation".format(source, lineno)
            )
        if not _is_sequence_item(content):
            # 같은 들여쓰기에서 시퀀스와 매핑 혼합 — subset 밖
            raise YamlSubsetError(
                "{}:{}: mapping entry where a sequence item was expected".format(
                    source, lineno
                )
            )
        if content == "-":
            raise YamlSubsetError(
                "{}:{}: empty sequence item is not supported".format(
                    source, lineno
                )
            )
        remainder = content[1:].lstrip(" ")
        effective_indent = indent + (len(content) - len(remainder))
        if _is_sequence_item(remainder):
            raise YamlSubsetError(
                "{}:{}: nested sequence is not supported".format(source, lineno)
            )
        if _opens_mapping(remainder):
            # 항목이 매핑인 시퀀스 (spec §5.2 testing.commands[] 형태).
            # 토큰을 '- ' 뒤 유효 들여쓰기 기준으로 재작성해 매핑 파서에 태운다
            # — tokens 는 parse() 호출마다 새로 만들어지는 로컬 목록이다.
            tokens[index] = (lineno, effective_indent, remainder)
            value, index = _parse_mapping(
                tokens, index, effective_indent, source
            )
        else:
            value = _parse_scalar(remainder, source, lineno)
            index += 1
        items.append(value)
    return items, index


def _opens_mapping(content):
    """'key: value' / 'key:' 형태인가 — quoted 스칼라는 매핑이 아니다."""
    if content[0] in _QUOTE_CHARS:
        return False
    return ": " in content or content.endswith(":")


def _split_entry(content, source, lineno):
    if content[0] in _QUOTE_CHARS:
        raise YamlSubsetError(
            "{}:{}: quoted mapping key is not supported".format(source, lineno)
        )
    key, separator, rest = content.partition(":")
    if not separator or (rest and not rest.startswith(" ")):
        raise YamlSubsetError(
            "{}:{}: expected 'key: value' mapping entry".format(source, lineno)
        )
    key = key.strip()
    if not key:
        raise YamlSubsetError(
            "{}:{}: mapping entry has an empty key".format(source, lineno)
        )
    value_text = rest.strip()
    if value_text.startswith("#"):
        # 'key:  # 주석' — 값 없음, 블록 오프너로 취급
        value_text = ""
    return key, value_text


def _check_plain_key(key, source, lineno):
    for prefix, message in _REJECTED_SCALAR_PREFIXES:
        if key.startswith(prefix):
            raise YamlSubsetError(
                "{}:{}: {}".format(source, lineno, message)
            )


def _parse_scalar(text, source, lineno):
    if text[0] in _QUOTE_CHARS:
        return _parse_quoted_scalar(text, source, lineno)
    comment_index = text.find(_COMMENT_MARKER)
    if comment_index != -1:
        text = text[:comment_index].rstrip()
    if not text:
        raise YamlSubsetError(
            "{}:{}: scalar value is empty after comment strip".format(
                source, lineno
            )
        )
    first = text[0]
    for prefix, message in _REJECTED_SCALAR_PREFIXES:
        if first == prefix:
            raise YamlSubsetError("{}:{}: {}".format(source, lineno, message))
    return text


def _parse_quoted_scalar(text, source, lineno):
    quote = text[0]
    end = text.find(quote, 1)
    if end == -1:
        raise YamlSubsetError(
            "{}:{}: unterminated quoted scalar (multi-line scalars are not "
            "supported)".format(source, lineno)
        )
    inner = text[1:end]
    trailer = text[end + 1:].strip()
    if trailer and not trailer.startswith("#"):
        raise YamlSubsetError(
            "{}:{}: unexpected content after quoted scalar".format(
                source, lineno
            )
        )
    if quote == "\"" and "\\" in inner:
        # escape 처리를 구현하지 않으므로 조용한 의미 차이를 만들지 않는다
        raise YamlSubsetError(
            "{}:{}: escape sequences are not supported".format(source, lineno)
        )
    return inner
