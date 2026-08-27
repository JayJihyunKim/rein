"""active_task fact 소스 — `task.active` / `changeset.task_relevant`
(v2 Phase 6 worker D — spec §3.6 §10, §6.3, plan Task 4.2 대응).

`rein.capabilities.task.capability` 가 요구하는 계약(모듈 상단 docstring
"Fact 계약" 절 참조):

- `task.active` — 활성 task 식별자(비어있지 않은 `str`) 또는 `None`.
- `changeset.task_relevant` — 현재 ChangeSet 이 task governance 를
  필요로 하는 변경인지의 `bool`.

이 모듈은 두 fact 모두 v1 `hooks/pre-edit-dod-gate.sh` 의 실제 판정과
**동등한 의미**로 재현한다(DoD 지시 — v1 을 읽고 대응 로직을 확인한 뒤
구현). **Phase 7 웨이브 3 ③-d (2026-08-24) 갱신**: `rein.engine.
authority` 는 legacy marker dual-read 계층 전체가 제거되며 이 DOD_FOUND
로직의 legacy 판정용 대응 함수(`_legacy_active_task_status`)를 더 이상
갖지 않는다 — 이 모듈은 애초에 그 함수를 import 하지 않았으므로(engine
계층과 platform 계층은 서로 다른 소비자를 위한 독립 구현, spec §3.1
계층 분리: platform 은 engine 을 몰라도 되고, 이 fact 소스는 engine 의
전환 로직과 무관하게 그 자체로 정확해야 한다) 이 제거는 이 모듈의
판정 로직에 영향을 주지 않는다(무변경) — 아래 재현 로직은 여전히 이
모듈이 유지하는 유일한 DOD_FOUND 구현이다.

## task.active — v1 DOD_FOUND 재현 (hooks/pre-edit-dod-gate.sh 라인 448-479)

pending = 신 포맷 `trail/dod/dod-YYYY-MM-DD-<slug>.md` 파일이 존재하고,
같은 slug 의 `trail/inbox/YYYY-MM-DD-<slug>.md` 완료 기록이 없다. 레거시
포맷(신 포맷 정규식에 안 맞는 파일명)은 v1 과 동일하게 무시한다(별도
스윕 대상). 여러 dod 파일이 있으면 정렬 순서로 첫 pending 항목을
반환한다(v1 의 `for dod_file in "$DOD_DIR"/dod-*.md; do ... break; done`
과 동일한 first-match 의미론).

식별자 형식은 파일명에서 `.md` 확장자를 뗀 값이다(예:
`dod-2026-08-11-foo`) — v1 은 판정에 boolean(`DOD_FOUND`)만 쓰고
식별자를 노출하지 않지만, capability 계약은 "비어있지 않은 문자열"을
요구하므로(단순 boolean 이 아니라 식별 가능한 값) 파일명 slug 를
그대로 identifier 로 쓴다.

## changeset.task_relevant — v1 IS_SOURCE 재현 (같은 파일 라인 233-339)

cascade 순서(tightening-only, 뒷 단계가 앞 단계의 결정을 뒤집지 않음):

1. 경로 기반 면제(runtime state/trail/`.gitkeep`) — 단 `.gitignore` 는
   이 면제보다 먼저 걸러져 그대로 3번(소스 디렉토리 화이트리스트)으로
   진입한다(v1 case 문 최상단 fall-through 그대로).
2. generated/vendored 제외 — 디렉토리 화이트리스트보다 우선(예:
   `src/generated/api.ts` 는 `src/` 안에 있어도 비관련).
3. 소스 디렉토리 화이트리스트(`*/src/*` 등 + rein-internal 경로) —
   확장자와 무관하게 관련.
4. doc/data/lock 확장자 제외 — 3에서 이미 잡히지 않은 경로에서만 평가.
5. 소스 확장자 화이트리스트(additive) — 위 어느 단계에도 안 걸리면.
   목록 밖 확장자는 v1 과 동일하게 "비관련"으로 보수적 기본값(과차단
   방지가 v1 의 명시적 선택, GMF-3 주석 참조).

ChangeSet(복수 경로) 결합은 v1 에 대응이 없다 — v1 hook 은 Edit/Write
호출마다 파일 1개만 본다. v2 의 ChangeSet 은 여러 경로를 가질 수 있으므로
"하나라도 관련이면 전체가 관련"(OR 결합)으로 확장한다 — 게이트 계열은
FN(놓침)이 FP(과차단)보다 나쁘다는 이 저장소의 반복 결정과 같은 방향
(§2.2 위협모델)이다.

## 비용 (cost) 메모

`task_active_identifier` 는 `trail/dod/`·`trail/inbox/` 두 디렉토리의
`os.listdir` 만 수행한다 — 각 디렉토리는 보통 수십 개 이하 파일이라
실측 비용은 작지만, 파일시스템 I/O 라는 점에서 spec §3.2 의 "expensive
(... active task ...)" 분류에 해당한다(캐시 없이 매번 재스캔). 이 모듈
자체는 캐싱하지 않는다 — request-scoped 캐싱은 `EvaluationContext`
(engine 계층, 다음 단계 CLI 가 fact resolver 로 배선할 때) 의 책임이다.

`is_task_relevant_path`/`changeset_task_relevant` 는 순수 문자열 매칭
(I/O 없음)이라 그 자체로는 cheap 하다 — 다만 호출자가 넘기는 `paths`
는 대개 이미 계산된 ChangeSet(그 계산 자체는 git status 등 expensive
fact)에서 온다.
"""
import fnmatch
import os
import posixpath
import re

