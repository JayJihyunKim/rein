"""`rein doctor` — 설정·policy·storage 상태 진단 (plan Task 4.7, spec §5.2/§3.1).

spec §3.1 패키지 구조표가 `cli/` 아래 이 모듈을 명시한다("doctor,
explain"). spec §5.2 "미선언 프로젝트 처리(확정)" 원문: "기본 Policy
세트의 tests_passed 요구 조항은 testing.configured fact 가 true 일 때만
활성화된다(온보딩 마찰 방지 — 미선언 프로젝트의 push 를 막지 않고
**doctor 가 설정을 안내**)." 이 모듈이 그 안내를 구현한다.

세 축을 진단한다 (모두 기존 로더 재사용 — 재구현 금지):
1. **설정**: `.rein/policy/testing.yaml` (plan D1 확정 위치) 존재·파싱
   가능 여부. `rein.capabilities.testing.capability.load_testing_config`
   를 그대로 호출한다 — 이 모듈은 파일이 없다/파싱 실패다 를 스스로
   판정하지 않고 그 함수의 반환/예외를 그대로 옮긴다.
2. **policy**: `rein.kernel.policy.load_policies` 가 실제 평가 경로
   (`rein/cli/__init__.py::run_event`)에서 참조하는 것과 동일한
   `REIN_POLICY_DIR` 환경변수를 읽는다 — doctor 가 보고하는 policy
   상태는 "실제로 평가에 쓰일 policy 집합"과 항상 같은 소스를 봐야
   진단이 신뢰된다 (다른 경로를 따로 만들면 doctor 와 실제 평가가
   드리프트할 위험).
3. **storage**: `rein.platform.storage.local.LocalStateRoot` +
   `rein.platform.sqlite.store.SqliteStore` 로 state 디렉토리·
   ledger/evidence 정본 파일·sqlite 캐시의 상태를 읽는다.

읽기 전용 계약: 이 모듈은 존재하지 않는 storage 파일/디렉토리를
**새로 만들지 않는다** — sqlite 열림 검사는 db 파일이 이미 존재할
때만 시도한다. 프로젝트가 아직 한 번도 평가를 거치지 않았다면
doctor 실행 자체가 `.rein/state/` 를 생성하는 부작용을 만들어서는
안 된다(진단 도구가 진단 대상을 만들어내면 "무엇이 실제 상태인가"를
알 수 없게 된다).

## sqlite 검사는 read-only URI 로만 연다 (2026-08-11 사이클 C 재리뷰 4회차 Medium 1)

이전 구현은 여기서 `platform.sqlite.store.SqliteStore.open(db_path)`
를 호출했다. 그런데 그 생성자(`SqliteStore.__init__`)는 무조건
`_ensure_schema()` 를 실행해 5개 테이블을 `CREATE TABLE IF NOT EXISTS`
로 만든다 — "이미 존재하는 파일을 여는 것"이라도 그 파일이 스키마가
없는 상태(예: 0바이트)였다면 doctor 호출 하나로 스키마가 새로 생긴다
(리뷰어 실증: 0바이트 db 가 doctor 실행 후 45KB·5테이블 db 로 바뀌었다
— "읽기 전용 진단"이 실제로는 쓰기였다). `SqliteStore` 자체는 evaluator
가 쓰는 실제 캐시 계층 진입점이라 스키마 보장 책임이 있는 게 맞다 —
문제는 doctor 가 그 쓰기 경로를 진단 목적으로 빌려 쓴 것이다.

그래서 doctor 는 `SqliteStore` 를 전혀 쓰지 않는다. 대신 sqlite3 표준
read-only URI(`file:<path>?mode=ro`, stdlib `sqlite3.connect(uri,
uri=True)`)로 직접 연결해 `PRAGMA integrity_check` 만 실행한다 — 이
경로는 어떤 스키마도 만들지 않고 어떤 PRAGMA 도 파일에 쓰지 않는다
(WAL/synchronous PRAGMA 설정도 시도하지 않는다 — 그 자체가 쓰기다).
실측 확인(before/after 파일 바이트·해시 동일, 세 케이스 — 빈 파일/
정상 초기화된 db/손상된 파일 전부): 코드 리뷰 시점에 재현해 회귀
테스트로 고정했다. 부재 DB 는 "미생성" 그대로 보고한다(연결을 시도조차
하지 않는다 — `sqlite3.connect` 의 `mode=ro` 는 파일이 없으면 새로
만들지 않고 그냥 실패하지만, 애초에 실패를 유도할 이유가 없어 존재
검사를 먼저 한다).
"""
import os
import sqlite3
import urllib.parse

from rein.capabilities.testing.capability import (
    CONFIG_RELATIVE_PATH as TESTING_CONFIG_RELATIVE_PATH,
    TestingConfigError,
    load_testing_config,
)
from rein.kernel.policy import PolicyLoadError, load_policies
from rein.platform.storage.local import LocalStateRoot

# sqlite3 read-only URI 템플릿 — RFC 3986 문법상 안전하지 않은 문자
# (공백·`?`·`#` 등)는 연결 전에 반드시 percent-encode 해야 한다
# (`urllib.parse.quote`, 기본 safe="/" 로 경로 구분자는 보존).
_READ_ONLY_URI_TEMPLATE = "file:{}?mode=ro"
_INTEGRITY_CHECK_OK = "ok"

# run_event 와 동일한 환경변수 — cli/__init__.py 의 ENV_POLICY_DIR 과
# 값이 어긋나면 doctor 가 실제 평가와 다른 policy 상태를 보고하게 되므로
# 문자열을 이 모듈에서 다시 정의하지 않고 상수만 나란히 둔다(순환
# import 방지 — rein.cli.__init__ 은 이 모듈을 import 하지 않는다).
ENV_POLICY_DIR = "REIN_POLICY_DIR"

