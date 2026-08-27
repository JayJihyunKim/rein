"""보수적 명령 분류기 (plan Task 2.3 — spec §3.2, §6.3).

단순 명령만 정확 분류하고, 복합/불확실은 전부 UNKNOWN 으로 넘긴다.
Fact Resolver 는 Shell Sandbox 가 아니다 — 셸 문법의 완전 파싱을
시도하지 않으며, 판단이 조금이라도 불확실하면 UNKNOWN 이다. UNKNOWN
은 실패가 아니라 정상 fact 값이며, Policy 가 stricter 경로(예:
user_approval 요구)로 처리한다. 위험 작업은 단일 단순 명령으로 실행
하도록 계약한다 (v1 학습: "릴리스 커밋은 add/commit 분리 + 단독
`git commit`").

분류 어휘 (cheap fact `command.type` — kernel/fact.py 예시와 동일):
- git 단순 명령 → ``git.<subcommand>`` (예: git.commit, git.push)
- 그 외 단순 명령 → 첫 토큰의 명령어 단어 그대로 (예: ls, pytest)
- 나머지 전부 → ``unknown``

UNKNOWN 판정 (보수 규칙 — 화이트리스트 방식):
- 인용 밖 구조 메타문자: ``; & | < > ( ) ` $`` 및 개행 (연결·파이프·
  리다이렉션·서브셸·치환·확장 전부). ``$``/백틱은 큰따옴표 안에서도
  활성이므로 그 안에서도 UNKNOWN.
- 인용 밖 백슬래시 (`\\;`·줄 연속·`g\\it` 류 난독화 — 해석하지 않는다).
- 인용 불균형 / 토큰화 실패 / 빈 명령 / 비문자열 입력.
- eval·exec·source·env·sudo·xargs·find 등 다른 명령을 실행·포장하는
  wrapper, 셸 인터프리터 호출 (``bash -c`` 포함 일체), 인라인 코드
  플래그를 동반한 인터프리터 (``python3 -c`` 등).
- 할당 접두 (``FOO=bar cmd``), 경로 형태 첫 토큰 (``./run.sh``),
  git 전역 옵션 (``git -C <path> commit`` — 대상 저장소가 명령 문자열
  만으로 확정되지 않는다).

의도된 비목표: 인용 문자열 **내부**는 데이터다 — `echo 'git commit'`
은 echo 로 분류된다 (v1 이 텍스트 `git commit` 을 실행 절로 오인한
사례의 클래스 제거, spec §6.3). 인자 수준의 의미 분석(예: awk 스크립트
본문)은 하지 않는다 — 그것은 해당 명령 라벨에 대한 Policy 소관이다.

대소문자 정규화 규약 (라벨은 casefold 소문자 정규형, 보안 리뷰 수정):
macOS 등 대소문자 비구분(case-insensitive) 파일시스템에서는 선두
토큰의 대소문자와 무관하게 **동일한 바이너리**가 resolve 된다
(``Sudo``/``sudo``, ``Bash``/``bash`` 는 같은 실행 파일). 분류기가
대소문자를 구분해 wrapper/shell/interpreter/git 판정을 내리면, 선두
단어의 대소문자만 바꾸는 것으로 "판단 불가 → unknown" 계약을 우회할
수 있다 (fail-open — 예: ``Bash -c 'rm -rf /'`` 가 예전엔 단순 명령
``Bash`` 로 오분류됐다). 따라서:
- wrapper(``_OPAQUE_WRAPPERS``)/shell(``_SHELLS``)/인터프리터
  (``_INTERPRETER_CODE_FLAGS``)/git 판정은 선두 토큰을
  ``str.casefold()`` 한 값으로 한다. ``str.lower()`` 대신 casefold 를
  쓰는 이유는 Python 문서가 명시하는 caseless 비교 표준 방법이기
  때문 (ASCII 범위에서는 둘이 동치이지만, 이후 `_COMMAND_WORD` 의
  ASCII 제약이 완화될 경우를 대비한 방어적 선택).
- 반환 라벨 자체도 casefold 정규형(소문자)으로 통일한다. 즉
  ``Git commit`` 은 ``git.commit`` (소문자 ``git commit`` 과 동일 라벨)
  로, 일반 명령 ``LS -la`` 는 ``ls`` 로 수렴한다. 근거(spec §3.2 —
  Fact Resolver 는 Shell Sandbox 아님): 실행되는 바이너리가 대소문자와
  무관하게 동일하다면, 그 바이너리에 걸리는 policy 매칭
  (예: ``command.type: rm`` 강화 정책)도 대소문자 변형에 의해 우회되면
  안 된다 — 대소문자 변형이 "새로운 정상 라벨"로 승격되는 게 아니라,
  기존 소문자 형태와 **최소한 동일한 보수성**을 갖도록 라벨을
  정규화한다. git 서브커맨드 토큰 자체(``tokens[1]``)는 정규화하지
  않는다 — ``_GIT_SUBCOMMAND`` 는 여전히 소문자만 인정하며, 대문자
  서브커맨드(예: ``GIT COMMIT``)는 UNKNOWN 으로 넘어간다 (실제 git
  서브커맨드 이름 자체가 대소문자 구분이므로 과대 분류가 아니다).
- ASCII 게이트는 그대로 유지된다: ``_COMMAND_WORD`` 는 ASCII 문자만
  허용하므로, 유니코드 동형이의(homoglyph) 문자로 wrapper 이름을
  흉내내도(예: 키릴 ``ѕudo``) casefold 매칭 이전에 이미 UNKNOWN 으로
  걸러진다 — casefold 도입이 ASCII 제약을 느슨하게 하지 않았음을
  회귀 테스트로 고정한다.
"""
import re
import shlex

