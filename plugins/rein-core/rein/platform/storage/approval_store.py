"""User approval one-shot 소비 원장 (v2 Phase 6 worker D — spec §3.6 §21,
plan Task 4.5).

`rein.capabilities.approval.capability` 가 요구하는 duck-typed 소비 저장
프로토콜(`is_consumed(fingerprint) -> bool`, `claim(fingerprint) -> bool`
원자적 check-and-set, `release(fingerprint) -> Any` best-effort 롤백)의
실제 구현체다. capability 모듈은 이 클래스를 전혀 모른다(import 하지
않는다) — 프로토콜 모양만 duck-type 으로 검증한다(`_validate_
consumption_store`, `rein/capabilities/approval/capability.py`).

## 저장 위치 — 왜 `SqliteStore`(runtime.sqlite3)의 5-section 캐시가 아닌가

`platform.sqlite.store.SqliteStore` 는 spec §3.8 "재구축 가능성 계약"
아래 있다 — 그 store 의 5-section(fact_cache/evidence_index/digest_cache
/runtime_state/ledger_index)은 전부 **다른 권위 소스의 캐시/인덱스**이고,
db 파일을 지워도 권위 소스에서 다시 채워져 동일 decision 을 내야 한다.

승인 소비 여부는 이 계약을 만족할 수 없다 — "이 fingerprint 가 이미
소비됐다"는 사실은 다른 어디에도 정본으로 남지 않는다(`kernel.evidence.
Evidence` 는 `@dataclass(frozen=True)` 라 "사용됨" 필드를 사후에 세팅할
방법이 없다, `rein.capabilities.approval.capability` 모듈 docstring
"이 capability 가 review/security 와 다른 지점" 절 참조). 이 store 를
지우면 이미 소비된 승인이 "미소비"로 되살아나 재사용 가능해지는 것은
캐시 무효화가 아니라 **one-shot 계약 파괴**다. 그러므로 이 파일은
`SqliteStore` 와 별개의 db(`LocalStateRoot.approval_consumption_path()`,
`runtime.sqlite3` 와 다른 파일)를 쓴다 — `SqliteStore` 의 5-section
폐쇄 스키마에 여섯 번째 용도를 얹지 않는다(그 클래스의 재구축 가능성
계약을 깨는 대신, 애초에 그 계약 아래 있지 않은 별도 파일로 분리한다).

## 원자성 — PRIMARY KEY 제약을 이용한 check-and-set

`claim()` 은 `INSERT INTO consumed_approvals (fingerprint, ...) VALUES
(...)` 문 하나로 구현된다 — `fingerprint` 가 PRIMARY KEY 이므로, 이미
존재하는 값을 다시 넣으려는 시도는 SQLite 자신이 `sqlite3.
IntegrityError` 로 거부한다. 이 UNIQUE 제약 위반이 곧 "경합에서 진 쪽"
신호다(승인 프로토콜의 `claim() -> False` 계약). WAL 모드 +
`platform.sqlite.store.run_with_retry` 의 locked-only bounded retry 를
그대로 재사용해(재구현하지 않는다 — 기존 저장소 패턴 재사용) 동시 쓰기
경합 시 일시적 "database is locked" 를 흡수한다.

`claim()` 이 그 외 sqlite 오류(재시도 소진 등)로 실패하면 예외를 그대로
전파한다 — `rein.capabilities.approval.capability` 모듈 docstring이
명시하는 "claim 이 `False` 를 반환하거나 예외를 던지면 그 즉시 그 cycle
의 decision 은 fail-closed BLOCK 으로 downgrade" 계약을 그대로 만족
하려면, "경합 패배"(정상적으로 예상되는 `False`)와 "저장소 자체가
고장남"(예외)을 굳이 이 계층에서 하나로 뭉개지 않는 편이 호출자(Runtime
commit 층)의 진단에 유리하다 — 두 경우 모두 최종 처리 방향(BLOCK)은
같지만, 원인 구분은 로그·재시도 판단에 남는다.

## 동시성 보장 범위 — 정직한 경계 (과장 금지)

- **같은 머신, 여러 프로세스**: SQLite 의 파일 잠금 + PRIMARY KEY 제약이
  실제로 두 프로세스가 같은 fingerprint 를 동시에 claim 하는 경쟁에서
  정확히 하나만 성공시킨다 — `tests/unit/test_approval_consumption_
  store.py::ConcurrentClaimTest` 가 `multiprocessing`(spawn, 서로 다른
  sqlite 연결)으로 실제 재현·고정한다. 이는 "테스트 더블로 흉내낸
  동시성"이 아니라 실제 두 OS 프로세스의 경쟁이다.
- **네트워크 파일시스템(NFS 등)**: SQLite 자신의 문서가 NFS 위 잠금
  프로토콜의 신뢰성을 보장하지 않는다고 명시한다 — 이 store 는 spec
  §2.3 이 정한 로컬 전용 전제(`.rein/state/`)를 넘어서는 보장은 하지
  않는다.
- **프로세스 내부 스레드 공유**: 이 클래스는 스레드 안전을 별도로
  구현하지 않는다 — `sqlite3.connect` 의 기본값(`check_same_thread=
  True`)을 그대로 쓰므로, 연결을 연 스레드가 아닌 다른 스레드에서 같은
  인스턴스를 쓰면 sqlite3 자신이 `ProgrammingError` 로 거부한다. 여러
  스레드에서 쓰려면 스레드마다 별도로 `ApprovalConsumptionStore.open()`
  을 호출해야 한다(이 클래스가 강제하지 않음 — 문서화만 하는 경계).
- **claim 성공 후 정전/kill -9 같은 비정상 종료**: `claim()` 의
  `INSERT` 는 `with self._connection:` 컨텍스트(단문 transaction, 성공
  시 자동 COMMIT)로 감싼다 — SQLite 의 WAL 커밋이 실제로 완료된 뒤에만
  `claim()` 이 `True` 를 반환하므로, "claim 이 True 를 반환했는데 사실은
  커밋 안 됨" 같은 반쪽 상태는 SQLite 자신의 durability 계약 범위 안이다
  (이 store 가 별도로 보강하지 않는다 — SQLite WAL 의 표준 보장에 의존).

## 읽기 전용 진단 연결 — `open_read_only_approval_consumption_store`
(v2 Phase 6 3회차 재리뷰 Medium C 시정)

`rein/cli/__init__.py::_open_approval_consumption_store` 는 `run_explain()`
(진단, `read_only=True`)이 **이미 존재하는** db 파일을 열 때 이 함수를
쓴다. `open_default_approval_consumption_store()`(위, 항상 쓰기 가능)를
그대로 재사용하면 `ApprovalConsumptionStore.__init__` 이 무조건
`_ensure_schema()`(`CREATE TABLE IF NOT EXISTS`)를 실행한다 — 이미
스키마가 있는 정상 db 에는 no-op 이지만, 아직 초기화되지 않은 0바이트
정규 파일에는 실제로 테이블을 만들어 파일 크기를 바꾼다(실측: 0 →
12288 바이트) — "진단은 상태를 바꾸지 않는다" 계약 위반(리뷰어 재현).

`open_read_only_approval_consumption_store()` 는 SQLite read-only URI
연결(`mode=ro` + `PRAGMA query_only=1` 이중 방어)로 이 문제를 구조적으로
막는다 — 쓰기 시도(스키마 생성 포함) 자체가 SQLite 에 의해 거부된다.
`ReadOnlyApprovalConsumptionStore.is_consumed()` 는 그 결과로 아직
스키마가 없는(테이블이 없는) db 에서 `sqlite3.OperationalError`
("no such table")를 흡수해 `False` 를 반환한다 — 빈/미초기화 db 는
"아무 것도 소비된 적 없음"과 논리적으로 동치이기 때문이다(위 "저장
위치" 절과 동일 판단). 그 외 사유(파일 손상 등, "file is not a
database")는 흡수하지 않고 그대로 전파한다 — 손상을 부재로 위장하지
않는다.

**심볼릭 링크 판정 parity**: 호출자(`rein/cli/__init__.py`)가 대상이
정규 파일로 이미 존재함을 `os.lstat`+`stat.S_ISREG` 로 먼저 확인한
뒤에만 이 함수를 부른다 — 매달린 심볼릭 링크는 그 판정에서 이미
걸러진다(`_reject_symlink_or_special` 과 동일한 lstat 판정을 진단
경로에도 적용, 이전에는 `os.path.exists()`(심볼릭 링크를 따라감)만
써서 매달린 링크가 "파일 없음"으로 오인정돼 explain 은 통과, 실제
`run_event()` 는 차단하는 판정 갈라짐이 있었다). 이 함수 자신도
`_reject_symlink_or_special()` 을 다시 호출한다(TOCTOU 완화 — 호출자의
lstat 과 이 함수의 connect 사이 창).
"""
import os
import sqlite3
import stat
import urllib.parse
from datetime import datetime, timezone

