"""plan Task 4.5(b) — marker 기반 우회 인식 경로 부재 (spec §3.6 §21, §11.1).

spec §3.6 (§21, 원문 인용):
    "... `.skip-review`/`.skip-security` 류 marker 우회는 제거."

spec §11.1 배제 목록(원문 인용):
    "marker 파일 기반 우회 (`.skip-review` 류, §21)"

v1 계열 도구는 `.skip-review`/`.skip-security` 형태의 marker 파일을
프로젝트에 두면 리뷰/보안 게이트를 건너뛸 수 있는 개념(brainstorm/spec
문서가 "제거 대상"으로 명시하는 그 패턴)을 가리킨다 — 이 스위트는 v2
Governance runtime 에 그 패턴이 **애초에 존재하지 않는다**를 두 각도로
고정한다:

(a) **행위 검증**: marker 파일이 실제로 디스크에 존재하는 상태에서
    실제 `engine.evaluator.evaluate()` 평가 사이클을 돌려도 BLOCK
    결과가 marker 부재 시와 완전히 동일하다 — 애초에 어떤 fact
    resolver·capability 도 이 파일들을 조회 대상으로 삼지 않으므로,
    파일 존재 자체가 판정에 개입할 경로가 없다. **평가 실행 시점의
    CWD 를 실제로 marker 파일이 있는 디렉토리로 옮긴 채** 평가한다
    (`_chdir` — 사이클 C 리뷰 1회차 Medium 시정): 그냥 무관한 디렉토리
    에서 evaluate 를 부르고 "안 바뀌었다"고 주장하면, marker 가 "안
    보이는 곳"에 있었을 뿐이라 공허하게 참인 주장이 된다. marker 가
    실제로 **보이는 위치**(evaluate 호출 시점의 CWD)에 있어도 무시된다는
    것까지 결합해야 "인식 경로가 없다"는 주장이 의미를 갖는다.
(b) **정적 검사**: `rein/` 소스 트리 전체에서 **주석·docstring 을 뺀
    실제 코드**를 훑어 marker 파일명을 인식하는 코드가 0건임을
    고정한다 — import 구조만 보는 `test_capability_isolation.py` 의
    AST 검사와 달리, 경로 인식은 문자열 비교·`open()` 호출 등 다양한
    형태로 나타날 수 있으므로 원문(코드 부분)을 substring 으로 훑는다.
    **주석·docstring 은 스캔에서 제외한다** — 이 capability 자신의
    docstring 이 "왜 marker 인식 경로가 없는가"를 설명하며 그 marker
    이름을 실제로 인용하는 것은 정상적인 설계 문서화이지 인식 경로가
    아니다(예: `rein/capabilities/approval/capability.py` 의 모듈
    docstring). 주석/docstring 까지 문자열 매치 대상에 넣으면 그런
    정당한 문서화조차 이 테스트를 깨뜨리게 된다 — "인식 경로 0건"과
    "문자열 언급 0건"은 다른 주장이고, 이 스위트가 고정하는 것은
    전자다.

**자기매칭 함정 회피**: 이 파일(테스트 파일) 자신이 marker 파일명을
리터럴로 담고 있으면, 정적 검사 스코프가 (미래의 리팩터로) `tests/`
까지 넓어질 경우 자기 자신을 위반으로 오탐할 수 있다. 두 겹으로
막는다 — (1) 정적 검사 스코프를 `rein/` 패키지 트리 하나로 고정하고
(`tests/` 는 원천적으로 스캔 대상 밖), (2) 이 파일 안의 marker 문자열은
전부 문자열 조립(`+`)으로 생성해 grep 스코프가 실수로 넓어져도 리터럴
매치가 나지 않게 한다.

**정적 검사(b)의 한계 — 조립·난독화된 문자열은 탐지 범위 밖 (의도된
범위, 하드닝 대상 아님, 사이클 C 리뷰 1회차 Medium 시정)**: (b) 는
`marker in code_only` 리터럴 substring 매치다. 만약 `rein/` 소스
어딘가에 이 파일 자신이 쓰는 것과 같은 방식으로 `"." + "skip" + "-" +
"review"` 처럼 **조립해서** marker 를 인식하는 코드가 생긴다면, 조립된
결과 문자열이 소스에 리터럴로 존재하지 않으므로 이 스캔은 잡지
못한다. 이는 구현 누락이 아니라 spec §2.2 위협 모델의 직접 귀결이다
(`test_capability_isolation.py` 가 `importlib.import_module()` 류 동적
import 를 "탐지 범위 밖 — 하드닝 대상 아님"으로 명시하는 것과 동일한
경계): "적대적 우회 하드닝은 명시적 비범위 — 정직한 Agent 가 실수로
marker 인식 코드를 리터럴로 작성하는 것을 막는 규율 장치이지, 그 검사
자체를 능동적으로 우회하려는 시도까지 막는 sandbox 가 아니다." 이
스위트가 보장하는 범위는 정확히 "marker 파일명이 코드에 리터럴로
등장하는 인식 경로가 0건" 까지다.

**Phase 7 웨이브 3 ③-d 확장** — `NoLegacyDualReadRecognitionPathTest`
가 같은 (b) 스캔 도구를 재사용해 별개 대상(legacy v1 marker *파일*
읽기 경로 + 그 판정 결과 심볼)의 부재를 고정한다. (a)/(b)/(위 클래스들)
은 "`.skip-*` 우회 marker를 v2 가 인식하는가"를, 이 신설 클래스는
"legacy(v1) `.codex-reviewed`/`.security-reviewed`/`.review-pending`
marker 를 읽어 판정에 반영하던 dual-read 경로(`authority.
legacy_status` 계열, ③-d 로 삭제)가 재등장했는가"를 묻는다 — 개념은
다르지만 "인식 경로 재도입은 코드 스캔이 즉시 잡는다"는 원칙은 같다.
"""
import ast
import contextlib
import io
import os
import sys
import tempfile
import tokenize
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