# v1 hooks/pre-edit-dod-gate.sh 와 동일한 파일명 규약
_DOD_FILENAME_PATTERN = re.compile(r"^dod-\d{4}-\d{2}-\d{2}-(.+)\.md$")
_INBOX_FILENAME_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}-(.+)\.md$")

# --- changeset.task_relevant cascade (v1 라인 233-339 재현) -------------

# (1) 경로 기반 면제 — 항상 비관련. `.gitignore` 는 이 표 밖에서 먼저
# 처리된다(아래 is_task_relevant_path 참조).
_ALWAYS_IRRELEVANT_PATTERNS = (
    "*/.claude/cache/*",
    "*/.claude/.rein-state/*",
    "*/trail/*",
    "*.gitkeep",
)

# (2) generated/vendored 제외 — 디렉토리 화이트리스트보다 우선.
_GENERATED_DIR_PATTERNS = (
    "*/node_modules/*",
    "*/vendor/*",
    "*/dist/*",
    "*/build/*",
    "*/.next/*",
    "*/generated/*",
    "*/__generated__/*",
    "*/__pycache__/*",
)
_GENERATED_FILE_PATTERNS = (
    "*.min.js",
    "*.generated.*",
    "*_pb2.py",
    "*.pb.go",
)

# (3) 소스 디렉토리 화이트리스트 — 확장자와 무관하게 관련.
_SOURCE_DIR_PATTERNS = (
    "*/src/*",
    "*/app/*",
    "*/services/*",
    "*/apps/*",
    "*/lib/*",
    "*/components/*",
    "*/hooks/*",
    "*/store/*",
    "*/types/*",
    "*/models/*",
    "*/schemas/*",
    "*/repositories/*",
    "*/routers/*",
    "*/alembic/*",
    "*/scripts/*",
    "scripts/*",
    "*/.claude/rules/*",
    "*/.claude/skills/*",
    "*/.claude/agents/*",
    "*/.claude/workflows/*",
    "*/.claude/CLAUDE.md",
    "*/.claude/orchestrator.md",
    "*/.claude/settings.json",
    "*/AGENTS.md",
    "AGENTS.md",
)

# `.gitignore` 전용 — v1 은 이 패턴을 면제 표 최상단(fall-through)과
# 소스 디렉토리 화이트리스트 양쪽에 중복 기재한다. 최종 효과는
# "어디에 있든 항상 관련"이므로 이 모듈은 그 효과만 별도 상수로 고정한다.
_GITIGNORE_PATTERNS = ("*/.gitignore", ".gitignore")

# (4) doc/data/lock 확장자 제외 — (3) 에서 안 잡힌 경로에서만 평가.
_NONSOURCE_EXT_PATTERNS = (
    "*.md",
    "*.txt",
    "*.rst",
    "*.adoc",
    "*.json",
    "*.yaml",
    "*.yml",
    "*.toml",
    "*.ini",
    "*.csv",
    "*.xml",
    "*.env",
    "*.lock",
    "*.sum",
)