# unknown 은 정상 fact 값 — Policy when 절이 문자열로 비교한다
UNKNOWN = "unknown"
# 이 분류가 실리는 fact key (kernel/fact.py 의 점 표기 네임스페이스)
FACT_KEY = "command.type"

# 인용 밖에서 하나라도 등장하면 구조 판단 불가 → UNKNOWN.
# ( ; & | ) 연결, ( < > ) 리다이렉션(heredoc `<<` 포함), 서브셸 괄호,
# 백틱/달러(치환·확장), 개행(다중 문장).
_STRUCTURAL_META = frozenset(";&|<>()`$\n\r")

# 다른 명령을 실행하거나 감싸는 wrapper — 내부를 들여다보지 않는다
_OPAQUE_WRAPPERS = frozenset(
    {
        "eval",
        "exec",
        "source",
        "command",
        "builtin",
        "env",
        "sudo",
        "doas",
        "su",
        "nohup",
        "setsid",
        "time",
        "timeout",
        "stdbuf",
        "nice",
        "ionice",
        "xargs",
        "watch",
        "chroot",
        "script",
        "parallel",
        # find 는 -exec/-execdir/-ok/-delete 로 실행·파괴 동작을 내장한다
        # — 옵션 유무를 해석하지 않고 통째로 불투명 취급
        "find",
    }
)

# 셸 인터프리터 — `bash -c` 는 물론 `sh script.sh` 도 내용 불명
_SHELLS = frozenset(
    {"sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh"}
)

# 인라인 코드 플래그를 동반하면 UNKNOWN 인 인터프리터.
# 플래그 없는 호출(`python3 -m unittest`)은 해당 명령 라벨로 분류된다.
_INTERPRETER_CODE_FLAGS = {
    "python": ("-c",),
    "python2": ("-c",),
    "python3": ("-c",),
    "node": ("-e", "--eval", "-p", "--print"),
    "ruby": ("-e",),
    "perl": ("-e", "-E"),
}

# 분류 가능한 명령어 단어 — 경로(/)·할당(=)·특수문자 시작은 제외
_COMMAND_WORD = re.compile(r"^[A-Za-z][A-Za-z0-9_.+-]*$")
# git subcommand 형태 (commit, push, rev-parse, ...)
_GIT_SUBCOMMAND = re.compile(r"^[a-z][a-z0-9-]*$")