_REIN_PACKAGE_ROOT = os.path.join(_PLUGIN_ROOT, "rein")

from rein.engine import evaluator  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import DECISION_BLOCK  # noqa: E402

# 마커 파일명 — 리터럴 하드코딩 대신 조립한다 (모듈 docstring "자기매칭
# 함정 회피" 절). 정적 검사 대상 문자열과 완전히 동일한 값이어야 하므로
# 조립 조각을 바꿀 때는 아래 두 상수를 함께 갱신한다.
_DOT_SKIP = "." + "skip" + "-"
MARKER_REVIEW = _DOT_SKIP + "review"
MARKER_SECURITY = _DOT_SKIP + "security"
MARKERS = (MARKER_REVIEW, MARKER_SECURITY)

# --- Phase 7 웨이브 3 ③-d 정적 회귀 핀 — legacy dual-read 읽기 경로가
# authority.py/evaluator.py(그리고 rein/ 패키지 전체)에 재등장하지 않는다.
# 이 상수/클래스는 ".skip-review" 류(spec §21, 위 MARKERS)와는 다른
# 대상이다 — 저건 "우회 marker 를 v2 가 인식하는 코드가 있는가", 이건
# "legacy(v1) 리뷰/보안 marker *파일*을 읽어 판정에 반영하던 코드
# (`authority.legacy_status` 계열, ③-d 로 삭제됨)가 되살아났는가" 다.
# 같은 스캔 도구(`_code_only`/`_python_files`)를 재사용해 "부재 자체가
# 계약"이라는 동일 원칙으로 고정한다. 리터럴 하드코딩 대신 조립하는
# 이유도 위 MARKERS 와 동일(자기매칭 함정 회피 — 이 파일 자신이 legacy
# marker 이름/심볼 이름을 조립 없이 그대로 쓰면 미래에 스캔 스코프가
# 넓어질 때 자기 자신을 오탐할 수 있다).
_DOT = "."
LEGACY_CODE_REVIEW_STAMP = _DOT + "codex-reviewed"
LEGACY_SECURITY_STAMP = _DOT + "security-reviewed"
LEGACY_REVIEW_PENDING = _DOT + "review-pending"
LEGACY_FILE_MARKERS = (
    LEGACY_CODE_REVIEW_STAMP,
    LEGACY_SECURITY_STAMP,
    LEGACY_REVIEW_PENDING,
)

