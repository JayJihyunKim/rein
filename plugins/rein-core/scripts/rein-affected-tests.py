#!/usr/bin/env python3
"""rein-affected-tests — 바뀐 파일에서 돌릴 테스트와 실행 명령을 고르는 선택기.

에이전트가 후속 리뷰 요청서의 델타 증거를 쓸 때 직접 호출한다(래퍼는 호출하지
않는다). 판정 순서는 hard 복귀 조건 → 프로젝트 스크립트(.rein/affected-tests.sh 의
--base 판) → 스택 판정 → 정밀 도구(jest / vitest / pytest-testmon, 필요하면 testmon
자동 설치) → rein 내장 import 검색 → 전체 실행(fail-closed) 이다.

CLI:
    rein-affected-tests.py [--base REF] [--format text|json] [--no-install]
                           [--untracked-scope GLOB ...] [--untracked-snapshot FILE]
                           [--external-inputs-changed] [--root DIR]

종료 코드: 0 = 출력을 냈다(전체 실행 판정 포함), 1 = 예상하지 못한 내부 오류,
2 = 인자 오류(스냅샷 파일 읽기·형식 오류 포함). 기준 ref 해석 실패·git 저장소
아님·git 실행 실패는 종료 코드 0 + full_run_required: true + 사유다.

설계: docs/specs/2026-10-08-affected-tests-and-precheck.md §3.1
"""
from __future__ import annotations

import argparse
import ast
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import string
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

# ---- 판정 상수 (spec §3.1.5 — 선택기 판정의 단일 출처) ----------------------
MAX_SOURCE_FILES = 5      # SKILL "소스 파일 5개 초과"
MAX_DELTA_LINES = 200     # SKILL "변경 200줄 초과"
IMPORT_SEARCH_MAX_RATIO = 0.5   # import-search 대상 > 전체 테스트 파일의 절반 → full
SHARED_MODULE_MIN_TESTS = 2     # import-search: 직접 import 하는 테스트 파일이 이 수 이상이면 공용 모듈 → full
MAX_PARSE_BYTES = 1_000_000     # 파일당 파싱 상한 — 넘는 파일은 "파싱 실패" 와 같게 처리
SCRIPT_STDOUT_MAX = 1_048_576   # 프로젝트 스크립트 stdout 보관 상한 (D16)
SELECTOR_BUDGET = 600     # 선택기 전체 상한(초) (D13)

# ---- 시간·개수 상수 (spec §3.1.1) -------------------------------------------
GIT_TIMEOUT = 60
PROBE_TIMEOUT = 30
PROJECT_SCRIPT_TIMEOUT = 120
INSTALL_TIMEOUT = 300
MAX_SCAN_FILES = 20000

INSTALL_SPEC = "pytest-testmon>=2,<3"
METHODS = ("project-script", "jest", "vitest", "testmon", "import-search", "full")

PY_EXTS = (".py",)
JS_EXTS = (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".mts", ".cts")

# ---- 분류 표 (spec §3.1.4) --------------------------------------------------
DEP_CONFIG_NAMES = frozenset((
    "pyproject.toml", "setup.py", "setup.cfg", "poetry.lock", "uv.lock",
    "Pipfile", "Pipfile.lock", "tox.ini", "pytest.ini", "package.json",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", ".babelrc",
))
DEP_CONFIG_PATTERNS = (
    "requirements*.txt", "jest.config.*", "vitest.config.*", "vite.config.*",
    "babel.config.*", "tsconfig*.json",
)
TEST_SHARED_NAMES = ("conftest.py", "jest.setup.*", "vitest.setup.*", "setupTests.*")
TEST_SHARED_PARTS = ("tests/fixtures/", "tests/helpers/", "test/fixtures/", "__fixtures__/")
DOC_EXTS = (".md", ".rst", ".txt")
DOC_PREFIXES = ("docs/", "trail/", ".rein/")

# ---- 경로·입출력 상수 --------------------------------------------------------
STATE_REL = ".rein/state/test-tools.json"
LOCK_REL = ".rein/state/test-tools.lock"
SCRIPT_REL = ".rein/affected-tests.sh"
SCRIPT_ENV_DROP = frozenset({"BASH_ENV", "ENV", "CDPATH"})   # 셸 시작 코드 주입 경로
CHUNK_BYTES = 65536
KILL_GRACE_SEC = 2
STDERR_TAIL_LINES = 5
INSTALL_TAIL_LINES = 20
GIT_OUT_MAX = 67_108_864        # git 출력 보관 상한 — 넘으면 git 실행 실패로 본다
SCRIPT_COMMAND_MAX = 4096       # 프로젝트 스크립트 command 길이 상한
JS_LITERAL_MAX = 4096           # 동적 import 첫 인자 리터럴을 찾는 창 크기
PROBE_CODE = "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec('testmon') else 1)"

# ---- 사유 문구 -------------------------------------------------------------
INSTALLED_REASON = (
    "테스트 도구 설치(pytest-testmon) — 의존성 변경 + testmon 기록 생성을 위해 이번 회차는 전체 실행"
)
NO_TESTMON_DATA = "testmon 기록 없음 — 이번 전체 실행이 기록을 만든다"
SKIPPED_MESSAGE = "venv 없는 시스템 파이썬 — 프로젝트 환경을 만든 뒤 기록 파일을 지우면 다시 시도한다"
FULL_DELTA_LINE = "델타 증거 칸: 쓰지 않음 — 전체 실행 후 새 기준 트리를 만든다"
INSTALL_NOTICE = "주의: 의존성 파일이 바뀌었다 — 다음 리뷰 대상에 포함된다"

# ---- 정규식 (중첩 수량자 없는 단순 패턴) -------------------------------------
SHA_RE = re.compile(r"[0-9a-fA-F]{64}")
CTRL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
JS_IMPORT_RE = re.compile(
    r"""\b(?:import|export)\b[^'"`;()]*?\bfrom\s*(['"])([^'"\n]*)\1"""
    r"""|\bimport\s*(['"])([^'"\n]*)\3"""
)
JS_DYN_RE = re.compile(r"\b(?:require|import)\s*\(\s*")
JS_SIMPLE_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v"}  # 단일 문자 이스케이프
JS_LINE_TERMINATORS = ("\r\n", "\n", "\r", "\u2028", "\u2029")  # 백슬래시 + 이것 = 줄 이음(제거)
JS_ARG_END_RE = re.compile(r"\s*[),]")   # 리터럴 첫 인자 뒤에 올 수 있는 것: 공백 + `)`·`,`
DISCOVERY_KEY_RE = re.compile(r"\s*(?:python_files|testpaths)\s*[=:]")
JEST_KEY_RE = re.compile(r"\b(?:testMatch|testRegex|roots)\b")
VITEST_KEY_RE = re.compile(r"\binclude(?:Source)?\b")
TESTMON_REQ_RE = re.compile(r"^\s*pytest-testmon\b", re.MULTILINE)
INI_COMMENT_RE = re.compile(r"[#;]")

PYTEST_INI_HEADERS = ("[pytest]", "[tool:pytest]")
PYTEST_CONFIGS = (
    ("pytest.ini", PYTEST_INI_HEADERS),
    ("tox.ini", PYTEST_INI_HEADERS),
    ("setup.cfg", PYTEST_INI_HEADERS),
    ("pyproject.toml", ("[tool.pytest.ini_options]",)),
)
MGR_UNSET = "<unset>"


class DeadlineExceeded(Exception):
    """선택기 전체 상한 초과 — select 가 잡아 full 로 만든다."""


class GitError(Exception):
    """git 실행 실패(비0·시간 초과·출력 과다·실행 파일 없음)."""


class SnapshotError(Exception):
    """--untracked-snapshot 읽기·형식 오류 — 종료 코드 2."""


class Deadline:
    """선택기 전체 상한. 하위 프로세스 시간 제한과 반복 루프가 이것을 본다 (D13)."""

    def __init__(self, budget):
        self.budget = budget
        self.end = time.monotonic() + budget

    def remaining(self):
        return max(0.0, self.end - time.monotonic())

    def cap(self, t):
        return min(float(t), self.remaining())

    def expired(self):
        return time.monotonic() >= self.end


@dataclass
class RunOpts:
    timeout: float
    stdin: bytes | None = None
    out_max: int = SCRIPT_STDOUT_MAX
    env: dict | None = None


@dataclass
class RunResult:
    rc: int
    out: bytes
    out_truncated: bool
    err: bytes
    timed_out: bool


@dataclass
class Graph:
    tests: set = field(default_factory=set)
    deps: dict = field(default_factory=dict)
    rdeps: dict = field(default_factory=dict)
    dynamic: set = field(default_factory=set)
    error: str | None = None


@dataclass
class Ctx:
    root: str
    base: str
    args: argparse.Namespace
    deadline: Deadline
    snapshot: dict = field(default_factory=dict)
    base_rev: str = ""
    reasons: list = field(default_factory=list)
    changes: list = field(default_factory=list)
    totals: dict = field(default_factory=dict)
    files: list | None = None
    stack: str | None = None
    graph: Graph | None = None
    mgr: str | None = MGR_UNSET
    testmon: bool | None = None
    install: dict | None = None
    lock_fd: int | None = None