from rein.platform.sqlite import open_store
from rein.platform.sqlite.store import (
    DEFAULT_BUSY_TIMEOUT_MS,
    DEFAULT_RETRY_ATTEMPTS,
    DEFAULT_RETRY_DELAY_SECONDS,
    run_with_retry,
)
from rein.platform.storage.local import create_private_file

_TABLE = "consumed_approvals"


def _reject_symlink_or_special(db_path):
    """열기 전에 미리 심어진 심볼릭 링크·비정규 파일을 거부한다 (fail-closed).

    보안 시정 (v2 Phase 6 재리뷰 Medium C). `create_private_file` 의
    O_CREAT|O_EXCL 는 POSIX 계약상 대상이 심볼릭 링크면 내용과 무관하게
    EEXIST 로 실패한다(링크를 따라가지 않는다) — "파일이 아예 없던" 최초
    생성 경로는 이미 안전하다. 하지만 그 다음(`open_store` →
    `sqlite3.connect`)은 일반 `open()` 경로라 심볼릭 링크를 그대로
    따라간다 — 공격자가 이 경로에 미리 외부 파일을 가리키는 링크를
    심어두면(`create_private_file` 은 조용히 `False` 를 반환하고 지나갈
    뿐 막지 않는다) 이후 모든 소비 기록(`claim`/`release`)이 그 외부
    파일에 쓰인다. 이 store 는 캐시가 아니라 권위 기록이다(모듈
    docstring "저장 위치" 절) — 소비 기록이 엉뚱한 파일에 쓰이면 원래
    db 는 "미소비"로 남아 이미 쓴 승인이 되살아난다(one-shot 계약 파괴).

    수리: `open_store` 호출 전 `os.lstat`(링크를 따라가지 않는 stat)으로
    실제 파일 종류를 확인해, 일반 파일이 아니면(심볼릭 링크 포함) 열지
    않고 명시적으로 거부한다 — 이 저장소 트리의 기존 방어와 같은
    패턴이다: `platform.git.facts` 가 WORKTREE 내용을 읽기 전
    `os.stat(follow_symlinks=False)` + `stat.S_ISREG` 로 특수 파일을
    걸러내는 것과 동일 계열의 검사다. 이 store 는 `sqlite3.connect` 에
    fd 가 아니라 경로 문자열을 넘겨야 하므로(`platform.storage.local.
    open_private_append` 의 O_NOFOLLOW open() 트릭을 그대로 재사용할 수
    없다) stat 기반 사전 검사를 쓴다 — `platform.git.facts` 가 이미 쓰는
    것과 동일선상의 완화다.
    """
    # 오류 분류: `FileNotFoundError`(POSIX ENOENT — 경로 자체가, 또는
    # 그 상위 경로 구성요소가 존재하지 않음)만 "진짜 없음"으로 흡수한다.
    # 이전에는 `except OSError:` 로 너무 넓게 받아 "파일이 정말
    # 없음"과 "lstat 자체가 다른 이유로 실패함"(예: 상위 디렉터리 권한
    # 거부 → `PermissionError`)을 똑같이 "부재"로 흡수했다 — 진입점
    # (`rein/cli/__init__.py::_open_approval_consumption_store`)의 4회차
    # 독립 리뷰 Medium 2 시정과 정확히 같은 클래스의 결함이 여기 남아
    # 있었다. 이 store 는 캐시가 아니라 권위 기록이다(모듈 docstring
    # "저장 위치" 절) — 판단 재료를 확보하지 못한 상태(권한 거부 등)를
    # "부재"로 흡수하면 접근 불가 상태가 조용히 통과하는 fail-open 이
    # 된다. 그 외 `OSError`(권한 거부, 경로 구성요소가 디렉터리가 아님
    # 등)는 그대로 전파한다(`tests/unit/test_approval_consumption_store.
    # py::RejectSymlinkOrSpecialErrorClassificationTest` 가 이 경계를
    # 고정한다).
    try:
        st = os.lstat(db_path)
    except FileNotFoundError:
        return  # 정말로 없음 — 다음 open_store 호출이 새로 만든다 (안전)
    if not stat.S_ISREG(st.st_mode):
        raise OSError(
            "refusing to open approval consumption store at {!r}: not a "
            "regular file (symlink or special file rejected, "
            "fail-closed)".format(db_path)
        )


