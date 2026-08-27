"""사적 경로 규칙 SSOT — 검출(corpus 반입 검증) + 정규화(수집 단계) 공용.

존재 이유 (2026-08-10, Phase 2 잔존 인수 조건 1번 수리): 사적 경로
규칙이 `corpus.py` 안에만 살고 있었고, 수집(`capture.py`) 쪽에는 그
규칙에 걸리지 않을 형태로 경로를 축약해 주는 처리가 **아예 없었다**.
결과적으로 절대경로를 담은 Shadow Case 는 전부 반입 거부되어 조용히
사라졌다 — 홈 아래에 프로젝트를 두는 모든 사용자와 CI 러너
(`/home/runner/...`) 가 해당한다. 실측: 이 저장소 corpus 308건 중 편집
계열 훅의 **실제 편집 경로 레코드 0건**.

수리 시 규칙을 `capture.py` 에 재구현하지 않고 이 모듈로 옮긴 이유는
Phase 2 의 교훈이다 — 같은 규칙이 두 곳에 복제되면 한쪽만 고쳐지고
경계가 갈라지는 결함이 반복된다(마스킹 URL credential 규칙에서 4회).
검출(`contains_private_path`)과 정규화(`normalize`)가 **같은 정의**
(`PRIVATE_PATH`)를 소비한다.

역할 분담:
  - `capture.py` — 수집 단계에서 `normalize()` 로 축약 (사용자명 제거,
    프로젝트 내부는 상대경로화).
  - `corpus.py` — 반입 직전 `contains_private_path()` 로 최후 검증
    (spec §6.4 private path). 축약을 거치지 않은 경로는 여전히 거부된다.

이 모듈은 secret 마스킹을 하지 않는다 — 그것은 `masking.py` SSOT 소유다.
여기서 다루는 것은 "값이 비밀인가" 가 아니라 "경로 문자열이 사용자
신원을 드러내는가" 라는 별개의 구조적 정책이다.
"""
import re

__all__ = [
    "HOME_PLACEHOLDER",
    "PRIVATE_PATH",
    "contains_private_path",
    "normalize",
]

# 축약 후 표기. `<...>` 형태라 masking.py 의 placeholder 판정
# (`_PLACEHOLDER`) 과 형태가 일관되고, 스스로는 사적 경로 패턴에 걸리지
# 않으므로 `normalize()` 가 멱등이다.
HOME_PLACEHOLDER = "<HOME>"