class _Sink:
    """앞의 limit + 1 바이트만 보관하고 나머지는 읽어서 버린다 (D16)."""

    def __init__(self, limit):
        self.limit = limit
        self.data = bytearray()

    def add(self, chunk):
        room = self.limit + 1 - len(self.data)
        if room > 0:
            self.data += chunk[:room]


# ---- 작은 도우미 -------------------------------------------------------------

def env_int(name, default, bounds):
    """환경 변수 재정의 — 정수이고 bounds=(lo, hi) 안일 때만, 아니면 default."""
    raw = os.environ.get(name, "").strip()
    if not raw or not raw.isascii() or not raw.isdigit():
        return default
    value = int(raw)
    low, high = bounds
    return value if low <= value <= high else default


def _unlink_quiet(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _is_regular(path):
    return os.path.isfile(path) and not os.path.islink(path)


def _clean(text):
    return CTRL_RE.sub("", text)


def _tail_lines(data, count):
    """출력 마지막 count 줄(빈 줄 제외, 제어 문자 제거)."""
    lines = [_clean(line).strip() for line in data.decode("utf-8", "replace").splitlines()]
    return [line for line in lines if line][-count:]


def _fn_any(name, patterns):
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def _nul_split(data):
    return [part for part in data.decode("utf-8", "surrogateescape").split("\0") if part]


def _read_capped(path):
    """파일 바이트(MAX_PARSE_BYTES 이하). 읽기 실패·상한 초과면 None."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_PARSE_BYTES + 1)
    except OSError:
        return None
    return None if len(data) > MAX_PARSE_BYTES else data


def _read_text(path):
    """(존재 여부, 텍스트). 존재하지만 읽거나 디코딩하지 못하면 텍스트는 None."""
    if not os.path.lexists(path):
        return False, None
    data = _read_capped(path)
    if data is None:
        return True, None
    try:
        return True, data.decode("utf-8")
    except UnicodeDecodeError:
        return True, None


def _root_matches(root, pattern):
    try:
        names = os.listdir(root)
    except OSError:
        return []
    return sorted(name for name in names if fnmatch.fnmatchcase(name, pattern))


def emit(text):
    """출력은 이 함수 한 곳에서만 한다."""
    out = getattr(sys.stdout, "buffer", None)
    if out is None:
        sys.stdout.write(text)
        return
    out.write(text.encode("utf-8", "surrogateescape"))
    out.flush()


# ---- 하위 프로세스 실행 (spec §3.1.7 공통, D13·D16) -------------------------

def _drain(fd, sink):
    """파이프를 끝까지 읽어 sink 에 넣는다 — 출력이 많아도 자식이 막히지 않는다."""
    try:
        while True:
            chunk = os.read(fd, CHUNK_BYTES)
            if not chunk:
                break
            sink.add(chunk)
    except OSError:
        pass


def _feed(pipe, data):
    """stdin 을 별도 스레드로 쓰고 닫는다(큰 입력에서 막힘 방지)."""
    try:
        pipe.write(data)
    except OSError:
        pass
    finally:
        try:
            pipe.close()
        except OSError:
            pass


def _killpg(pid, sig):
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def _start_thread(target, args):
    thread = threading.Thread(target=target, args=args, daemon=True)
    thread.start()
    return thread


def _wait_or_kill(proc, timeout):
    """시간 초과면 그룹 TERM → KILL_GRACE_SEC → 그룹 KILL → 회수. 반환: 시간 초과 여부."""
    try:
        proc.wait(timeout=timeout)
        return False
    except subprocess.TimeoutExpired:
        pass
    _killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=KILL_GRACE_SEC)
    except subprocess.TimeoutExpired:
        pass
    _killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    return True


def _join_all(threads, pid):
    """읽기 스레드 회수. 파이프를 쥔 자손이 남았으면 그룹을 끝내고 다시 기다린다."""
    for thread in threads:
        thread.join(KILL_GRACE_SEC)
    if any(thread.is_alive() for thread in threads):
        _killpg(pid, signal.SIGKILL)
        for thread in threads:
            thread.join(KILL_GRACE_SEC)


def run(argv, root, opts):
    """새 세션 Popen + 상한 읽기 스레드 + 시간 초과 시 그룹 종료. 실행 파일 없음은 OSError."""
    proc = subprocess.Popen(
        argv,
        shell=False,
        cwd=root,
        env=opts.env,
        stdin=subprocess.PIPE if opts.stdin is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    out, err = _Sink(opts.out_max), _Sink(opts.out_max)
    threads = [
        _start_thread(_drain, (proc.stdout.fileno(), out)),
        _start_thread(_drain, (proc.stderr.fileno(), err)),
    ]
    if opts.stdin is not None:
        threads.append(_start_thread(_feed, (proc.stdin, opts.stdin)))
    timed_out = _wait_or_kill(proc, opts.timeout)
    _join_all(threads, proc.pid)
    if not any(thread.is_alive() for thread in threads):
        proc.stdout.close()
        proc.stderr.close()
    truncated = len(out.data) > opts.out_max
    return RunResult(proc.returncode, bytes(out.data), truncated, bytes(err.data), timed_out)


# ---- git --------------------------------------------------------------------

def _git_env():
    return dict(os.environ, GIT_OPTIONAL_LOCKS="0")


def _git_raw(cwd, args):
    """ctx 이전(루트 해석) 단계의 git 호출. 실패면 None."""
    opts = RunOpts(timeout=GIT_TIMEOUT, out_max=GIT_OUT_MAX, env=_git_env())
    try:
        res = run(["git", "-C", cwd, *args], cwd, opts)
    except OSError:
        return None
    if res.timed_out or res.rc != 0 or res.out_truncated:
        return None
    return res.out.decode("utf-8", "surrogateescape")


def git(ctx, args):
    """기한 안의 git 호출. 시간 초과는 기한이면 DeadlineExceeded, 아니면 GitError."""
    if ctx.deadline.expired():
        raise DeadlineExceeded()
    opts = RunOpts(timeout=ctx.deadline.cap(GIT_TIMEOUT), out_max=GIT_OUT_MAX, env=_git_env())
    try:
        res = run(["git", "-C", ctx.root, *args], ctx.root, opts)
    except OSError as exc:
        raise GitError(f"git {args[0]}: {exc}") from exc
    if res.timed_out:
        if ctx.deadline.expired():
            raise DeadlineExceeded()
        raise GitError(f"git {args[0]}: 시간 초과")
    if res.out_truncated:
        raise GitError(f"git {args[0]}: 출력 과다")
    return res


def git_ok(ctx, args):
    res = git(ctx, args)
    if res.rc != 0:
        raise GitError(f"git {args[0]}: rc={res.rc}")
    return res.out


def resolve_root(arg):
    """저장소 루트. --root 가 없으면 현재 디렉터리의 git 최상위. git 저장소가 아니면 None."""
    if arg:
        path = os.path.abspath(arg)
        if not os.path.isdir(path):
            return None
        inside = _git_raw(path, ["rev-parse", "--is-inside-work-tree"])
        return path if inside and inside.strip() == "true" else None
    out = _git_raw(os.getcwd(), ["rev-parse", "--show-toplevel"])
    top = out.strip() if out else ""
    return top or None


def verify_base(ctx):
    """기준 ref 를 커밋으로 해석. 실패면 False (옵션처럼 보이는 값도 거부)."""
    if not ctx.base or ctx.base.startswith("-"):
        return False
    res = git(ctx, ["rev-parse", "--verify", "--quiet", f"{ctx.base}^{{commit}}"])
    rev = res.out.decode("utf-8", "replace").strip()
    if res.rc != 0 or not rev:
        return False
    ctx.base_rev = rev
    return True


def repo_files(ctx):
    """추적 + 미추적(무시 목록 제외) 파일 목록 — 캐시."""
    if ctx.files is None:
        listed = git_ok(ctx, ["ls-files", "-co", "--exclude-standard", "-z"])
        ctx.files = list(dict.fromkeys(_nul_split(listed)))
    return ctx.files


def _files_or_empty(ctx):
    try:
        return repo_files(ctx)
    except (DeadlineExceeded, GitError):
        return []


# ---- 스냅샷·바뀐 파일 수집·분류·줄 수 (spec §3.1.4, D14·D18·D21) -------------

def _snapshot_entry(line):
    parts = line.rsplit(" ", 2)
    ok = (
        len(parts) == 3 and parts[0] and SHA_RE.fullmatch(parts[1])
        and parts[2].isascii() and parts[2].isdigit()
    )
    if not ok:
        raise SnapshotError(f"스냅샷 줄 형식 오류: {line}")
    return parts[0], (parts[1].lower(), int(parts[2]))


def read_snapshot(path):
    """--untracked-snapshot — `<경로> <sha256> <줄 수>` 줄들 또는 `none` 한 줄."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read(GIT_OUT_MAX + 1)
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SnapshotError(f"스냅샷 파일을 읽지 못함: {path}: {exc}") from exc
    if len(raw) > GIT_OUT_MAX:
        raise SnapshotError(f"스냅샷 파일이 너무 큼: {path}")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if lines == ["none"]:
        return {}
    if not lines:
        raise SnapshotError("스냅샷 파일이 비어 있음 — 미추적 파일이 없으면 none 한 줄")
    snapshot = {}
    for line in lines:
        key, value = _snapshot_entry(line)
        if key in snapshot:
            raise SnapshotError(f"스냅샷 경로 중복: {key}")
        snapshot[key] = value
    return snapshot


def is_test_path(path):
    """파일명 규칙으로 테스트 파일인지 (spec §3.1.4 `test` 행)."""
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".py"):
        return fnmatch.fnmatchcase(name, "test_*.py") or fnmatch.fnmatchcase(name, "*_test.py")
    ext = os.path.splitext(name)[1]
    if ext not in JS_EXTS:
        return False
    stem = name[: -len(ext)]
    return stem.endswith((".test", ".spec")) or "/__tests__/" in "/" + path