class ApprovalConsumptionStore:
    """승인 소비 프로토콜(`is_consumed`/`claim`/`release`)의 sqlite 구현체."""

    def __init__(
        self,
        connection,
        retry_attempts=DEFAULT_RETRY_ATTEMPTS,
        retry_delay_seconds=DEFAULT_RETRY_DELAY_SECONDS,
    ):
        self._connection = connection
        self._retry_attempts = retry_attempts
        self._retry_delay_seconds = retry_delay_seconds
        self._ensure_schema()

    @classmethod
    def open(
        cls,
        db_path,
        busy_timeout_ms=DEFAULT_BUSY_TIMEOUT_MS,
        retry_attempts=DEFAULT_RETRY_ATTEMPTS,
        retry_delay_seconds=DEFAULT_RETRY_DELAY_SECONDS,
    ):
        """db 를 연다 — 신규 db 파일은 0600 으로 생성한다(`SqliteStore.open`
        과 동일 패턴, 재구현하지 않고 같은 저장소 관례를 따른다).

        심볼릭 링크·비정규 파일은 `_reject_symlink_or_special` 이 거부한다
        (Medium C 보안 시정, 함수 docstring 참조).

        연결 누수 방지 (Low D 보안 시정): PRAGMA 설정이나 스키마 생성
        (`cls(...)` 생성자가 호출하는 `_ensure_schema`) 도중 예외가 나면,
        이미 연 sqlite3 connection 을 닫지 않고 그대로 예외를 전파하던
        구 구현은 그 connection 을 참조할 방법이 호출자에게 전혀 남지
        않아(반환되지 못한 로컬 변수) 그대로 누수됐다. 이제 이 구간
        전체를 try/except 로 감싸 실패 시 `connection.close()` 를 먼저
        호출한 뒤 원래 예외를 그대로 재전파한다.
        """
        create_private_file(db_path)
        _reject_symlink_or_special(db_path)
        connection = open_store(db_path)
        try:
            connection.execute(
                "PRAGMA busy_timeout = {:d}".format(int(busy_timeout_ms))
            )
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=NORMAL")
            return cls(
                connection,
                retry_attempts=retry_attempts,
                retry_delay_seconds=retry_delay_seconds,
            )
        except Exception:
            connection.close()
            raise

    def _run(self, operation):
        return run_with_retry(
            operation,
            attempts=self._retry_attempts,
            delay_seconds=self._retry_delay_seconds,
        )

    def _ensure_schema(self):
        def create():
            with self._connection:
                self._connection.execute(
                    "CREATE TABLE IF NOT EXISTS {} ("
                    "fingerprint TEXT PRIMARY KEY, "
                    "consumed_at TEXT NOT NULL)".format(_TABLE)
                )

        self._run(create)

    def is_consumed(self, fingerprint):
        """순수 조회(peek) — 이미 소비된 fingerprint 인가."""

        def read():
            return self._connection.execute(
                "SELECT 1 FROM {} WHERE fingerprint = ?".format(_TABLE),
                (fingerprint,),
            ).fetchone()

        return self._run(read) is not None

    def claim(self, fingerprint):
        """원자적 check-and-set — 이미 소비면 `False`, 새로 소비하면 `True`.

        `sqlite3.IntegrityError`(PRIMARY KEY 충돌)는 "경합 패배" 신호
        이므로 여기서 직접 잡아 `False` 로 변환한다 — 그 외 sqlite 오류
        (잠금 재시도 소진 등)는 호출자(`rein.engine.runtime` 의 commit
        층)까지 그대로 전파한다(모듈 docstring "원자성" 절 참조).
        """

        def insert():
            with self._connection:
                self._connection.execute(
                    "INSERT INTO {} (fingerprint, consumed_at) "
                    "VALUES (?, ?)".format(_TABLE),
                    (fingerprint, _now_iso()),
                )

        try:
            self._run(insert)
        except sqlite3.IntegrityError:
            return False
        return True

    def release(self, fingerprint):
        """best-effort 롤백 — 실제로 지워진 행이 있었으면 `True`."""

        def delete():
            with self._connection:
                cursor = self._connection.execute(
                    "DELETE FROM {} WHERE fingerprint = ?".format(_TABLE),
                    (fingerprint,),
                )
                return cursor.rowcount

        return self._run(delete) > 0

    def close(self):
        self._connection.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False


