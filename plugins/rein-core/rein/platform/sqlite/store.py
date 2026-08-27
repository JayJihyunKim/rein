"""SQLite 확장 계층 — 캐시·인덱스 전용, Source of Truth 아님 (spec §3.8).

용도는 5개 section 으로 폐쇄된다: Fact Cache / Evidence Index / Digest
Cache / Runtime State / Ledger Index. 판단 재료의 정본은 프로젝트
상태(권위 소스)이며, 이 store 는 언제든 삭제·손상 후 재구축 가능해야
한다 — **재구축 가능성 계약**: sqlite 파일 삭제 전/후 동일 시나리오는
동일 decision 을 낸다.

운영 계약 (spec §3.8): WAL mode, 짧은 transaction (문장 단위 커밋),
busy timeout, locked 한정 bounded retry.

`platform.sqlite.__init__.open_store` (SPIKE-1 콜드스타트 probe 계약)
위의 확장 계층이다 — open_store 자체는 수정하지 않는다.
"""
import json
import os
import sqlite3
import stat
import time

# storage 어댑터의 판단-불능 번역 타입 — engine/context.py docstring 이
# 지정한 계약("storage 어댑터는 parse 실패·손상 등을 이 타입으로 번역해
# 올린다"). context 는 platform 을 import 하지 않으므로 순환 없음.
from rein.engine.context import EvidenceStorageError
from rein.kernel.evidence import (
    Evidence,
    evidence_fields,
    evidence_fingerprint,
    issuance_entry,
    issuance_matches,
    LEDGER_FIELD_FINGERPRINT,
)
from rein.kernel.requirement import REQUIREMENT_NAMES
from rein.platform.sqlite import IN_MEMORY_DB, open_store
from rein.platform.storage.local import create_private_file

# 발급 evidence 정본(JSONL) 라인의 필드 이름 — runtime 이 쓰는 형식의
# 단일 어휘. 테스트(위조 라인 시뮬레이션)도 이 상수를 참조한다.
EVIDENCE_LINE_REQUIREMENT = "requirement"
EVIDENCE_LINE_FIELDS = "fields"

SECTION_FACT_CACHE = "fact_cache"
SECTION_EVIDENCE_INDEX = "evidence_index"
SECTION_DIGEST_CACHE = "digest_cache"
SECTION_RUNTIME_STATE = "runtime_state"
SECTION_LEDGER_INDEX = "ledger_index"

# 폐쇄 section 집합 — 이 밖의 용도로 store 를 쓰는 것은 비지원
SECTIONS = (
    SECTION_FACT_CACHE,
    SECTION_EVIDENCE_INDEX,
    SECTION_DIGEST_CACHE,
    SECTION_RUNTIME_STATE,
    SECTION_LEDGER_INDEX,
)

# section → 테이블 이름. SQL 에 들어가는 식별자는 이 화이트리스트로만
# 결정된다 (외부 입력이 식별자가 되는 경로 차단).
_TABLES = {section: section for section in SECTIONS}

DEFAULT_BUSY_TIMEOUT_MS = 5000
DEFAULT_RETRY_ATTEMPTS = 3
DEFAULT_RETRY_DELAY_SECONDS = 0.02

# sqlite3 는 lock 충돌을 OperationalError 메시지로만 구분한다
_LOCKED_MESSAGE_MARKERS = (
    "database is locked",
    "database table is locked",
    "database schema is locked",
)

_SIDECAR_SUFFIXES = ("-wal", "-shm", "-journal")


def is_locked_error(error):
    """OperationalError 가 lock 충돌(재시도 가치 있음)인지 판정한다."""
    message = str(error).lower()
    return any(marker in message for marker in _LOCKED_MESSAGE_MARKERS)


def run_with_retry(
    operation,
    attempts=DEFAULT_RETRY_ATTEMPTS,
    delay_seconds=DEFAULT_RETRY_DELAY_SECONDS,
):
    """locked 한정 bounded retry (spec §3.8).

    lock 충돌 OperationalError 만 재시도한다 — 그 외(스키마 오류·손상
    등)는 즉시 전파해 오류를 침묵시키지 않는다. attempts 소진 시 마지막
    locked 오류를 그대로 올린다.
    """
    if attempts < 1:
        raise ValueError("attempts must be >= 1, got {!r}".format(attempts))
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except sqlite3.OperationalError as error:
            if not is_locked_error(error) or attempt == attempts:
                raise
            if delay_seconds:
                time.sleep(delay_seconds)


