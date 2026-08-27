"""로컬 전용 runtime state 경로 관리 (plan Task 2.5 — spec §2.3, §3.8).

Runtime State 는 Git 으로 동기화하지 않는다 (spec §2.3 의도적 설계 결정):
Ledger·SQLite·Evidence Index·Circuit State 는 프로젝트의 영구 Source of
Truth 가 아니며, Git commit 이나 `trail/` 을 Runtime Ledger 로 오염시키지
않는다. state 루트는 사용자 프로젝트의 `.rein/state/` 로 고정하고,
`.gitignore` 의 `/.rein/state/` 패턴이 비추적을 보장한다 (테스트가 이
사실을 고정한다).

권한 계약 (spec §3.8, §5.5 백로그 흡수):
- 신규 생성되는 로그·ledger·db 파일은 0600 — umask 가 관대해도 chmod 로
  강제한다. 기존 파일의 권한은 건드리지 않는다 (계약은 "신규 생성" 만).
- state 디렉토리는 0700. 단 부모 `.rein/` 은 공유 디렉토리(project.json
  등 ship 대상)이므로 권한을 건드리지 않는다.
"""
import os
import stat

# state 루트 상대 경로 — GITIGNORE_PATTERN 과 짝으로 유지한다
STATE_DIR_RELATIVE = os.path.join(".rein", "state")
# 이 repo `.gitignore` 에 이미 존재하는 비추적 패턴 (테스트가 고정)
GITIGNORE_PATTERN = "/.rein/state/"

PRIVATE_FILE_MODE = 0o600
PRIVATE_DIR_MODE = 0o700

DB_FILENAME = "runtime.sqlite3"
# 발급 원장 + 발급 evidence 의 정본 쌍 (plan Task 3.3 — spec §2.2 원장
# 대조). 둘 다 append-only JSONL, 0600, git 미추적 (§2.3 로컬 전용).
# sqlite 는 이 정본의 캐시/인덱스다 — §3.8 재구축 계약(sqlite 삭제 전후
# 동일 decision)은 이 파일 쌍이 정본이기에 성립한다.
LEDGER_FILENAME = "ledger.jsonl"
EVIDENCE_FILENAME = "evidence.jsonl"
DEFAULT_LOG_FILENAME = "runtime.log"
# user_approval one-shot 소비 원장 전용 db (plan Task 4.5 — spec §3.6
# §21). `DB_FILENAME`(runtime.sqlite3) 의 5-section 캐시 계층과는 별개
# 파일이다 — 소비 여부는 재구축 가능한 캐시가 아니라 그 자체가 권위
# 소스이므로 `platform.sqlite.store.SqliteStore` 의 재구축 가능성 계약
# 아래 두지 않는다(`platform.storage.approval_store` 모듈 docstring
# 참조).
APPROVAL_CONSUMPTION_DB_FILENAME = "approval-consumption.sqlite3"

# O_NOFOLLOW 는 POSIX 확장 — 이 값이 없는 플랫폼(예: 구형 Windows 빌드)
# 에서는 0(no-op 플래그)으로 폴백한다. 이 모듈의 권한 계약 자체가 POSIX
# 대상(spec §3.8, 테스트는 `os.name == "posix"` 로 skip)이라 실사용
# 환경에서는 사실상 항상 값이 있다.
_OPEN_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def create_private_file(path):
    """파일이 없으면 0600 으로 생성한다. 새로 만들었으면 True.

    os.open 의 mode 인자는 umask 로 약화될 수 있으므로, 새로 만든 경우
    chmod 로 0600 을 확정한다. 이미 존재하는 파일은 내용·권한 모두
    건드리지 않는다 — 계약 대상은 "신규 생성" 파일뿐이다 (spec §3.8).
    """
    try:
        fd = os.open(
            path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, PRIVATE_FILE_MODE
        )
    except FileExistsError:
        return False
    try:
        os.chmod(path, PRIVATE_FILE_MODE)
    finally:
        os.close(fd)
    return True