# 사용자 홈 디렉토리 경로의 **접두 부분만** 매치한다 — POSIX
# (`/Users/<name>`, `/home/<name>`, `/root`, `~/...`, `~<user>/...`) +
# Windows(`C:\Users\<name>`) 관용 형태. 실제 사용자명이 에러 메시지·경로
# fact 에 실려 유출되는 것을 막는다.
#
# **접두만** 매치하는 것이 핵심이다: 검출(존재 여부)에는 접두만으로
# 충분하고, 정규화는 접두를 `<HOME>` 으로 갈아끼우고 **뒤 경로는 그대로
# 보존**해야 하기 때문이다 (뒤 경로가 Phase 3 대조의 실제 신호다 — 어떤
# 파일을 건드렸는가). 이 성질이 하나의 정규식으로 두 쓰임을 모두 지탱한다.
#
# `/root` 는 `/rootfs`·`/rootcause` 류 오탐을 피하려 단어 경계(`\b`)를
# 요구한다.
#
# 물결표(`~`) 홈 경로 (2026-08-09 보안 리뷰 Medium 수정 —
# `~/secrets/deploy_key` 같은 POSIX 관용 표기가 다른 패턴 어디에도 안
# 걸려 통과했다). 오탐 경계 3가지:
#   1) `~` 바로 앞에 영숫자/언더스코어가 있으면 안 된다
#      (`(?<![A-Za-z0-9_])`) — `a~b` 같은 단어 중간 물결표를 경로로
#      오인하지 않는다.
#   2) `~` 다음은 곧장 `/` 이거나(현재 사용자 홈), 문자로 시작하는
#      사용자명 다음에 `/` 가 와야 한다(`~alice/...`, 다른 사용자 홈).
#      사용자명을 문자 시작으로 제한한 덕에 "~5/10 확률" 같은 근사치
#      표기는 걸리지 않는다.
#   3) `/` 다음에 공백이 아닌 문자가 최소 1개 있어야 한다 — `~/` 만
#      있고 뒤에 아무것도 없으면(또는 공백이 바로 이어지면) 매치하지
#      않는다(유출될 구체 정보가 없다). 이 조건 덕에 "~ish 범위"처럼
#      슬래시 없는 단독 물결표도 걸리지 않는다.
# 3) 은 **lookahead** 로 둔다 — 조건으로는 뒤 경로의 존재를 요구하되
# 매치 범위에는 포함시키지 않아야 `~` 접두만 치환할 수 있다.
# (이 경계들은 회귀 테스트
# `test_private_path_lookalikes_are_not_false_positives` /
# `NormalizeLeavesNonPrivatePathsIntact` 로 고정.)
#
# ReDoS: 모든 대안이 접두 고정 리터럴로 시작하고 문자클래스는 서로
# 겹치지 않는 단일 반복이라 백트래킹 폭발 경로가 없다 (스케일링 회귀
# 테스트 `NormalizeScalesLinearly` 로 고정).
# 하이픈 인코딩 홈 경로 (2026-08-10 실측 발견 — 슬래시 기준 규칙만으로는
# 못 잡던 잔존 유출 49건). 일부 도구는 프로젝트 절대경로의 슬래시를
# 하이픈으로 바꿔 작업 디렉토리 이름 하나로 만든다:
#     /Users/alice/work/proj → /private/tmp/<tool>/-Users-alice-work-proj/…
# 이 형태에는 사용자명이 그대로 들어있지만 `/Users/` 슬래시 형태가 아니다.
#
# 세그먼트 **전체**를 치환한다: 하이픈이 구분자이자 이름의 일부라
# `-Users-alice-work-proj` 에서 사용자명이 `alice` 인지 `alice-work` 인지
# 구조적으로 판정할 수 없다. 경계가 모호할 때는 과잉 축약이 안전한
# 방향이다(이 모듈의 목적은 신원 제거이고, 스크래치 디렉토리 이름은
# 대조 신호로서의 가치도 낮다).
#
# 오탐 경계: **`/` 바로 뒤**여야 한다 (`(?<=/)`) — 실측된 인코딩 형태는
# 항상 경로 세그먼트 위치에 나타난다. 단어 중간 하이픈
# (`some-Users-thing`)은 물론, 공백 뒤 단독 토큰(`echo -Users-alice-feature`,
# `case -home-runner-build`)도 경로가 아니므로 건드리지 않는다
# (code review Medium, 2026-08-10 — 앞 경계를 "공백 또는 `/`" 로 두었더니
# 명령 옵션·kebab-case 식별자가 통째로 축약됐다. 회귀 테스트
# `test_hyphen_inside_a_word_is_not_a_path_segment` /
# `test_standalone_token_is_not_a_path_segment`).
#
# `-root-` 는 넣지 않는다: `/root` 는 사용자명이 고정이라 신원을 드러내지
# 않는 반면, `-root-` 는 일반 디렉토리 이름(`my-root-config`)에서 흔해
# 오탐 비용만 크다. Windows 형태(`C:\Users\…` 의 인코딩)는 실측 사례가
# 없어 추측으로 넣지 않는다 — 알려진 한계.
_HYPHEN_ENCODED_HOME = r"(?<=/)-(?:Users|home)-[^/\s]+"

PRIVATE_PATH = re.compile(
    r"(?:/Users/[^/\s]+|/home/[^/\s]+|/root\b|[A-Za-z]:\\Users\\[^\\\s]+"
    r"|" + _HYPHEN_ENCODED_HOME + r""
    r"|(?<![A-Za-z0-9_])~(?:[A-Za-z][A-Za-z0-9_.\-]*)?(?=/[^\s]))"
)

# 프로젝트 루트 접두를 잘라낼 때의 **양쪽** 경계.
#
# 경계를 "경로에 쓰이는 문자" 의 블랙리스트로 잡았더니 POSIX 파일명이
# 허용하는 `+`·`@`·`:`·`=` 등이 빠져 오절단이 남았다 (code review Medium,
# 3회차 실측: `<root>+backup/a.py` → `.+backup/a.py`,
# `/tmp+<root>/a.py` → `/tmp+a.py`). POSIX 파일명은 `/` 와 NUL 을 뺀 모든
# 바이트를 허용하므로 그 방향의 열거는 원리적으로 완결될 수 없다.
#
# 그래서 방향을 뒤집어 **구분자 화이트리스트**로 판정한다: 루트 접두는
# 앞뒤가 "경로를 이어붙일 수 없는 문자"(공백류·따옴표·괄호·셸 구분자)
# 이거나 문자열 경계일 때만 잘라낸다. 모르는 문자를 만나면 자르지 않고
# 남긴다.
#
# 이 보수적 실패가 안전한 이유: 루트 접두 제거는 **가독성·신호 품질**
# 최적화이고, 사용자명 제거는 그 다음 단계인 `PRIVATE_PATH` 축약이
# 책임진다. 루트 제거가 건너뛰어져도 홈 접두는 여전히 `<HOME>` 으로
# 바뀌므로 유출은 발생하지 않는다 — 반대 방향(과잉 절단)은 관측 데이터를
# 조용히 왜곡하므로 더 나쁘다.
_PATH_SEPARATORS = r"\s'\"()=:,;|&<>`"
_ROOT_LEFT = r"(?<![^" + _PATH_SEPARATORS + r"])"
_ROOT_RIGHT = r"(?![^" + _PATH_SEPARATORS + r"])"