# 심볼 이름 — 함수/클래스/상수 전부 ③-d 로 authority.py 에서 삭제됐다
# (`legacy_status`/`_legacy_code_review_status`/
# `_legacy_security_review_status`/`_legacy_active_task_status`/
# `_parse_codex_marker`/`_parse_stamp_field`/`_normalize_iso`/
# `LegacyStatus`/`LEGACY_PASS`/`LEGACY_FAIL`/`LEGACY_ABSENT`/
# `LEGACY_STATUSES`/`SOURCE_LEGACY`). **전부를 대표 패턴으로 커버한다**
# (코드리뷰 Medium 시정, 2026-08-24 — 이전 판은 세 갈래만 두고 "이 중
# 하나라도 재도입되면 잡는다"고 주장했지만 `legacy_status`(밑줄 없는
# 공개 진입점)·`_parse_codex_marker`·`_parse_stamp_field`·
# `_normalize_iso`·`LEGACY_PASS` 류 상수는 어느 패턴에도 안 걸려
# 재도입돼도 통과했다):
LEGACY_JUDGE_FN_PREFIX = "_legacy" + "_"
LEGACY_STATUS_TYPE = "Legacy" + "Status"
LEGACY_SOURCE_LABEL = "SOURCE" + "_LEGACY"
LEGACY_STATUS_FN = "legacy" + "_status"
LEGACY_PARSE_MARKER_FN = "_parse_codex" + "_marker"
LEGACY_PARSE_FIELD_FN = "_parse_stamp" + "_field"
LEGACY_NORMALIZE_FN = "_normalize" + "_iso"
# 코드리뷰 Medium 시정 (2026-08-24, round 2) — 광의 "LEGACY_" 접두어
# substring 은 향후 무관한 합법 상수(예: `LEGACY_CONFIG_VERSION`)까지
# 오탐시킨다. 삭제된 4개 상수를 정확히 조립해 개별 고정한다.
LEGACY_CONST_PASS = "LEGACY" + "_PASS"
LEGACY_CONST_FAIL = "LEGACY" + "_FAIL"
LEGACY_CONST_ABSENT = "LEGACY" + "_ABSENT"
LEGACY_CONST_STATUSES = "LEGACY" + "_STATUSES"
LEGACY_SYMBOLS = (
    LEGACY_JUDGE_FN_PREFIX,
    LEGACY_STATUS_TYPE,
    LEGACY_SOURCE_LABEL,
    LEGACY_STATUS_FN,
    LEGACY_PARSE_MARKER_FN,
    LEGACY_PARSE_FIELD_FN,
    LEGACY_NORMALIZE_FN,
    LEGACY_CONST_PASS,
    LEGACY_CONST_FAIL,
    LEGACY_CONST_ABSENT,
    LEGACY_CONST_STATUSES,
)


def _require_user_approval_policy():
    """user_approval 을 fail-closed 로 요구하는 policy fixture.

    spec §21 이 marker 우회 제거를 명시하는 바로 그 requirement 다 —
    v1 개념상 marker 파일로 건너뛸 수 있었던 게이트가 이 requirement 와
    가장 가깝다.
    """
    return {
        "policy_id": "require-approval",
        "fields": kernel_policy.parse_policy(
            "trigger: tool.pre\n"
            "when:\n"
            "  tool: Bash\n"
            "require:\n"
            "  - user_approval\n"
            "failure_mode: closed\n",
            source="<test:require-approval>",
        ),
    }


def _decide():
    """evidence 부재 + 미등록 registry 상태의 평가 1회.

    marker 경로를 조회할 fact resolver 를 아예 배선하지 않는다 — 이
    자체가 "그런 조회 창구가 없다"를 구성으로 보여준다. facts 에도
    project 디렉토리 경로를 담지 않는다: 아래 테스트가 marker 파일을
    실제로 만들어도, 그 경로를 평가 입력으로 넘길 방법 자체가 없다는
    것이 이 스위트가 고정하는 사실이다. 이 함수 자신은 CWD 를 건드리지
    않는다 — "marker 가 보이는 위치에서 호출됐는가" 는 호출자(테스트)
    가 `_chdir` 로 보장한다(모듈 docstring "행위 검증" 절).
    """
    context = EvaluationContext(facts={"tool": "Bash"})
    registry = RequirementRegistry()
    return evaluator.evaluate(
        "tool.pre",
        context,
        [_require_user_approval_policy()],
        registry=registry,
    )