def open_private_append(path):
    """0600 을 보장하는 append 텍스트 핸들 — 로그·ledger 공용 진입점.

    파일이 없으면 0600 으로 먼저 만들고, append 전용으로 연다 (truncate
    없음 — ledger 는 append-only).

    심볼릭 링크 가드 (보안 리뷰 시정, Low): `create_private_file` 의
    O_CREAT|O_EXCL 는 대상이 심볼릭 링크면 내용과 무관하게 EEXIST 로
    실패하므로 "파일이 아예 없던" 최초 생성 경로는 이미 안전하다.
    문제는 이 아래의 두 번째 `os.open` — 파일(또는 로컬 공격자가 미리
    심어둔 심볼릭 링크)이 이미 존재하는 정상 케이스를 열기 위한
    호출이라 O_EXCL 을 쓸 수 없다. 대신 O_NOFOLLOW 를 더해 그 사이
    심어진 심볼릭 링크를 따라가지 않는다 — 대상이 링크면 이 open 은
    조용히 링크를 통과하는 대신 ELOOP(OSError)로 명시 실패한다.
    """
    create_private_file(path)
    fd = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND | _OPEN_NOFOLLOW,
        PRIVATE_FILE_MODE,
    )
    return os.fdopen(fd, "a", encoding="utf-8")


def _reject_if_not_expected_type(path, is_expected_type, kind_label):
    """`path` 가 이미 존재한다면 심볼릭 링크가 아니고 기대한 종류인지 확인한다.

    Task 6.1 선행1 코드 리뷰 Medium 4 수리 — 이 저장소가 이미 3지점
    (`platform.storage.approval_store._reject_symlink_or_special`,
    `platform.sqlite.store._reject_symlink_or_special`, 그리고 그 둘이
    참조하는 `os.lstat`+`stat.S_IS*` 판정)에서 확립한 것과 동일한 패턴을
    반복한다 — 새 방식을 발명하지 않는다: `os.lstat`(링크를 따라가지
    않는 stat)으로 실제 종류를 확인해, 심볼릭 링크·비정규 항목이면
    명시 거부한다.

    오류 분류도 기존 3지점과 동일하게 좁힌다 — `FileNotFoundError`
    (ENOENT, 정말로 없음)만 "부재"로 흡수하고, 그 외 `OSError`(권한
    거부 등 접근 불가)는 그대로 전파한다. "접근 불가"를 "부재"로
    흡수하면 판단 재료를 확보하지 못한 상태가 조용히 "새로 만들면
    된다"로 통과하는 fail-open 이 된다.
    """
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return  # 정말로 없음 — 호출자가 새로 만든다 (안전)
    if not is_expected_type(st.st_mode):
        raise OSError(
            "refusing to use {!r} as a rein state {}: not a regular {} "
            "(symlink or special file rejected, fail-closed)".format(
                path, kind_label, kind_label
            )
        )


def reject_symlink_or_special_file(path):
    """`path` 가 이미 존재한다면 정규 파일이어야 한다.

    db 파일 등 `open_private_append`(O_NOFOLLOW 자체 방어를 이미 가짐)
    를 거치지 않는 파일 열기 앞에서 호출한다(`rein/cli/
    __init__.py::_resolve_db_path` 참조 — sqlite3.connect() 는 심볼릭
    링크를 그대로 따라가므로 열기 전에 이 검사가 필요하다).
    """
    _reject_if_not_expected_type(path, stat.S_ISREG, "file")


def _reject_symlink_or_special_dir(path):
    """`path` 가 이미 존재한다면 정규 디렉토리여야 한다 (`ensure()` 전용)."""
    _reject_if_not_expected_type(path, stat.S_ISDIR, "directory")