def _reject_symlink_or_special(db_path):
    """열기 전에 미리 심어진 심볼릭 링크·비정규 파일을 거부한다 (fail-closed).

    보안 시정 (Phase 6 마무리 수리 워커 H) — `platform.storage.
    approval_store.ApprovalConsumptionStore.open` 이 승인 소비 원장에
    이미 적용한 것과 같은 방어를 이 store 에도 적용한다(직전 수리 워커가
    이 파일을 자기 scope 밖이라 보고만 하고 넘긴 것 — 그 워커의 docstring
    "보안 시정 (v2 Phase 6 재리뷰 Medium C)" 절 참조). `create_private_file`
    의 `O_CREAT|O_EXCL` 는 POSIX 계약상 대상이 심볼릭 링크면 내용과
    무관하게 EEXIST 로 실패한다(링크를 따라가지 않는다) — "파일이 아예
    없던" 최초 생성 경로는 이미 안전하다. 하지만 그 다음(`open_store` →
    `sqlite3.connect`)은 일반 `open()` 경로라 심볼릭 링크를 그대로
    따라간다 — 공격자가 이 경로에 미리 외부 파일을 가리키는 링크를
    심어두면(`create_private_file` 은 조용히 `False` 를 반환하고 지나갈
    뿐 막지 않는다) 이후 모든 캐시 쓰기(`put`/`_ensure_schema`)가 그 외부
    파일에 쓰인다. 이 store 자신은 캐시일 뿐이라(spec §3.8 재구축 가능성
    계약, 클래스 docstring) 위험도는 승인 소비 원장(one-shot 계약)보다
    낮지만, 같은 결함 클래스(심볼릭 링크를 그대로 따라가는 SQLite 파일
    열기)이므로 같은 방어를 그대로 적용한다.

    수리: `open_store` 호출 전 `os.lstat`(링크를 따라가지 않는 stat)으로
    실제 파일 종류를 확인해, 일반 파일이 아니면(심볼릭 링크 포함) 열지
    않고 명시적으로 거부한다 — `rein.platform.storage.approval_store.
    _reject_symlink_or_special` 과 동일 패턴(중복 구현이지만 두 모듈
    사이에 순환 import 가 생기므로 공유 함수로 뽑지 않는다 —
    `approval_store` 가 이미 이 모듈(`run_with_retry` 등)을 import 한다).

    **오류 분류 정정 (5회차 재리뷰 Medium — 나머지 세 lstat 지점과의
    불일치 시정)**: 이전에는 `except OSError:` 로 lstat 실패를 전부
    "아직 없음"으로 흡수했다. 이 저장소의 다른 세 lstat 판정 지점
    (`approval_store._reject_symlink_or_special`,
    `cli.__init__._open_approval_consumption_store`,
    `engine.authority` 의 전환 정책 로더)은 이미 `FileNotFoundError`
    (ENOENT — 경로가 정말 없음)만 "부재"로 좁혀 흡수하고, 그 외
    `OSError`(권한 거부로 인한 `PermissionError`, 경로 구성요소가
    디렉터리가 아닌 `NotADirectoryError` 등 "접근 불가")는 그대로
    전파하도록 이미 시정돼 있었다 — 이 store 만 시정에서 빠져 있었다.
    "접근 불가"를 "부재"로 흡수하면 판단 재료를 확보하지 못한 상태가
    조용히 "새로 만들면 된다"로 통과하는 fail-open 이 된다(이 store 는
    캐시라 위험도는 승인 소비 원장보다 낮지만, 같은 오류 분류 결함
    클래스이므로 같은 방향으로 좁힌다).
    """
    try:
        st = os.lstat(db_path)
    except FileNotFoundError:
        return  # 정말로 없음 — 다음 open_store 호출이 새로 만든다 (안전)
    if not stat.S_ISREG(st.st_mode):
        raise OSError(
            "refusing to open sqlite store at {!r}: not a regular file "
            "(symlink or special file rejected, fail-closed)".format(db_path)
        )