def classify(path):
    """kind 판정 — 위에서부터 첫 일치 (spec §3.1.4 분류 표)."""
    name = path.rsplit("/", 1)[-1]
    if name in DEP_CONFIG_NAMES or _fn_any(name, DEP_CONFIG_PATTERNS):
        return "dep-config"
    in_shared_dir = any(("/" + part) in ("/" + path) for part in TEST_SHARED_PARTS)
    if _fn_any(name, TEST_SHARED_NAMES) or in_shared_dir:
        return "test-shared"
    if is_test_path(path):
        return "test"
    if path.lower().endswith(DOC_EXTS) or path.startswith(DOC_PREFIXES):
        return "doc"
    return "source"


def _entry(path, status):
    return {"path": path, "status": status, "kind": classify(path)}


def _hash_stream(fh, deadline):
    digest = hashlib.sha256()
    lines = 0
    while True:
        if deadline.expired():
            raise DeadlineExceeded()
        chunk = fh.read(CHUNK_BYTES)
        if not chunk:
            break
        digest.update(chunk)
        lines += chunk.count(b"\n")
    return lines, digest.hexdigest()


def count_lines_stream(path, deadline):
    """정본 줄 수(개행 문자 개수 — wc -l 과 같음)와 sha256. 64 KiB 청크, 절단 없음 (D21)."""
    if not os.path.isfile(path):
        return 0, ""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return 0, ""
    try:
        with os.fdopen(fd, "rb", buffering=0) as fh:
            return _hash_stream(fh, deadline)
    except OSError:
        return 0, ""


def collect_tracked(ctx):
    """추적 파일 — `git diff --name-status -z --no-renames <base> --`."""
    out = git_ok(ctx, ["diff", "--name-status", "-z", "--no-renames", ctx.base_rev, "--"])
    parts = _nul_split(out)
    if len(parts) % 2:
        raise GitError("git diff --name-status: 출력 형식 오류")
    return [_entry(path, status) for status, path in zip(parts[0::2], parts[1::2])]


def _untracked_now(ctx):
    out = git_ok(ctx, ["ls-files", "--others", "--exclude-standard", "-z"])
    paths = _nul_split(out)
    scopes = ctx.args.untracked_scope or []
    if not scopes:
        return paths
    return [path for path in paths if _fn_any(path, scopes)]


def _untracked_deleted(ctx, snapshot, current):
    """스냅샷에 있는데 지금 미추적 목록에 없음 → ?? deleted. 지금 추적 파일이면 세지 않는다."""
    missing = [path for path in sorted(snapshot) if path not in current]
    if not missing:
        return [], 0
    tracked = set(_nul_split(git_ok(ctx, ["ls-files", "-z"])))
    gone = [path for path in missing if path not in tracked]
    return [_entry(path, "?? deleted") for path in gone], sum(snapshot[p][1] for p in gone)


def collect_untracked(ctx, snapshot):
    """미추적 항목 — 정본 규칙(added/modified/deleted + 추적 전환). 반환 (항목, 줄 수 합)."""
    current = _untracked_now(ctx)
    items, total = [], 0
    for path in current:
        if ctx.deadline.expired():
            raise DeadlineExceeded()
        lines, digest = count_lines_stream(os.path.join(ctx.root, path), ctx.deadline)
        prev = snapshot.get(path)
        if prev is None:
            items.append(_entry(path, "?? added"))
            total += lines
        elif prev[0] != digest:
            items.append(_entry(path, "?? modified"))
            total += max(prev[1], lines)
    gone, gone_lines = _untracked_deleted(ctx, snapshot, set(current))
    return items + gone, total + gone_lines


def count_delta_lines(ctx):
    """정본 산식 — numstat 추가+삭제 합(모든 종류, 바이너리 0) + 미추적 항목 줄 수."""
    out = git_ok(ctx, ["diff", "--numstat", "-z", "--no-renames", ctx.base_rev, "--"])
    total = 0
    for record in _nul_split(out):
        fields = record.split("\t", 2)
        if len(fields) < 3:
            continue
        total += sum(int(value) for value in fields[:2] if value.isdigit())
    return total + ctx.totals.get("untracked_lines", 0)


def collect_changes(ctx):
    tracked = collect_tracked(ctx)
    untracked, untracked_lines = collect_untracked(ctx, ctx.snapshot)
    ctx.changes = tracked + untracked
    ctx.totals["untracked_lines"] = untracked_lines
    ctx.totals["delta_lines"] = count_delta_lines(ctx)
    ctx.totals["delta_source_files"] = sum(1 for c in ctx.changes if c["kind"] == "source")


def _paths_of(changes, kind):
    return [c["path"] for c in changes if c["kind"] == kind]


def hard_full_reasons(ctx):
    """spec §3.1.6 표 7행을 표 순서로. 하나라도 있으면 full — 이후 단계는 실행하지 않는다."""
    changes, totals = ctx.changes, ctx.totals
    reasons = []
    if not changes:
        reasons.append("변경 파일 없음")
    dep = _paths_of(changes, "dep-config")
    if dep:
        reasons.append("의존성·빌드 설정 변경: " + ", ".join(dep))
    shared = _paths_of(changes, "test-shared")
    if shared:
        reasons.append("테스트 공용 설정·픽스처 변경: " + ", ".join(shared))
    sources = totals.get("delta_source_files", 0)
    if sources > MAX_SOURCE_FILES:
        reasons.append(f"소스 파일 {MAX_SOURCE_FILES}개 초과: {sources}개")
    lines = totals.get("delta_lines", 0)
    if lines > MAX_DELTA_LINES:
        reasons.append(f"변경 {MAX_DELTA_LINES}줄 초과: {lines}줄")
    deleted = [c["path"] for c in changes if c["kind"] == "source" and c["status"] == "D"]
    if deleted:
        reasons.append("소스 파일 삭제·이름 변경: " + ", ".join(deleted))
    if ctx.args.external_inputs_changed:
        reasons.append("외부 입력 변경 선언")
    return reasons


# ---- 프로젝트 스크립트 (spec §3.1.7 (a), D12) ---------------------------------

def _worktree_differs(path, blob):
    """작업 트리 판(일반 파일)이 있고 바이트가 기준 판과 다른가."""
    if not _is_regular(path):
        return False
    try:
        if os.path.getsize(path) != len(blob):
            return True
        with open(path, "rb") as fh:
            return fh.read(len(blob) + 1) != blob
    except OSError:
        return False


def script_in_base(ctx):
    """--base 트리에 스크립트가 일반 파일로 있는가. 작업 트리 판은 어떤 경우에도 실행하지 않는다."""
    listing = git_ok(ctx, ["ls-tree", ctx.base_rev, "--", SCRIPT_REL])
    line = listing.decode("utf-8", "surrogateescape").strip()
    if not line:
        if os.path.lexists(os.path.join(ctx.root, SCRIPT_REL)):
            ctx.reasons.append("프로젝트 스크립트가 기준(--base)에 없음 — 건너뜀")
        return False
    if line.split(None, 1)[0] not in ("100644", "100755"):
        ctx.reasons.append("프로젝트 스크립트 거부 — 기준 판이 일반 파일이 아님")
        return False
    return True


class UnsafeArchive(Exception):
    """기준 트리 아카이브에 트리 밖을 가리키는 항목이 있음."""


def _outside(rel):
    """정규화한 상대 경로가 트리 밖(절대 경로·`..`)인가."""
    if not rel or os.path.isabs(rel) or rel.startswith(("/", "\\")):
        return True
    norm = os.path.normpath(rel)
    return norm == ".." or norm.startswith(("../", "/"))


def _via_symlink(rel, links):
    """rel 을 앞에서부터 따라갈 때 중간에 다른 심볼릭 링크 항목을 지나는가(링크 사슬 탈출 차단)."""
    stack = []
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    for index, part in enumerate(parts):
        if part == "..":
            if stack:
                stack.pop()
            continue
        stack.append(part)
        if index < len(parts) - 1 and "/".join(stack) in links:
            return True
    return False


def _check_member(member, links):
    """경로 탈출·심볼릭 링크 탈출·일반 파일/디렉터리/링크 외 항목을 거부한다."""
    if _outside(member.name):
        raise UnsafeArchive(member.name)
    if member.issym():
        target = os.path.join(os.path.dirname(member.name), member.linkname)
        if os.path.isabs(member.linkname) or _outside(target) or _via_symlink(target, links):
            raise UnsafeArchive(member.name)
    elif not (member.isreg() or member.isdir()):
        raise UnsafeArchive(member.name)


def _safe_extract(ctx, tar_path, dest):
    """tar 를 항목마다 검사하며 dest 아래로 푼다. 링크 확인은 쓰기 전에 끝낸다."""
    kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
    with tarfile.open(tar_path, mode="r:") as tar:
        members = tar.getmembers()
        links = {os.path.normpath(m.name) for m in members if m.issym()}
        for member in members:
            _check_member(member, links)
        for member in members:
            if ctx.deadline.expired():
                raise DeadlineExceeded()
            tar.extract(member, dest, set_attrs=member.isreg(), **kwargs)