def contains_private_path(text):
    """`text` 안에 사용자 홈 경로 형태가 존재하는지."""
    if not text:
        return False
    return bool(PRIVATE_PATH.search(text))


def _strip_project_root(text, project_root):
    """프로젝트 루트 접두를 잘라 루트 기준 상대경로로 만든다.

    두 형태를 따로 처리하며, **단독형을 먼저** 본다:
      1) `<root>` 또는 `<root>/` 단독 (뒤에 경로가 이어지지 않음) → `.`
         — 작업 디렉토리 fact 처럼 루트 자체가 값인 경우. 빈 문자열로
         만들면 "값이 없음" 과 구분되지 않으므로 `.` 을 쓴다.
      2) `<root>/<rest>` → `<rest>` — 뒤에 경로가 이어지는 일반형.

    순서가 중요하다 (code review Medium, 4회차): 일반형을 먼저 돌리면
    `<root>/` 의 슬래시까지 무조건 먹어치워 값이 빈 문자열이 되고,
    그 뒤 단독형 규칙은 볼 대상 자체가 사라진 뒤라 실행되지 못한다
    (`cd <root>/ && npm test` → `cd  && npm test` 로 디렉토리 신호가
    조용히 소실됐다). 단독형이 먼저 트레일링 슬래시까지 흡수해 `.` 으로
    바꾸면 이 구멍이 닫힌다 — 일반형은 슬래시 뒤에 실제 경로가 있을 때만
    매치하므로 서로 겹치지 않는다.

    `re.escape` 로 루트를 리터럴 취급하므로 사용자 경로에 정규식
    메타문자가 있어도 안전하고, 백트래킹 폭발 경로가 없다.
    """
    # `str()` 로 한 번 통과시킨다 (security review Info-1): 호출부가 경로
    # 객체를 넘겨도 속성 부재 예외로 레코드가 통째로 유실되지 않게.
    root = str(project_root).rstrip("/\\")
    if not root:
        return text
    escaped = _ROOT_LEFT + re.escape(root)
    text = re.sub(escaped + r"[/\\]?" + _ROOT_RIGHT, ".", text)
    return re.sub(escaped + r"[/\\]", "", text)


def normalize(text, project_root=None):
    """경로 축약 — 프로젝트 내부는 상대경로, 나머지 홈 경로는 `<HOME>`.

    `project_root` 가 없으면(구버전 호출부·루트 미상) 홈 축약만 적용한다
    — 아래 "알려진 사각지대" 를 제외하면 어느 경로로 들어와도 사용자명이
    남지 않는다.

    실사용 입력에서는 멱등이다: 결과에 남는 `<HOME>` 과 상대경로는 어느
    패턴에도 걸리지 않는다. **예외** (security review Info-1, fuzz 로만
    재현 — 실측 코퍼스 9,690 필드에서 0건): `/Users//root` 처럼 홈 접두
    바로 뒤에 또 다른 사적 경로 토큰이 붙으면 1차 결과(`/Users/<HOME>`)의
    `<HOME>` 이 `[^/\s]+` 에 다시 걸려 2차 적용이 값을 더 줄인다. 실패
    방향은 (덜 지우는 쪽이 아니라) 더 지우는 쪽이고, 그런 값은 검증에서
    거부되므로 유출로 이어지지 않는다.

    알려진 사각지대 (security review Low-1 — 전부 **오탐과의 trade** 로
    의도한 경계이며, 넓히면 일상적인 텍스트를 경로로 오인한다):
      - `~alice` 처럼 뒤에 `/` 가 없는 물결표 홈 표기. 이름 부분만으로는
        `~ish`·`~about` 같은 근사치/단어 표기와 구분할 수 없다.
      - `/` 앞에 오지 않는 하이픈 인코딩(`-Users-alice-proj` 단독). 좁히지
        않으면 명령 옵션·kebab-case 식별자를 통째로 삼킨다.
      - 드라이브 문자 없는 Windows 표기, `/export/home2/<name>` 류 비표준
        홈 위치 — 변형이 열려 있어 열거로 닫히지 않는다.
    """
    if not text:
        return text
    if project_root:
        text = _strip_project_root(text, project_root)
    return PRIVATE_PATH.sub(HOME_PLACEHOLDER, text)