def remove_store_files(db_path):
    """db 본체 + WAL/SHM/journal sidecar 를 제거한다 — 재구축 진입점.

    SQLite 는 Source of Truth 가 아니므로 통째 폐기가 안전하다. 없는
    파일은 조용히 지나간다 (이미 폐기된 상태도 정상).
    """
    if db_path == IN_MEMORY_DB:
        return
    for path in (db_path,) + tuple(
        db_path + suffix for suffix in _SIDECAR_SUFFIXES
    ):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


class SqliteStore:
    """폐쇄 5-section KV store — WAL·짧은 transaction·retry.

    값은 JSON 으로 직렬화해 저장한다 (stdlib only). 짧은 transaction
    계약: put/delete 는 각각 문장 1개 단위로 즉시 커밋하고 긴 트랜잭션을
    잡지 않는다.
    """

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
        """store 를 연다 — 신규 db 파일은 0600 으로 생성한다 (spec §3.8).

        파일을 sqlite 보다 먼저 0600 으로 만들어 두면 WAL/SHM sidecar 도
        같은 권한을 상속한다 (SQLite 는 sidecar 를 db 파일 권한으로
        생성). 부모 디렉토리 준비는 storage.local.LocalStateRoot 소관.

        심볼릭 링크·비정규 파일은 `_reject_symlink_or_special` 이 거부한다
        (Phase 6 마무리 수리 워커 H — 함수 docstring 참조. `IN_MEMORY_DB`
        는 파일시스템 경로가 아니므로 이 검사 대상이 아니다).
        """
        if db_path != IN_MEMORY_DB:
            create_private_file(db_path)
            _reject_symlink_or_special(db_path)
        connection = open_store(db_path)
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

    @classmethod
    def open_or_rebuild(cls, db_path, **open_kwargs):
        """손상된 db 는 폐기하고 새로 연다 (spec §3.8 재구축 계약).

        SQLite 는 캐시일 뿐이므로 손상 시 데이터 복구를 시도하지 않고
        버린다 — 판단 재료는 권위 소스에서 다시 읽힌다. 단 lock 충돌
        (OperationalError ⊂ DatabaseError)은 손상이 아니므로 폐기하지
        않고 그대로 전파한다.
        """
        try:
            return cls.open(db_path, **open_kwargs)
        except sqlite3.DatabaseError as error:
            if isinstance(
                error, sqlite3.OperationalError
            ) and is_locked_error(error):
                raise
            remove_store_files(db_path)
            return cls.open(db_path, **open_kwargs)

    @property
    def connection(self):
        return self._connection

    def _run(self, operation):
        return run_with_retry(
            operation,
            attempts=self._retry_attempts,
            delay_seconds=self._retry_delay_seconds,
        )

    def _table(self, section):
        try:
            return _TABLES[section]
        except KeyError:
            raise ValueError(
                "unknown store section {!r}; supported sections: {}".format(
                    section, ", ".join(SECTIONS)
                )
            )

    def _ensure_schema(self):
        def create():
            with self._connection:  # 짧은 transaction
                for table in _TABLES.values():
                    self._connection.execute(
                        "CREATE TABLE IF NOT EXISTS {} ("
                        "key TEXT PRIMARY KEY, value TEXT NOT NULL)".format(
                            table
                        )
                    )

        self._run(create)

    def put(self, section, key, value):
        """value 를 JSON 직렬화해 저장한다 (단문 transaction + retry)."""
        table = self._table(section)
        payload = json.dumps(value)

        def write():
            with self._connection:
                self._connection.execute(
                    "INSERT OR REPLACE INTO {} (key, value) "
                    "VALUES (?, ?)".format(table),
                    (key, payload),
                )

        self._run(write)

    def get(self, section, key, default=None):
        """저장된 값을 JSON 역직렬화해 반환한다. 없으면 default."""
        table = self._table(section)

        def read():
            return self._connection.execute(
                "SELECT value FROM {} WHERE key = ?".format(table), (key,)
            ).fetchone()

        row = self._run(read)
        if row is None:
            return default
        return json.loads(row[0])

    def delete(self, section, key):
        table = self._table(section)

        def remove():
            with self._connection:
                self._connection.execute(
                    "DELETE FROM {} WHERE key = ?".format(table), (key,)
                )

        self._run(remove)

    def close(self):
        self._connection.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False