def extract_base_tree(ctx, workdir):
    """--base 트리 전체를 workdir/tree 로 꺼낸다(저장소 밖). → 꺼낸 트리 경로."""
    tar_path = os.path.join(workdir, "base.tar")
    tree = os.path.join(workdir, "tree")
    os.mkdir(tree, 0o700)
    git_ok(ctx, ["archive", "--format=tar", f"--output={tar_path}", ctx.base_rev])
    try:
        _safe_extract(ctx, tar_path, tree)
    finally:
        _unlink_quiet(tar_path)
    return tree


def _chmod_quiet(path):
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _restore_dir_perms(path):
    """최상위부터 디렉터리 권한을 0700 으로 되돌린다. 하위 디렉터리는 진입 전에 복원, 링크는 따라가지 않는다."""
    stack = [path]
    while stack:
        top = stack.pop()
        _chmod_quiet(top)
        try:
            entries = list(os.scandir(top))
        except OSError:
            continue
        stack.extend(e.path for e in entries if e.is_dir(follow_symlinks=False))


def _rmtree_quiet(path):
    """임시 디렉터리 삭제. 스크립트가 권한을 바꿨어도 복원 후 지우고, 한 번 더 실패하면 경고 1줄."""
    for _attempt in range(2):
        _restore_dir_perms(path)
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.lexists(path):
            return
    sys.stderr.write(f"rein-affected-tests: 경고 — 임시 디렉터리를 지우지 못함: {path}\n")


def _valid_test_path(root, item):
    if not isinstance(item, str) or not item or os.path.isabs(item):
        return False
    if ".." in item.replace("\\", "/").split("/"):
        return False
    return os.path.isfile(os.path.join(root, item))


def validate_script_output(ctx, raw, truncated):
    """(a) 출력 검증 — 통과하면 (tests, command), 아니면 None."""
    if truncated:
        return None
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        return None
    if not isinstance(obj, dict):
        return None
    tests, command = obj.get("tests"), obj.get("command")
    if not isinstance(tests, list) or not tests:
        return None
    if not isinstance(command, str) or not command or len(command) > SCRIPT_COMMAND_MAX:
        return None
    if not all(_valid_test_path(ctx.root, item) for item in tests):
        return None
    return tests, command


def _script_verdict(ctx, res):
    if res.timed_out:
        ctx.reasons.append("프로젝트 스크립트 시간 초과 — 다음 단계로")
        return None
    if res.rc == 3:
        ctx.reasons.append("프로젝트 스크립트가 전체 실행을 요구")
        return make_full(ctx)
    if res.rc != 0:
        tail = _tail_lines(res.err, STDERR_TAIL_LINES)
        detail = (": " + " | ".join(tail)) if tail else ""
        ctx.reasons.append(f"프로젝트 스크립트 실패(rc={res.rc}) — 다음 단계로{detail}")
        return None
    picked = validate_script_output(ctx, res.out, res.out_truncated)
    if picked is None:
        ctx.reasons.append("프로젝트 스크립트 출력 형식 오류 — 다음 단계로")
        return None
    return make_result(ctx, "project-script", picked)


def _script_env(ctx):
    """셸 시작 시 코드를 끌어올 수 있는 변수(BASH_ENV·ENV·CDPATH·내보낸 함수)를 뺀 환경."""
    env = {
        key: value for key, value in os.environ.items()
        if key not in SCRIPT_ENV_DROP and not key.startswith("BASH_FUNC_")
    }
    env.update(REIN_AFFECTED_BASE=ctx.base, REIN_AFFECTED_ROOT=ctx.root, REIN_AFFECTED_TARGET=ctx.root)
    return env


def run_project_script(ctx, tree):
    """기준 트리를 cwd 로 `bash --noprofile --norc <스크립트>` 실행. 현재 저장소는 데이터로만 넘긴다."""
    stdin = "".join(c["path"] + "\n" for c in ctx.changes).encode("utf-8", "surrogateescape")
    limit = env_int("REIN_AFFECTED_TESTS_SCRIPT_TIMEOUT", PROJECT_SCRIPT_TIMEOUT, (1, 9999))
    opts = RunOpts(timeout=ctx.deadline.cap(limit), stdin=stdin, env=_script_env(ctx))
    argv = ["bash", "--noprofile", "--norc", os.path.join(tree, SCRIPT_REL)]
    try:
        res = run(argv, tree, opts)
    except OSError as exc:
        ctx.reasons.append(f"프로젝트 스크립트 실패(rc=127) — 다음 단계로: {exc}")
        return None
    if ctx.deadline.expired():
        raise DeadlineExceeded()
    return _script_verdict(ctx, res)


def _note_changed_script(ctx, tree):
    try:
        with open(os.path.join(tree, SCRIPT_REL), "rb") as fh:
            blob = fh.read()
    except OSError:
        return
    if _worktree_differs(os.path.join(ctx.root, SCRIPT_REL), blob):
        ctx.reasons.append("프로젝트 스크립트가 기준 이후 바뀜 — 기준 판으로 실행")


def _run_in_base_tree(ctx, workdir):
    try:
        tree = extract_base_tree(ctx, workdir)
    except UnsafeArchive as exc:
        ctx.reasons.append(f"프로젝트 스크립트 거부 — 기준 트리에 트리 밖을 가리키는 항목: {exc}")
        return None
    except (OSError, tarfile.TarError) as exc:
        ctx.reasons.append(f"프로젝트 스크립트 실패(기준 트리 추출 불가: {exc}) — 다음 단계로")
        return None
    _note_changed_script(ctx, tree)
    return run_project_script(ctx, tree)


def project_script_step(ctx):
    """판정 순서 (ii) — 결과(채택·full) 또는 None(다음 단계). 기준 트리는 실행 후 반드시 삭제."""
    if not script_in_base(ctx):
        return None
    if any("\n" in c["path"] for c in ctx.changes):
        ctx.reasons.append("프로젝트 스크립트 건너뜀 — 경로에 줄바꿈")
        return None
    try:
        workdir = tempfile.mkdtemp(prefix="rein-affected-base-")
    except OSError as exc:
        ctx.reasons.append(f"프로젝트 스크립트 실패(임시 디렉터리 생성 불가: {exc}) — 다음 단계로")
        return None
    try:
        return _run_in_base_tree(ctx, workdir)
    finally:
        _rmtree_quiet(workdir)


# ---- 스택 판정 (spec §3.1.7 (b0)) --------------------------------------------

def _ext_stack(path):
    if path.endswith(PY_EXTS):
        return "python"
    if path.endswith(JS_EXTS):
        return "js"
    return "other"


def _stack_changes(ctx, kinds):
    return [c for c in ctx.changes if c["kind"] in kinds and _ext_stack(c["path"]) == ctx.stack]


def _is_deleted(change):
    return change["status"] in ("D", "?? deleted")


def detect_pytest(root, files):
    """파이썬 스택 지원 판정 — 하나라도 참이면 pytest 스택."""
    if os.path.isfile(os.path.join(root, "pytest.ini")):
        return True
    if any(path.rsplit("/", 1)[-1] == "conftest.py" for path in files):
        return True
    needles = (("pyproject.toml", "pytest"), ("setup.cfg", "[tool:pytest]"), ("tox.ini", "[pytest]"))
    for name, needle in needles:
        text = _read_text(os.path.join(root, name))[1]
        if text and needle in text:
            return True
    for name in _root_matches(root, "requirements*.txt"):
        text = _read_text(os.path.join(root, name))[1]
        if text and "pytest" in text:
            return True
    return False


def source_stack(ctx):
    """판정 순서 (iii) — 스택을 정하면 None, 다중·지원 밖·대상 없음이면 full."""
    picked = [c for c in ctx.changes if c["kind"] in ("source", "test")]
    stacks = {_ext_stack(c["path"]) for c in picked} - {"other"}
    others = [c["path"] for c in picked if _ext_stack(c["path"]) == "other"]
    if len(stacks) > 1:
        reason = "다중 스택 변경"
    elif others:
        reason = "지원 스택 밖: " + ", ".join(others)
    elif not stacks:
        reason = "선택 결과 없음"
    elif stacks == {"python"} and not detect_pytest(ctx.root, repo_files(ctx)):
        reason = "지원 스택 밖: pytest 미감지"
    else:
        ctx.stack = stacks.pop()
        return None
    ctx.reasons.append(reason)
    return make_full(ctx)


# ---- 사용자 정의 테스트 판별 규칙 (D22) --------------------------------------

def _section_has_key(text, headers):
    """INI/TOML 절 머리 headers 안에 줄 머리 python_files·testpaths 키가 있는가."""
    active = False
    for raw in text.splitlines():
        head = INI_COMMENT_RE.split(raw, 1)[0].strip()
        if head.startswith("["):
            active = head in headers
        elif active and DISCOVERY_KEY_RE.match(raw):
            return True
    return False


def _pytest_discovery(root):
    for name, headers in PYTEST_CONFIGS:
        present, text = _read_text(os.path.join(root, name))
        if not present:
            continue
        if text is None or _section_has_key(text, headers):
            return name
    return None