# (5) 소스 확장자 화이트리스트 — additive.
_SOURCE_EXT_PATTERNS = (
    "*.go",
    "*.rs",
    "*.py",
    "*.ts",
    "*.tsx",
    "*.js",
    "*.jsx",
    "*.mjs",
    "*.cjs",
    "*.java",
    "*.kt",
    "*.kts",
    "*.scala",
    "*.c",
    "*.h",
    "*.cpp",
    "*.cc",
    "*.cxx",
    "*.hpp",
    "*.hh",
    "*.rb",
    "*.php",
    "*.sh",
    "*.bash",
    "*.swift",
    "*.m",
    "*.mm",
    "*.cs",
    "*.ex",
    "*.exs",
    "*.erl",
    "*.hs",
    "*.clj",
    "*.cljs",
    "*.lua",
    "*.dart",
    "*.pl",
    "*.pm",
    "*.r",
    "*.R",
    "*.jl",
    "*.zig",
    "*.ml",
    "*.mli",
    "*.fs",
    "*.fsx",
    "*.groovy",
    "Dockerfile",
    "*/Dockerfile",
    "Makefile",
    "*/Makefile",
    "*.mk",
)


def task_active_identifier(project_root):
    """활성 task 식별자 — v1 DOD_FOUND 와 동등한 의미(모듈 docstring 참조).

    `project_root` 아래 `trail/dod/` 가 없거나 pending 파일이 없으면
    `None`. pending 파일이 있으면 그중 정렬 순서상 첫 항목의 slug
    (`dod-YYYY-MM-DD-<slug>`, `.md` 제외)를 반환한다.
    """
    dod_dir = os.path.join(project_root, "trail", "dod")
    if not os.path.isdir(dod_dir):
        return None

    inbox_dir = os.path.join(project_root, "trail", "inbox")
    inbox_slugs = set()
    if os.path.isdir(inbox_dir):
        for name in os.listdir(inbox_dir):
            match = _INBOX_FILENAME_PATTERN.match(name)
            if match:
                inbox_slugs.add(match.group(1))

    for name in sorted(os.listdir(dod_dir)):
        match = _DOD_FILENAME_PATTERN.match(name)
        if not match:
            continue
        slug = match.group(1)
        if slug not in inbox_slugs:
            return name[: -len(".md")]
    return None