class CachedEvidenceSource:
    """EvidenceSource 프로토콜 구현 — evidence_index 캐시 + 권위 소스.

    재구축 가능성 계약의 배선 지점: decision 의 재료는 항상 권위
    소스(프로젝트 상태를 읽는 쪽)가 정본이고, sqlite 는 그 조회 결과의
    캐시일 뿐이다.

    - 캐시 히트: sqlite 결과 반환 (부재 = 빈 목록도 정상 캐시 대상)
    - 캐시 미스·캐시 계층 오류: 권위 소스 재조회 → best-effort 재캐시
      (캐시 오류는 decision 을 바꾸지 못한다 — SoT 아님)
    - 권위 소스의 실패는 그대로 전파한다 — 판단 불능(failure_mode)
      경계는 권위 소스(storage adapter) 소관이며 캐시가 삼키면 정상
      BLOCK 과 판단 불능이 섞인다 (spec §3.4)

    **가변 권위(runtime 발급 evidence) 경로에는 부적합** — 그 경로는
    `LedgerVerifiedEvidenceSource` 를 직접 사용한다. 근거 (웨이브 3
    3회차 리뷰 실증): 무효화 배선이 없는 캐시는 권위 소스가 시간에
    따라 변하는 순간 §3.8 삭제 전후 등가와 구조적으로 양립 불가다 —
    채워진 슬롯이 이후 발급·정본 변경을 가리고, sqlite 삭제가 오히려
    결과를 바꾼다. 이 클래스는 같은 입력에 같은 답을 내는 스냅샷성
    권위 조회의 캐시로만 쓴다.
    """

    def __init__(self, store, authority):
        self._store = store
        self._authority = authority

    def find(self, requirement_name):
        try:
            cached = self._store.get(SECTION_EVIDENCE_INDEX, requirement_name)
        except (sqlite3.Error, ValueError):
            cached = None  # 캐시 오류 = 미스로 강등, 권위 소스로 진행
        if cached is not None:
            try:
                return tuple(cached)
            except TypeError:
                pass  # scalar 등 형태 손상 = 캐시 오류 — 미스 강등
        records = tuple(self._authority.find(requirement_name) or ())
        try:
            self._store.put(
                SECTION_EVIDENCE_INDEX, requirement_name, list(records)
            )
        except (sqlite3.Error, TypeError, ValueError):
            pass  # 캐시 기록은 best-effort — 실패해도 결과는 그대로
        return records