def _load_package(root):
    """(존재 여부, 루트 package.json 객체 또는 None)."""
    present, text = _read_text(os.path.join(root, "package.json"))
    if not present or text is None:
        return present, None
    try:
        return True, json.loads(text)
    except (ValueError, RecursionError):
        return True, None


def _jest_discovery(root):
    for name in _root_matches(root, "jest.config.*"):
        text = _read_text(os.path.join(root, name))[1]
        if text is None or JEST_KEY_RE.search(text):
            return name
    present, pkg = _load_package(root)
    if not present:
        return None
    if not isinstance(pkg, dict):
        return "package.json"
    jest = pkg.get("jest")
    if isinstance(jest, dict) and any(key in jest for key in ("testMatch", "testRegex", "roots")):
        return "package.json"
    return None


def _vitest_discovery(root):
    names = _root_matches(root, "vitest.config.*") + _root_matches(root, "vite.config.*")
    for name in names:
        text = _read_text(os.path.join(root, name))[1]
        if text is None or VITEST_KEY_RE.search(text):
            return name
    return None


def custom_test_discovery(root, stack):
    """테스트 판별 규칙을 설정으로 바꾼 설정 파일 이름, 없으면 None (파싱 못 하면 있음으로)."""
    if stack == "python":
        return _pytest_discovery(root)
    return _jest_discovery(root) or _vitest_discovery(root)


# ---- import 추출 (spec §3.1.7 (d), D20) --------------------------------------

def py_module_names(path):
    """`a/b/c.py` → a.b.c·b.c·c, `__init__.py` 는 패키지 이름, 첫 조각 src 는 뺀 경로도."""
    stem = path[:-3] if path.endswith(".py") else path
    parts = [part for part in stem.split("/") if part]
    if parts and parts[-1] == "__init__":
        parts = parts[:-1]
    names = {".".join(parts[i:]) for i in range(len(parts))}
    if parts and parts[0] == "src":
        rest = parts[1:]
        names |= {".".join(rest[i:]) for i in range(len(rest))}
    return {name for name in names if name}


def _import_module_aliases(tree):
    """`from importlib import import_module [as x]` 로 들여온 이름들."""
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "importlib" and not node.level:
            names.update(a.asname or a.name for a in node.names if a.name == "import_module")
    return names


def _is_dynamic_import(node, aliases):
    func = node.func
    if isinstance(func, ast.Name):
        return func.id == "__import__" or func.id in aliases
    if isinstance(func, ast.Attribute):
        owner = func.value
        return func.attr == "import_module" and isinstance(owner, ast.Name) and owner.id == "importlib"
    return False


def _literal_arg(node):
    """첫 위치 인자가 str 상수면 그 값, 아니면 None(= 동적 import 흔적)."""
    if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
        return node.args[0].value
    return None


def _from_names(node, path):
    """`from P import X` → P 와 P.X. 상대 import 는 파일의 패키지 경로로 절대화."""
    base = node.module or ""
    if node.level:
        pkg = path.split("/")[:-1]
        keep = len(pkg) - (node.level - 1)
        if keep < 0:
            return set()
        base = ".".join(pkg[:keep] + ([base] if base else []))
    names = {base} if base else set()
    for alias in node.names:
        if alias.name != "*":
            names.add(f"{base}.{alias.name}" if base else alias.name)
    return names


def _py_imports(tree, path):
    aliases = _import_module_aliases(tree)
    imports, dynamic = set(), False
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imports.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            imports.update(_from_names(node, path))
        elif isinstance(node, ast.Call) and _is_dynamic_import(node, aliases):
            literal = _literal_arg(node)
            if literal is None:
                dynamic = True
            else:
                imports.add(literal)
    return imports, dynamic


def py_scan(root, path):
    """→ (imports, has_dynamic, parse_ok). ast.parse 는 코드를 실행하지 않는다."""
    data = _read_capped(os.path.join(root, path))
    if data is None:
        return set(), False, False
    try:
        tree = ast.parse(data, filename=path)
    except (SyntaxError, ValueError, RecursionError, MemoryError):
        return set(), False, False
    imports, dynamic = _py_imports(tree, path)
    return imports, dynamic, True


def _js_after_escape(text, i):
    """text[i] = 백슬래시 → 이스케이프 다음 위치. 줄 이음(`\\` + `\r\n` 등)은 종결자 전체를 건너뛴다."""
    for term in JS_LINE_TERMINATORS:
        if text.startswith(term, i + 1):
            return i + 1 + len(term)
    return i + 2


def _js_string_end(text, pos, quote):
    """pos 의 여는 따옴표에 맞는 닫는 따옴표 위치. 백슬래시 이스케이프는 건너뛴다.

    닫히지 않음·창 초과·일반 문자열의 줄바꿈(LF·CR)·템플릿의 `${` → -1 (비리터럴).
    """
    limit = min(len(text), pos + 1 + JS_LITERAL_MAX)
    i = pos + 1
    while i < limit:
        ch = text[i]
        if ch == "\\":
            i = _js_after_escape(text, i)
            continue
        if ch == quote:
            return i
        if quote == "`" and text.startswith("${", i):
            return -1
        if ch in "\r\n" and quote != "`":
            return -1
        i += 1
    return -1


def _js_code_escape(body, i):
    """body[i] 가 `x`·`u` 인 16진 이스케이프 → (문자, 다음 위치). 잘못된 16진·범위 초과 → None."""
    if body[i] == "x":
        digits, nxt = body[i + 1:i + 3], i + 3
        width = 2
    elif body.startswith("{", i + 1):
        close = body.find("}", i + 2)
        if close < 0:
            return None
        digits, nxt, width = body[i + 2:close], close + 1, None
    else:
        digits, nxt = body[i + 1:i + 5], i + 5
        width = 4
    if not digits or (width and len(digits) != width) or any(c not in string.hexdigits for c in digits):
        return None
    code = int(digits, 16)
    return (chr(code), nxt) if code <= 0x10FFFF else None


def _js_escape_at(body, i):
    """body[i] = 백슬래시 다음 위치 → (해석 문자열, 다음 위치). 해석 불가·모호(레거시 8진 등) → None."""
    if i >= len(body):
        return None
    for term in JS_LINE_TERMINATORS:
        if body.startswith(term, i):
            return "", i + len(term)
    ch = body[i]
    if ch == "0" and body[i + 1:i + 2] not in tuple("0123456789"):
        return "\0", i + 1
    if ch in "0123456789":
        return None
    if ch in "xu":
        return _js_code_escape(body, i)
    return JS_SIMPLE_ESCAPES.get(ch, ch), i + 1


def _js_unescape(body):
    """JS 문자열 리터럴 본문을 표준 이스케이프 규칙으로 해석. 해석 불가·모호 → None(비리터럴 취급)."""
    out = []
    i = 0
    while i < len(body):
        if body[i] != "\\":
            out.append(body[i])
            i += 1
            continue
        step = _js_escape_at(body, i + 1)
        if step is None:
            return None
        out.append(step[0])
        i = step[1]
    try:  # `\uD83D\uDE00` 같은 서로게이트 쌍을 한 문자로 합친다 — 짝 없는 서로게이트는 해석 불가
        return "".join(out).encode("utf-16", "surrogatepass").decode("utf-16")
    except UnicodeError:
        return None


def _js_literal_arg(text, pos):
    """`require(`·`import(` 다음 첫 인자가 리터럴 단독이면 그 문자열, 아니면 None(흔적).

    리터럴 단독 = 이스케이프를 고려해 실제로 닫힌 따옴표 문자열(또는 인터폴레이션 없는 템플릿)
    뒤에 공백만 있고 곧바로 `)`·`,`. `"./x/" + name` 같은 결합·그 밖의 식은 비리터럴로 본다 (D20).
    """
    quote = text[pos:pos + 1]
    if quote not in ("'", '"', "`"):
        return None
    end = _js_string_end(text, pos, quote)
    if end < 0 or not JS_ARG_END_RE.match(text, end + 1):
        return None
    return _js_unescape(text[pos + 1:end])


def js_scan(root, path):
    """→ (imports, has_dynamic, parse_ok). 정규식으로 읽으므로 JS 구문 오류는 감지하지 않는다."""
    data = _read_capped(os.path.join(root, path))
    if data is None:
        return set(), False, False
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return set(), False, False
    specs = set()
    for match in JS_IMPORT_RE.finditer(text):
        specs.add(match.group(2) if match.group(2) is not None else match.group(4))
    dynamic = False
    for match in JS_DYN_RE.finditer(text):
        literal = _js_literal_arg(text, match.end())
        if literal is None:
            dynamic = True
        else:
            specs.add(literal)
    return specs, dynamic, True


def resolve_js_spec(src, spec, known):
    """`./`·`../` 로 시작하는 경로만 — 그대로 / +확장자 / /index+확장자 순 첫 존재 파일."""
    if not spec.startswith(("./", "../")):
        return None
    base = os.path.normpath(os.path.join(os.path.dirname(src), spec))
    if base == ".." or base.startswith(("../", "/")):
        return None
    candidates = [base] + [base + ext for ext in JS_EXTS] + [f"{base}/index{ext}" for ext in JS_EXTS]
    for candidate in candidates:
        if candidate in known:
            return candidate
    return None