def classify(command):
    """명령 문자열을 command.type 라벨 또는 UNKNOWN 으로 분류한다.

    반환값은 항상 문자열이다. 예외를 올리지 않는다 — 판단 불가는
    전부 UNKNOWN (cheap fact 는 평가를 실패시키지 않는다).

    선두 토큰의 wrapper/shell/interpreter/git 판정은 대소문자 무관
    (``casefold``) 이며, 반환 라벨도 casefold 소문자 정규형이다 —
    모듈 docstring "대소문자 정규화 규약" 참조 (보안 리뷰 fail-open
    수정: macOS 대소문자 비구분 파일시스템에서 동일 바이너리가
    resolve 되므로, 대소문자 변형만으로 unknown 판정을 우회할 수
    없어야 한다).
    """
    if not isinstance(command, str):
        return UNKNOWN
    if _has_uncertain_structure(command):
        return UNKNOWN
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return UNKNOWN
    if not tokens:
        return UNKNOWN

    head = tokens[0]
    head_key = head.casefold()
    if head_key == "git":
        return _classify_git(tokens)
    if not _COMMAND_WORD.match(head):
        # 경로 실행(./run.sh, /tmp/build.sh)·할당 접두(FOO=bar ...)·
        # 그 외 비정형 첫 토큰 — 실체를 단정하지 않는다. _COMMAND_WORD
        # 는 ASCII 전용이므로 유니코드 동형이의 문자는 여기서 걸린다.
        return UNKNOWN
    if head_key in _OPAQUE_WRAPPERS or head_key in _SHELLS:
        return UNKNOWN
    code_flags = _INTERPRETER_CODE_FLAGS.get(head_key)
    if code_flags and any(token in code_flags for token in tokens[1:]):
        return UNKNOWN
    return head_key


def _classify_git(tokens):
    """`git <subcommand> ...` 만 git.<subcommand> — 전역 옵션은 UNKNOWN.

    `git -C <path> commit` 은 대상 저장소가 명령 문자열만으로 확정되지
    않는다 (v1 샌드박스 커밋 판정의 이식 — spec §6.3). 전역 옵션 해석을
    시도하지 않고 UNKNOWN 으로 넘겨 stricter policy 가 처리하게 한다.

    `tokens[0]` (``git``/``Git``/``GIT`` 등)의 대소문자는 호출부
    (`classify`)가 이미 casefold 로 판정했으므로 여기서는 쓰지 않는다.
    `tokens[1]`(서브커맨드)의 대소문자는 정규화하지 않는다 — 실제 git
    서브커맨드 이름은 대소문자를 구분하므로(`GIT COMMIT` 은 존재하지
    않는 서브커맨드), `_GIT_SUBCOMMAND` 가 소문자만 인정해도 과소
    분류가 아니다.
    """
    if len(tokens) < 2:
        return UNKNOWN
    subcommand = tokens[1]
    if subcommand.startswith("-"):
        return UNKNOWN
    if not _GIT_SUBCOMMAND.match(subcommand):
        return UNKNOWN
    return "git." + subcommand


def _has_uncertain_structure(command):
    """인용 인지 스캔 — 구조 메타문자/백슬래시/인용 불균형이면 True.

    작은따옴표 안은 전부 데이터. 큰따옴표 안은 `$`/백틱만 활성
    (치환·확장) — 그 둘이 보이면 True. 인용 밖 백슬래시는 해석하지
    않고 True (이스케이프·줄 연속·난독화 일체). 닫히지 않은 인용도
    True. 완전 파싱이 아니라 "확실히 단순한가" 만 판정한다.
    """
    in_single = False
    in_double = False
    index = 0
    length = len(command)
    while index < length:
        char = command[index]
        if in_single:
            if char == "'":
                in_single = False
            index += 1
            continue
        if in_double:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_double = False
                index += 1
                continue
            if char in "`$":
                return True
            index += 1
            continue
        if char == "\\":
            return True
        if char == "'":
            in_single = True
            index += 1
            continue
        if char == '"':
            in_double = True
            index += 1
            continue
        if char in _STRUCTURAL_META:
            return True
        index += 1
    if in_single or in_double:
        return True
    return False