@contextlib.contextmanager
def _chdir(path):
    """`path` 로 CWD 를 옮긴 채 블록을 실행하고, 끝나면 원래 CWD 로 복원한다.

    사이클 C 리뷰 1회차 Medium 시정 — marker 파일을 만드는 것만으로는
    "marker 가 무시된다"는 주장이 공허할 수 있다(애초에 아무 코드도
    그 디렉토리를 보지 않았을 뿐일 수 있으므로). 평가를 **실제로 marker
    가 보이는 위치**(CWD)에서 실행해야 "보여도 무시된다"는 결합
    주장이 성립한다.
    """
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class MarkerFileHasNoEffectTest(unittest.TestCase):
    """(a) — marker 파일이 보이는 위치(CWD)에 있어도 평가 결과를 바꾸지 못한다."""

    def test_marker_files_present_does_not_change_block_decision(self):
        with tempfile.TemporaryDirectory() as project_dir:
            with _chdir(project_dir):
                without_markers = _decide()

                for name in MARKERS:
                    marker_path = os.path.join(project_dir, name)
                    with open(marker_path, "w", encoding="utf-8") as handle:
                        handle.write("this marker must be ignored by v2\n")
                # 주입 전제 가드 — 파일 생성 자체가 실패하면 아래 비교가
                # 공허하게 통과한다. CWD 전제도 함께 고정한다: 지금
                # os.getcwd() 가 실제로 marker 가 있는 그 디렉토리여야
                # 아래 "보이는 위치에서 무시됨" 주장이 의미를 갖는다.
                self.assertEqual(os.getcwd(), os.path.realpath(project_dir))
                self.assertTrue(
                    all(os.path.isfile(name) for name in MARKERS),
                    msg=(
                        "marker 파일 생성 자체가 실패했다 — 아래 비교 "
                        "전제 위반"
                    ),
                )
                with_markers = _decide()

        self.assertEqual(without_markers.decision, DECISION_BLOCK)
        self.assertEqual(with_markers.decision, DECISION_BLOCK)
        # 존재/부재로 reason·policy·missing_requirements 등 어떤 필드도
        # 갈라지지 않는다 — marker 는 판정에 관여할 창구가 없다
        self.assertEqual(without_markers.to_dict(), with_markers.to_dict())

    def test_marker_files_present_alongside_unrelated_evidence_still_blocks(
        self,
    ):
        # marker 파일 + (무관한) 다른 requirement 의 evidence 가 있어도
        # user_approval 자체가 부재면 여전히 BLOCK — marker 가 요구
        # 자체를 무효화하는 경로도 없다. 이번에도 CWD 를 실제로 marker
        # 디렉토리로 옮긴 채 평가한다.
        with tempfile.TemporaryDirectory() as project_dir:
            with _chdir(project_dir):
                for name in MARKERS:
                    with open(name, "w", encoding="utf-8") as handle:
                        handle.write("noop\n")
                self.assertTrue(all(os.path.isfile(name) for name in MARKERS))
                decision = _decide()
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.missing_requirements, ("user_approval",))

    def test_cwd_is_restored_after_the_context_manager_exits(self):
        # `_chdir` 자체의 계약 가드 — 테스트 스위트 전체의 CWD 오염을
        # 방지한다(다른 테스트가 상대경로를 쓸 수 있으므로).
        before = os.getcwd()
        with tempfile.TemporaryDirectory() as project_dir:
            with _chdir(project_dir):
                self.assertEqual(os.getcwd(), os.path.realpath(project_dir))
        self.assertEqual(os.getcwd(), before)


def _python_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            if filename.endswith(".py"):
                yield os.path.join(dirpath, filename)


def _docstring_string_nodes(tree):
    """Module/Class/Function 의 첫 statement 가 문자열이면 그 노드를 낸다.

    Python 의 docstring 규약 그대로다 — `ast.get_docstring` 이 텍스트만
    돌려주는 것과 달리, 여기서는 원문에서 그 구간을 지우기 위한 위치
    정보(`lineno`/`col_offset`/`end_lineno`/`end_col_offset`)가 필요해
    노드 자체를 낸다.
    """
    for node in ast.walk(tree):
        if isinstance(
            node,
            (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef),
        ):
            body = getattr(node, "body", None)
            if not body:
                continue
            first = body[0]
            if (
                isinstance(first, ast.Expr)
                and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)
            ):
                yield first.value