def _py_resolver(known):
    """import 이름 N → 모듈 이름 M 이 N == M 또는 N.startswith(M + ".") 인 파일들."""
    modmap = {}
    for path in known:
        for name in py_module_names(path):
            modmap.setdefault(name, set()).add(path)

    def resolve(_src, name):
        parts = name.split(".")
        hits = set()
        for i in range(len(parts), 0, -1):
            hits |= modmap.get(".".join(parts[:i]), set())
        return hits

    return resolve


def _js_resolver(known):
    def resolve(src, spec):
        hit = resolve_js_spec(src, spec, known)
        return {hit} if hit else set()

    return resolve


# ---- 그래프·흔적 집합 (spec §3.1.7 (b0)·(d), D20) -----------------------------

def _link_graph(ctx, stack, scans):
    """파일 단위 의존 그래프 deps·역방향 rdeps·흔적 집합·테스트 집합."""
    known = set(scans) | {c["path"] for c in _stack_changes(ctx, ("source", "test"))}
    resolve = _py_resolver(known) if stack == "python" else _js_resolver(known)
    graph = Graph()
    for path, (imports, dynamic) in scans.items():
        deps = set()
        for spec in imports:
            deps |= resolve(path, spec)
        deps.discard(path)
        graph.deps[path] = deps
        for dep in deps:
            graph.rdeps.setdefault(dep, set()).add(path)
        if dynamic:
            graph.dynamic.add(path)
        if classify(path) == "test":
            graph.tests.add(path)
    return graph


def build_graph(ctx, stack):
    """스택 확장자 저장소 파일 전부를 훑는다. 미완성(상한·파싱 실패)이면 error 를 채운다."""
    exts = PY_EXTS if stack == "python" else JS_EXTS
    files = [path for path in repo_files(ctx) if path.endswith(exts)]
    limit = env_int("REIN_AFFECTED_TESTS_MAX_SCAN", MAX_SCAN_FILES, (1, 99999))
    if len(files) > limit:
        return Graph(error=f"검색 대상 파일 과다: {len(files)}개 > {limit}개")
    scan = py_scan if stack == "python" else js_scan
    scans = {}
    for path in files:
        if ctx.deadline.expired():
            raise DeadlineExceeded()
        if not os.path.isfile(os.path.join(ctx.root, path)):
            continue
        imports, dynamic, parse_ok = scan(ctx.root, path)
        if not parse_ok:
            return Graph(error=f"파싱 실패로 흔적 집합 미완성: {path}")
        scans[path] = (imports, dynamic)
    return _link_graph(ctx, stack, scans)


def get_graph(ctx):
    if ctx.graph is None:
        ctx.graph = build_graph(ctx, ctx.stack)
    return ctx.graph


def dynamic_extra(graph):
    """dyn_extra = (흔적 테스트) ∪ (흔적 소스에 역방향 전이 폐쇄로 닿는 모든 테스트)."""
    dyn_tests = graph.dynamic & graph.tests
    seen = set()
    queue = list(graph.dynamic - graph.tests)
    while queue:
        node = queue.pop()
        for importer in graph.rdeps.get(node, ()):
            if importer not in seen:
                seen.add(importer)
                queue.append(importer)
    return dyn_tests | (seen & graph.tests)


def graph_mapping(graph, sources):
    """소스마다 (1단계 직접 테스트, 1·2단계 대상). 중계 모듈 = 비테스트·비 conftest 의 importer."""
    per_source, level1 = {}, {}
    for src in sources:
        importers = graph.rdeps.get(src, set())
        direct = importers & graph.tests
        relays = {
            r for r in importers - graph.tests
            if r != src and r.rsplit("/", 1)[-1] != "conftest.py"
        }
        second = set().union(*(graph.rdeps.get(r, set()) for r in relays)) & graph.tests
        level1[src] = direct
        per_source[src] = direct | second
    return per_source, level1


def _graph_targets(ctx, graph):
    """→ (대상 합집합, 소스별 대상, 소스별 1단계). 대상에는 바뀐 테스트(삭제 제외)가 늘 들어간다."""
    sources = [c["path"] for c in _stack_changes(ctx, ("source",))]
    tests = {c["path"] for c in _stack_changes(ctx, ("test",)) if not _is_deleted(c)}
    per_source, level1 = graph_mapping(graph, sources)
    return tests.union(*per_source.values()), per_source, level1


def _graph_blocker(ctx):
    """jest·vitest·import-search 진입 전 — 판별 규칙(D22) 또는 그래프 미완성 사유."""
    found = custom_test_discovery(ctx.root, ctx.stack)
    if found:
        return f"사용자 정의 테스트 판별 규칙: {found}"
    return get_graph(ctx).error


# ---- 정밀 도구 감지 (spec §3.1.7 (b)) ----------------------------------------

def js_test_script(root):
    pkg = _load_package(root)[1]
    scripts = pkg.get("scripts") if isinstance(pkg, dict) else None
    test = scripts.get("test") if isinstance(scripts, dict) else None
    return test if isinstance(test, str) and test.strip() else None


def detect_js_runner(root):
    """의존성 선언 그리고 node_modules/.bin/<이름> 존재. 둘 다면 scripts.test 로, 판단 불가면 vitest."""
    pkg = _load_package(root)[1]
    if not isinstance(pkg, dict):
        return None
    declared = set()
    for key in ("dependencies", "devDependencies"):
        section = pkg.get(key)
        if isinstance(section, dict):
            declared.update(section)
    found = [
        name for name in ("jest", "vitest")
        if name in declared and os.path.exists(os.path.join(root, "node_modules", ".bin", name))
    ]
    if len(found) < 2:
        return found[0] if found else None
    script = js_test_script(root) or ""
    if "jest" in script and "vitest" not in script:
        return "jest"
    return "vitest"


def _venv_python():
    return os.path.join(os.environ.get("VIRTUAL_ENV", ""), "bin", "python")


def detect_py_manager(root):
    """poetry → uv → pip(venv) → None. pyvenv.cfg 요건은 시스템 파이썬 오인 방지."""
    if _is_regular(os.path.join(root, "poetry.lock")) and shutil.which("poetry"):
        return "poetry"
    if _is_regular(os.path.join(root, "uv.lock")) and shutil.which("uv"):
        return "uv"
    venv = os.environ.get("VIRTUAL_ENV", "")
    if venv and _is_regular(os.path.join(venv, "pyvenv.cfg")) and os.path.exists(_venv_python()):
        return "pip"
    return None


def get_mgr(ctx):
    if ctx.mgr == MGR_UNSET:
        ctx.mgr = detect_py_manager(ctx.root)
    return ctx.mgr


def pytest_prefix(mgr):
    if mgr == "poetry":
        return "poetry run pytest"
    if mgr == "uv":
        return "uv run pytest"
    if mgr == "pip":
        return shlex.join([_venv_python(), "-m", "pytest"])
    return "python3 -m pytest"


def _file_has_line(path, wanted):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return any(line.strip() == wanted for line in fh)
    except OSError:
        return False


def testmon_installed(ctx, mgr):
    """poetry·uv 는 잠금 파일 텍스트(실행 없음), pip·없음은 PROBE_CODE probe(-I -c)."""
    if mgr in ("poetry", "uv"):
        lock = os.path.join(ctx.root, "poetry.lock" if mgr == "poetry" else "uv.lock")
        return _file_has_line(lock, 'name = "pytest-testmon"')
    python = _venv_python() if mgr == "pip" else shutil.which("python3")
    if not python:
        return False
    opts = RunOpts(timeout=ctx.deadline.cap(PROBE_TIMEOUT))
    try:
        res = run([python, "-I", "-c", PROBE_CODE], ctx.root, opts)
    except OSError:
        return False
    return not res.timed_out and res.rc == 0


def _testmon_ready(ctx, mgr):
    if ctx.testmon is None:
        ctx.testmon = testmon_installed(ctx, mgr)
    return ctx.testmon


# ---- testmon 자동 설치 (spec §3.1.7 (c), §4.1·§4.3) ---------------------------

def _install_info(status, mgr, message):
    attempted = status in ("installed", "failed")
    return {"attempted": attempted, "status": status, "manager": mgr, "message": message}


def _state_record(status, mgr, reason):
    at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "schema": 1, "tool": "pytest-testmon", "status": status,
        "manager": mgr, "reason": reason, "at": at,
    }


def policy_auto_install(ctx):
    """정책 로더 조회 — stdout 이 정확히 `true` 일 때만 켜짐. 로더 경고 줄은 reasons 로."""
    loader = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rein-policy-loader.py")
    argv = [sys.executable or "python3", loader, "--test-selection-auto-install"]
    try:
        res = run(argv, ctx.root, RunOpts(timeout=ctx.deadline.cap(PROBE_TIMEOUT)))
    except OSError:
        return False
    for line in res.err.decode("utf-8", "replace").splitlines():
        if "warning:" in line:
            ctx.reasons.append(_clean(line).strip())
    if res.timed_out or res.rc != 0:
        return False
    return res.out.decode("utf-8", "replace").strip() == "true"


def state_path_problem(root):
    """네 상태 경로 중 심볼릭 링크(또는 디렉터리가 아닌 디렉터리 자리)인 첫 경로, 없으면 None."""
    for rel in (".rein", ".rein/state"):
        path = os.path.join(root, rel)
        if os.path.islink(path) or (os.path.lexists(path) and not os.path.isdir(path)):
            return rel
    for rel in (STATE_REL, LOCK_REL):
        if os.path.islink(os.path.join(root, rel)):
            return rel
    return None