def _now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def open_default_approval_consumption_store(state_root):
    """`LocalStateRoot` 의 기본 경로에 store 를 연다(디렉토리도 보장한다)."""
    state_root.ensure()
    return ApprovalConsumptionStore.open(
        state_root.approval_consumption_path()
    )


class ReadOnlyApprovalConsumptionStore:
    """이미 존재하는 db 를 읽기 전용으로 조회한다 — 스키마 보장을 하지 않는다.

    `open_read_only_approval_consumption_store()` 전용 구현체(모듈
    docstring "읽기 전용 진단 연결" 절). `ApprovalConsumptionStore` 와
    달리 생성자가 `_ensure_schema()` 를 호출하지 않는다 — 호출하면
    읽기 전용 연결에서 아직 스키마가 없는(빈) db 에 대해 쓰기 시도가
    거부되기 때문이다(실측: `sqlite3.OperationalError: attempt to
    write a readonly database`). 대신 `is_consumed()` 조회 시점에
    "테이블 없음" 을 정상 흡수한다(아래 참조).

    `claim()`/`release()` 는 이 store 를 쓰는 유일한 프로덕션 호출자
    (`run_explain()`)가 구조적으로 호출하지 않는다 — `evaluator.
    evaluate()` 는 commit 단계가 없는 함수다(`rein/cli/explain.py`
    모듈 docstring "진단은 상태를 바꾸지 않는다" 절). 그럼에도 호출되면
    관대하게 성공한 척하지 않고 즉시 실패한다(`rein/cli/
    __init__.py::_ReadOnlyEmptyApprovalConsumptionStore` 와 동일한
    fail-loud 원칙 — 그 클래스는 "파일이 아예 없음", 이 클래스는
    "파일은 있지만 읽기 전용"이라는 다른 경계를 담당한다).
    """

    def __init__(self, connection):
        self._connection = connection

    def is_consumed(self, fingerprint):
        """순수 조회 — 아직 스키마가 없는 db 는 '미소비' 로 흡수한다.

        빈/미초기화 db(`consumed_approvals` 테이블 자체가 없음)는
        "아무 것도 소비된 적 없음"과 논리적으로 동치다(모듈 docstring
        "읽기 전용 진단 연결" 절) — `sqlite3.OperationalError` 의
        메시지가 "no such table" 을 포함할 때만 이 등가성을 적용해
        `False` 를 반환한다. 그 외 사유(파일 손상 등)는 흡수하지 않고
        그대로 전파한다 — 손상을 부재로 위장하지 않는다.
        """
        try:
            cursor = self._connection.execute(
                "SELECT 1 FROM {} WHERE fingerprint = ?".format(_TABLE),
                (fingerprint,),
            )
        except sqlite3.OperationalError as error:
            if "no such table" in str(error):
                return False
            raise
        return cursor.fetchone() is not None

    def claim(self, fingerprint):
        raise RuntimeError(
            "read-only approval consumption store (existing db opened "
            "for diagnostics) was asked to claim(fingerprint={!r}) — "
            "this must never happen: run_explain() never commits "
            "(rein/cli/explain.py module docstring), so reaching here "
            "signals a structural bug, not a normal code "
            "path".format(fingerprint)
        )

    def release(self, fingerprint):
        raise RuntimeError(
            "read-only approval consumption store (existing db opened "
            "for diagnostics) was asked to release(fingerprint={!r}) — "
            "it never claims anything, so it should never be asked to "
            "release either; this signals a structural bug".format(
                fingerprint
            )
        )

    def close(self):
        self._connection.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False


def open_read_only_approval_consumption_store(state_root):
    """이미 존재하는 db 파일을 읽기 전용으로 연다 — 스키마를 생성하지 않는다.

    모듈 docstring "읽기 전용 진단 연결" 절 참조 (v2 Phase 6 3회차
    재리뷰 Medium C 시정). 호출 전 대상이 **정규 파일로 이미 존재함**을
    확인하는 것은 호출자 책임이다(`rein/cli/__init__.py::
    _open_approval_consumption_store` 가 `os.lstat`+`stat.S_ISREG` 로
    미리 가른다) — 이 함수는 그 판정을 다시 반복하지 않고, 대신
    `_reject_symlink_or_special()` 로 한 번 더 확인한다(TOCTOU 완화).
    """
    db_path = state_root.approval_consumption_path()
    _reject_symlink_or_special(db_path)
    uri = "file:{}?mode=ro".format(urllib.parse.quote(db_path))
    connection = sqlite3.connect(uri, uri=True)
    try:
        connection.execute("PRAGMA query_only = 1")
    except Exception:
        connection.close()
        raise
    return ReadOnlyApprovalConsumptionStore(connection)