class LocalStateRoot:
    """사용자 프로젝트의 `.rein/state/` — 로컬 전용 runtime 저장 루트.

    경로 산출만 담당한다 — sqlite 연결·스키마는 `platform.sqlite.store`
    소관. 모든 경로는 프로젝트 루트 밑으로 고정되며 파일 이름에 경로
    구분자를 허용하지 않는다 (탈출 금지).
    """

    def __init__(self, project_root):
        self._project_root = os.path.abspath(project_root)

    @property
    def project_root(self):
        return self._project_root

    @property
    def state_dir(self):
        return os.path.join(self._project_root, STATE_DIR_RELATIVE)

    def ensure(self):
        """state 디렉토리를 만들고 0700 을 강제한다. 경로를 반환한다.

        부모 `.rein/` 은 공유 디렉토리라 권한을 건드리지 않는다 — 0700
        은 state/ 리프에만 적용한다.

        심볼릭 링크 가드 (Task 6.1 선행1 코드 리뷰 Medium 4): 이 검사
        전에는 `os.makedirs(exist_ok=True)` 가 `state_dir` 자리에 미리
        심어진 심볼릭 링크를 "이미 존재하는 디렉토리"로 그대로 인정해
        통과시키고, 뒤이은 `os.chmod` 는 기본적으로 링크를 따라가 링크
        타깃(프로젝트 밖 디렉토리일 수 있음)을 0700 으로 chmod했다 —
        이후 이 루트 밑에서 열리는 모든 ledger/evidence/db/log 파일이
        실제로는 그 외부 디렉토리에 쓰였다(리뷰어 실측 재현). 아래
        검사가 `os.makedirs`/`os.chmod` 전에 먼저 실행되어 그 경로를
        차단한다. TOCTOU 완화는 하지 않는다(이 검사와 `os.makedirs` 사이
        창이 남는다) — 이 저장소의 다른 lstat 방어들과 동일한 방어
        수준이다(그 함수들도 "재확인"만으로 완화할 뿐 완전 제거는
        하지 않는다).
        """
        _reject_symlink_or_special_dir(self.state_dir)
        os.makedirs(self.state_dir, exist_ok=True)
        os.chmod(self.state_dir, PRIVATE_DIR_MODE)
        return self.state_dir

    def database_path(self):
        return os.path.join(self.state_dir, DB_FILENAME)

    def approval_consumption_path(self):
        """user_approval 소비 원장 db 경로 — `DB_FILENAME` 과 별도 파일.

        `platform.storage.approval_store.ApprovalConsumptionStore` 가
        이 경로에 자신의 db 를 연다 (`ApprovalConsumptionStore.open`
        과 동일하게 신규 생성 시 0600 을 강제한다).
        """
        return os.path.join(
            self.state_dir, APPROVAL_CONSUMPTION_DB_FILENAME
        )

    def ledger_path(self):
        return os.path.join(self.state_dir, LEDGER_FILENAME)

    def evidence_path(self):
        return os.path.join(self.state_dir, EVIDENCE_FILENAME)

    def log_path(self, name=DEFAULT_LOG_FILENAME):
        """state 디렉토리 밑의 로그 파일 경로 — 이름만 받는다.

        경로 구분자·상대 참조가 섞인 이름은 state 루트 탈출이므로 명시
        거부한다 (spec §2.3 로컬 전용 계약).
        """
        if (
            not name
            or name in (os.curdir, os.pardir)
            or os.sep in name
            or (os.altsep and os.altsep in name)
        ):
            raise ValueError(
                "log name must be a bare filename inside the state "
                "directory, got {!r}".format(name)
            )
        return os.path.join(self.state_dir, name)

    def open_ledger(self):
        """ledger append 핸들 (0600 보장). 디렉토리도 함께 보장한다."""
        self.ensure()
        return open_private_append(self.ledger_path())

    def open_evidence(self):
        """발급 evidence append 핸들 (0600 보장). 디렉토리도 보장한다."""
        self.ensure()
        return open_private_append(self.evidence_path())

    def open_log(self, name=DEFAULT_LOG_FILENAME):
        """로그 append 핸들 (0600 보장). 디렉토리도 함께 보장한다."""
        self.ensure()
        return open_private_append(self.log_path(name))
