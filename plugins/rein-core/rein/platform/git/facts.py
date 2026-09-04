"""Git ChangeSet facts — WORKTREE/STAGED 해석 + 내용 공급 (spec §3.3).

kernel 의 ChangeSet/digest 는 git 을 모른다 — 이 모듈이 git 해석
(어떤 경로가 변했는가, 그 내용은 무엇인가)을 담당하고, digest 계산은
kernel `content_digest` 에 내용 공급자를 주입해 위임한다.

해석 불가(레포 부재·git 부재·timeout)는 예외가 아니라 None 이다 —
fact 의 부재일 뿐 평가 실패(failure_mode 대상)가 아니다
(`current_branch` 관례, spec §3.4).

내용 크기 상한 (보안 리뷰 시정, Medium): kernel `content_digest` 의
주입 계약은 `read_content(path) -> bytes | None` 이며 완성된 bytes 를
요구한다 (hasher 에 청크 단위로 흘려 넣는 스트리밍 API 가 아니다 —
그렇게 바꾸려면 kernel 계약 자체를 변경해야 하고 이는 이 모듈의 scope
밖이다). 따라서 이 모듈은 "명시적 크기 상한 + 초과 시 에러" 를
택한다: 단일 파일/blob 이 `_MAX_CONTENT_BYTES` 를 넘으면 조용히
잘라내지 않고 `ContentSizeExceededError` 를 던진다 — 절단하면 서로
다른 내용이 같은 digest 로 축약될 수 있어 근거 만료 계약이 깨진다.
WORKTREE 는 청크 단위로 읽으며 상한 도달 즉시 중단해(전체를 메모리에
올리기 전에) 초과 파일의 나머지를 읽지 않고, STAGED 는 `git cat-file
-s`(단일 오브젝트용 `--batch-check` 크기 조회)로 blob 크기를 먼저
확인해 상한 초과 시 `cat-file blob` 자체를 실행하지 않는다.

심볼릭 링크 (보안 리뷰 참고): WORKTREE 리더는 심링크를 따라가지 않기로
결정했다 — 대신 git 이 심링크 blob(mode 120000)에 저장하는 것과 같은
"타깃 경로 문자열"만 해싱한다. 이유는 둘: (1) 링크를 follow 하면 repo
경계 밖 파일 내용이 digest 계산에 섞여 "이 ChangeSet 은 repo 안의
내용만 반영한다"는 암묵 전제가 깨진다. (2) 대상이 FIFO/디바이스 등
특수 파일이면 무기한 블로킹 read 로 DoS 가 가능하다. STAGED 리더는
git 오브젝트 스토어에서 직접 blob 을 읽으므로(파일시스템 `open()`
경유가 아님) 이 문제에 애초에 노출되지 않는다.

특수 파일 — 심링크 미경유 (재리뷰 시정, Low): 위 (2)는 심링크가 특수
파일을 "가리키는" 경우만 막는다. 작업 트리에 심링크 없이 FIFO(named
pipe, `mkfifo`)가 직접 놓여 있으면 `islink()` 는 False 라 그대로
`open(path, "rb")` 로 진입한다 — writer 가 없는 FIFO 의 open 은
무기한 블로킹되므로 같은 DoS 가 재발한다. 따라서 open 이전에
`os.stat(path, follow_symlinks=False)` 로 파일 종류를 확인해, 일반
파일(`stat.S_ISREG`)이 아니면 열지 않고 부재(None)로 답한다. "부재"가
맞는 판정인 이유: git 자체가 FIFO/소켓/디바이스/디렉토리를 blob 으로
추적하지 않는다 — 이런 경로는 애초에 git 이 다루는 "내용 있는 변경"
개념에 대응하지 않으므로, 여는 것을 시도하다 실패로 올리기보다는
ChangeSet 의 다른 삭제/부재 경로들과 동일하게 조용히 None 으로 답하는
편이 기존 계약(레포 부재·git 부재와 같은 "해석 불가는 예외가 아니라
None" 원칙)과 일관된다.
"""
import json
import os
import re
import stat
import subprocess
import warnings

from rein.engine.tags import TAG_SENSITIVE, classify_path, load_tag_rules
from rein.kernel.changeset import (
    SCOPE_STAGED,
    SCOPE_WORKTREE,
    SUBJECT_EMPTY,
    SUBJECT_UNRESOLVED,
    ChangeSet,
    content_digest,
)
from rein.kernel.policy import (
    DIGEST_SCOPE_SENSITIVE,
    DIGEST_SCOPE_STRICT,
    VERSION_FILENAME,
    PolicyVersionError,
    parse_policy_version,
)

# `load_policy_version` 는 여기서 top-level import 하지 않는다 — 아래
# `resolve_policy_version_digest_scope()` 의 s5(비 git) fallback 이 호출
# 시점에 매번 `rein.kernel.policy.load_policy_version` 을 새로 조회해야
# 한다(테스트가 `mock.patch.object(policy_module, "load_policy_version",
# ...)` 로 스파이/교체하는 계약, `tests/cli/test_changeset_fact_dependency_
# gating.py::PolicyVersionCacheSharingTest` 참조). top-level `from X
# import Y` 로 한 번 바인딩하면 그 이름은 import 시점의 함수 객체를
# 영구히 가리켜, 이후 다른 모듈이 `rein.kernel.policy.load_policy_version`
# 자체를 재할당해도(monkeypatch) 이 모듈은 여전히 원본을 호출한다 —
# 실측: 이 함수를 top-level import 로 뒀을 때 위 테스트의 "unshared 경로
# 2회 호출" 대조군이 1회로 undercount 됐다(패치가 반영되지 않아 실제로는
# 호출됐지만 스파이가 세지 못함).

_GIT_TIMEOUT_SECONDS = 5

# 상태 필드에 이 문자가 있으면 다음 -z 토큰은 rename/copy 의 원본 경로다
_RENAME_STATUS_CHARS = ("R", "C")

# strict digest scope 의 버전-only 특례 2파일 (spec §3.6, v1 계승 —
# `hooks/lib/security-review-gate.sh` `_sx_version_only_rein_sh` /
# `_sx_version_only_plugin_json` L491-559 부근의 python 재현).
_STRICT_VERSION_ONLY_REIN_SH = "scripts/rein.sh"
_STRICT_VERSION_ONLY_PLUGIN_JSON = (
    "plugins/rein-core/.claude-plugin/plugin.json"
)

# 단일 파일/blob 의 내용 상한 (바이트) — 초과 시 조용한 절단이 아니라
# ContentSizeExceededError 로 명시 실패한다 (모듈 docstring 참조).
_MAX_CONTENT_BYTES = 64 * 1024 * 1024
# WORKTREE 청크 읽기 단위 — 상한 도달 즉시 중단하기 위한 크기.
_READ_CHUNK_BYTES = 1024 * 1024


class ContentSizeExceededError(RuntimeError):
    """내용/blob 이 크기 상한을 초과 — 절단 대신 명시 실패 (fact 부재 아님).

    kernel `content_digest` 의 read_content 계약(bytes | None)에서 None
    은 "경로 부재" 를 뜻한다. 크기 초과는 경로가 존재하고 내용도 있지만
    안전하게 다룰 수 없는 상태이므로 None(부재)과 구분해 별도 예외로
    올린다 — 부재로 취급하면 대용량 변경이 조용히 digest 계산에서
    빠져 근거 만료 계약이 깨진다.
    """