_TESTING_GUIDANCE_TEMPLATE = (
    "테스트 검증(tests_passed)이 아직 설정되지 않았습니다. {path} 파일을 "
    "만들어 테스트 명령을 선언하면 push/release 단계의 tests_passed 요구가 "
    "활성화됩니다. 그 전까지는 차단되지 않습니다 (spec §5.2 — 미설정 "
    "프로젝트의 온보딩 마찰 방지 확정 방향)."
)
_TESTING_GUIDANCE_ERROR_TEMPLATE = (
    "{path} 파일이 있지만 읽는 데 실패했습니다: {error}. 스키마를 spec "
    "§5.2 형식(testing.commands[].{{id,run,tag}})에 맞춰 수정하세요."
)


def _config_report(project_root):
    """testing.yaml 상태 — load_testing_config 반환/예외를 그대로 반영."""
    path = os.path.join(project_root, TESTING_CONFIG_RELATIVE_PATH)
    report = {
        "path": path,
        "configured": False,
        "commands": None,
        "error": None,
        "guidance": None,
    }
    try:
        config = load_testing_config(path)
    except TestingConfigError as error:
        report["error"] = str(error)
        report["guidance"] = _TESTING_GUIDANCE_ERROR_TEMPLATE.format(
            path=path, error=error
        )
        return report
    if config is None:
        # 파일 부재 — "미설정" (load_testing_config 의 None 계약)
        report["guidance"] = _TESTING_GUIDANCE_TEMPLATE.format(path=path)
        return report
    report["configured"] = True
    report["commands"] = len(config.commands)
    return report


def _policy_report():
    """policy 디렉토리 상태 — 평가 경로가 쓰는 REIN_POLICY_DIR 그대로."""
    policy_dir = os.environ.get(ENV_POLICY_DIR)
    report = {
        "dir": policy_dir,
        "count": 0,
        "loaded": False,
        "error": None,
    }
    try:
        policies = load_policies(policy_dir)
    except PolicyLoadError as error:
        report["error"] = str(error)
        return report
    report["loaded"] = True
    report["count"] = len(policies)
    return report


def _file_status(path):
    return {"path": path, "exists": os.path.exists(path)}


def _sqlite_read_only_check(db_path):
    """read-only URI 로 연결해 정합성만 확인한다 — 아무것도 쓰지 않는다.

    반환: `(ok, error_message)`. `ok` 는 `PRAGMA integrity_check` 의
    첫 행이 정확히 `"ok"` 일 때만 True. 손상·비-sqlite 파일은
    `sqlite3.connect`/실행 단계에서 `sqlite3.DatabaseError`(`sqlite3.
    Error` 하위)로 즉시 실패한다 — 호출자가 그 예외를 잡아 `ok=False`
    로 옮긴다(이 함수 자신은 예외를 삼키지 않는다 — 무엇이 실패
    원인인지는 호출자가 결정할 문제).
    """
    uri = _READ_ONLY_URI_TEMPLATE.format(urllib.parse.quote(db_path))
    connection = sqlite3.connect(uri, uri=True)
    try:
        rows = connection.execute("PRAGMA integrity_check").fetchall()
    finally:
        connection.close()
    messages = [str(row[0]) for row in rows] if rows else []
    ok = messages == [_INTEGRITY_CHECK_OK]
    error = None if ok else "integrity_check: {}".format(
        "; ".join(messages) if messages else "no result"
    )
    return ok, error


def _storage_report(project_root):
    """state 디렉토리 + ledger/evidence 정본 + sqlite 캐시 상태 (읽기 전용)."""
    root = LocalStateRoot(project_root)
    db_path = root.database_path()
    db_exists = os.path.exists(db_path)
    sqlite_report = {"path": db_path, "exists": db_exists, "ok": None, "error": None}
    if db_exists:
        # 이미 존재하는 db 만, 그것도 read-only URI 로만 연다 — 모듈
        # docstring "sqlite 검사는 read-only URI 로만 연다" 절 참조.
        # SqliteStore.open() 은 스키마를 생성하는 쓰기 경로라 여기서
        # 쓰지 않는다.
        try:
            ok, error = _sqlite_read_only_check(db_path)
        except (sqlite3.Error, OSError) as error:
            sqlite_report["ok"] = False
            sqlite_report["error"] = str(error)
        else:
            sqlite_report["ok"] = ok
            sqlite_report["error"] = error
    return {
        "state_dir": root.state_dir,
        "exists": os.path.isdir(root.state_dir),
        "ledger": _file_status(root.ledger_path()),
        "evidence": _file_status(root.evidence_path()),
        "sqlite": sqlite_report,
    }


def run_doctor(project_root=None):
    """설정/policy/storage 상태를 진단해 직렬화 가능한 dict 로 반환한다.

    project_root 미지정 시 `os.getcwd()` — hook·CLI 호출 관례(이벤트
    평가 경로가 git fact 를 cwd 기준으로 해석하는 것과 동일 전제, plan
    Task 1.1)와 맞춘다.

    반환 필드는 테스트가 계약으로 고정한다: 최상위
    `project_root`/`config`/`policy`/`storage` 4키. `config` 는 미설정
    상태에서 항상 `guidance` 문자열을 채운다(spec §5.2 온보딩 안내).
    """
    if project_root is None:
        project_root = os.getcwd()
    project_root = os.path.abspath(project_root)
    return {
        "project_root": project_root,
        "config": _config_report(project_root),
        "policy": _policy_report(),
        "storage": _storage_report(project_root),
    }