def _content_length(line):
    """줄바꿈 문자를 뺀 내용 길이 — 공백 치환이 개행을 삼키지 않게 한다.

    `_blank_span` 이 "줄 전체"를 지울 때 `len(line)` 을 그대로 쓰면
    끝의 `\\n`(혹은 `\\r\\n`)까지 공백으로 바뀌어 그 줄과 다음 줄이
    이어 붙는다 — 여러 줄에 걸친 docstring 을 지울 때 실측된 버그
    (재현: `rein/engine/context.py` 의 `_resolve` 메서드 docstring).
    """
    if line.endswith("\r\n"):
        return len(line) - 2
    if line.endswith("\n") or line.endswith("\r"):
        return len(line) - 1
    return len(line)


def _byte_col_to_char_col(line, byte_col):
    """`ast` 의 UTF-8 바이트 col_offset 을 문자(코드포인트) 오프셋으로 변환한다.

    CPython 의 `ast` 는 `col_offset`/`end_col_offset` 을 **UTF-8 바이트
    오프셋**으로 낸다 — 이 저장소의 docstring 은 한글이 섞여 멀티바이트
    문자가 흔하므로, 문자 인덱스로 그대로 슬라이싱하면 어긋난다(실측:
    한글이 포함된 한 줄짜리 docstring에서 `end_col_offset` 이 실제 문자
    길이보다 커서 뒤의 개행 문자까지 잘려나가는 버그로 나타났다).
    `tokenize` 는 반대로 str 스트림을 그대로 읽으므로 이미 문자
    오프셋이다 — 이 변환은 `ast` 유래 offset 에만 적용한다.
    """
    encoded = line.encode("utf-8")
    return len(encoded[: min(byte_col, len(encoded))].decode("utf-8"))


def _blank_span(lines, start_line, start_col, end_line, end_col):
    """`lines`(1-based 줄 리스트)의 [start, end) 구간을 공백으로 치환한다.

    문자 수를 보존하며 지우므로(줄 수·다른 토큰의 line/col 은 불변)
    여러 span 을 순서 무관하게 연속 적용할 수 있다. `start_col`/
    `end_col` 은 이미 **문자 오프셋**이어야 한다(`ast` 유래 offset 은
    호출 전에 `_byte_col_to_char_col` 로 변환한다).
    """
    if start_line == end_line:
        line = lines[start_line - 1]
        lines[start_line - 1] = (
            line[:start_col] + " " * (end_col - start_col) + line[end_col:]
        )
        return
    first = lines[start_line - 1]
    first_content_len = _content_length(first)
    first_blank_end = max(start_col, first_content_len)
    lines[start_line - 1] = (
        first[:start_col]
        + " " * (first_blank_end - start_col)
        + first[first_blank_end:]
    )
    for lineno in range(start_line + 1, end_line):
        mid = lines[lineno - 1]
        mid_content_len = _content_length(mid)
        lines[lineno - 1] = " " * mid_content_len + mid[mid_content_len:]
    last = lines[end_line - 1]
    lines[end_line - 1] = " " * end_col + last[end_col:]