def _run_git(args, cwd=None):
    """git 하위 명령 실행 — 성공 시 stdout bytes, 실패 시 None.

    **주의 (리뷰 지적, 2026-08-20)**: 이 함수의 `None` 은 "비-git
    저장소"·"timeout"·"프로세스 실행 오류"·"그 밖의 비0 종료" 를 전부
    합친 값이다 — 이 넷을 구분해야 하는 호출자(예: "git 저장소인지"를
    판정해 그 결과에 따라 서로 다른 신뢰 수준으로 분기하는 코드)는 이
    함수를 직접 쓰지 말고 아래 `_resolve_git_toplevel()`/
    `_run_git_lifecycle_query()` 처럼 전용 헬퍼로 필요한 만큼만
    세분화한다 — 이 함수 자신의 반환 계약은 바꾸지 않는다(기존 소비처
    10곳 전부가 "성공 bytes 아니면 실패로 흡수" 라는 단순 계약에
    의존하므로, 계약을 넓히면 그 전부를 재검토해야 한다 — 이 함수는
    그대로 두고 필요한 곳에만 전용 헬퍼를 추가하는 편이 최소 침습이다.
    실측 근거: `grep -n "_run_git("` 이 정의 자신과 주석·docstring 언급을
    제외하고 정확히 10개 실호출부를 센다, 2026-08-20 — 리뷰 지적 당시의
    "17곳"(실제로는 그 시점 기준 15곳이던 stale 수치)에서, 이번 수리로
    `resolve_policy_version_digest_scope()`/`resolve_policy_version_for_
    absent_worktree()` 의 5개 호출부가 `_run_git_lifecycle_query()` 로
    옮겨가면서 10곳으로 더 줄었다).
    """
    try:
        proc = subprocess.run(
            ("git",) + tuple(args),
            cwd=cwd,
            capture_output=True,
            timeout=_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


# ---------------------------------------------------------------------------
# 정책 버전 git 수명주기 판정 전용 3상태 조회 (Critical/High 리뷰 지적
# 수리, 2026-08-20).
#
# 직전 수리(`_resolve_git_toplevel()`, 아래)는 최초 `rev-parse
# --show-toplevel` 조회 하나만 "확실히 비-git" 대 "판정 자체가
# 실패했다"로 구분했다. 그런데 `resolve_policy_version_digest_scope()`/
# `resolve_policy_version_for_absent_worktree()` 의 **후속** 조회(HEAD
# 내용 `show HEAD:<path>`, index 내용 `cat-file blob :0:<path>`)는
# 여전히 공용 `_run_git()`(부재·오류를 전부 `None` 하나로 합침)을 그대로
# 썼다 — 리뷰어 재현: clean 하게 committed 된 strict 저장소에서 HEAD
# 조회만 프로세스 오류로 실패하게 주입하면, worktree/index 내용은 실제
# 정상 조회되어 서로 일치하는데 `head_bytes` 만 "확인 실패"인지 "HEAD 에
# 파일 없음"인지 구분되지 않아, 후자로 오인해 s2(최초 staged-add) 분기로
# 새 곧바로 `DIGEST_SCOPE_SENSITIVE` 기본값을 반환했다 — clean committed
# strict 선언이 순간적인 git 실행 실패 하나로 조용히 sensitive 로
# 강등되는, `_resolve_git_toplevel()` 이 최초 조회에서 이미 막았던 것과
# 같은 클래스의 결함이 후속 조회에서 재발한 것.
#
# 아래 `_run_git_lifecycle_query()` 가 두 함수의 **모든** git 조회
# (rev-parse 포함, `_resolve_git_toplevel()` 도 이제 이 헬퍼 위에
# 재구현된다)를 FOUND/ABSENT/ERROR 3상태로 통일한다. 공용 `_run_git()`
# 자신은 바꾸지 않는다 — 별도 subprocess 호출 경로를 갖는 신설 헬퍼다
# (`_run_git()` docstring "기존 소비처" 절 참조, 최소 침습 원칙 계승).

_GIT_QUERY_FOUND = "found"
_GIT_QUERY_ABSENT = "absent"
_GIT_QUERY_ERROR = "error"

# 각 git 하위 명령이 "이 시점에 이 경로/오브젝트가 없다" 는 것을
# **명시적으로** 확인해 줄 때의 stderr 부분 문자열. 실측 근거
# (2026-08-20, 임시 저장소에서 실제 git 하위 명령을 직접 실행해 stderr
# 원문을 확인 — 추측으로 채우지 않았다):
#
#   * `rev-parse --show-toplevel` (비 git 디렉터리):
#     "fatal: not a git repository (or any of the parent directories): .git"
#   * `show HEAD:<path>` (HEAD 는 존재, 경로가 그 안에 없고 worktree 에도
#     물리적으로 없음 — 예: committed 저장소에서 완전 미지의 경로):
#     "fatal: path '<path>' does not exist in 'HEAD'"
#   * `show HEAD:<path>` (HEAD 는 존재, 경로가 HEAD 에는 없지만 worktree
#     에는 물리적으로 존재 — 예: 완전 신규 untracked 파일, s4 시나리오):
#     "fatal: path '<path>' exists on disk, but not in 'HEAD'"
#   * `show HEAD:<path>` (HEAD 자체가 없음 — 초기 커밋 전 unborn 브랜치):
#     "fatal: invalid object name 'HEAD'."
#   * `cat-file blob :0:<path>` (경로가 index 에 없고, 그 경로가 worktree
#     에도 없음 — 예: committed 저장소에서 완전 미지의 경로):
#     "fatal: path '<path>' does not exist (neither on disk nor in the index)"
#   * `cat-file blob :0:<path>` (경로가 index 에는 없지만 worktree 에는
#     물리적으로 존재 — 예: 완전 신규 untracked 파일, s4 시나리오):
#     "fatal: path '<path>' exists on disk, but not in the index"
#
# (재현 회귀, 둘 다 2026-08-20 같은 수리 세션에서 실측으로 드러남: "경로가
# worktree 에 물리적으로 존재하는 untracked 파일" 변형 문구를 처음에
# 놓쳐, s4 시나리오(`test_s4_untracked_new_file_has_no_authority_and_
# warns`)와 실 CLI 회귀 스위트(`tests/cli/test_run_event_over_blocking_
# regression.py`, `_write_policy_dir()` 가 project_root 하위에 물리적
# untracked `_version.yaml` 을 두는 고정 픽스처)가 모두 ABSENT 대신
# ERROR 로 오분류되어 RED 로 드러났다 — 각 명령 쌍이 "in 'HEAD'"/"in
# the index" 를 공통 부분 문자열로 공유하므로 그것으로 통일해 두 변형을
# 한 marker 로 함께 포착한다.)
#
# 이 목록에 없는 비0 종료(손상된 저장소·권한 오류·그 밖의 예기치 못한
# 실패)는 전부 ERROR(모호한 실패)로 분류된다 — 신규 marker 추가는 반드시
# 같은 방식의 실측을 거쳐야 하며 문구를 추측해 넣지 않는다.
_ABSENT_MARKERS_TOPLEVEL = ("not a git repository",)
_ABSENT_MARKERS_HEAD_SHOW = (
    "in 'HEAD'",
    "invalid object name 'HEAD'",
)
_ABSENT_MARKERS_INDEX_CATFILE = (
    "in the index",
)


def _run_git_lifecycle_query(args, cwd, absent_markers):
    """정책 버전 git 수명주기 판정 전용 3상태 조회 — FOUND/ABSENT/ERROR.

    `_run_git()`(불변, bytes-or-None)은 "성공"과 "실패"만 구분하고, 그
    실패의 원인(진짜 부재 vs 확인 자체의 실패)을 뭉갠다. 이 헬퍼는 그
    실패를 다시 둘로 쪼갠다.

    반환: `(state, stdout_bytes)`.

    - `(_GIT_QUERY_FOUND, stdout_bytes)` — git 이 exit 0 으로 성공했다.
      `stdout_bytes` 는 항상 bytes(내용이 비어 있으면 `b""`) — 아래
      두 상태의 `None` 과 값 공간이 겹치지 않는다.
    - `(_GIT_QUERY_ABSENT, None)` — git 이 정상적으로 실행되어 비0(전형
      적으로 128)으로 종료했고, stderr 가 `absent_markers` 중 하나를
      포함한다 — git 스스로 "이 시점에 이 경로/오브젝트가 없다"고 명시
      적으로 확인해 준 경우만 이 상태로 분류한다.
    - `(_GIT_QUERY_ERROR, None)` — 그 밖 전부: `OSError`/
      `subprocess.TimeoutExpired` 로 프로세스 자체가 실행되지 못했거나,
      git 이 비0 으로 종료했지만 stderr 에 명시 부재 신호가 없는 경우
      (손상된 저장소·권한 오류·그 밖의 예기치 못한 실패). 이 상태는
      "확인해 봤더니 없더라"가 아니라 "확인 자체가 실패했다"는 뜻이므로,
      호출자는 부재(ABSENT)로 흡수하면 안 되고 반드시
      `PolicyVersionGitStateError` 로 fail-closed 해야 한다.
    """
    try:
        proc = subprocess.run(
            ("git",) + tuple(args),
            cwd=cwd,
            capture_output=True,
            timeout=_GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return _GIT_QUERY_ERROR, None
    if proc.returncode == 0:
        return _GIT_QUERY_FOUND, proc.stdout
    stderr_text = (
        proc.stderr.decode("utf-8", "replace") if proc.stderr else ""
    )
    if any(marker in stderr_text for marker in absent_markers):
        return _GIT_QUERY_ABSENT, None
    return _GIT_QUERY_ERROR, None


def _resolve_git_toplevel(cwd):
    """`git rev-parse --show-toplevel` 전용 헬퍼 — "확실히 비-git 문맥"과
    "판정 자체가 실패했다"(timeout·프로세스 오류·그 밖의 비0 종료)를
    구분해 반환한다 (리뷰 지적 수리, 2026-08-20).

    `_run_git()` 의 bytes-or-None 계약은 이 둘을 구분하지 못한다 —
    `resolve_policy_version_digest_scope()`/`resolve_policy_version_for_
    absent_worktree()` 는 "이 경로가 git 작업 트리 밖" 이라고 확인된
    경우에만 s5(비 git 문맥, worktree 직접 읽기 신뢰)로 내려가야 하는데,
    수리 전에는 실행 실패까지 같은 `None` 으로 뭉뚱그려 s5 로 오판했다
    — 리뷰어 재현: strict 로 committed 된 저장소에서 미스테이징 편집이
    있는 상태(정상 경로라면 s3, fail-closed)일 때 최초 git 조회가
    timeout 등으로 실패하면, 그 미스테이징(신뢰할 수 없는) worktree
    내용을 그대로 신뢰해 strict → sensitive 로 조용히 강등했다.

    (2026-08-20 후속 수리로 내부 구현이 공용 3상태 헬퍼
    `_run_git_lifecycle_query()` 위로 옮겨졌다 — 이 함수의 반환 계약
    (아래 3-tuple 중 앞 두 원소)과 호출자 계약은 바뀌지 않았다, 순수 내부
    리팩터.)

    `cwd` 자체가 존재하지 않는 경우는 세 번째 상태로 분리한다:
    `subprocess.run(cwd=<존재하지 않는 경로>)` 는 git 프로세스를
    실행하기도 전에 `FileNotFoundError`(OSError)를 던진다 — git 이
    실행되어 응답한 게 아니라 실행이 시도조차 되지 않은 것이다. 이
    구분이 없으면 호출자가 "판정 실패"(아래 항목)로 오분류해 git 조회를
    지목하는 fail-closed 문구를 내는데, 실제 원인은 그 경로가 없다는
    것뿐이다 — git 을 지목하면 사용자가 엉뚱한 곳을 디버깅하게 된다.

    반환: `(toplevel, confirmed_non_git, cwd_missing)` 3-tuple.

    - 성공(git 작업 트리 안): `(toplevel_경로_bytes, False, False)`.
    - **확실히 비-git**(git 이 정상적으로 실행되어 스스로 "not a git
      repository" 로 응답 — 전형적으로 exit 128 + 그 문구가 포함된
      stderr): `(None, True, False)`. 이 신호만 s5 판정의 근거로
      인정한다.
    - **`cwd` 자체가 존재하지 않음**(`os.stat` 이 ENOENT — git 은 호출되지
      않았다. 접근 불가·일반 파일 등 다른 OSError 는 이 상태가 아니라 아래
      판정 실패로 흐른다):
      `(None, False, True)`. 호출자는 이를 "git 조회 실패"와 별개로
      취급해, 그 경로가 없다는 것을 명시한 fail-closed 오류를 내야
      한다 — "git query failed"/"unable to confirm" 류의 문구로
      뭉뚱그리면 안 된다.
    - **판정 실패**(`OSError`/`subprocess.TimeoutExpired` 로 프로세스
      자체가 실행되지 못했거나, git 이 실행은 됐지만 "not a git
      repository" 가 아닌 다른 사유로 비0 종료 — 예: 손상된 저장소,
      권한 오류, 그 밖의 예기치 못한 실패): `(None, False, False)`. 이
      조합은 "비-git 이라고 결론 낼 근거가 없다" 는 뜻이다 — 호출자는
      이 조합을 s5 로 흡수하면 안 되고 fail-closed 해야 한다(위 재현
      시나리오의 바로 그 결함).
    """
    if cwd is not None:
        try:
            os.stat(cwd)
        except FileNotFoundError:
            # 진짜 부재 또는 매달린(dangling) 심볼릭 링크 — 둘 다 git 을
            # 실행할 수 없는 "경로 해소 불가" 상태다. 호출자 문구가 둘을
            # 구분해 안내한다(_policy_dir_missing_error).
            return None, False, True
        except OSError:
            # 경로는 있으나 접근 불가·일반 파일 등 — "존재하지 않음" 이
            # 아니므로 아래 git 조회로 넘겨 ERROR(판정 실패, fail-closed)
            # 분기가 처리하게 둔다.
            pass
    state, stdout = _run_git_lifecycle_query(
        ("rev-parse", "--show-toplevel"), cwd, _ABSENT_MARKERS_TOPLEVEL
    )
    if state == _GIT_QUERY_FOUND:
        return stdout, False, False
    if state == _GIT_QUERY_ABSENT:
        return None, True, False
    return None, False, False


def _read_bounded(handle, path, max_bytes):
    """handle 을 청크 단위로 읽어 max_bytes 상한을 강제한다.

    상한을 넘는 순간 남은 내용을 읽지 않고 ContentSizeExceededError 를
    던진다 (조용한 절단 금지 — 모듈 docstring 참조). 정상 크기 파일은
    materialize 된 bytes 를 그대로 돌려준다 (kernel 계약).
    """
    chunks = []
    total = 0
    while True:
        chunk = handle.read(_READ_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise ContentSizeExceededError(
                "{!r} exceeds {} byte content cap".format(path, max_bytes)
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _blob_size(spec, cwd):
    """`git cat-file -s <spec>` — 단일 오브젝트의 크기(바이트).

    `--batch-check` 의 단일 오브젝트 등가물이다: 오브젝트 본문을 전혀
    읽지 않고 크기만 얻어 상한 초과 여부를 먼저 판단할 수 있게 한다.
    오브젝트가 없거나 git 해석에 실패하면 None.
    """
    out = _run_git(("cat-file", "-s", spec), cwd=cwd)
    if out is None:
        return None
    try:
        return int(out.strip())
    except ValueError:
        return None


def _parse_worktree_status(out):
    """Shared porcelain -z parser — returns ``(paths, deleted_not_readded)``.

    Factored out of ``worktree_changeset()`` so ``worktree_deleted_paths()``
    (below) parses the exact same record shape rather than duplicating the
    token-walk logic.

    ``deleted_not_readded`` is the set of paths whose INDEX column (the
    first of the two status-field characters, ``XY``) is ``D`` — staged for
    deletion relative to HEAD — and which are NOT ALSO reported as a
    separate ``??`` record for the same path. A path can appear twice: a
    tracked file removed via ``git rm --cached`` while the on-disk copy
    survives is reported as ``D `` alone when that path is now gitignored
    (no re-surfacing), but as BOTH ``D `` and ``??`` when it is not ignored
    (git treats the surviving on-disk copy as a new untracked file). Only
    the first case belongs in this set — the second means the on-disk
    content is authoritative again.
    """
    paths = []
    deleted = set()
    untracked = set()
    tokens = out.split(b"\0")
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if len(token) < 4:
            # 빈 꼬리 토큰 또는 형식 밖 레코드 — 보수적으로 건너뜀
            continue
        status_field = token[:2].decode("ascii", "replace")
        path = os.fsdecode(token[3:])
        paths.append(path)
        # Exactly "D " (deleted in the index, worktree unchanged). Unmerged
        # records that also start with D ("DU"/"DD") are conflicts whose
        # on-disk content IS authoritative — never suppress them.
        if status_field == "D ":
            deleted.add(path)
        if status_field == "??":
            untracked.add(path)
        if any(char in status_field for char in _RENAME_STATUS_CHARS):
            if index < len(tokens) and tokens[index]:
                paths.append(os.fsdecode(tokens[index]))
            index += 1
    return paths, (deleted - untracked)


def worktree_changeset(cwd=None):
    """WORKTREE ChangeSet — HEAD 대비 작업 트리의 변경 경로 전부.

    staged/unstaged/untracked 를 모두 포함한다 (작업 트리의 현재 상태가
    Enforcement 대상이므로). rename/copy 는 새 경로와 원본 경로를 둘 다
    포함한다 — 원본은 내용 공급자가 None(부재)으로 답한다.
    """
    out = _run_git(
        ("status", "--porcelain", "-z", "--untracked-files=all"), cwd=cwd
    )
    if out is None:
        return None
    paths, _deleted_not_readded = _parse_worktree_status(out)
    return ChangeSet(scope=SCOPE_WORKTREE, paths=tuple(paths))


def worktree_deleted_paths(cwd=None):
    """Paths staged for deletion (index column ``D``) that are NOT also
    re-surfaced as untracked (``??``) in the current worktree status
    (2026-09-04 review-digest self-invalidation fix).

    Used by ``changeset_digest()``'s WORKTREE branch to suppress reading
    on-disk content for a path git itself considers deleted — without this,
    `git rm --cached` on a gitignored path (the file survives on disk, and
    because it is ignored git does not re-report it as untracked) leaves
    the WORKTREE content reader still opening that on-disk file, so its
    every rewrite moves the digest despite the deletion being staged.

    This runs its own single ``git status`` call rather than reusing a
    caller-supplied ``ChangeSet`` — `review_digest()` / `sensitive_security_
    digest()` construct a FRESH filtered ``ChangeSet`` (allowlist/tag
    filtering) before calling `changeset_digest()`, discarding whatever a
    prior `worktree_changeset()` call parsed. `cwd` is the one input stable
    across every such call site, so deriving the suppression set here (by
    `cwd`, on demand) is smaller than threading a deleted-paths parameter
    through every WORKTREE digest call site and every re-filter step.
    Returns None when the status query itself fails (non-repo, timeout,
    execution error) — a missing fact, never an empty set: an empty set
    would let the digest silently re-hash on-disk content of staged-deleted
    paths, which is exactly the self-invalidation this suppression exists
    to stop. `changeset_digest()` propagates None as "digest unresolved".
    """
    out = _run_git(
        ("status", "--porcelain", "-z", "--untracked-files=all"), cwd=cwd
    )
    if out is None:
        return None
    _paths, deleted_not_readded = _parse_worktree_status(out)
    return frozenset(deleted_not_readded)


def staged_changeset(cwd=None):
    """STAGED ChangeSet — index 에 올라간 변경 경로 (HEAD 대비)."""
    out = _run_git(("diff", "--cached", "--name-only", "-z"), cwd=cwd)
    if out is None:
        return None
    paths = tuple(
        os.fsdecode(token) for token in out.split(b"\0") if token
    )
    return ChangeSet(scope=SCOPE_STAGED, paths=paths)


def worktree_content_reader(
    cwd=None, max_bytes=_MAX_CONTENT_BYTES, suppressed_paths=None
):
    """WORKTREE 내용 공급자 — 작업 트리 파일을 그대로 읽는다.

    kernel `content_digest` 주입 계약: path -> bytes | None. 레포
    최상위를 해석하지 못하면 None (fact 부재). 심볼릭 링크는 follow 하지
    않는다 — git 의 심링크 blob(mode 120000)과 같이 타깃 경로 문자열만
    해싱한다 (모듈 docstring "심볼릭 링크" 절 참조). 일반 파일이 아닌
    특수 파일(FIFO/소켓/디바이스/디렉토리 등)은 open() 을 시도하지 않고
    None (모듈 docstring "특수 파일 — 심링크 미경유" 절 참조 — FIFO
    open() 의 무기한 블로킹 DoS 방지). max_bytes 초과 파일은
    ContentSizeExceededError.

    `suppressed_paths` (2026-09-04 review-digest self-invalidation fix) —
    an optional set of paths (typically `worktree_deleted_paths()`'s
    result) that read as absent (None) WITHOUT ever stat()-ing or
    open()-ing the on-disk file, regardless of what is actually sitting
    there. This is how a staged deletion (`git rm --cached`) of a
    gitignored path stops its surviving on-disk copy from feeding the
    digest — see `worktree_deleted_paths()`'s own docstring for why git
    itself does not already surface this as an absence.
    """
    out = _run_git(("rev-parse", "--show-toplevel"), cwd=cwd)
    if out is None:
        return None
    toplevel = os.fsdecode(out).strip()
    if not toplevel:
        return None
    suppressed = suppressed_paths if suppressed_paths else frozenset()

    def read_content(path):
        if path in suppressed:
            return None
        full_path = os.path.join(toplevel, path)
        try:
            st = os.stat(full_path, follow_symlinks=False)
        except OSError:
            return None
        if stat.S_ISLNK(st.st_mode):
            try:
                return os.fsencode(os.readlink(full_path))
            except OSError:
                return None
        if not stat.S_ISREG(st.st_mode):
            # FIFO/소켓/디바이스/디렉토리 — open() 을 시도하지 않는다
            # (FIFO 는 writer 없는 open() 이 무기한 블로킹될 수 있음).
            return None
        try:
            with open(full_path, "rb") as handle:
                return _read_bounded(handle, path, max_bytes)
        except OSError:
            return None

    return read_content


def staged_content_reader(cwd=None, max_bytes=_MAX_CONTENT_BYTES):
    """STAGED 내용 공급자 — index (stage 0) 의 blob 을 읽는다.

    worktree 후속 편집·touch 는 결과에 개입하지 못한다 (내용 기준).
    index 에 없는 경로(예: staged 삭제)는 None (부재). 레포 자체를
    해석하지 못하면 공급자 대신 None (fact 부재 — worktree 쪽과 일관).
    본문을 읽기 전에 `git cat-file -s` 로 크기를 먼저 확인하고,
    max_bytes 초과 시 본문 조회 자체를 생략하고 ContentSizeExceededError.
    """
    if _run_git(("rev-parse", "--show-toplevel"), cwd=cwd) is None:
        return None

    def read_content(path):
        spec = ":0:{}".format(path)
        size = _blob_size(spec, cwd)
        if size is None:
            return None
        if size > max_bytes:
            raise ContentSizeExceededError(
                "staged blob {!r} exceeds {} byte content cap "
                "({} bytes)".format(path, max_bytes, size)
            )
        return _run_git(("cat-file", "blob", spec), cwd=cwd)

    return read_content


def changeset_digest(changeset, cwd=None, max_bytes=_MAX_CONTENT_BYTES):
    """ChangeSet 의 내용 기반 digest — scope 에 맞는 공급자를 결합.

    v2.0 Enforcement Scope 는 WORKTREE/STAGED — 그 밖의 scope 또는
    해석 불가 시 None (fact 부재). max_bytes 초과 내용은
    ContentSizeExceededError 로 전파된다 (부재로 조용히 흡수하지 않음).

    WORKTREE 분기는 `worktree_deleted_paths(cwd)` 로 스테이징된 삭제
    경로(무시되는 파일이라 '??' 로 재등장하지 않는 것만)를 별도 조회해
    content reader 에 넘긴다 — 한 번의 추가 `git status` 호출(2026-09-04
    review-digest 자기무효화 수리). 그 조회가 실패하면(None) digest 도
    None(부재) — 빈 억제 집합으로 계속하면 삭제 예정 파일 내용을 다시
    해싱해 이 수리의 목적 자체가 무효화된다. `changeset` 인스턴스에서 직접
    파생하지 않는 이유: `review_digest()`/`sensitive_security_digest()`
    가 허용목록/태그 필터링 후 **새** `ChangeSet` 을 만들어 이 함수에
    넘기므로(원본 인스턴스에 무언가를 붙여도 그 시점에 소실), 모든
    WORKTREE 호출부에서 안정적인 입력은 `cwd` 뿐이다 — 매 필터링 단계마다
    삭제 집합을 threading 하는 것보다 이 조회 하나가 더 작은 변경이다.
    """
    if changeset is None:
        return None
    if changeset.scope == SCOPE_WORKTREE:
        suppressed = worktree_deleted_paths(cwd=cwd)
        if suppressed is None:
            # The suppression query failed after the changeset itself was
            # resolved — treat the digest as absent rather than hashing
            # content the caller may have staged for deletion.
            return None
        reader = worktree_content_reader(
            cwd=cwd, max_bytes=max_bytes, suppressed_paths=suppressed
        )
    elif changeset.scope == SCOPE_STAGED:
        reader = staged_content_reader(cwd=cwd, max_bytes=max_bytes)
    else:
        return None
    if reader is None:
        return None
    return content_digest(changeset.paths, reader)


def changeset_tag(changeset, tag_rules=None):
    """ChangeSet 의 단일 Tag — 전부 같은 Tag 로 분류될 때만 값을 낸다.

    testing capability 의 `changeset.tag` fact 계약(`rein.capabilities.
    testing.capability.FACT_CHANGESET_TAG`) — 값은 `rein.engine.tags.
    TAG_NAMES` 중 하나이거나 판정 불가(`None`)여야 한다. 분류는 `rein.
    engine.tags.classify_path` 를 그대로 재사용한다(재구현 금지 —
    Tag 분류의 유일한 SSOT).

    **설계 결정 (혼합 ChangeSet)**: `paths` 전부가 정확히 같은 Tag 로
    분류될 때만 그 Tag 를 반환한다. 하나라도 다른 Tag 이거나
    무매치(`classify_path` 가 `None`)면 전체를 `None`(판정 불가)으로
    반환한다 — 부분 일치를 관대하게 승격하지 않는다. 이는 testing
    capability 의 발급측 검증(`observe_test_run` → `_verify_paths_
    classify_to_tag`)이 "선언된 tag 로 전부 재분류되지 않으면 거부"
    하는 것과 동일한 보수적 방향이다 — 혼합 ChangeSet 에 임의의 한
    Tag 를 배정하면, 그 Tag 로 발급된 evidence 가 실제로는 다른 성격의
    변경까지 우연히 통과시키는 경로가 열린다(spec §3.4 "확인 불가 ≠
    충족" 원칙의 이 fact 판). 평가 시점 소비자(`TestsPassedRequirement.
    evaluate`)는 `current_tag` 가 falsy(`None` 포함)면 그 축을 미확보로
    보고 보수적으로 미충족 처리하므로, 혼합 상태에서 `None` 을 반환하는
    것은 "이 ChangeSet 에 대해서는 어떤 Tag 로도 tests_passed 증거를
    재확인할 수 없다"는 의도된 결과다.

    `tag_rules` 미지정 시 배포 기본값(`policies/tags.yaml`)을 매 호출
    마다 새로 읽는다 — 반복 호출이 예상되는 hot path(예: 같은 cycle 안
    여러 policy 평가)에서는 호출자가 `load_tag_rules()` 결과를 한 번만
    계산해 명시적으로 넘기는 편이 파일 재읽기 비용을 피한다(비용 메모,
    이 함수 docstring 하단 "비용" 참조 — 이 함수 자신은 request-scoped
    캐시를 갖지 않는다, 그 책임은 fact resolver 배선 계층).

    `changeset` 이 `None` 이거나 `paths` 가 비어 있으면 판정할 대상이
    없으므로 `None`.

    비용: `tag_rules` 가 주어지면 순수 문자열 매칭(cheap). 주어지지
    않으면 `load_tag_rules()` 의 파일 I/O + YAML subset 파싱이 매 호출
    마다 발생한다(호출자가 캐시해 재사용 권장).
    """
    if changeset is None:
        return None
    paths = changeset.paths
    if not paths:
        return None
    if tag_rules is None:
        tag_rules = load_tag_rules()
    classified = set()
    for path in paths:
        tag = classify_path(path, tag_rules)
        if tag is None:
            return None
        classified.add(tag)
        if len(classified) > 1:
            return None
    if len(classified) != 1:
        return None
    return next(iter(classified))


# ---------------------------------------------------------------------------
# strict digest scope (spec §3.6 "digest scope 프로필" 절, 2026-08-19).
#
# `sensitive` 프로필(기존 의미론)과 이원화되는 두 번째 subject digest
# 산정 방식 — staged 변경 **전체**에서 검토 면제 허용목록을 제외한
# 집합을 subject 로 삼는다. 어느 정책 폴더가 이 프로필을 쓸지는
# `rein.kernel.policy.load_policy_version().digest_scope` 가 결정한다
# (이 모듈은 프로필 선택을 모른다 — 여기는 `strict` 산정 함수 자체만
# 제공한다. 프로필별 분기·capability 배선은 이 워커의 scope 밖).
#
# 허용목록은 v1 `hooks/lib/security-review-gate.sh` 의 면제 판정을
# 그대로 재현한다(재구현이 아니라 동일 판정을 python 으로 옮긴 것) —
# `_sx_path_is_doc_or_trail`(L479-489)/`_sx_version_only_rein_sh`
# (L491-517)/`_sx_version_only_plugin_json`(L519-559)/
# `_sx_classify_paths`(L561-620 부근). **v1 명령 형태 검사
# (`_sx_command_has_eval` 류 TOCTOU 가드)는 이관하지 않는다** — spec
# §3.6 "digest scope 프로필" 절의 명시 비계승 결정(subject digest
# 산정만 재현, 명령 형태 판정은 별개 관심사로 두고 재구현하지 않는다).

# `scripts/rein.sh` VERSION="..." 라인 판정 — v1 `_sx_version_only_rein_sh`
# 의 `grep -qE '^[[:space:]]*VERSION="[^"]*"[[:space:]]*$'` 과 동일 패턴.
_STRICT_VERSION_LINE_PATTERN = re.compile(r'^\s*VERSION="[^"]*"\s*$')


def _strict_acquire_staged_paths(cwd=None):
    """strict scope 의 staged 경로 목록 — `git diff --cached --name-status -M -z`.

    rename/copy(`R`/`C`)는 원본·신규 경로 둘 다 포함한다(v1
    `_sx_acquire_staged_paths` 와 동일 — 파일이 sensitive 위치에서
    허용목록처럼 보이는 이름으로 이동해도 원본 경로가 여전히
    비허용목록으로 잡힌다). git 호출 실패·레코드 파싱 불가는 `None`
    (호출자가 `SUBJECT_UNRESOLVED` 로 승격 — fail-closed). staged 변경이
    전혀 없으면 빈 tuple(파싱 성공, 대상 0개 — 호출자가 이를
    `SUBJECT_EMPTY` 로 승격한다).
    """
    out = _run_git(
        ("diff", "--cached", "--name-status", "-M", "-z"), cwd=cwd
    )
    if out is None:
        return None
    tokens = out.split(b"\0")
    paths = []
    index = 0
    total = len(tokens)
    while index < total:
        status_token = tokens[index]
        index += 1
        if not status_token:
            # `-z` 출력은 항상 트레일링 NUL 로 끝나므로 split 의 마지막
            # 원소는 빈 문자열이다 — 그 위치에서만 정상 종료. 중간에
            # 나타나면 레코드 경계가 어긋난 것이므로 파싱 실패.
            if index == total:
                break
            return None
        status_char = status_token[:1].decode("ascii", "replace")
        if index >= total:
            return None  # status 뒤에 경로가 없음 — 파싱 실패
        path_token = tokens[index]
        index += 1
        if not path_token:
            return None
        paths.append(os.fsdecode(path_token))
        if status_char in _RENAME_STATUS_CHARS:
            if index >= total:
                return None
            new_path_token = tokens[index]
            index += 1
            if not new_path_token:
                return None
            paths.append(os.fsdecode(new_path_token))
    return tuple(paths)


def _strict_path_is_allowlisted_doc_or_trail(path):
    """spec §3.6 허용목록 ⓐⓑ — `*.md`(임의 위치) / `docs/**` / `trail/**`.

    v1 `_sx_path_is_doc_or_trail` 과 동일 판정: `.md` 확장자는 경로 내
    위치 무관 허용(단순 접미사 검사), `docs/`·`trail/` 은 그 prefix 로
    시작하는 모든 하위 경로(재귀)를 허용한다.
    """
    if path.endswith(".md"):
        return True
    if path.startswith("docs/"):
        return True
    if path.startswith("trail/"):
        return True
    return False


def _strict_version_only_rein_sh(cwd=None):
    """`scripts/rein.sh` staged diff — 추가/삭제 라인 전부가 `VERSION="..."`
    형태일 때만 True (v1 `_sx_version_only_rein_sh` 재현). 변경 라인이
    0개(빈 diff)·git 호출 실패는 False(비허용 — fail-closed).
    """
    diff = _run_git(
        ("diff", "--cached", "--", _STRICT_VERSION_ONLY_REIN_SH), cwd=cwd
    )
    if not diff:
        return False
    try:
        text = diff.decode("utf-8")
    except UnicodeDecodeError:
        return False
    changed = 0
    for line in text.split("\n"):
        if line.startswith("+++ ") or line.startswith("--- "):
            continue
        if not (line.startswith("+") or line.startswith("-")):
            continue
        changed += 1
        body = line[1:]
        if not _STRICT_VERSION_LINE_PATTERN.match(body):
            return False
    return changed > 0


def _strict_version_only_plugin_json(cwd=None):
    """plugin manifest staged diff — top-level `version` 키만 다르면 True
    (v1 `_sx_version_only_plugin_json` 재현). staged/HEAD 양쪽을 JSON
    dict 로 파싱해 `version` 외 모든 키·값(중첩 포함)이 동일할 때만
    허용한다. git 호출 실패·JSON 파싱 실패·키 집합 불일치·다른 키 값
    차이는 전부 False(비허용 — fail-closed).
    """
    pj = _STRICT_VERSION_ONLY_PLUGIN_JSON
    staged = _run_git(("show", ":{}".format(pj)), cwd=cwd)
    head = _run_git(("show", "HEAD:{}".format(pj)), cwd=cwd)
    if not staged or not head:
        return False
    try:
        staged_obj = json.loads(staged.decode("utf-8"))
        head_obj = json.loads(head.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False
    if not isinstance(staged_obj, dict) or not isinstance(head_obj, dict):
        return False
    if set(staged_obj.keys()) != set(head_obj.keys()):
        return False
    for key in head_obj:
        if key == "version":
            continue
        if staged_obj.get(key) != head_obj.get(key):
            return False
    if "version" not in staged_obj or "version" not in head_obj:
        return False
    return True


def strict_security_subject_paths(cwd=None):
    """strict profile 이 실제로 digest 로 흡수하는 경로 집합 (단일 정본).

    **Phase 7 웨이브 3 ③-a 리팩토링** (`--print-subject security_review`
    도입에 따른 분리) — 이 함수 하나가 "strict security digest 의 subject
    는 어떤 경로들인가"를 결정하고, `strict_security_subject()`/
    `strict_security_digest()`(아래) 와 `rein.cli.issue_evidence.
    print_subject()` 가 전부 이 함수(정확히는 아래 `strict_security_
    subject()`)를 거쳐 digest 를 쌓는다 — `review_subject_paths()` 가
    code_review 에 대해 하는 역할과 동일한 이유(허용목록/sensitive-우선
    판정을 두 곳에 나눠 두면 발산 위험이 생긴다).

    판정 로직 자체(sensitive 우선 → 허용목록 → 버전-only 특례)는 기존
    `strict_security_digest()` 몸체를 그대로 옮긴 것 — 새 판정을 도입하지
    않는다.

    반환: staged 경로 획득(git 호출/파싱) 자체가 실패하면 `None`(호출자가
    `SUBJECT_UNRESOLVED` 로 승격). 파싱 성공이면 비허용 경로의 tuple(빈
    tuple 이면 전부 허용 — 호출자가 `SUBJECT_EMPTY` 로 승격).
    """
    paths = _strict_acquire_staged_paths(cwd=cwd)
    if paths is None:
        return None

    tag_rules = load_tag_rules()
    non_allowed = []
    version_ok_cache = {}
    for path in paths:
        if classify_path(path, tag_rules) == TAG_SENSITIVE:
            # sensitive 분류는 허용목록보다 우선한다 — 문서/trail 경로
            # 모양이어도 검토 대상에서 빠지지 않는다(strict_security_
            # subject() docstring 의 "sensitive 분류 우선" 절 참조).
            non_allowed.append(path)
            continue
        if _strict_path_is_allowlisted_doc_or_trail(path):
            continue
        if path == _STRICT_VERSION_ONLY_REIN_SH:
            if path not in version_ok_cache:
                version_ok_cache[path] = _strict_version_only_rein_sh(
                    cwd=cwd
                )
            if version_ok_cache[path]:
                continue
            non_allowed.append(path)
            continue
        if path == _STRICT_VERSION_ONLY_PLUGIN_JSON:
            if path not in version_ok_cache:
                version_ok_cache[path] = _strict_version_only_plugin_json(
                    cwd=cwd
                )
            if version_ok_cache[path]:
                continue
            non_allowed.append(path)
            continue
        non_allowed.append(path)

    return tuple(non_allowed)


def strict_security_subject(cwd=None, max_bytes=_MAX_CONTENT_BYTES):
    """strict profile 의 (subject, paths) 를 **단일 스냅샷**에서 함께 반환한다.

    High finding (Phase 7 웨이브 3 ③-a, code review round 3) — 예전에는
    digest 조회(`strict_security_digest()`)와 경로 조회를 별도 호출로
    나누면, 두 호출 사이에 staged 상태가 바뀔 수 있어(비원자적) digest 가
    실제로 증명하는 경로와 호출자가 "인증됐다"고 믿는 경로가 갈라질 수
    있었다. 이 함수는 `strict_security_subject_paths()` 로 staged 경로를
    **한 번만** 획득하고, 그 결과 위에서 곧바로 digest 를 쌓는다 — 두 값이
    항상 같은 `git diff --cached` 호출 결과에서 나온다.

    반환: `(subject, paths)`. `subject` 는 `SUBJECT_UNRESOLVED`/
    `SUBJECT_EMPTY` 또는 `"sha256:<hex>"` digest 문자열. `paths` 는
    `subject` 가 실제 digest 문자열일 때만 그 digest 가 흡수한 경로
    tuple 이고, 센티널이면 빈 tuple(호출자 계약 — "sentinel subject →
    paths 빈 값", `--print-subject` 인터페이스 계약과 동일 방향).

    **sensitive 분류 우선 (spec §3.6 리뷰 보강, 2026-08-20 — 보수 불변식
    strict ⊇ sensitive)**: 태그 규칙(`rein.engine.tags`, `policies/
    tags.yaml` 소비)상 `TAG_SENSITIVE` 로 분류되는 경로는 문서/trail
    허용목록·버전-only 특례보다 **먼저** 검토 대상으로 확정한다 —
    `strict_security_subject_paths()` 의 루프가 허용목록 판정보다
    sensitive 판정을 먼저 검사하는 이유다. `docs/.env`·`trail/.npmrc`·
    `secrets/runbook.md` 처럼 경로가 문서 계열 접두어(`docs/`/`trail/`)나
    확장자(`.md`)를 갖더라도, basename 이 sensitive 패턴(`.env`/`.npmrc`/
    `*credentials*` 등)과 매치하면 `classify_path`(policies/tags.yaml 의
    sensitive 블록이 항상 최우선 선언돼 있다 — 그 파일 자체의 주석 "겹칠
    시 최우선" 참조) 는 이미 `TAG_SENSITIVE` 를 반환한다. sensitive 분류
    로직 자체는 재구현하지 않는다 — 기존 `rein.engine.tags.classify_path`/
    `load_tag_rules`(이미 이 모듈 상단에서 import, `changeset_tag()` 가
    재사용하는 것과 동일한 소비 경로)를 그대로 호출한다.
    """
    non_allowed = strict_security_subject_paths(cwd=cwd)
    if non_allowed is None:
        return SUBJECT_UNRESOLVED, ()
    if not non_allowed:
        return SUBJECT_EMPTY, ()

    changeset = ChangeSet(scope=SCOPE_STAGED, paths=non_allowed)
    digest = changeset_digest(changeset, cwd=cwd, max_bytes=max_bytes)
    if digest is None:
        return SUBJECT_UNRESOLVED, ()
    return digest, non_allowed


def strict_security_digest(cwd=None, max_bytes=_MAX_CONTENT_BYTES):
    """strict digest scope 의 subject digest (spec §3.6, closed-value 계약).

    **Phase 7 웨이브 3 ③-a 리팩토링** — 실제 판정/계산은 이제
    `strict_security_subject()`(바로 위) 하나로 합류했다. 이 함수는 기존
    호출자(`_resolve_sensitive_digest`/`issue_evidence._current_subject_
    digest` 등 digest 문자열 하나만 필요한 소비처) 하위호환을 위해 그
    결과의 첫 원소만 반환하는 얇은 래퍼다 — 새 판정 로직을 여기 두지
    않는다(단일 정본, 발산 금지). 반환값 3종류(`SUBJECT_EMPTY`/
    `SUBJECT_UNRESOLVED`/실 digest 문자열)와 sensitive 우선 불변식의 전체
    설명은 `strict_security_subject_paths()`/`strict_security_subject()`
    docstring 참조.
    """
    subject, _paths = strict_security_subject(cwd=cwd, max_bytes=max_bytes)
    return subject


# ---------------------------------------------------------------------------
# code_review subject digest — "리뷰 digest 범위" (spec §3.6, 2026-08-20
# 보강, Phase 7 웨이브 3 ③-a).
#
# 배선 전 구현은 code_review 의 subject 를 WORKTREE ChangeSet 전체(trail/
# 하위 운영 기록 포함)의 digest 로 계산했다 — 그 결과 도장·기록 쓰기가
# 증거를 자기무효화해(발급 시점 재계산 불일치) 리뷰→기록→커밋의 정상
# 절차가 자기차단됐다(실측 경위는 spec §3.6 code_review 절 참조). 이
# 함수가 그 결함을 닫는다: WORKTREE ChangeSet(staged/unstaged/untracked
# 포함)에서 검토 면제 허용목록만 뺀 나머지를 subject 로 삼는다.
#
# 허용목록은 strict digest scope 프로필(위 섹션)의 문서/trail 허용목록
# predicate `_strict_path_is_allowlisted_doc_or_trail()` 을 **그대로
# 재사용**한다 — 경계 정본을 하나로 유지하기 위해 패턴을 다시 나열하지
# 않는다. 단 strict 프로필의 **버전-only 특례 2파일 판정은 적용하지
# 않는다** — 그 특례는 보안 검토 면제 전용이고, spec §3.6 은 코드리뷰에
# 대해 "버전 라인 변경도 검토 대상"이라고 명시한다. 마찬가지로 sensitive
# 태그 우선 판정(strict_security_digest 의 sensitive-first 절)도 여기서는
# 재사용하지 않는다 — 그건 strict 프로필이 sensitive ⊆ strict 불변식을
# 지키기 위한 보안 전용 보강이고, spec 이 code_review digest 범위에
# 요구하는 것은 "문서/trail 허용목록만 제외"뿐이다.
def review_subject_paths(changeset):
    """review_digest() 가 다이제스트로 흡수하는 것과 정확히 같은 경로 집합.

    **단일 정본 (Phase 7 웨이브 3 ③-a 정제, code review round 후속)**:
    이 함수 하나가 "review digest 의 subject 는 어떤 경로들인가"를 결정하고,
    `review_digest()`(아래)와 `rein.cli.issue_evidence.print_subject()`
    (`bin/rein issue-evidence code_review --print-subject`, 리뷰
    스킬/래퍼가 소비하는 CLI 표면)가 둘 다 이 함수를 호출한다 — 허용목록
    판정을 두 곳에 나눠 두면(예: bash 래퍼가 패턴을 다시 나열) 그 둘이
    서로 다른 시점에 서로 다른 결론을 낼 수 있고, 그러면 "리뷰어가 실제로
    본 파일" 과 "다이제스트가 증명하는 파일" 이 갈라진다 — 그 갈라짐이
    바로 이 함수가 막는 문제다.

    반환: `changeset` 이 `None`(WORKTREE 해석 자체 실패 — 레포 부재 등)이면
    `None`. 아니면 허용목록(임의 위치 `*.md` / `docs/**` / `trail/**`,
    `_strict_path_is_allowlisted_doc_or_trail` 재사용 — strict security
    digest 프로필과 같은 정본) 제외 후 남은 경로의 정렬된 dedup tuple —
    `content_digest()` 자신이 `sorted(set(paths))` 로 순회하는 것과 동일한
    정규화를 미리 적용해 둔다(`rein.kernel.changeset.content_digest`
    참조) — "review_digest 가 실제로 해싱하는 집합"과 이 함수가 내놓는
    목록이 순서·중복 표현까지 일치한다. 대상이 없으면(전부 허용목록)
    빈 tuple — `SUBJECT_EMPTY` 로 승격하는 것은 이 함수의 소관이 아니다
    (호출자가 각자의 계약대로 번역한다: `review_digest()`는
    `SUBJECT_EMPTY`, `--print-subject` CLI 는 `{"subject": "empty:no-
    subject", "paths": []}`).
    """
    if changeset is None:
        return None
    non_allowed = (
        path
        for path in changeset.paths
        if not _strict_path_is_allowlisted_doc_or_trail(path)
    )
    return tuple(sorted(set(non_allowed)))


def review_digest(changeset, cwd=None, max_bytes=_MAX_CONTENT_BYTES):
    """code_review 의 subject digest (spec §3.6 "리뷰 digest 범위" 절).

    `changeset` — 호출자가 이미 계산한 WORKTREE `ChangeSet`(`rein.cli.
    _git_changeset_facts()` 의 단일 pass 에서 나온 것 — 이 함수가 다시
    `worktree_changeset()` 을 호출해 `git status` 를 재실행하지 않는다,
    비용 재사용). `changeset` 이 `None`(WORKTREE 해석 자체가 실패 —
    레포 부재 등)이면 `SUBJECT_UNRESOLVED`.

    subject 경로 집합 자체는 `review_subject_paths()`(바로 위)에 위임한다
    — 두 함수가 같은 허용목록 계산을 각자 반복하면 divergence 위험이
    생기므로, 이 함수는 그 결과(닫힌 값 None/빈 tuple/non-empty tuple)를
    digest 로 번역만 한다.

    닫힌 값 계약 2상태(`rein.kernel.changeset`): 허용목록 제외 후 대상이
    비면(변경 전부 허용목록) `SUBJECT_EMPTY` — 충족 방향(spec §3.6 "문서·
    기록-only 커밋은 코드리뷰 불요"). 그 부분집합의 digest 계산 자체가
    실패하면(예: 저장소 toplevel 조회 실패) `SUBJECT_UNRESOLVED`. 그 외는
    실제 content digest 문자열(기존 `changeset_digest`/`content_digest`
    재사용 — 새 알고리즘 없음). `ContentSizeExceededError` 류는 여기서
    삼키지 않고 그대로 전파한다(strict_security_digest 와 동일 방향,
    모듈 docstring "내용 크기 상한" 절).
    """
    non_allowed = review_subject_paths(changeset)
    if non_allowed is None:
        return SUBJECT_UNRESOLVED
    if not non_allowed:
        return SUBJECT_EMPTY

    filtered = ChangeSet(scope=changeset.scope, paths=non_allowed)
    digest = changeset_digest(filtered, cwd=cwd, max_bytes=max_bytes)
    if digest is None:
        return SUBJECT_UNRESOLVED
    return digest


# ---------------------------------------------------------------------------
# security_review subject digest — sensitive digest scope 프로필 (기본,
# spec §3.6 "digest scope 프로필" 절). WORKTREE 기준 — strict(위 STAGED
# 기준)와 scope 자체가 다르므로 하나로 통합하지 않는다(기존 `strict_
# security_subject()` 문서화 관례와 동일 사유).
#
# **Phase 7 웨이브 3 ③-a 리팩토링** — 이 절의 두 함수는 새 판정을
# 도입하지 않는다. `rein.cli._git_changeset_facts()` 가 이전에 인라인으로
# 반복하던 "WORKTREE changeset 에서 TAG_SENSITIVE 분류 경로만 남긴다"
# 로직을 이 모듈로 끌어올려 `review_subject_paths()`/`strict_security_
# subject_paths()` 와 동일한 위치(단일 정본)에 둔 것뿐이다 — `_git_
# changeset_facts()` 는 이제 이 함수들을 호출하도록 리팩토링됐다(그
# 함수의 docstring 참조). `--print-subject security_review`(sensitive
# 프로필 분기, `rein.cli.issue_evidence.print_subject()`)도 같은 함수를
# 거친다 — sensitive 축의 "digest 와 경로 목록이 갈라질 수 없다" 불변식이
# code_review/strict 축과 동일하게 성립한다.


def sensitive_security_subject_paths(changeset, tag_rules=None):
    """sensitive profile 이 실제로 digest 로 흡수하는 경로 집합.

    `changeset` 이 `None`(WORKTREE 해석 자체 실패)이면 `None`. 아니면
    태그 규칙상 `TAG_SENSITIVE` 로 분류되는 경로만 남긴 tuple(빈 tuple 이면
    sensitive 경로 없음 — 호출자가 `SUBJECT_EMPTY` 로 승격). `tag_rules`
    생략 시 `load_tag_rules()` 를 직접 호출한다(호출자가 이미 로드해 둔
    규칙이 있으면 재사용 — `changeset_tag()`/`review_subject_paths()` 와
    동일한 "1회 로드, 여러 곳 재사용" 관례).
    """
    if changeset is None:
        return None
    rules = tag_rules if tag_rules is not None else load_tag_rules()
    return tuple(
        path
        for path in changeset.paths
        if classify_path(path, rules) == TAG_SENSITIVE
    )


def sensitive_security_digest(
    changeset, cwd=None, max_bytes=_MAX_CONTENT_BYTES, tag_rules=None
):
    """sensitive profile 의 subject digest — 호출자가 이미 계산한 WORKTREE
    `ChangeSet` 을 그대로 받는다(`review_digest()` 와 동일한 "재사용,
    재계산 아님" 계약 — `rein.cli._git_changeset_facts()` 가 `worktree_
    changeset()` 을 한 번만 호출해 이 함수와 `review_digest()`/
    `changeset_tag()` 모두에 그 결과를 넘긴다).

    닫힌 값 계약 2상태: `changeset` 이 `None` 이면 `SUBJECT_UNRESOLVED`,
    sensitive 경로가 0건이면 `SUBJECT_EMPTY`, 그 부분집합의 digest 계산
    자체가 실패하면(예: 저장소 toplevel 조회 실패) `SUBJECT_UNRESOLVED`.
    그 외는 실제 content digest 문자열.
    """
    sensitive_paths = sensitive_security_subject_paths(
        changeset, tag_rules=tag_rules
    )
    if sensitive_paths is None:
        return SUBJECT_UNRESOLVED
    if not sensitive_paths:
        return SUBJECT_EMPTY

    sensitive_changeset = ChangeSet(
        scope=SCOPE_WORKTREE, paths=sensitive_paths
    )
    digest = changeset_digest(sensitive_changeset, cwd=cwd, max_bytes=max_bytes)
    if digest is None:
        return SUBJECT_UNRESOLVED
    return digest


def sensitive_security_subject(
    cwd=None, max_bytes=_MAX_CONTENT_BYTES, tag_rules=None
):
    """sensitive profile 의 (subject, paths) 를 **단일 스냅샷**에서 함께
    반환한다 — `strict_security_subject()` 의 sensitive-profile 대응.

    이 함수는 (위 `sensitive_security_digest()`/`sensitive_security_
    subject_paths()` 와 달리) 이미 계산된 changeset 을 받지 않고
    `worktree_changeset()` 을 **직접 한 번** 호출한다 — `--print-subject
    security_review`(sensitive 분기, `rein.cli.issue_evidence.
    print_subject()`)가 다른 fact(`changeset.digest`/`changeset.tag`/
    `changeset.review_digest` 등)를 필요로 하지 않는 단독 호출자라서,
    `_git_changeset_facts()` 의 5-tuple 전체를 계산하지 않고 이 경로 하나만
    원자적으로 얻는다(atomic subject snapshot 요구사항, Phase 7 웨이브 3
    ③-a code review round 3 High-1).

    반환: `(subject, paths)`. `paths` 는 `subject` 가 실제 digest 문자열일
    때만 채워지고, 센티널이면 빈 tuple(`strict_security_subject()` 와
    동일한 "sentinel subject → paths 빈 값" 계약).
    """
    changeset = worktree_changeset(cwd=cwd)
    if changeset is None:
        return SUBJECT_UNRESOLVED, ()
    sensitive_paths = sensitive_security_subject_paths(
        changeset, tag_rules=tag_rules
    )
    if not sensitive_paths:
        return SUBJECT_EMPTY, ()

    sensitive_changeset = ChangeSet(
        scope=SCOPE_WORKTREE, paths=sensitive_paths
    )
    digest = changeset_digest(sensitive_changeset, cwd=cwd, max_bytes=max_bytes)
    if digest is None:
        return SUBJECT_UNRESOLVED, ()
    return digest, sensitive_paths


# ---------------------------------------------------------------------------
# 정책 버전 선언(`_version.yaml`)의 git 상태·수명주기 판정 — digest_scope
# 프로필 전용 (spec §3.6 "선언의 유효 기준" 절, 2026-08-20 보강).
#
# 리뷰 지적: worktree 파일을 그대로 읽으면 미커밋 로컬 편집만으로
# strict → sensitive 무음 강등이 가능하다("이 저장소는 strict 로
# 선언돼 있다"고 믿고 있어도, 누군가 로컬에서 `_version.yaml` 을
# 편집해 `digest_scope: sensitive` 로 바꾸면 커밋 직전 게이트가 그
# 편집된(미커밋) 값을 그대로 신뢰했다). 이 절이 고정하는 원칙은
# **git 저장소에서 유효 선언 = HEAD 커밋 내용** — worktree 는 "아직
# 발효되지 않은 미래" 일 뿐이다.
#
# 이 모듈은 spec 이 정의하는 5상태(s1~s5) + malformed 교차 계약
# (m1~m3) 의 **구현**이다 — 정본은 spec 본문. `rein.cli.
# _security_digest_scope_profile()`(+ `_resolve_sensitive_digest` 의
# 캐시 공유 경로)가 이 함수 하나로 합류한다 — **이 함수 자신의 원래
# 지시 범위는 digest_scope 프로필 결정에 한정**됐다: `policy.version`/
# `policy.compatible_versions` fact(code_review/tests_passed/
# user_approval 의 evidence 유효성 판정이 쓴다, `rein.cli.
# _load_policy_version_fact()`)는 원래 이 함수의 관심사가 아니었고
# 건드리지 않았다.
#
# **범위 갱신 (리뷰 지적 수리, 2026-08-20)** — 그런데 `_load_policy_
# version_fact()` 는 여전히 naive `os.path.exists()` 로만 worktree
# 부재를 판정하는 바람에, staged 삭제(s2 — "HEAD 기준 평가가 여전히
# 유효") 상태에서 그 부재를 곧바로 "진짜 미설정"으로 오판해
# `_evaluate_event()` 전체를 조기에 `PolicyVersionError` 로 죽이는
# 결함이 실 CLI 경로에서 발견됐다(이 함수 자체의 결함이 아니라 그
# 앞단 호출 순서 결함 — 이 함수가 이미 올바르게 구현한 s2/m2 판정에
# `_evaluate_event()` 가 결코 도달하지 못했다). 아래
# `resolve_policy_version_for_absent_worktree()` 가 그 좁은 진입 조건
# (worktree 파일이 물리적으로 없는 경우 **만**)을 별도 함수로 다룬다 —
# 이 함수(`resolve_policy_version_digest_scope`) 자신의 로직은 한 글자도
# 바뀌지 않았다. "정책 폴더가 아직 git 에 커밋되지 않은 fixture 도
# policy.version 을 정상적으로 읽는다"는 기존 테스트 스위트 계약도
# 그대로 보존된다 — 그 fixture 들은 worktree 파일이 물리적으로
# 존재하므로(untracked-존재, s4 또는 non-git s5) 새 함수의 대상이 아니고
# `_load_policy_version_fact()` 의 기존 `load_policy_version(policy_dir)`
# 직접 호출 경로를 그대로 탄다.


class PolicyVersionGitStateError(PolicyVersionError):
    """spec §3.6 s3/m1/m3 — 정책 버전 선언의 git 상태가 모호하거나
    malformed 복구 조건을 충족하지 못해 명시 실패 (fail-closed).

    `rein.kernel.policy.PolicyVersionError` 의 하위 타입이다 — 원인은
    "내용 스키마 위반"이 아니라 "그 내용을 어느 시점 상태에서 읽어야
    하는지가 git 상태만으로 모호함"이지만, 호출자(`rein/cli/doctor.py`
    의 `except PolicyLoadError`, `bin/rein` 의 포괄 예외 처리기)는
    여전히 "정책 버전 메타데이터 문제"로 뭉뚱그려 fail-closed 처리해야
    하므로 별도 상속 계층을 새로 만들지 않는다.
    """


def _policy_dir_missing_error(policy_dir):
    """`_resolve_git_toplevel()` 이 `cwd_missing=True` 를 신호했을 때
    양쪽 호출자(`resolve_policy_version_digest_scope()`/
    `resolve_policy_version_for_absent_worktree()`)가 공유하는 문구
    — 정책 디렉터리 자체가 없다는
    것과 git 조회 실패를 더 이상 같은 문구로 뭉뚱그리지 않는다: git 은
    호출된 적이 없으므로 "git query failed"/"unable to confirm" 류의
    표현을 쓰지 않고, 그 경로가 없다는 사실과(cwd 로 존재하지 않는
    경로를 넘기면 subprocess 가 git 을 실행하기도 전에 실패한다) 이
    축의 정책이 여기 provisioning 되지 않았다는 것(프로젝트 오버라이드도
    번들 폴백도 이 경로에 없다)만 명시한다. 여전히 fail-closed다 —
    "부재이니 통과"가 아니라 "확인할 자체가 없으니 명시 실패".
    """
    if os.path.lexists(policy_dir):
        what = (
            "policy directory path cannot be resolved (dangling symbolic "
            "link): {path}"
        )
    else:
        what = "policy directory does not exist: {path}"
    return PolicyVersionGitStateError(
        (
            what + ". git was not invoked. This axis's policy is not "
            "provisioned here — no project override at {path} and no "
            "bundled fallback directory was supplied via REIN_POLICY_DIR"
        ).format(path=policy_dir)
    )


# "캐시 힌트가 아예 주어지지 않음"을 "캐시 힌트가 None(확인했더니 파일
# 자체가 없음)"과 구분하기 위한 센티널 — `object()` 자체를 비교하므로
# 어떤 실제 인자 값과도 절대 충돌하지 않는다.
_NO_CACHED_POLICY_VERSION_HINT = object()


def _decode_policy_version_bytes(raw_bytes, source):
    """raw_bytes 를 디코드·파싱해 유효하면 `PolicyVersion`, 아니면 `None`.

    UTF-8 디코드 실패도 malformed 로 취급한다 — 버전 선언은 사람이
    관리하는 평문 YAML subset 이어야 하므로 이진 쓰레기가 유효한 값일
    수 없다.
    """
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return None
    try:
        return parse_policy_version(text, source=source)
    except PolicyVersionError:
        return None


def resolve_policy_version_digest_scope(
    policy_dir, cached_policy_version=_NO_CACHED_POLICY_VERSION_HINT
):
    """`policy_dir/_version.yaml` 의 유효 `digest_scope` 를 git 수명주기로 판정한다.

    (spec §3.6 "선언의 유효 기준" 절, s1~s5 + malformed 교차 m1~m3 — 정본은
    spec 본문, 이 함수는 그 판정의 구현. digest_scope 전용 — `PolicyVersion`
    전체나 `policy.version`/`compatible_versions` fact 는 다루지 않는다,
    모듈 상단 섹션 주석 "이 워커의 지시 범위" 참조.)

    반환: 항상 구체적 문자열(`DIGEST_SCOPE_SENSITIVE`/`DIGEST_SCOPE_STRICT`).
    평소에는 선언된 `digest_scope` 값 그대로이거나(선언 있음) 기본값
    (선언 없음)이지만, **m2 순수 복구 스테이징**에서는 선언 내용과
    무관하게 항상 `DIGEST_SCOPE_STRICT` 로 강제된다(spec §3.6 "복구
    탈출구가 집행 완화 수단이 될 수 없는 방향 고정").

    예외: `PolicyVersionGitStateError` — s3(tracked 미스테이징
    divergence)/m1(순수 스테이징 후보가 malformed)/m3(malformed HEAD +
    비복구 상태, "clean 인데 malformed"인 경우 포함)에서 발생한다
    (fail-closed).

    `cached_policy_version`(선택) — 호출자(`rein.cli.
    _security_digest_scope_profile`)가 이미 다른 경로(`_load_policy_
    version_fact`)로 같은 파일을 worktree 기준으로 읽어 뒀다면, **s5
    (비 git 문맥)** 판정에 한해 그 결과를 그대로 재사용해 `_version.yaml`
    을 두 번 읽지 않는다(git 추적 컨텍스트, 즉 s1~s4/m1~m3 판정에서는
    이 힌트를 절대 신뢰하지 않는다 — 캐시가 담은 값은 naive worktree
    읽기의 산물이라 git 상태를 반영하지 않으므로, 이 함수가 고치려는
    바로 그 결함을 재도입하게 된다). 힌트를 넘기지 않으면(기본) s5 에서도
    직접 `load_policy_version()` 을 호출한다(하위호환).
    """
    full_path = os.path.join(policy_dir, VERSION_FILENAME)
    toplevel_out, confirmed_non_git, cwd_missing = _resolve_git_toplevel(
        policy_dir
    )
    if toplevel_out is None:
        if cwd_missing:
            # policy_dir 자체가 존재하지 않는다 — git 은 호출된 적이
            # 없다(위 confirmed_non_git 분기와 원인이 다르다 — 문구도
            # 분리한다).
            raise _policy_dir_missing_error(policy_dir)
        if not confirmed_non_git:
            # High (리뷰 지적, 2026-08-20) — 최초 git 조회가 "비-git" 을
            # 명시적으로 답한 게 아니라 실행 자체가 실패했다(timeout·
            # 프로세스 오류·그 밖의 비0 종료). 이걸 s5 로 흡수하면
            # git 이 일시적으로 불안정할 때 tracked strict 선언이
            # 미스테이징(신뢰할 수 없는) worktree 내용으로 조용히
            # 대체돼 강등된다 — 확인 불가를 "비-git 이니 worktree 를
            # 신뢰" 로 승격하지 않는다(spec §3.4 "확인 불가 ≠ 충족"
            # 원칙과 동일 방향). fail-closed.
            raise PolicyVersionGitStateError(
                "{}: unable to confirm whether this policy directory is "
                "outside a git repository — the initial git query failed "
                "for a reason other than a confirmed 'not a git "
                "repository' response (timeout, process error, or "
                "unexpected exit), so it cannot be safely treated as a "
                "non-git worktree-only context; fail-closed instead of "
                "silently trusting the worktree copy (spec §3.6, do not "
                "conflate git execution failure with a confirmed "
                "non-git context)".format(full_path)
            )
        # s5 — 확실히 비 git 문맥. 기존 worktree 직접 로드 경로를 그대로
        # 유지한다 — 기존 fixture 다수가 policy_dir 을 git 저장소 밖
        # (또는 안이어도 미추적)에 둔다. (policy_dir 자체가 없는 경우는
        # 더 이상 이 분기로 흡수되지 않는다 — 위 cwd_missing 분기 참조.)
        if cached_policy_version is not _NO_CACHED_POLICY_VERSION_HINT:
            if cached_policy_version is None:
                return DIGEST_SCOPE_SENSITIVE
            return cached_policy_version.digest_scope
        if not os.path.exists(full_path):
            return DIGEST_SCOPE_SENSITIVE
        from rein.kernel.policy import load_policy_version

        return load_policy_version(policy_dir).digest_scope

    # macOS 등에서 tempdir 이 symlink 경유일 수 있다(`/tmp` ->
    # `/private/tmp`) — 양쪽을 realpath 로 정규화하지 않으면 relpath 가
    # 어긋난다.
    toplevel = os.path.realpath(os.fsdecode(toplevel_out).strip())
    rel_path = os.path.relpath(os.path.realpath(full_path), toplevel)
    rel_path = rel_path.replace(os.sep, "/")

    head_state, head_bytes = _run_git_lifecycle_query(
        ("show", "HEAD:{}".format(rel_path)),
        policy_dir,
        _ABSENT_MARKERS_HEAD_SHOW,
    )
    if head_state == _GIT_QUERY_ERROR:
        # Critical (리뷰 지적, 2026-08-20) — 리뷰어 재현: clean 하게
        # committed 된 strict 저장소에서 이 HEAD 조회만 프로세스 오류로
        # 실패하게 주입하면, worktree/index 는 정상 조회돼 서로
        # 일치하는데 head_bytes 만 확인 실패다. 수리 전에는 그 실패를
        # "HEAD 에 파일 없음"(None)으로 흡수해 s2(최초 staged-add) 분기로
        # 새 곧장 DIGEST_SCOPE_SENSITIVE 기본값을 반환했다 — clean
        # committed strict 선언이 순간적인 git 실행 실패 하나로 조용히
        # sensitive 로 강등되는 fail-closed 계약 직접 위반. "확인 불가"
        # 를 "없음" 으로 승격하지 않는다.
        raise PolicyVersionGitStateError(
            "{}: unable to confirm HEAD content for this policy version "
            "declaration — the git query failed for a reason other than "
            "a confirmed 'path does not exist in HEAD' response (timeout, "
            "process error, or unexpected exit), so it cannot be safely "
            "treated as 'HEAD has no declaration'; fail-closed instead of "
            "silently demoting to the default profile (spec §3.6, do not "
            "conflate git query failure with confirmed absence)".format(
                full_path
            )
        )
    index_state, index_bytes = _run_git_lifecycle_query(
        ("cat-file", "blob", ":0:{}".format(rel_path)),
        policy_dir,
        _ABSENT_MARKERS_INDEX_CATFILE,
    )
    if index_state == _GIT_QUERY_ERROR:
        # 위 HEAD 조회와 동일한 클래스 — index 조회 실패를 "index 에
        # 파일 없음"으로 흡수하면 s1(clean, 3자 일치) 판정이 실제로는
        # 확인되지 않은 채 통과하거나, s3(모호) 로 가야 할 상태가 다른
        # 분기로 샐 수 있다.
        raise PolicyVersionGitStateError(
            "{}: unable to confirm index content for this policy version "
            "declaration — the git query failed for a reason other than "
            "a confirmed 'path does not exist in the index' response "
            "(timeout, process error, or unexpected exit); fail-closed "
            "instead of silently treating it as absent (spec §3.6, do "
            "not conflate git query failure with confirmed "
            "absence)".format(full_path)
        )
    try:
        with open(full_path, "rb") as handle:
            worktree_bytes = handle.read()
    except OSError:
        worktree_bytes = None

    if worktree_bytes == index_bytes:
        if index_bytes == head_bytes:
            # s1 — clean(3자 일치, 파일 존재 또는 3자 모두 부재).
            if head_bytes is None:
                return DIGEST_SCOPE_SENSITIVE
            head_version = _decode_policy_version_bytes(
                head_bytes, "{} (HEAD)".format(full_path)
            )
            if head_version is None:
                # HEAD malformed + 복구 스테이징 없음(worktree/index/HEAD
                # 전부 동일) — m2 의 "원칙상 명시 실패" 기본 분기.
                raise PolicyVersionGitStateError(
                    "{}: HEAD content is malformed and worktree/index/HEAD "
                    "are all identical — no staged recovery in progress, "
                    "fail-closed (spec §3.6, clean state has no recovery "
                    "path)".format(full_path)
                )
            return head_version.digest_scope

        # s2 — 순수 스테이징(최초 추가·수정·staged 삭제 모두 포함).
        if index_bytes is not None:
            staged_version = _decode_policy_version_bytes(
                index_bytes, "{} (staged)".format(full_path)
            )
            if staged_version is None:
                # m1 — 게이팅된 커밋 경로로는 malformed 선언이 HEAD 에
                # 유입될 수 없다.
                raise PolicyVersionGitStateError(
                    "{}: staged policy version declaration is malformed "
                    "— the gated commit path must not let it reach HEAD "
                    "(spec §3.6 m1, fail-closed)".format(full_path)
                )
        if head_bytes is None:
            # 최초 추가(HEAD 부재) 또는 이미 부재였던 상태 — 변경 전
            # 상태(부재) 기준으로 평가.
            return DIGEST_SCOPE_SENSITIVE
        head_version = _decode_policy_version_bytes(
            head_bytes, "{} (HEAD)".format(full_path)
        )
        if head_version is None:
            # m2 — HEAD malformed + 순수 복구 스테이징(위에서 staged 가
            # 유효하거나 삭제임을 이미 확인) → strict 프로필 강제(선언
            # 내용과 무관 — 복구 탈출구가 집행 완화 수단이 될 수 없다).
            return DIGEST_SCOPE_STRICT
        return head_version.digest_scope

    # worktree != index.
    if head_bytes is None and index_bytes is None:
        # s4 — untracked 신규: 운영 권위 없음. HEAD 기준(=선언 없음,
        # 기본 프로필)으로 평가하되 명시 경고.
        warnings.warn(
            "{}: untracked policy version declaration has no operating "
            "authority yet — stage and commit it to take effect (spec "
            "§3.6 s4)".format(full_path),
            RuntimeWarning,
            stacklevel=2,
        )
        return DIGEST_SCOPE_SENSITIVE

    # s3 — tracked 파일의 미스테이징 divergence(staged+unstaged 혼재
    # 포함) — 모호 상태, 명시 실패.
    raise PolicyVersionGitStateError(
        "{}: unstaged divergence between worktree and index for a "
        "tracked policy version declaration — ambiguous state, "
        "fail-closed (spec §3.6 s3)".format(full_path)
    )


# ---------------------------------------------------------------------------
# 정책 버전 fact(`FACT_POLICY_VERSION`/`FACT_POLICY_COMPATIBLE_VERSIONS`,
# `rein.cli._load_policy_version_fact()`)의 "worktree 부재" 진입 조건
# 전용 보조 판정 (리뷰 지적 수리, 2026-08-20).
#
# 리뷰 지적: `_load_policy_version_fact()` 는 `os.path.exists()` 로
# worktree 파일 부재를 확인하면 곧바로 "미설정"으로 단정해, declared 가
# 증거 발급형 requirement(`_EVIDENCE_ISSUED_REQUIREMENTS`)를 포함하면
# 즉시 `PolicyVersionError` 로 `_evaluate_event()` 전체를 죽인다 — 그런데
# 이 부재가 실은 아직 커밋되지 않은 staged 삭제(spec §3.6 s2 — "커밋
# 전까지는 HEAD 의 옛 선언이 여전히 발효")라면, 실제로는 판정을 계속할
# 수 있어야 한다.
#
# 이 함수는 그 "worktree 부재" 진입 조건 **하나만** 다룬다 — 호출자가
# 이미 `os.path.exists(version_path) == False` 를 확인했다는 전제다.
# `resolve_policy_version_digest_scope()` 의 완전한 s1~s5/m1~m3
# 재구현이 아니다(그 함수는 건드리지 않는다 — digest_scope 축은 이미
# 정답이었다, 위 섹션 주석 "범위 갱신" 절 참조). worktree 파일이
# 물리적으로 존재하는 다른 4상태(s1 clean-존재/s2 staged-add·mod/s4
# untracked-존재)는 이 함수의 대상이 아니다 — 호출자의 기존
# `load_policy_version(policy_dir)` 직접 호출 경로가 그대로 처리한다.


POLICY_VERSION_MALFORMED_RECOVERY = object()
"""m2 센티널 — HEAD 가 malformed 인 채 staged 삭제만 진행 중(복구
스테이징)이라 유효 `PolicyVersion` 값을 낼 수 없지만, 이는 "설정 오류"
가 아니라 "지금은 판정 불가"다(spec §3.6 "복구 탈출구가 집행 완화
수단이 될 수 없는 방향 고정" 절과 동일 정신 — digest_scope 축은 이
상태에서 strict 를 강제하고 raise 하지 않는다,
`resolve_policy_version_digest_scope()` m2 분기 참조). 호출자
(`rein.cli._load_policy_version_fact`)는 이 센티널을 받으면 Medium D
랜드마인 가드(declared 가 증거 발급형 requirement 를 포함하면 명시
차단)를 적용하지 않고 조용히 fact 를 부재로 남긴다 — 그 가드는 "애초에
설정된 적이 없다"를 노리는 것이지, "설정돼 있었는데 복구가 진행
중이다"를 노리는 게 아니다.
"""


def resolve_policy_version_for_absent_worktree(policy_dir):
    """`policy_dir/_version.yaml` 이 worktree 에 물리적으로 없을 때만
    호출되는 보조 판정 — 그 부재가 진짜 부재인지 staged 삭제(HEAD 기준
    평가 대상)인지를 가른다. 호출 전제: 호출자가 이미
    `os.path.exists(...) == False` 로 부재를 확인했다(이 함수 자신은
    재확인하지 않는다 — 재확인이 TOCTOU 경합을 새로 만들 이유가 없다,
    실패해도 아래 각 분기의 `_run_git_lifecycle_query()` fail-closed
    경로로 흡수된다).

    **2026-08-20 후속 리뷰 지적 수리** — 이전 판단("이 함수의 git 조회는
    그대로 둔다")이 이번 지적으로 뒤집혔다. 아래 세 조회(toplevel 확인·
    index 내용·HEAD 내용) 전부가 예전에는 공용 `_run_git()`(부재·오류를
    `None` 하나로 합침)을 썼다 — 즉 `resolve_policy_version_digest_
    scope()` 가 이미 겪고 고친 것과 같은 클래스의 결함이 이 함수에는
    3곳 모두 남아 있었다. 이제 전부 `_run_git_lifecycle_query()`(FOUND/
    ABSENT/ERROR 3상태)를 거친다 — ERROR(확인 자체의 실패)는 부재로
    흡수하지 않고 `PolicyVersionGitStateError` 로 fail-closed 한다.

    반환:

    - `PolicyVersion` — git 추적 컨텍스트에서 HEAD 에 유효한 이전
      선언이 있고(staged 삭제로 index 도 비어 있음, s2) 그 내용을 그대로
      쓸 수 있다("staged 삭제 = HEAD 기준 평가").
    - `POLICY_VERSION_MALFORMED_RECOVERY`(센티널) — 위와 같은 staged
      삭제 상태이지만 HEAD 내용이 malformed(m2, "복구 스테이징").
    - `None` — 그 밖 전부: non-git 문맥(확인됨, 호출자가 기존 s5 경로를
      그대로 탄다) 또는 HEAD 도 부재(진짜 부재 — "커밋으로 부재 발효"
      또는 초기 커밋 전 unborn HEAD). 호출자가 기존 "미설정" 판정
      경로(Medium D 랜드마인 가드)로 fall through 한다. **git 조회
      자체의 실패는 더 이상 이 분기로 흡수되지 않는다** — 아래 예외
      참조.

    예외: `PolicyVersionGitStateError` — 다음 중 하나.

    1. index 는 여전히 이전 내용을 가리키는데 worktree 만 사라진 경우
       (스테이징되지 않은 삭제, tracked divergence) — s3 와 동일한
       모호성이라 fail-closed 한다. 조용히 "부재"로 흡수하면, index 에는
       여전히 유효한 tracked 선언이 있는데도 증거 발급형 requirement 가
       버전 검증 없이 통과하는 길이 열린다.
    2. 위 세 git 조회(toplevel 확인·index 내용·HEAD 내용) 중 하나라도
       ERROR 상태(확인 자체가 실패 — timeout·프로세스 오류·그 밖의
       모호한 비0 종료)로 끝난 경우 — "확인 불가"를 "없음"으로 승격하지
       않는다.
    """
    full_path = os.path.join(policy_dir, VERSION_FILENAME)

    toplevel_out, confirmed_non_git, cwd_missing = _resolve_git_toplevel(
        policy_dir
    )
    if toplevel_out is None:
        if cwd_missing:
            # policy_dir 자체가 존재하지 않는다 — git 은 호출된 적이
            # 없다(위 confirmed_non_git 분기와 원인이 다르다 — 문구도
            # 분리한다, `resolve_policy_version_digest_scope()` 와 동일
            # 방향).
            raise _policy_dir_missing_error(policy_dir)
        if not confirmed_non_git:
            # High (리뷰 지적, 2026-08-20) — 최초 조회가 "비-git" 을
            # 명시적으로 답한 게 아니라 실행 자체가 실패했다. 이걸 기존
            # s5(non-git, worktree 직접 신뢰) 경로로 흡수하면, 실은 git
            # 추적 컨텍스트인 tracked 선언이 검증 없이 "미설정"으로
            # 오판될 수 있다 — `resolve_policy_version_digest_scope()`
            # 의 최초 조회에 이미 적용된 것과 동일한 방향의 수리.
            raise PolicyVersionGitStateError(
                "{}: unable to confirm whether this policy directory is "
                "outside a git repository — the initial git query failed "
                "for a reason other than a confirmed 'not a git "
                "repository' response (timeout, process error, or "
                "unexpected exit), so it cannot be safely treated as a "
                "non-git worktree-only context; fail-closed instead of "
                "silently falling through to the absent-declaration path "
                "(spec §3.6, do not conflate git execution failure with "
                "a confirmed non-git context)".format(full_path)
            )
        # s5 — 확실히 비 git 문맥. 호출자의 기존 s5 경로(worktree 직접
        # 읽기)가 이미 부재를 "미설정"으로 정확히 판정한다. 새 판단 없음.
        # (policy_dir 자체가 없는 경우는 더 이상 이 분기로 흡수되지
        # 않는다 — 위 cwd_missing 분기 참조.)
        return None

    # macOS 등에서 tempdir 이 symlink 경유일 수 있다 — 양쪽을 realpath 로
    # 정규화한다(`resolve_policy_version_digest_scope()` 와 동일 관례).
    # full_path 가 물리적으로 없어도 `os.path.realpath` 는 문자열
    # 정규화만 수행하므로 안전하다(마지막 성분의 존재를 요구하지 않음).
    toplevel = os.path.realpath(os.fsdecode(toplevel_out).strip())
    rel_path = os.path.relpath(os.path.realpath(full_path), toplevel)
    rel_path = rel_path.replace(os.sep, "/")

    index_state, index_bytes = _run_git_lifecycle_query(
        ("cat-file", "blob", ":0:{}".format(rel_path)),
        policy_dir,
        _ABSENT_MARKERS_INDEX_CATFILE,
    )
    if index_state == _GIT_QUERY_ERROR:
        raise PolicyVersionGitStateError(
            "{}: unable to confirm index content while resolving an "
            "absent worktree copy — the git query failed for a reason "
            "other than a confirmed 'path does not exist in the index' "
            "response (timeout, process error, or unexpected exit); "
            "fail-closed instead of silently treating it as absent "
            "(spec §3.6, do not conflate git query failure with "
            "confirmed absence)".format(full_path)
        )
    if index_state == _GIT_QUERY_FOUND:
        # index 는 여전히 내용을 갖는데 worktree 만 사라짐 — 스테이징
        # 되지 않은 삭제(tracked divergence). s3 와 동일한 모호성.
        raise PolicyVersionGitStateError(
            "{}: worktree copy is missing but the index still holds "
            "tracked content for it — an unstaged deletion of a tracked "
            "policy version declaration is ambiguous, fail-closed "
            "(spec §3.6 s3-equivalent for absence)".format(full_path)
        )

    head_state, head_bytes = _run_git_lifecycle_query(
        ("show", "HEAD:{}".format(rel_path)),
        policy_dir,
        _ABSENT_MARKERS_HEAD_SHOW,
    )
    if head_state == _GIT_QUERY_ERROR:
        raise PolicyVersionGitStateError(
            "{}: unable to confirm HEAD content while resolving an "
            "absent worktree copy — the git query failed for a reason "
            "other than a confirmed 'path does not exist in HEAD' "
            "response (timeout, process error, or unexpected exit); "
            "fail-closed instead of silently treating it as absent "
            "(spec §3.6, do not conflate git query failure with "
            "confirmed absence)".format(full_path)
        )
    if head_state == _GIT_QUERY_ABSENT:
        # HEAD 도 부재 — 진짜 부재(이미 커밋된 삭제, "커밋으로 부재
        # 발효") 또는 HEAD 자체가 없는 저장소(초기 커밋 전). 호출자의
        # 기존 "미설정" 경로로.
        return None

    head_version = _decode_policy_version_bytes(
        head_bytes, "{} (HEAD)".format(full_path)
    )
    if head_version is None:
        # m2 — HEAD malformed + 순수 복구 스테이징(위에서 index 가 비어
        # 있음을 이미 확인) → 값을 낼 수 없지만 설정 오류로 보지 않는다.
        return POLICY_VERSION_MALFORMED_RECOVERY
    return head_version