class LedgerVerifiedEvidenceSource:
    """EvidenceSource — Runtime 발급 원장 대조 소스 (spec §2.2, 파일 정본).

    spec §2.2 위협 모델: "Agent 가 Evidence 파일(JSON 등)을 직접 생성하는
    것만으로는 어떤 Requirement 도 충족되지 않는다 — Evidence 는 Rein
    Runtime 만 발급한다."

    저장 아키텍처 (웨이브 3 리뷰 방향 확정 — §3.8 재구축 계약 정합):
    발급 evidence 와 발급 원장의 **정본은 LocalStateRoot 하위의
    append-only JSONL 쌍**(`evidence.jsonl` + `ledger.jsonl`, 0600,
    git 미추적 — spec §2.3 로컬 전용)이다. **sqlite 는 evidence 신뢰
    경로에서 완전히 빠진다** (3회차 리뷰 방향 확정): 무효화 배선 없는
    가변 권위 캐시는 §3.8 삭제 전후 등가와 구조적으로 양립 불가라
    (채워진 슬롯이 이후 발급·정본 변경을 가리고, 삭제가 오히려 결과를
    바꾼다) 증거 서빙은 이 클래스 단독 — sqlite 에 무엇이 있든 평가에
    영향이 없다.

    조회(`find`)는 정본 evidence 를 원장과 대조한다 (판정은 kernel 순수
    함수 `issuance_matches`). 원장에 대응 발급 레코드가 없는 evidence
    는 형식이 §3.5 스키마와 완전히 일치해도 불인정이다.

    실패 방향 (parse/shape/원장 정합성 일관 계층 — 리뷰 지적 C):
    - 정본 파일의 JSON parse 실패·라인 shape 위반·"원장 대응 + 재수화
      불가" = 저장 손상 → EvidenceStorageError 승격 (판단 불능,
      failure_mode 분기는 evaluator 소관). runtime 발급 경로는 검증
      통과분만 정형 라인으로 쓰므로 이 상태들은 정상 경로가 만들 수
      없다 — 조용히 제외하면 '위조'와 '손상'이 섞여 부재 위장이 된다
      (spec §3.4 부재 ≠ 판단 불능).
    - 파싱·shape 정상 + 원장 미대응 = 위조 의심 제외 (보수) — 빈
      tuple 은 '부재'(정상 BLOCK 재료)다. bucket ≠ `type` 재검증
      탈락도 같은 방향이다 (재리뷰 High 1 — `find` docstring).

    성능: 매 조회마다 정본 파일을 재읽는다 (재리뷰 High 3 — 이전 stat
    서명(mtime_ns, size) 캐시는 같은 크기 + mtime 보존 교체를 놓쳤다.
    mtime 은 invalidation hint 일 뿐 validity 근거가 아니다). 정본
    JSONL 은 소형이라 재읽기 비용은 hook 예산(SPIKE-1 콜드스타트
    ≈30ms) 대비 무시 가능하다 — 캐시 없는 재읽기가 곧 즉시성 보장
    (발급 직후 조회가 바로 인정)이다.
    """

    def __init__(self, state_root):
        self._root = state_root

    # -- Runtime 발급 경로 --------------------------------------------

    def record_issued(self, requirement_name, record):
        """Runtime 발급 경로 — 원장 발급 레코드 + evidence 를 함께 기록한다.

        `record` 는 kernel Evidence 인스턴스 또는 §3.5 필드 계약 mapping.
        발급 시점 검증 (전부 저장 **전** ValueError 거부 — 반쪽 기록
        금지):
        - `requirement_name` 은 고정 5종(REQUIREMENT_NAMES) 이어야 한다.
        - Evidence 재수화로 §3.5 계약을 검증한다.
        - `record.type == requirement_name` (리뷰 지적 A — 다른 bucket
          에 기록해 교차 인정되는 경로 차단. bucket 과 type 은 같은
          어휘의 두 표기일 뿐, 불일치는 발급 계약 위반이다).

        저장 형태는 kernel `evidence_fields` 정규화 dict 를 담은 JSONL
        라인이다 (fingerprint 정규화 대칭 — 저장 왕복 후에도 대조 성립).
        쓰기 순서는 원장이 먼저다: 두 쓰기 사이에서 중단되면 "원장만
        있는" 상태(대응 evidence 부재 — 무해)로 남지, "원장 없는
        evidence"(위조 주입과 구분 불가) 상태를 만들지 않는다.

        발급된 kernel Evidence 인스턴스를 반환한다 (`find` 반환 경계와
        동일 형태).
        """
        if requirement_name not in REQUIREMENT_NAMES:
            raise ValueError(
                "evidence can only be issued for the fixed requirement "
                "contract set {} (spec §3.4), got {!r}".format(
                    REQUIREMENT_NAMES, requirement_name
                )
            )
        fields = evidence_fields(record)
        issued = Evidence(**fields)  # §3.5 계약 검증 — 실패 시 저장 안 함
        if issued.type != requirement_name:
            raise ValueError(
                "evidence type {!r} does not match the requirement bucket "
                "{!r} — cross-bucket issuance would let one requirement's "
                "evidence satisfy another (review finding A)".format(
                    issued.type, requirement_name
                )
            )
        entry = issuance_entry(fields)
        with self._root.open_ledger() as handle:
            handle.write(json.dumps(entry) + "\n")
        line = {
            EVIDENCE_LINE_REQUIREMENT: requirement_name,
            EVIDENCE_LINE_FIELDS: fields,
        }
        with self._root.open_evidence() as handle:
            handle.write(json.dumps(line) + "\n")
        return issued

    # -- 조회 (EvidenceSource 프로토콜) --------------------------------

    def find(self, requirement_name):
        """원장 대응이 확인된 evidence 만 kernel Evidence 인스턴스로 반환한다.

        반환 경계 계약: 저장 라인(dict)이 아니라 **재수화된 Evidence
        인스턴스**다 — registry 배선된 capability 구현체(예:
        CodeReviewRequirement.evaluate)는 `record.type`·`record.result`
        속성 접근과 kernel `subject_matches`(`.subject`)로 판정하므로,
        dict 를 그대로 돌려주면 결합 시 AttributeError 로 깨진다.
        실패 방향은 클래스 docstring 의 일관 계층을 따른다.
        """
        ledger = self._ledger_index()
        recognized = []
        for line in self._evidence_lines():
            if line[EVIDENCE_LINE_REQUIREMENT] != requirement_name:
                continue
            fields = line[EVIDENCE_LINE_FIELDS]
            if fields.get("type") != requirement_name:
                # 재리뷰 High 1 — bucket 만 변조된 라인은 fields 무변조라
                # 원장 대응이 살아 있다. 발급 3중 검증과 대칭으로 조회
                # 시에도 type == bucket 을 재검증한다 (불일치 = 위조
                # 의심 제외 — 교차 bucket 인정 차단)
                continue
            entry = ledger.get(evidence_fingerprint(fields))
            if not issuance_matches(fields, entry):
                continue  # 원장 미대응 = 위조 의심 제외 (보수)
            try:
                recognized.append(Evidence(**evidence_fields(fields)))
            except (TypeError, ValueError) as error:
                raise EvidenceStorageError(
                    "ledger-matched evidence record for requirement {!r} "
                    "failed to rehydrate as a §3.5 Evidence — storage "
                    "corruption suspected: {}".format(requirement_name, error)
                ) from error
        return tuple(recognized)

    # -- 정본 파일 파싱 ------------------------------------------------

    def _evidence_lines(self):
        """evidence 정본 라인 tuple — shape 검증 포함 (위반 = 손상 승격)."""
        lines = self._read_jsonl(self._root.evidence_path())
        for line in lines:
            if (
                not isinstance(line.get(EVIDENCE_LINE_REQUIREMENT), str)
                or not isinstance(line.get(EVIDENCE_LINE_FIELDS), dict)
            ):
                raise EvidenceStorageError(
                    "evidence record line in {!r} does not match the "
                    "runtime line shape ({!r} + {!r}) — storage corruption "
                    "suspected".format(
                        self._root.evidence_path(),
                        EVIDENCE_LINE_REQUIREMENT,
                        EVIDENCE_LINE_FIELDS,
                    )
                )
        return lines

    def _ledger_index(self):
        """원장 정본을 fingerprint -> entry 매핑으로 — shape 검증 포함."""
        entries = {}
        for entry in self._read_jsonl(self._root.ledger_path()):
            fingerprint = entry.get(LEDGER_FIELD_FINGERPRINT)
            if not isinstance(fingerprint, str) or not fingerprint:
                raise EvidenceStorageError(
                    "issuance ledger line in {!r} has no usable {!r} — "
                    "storage corruption suspected".format(
                        self._root.ledger_path(), LEDGER_FIELD_FINGERPRINT
                    )
                )
            entries[fingerprint] = entry
        return entries

    def _read_jsonl(self, path):
        """JSONL 파일을 mapping 라인 tuple 로 파싱한다 (매 호출 재읽기).

        - 파일 부재 = 빈 tuple ('부재' — 아직 발급 없음, 정상).
        - JSON parse 실패·UTF-8 decode 실패·비 mapping 라인 =
          EvidenceStorageError (정본 손상 — runtime 은 정형 UTF-8
          mapping 라인만 쓴다).
        - 그 외 OSError = EvidenceStorageError (판단 재료 확보 실패).
        """
        parsed = []
        try:
            with open(path, "r", encoding="utf-8") as handle:
                for line_number, raw in enumerate(handle, start=1):
                    stripped = raw.strip()
                    if not stripped:
                        continue
                    try:
                        value = json.loads(stripped)
                    except ValueError as error:
                        raise EvidenceStorageError(
                            "broken JSON at {}:{} — storage corruption "
                            "suspected: {}".format(path, line_number, error)
                        ) from error
                    if not isinstance(value, dict):
                        raise EvidenceStorageError(
                            "non-mapping JSONL line at {}:{} — storage "
                            "corruption suspected".format(path, line_number)
                        )
                    parsed.append(value)
        except FileNotFoundError:
            return ()
        except UnicodeDecodeError as error:
            raise EvidenceStorageError(
                "undecodable bytes in evidence store file {!r} — storage "
                "corruption suspected: {}".format(path, error)
            ) from error
        except OSError as error:
            raise EvidenceStorageError(
                "cannot read evidence store file {!r}: {}".format(path, error)
            ) from error
        return tuple(parsed)