def _code_only(source):
    """주석 + docstring 을 공백으로 지운 소스 — 코드 리터럴만 남긴다.

    (b) 스캔이 "marker 인식 경로"(실제 코드의 문자열 리터럴)와 "marker
    개념을 설명하는 문서화"(docstring·주석 속 언급)를 구분하기 위한
    전처리다. `MARKER = ".skip-review"` 같은 실제 코드 문자열은 그대로
    남고, docstring/주석 안의 같은 문자열은 지워진다 — 아래 두 단계:

    1. `ast` 로 Module/Class/Function 의 선두 문자열 statement(=
       docstring 규약)를 찾아 그 구간을 지운다(byte→char offset 변환
       포함, `_byte_col_to_char_col` 참조).
    2. `tokenize` 로 `#` 주석 토큰을 찾아 그 구간을 지운다(1 단계 결과
       에서 실행 — 문자만 공백으로 바뀌었을 뿐 줄 수·컬럼 위치는
       원문과 동일하므로 토큰 위치가 어긋나지 않는다).

    docstring 이 클래스/함수 본문의 유일한 statement 인 경우(이
    저장소의 예외 클래스들에 흔한 패턴), 지운 자리는 공백뿐인 줄로
    남아 더 이상 유효한 Python 문법이 아닐 수 있다 — 이는 의도된
    트레이드오프다: 이 함수의 반환값은 **재컴파일 대상이 아니라 substring
    검색 대상**이고(`tokenize` 는 들여쓰기 일관성만 요구할 뿐 문법
    완전성을 요구하지 않는다), 실제로 `rein/` 하위 전체 파일에 대해
    `_code_only` 가 예외 없이 동작함을 확인했다(46개 파일, 이 스위트
    자체 실행이 그 확인이다).

    문법 오류가 있는 파일은 `SyntaxError` 를, 들여쓰기 자체가 어긋난
    경우(위 트레이드오프 밖의 진짜 손상)는 `tokenize` 의
    `IndentationError`/`TokenizeError` 를 그대로 전파한다 — 조용히
    건너뛰면 스캔 공백을 감추는 셈이 된다(부재 위장 금지 원칙과 동일한
    방향).
    """
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    for string_node in _docstring_string_nodes(tree):
        start_col = _byte_col_to_char_col(
            lines[string_node.lineno - 1], string_node.col_offset
        )
        end_col = _byte_col_to_char_col(
            lines[string_node.end_lineno - 1], string_node.end_col_offset
        )
        _blank_span(
            lines,
            string_node.lineno,
            start_col,
            string_node.end_lineno,
            end_col,
        )
    blanked = "".join(lines)
    for token in tokenize.generate_tokens(io.StringIO(blanked).readline):
        if token.type == tokenize.COMMENT:
            _blank_span(
                lines,
                token.start[0],
                token.start[1],
                token.end[0],
                token.end[1],
            )
    return "".join(lines)


class NoMarkerRecognitionPathTest(unittest.TestCase):
    """(b) — `rein/` 소스의 실제 코드에 marker 파일명 인식 0건 (주석/docstring 제외)."""

    def test_scan_root_excludes_this_bypass_suite_itself(self):
        # 스캔 스코프가 tests/ 를 포함하지 않는다는 전제 자체를 고정한다
        # — 이 전제가 깨지면 이 파일의 MARKERS 상수가 자기 자신을
        # 위반으로 오탐할 것이다 (모듈 docstring "자기매칭 함정 회피" 절)
        this_file = os.path.abspath(__file__)
        self.assertFalse(
            this_file.startswith(_REIN_PACKAGE_ROOT + os.sep),
            msg="bypass 스위트 자신이 스캔 루트(rein/) 밖에 있어야 한다",
        )

    def test_code_only_strips_docstrings_and_comments_but_keeps_code(self):
        # `_code_only` 전제 가드 — docstring/주석 속 언급은 지워지고
        # 실제 코드 리터럴(할당·비교)은 남는다는 구분 자체를 고정한다.
        # 여기서만 마커 리터럴을 직접 쓰지 않고 MARKERS 상수(조립본)를
        # 사용한다 — 이 파일 자체에도 "자기매칭 함정 회피" 원칙을
        # 일관 적용한다.
        sample = (
            '"""module docstring mentions {marker}."""\n'
            "MARK = {marker!r}  # trailing comment mentions {marker}\n"
            "def check(name):\n"
            '    """fn docstring about {marker}."""\n'
            "    if name == {marker!r}:\n"
            "        return True\n"
            "    return False\n"
        ).format(marker=MARKER_REVIEW)
        code_only = _code_only(sample)
        self.assertEqual(code_only.count(MARKER_REVIEW), 2)  # 두 코드 리터럴만
        self.assertNotIn("docstring", code_only)
        self.assertNotIn("comment", code_only)

    def test_marker_filenames_do_not_appear_in_code_under_rein_package(
        self,
    ):
        self.assertTrue(
            os.path.isdir(_REIN_PACKAGE_ROOT),
            msg="스캔 대상 디렉토리 전제가 깨졌다",
        )
        offenders = []
        scanned = 0
        for path in _python_files(_REIN_PACKAGE_ROOT):
            scanned += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            code_only = _code_only(source)
            for marker in MARKERS:
                if marker in code_only:
                    offenders.append((path, marker))
        # 공허한 통과 방지 — rein/ 하위에 실제로 .py 파일이 스캔됐어야
        # "0건"이 의미 있는 결과다
        self.assertGreater(
            scanned,
            0,
            msg="스캔된 .py 파일이 0건이면 아래 부재 단언이 공허하게 통과한다",
        )
        self.assertEqual(
            offenders,
            [],
            msg=(
                "v2 소스의 실제 코드에서 marker 인식 경로 발견 — "
                "`.skip-review`/`.skip-security` 류 marker 우회는 v2 에 "
                "존재해서는 안 된다 (spec §3.6 §21, docstring/주석 속 "
                "설명은 제외됨): {!r}".format(offenders)
            ),
        )