def state_paths_safe(root):
    return state_path_problem(root) is None


def read_state(root):
    """상태 기록. 없으면 None, 손상(JSON 아님·schema != 1)이면 빈 dict(= 존재, 재시도 안 함)."""
    path = os.path.join(root, STATE_REL)
    if not os.path.lexists(path):
        return None
    try:
        with open(path, "rb") as fh:
            record = json.loads(fh.read(MAX_PARSE_BYTES + 1).decode("utf-8"))
    except (OSError, ValueError, RecursionError):
        return {}
    if not isinstance(record, dict) or record.get("schema") != 1:
        return {}
    return record


def _recorded_message(record):
    status = record.get("status", "손상") if record else "손상"
    reason = record.get("reason", "형식 오류") if record else "형식 오류"
    return f"기록된 상태: {status} ({reason}) — 지우면 다시 시도한다: {STATE_REL}"


def _atomic_write(target, data, mode_src):
    """같은 디렉터리 임시 파일 + fsync + (권한 복사) + 대상 재 lstat + os.replace."""
    prefix = "." + os.path.basename(target).rsplit(".", 1)[0] + "."
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=prefix, suffix=".tmp")
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if mode_src:
            shutil.copymode(mode_src, tmp)
        if os.path.islink(target):
            raise OSError("대상이 심볼릭 링크")
        os.replace(tmp, target)
        return True
    except OSError:
        _unlink_quiet(tmp)
        return False


def write_state(root, record):
    """상태 기록 원자적 쓰기. 경로 안전 검사를 다시 하고, 실패하면 False."""
    try:
        os.makedirs(os.path.join(root, ".rein", "state"), exist_ok=True)
    except OSError:
        return False
    if not state_paths_safe(root):
        return False
    data = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
    return _atomic_write(os.path.join(root, STATE_REL), data, None)