def task_exists(project_root):
    """`task.exists` fact — v1 커밋 게이트 술어의 **의도적 미러(shim)**.

    High-1 리뷰 지적(2026-08-19, 리뷰어 실재현)으로 구현 방향이
    바뀌었다: 이 fact 는 v2 활성작업 스캐너(`task_active_identifier()`,
    신 포맷 정규식 강제 + 완료 inbox 대조)와 **의도적으로 다른** v1
    의미론을 보존한다. 위임·등록 경로에서 v1 커밋 게이트
    (`hooks/lib/code-review-gate.sh` `rein_check_code_review_stamp()`
    의 `dod_exists` precondition, 라인 302-315)의 판정을 그대로
    재현하는 것이 이 함수의 목적이며, v2 관념(`task_active_identifier`)
    과의 통일은 v1 게이트 제거 이후 별도 결정 사안이다 — 이 함수는
    지금 그 통일을 하지 않는다.

    v1 술어 원문(`code-review-gate.sh` 라인 302-315):

        local dod_dir="$PROJECT_DIR/trail/dod"
        local dod_exists=false
        if [ -d "$dod_dir" ]; then
          local f
          for f in "$dod_dir"/dod-*.md; do
            [ -f "$f" ] || continue
            dod_exists=true
            break
          done
        fi
        [ "$dod_exists" = false ] && return 0

    이 술어는 **파일명 글롭(`dod-*.md`)만** 본다 — 완료 여부(inbox
    대조)도, 날짜 형식(`YYYY-MM-DD`)도 요구하지 않는다. 디렉토리 자체가
    없으면 미존재(v1 의 `[ -d "$dod_dir" ]` 가드와 동일).

    `task_active_identifier()`(신 포맷 정규식 + inbox 완료 대조)를 그대로
    재사용해 파생하면 이 v1 술어와 갈라진다 — 리뷰어가 실재현한 두 창:
    (a) **완료-but-파일-잔존**: 완료 처리(inbox 기록)됐지만 정의서
    파일이 아직 `trail/dod/` 에 남아있는 흔한 운영 창에서, v2 스캐너는
    None(요구 없음)을 내지만 v1 은 여전히 true(리뷰 계속 요구)였다.
    (b) **레거시 파일명**: 날짜 세그먼트가 없는 파일(`dod-notes.md`
    류)에서 v2 스캐너는 정규식 불일치로 무시(None)하지만 v1 glob 은
    그대로 매칭(true)한다. 두 경우 모두 `task_active_identifier()` 를
    재사용하면 v1 이 요구하던 리뷰가 v2 위임 경로에서 오늘부터 조용히
    사라지는 방향(fail-open)이라 "동작 불변 계약 위반"이다. 그래서 이
    함수는 `task_active_identifier()` 를 호출하지 않고 위 v1 glob
    의미론을 독립적으로 재현한다(아래 구현) — `task.active` fact 와는
    완전히 별개의 스캔이다(트레이드오프: 두 fact 가 같은 cycle 에서
    함께 조회되면 `trail/dod/` 를 각각 `os.listdir`/`os.scandir` 로 두
    번 훑지만, 이 비용은 모듈 docstring "비용 메모" 절이 이미 무시할
    만하다고 판단한 수준이다).

    ## 값 계약

    `project_root` 아래 `trail/dod/` 가 없으면 `None`. 있으면 `dod-*.md`
    글롭에 매치되는 **파일**(디렉토리 아님 — v1 의 `[ -f "$f" ]` 가드와
    동일)이 하나라도 있으면 리터럴 문자열 `"true"`, 없으면 `None`(다른
    문자열이 아니라 값 부재 — `testing.configured` fact 의 선례와 동일
    패턴: "활성 아님"을 "false" 문자열로 명시하지 않는다).

    ## 응답/배선 층에서의 None 취급 (Phase 7 배선부 문서 정합 수리)

    이 함수가 `None` 을 반환해도, 호출자(`rein/cli/__init__.py` 의
    `_resolve_task_exists`/`_record`)가 그 값을 응답에서 반드시 빼는
    것은 아니다 — 실측 배선은 `resolved_out[key] = value` 를 값이
    `None` 이어도 그대로 기록하며, 이 fact 가 실제로 조회된 cycle 이면
    응답(`decision["facts"]`/`explanation["facts"]`)에 `"task.exists":
    null` 로 나타날 수 있다. 이는 버그가 아니다 — policy `when:` 비교
    (`rein/engine/evaluator.py` `evaluate()` 의 `context.fact(key) !=
    value`)는 `context.fact()` 가 `None` 을 반환하는 경우와 그 키가
    애초에 한 번도 조회되지 않아 부재인 경우를 **동일하게** 불일치로
    처리한다(`None != "true"` 는 항상 참). 즉 이 fact 가 실제로 보장
    하는 것은 "값이 다르면 매칭 실패"이지 "키가 응답에서 사라짐"이
    아니다 — 후자는 조회 여부(lazy resolver 가 실제로 불렸는지)에
    달린 별개 질문이며 이 함수의 반환 계약과 무관하다.

    ## 실패 방향 (필수 — DoD 지시, High-1 리뷰 후 경계 재정의)

    이 함수는 `os.path.isdir()`/`os.path.isfile()` 을 쓰지 않는다 — 이
    두 헬퍼는 내부적으로 `os.stat()` 을 호출하되 `OSError`(권한 오류
    포함)를 **삼켜 `False` 로 흡수**한다(표준 라이브러리 `genericpath`
    구현, 실측 확인: `os.stat` 을 `PermissionError` 로 patch 해도
    `os.path.isdir`/`isfile` 은 예외 없이 `False` 를 반환했다). 이
    흡수형 헬퍼를 판정에 쓰면 권한 오류가 "디렉토리 없음"/"파일 아님"
    으로 위장되어 이 함수가 `None`("정의서 없음")을 반환하고, policy
    `when:` 이 미매칭되어 리뷰 게이트가 조용히 꺼지는 **fail-open** 이
    된다(리뷰어가 `os.stat` PermissionError 주입으로 실재현) — 이
    저장소의 게이트 계열 반복 결정("판단 불능은 거부 방향이어야 한다",
    `bin/rein` 모듈 docstring "fail-closed 매핑" 절과 동일 사상)과
    정면으로 어긋난다.

    대신 이 함수는 `os.scandir(dod_dir)` 로 디렉토리를 열고, 그 호출이
    던지는 예외 중 **`FileNotFoundError`/`NotADirectoryError` 만**
    "활성 작업 없음"(`None`) 으로 처리한다 — 이 둘은 v1 의
    `[ -d "$dod_dir" ]` 가드가 뜻하는 "디렉토리가 아예 없거나 디렉토리가
    아님"과 의미가 같다. 그 외 `OSError`(`PermissionError` 포함 —
    디렉토리는 있지만 열람 권한이 없는 경우)는 잡지 않고 그대로
    전파한다. 항목별 파일 여부 판정(`entry.is_file()`)도 동일 원칙 —
    이 메서드는 `follow_symlinks=True` 기본값에서 (플랫폼의 `d_type`
    캐시가 없거나 심볼릭 링크인 경우) 내부적으로 `os.stat()` 을 호출할
    수 있고 그 호출이 던지는 예외를 삼키지 않는다(실측: `os.DirEntry.
    is_file` 자체를 `PermissionError` 로 patch 하면 그대로 전파됨).
    이 함수는 그 주위에 흡수형 `try/except` 를 두지 않는다: 예외
    비흡수 자체가 계약이다.
    """
    dod_dir = os.path.join(project_root, "trail", "dod")
    try:
        scanner = os.scandir(dod_dir)
    except (FileNotFoundError, NotADirectoryError):
        return None
    with scanner:
        for entry in scanner:
            if not fnmatch.fnmatchcase(entry.name, "dod-*.md"):
                continue
            if entry.is_file():
                return "true"
    return None