class NoLegacyDualReadRecognitionPathTest(unittest.TestCase):
    """(정적 회귀 핀, Phase 7 웨이브 3 ③-d) — legacy marker *파일* 읽기
    경로(`.codex-reviewed`/`.security-reviewed`/`.review-pending`)와
    그 결과를 나르던 심볼(`_legacy_*`/`LegacyStatus`/`SOURCE_LEGACY`)
    이 `rein/` 패키지 실제 코드에 재등장하지 않는다.

    `NoMarkerRecognitionPathTest` 와 같은 스캔 도구를 재사용하되 대상이
    다르다 — 저건 "우회 marker(`.skip-*`)를 v2 가 인식하는가", 이건
    "legacy(v1) 판정 marker 를 v2 가 다시 읽기 시작했는가". 두 스캔
    모두 `_code_only()`(docstring/주석 제외, 실제 코드 리터럴만)를 거쳐
    같은 "인식 경로 0건" 원칙을 적용한다 — 이 파일이 자기 자신의
    docstring/주석에서 legacy marker 이름을 인용하는 것(위 상수 선언부
    주석, 이 클래스 docstring)은 위반이 아니다(스캔 스코프가 `rein/`
    패키지로 고정돼 있어 `tests/` 는 애초에 스캔 대상이 아니다 — 위
    `test_scan_root_excludes_this_bypass_suite_itself` 와 동일한 전제).
    """

    def test_legacy_marker_filenames_do_not_appear_in_code_under_rein_package(
        self,
    ):
        self.assertTrue(
            os.path.isdir(_REIN_PACKAGE_ROOT),
            msg="스캔 대상 디렉토리 전제가 깨졌다",
        )
        offenders = []
        scanned = 0
        for path in _python_files(_REIN_PACKAGE_ROOT):
            scanned += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            code_only = _code_only(source)
            for marker in LEGACY_FILE_MARKERS:
                if marker in code_only:
                    offenders.append((path, marker))
        self.assertGreater(
            scanned,
            0,
            msg="스캔된 .py 파일이 0건이면 아래 부재 단언이 공허하게 통과한다",
        )
        self.assertEqual(
            offenders,
            [],
            msg=(
                "v2 소스의 실제 코드에서 legacy marker *파일* 읽기 경로 "
                "재발견 — Phase 7 웨이브 3 ③-d 로 이 경로는 완전히 "
                "제거됐다(spec §3.6 판정 상태표 'legacy 제거 후 (종국)' "
                "열, docstring/주석 속 역사적 설명은 제외됨): "
                "{!r}".format(offenders)
            ),
        )

    def test_legacy_judge_symbols_do_not_appear_in_code_under_rein_package(self):
        self.assertTrue(
            os.path.isdir(_REIN_PACKAGE_ROOT),
            msg="스캔 대상 디렉토리 전제가 깨졌다",
        )
        offenders = []
        scanned = 0
        for path in _python_files(_REIN_PACKAGE_ROOT):
            scanned += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            code_only = _code_only(source)
            for symbol in LEGACY_SYMBOLS:
                if symbol in code_only:
                    offenders.append((path, symbol))
        self.assertGreater(
            scanned,
            0,
            msg="스캔된 .py 파일이 0건이면 아래 부재 단언이 공허하게 통과한다",
        )
        self.assertEqual(
            offenders,
            [],
            msg=(
                "v2 소스의 실제 코드에서 legacy 판정 심볼 재발견 — "
                "`legacy_status`/`_legacy_*_status`/`LegacyStatus`/"
                "`SOURCE_LEGACY` 계열은 Phase 7 웨이브 3 ③-d 로 "
                "authority.py 에서 완전히 삭제됐다: {!r}".format(offenders)
            ),
        )


if __name__ == "__main__":
    unittest.main()
