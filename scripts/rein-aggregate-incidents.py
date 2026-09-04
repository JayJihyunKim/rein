#!/usr/bin/env python3
"""Aggregate blocks.jsonl into incident files. Called from stop-session-gate.sh."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import sys
import tempfile
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

THRESHOLD = int(os.environ.get("REIN_INCIDENT_THRESHOLD", "2"))
LOCK_TTL_SEC = 300

# advisory-summary reads from this path (overridable for tests)
_BLOCKS_JSONL_DEFAULT = None  # resolved lazily from PROJECT_DIR


# --- v2 마스킹/경로 SSOT 위임 (규칙 중복 금지) --------------------------
#
# spec §5.5 [B-5] / plan Task 7.1: incident 예시와 손상 행 격리 파일의
# target 에 `rein.shadow.masking.redact()` 와 `rein.shadow.paths.normalize()`
# 를 적용한다. 이 스크립트는 두 규칙을 자체 구현하지 않는다 — 엔진을 못
# 불러오면 로컬 폴백 없이 고정 placeholder 로 닫는다(fail-closed).
#
# 출처(source) 필드가 없는 legacy 레코드의 `<legacy-target-redacted>` 통째
# 치환은 그대로 둔다 — 마스킹 규칙이 아니라 "출처 불명 레코드는 신뢰하지
# 않는다" 는 별개의 신뢰 규칙이다(아래 aggregate() 참조).
#
# 엔진은 dotted import 가 아니라 파일 직접 로드로 가져온다(`sys.modules` 에
# 등록하지 않음). 대상 모듈을 모듈 캐시로 바꿔치기하는 경로는 막히지만,
# 표준 라이브러리 오염이나 기대 파일 자체의 교체는 막지 않는다 — 둘 다
# 인터프리터나 설치 트리를 이미 통제하는 주체를 전제하므로 이 계층이
# 지킬 수 있는 경계 밖이다.
#
# 판단 근거·리뷰 궤적: `docs/reports/v2-phase-gates.md` Phase 7 웨이브 4.

_BUNDLE_MANIFEST_RELPARTS = (".claude-plugin", "plugin.json")


def _package_parent_candidate():
    """이 파일의 배치에 대응하는 rein 패키지 부모 경로를 계산한다.

    판정 기준은 **번들 매니페스트(`.claude-plugin/plugin.json`) 의 존재**다.
    디렉토리 이름으로 판정하지 않는다 — 실제 설치 경로
    (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/scripts/…`)는
    이름 판정이 기대하던 구조가 아니라, 이름으로 보면 설치 환경 전체에서
    엔진 로드가 실패한다. 매니페스트는 배포 tarball 과 저장소
    `plugins/rein-core/` 양쪽에 있어 버전·마켓플레이스 이름과 무관하다.

    이 방식은 "형제 `rein/shadow/masking.py` 가 있으면 신뢰" 하는 탐색과도
    다르다 — 매니페스트 없는 디코이 패키지는 후보가 되지 않는다.

      - 번들 안의 사본: `<bundle>/scripts/…` → 부모가 곧 번들.
      - 저장소 루트 사본: `<repo>/scripts/…` → 번들은 `<repo>/plugins/rein-core`.
      - 둘 다 아니면 `None` (호출부가 fail-closed 처리).
    """
    here = os.path.realpath(__file__)
    parent_of_scripts_dir = os.path.dirname(os.path.dirname(here))
    if os.path.isfile(
            os.path.join(parent_of_scripts_dir, *_BUNDLE_MANIFEST_RELPARTS)):
        return parent_of_scripts_dir
    bundled = os.path.join(parent_of_scripts_dir, "plugins", "rein-core")
    if os.path.isfile(os.path.join(bundled, *_BUNDLE_MANIFEST_RELPARTS)):
        return bundled
    return None


_MASK_UNAVAILABLE = "<mask-unavailable>"


def _load_verified_symbol(module_relparts, symbol_name, private_name):
    """자기 위치 기준 파일에서 `symbol_name` 을 직접 로드한다 (`sys.modules`
    조회·등록 없음 — 상단 주석 참조). 기대 경로에 파일이 없거나 로드가
    실패하면 None (fail-closed → 호출자가 placeholder 로 대체).
    """
    package_parent = _package_parent_candidate()
    if package_parent is None:
        return None  # 번들 매니페스트 부재 → fail-closed
    expected_path = os.path.realpath(
        os.path.join(package_parent, *module_relparts)
    )
    if not os.path.isfile(expected_path):
        return None
    try:
        spec = importlib.util.spec_from_file_location(private_name, expected_path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:
        return None
    return getattr(module, symbol_name, None)


# Import once at module load — never retried per call. This script's hook
# callers include the session-start trail loader, the stop-session gate, and
# the incident-review gate library (not an edit hook — an earlier comment
# here said "edit-hook-triggered", which was wrong); the incidents-to-rule
# skill invokes it directly as well, so treat this list as illustrative,
# not exhaustive. Every caller spawns a fresh interpreter, so "once" means
# once per process, not once across a session. On failure _v2_redact / _v2_path_normalize stay None
# and _redact_example() / _normalize_example_path() fail closed.
try:
    _v2_redact = _load_verified_symbol(
        ("rein", "shadow", "masking.py"), "redact", "_rein_verified__agg_masking"
    )
except Exception:
    _v2_redact = None

try:
    _v2_path_normalize = _load_verified_symbol(
        ("rein", "shadow", "paths.py"), "normalize", "_rein_verified__agg_paths"
    )
except Exception:
    _v2_path_normalize = None


def _redact_example(text):
    """incident 예시 target 에 방어적으로 적용하는 v2 마스킹 SSOT 위임.

    Fail-closed: import 실패(혹은 호출 실패) 시 규칙을 로컬에 복제하지
    않고 고정 placeholder 로 대체한다 (rein-log-block.py mask() 와 동일
    계약 — 모듈 상단 주석 참조).
    """
    if _v2_redact is None:
        return _MASK_UNAVAILABLE
    try:
        return _v2_redact(text)
    except Exception:
        return _MASK_UNAVAILABLE


_PATH_NORMALIZE_UNAVAILABLE = "<path-normalize-unavailable>"


def _normalize_example_path(text):
    """`_redact_example()` 다음에 적용하는 경로 정규화.

    `rein-log-block.py` 의 `mask_tracked_path()` 와 같은 순서·같은
    fail-closed 계약: 이미 마스킹 placeholder 면 그대로 통과, 정규화가
    불가하면 미정규화 텍스트를 폴백으로 쓰지 않고 placeholder 로 닫는다.
    """
    if text == _MASK_UNAVAILABLE:
        return text
    if _v2_path_normalize is None:
        return _PATH_NORMALIZE_UNAVAILABLE
    try:
        return _v2_path_normalize(text)
    except Exception:
        return _PATH_NORMALIZE_UNAVAILABLE


# hook 이름 문법 — 사건 파일 이름의 일부가 되므로 닫힌 집합만 허용한다.
# 경로 구분자·상위 참조·NUL 등이 이름에 섞이면 `auto-<hook>-<hash>.md` 조립이
# incidents 디렉토리 밖을 가리킬 수 있다 (실측: `hook="x/../../escaped"` 로
# `trail/escaped-….md` 가 incidents 밖에 생성됨). 실제 훅 이름은 전부
# 소문자·숫자·하이픈·언더스코어라 이 문법으로 충분하다.
_SAFE_HOOK_NAME = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def _incident_path_is_contained(incidents_dir: Path, candidate: Path) -> bool:
    """조립된 사건 경로가 incidents 디렉토리 안인지 최종 확인 (2차 방어).

    `_SAFE_HOOK_NAME` 이 1차이지만, 경로 조립은 별도 지점이라 결과물 자체를
    한 번 더 검사한다 — 문법 검사와 조립 사이가 벌어져도 밖으로 새지 않는다.
    """
    try:
        base = os.path.realpath(str(incidents_dir))
        target = os.path.realpath(str(candidate))
    except OSError:
        return False
    return target == base or target.startswith(base + os.sep)


def _safe_parse_record(raw):
    """blocks.jsonl 한 줄을 안전하게 파싱한다 — 신뢰 가능한 dict 이면 반환,
    아니면 None (호출부가 격리/skip 처리).

    "해석 불가" 를 한 곳에서 총괄한다: (a) UTF-8 디코딩 실패, (b) JSON 파싱
    실패 — `json.loads` 는 `JSONDecodeError` 외에 깊은 중첩에서 `RecursionError`
    도 낼 수 있으므로 넓게 잡는다, (c) 최상위가 객체가 아님. 세 소비자(집계
    루프·advisory summary·[log-block 의 live_count 는 자체 사본])가 같은
    규칙을 쓰도록 이 함수로 모은다.
    """
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        rec = json.loads(raw)
    except Exception:
        return None
    return rec if isinstance(rec, dict) else None


def _looks_absolute(text: str) -> bool:
    """표시 경로가 아직 절대경로/드라이브 형태인지 — 축약 실패로 사용자명이
    남았는지 판정한다. POSIX `os.path.isabs` 는 백슬래시 드라이브를 놓치므로
    직접 본다. 이 함수의 대상은 **파일시스템 경로**다 (유일 호출자가 넘기는
    값이 `Path` 이며, URL 은 여기 오지 않는다)."""
    if not text:
        return False
    if text[0] in "/\\":
        return True
    if len(text) >= 2 and text[1] == ":":   # C:\ 또는 C:/
        return True
    return False


def _last_component(text: str) -> str:
    """세퍼레이터(`/`·`\\`) 무관 마지막 경로 구성요소. POSIX `os.path.basename`
    은 백슬래시를 세퍼레이터로 보지 않아 Windows 경로에서 전체를 돌려주므로
    직접 분리한다 (파일시스템 경로 전용 — URL 파서가 아니다)."""
    return re.split(r"[/\\]", text)[-1]


def _utf8_safe_str(v) -> bool:
    """`v` 가 UTF-8 로 직렬화 가능한 문자열인지. 유효 JSON 도 짝 없는
    surrogate(`"\ud800"`)를 담을 수 있어 isinstance(str) 만으론 부족하다 —
    그런 값은 sha 해시·incident 쓰기의 `.encode("utf-8")` 에서
    UnicodeEncodeError 를 내 뒤의 정상 행까지 소실시킨다."""
    if not isinstance(v, str):
        return False
    try:
        v.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _read_snapshot_dict(snapshot_path):
    """스냅샷 파일을 안전하게 읽어 신뢰 가능한 dict 이면 반환, 아니면 None.

    읽기 실패(OSError)·디코딩·JSON 파싱(깊은 중첩의 RecursionError 포함)·
    비-dict 를 모두 흡수한다 — `_safe_parse_record` 와 같은 규칙이라 손상
    스냅샷 하나가 traceback(절대경로 포함)으로 새지 않는다.
    """
    try:
        with open(snapshot_path, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    return _safe_parse_record(raw)


def _display_path(path) -> str:
    """stderr 등에 보여줄 경로 — 사적 홈 접두를 축약한다 (경로 SSOT 위임).

    정규화를 쓸 수 없으면 파일명만 남긴다 (원문 경로로 폴백하지 않는다).
    """
    text = str(path)
    if _v2_path_normalize is None:
        return _last_component(text)
    try:
        shown = _v2_path_normalize(text)
    except Exception:
        return _last_component(text)
    # normalize 가 인식 못한 절대경로/드라이브 형태(`/mnt/users/alice/…`,
    # `C:\\Profiles\\alice\\…`)는 사용자명을 담을 수 있다 — 그런 경우
    # 세퍼레이터 무관 마지막 구성요소만 보인다.
    if _looks_absolute(shown):
        return _last_component(text)
    return shown


def utcnow_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def compute_hash(hook, reason):
    return hashlib.sha1(f"{hook}|{reason}".encode("utf-8")).hexdigest()[:16]


def acquire_lock(lock_path):
    """fcntl.flock 기반 lock — 커널이 프로세스 종료 시 자동 해제하므로 manual stale 검사 불필요.

    구버전 race 회피: stale 파일을 미리 unlink 하지 않는다. 항상 같은 lock_path 를 open(a+)
    하고 flock(LOCK_EX|LOCK_NB) 만 시도. 다른 프로세스가 점유 중이면 BlockingIOError. 점유한 프로세스가
    종료(crash 포함)되면 커널이 자동 해제하므로 다음 호출은 즉시 성공.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fp = open(lock_path, "a+")  # O_RDWR|O_CREAT, append mode 로 truncate 회피
    try:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fp.close()
        return None
    # 진단용: PID 와 시작 시각을 파일 내에 기록 (정보용)
    fp.seek(0)
    fp.truncate()
    fp.write(json.dumps({"pid": os.getpid(), "started_at": time.time()}))
    fp.flush()
    return fp


def atomic_write(path: Path, content: str):
    """Same-dir tempfile + os.replace."""
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp_path, str(path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(text):
    """Returns (fm_dict, body). JSON-quoted 값은 json.loads 로 unescape."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        v = v.strip()
        # JSON-quoted (with double quotes) → 정식 파싱으로 escape 복원
        if len(v) >= 2 and v.startswith('"') and v.endswith('"'):
            try:
                v = json.loads(v)
            except json.JSONDecodeError:
                v = v[1:-1]  # fallback
        fm[k.strip()] = v
    return fm, text[m.end():]


def serialize_frontmatter(fm: dict) -> str:
    lines = ["---"]
    for k, v in fm.items():
        # JSON-quote values to handle quotes/colons
        lines.append(f'{k}: {json.dumps(v, ensure_ascii=False)}')
    lines.append("---")
    return "\n".join(lines)


def render_incident(fm: dict, examples: list, body_extra: str = "") -> str:
    fm_block = serialize_frontmatter(fm)
    examples_block = "\n".join(str(e) for e in examples) if examples else "(no examples)"
    return f"""{fm_block}

# Incident: {fm['hook']} / {fm['reason']}

## 예시 (최근 최대 5건)

```
{examples_block}
```

## 분석 메모

(incidents-to-rule 스킬이 분석 결과를 여기에 기록)

## 승격 이력

{body_extra or '(사용자 결정 기록)'}
"""


def find_open_incident(incidents_dir: Path, hook: str, hash_: str):
    """Returns (path, fm) of latest pending incident in suffix series, or None.

    Suffix 번호로 numeric sort (descending). lexical sort 면 -10 < -2 가 되어 잘못됨.
    """
    base_name = f"auto-{hook}-{hash_}"
    pattern = f"{base_name}*.md"

    def suffix_num(path: Path) -> int:
        stem = path.stem  # 'auto-hook-hash' or 'auto-hook-hash-N'
        if stem == base_name:
            return 0  # base = suffix 0
        rest = stem[len(base_name) + 1:]  # after '-'
        try:
            return int(rest)
        except ValueError:
            return -1  # 잘못된 형식은 뒤로

    candidates = sorted(incidents_dir.glob(pattern), key=suffix_num, reverse=True)
    for path in candidates:
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status") == "pending":
                return path, fm
        except Exception:
            continue
    return None


def next_suffix_path(incidents_dir: Path, hook: str, hash_: str):
    """Return next available auto-<hook>-<hash>[-N].md path.

    조립 결과가 incidents 디렉토리 밖을 가리키면 `ValueError` 로 닫는다
    (`_incident_path_is_contained` 참조 — 호출부의 hook 문법 검증에 이은
    2차 방어).
    """
    def _checked(p: Path) -> Path:
        if not _incident_path_is_contained(incidents_dir, p):
            raise ValueError(
                "사건 경로가 incidents 디렉토리를 벗어남 (hook=%r)" % hook)
        return p

    base = _checked(incidents_dir / f"auto-{hook}-{hash_}.md")
    if not base.exists():
        return base
    n = 2
    while True:
        p = _checked(incidents_dir / f"auto-{hook}-{hash_}-{n}.md")
        if not p.exists():
            return p
        n += 1


def _project_bootstrapped(project_dir: Path) -> bool:
    """A project owns trail/ writes only once it has completed rein bootstrap.

    `.rein/project.json` is the bootstrap completion marker (written last,
    atomically, by rein-bootstrap-project.py) — it must be a regular file,
    matching every other reader of this marker (the hooks' `[ -f ... ]`
    checks, bootstrap-check.sh's tri-marker predicate). A directory or other
    non-file entry at that path is not a valid marker and must be treated the
    same as absent. Any aggregate-side write (mkdir included) must be gated
    on this — a Stop-hook trap firing on an early exit in a never-bootstrapped
    project must not leave a stray trail/incidents/ behind, or the next
    prompt's bootstrap tri-marker check misreads it as a crashed-mid-run
    PARTIAL state instead of "not started".
    """
    return (project_dir / ".rein" / "project.json").is_file()


def aggregate(project_dir: Path):
    if not _project_bootstrapped(project_dir):
        return 0, 0

    incidents_dir = project_dir / "trail/incidents"
    blocks_jsonl = incidents_dir / "blocks.jsonl"
    watermark = incidents_dir / ".last-processed-line"
    lock_path = incidents_dir / ".aggregate.lock"

    if not blocks_jsonl.exists():
        return 0, 0

    incidents_dir.mkdir(parents=True, exist_ok=True)
    fp = acquire_lock(lock_path)
    if fp is None:
        print("NOTICE: incident 집계 skip (다른 세션 처리 중)", file=sys.stderr)
        return 0, 0

    try:
        last_line = 0
        if watermark.exists():
            try:
                last_line = int(watermark.read_text().strip())
            except ValueError:
                last_line = 0

        # 새 라인만 읽기.
        #
        # **바이너리로 읽고 줄 단위로 디코딩한다**: 파일 전체를 텍스트로 열면
        # 잘못된 바이트 하나가 `UnicodeDecodeError` 로 전체 집계를 죽인다
        # (실측: 손상 바이트 1개 → exit 1, 격리 파일도 워터마크도 남지 않아
        # 이후 집계가 영구 중단). 디코딩 실패는 파싱 실패와 같은 등급의
        # "해석 불가" 이므로 같은 격리 경로로 보낸다.
        with open(blocks_jsonl, "rb") as f:
            all_raw = f.readlines()
        total = len(all_raw)
        if total <= last_line:
            return 0, 0

        new_raw = all_raw[last_line:]
        # 패턴 카운트 + 예시 수집
        counts = defaultdict(int)
        examples = defaultdict(list)
        bad_path = blocks_jsonl.with_suffix(".jsonl.bad")
        bad_lines = []
        for idx, raw_bytes in enumerate(new_raw, start=last_line + 1):
            # 해석 불가 3분류를 모두 같은 격리 경로로 보낸다 — 어느 하나라도
            # 예외로 새어나가면 손상 행 한 줄이 집계 전체를 영구 중단시킨다.
            #   (a) UTF-8 디코딩 실패  (b) JSON 파싱 실패
            #   (c) 스키마 위반 — 최상위가 객체가 아니거나 hook/reason 이
            #       문자열이 아닌 경우(list/dict 등). 이전 판은 (c) 에서
            #       AttributeError/TypeError 로 죽었다.
            e = _safe_parse_record(raw_bytes)
            if e is None:
                # 디코딩·파싱·스키마 어느 실패든 같은 격리 경로로.
                bad_lines.append((idx, raw_bytes))
                continue
            hook = e.get("hook", "")
            reason = e.get("reason", "")
            target = e.get("target", "")
            if not _utf8_safe_str(hook) or not _utf8_safe_str(reason) \
                    or not _utf8_safe_str(target):
                # 비문자열이거나 UTF-8 직렬화 불가(surrogate) → 격리.
                bad_lines.append((idx, raw_bytes))
                continue
            if not hook or not reason:
                continue
            # hook 은 사건 파일 이름의 일부가 된다 — 닫힌 식별자 문법만 허용.
            # 위반 행은 집계에서 제외한다(격리 대상은 "해석 불가" 이고 이건
            # 해석은 되지만 신뢰할 수 없는 값이다).
            if not _SAFE_HOOK_NAME.fullmatch(hook):
                print("WARNING: 안전하지 않은 hook 이름 (line %d) — 집계 제외"
                      % idx, file=sys.stderr)
                continue
            # v1 safety release ①: 테스트 하니스발 이벤트는 incident 승격
            # 신호에서 제외 (legacy 무필드 레코드는 live 취급 — FN 방지).
            if e.get("source", "live") == "test":
                continue
            key = (hook, reason)
            counts[key] += 1
            if len(examples[key]) < 5:
                # 출처 필드 없는 legacy 레코드의 target 은 마스킹 이전
                # 원문일 수 있어 통째로 치환한다. 출처가 있어도 경로까지
                # 안전하다는 보장은 없으므로 마스킹 + 경로 정규화를 건다.
                if "source" not in e:
                    target = "<legacy-target-redacted>"
                else:
                    target = _normalize_example_path(_redact_example(target))
                examples[key].append(target)

        if bad_lines:
            # 손상 행의 **본문은 기록하지 않는다** — 줄 번호와 내용 해시만.
            #
            # 이 격리 파일은 git 추적 디렉토리 아래에 생기고 무시 규칙이
            # 없다. 그런데 마스킹·경로 규칙은 정규식이라 원문의 의미가 아니라
            # 표기를 본다: 파싱에 실패한 행은 정의상 신뢰할 수 있게 해석할 수
            # 없고, JSON 이스케이프(`pass\u0077ord`, `\/Users\/…`) 하나로
            # 규칙을 비껴간다. 정화를 시도해 통과시키면 그 우회분이 그대로
            # 기록된다 — 해석 불가능한 입력을 정화했다고 주장하지 않는 편이
            # 유일하게 건전하다.
            #
            # 진단 손실은 없다: 원문은 `blocks.jsonl` 의 해당 줄에 그대로
            # 있으므로 줄 번호로 찾아가면 된다. 해시는 같은 손상 행의 반복
            # 여부를 대조하는 용도다.
            with open(bad_path, "a") as bad_f:
                for idx, raw_bytes in bad_lines:
                    # 원문 바이트 그대로 해시 — 디코딩 불가 행도 대조 가능해야
                    # 하므로 문자열로 변환하지 않는다.
                    digest = hashlib.sha256(
                        raw_bytes.rstrip(b"\n")
                    ).hexdigest()[:12]
                    bad_f.write(f"# line {idx} #{digest}\n")
            # 경로를 그대로 찍으면 홈 아래 프로젝트에서 사용자명이 세션
            # 로그로 샌다 — 파일 자체의 정화와 같은 기준을 표시 경로에도 적용.
            print("WARNING: %d 손상 라인 → %s"
                  % (len(bad_lines), _display_path(bad_path)), file=sys.stderr)

        created = 0
        updated = 0
        now = utcnow_iso()
        for (hook, reason), count in counts.items():
            hash_ = compute_hash(hook, reason)
            open_inc = find_open_incident(incidents_dir, hook, hash_)

            # 기존 pending 이 있으면 THRESHOLD 와 무관하게 무조건 누적 갱신한다.
            # 이전 로직은 증가분이 1건(threshold=2 미만) 이면 skip 되어 느린 반복
            # 패턴의 count/last_seen_at 이 영구 과소 집계되었음 (codex v0.7.2 High).
            # THRESHOLD 는 "신규 incident 생성" 여부 판정에만 사용.
            if open_inc:
                path, fm = open_inc
                old_count = int(fm.get("count", "0"))
                fm["count"] = str(old_count + count)
                fm["last_seen_at"] = now
                _, body = parse_frontmatter(path.read_text())
                content = serialize_frontmatter(fm) + "\n" + body
                atomic_write(path, content)
                updated += 1
            elif count >= THRESHOLD:
                # 모든 suffix 가 closed + 이번 배치가 THRESHOLD 이상 → 새 파일 발급
                new_path = next_suffix_path(incidents_dir, hook, hash_)
                fm = {
                    "status": "pending",
                    "pattern_hash": hash_,
                    "hook": hook,
                    "reason": reason,
                    "count": str(count),
                    "first_seen": now,
                    "last_seen_at": now,
                }
                content = render_incident(fm, examples[(hook, reason)])
                atomic_write(new_path, content)
                created += 1
            # else: open_inc 없고 count < THRESHOLD → skip

        # watermark advance (atomic) — lock 안에서 incident 생성과 묶음
        atomic_write(watermark, str(total))

        # Write session state snapshot for SessionStart to detect abnormal termination.
        # session_end 는 보존 (Stop hook 의 trap 또는 SessionStart 의 reset 만 변경).
        snapshot_path = incidents_dir / ".last-aggregate-state.json"
        prev_session_end = False
        if snapshot_path.exists():
            _prev = _read_snapshot_dict(snapshot_path)
            if _prev is not None:
                prev_session_end = bool(_prev.get("session_end", False))
            else:
                print(
                    "WARNING: snapshot %s unreadable or not a dict "
                    "— session_end defaults to False this cycle"
                    % _display_path(snapshot_path),
                    file=sys.stderr,
                )
        snapshot = {
            "watermark": total,
            "pending_hashes": list_pending_hashes(incidents_dir),
            "timestamp": now,
            "session_end": prev_session_end,
        }
        atomic_write(snapshot_path, json.dumps(snapshot, ensure_ascii=False, indent=2))

        if created or updated:
            print(f"NOTICE: incident patterns — created={created}, updated={updated}", file=sys.stderr)

        return created, updated

    finally:
        # lock_path.unlink 하지 않음. 파일을 삭제하면 다른 프로세스가
        # 먼저 O_CREAT 로 새 inode 를 잡아 flock 이 서로 다른 객체에 걸리게 되어
        # 동시 집계 race 가 발생함 (codex v0.7.2 review High).
        # 고정 경로 파일에 대해 flock 만 사용하는 것이 올바르다.
        try:
            fcntl.flock(fp, fcntl.LOCK_UN)
            fp.close()
        except Exception:
            pass


def list_pending_hashes(incidents_dir: Path) -> list:
    """Return sorted list of pattern_hash values for all files with status=pending."""
    hashes = set()
    for path in incidents_dir.glob("auto-*.md"):
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status", "") == "pending":
                h = fm.get("pattern_hash", "")
                if h:
                    hashes.add(h)
        except Exception:
            continue
    return sorted(hashes)


def count_pending(project_dir: Path) -> int:
    incidents_dir = project_dir / "trail/incidents"
    if not incidents_dir.exists():
        return 0
    n = 0
    # glob 이 auto-*.md 만 반환하므로 startswith 필터 불필요.
    # SKILL.md 정책: 루트의 frontmatter 없는 .md 파일은 무시 (legacy INC-*.md 는 legacy/ 서브디렉토리 opt-in).
    for path in incidents_dir.glob("auto-*.md"):
        try:
            fm, _ = parse_frontmatter(path.read_text())
            if fm.get("status", "") == "pending":
                n += 1
        except Exception:
            continue
    return n


def set_session_end(project_dir: Path, value: bool) -> int:
    """Atomic update of snapshot.session_end under aggregate flock (single-writer path).

    Stop hook 의 trap EXIT 와 SessionStart 의 reset 이 모두 이 경로만 호출하도록
    해 multi-writer race 를 제거한다. 다른 snapshot 필드 (watermark, pending_hashes,
    timestamp) 는 변경하지 않는다.

    Lock contention 시 silent (return 0) — hook 흐름을 차단하지 않는다.
    """
    if not _project_bootstrapped(project_dir):
        return 0

    incidents_dir = project_dir / "trail/incidents"
    snapshot_path = incidents_dir / ".last-aggregate-state.json"
    lock_path = incidents_dir / ".aggregate.lock"

    incidents_dir.mkdir(parents=True, exist_ok=True)
    fp = acquire_lock(lock_path)
    if fp is None:
        return 0
    try:
        snapshot = {}
        if snapshot_path.exists():
            _snap = _read_snapshot_dict(snapshot_path)
            if _snap is not None:
                snapshot = _snap
            else:
                print(
                    "WARNING: snapshot %s unreadable or not a dict "
                    "— rewriting with defaults"
                    % _display_path(snapshot_path),
                    file=sys.stderr,
                )
        snapshot["session_end"] = bool(value)
        snapshot.setdefault("watermark", 0)
        snapshot.setdefault("pending_hashes", [])
        snapshot.setdefault("timestamp", utcnow_iso())
        atomic_write(snapshot_path, json.dumps(snapshot, ensure_ascii=False, indent=2))
        return 0
    finally:
        try:
            fcntl.flock(fp, fcntl.LOCK_UN)
            fp.close()
        except Exception:
            pass


def cmd_advisory_summary(args) -> int:
    """advisory-summary 서브커맨드: blocks.jsonl 을 집계해 패턴 JSON 을 출력한다.

    blocks.jsonl 의 각 레코드는 {"ts": ..., "source": ..., "reason": ..., "target": ...} 형식.
    reason 필드를 pattern_label 로 사용하며 sha1 해시를 pattern_hash 로 부여한다.
    """
    blocks_jsonl_path = Path(
        os.environ.get("REIN_BLOCKS_JSONL", "")
        or os.path.join(str(Path(args.project_dir or ".").resolve()), "trail", "incidents", "blocks.jsonl")
    )

    if not blocks_jsonl_path.exists():
        print("[]")
        return 0

    since_line = max(1, args.since_line) if args.since_line is not None else 1
    since_ts = args.since_ts if hasattr(args, "since_ts") else None

    counts: dict = {}        # label → int
    examples: dict = {}      # label → list[str]

    # 바이너리로 읽는다: 손상 바이트 1개에 전체 summary 가 죽어(Stop 훅에서
    # 전량 소실) 반복 경고가 사라지지 않도록. 해석 불가 행은 조용히 skip
    # (여기는 격리가 아니라 요약이므로 — 격리는 집계 경로가 담당).
    with open(blocks_jsonl_path, "rb") as f:
        all_lines = f.readlines()

    # since_line is 1-indexed; skip lines before it
    for idx_zero, raw in enumerate(all_lines):
        line_num = idx_zero + 1  # 1-indexed
        if line_num < since_line:
            continue
        rec = _safe_parse_record(raw)
        if rec is None:
            continue
        # 최상위가 dict 여도 필드 타입까지 신뢰하면 안 된다: ts 가 list 면
        # 문자열 비교에서, reason 이 list 면 counts 키(해시 불가)에서 TypeError
        # 로 죽어 뒤의 정상 행까지 요약에서 사라진다. 필요한 필드가 문자열이
        # 아니면 그 행만 skip (집계 루프의 hook/reason/target isinstance 가드와
        # 동일 원칙).
        ts = rec.get("ts", "")
        label = rec.get("reason", "")
        # ts 는 비교에만, reason 은 counts 키·sha 인코딩에 쓰인다. ts 는 str
        # 이면 충분하고 reason 은 UTF-8 직렬화까지 가능해야 한다(surrogate 방지).
        # source 는 `== "test"` 비교뿐이라 타입 무관 안전 — 별도 가드를 두면
        # aggregate/live_count 와 의미가 갈리므로 두지 않는다(셋 다 비문자열
        # source 는 test 아님 → live 로 동일 취급).
        if not isinstance(ts, str) or not _utf8_safe_str(label):
            continue
        if since_ts and ts < since_ts:
            continue
        # v1 safety release ①: 테스트 하니스발 이벤트는 세션 종료 advisory
        # 카운트에서도 제외 (aggregate() 와 동일 계약).
        if rec.get("source", "live") == "test":
            continue
        if not label:
            continue
        counts[label] = counts.get(label, 0) + 1
        if len(examples.get(label, [])) < 3:
            ref = f"blocks.jsonl:L{line_num}"
            examples.setdefault(label, []).append(ref)

    result = []
    for label, count in counts.items():
        pattern_hash = hashlib.sha1(label.encode("utf-8")).hexdigest()[:12]
        result.append({
            "pattern_hash": pattern_hash,
            "pattern_label": label,
            "count": count,
            "examples": examples.get(label, []),
        })

    # Sort by (-count, pattern_label) for deterministic output
    result.sort(key=lambda x: (-x["count"], x["pattern_label"]))
    print(json.dumps(result, ensure_ascii=False))
    return 0


def cmd_combined(project_dir: Path, session_end_value: bool, run_agg: bool) -> dict:
    """PERF-1 combined-execution mode.

    Executes the three session-start steps in guaranteed order inside one process:
      1. set_session_end(false)   — reset stamp from previous session
      2. aggregate()              — incorporate any new blocks.jsonl lines
      3. count_pending()          — read final pending count

    Returns a dict suitable for JSON serialisation.
    """
    # Step 1 — always runs (session_end reset)
    set_session_end(project_dir, session_end_value)

    # Step 2 — conditional on --run-aggregate flag
    aggregate_ran = False
    if run_agg:
        aggregate(project_dir)
        aggregate_ran = True

    # Step 3 — always runs
    pending = count_pending(project_dir)

    return {
        "pending_count": pending,
        "session_end_set": session_end_value,
        "aggregate_ran": aggregate_ran,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=os.environ.get("REIN_PROJECT_DIR"))
    parser.add_argument("--count-pending", action="store_true",
                        help="aggregate 대신 pending 개수만 출력")

    # PERF-1: combined-execution mode flags (use alongside --output-json).
    # These are TOP-LEVEL flags so they compose with any future subcommand path
    # without conflicting with the existing `set-session-end <value>` subcommand.
    parser.add_argument(
        "--set-session-end",
        dest="set_session_end_value",
        choices=["true", "false"],
        default=None,
        metavar="true|false",
        help="(combined mode) session_end 값을 설정 (true|false)"
    )
    parser.add_argument(
        "--run-aggregate",
        action="store_true",
        dest="run_aggregate",
        help="(combined mode) aggregate() 를 실행"
    )
    parser.add_argument(
        "--output-json",
        action="store_true",
        dest="output_json",
        help="(combined mode) 결과를 JSON 으로 출력 (pending_count, session_end_set, aggregate_ran)"
    )

    subparsers = parser.add_subparsers(dest="subcommand")

    # advisory-summary 서브커맨드
    adv_parser = subparsers.add_parser(
        "advisory-summary",
        help="blocks.jsonl 을 집계해 패턴 요약 JSON 출력"
    )
    adv_parser.add_argument(
        "--since-line",
        type=int,
        default=1,
        metavar="N",
        help="1-indexed 시작 줄 번호 (기본: 1 = 전체)"
    )
    adv_parser.add_argument(
        "--since-ts",
        default=None,
        metavar="ISO8601",
        help="이 타임스탬프 이후 레코드만 집계"
    )

    sse_parser = subparsers.add_parser(
        "set-session-end",
        help="snapshot 의 session_end 필드만 flock 안에서 atomic 갱신 (단일 writer 경로)"
    )
    sse_parser.add_argument("value", choices=["true", "false"])

    args = parser.parse_args()
    project_dir = Path(args.project_dir or ".").resolve()

    if args.subcommand == "advisory-summary":
        sys.exit(cmd_advisory_summary(args))

    if args.subcommand == "set-session-end":
        sys.exit(set_session_end(project_dir, args.value == "true"))

    # PERF-1 combined mode: triggered when --output-json is present.
    # Guarantees execution order: set-session-end → aggregate → count-pending.
    if args.output_json:
        session_end_value = (args.set_session_end_value == "true") if args.set_session_end_value is not None else False
        result = cmd_combined(
            project_dir=project_dir,
            session_end_value=session_end_value,
            run_agg=args.run_aggregate,
        )
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)

    if args.count_pending:
        print(count_pending(project_dir))
        sys.exit(0)

    created, updated = aggregate(project_dir)
    sys.exit(0)