def _normalize(path):
    """backslash 구분자·`./` 접두어·중복 구분자를 posix 형태로 정규화.

    `rein.engine.tags._normalize_path` 와 동일한 원칙(재구현이지만 의도
    적으로 이 모듈은 tags.py 를 import 하지 않는다 — v1 IS_SOURCE 는
    Tag 3분류와 판정 기준 자체가 다르므로 별도 어휘를 쓴다, 모듈
    docstring 참조).
    """
    if not path:
        return ""
    normalized = posixpath.normpath(path.replace("\\", "/"))
    if normalized in (".", ".."):
        return ""
    return normalized


def _matches_any(path, patterns):
    """`path` 가 `patterns` 중 하나와 매칭되는지 — 절대/상대 경로 경계 보정 포함.

    v1 의 case 패턴(`*/src/*` 등)은 **절대 경로**(Claude hook 의
    `tool_input.file_path`)를 전제로 작성됐다 — 절대 경로는 항상
    `/` 로 시작하므로 `*/src/*` 는 최상위 `src/` 도 "그 앞에 뭔가(루트
    슬래시) + /src/" 형태로 자연히 매치된다. 그러나 v2 ChangeSet 의
    `paths` 는 **저장소 상대 경로**(kernel `ChangeSet.paths` 계약,
    앞에 `/` 없음)다 — 상대 경로 그대로 매칭하면 최상위 `src/main.py`
    같은 흔한 경로가 `*/src/*` 에 안 걸린다(패턴이 요구하는 리터럴
    `/` 가 문자열 맨 앞에 없으므로). 이 함수는 `path` 자체와 가상의
    루트 슬래시를 붙인 `"/" + path` 양쪽에 대해 매칭을 시도해 이
    간극을 보정한다 — `*/` 로 시작하는 "어디서든 매치" 패턴은 가상
    루트 슬래시 버전에서 최상위 경로도 잡아내고, 슬래시 없이 시작하는
    루트 앵커 패턴(`scripts/*`, `AGENTS.md`, `.gitignore` 등)은 원본
    경로에서 그대로 잡힌다. 확장자 전용 패턴(`*.py` 등)은 어느 쪽으로
    매칭해도 결과가 같다(둘 다 접미사 매치이므로 오탐 없음).
    """
    if not path:
        return False
    rooted = "/" + path
    for pattern in patterns:
        if fnmatch.fnmatchcase(path, pattern) or fnmatch.fnmatchcase(
            rooted, pattern
        ):
            return True
    return False


def is_task_relevant_path(path):
    """단일 경로가 task governance 관련(v1 IS_SOURCE)인지 판정한다.

    cascade 순서는 모듈 docstring "changeset.task_relevant" 절 그대로.
    빈/정규화 불가 경로는 보수적으로 비관련(False) — 판정할 대상이
    없다.
    """
    normalized = _normalize(path)
    if not normalized:
        return False
    if _matches_any(normalized, _GITIGNORE_PATTERNS):
        return True
    if _matches_any(normalized, _ALWAYS_IRRELEVANT_PATTERNS):
        return False
    if _matches_any(
        normalized, _GENERATED_DIR_PATTERNS
    ) or _matches_any(normalized, _GENERATED_FILE_PATTERNS):
        return False
    if _matches_any(normalized, _SOURCE_DIR_PATTERNS):
        return True
    if _matches_any(normalized, _NONSOURCE_EXT_PATTERNS):
        return False
    if _matches_any(normalized, _SOURCE_EXT_PATTERNS):
        return True
    return False


def changeset_task_relevant(paths):
    """ChangeSet 전체의 관련성 — 하나라도 관련 경로면 전체가 관련(OR 결합).

    v1 에 없는 다중 경로 결합에 대한 이 모듈의 설계 결정(모듈 docstring
    "changeset.task_relevant" 절 근거 참조). 빈 `paths` 는 비관련.
    """
    return any(is_task_relevant_path(path) for path in paths)