def acquire_lock(root):
    """O_NOFOLLOW 잠금 파일 + flock(LOCK_EX | LOCK_NB). 경합이면 None. fd 는 프로세스 끝까지 유지."""
    os.makedirs(os.path.join(root, ".rein", "state"), exist_ok=True)
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    fd = os.open(os.path.join(root, LOCK_REL), flags, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def install_argv(mgr):
    """설치 argv — 모든 요소가 상수이거나 which/VIRTUAL_ENV 경로. 인덱스·URL 인자 없음."""
    if mgr == "poetry":
        return [shutil.which("poetry") or "poetry", "add", "--group", "dev", INSTALL_SPEC]
    if mgr == "uv":
        return [shutil.which("uv") or "uv", "add", "--dev", INSTALL_SPEC]
    return [_venv_python(), "-m", "pip", "install", INSTALL_SPEC]


def update_requirements_dev(root):
    """pip 성공 시 requirements-dev.txt 에 한 줄 추가(일반 파일·비링크일 때만). 반환: 메시지 덧말."""
    path = os.path.join(root, "requirements-dev.txt")
    if os.path.islink(path):
        return "requirements-dev.txt 가 심볼릭 링크 — 갱신하지 않음"
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", "surrogateescape")
    except OSError:
        return "requirements-dev.txt 읽기 실패 — 갱신하지 않음"
    if TESTMON_REQ_RE.search(text):
        return ""
    sep = "" if not text or text.endswith("\n") else "\n"
    data = (text + sep + INSTALL_SPEC + "\n").encode("utf-8", "surrogateescape")
    return "" if _atomic_write(path, data, path) else "requirements-dev.txt 갱신 실패"


def _run_install(ctx, mgr):
    """설치 실행 → (status, reason, message). shell 없음, stdin=DEVNULL, 기한으로 깎인 시간 제한."""
    limit = env_int("REIN_AFFECTED_TESTS_INSTALL_TIMEOUT", INSTALL_TIMEOUT, (1, 9999))
    timeout = ctx.deadline.cap(limit)
    try:
        res = run(install_argv(mgr), ctx.root, RunOpts(timeout=timeout))
    except OSError as exc:
        return "failed", "oserror", _clean(str(exc))
    message = " | ".join(_tail_lines(res.out + b"\n" + res.err, INSTALL_TAIL_LINES))
    if res.timed_out:
        return "failed", f"timeout {round(timeout)}s", message
    if res.rc != 0:
        return "failed", f"rc={res.rc}", message
    return "installed", "rc=0", message


def _join_note(message, note):
    if not note:
        return message
    return f"{message} — {note}" if message else note


def _install_locked(ctx, mgr):
    """판정 표 6~8행 — 잠금을 쥔 뒤 기록 재확인, 관리자 없음, 설치 실행."""
    record = read_state(ctx.root)
    if record is not None:
        ctx.install = _install_info("already-recorded", None, _recorded_message(record))
        return None
    if mgr is None:
        saved = write_state(ctx.root, _state_record("skipped", None, "no-project-env"))
        message = _join_note(SKIPPED_MESSAGE, "" if saved else "상태 기록 실패")
        ctx.install = _install_info("skipped", None, message)
        return None
    status, reason, message = _run_install(ctx, mgr)
    if status == "installed" and mgr == "pip":
        message = _join_note(message, update_requirements_dev(ctx.root))
    saved = write_state(ctx.root, _state_record(status, mgr, reason))
    ctx.install = _install_info(status, mgr, _join_note(message, "" if saved else "상태 기록 실패"))
    if status != "installed":
        return None
    ctx.testmon = True
    ctx.reasons.append(INSTALLED_REASON)
    return make_result(ctx, "full", ([], pytest_prefix(mgr) + " --testmon-noselect"))


def maybe_install(ctx, mgr):
    """판정 표 1~5행을 표 순서대로. 결과(installed → full) 또는 None(import 검색으로 하강)."""
    if ctx.args.no_install:
        ctx.install = _install_info("disabled", None, "--no-install")
        return None
    if not policy_auto_install(ctx):
        ctx.install = _install_info("disabled", None, "정책 auto_install_test_tools: false")
        return None
    problem = state_path_problem(ctx.root)
    if problem:
        message = f"상태 경로가 심볼릭 링크이거나 비정상 — 기록·설치 거부: {problem}"
        ctx.install = _install_info("refused", None, message)
        return None
    record = read_state(ctx.root)
    if record is not None:
        ctx.install = _install_info("already-recorded", None, _recorded_message(record))
        return None
    try:
        ctx.lock_fd = acquire_lock(ctx.root)
    except OSError as exc:
        ctx.install = _install_info("refused", None, f"잠금 파일을 열 수 없음: {exc}")
        return None
    if ctx.lock_fd is None:
        ctx.install = _install_info("busy", None, "다른 선택기가 설치 중")
        return None
    return _install_locked(ctx, mgr)


# ---- 선택 단계 (spec §3.1.3 (iv)·(v)) ----------------------------------------

def _dyn_overflow(graph, targets, dyn):
    total = len(graph.tests)
    count = len(targets | dyn)
    if dyn and count > IMPORT_SEARCH_MAX_RATIO * total:
        return f"동적 import 흔적으로 대상 과다: {count}/{total}"
    return None


def _js_tool_command(runner, files, dyn):
    """jest·vitest 명령 — 동적 import 추가분이 있으면 둘째 명령을 && 로 잇는다."""
    extra = sorted(dyn)
    if runner == "jest":
        first = ["node_modules/.bin/jest", "--findRelatedTests", *files]
        second = ["node_modules/.bin/jest", "--runTestsByPath", *extra]
    else:
        first = ["node_modules/.bin/vitest", "related", "--run", *files]
        second = ["node_modules/.bin/vitest", "run", *extra]
    command = shlex.join(first)
    return f"{command} && {shlex.join(second)}" if extra else command


def js_tool_step(ctx):
    """jest·vitest — 판별 규칙·그래프 미완성·절반 근사면 full. 실행 파일은 실행하지 않는다."""
    runner = detect_js_runner(ctx.root)
    if runner is None:
        return None
    blocked = _graph_blocker(ctx)
    if blocked:
        ctx.reasons.append(blocked)
        return make_full(ctx)
    files = sorted(c["path"] for c in _stack_changes(ctx, ("source", "test")) if not _is_deleted(c))
    if not files:
        return None
    targets = _graph_targets(ctx, ctx.graph)[0]
    dyn = dynamic_extra(ctx.graph)
    over = _dyn_overflow(ctx.graph, targets, dyn)
    if over:
        ctx.reasons.append(over)
        return make_full(ctx)
    return make_result(ctx, runner, (sorted(dyn), _js_tool_command(runner, files, dyn)))


def py_tool_step(ctx):
    """testmon — 설치돼 있으면 기록 유무로 채택·full, 없으면 자동 설치. 흔적 스캔은 하지 않는다."""
    mgr = get_mgr(ctx)
    if _testmon_ready(ctx, mgr):
        prefix = pytest_prefix(mgr)
        if _is_regular(os.path.join(ctx.root, ".testmondata")):
            return make_result(ctx, "testmon", ([], prefix + " --testmon"))
        ctx.reasons.append(NO_TESTMON_DATA)
        return make_result(ctx, "full", ([], prefix + " --testmon-noselect"))
    result = maybe_install(ctx, mgr)
    if result is not None:
        return result
    ctx.reasons.append("testmon 미설치 — import 검색으로 선택")
    return None


def tool_step(ctx):
    """판정 순서 (iv)."""
    if ctx.stack == "js":
        return js_tool_step(ctx)
    return py_tool_step(ctx)


def import_search_verdict(ctx, graph):
    """(d) 판정 — 공용 모듈 → 매핑 실패 → 빈 결과 → 절반 초과. 반환 (tests, None) 또는 (None, 사유)."""
    targets, per_source, level1 = _graph_targets(ctx, graph)
    for src in sorted(level1):
        count = len(level1[src])
        if count >= SHARED_MODULE_MIN_TESTS:
            return None, f"공용 모듈 변경(import-search 는 완화 대상 아님): {src} ({count}개 테스트)"
    for src in sorted(per_source):
        if not per_source[src]:
            return None, f"테스트에 매핑되지 않는 소스: {src}"
    dyn = dynamic_extra(graph)
    picked = targets | dyn
    if not picked:
        return None, "선택 결과 없음"
    total = len(graph.tests)
    if len(picked) > IMPORT_SEARCH_MAX_RATIO * total:
        label = "동적 import 흔적으로 대상 과다" if dyn else "대상 테스트가 전체 테스트 파일의 절반 초과"
        return None, f"{label}: {len(picked)}/{total}"
    return sorted(picked), None


def import_search_step(ctx):
    """판정 순서 (v) — 통과하면 import-search 채택, 아니면 full."""
    blocked = _graph_blocker(ctx)
    if blocked:
        ctx.reasons.append(blocked)
        return make_full(ctx)
    tests, reason = import_search_verdict(ctx, ctx.graph)
    if reason:
        ctx.reasons.append(reason)
        return make_full(ctx)
    if ctx.stack == "python":
        command = pytest_prefix(get_mgr(ctx)) + " " + shlex.join(tests)
    elif js_test_script(ctx.root):
        command = shlex.join(["npm", "test", "--", *tests])
    else:
        ctx.reasons.append("지원 스택 밖: JS 테스트 실행기 없음")
        return make_full(ctx)
    return make_result(ctx, "import-search", (tests, command))


# ---- 결과 조립 (spec §3.1.2, D17) --------------------------------------------

def _full_stack(ctx):
    found = {_ext_stack(c["path"]) for c in ctx.changes if c["kind"] in ("source", "test")}
    if found:
        return found.pop() if len(found) == 1 else None
    if detect_pytest(ctx.root, _files_or_empty(ctx)):
        return "python"
    return "js" if js_test_script(ctx.root) else None


def _py_full_command(ctx):
    if not detect_pytest(ctx.root, _files_or_empty(ctx)):
        return ""
    mgr = get_mgr(ctx)
    prefix = pytest_prefix(mgr)
    return prefix + " --testmon-noselect" if _testmon_ready(ctx, mgr) else prefix


def full_command(ctx):
    """full 의 command. testmon 환경이면 --testmon-noselect (full 이 --testmon 으로 끝나는 일은 없다)."""
    try:
        stack = _full_stack(ctx)
        if stack == "python":
            return _py_full_command(ctx)
        if stack == "js" and js_test_script(ctx.root):
            return "npm test"
    except (DeadlineExceeded, GitError, OSError):
        pass
    return ""


def make_result(ctx, method, picked):
    """§3.1.2 의 키 12개를 정확히 만든다. picked = (tests, command)."""
    tests, command = picked
    return {
        "schema": 1,
        "base": ctx.base,
        "method": method,
        "tests": [] if method == "full" else sorted(set(tests)),
        "command": command,
        "full_run_required": method == "full",
        "reasons": list(ctx.reasons),
        "install": ctx.install,
        "changed": [{"path": c["path"], "status": c["status"], "kind": c["kind"]} for c in ctx.changes],
        "delta_lines": ctx.totals.get("delta_lines", 0),
        "delta_source_files": ctx.totals.get("delta_source_files", 0),
        "untracked_scope": list(ctx.args.untracked_scope or []),
    }


def make_full(ctx):
    return make_result(ctx, "full", ([], full_command(ctx)))


def render_json(result):
    return json.dumps(result, ensure_ascii=False) + "\n"


def _text_tests(result):
    method, tests = result["method"], result["tests"]
    if method == "full":
        return ["대상 테스트: 전체"]
    if method == "testmon":
        return ["대상 테스트: 도구가 실행 시 선택"]
    if method in ("jest", "vitest"):
        head = f"대상 테스트: 도구가 실행 시 선택 + 동적 import 추가 ({len(tests)}):"
    else:
        head = f"대상 테스트 ({len(tests)}):"
    return [head] + [f"  {test}" for test in tests]


def _text_install(info):
    if info is None:
        return []
    message = info.get("message") or ""
    lines = [f"정밀 도구 설치: {info['status']}" + (f" — {message}" if message else "")]
    if info["status"] == "installed":
        lines.append(INSTALL_NOTICE)
    return lines


def render_text(result):
    """§3.1.9 사람용 요약 — 첫 세 줄 고정 순서, 마지막 줄 델타 증거 칸."""
    lines = [
        f"선택 방법: {result['method']}",
        f"전체 실행 필요: {'예' if result['full_run_required'] else '아니오'}",
    ]
    lines += _text_tests(result)
    lines += [f"실행 명령: {result['command']}", f"기준: {result['base']}"]
    lines.append(f"바뀐 파일 ({len(result['changed'])}):")
    lines += [f"  {c['status']} {c['path']} ({c['kind']})" for c in result["changed"]]
    lines.append(f"줄 수: {result['delta_lines']} / 소스 파일: {result['delta_source_files']}")
    lines.append("사유:" if result["reasons"] else "사유: 없음")
    lines += [f"  - {reason}" for reason in result["reasons"]]
    lines += _text_install(result["install"])
    if result["full_run_required"]:
        lines.append(FULL_DELTA_LINE)
    else:
        lines.append(f"델타 증거 칸: selection: {result['method']}")
    return "\n".join(lines) + "\n"


# ---- 지휘 (spec §3.1.3) ------------------------------------------------------

def _select_steps(ctx):
    if ctx.deadline.expired():
        raise DeadlineExceeded()
    if not verify_base(ctx):
        ctx.reasons.append(f"기준 ref 해석 불가: {ctx.base}")
        return make_full(ctx)
    collect_changes(ctx)
    hard = hard_full_reasons(ctx)
    if hard:
        ctx.reasons.extend(hard)
        return make_full(ctx)
    for step in (project_script_step, source_stack, tool_step, import_search_step):
        if ctx.deadline.expired():
            raise DeadlineExceeded()
        result = step(ctx)
        if result is not None:
            return result
    return make_full(ctx)


def select(ctx):
    """판정 순서 지휘. 기한 초과·git 실패는 여기서 full 로 바꾼다."""
    try:
        return _select_steps(ctx)
    except DeadlineExceeded:
        ctx.reasons.append(f"선택기 시간 상한({ctx.deadline.budget}초) 초과 — 남은 단계 생략")
    except GitError as exc:
        ctx.reasons.append(f"git 실행 실패: {exc}")
    return make_full(ctx)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="rein-affected-tests.py",
        description="바뀐 파일에서 돌릴 테스트와 실행 명령을 고른다. "
        "종료 코드 0 = 출력(전체 실행 판정 포함), 1 = 내부 오류, 2 = 인자 오류.",
    )
    parser.add_argument("--base", default="HEAD", metavar="REF", help="비교 기준 (기본 HEAD)")
    parser.add_argument("--format", choices=("text", "json"), default="text", help="출력 형식 (기본 text)")
    parser.add_argument("--no-install", action="store_true", help="정밀 도구 자동 설치를 건너뛴다")
    parser.add_argument(
        "--untracked-scope", action="append", metavar="GLOB",
        help="미추적 파일을 거르는 glob (여러 번 지정 가능, 생략하면 전체)",
    )
    parser.add_argument(
        "--untracked-snapshot", metavar="FILE",
        help="델타 증거 untracked_at_full_run 줄들(또는 none)을 담은 파일",
    )
    parser.add_argument(
        "--external-inputs-changed", action="store_true",
        help="테스트가 읽는 외부 입력이 바뀌었거나 알 수 없음 → 전체 실행",
    )
    parser.add_argument("--root", metavar="DIR", help="저장소 루트 (기본 git 최상위)")
    return parser.parse_args(argv)


def _run_main(args):
    try:
        snapshot = read_snapshot(args.untracked_snapshot) if args.untracked_snapshot else {}
    except SnapshotError as exc:
        sys.stderr.write(f"rein-affected-tests: {exc}\n")
        return 2
    deadline = Deadline(env_int("REIN_AFFECTED_DEADLINE_SEC", SELECTOR_BUDGET, (0, 9999)))
    root = resolve_root(args.root)
    fallback = os.path.abspath(args.root or ".")
    ctx = Ctx(root=root or fallback, base=args.base, args=args, deadline=deadline, snapshot=snapshot)
    if root is None:
        ctx.reasons.append("git 저장소 아님")
        result = make_result(ctx, "full", ([], ""))
    else:
        result = select(ctx)
    emit(render_json(result) if args.format == "json" else render_text(result))
    return 0


def main(argv):
    args = parse_args(argv)
    try:
        return _run_main(args)
    except Exception as exc:  # 최상위 안전망 — 예상하지 못한 내부 오류는 종료 코드 1
        sys.stderr.write(f"rein-affected-tests: 내부 오류: {type(exc).__name__}: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
