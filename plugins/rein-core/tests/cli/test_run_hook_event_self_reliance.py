"""Task 6.1 선행1(b) — `run_hook_event()` 자립 규칙 (DoD
`dod-2026-08-12-v2-phase6-authority.md` Task 6.1 선행1).

`hooks/hooks.json` 스키마에 `env` 필드가 없어, 실제 hook 실행 경로에서는
REIN_POLICY_DIR/REIN_PROJECT_ROOT/REIN_DB_PATH 세 환경변수가 절대
채워지지 않는다. 기존 `run_event()` 를 그 경로에 그대로 연결하면
`load_policies(None)` → policy 0개 → 항상 ALLOW 로 새는데, 이는 spec
§3.4 "판단 불능은 거부 방향" 과 정면으로 어긋난다. 이 파일은
`run_hook_event()`/`_resolve_policy_dir()`/`_resolve_project_root()`/
`_resolve_db_path()` 가 이 구멍을 실제로 막는지 in-process 로 고정한다
— `bin/rein hook` 의 native 응답 변환·exit code 계약은
`tests/cli/test_hook_subcommand_native_response.py` 가 별도로 담당한다.

검증 축:
(a) 자기 위치 기준 self-location 이 실제 번들 정책 디렉토리를 가리킨다.
(b) 세 `_resolve_*` 함수 모두 "명시 환경변수 우선, 미설정 시 대체값
    유도" 규칙을 지킨다.
(c) `run_hook_event()` 가 세 환경변수 전부 미설정이어도 번들 기본
    정책으로 실제 판정을 낸다 — 정책 0개로 새어 무조건 ALLOW 로
    흐르지 않는다(핵심 회귀 방지 축).
(d) "정책 디렉토리를 못 찾음/손상"(예외 전파 → BLOCK 대상)과 "정책은
    정상 로드됐으나 매칭 규칙 없음"(정상 ALLOW)을 명확히 구분한다.
(e) project_root 유도 실패는 `ProjectRootResolutionError` 로 명시
    전파된다(조용히 흡수되지 않는다).
(f) 이 리팩토링(`_evaluate_event()` 추출)이 `run_event()` 의 기존
    계약(환경변수 미설정 시 policy 0개 → ALLOW)을 바꾸지 않았다.
"""
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import (  # noqa: E402
    ENV_DB_PATH,
    ENV_POLICY_DIR,
    ENV_PROJECT_ROOT,
    ProjectRootResolutionError,
    _default_policy_dir,
    _is_confirmed_not_a_repository,
    _resolve_db_path,
    _resolve_policy_dir,
    _resolve_project_root,
    _run_git_show_toplevel,
    run_event,
    run_hook_event,
)
from rein.kernel.policy import PolicyLoadError  # noqa: E402
from rein.platform.storage.local import LocalStateRoot  # noqa: E402

_ALL_THREE_ENV_VARS = (ENV_POLICY_DIR, ENV_PROJECT_ROOT, ENV_DB_PATH)


def _clear_env():
    """세 환경변수를 전부 제거한 dict — 바깥 세션 값이 결정성을 깨지 않게."""
    env = dict(os.environ)
    for key in _ALL_THREE_ENV_VARS:
        env.pop(key, None)
    return env


def _write_active_dod(project_root, slug="fixture-task", date="2026-08-19"):
    # Phase 7 결정 1(2026-08-19 사용자 결정) — 기본 commit.yaml 의
    # `when:` 에 `task.exists: "true"` 가 추가돼, `trail/dod/dod-*.md`
    # 글롭에 매치되는 파일이 하나도 없으면 commit.yaml 자체가 매칭되지
    # 않는다. `task.exists` 는 v1 `dod_exists` glob 의 독립 미러 shim —
    # 완료 여부(inbox 대조)·날짜 형식과 무관하게 파일 존재만 본다
    # (`rein.platform.task.facts.task_exists()` 참조, High-1 리뷰 후
    # 확정 — `tests/contract/test_commit_policy_task_conditioning.py`
    # 와 결정 번호 동일). `test_all_three_env_vars_unset_still_blocks_
    # matching_event` 는 "환경변수 자립 규칙이 정책 0개로 새지 않고 실제
    # BLOCK 판정을 낸다"를 겨냥하므로, commit.yaml 이 실제로 매칭돼야
    # 그 축을 검증할 수 있다 — 활성 작업 픽스처로 그 전제를 복원한다
    # (원 단언은 변경하지 않는다).
    dod_dir = os.path.join(project_root, "trail", "dod")
    os.makedirs(dod_dir, exist_ok=True)
    with open(
        os.path.join(dod_dir, "dod-{}-{}.md".format(date, slug)),
        "w",
        encoding="utf-8",
    ) as handle:
        handle.write("# DoD\n\n- date: {}\n".format(date))


def _bash_payload(command, cwd=None):
    payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    }
    if cwd is not None:
        payload["cwd"] = cwd
    return payload


def _read_payload(cwd=None):
    payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Read",
        "tool_input": {"file_path": "/tmp/whatever"},
    }
    if cwd is not None:
        payload["cwd"] = cwd
    return payload


def _init_git_repo(base_dir):
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
    with open(os.path.join(base_dir, "README.md"), "w", encoding="utf-8") as handle:
        handle.write("x\n")
    subprocess.run(["git", "add", "-A"], cwd=base_dir, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True)


class DefaultPolicyDirSelfLocationTest(unittest.TestCase):
    """(a) self-location 이 실제 번들 정책 디렉토리를 가리킨다."""

    def test_default_policy_dir_exists_and_contains_bundled_policies(self):
        default_dir = _default_policy_dir()
        self.assertTrue(
            os.path.isdir(default_dir), msg="{!r} must exist".format(default_dir)
        )
        self.assertIn("commit.yaml", os.listdir(default_dir))
        self.assertIn("_version.yaml", os.listdir(default_dir))

    def test_default_policy_dir_does_not_depend_on_claude_plugin_root(self):
        """CLAUDE_PLUGIN_ROOT 가 미설정/오염돼도 self-location 이 흔들리지 않는다."""
        with mock.patch.dict(os.environ, {"CLAUDE_PLUGIN_ROOT": "/nonexistent"}):
            with_env = _default_policy_dir()
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CLAUDE_PLUGIN_ROOT", None)
            without_env = _default_policy_dir()
        self.assertEqual(with_env, without_env)


class ResolvePolicyDirPrecedenceTest(unittest.TestCase):
    """(b) `_resolve_policy_dir()` — 명시 환경변수 우선, 없으면 번들 기본값."""

    def test_explicit_env_var_wins_over_default(self):
        with mock.patch.dict(os.environ, {ENV_POLICY_DIR: "/some/explicit/dir"}):
            self.assertEqual(_resolve_policy_dir(), "/some/explicit/dir")

    def test_unset_env_var_falls_back_to_bundled_default(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV_POLICY_DIR, None)
            self.assertEqual(_resolve_policy_dir(), _default_policy_dir())

    def test_empty_string_env_var_is_treated_as_unset(self):
        with mock.patch.dict(os.environ, {ENV_POLICY_DIR: ""}):
            self.assertEqual(_resolve_policy_dir(), _default_policy_dir())


class ResolveProjectRootTest(unittest.TestCase):
    """(b)/(e) `_resolve_project_root()` — 우선순위 + 유도 실패는 명시 예외."""

    def test_explicit_env_var_wins_over_payload_cwd(self):
        with mock.patch.dict(os.environ, {ENV_PROJECT_ROOT: "/explicit/root"}):
            result = _resolve_project_root({"cwd": "/some/other/dir"})
        self.assertEqual(result, "/explicit/root")

    def test_git_repo_subdirectory_resolves_to_repository_root(self):
        with tempfile.TemporaryDirectory() as repo_root:
            _init_git_repo(repo_root)
            sub_dir = os.path.join(repo_root, "src")
            os.mkdir(sub_dir)
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_PROJECT_ROOT, None)
                result = _resolve_project_root({"cwd": sub_dir})
        self.assertEqual(os.path.realpath(result), os.path.realpath(repo_root))

    def test_non_git_directory_falls_back_to_cwd_itself(self):
        with tempfile.TemporaryDirectory() as plain_dir:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_PROJECT_ROOT, None)
                result = _resolve_project_root({"cwd": plain_dir})
        self.assertEqual(result, plain_dir)

    def test_missing_cwd_field_raises_resolution_error(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV_PROJECT_ROOT, None)
            with self.assertRaises(ProjectRootResolutionError):
                _resolve_project_root({})

    def test_non_directory_cwd_raises_resolution_error(self):
        with tempfile.TemporaryDirectory() as base_dir:
            not_a_dir = os.path.join(base_dir, "does-not-exist")
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_PROJECT_ROOT, None)
                with self.assertRaises(ProjectRootResolutionError):
                    _resolve_project_root({"cwd": not_a_dir})

    def test_git_execution_failure_raises_resolution_error_not_silent_fallback(self):
        """코드 리뷰 Medium 2 — git 실행 자체가 불가능하면(바이너리 부재
        등) 판단 불능이지 "저장소 아님"이 아니다. 수리 전에는
        `_run_git_show_toplevel()` 이 `OSError`/timeout 을 `None` 으로
        뭉개, `_resolve_project_root()` 가 이 경우도 "확실히 저장소
        아님"과 동일하게 payload cwd 로 조용히 폴백했다(리뷰어 실측
        재현: PATH 조작으로 git 실행 불능 상태를 만들어도 하위
        디렉토리가 그대로 project_root 로 쓰였다)."""
        with tempfile.TemporaryDirectory() as plain_dir:
            with mock.patch(
                "subprocess.run",
                side_effect=FileNotFoundError("git executable not found"),
            ):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    with self.assertRaises(ProjectRootResolutionError):
                        _resolve_project_root({"cwd": plain_dir})

    def test_git_timeout_raises_resolution_error_not_silent_fallback(self):
        with tempfile.TemporaryDirectory() as plain_dir:
            with mock.patch(
                "subprocess.run",
                side_effect=subprocess.TimeoutExpired(cmd="git", timeout=5),
            ):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    with self.assertRaises(ProjectRootResolutionError):
                        _resolve_project_root({"cwd": plain_dir})

    def test_git_confirmed_not_a_repository_still_falls_back_to_cwd(self):
        """대조군 — git 이 정상 실행되어 "저장소 아님"을 답한 경우는
        여전히 안전한 폴백이다(실행 불능과는 다른 사건이라는 것을
        분명히 하기 위한 회귀 방지)."""
        with tempfile.TemporaryDirectory() as plain_dir:
            completed = subprocess.CompletedProcess(
                args=("git", "rev-parse", "--show-toplevel"),
                returncode=128,
                stdout=b"",
                stderr=b"fatal: not a git repository\n",
            )
            with mock.patch("subprocess.run", return_value=completed):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    result = _resolve_project_root({"cwd": plain_dir})
        self.assertEqual(result, plain_dir)

    def test_git_confirmed_not_a_repository_alternate_message_form_falls_back(self):
        """대조군 — git 의 "저장소 아님" 두 번째 실제 메시지 변형(경로
        인용형, 예: `GIT_DIR` 이 잘못된 경로를 가리킬 때)도 화이트리스트에
        매칭돼야 한다(실측: `git rev-parse --show-toplevel` 을 비-저장소
        디렉토리에서 직접 실행해 두 변형 모두 `fatal: not a git
        repository` 로 시작하는 것을 확인했다 — 회귀 방지용 두 번째
        고정)."""
        with tempfile.TemporaryDirectory() as plain_dir:
            completed = subprocess.CompletedProcess(
                args=("git", "rev-parse", "--show-toplevel"),
                returncode=128,
                stdout=b"",
                stderr=b"fatal: not a git repository: '/nonexistent/.git'\n",
            )
            with mock.patch("subprocess.run", return_value=completed):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    result = _resolve_project_root({"cwd": plain_dir})
        self.assertEqual(result, plain_dir)

    def test_git_ambiguous_non_zero_exit_raises_resolution_error_not_silent_fallback(
        self,
    ):
        """2회차 리뷰 Medium — "확인된 저장소 아님" 이 아닌 non-zero exit
        은 판단 불능으로 분류해 차단해야 한다. 대표 재현 대상은 git
        2.35.2+ 의 "dubious ownership" 안전장치(CVE-2022-24765 대응) —
        컨테이너/CI 에서 저장소가 다른 uid 로 마운트되면 정상 실행 +
        non-zero exit 이면서도 "저장소가 아니다"가 아니라 "소유자
        불일치로 판정을 거부한다"는 뜻이다. 실제 uid mismatch 는 root
        권한 없이 이 환경에서 재현할 수 없으므로, 실제 git 대신 그
        메시지 형태를 흉내낸 `subprocess.CompletedProcess` 로 주입한다
        (DoD 요구사항 4(b)). 수리 전에는 `_run_git_show_toplevel()` 이
        non-zero exit 을 전부 `None`(="확실히 저장소 아님")으로 뭉개
        `_resolve_project_root()` 가 검증되지 않은 payload cwd 를 그대로
        project_root 로 폴백시켰다 — 이 테스트는 그 fail-open 을
        고정한다."""
        with tempfile.TemporaryDirectory() as plain_dir:
            completed = subprocess.CompletedProcess(
                args=("git", "rev-parse", "--show-toplevel"),
                returncode=128,
                stdout=b"",
                stderr=(
                    "fatal: detected dubious ownership in repository at "
                    "'{0}'\nTo add an exception for this directory, "
                    "call:\n\n\tgit config --global --add safe.directory "
                    "{0}\n".format(plain_dir)
                ).encode("utf-8"),
            )
            with mock.patch("subprocess.run", return_value=completed):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    with self.assertRaises(ProjectRootResolutionError):
                        _resolve_project_root({"cwd": plain_dir})

    def test_git_returncode_zero_with_unrelated_stderr_noise_still_succeeds(self):
        """대조군 — exit 0 이면 stderr 내용과 무관하게(예: git 의 경고성
        stderr 출력) stdout 의 toplevel 값을 그대로 신뢰한다. 화이트리스트
        판정은 non-zero exit 경로에서만 적용된다는 것을 명확히 한다."""
        with tempfile.TemporaryDirectory() as repo_root:
            completed = subprocess.CompletedProcess(
                args=("git", "rev-parse", "--show-toplevel"),
                returncode=0,
                stdout=(repo_root + "\n").encode("utf-8"),
                stderr=b"warning: something unrelated\n",
            )
            with mock.patch("subprocess.run", return_value=completed):
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_PROJECT_ROOT, None)
                    result = _resolve_project_root({"cwd": repo_root})
        self.assertEqual(result, repo_root)


class IsConfirmedNotARepositoryWhitelistTest(unittest.TestCase):
    """`_is_confirmed_not_a_repository()` — 화이트리스트 판정 자체를 단위로 고정.

    2회차 리뷰 Medium 수리 — 종료 코드 128 *그리고* stderr 접두어
    두 조건을 모두 요구하는 화이트리스트다(요구사항 2/3). 어느 한쪽만
    만족하는 경우는 전부 판단 불능(`False`)이어야 한다."""

    def test_matches_confirmed_not_a_repository_signature(self):
        self.assertTrue(
            _is_confirmed_not_a_repository(
                128, "fatal: not a git repository (or any of the parent "
                "directories): .git\n"
            )
        )

    def test_matches_alternate_path_quoted_message_form(self):
        self.assertTrue(
            _is_confirmed_not_a_repository(
                128, "fatal: not a git repository: '/nonexistent/.git'\n"
            )
        )

    def test_dubious_ownership_message_is_not_whitelisted(self):
        """DoD 요구사항 4(b) 핵심 대조 — dubious ownership 은 exit 128
        을 공유하지만 화이트리스트 문구가 아니므로 `False` 여야 한다."""
        self.assertFalse(
            _is_confirmed_not_a_repository(
                128,
                "fatal: detected dubious ownership in repository at "
                "'/repo'\nTo add an exception for this directory, call:\n"
                "\n\tgit config --global --add safe.directory /repo\n",
            )
        )

    def test_matching_returncode_alone_is_not_sufficient(self):
        self.assertFalse(_is_confirmed_not_a_repository(128, "fatal: some other error\n"))

    def test_matching_stderr_alone_with_different_returncode_is_not_sufficient(self):
        self.assertFalse(
            _is_confirmed_not_a_repository(
                1, "fatal: not a git repository (or any of the parent "
                "directories): .git\n"
            )
        )

    def test_unrelated_non_zero_exit_is_not_whitelisted(self):
        self.assertFalse(_is_confirmed_not_a_repository(1, "fatal: unable to auto-detect email address\n"))


class RunGitShowToplevelRealBinaryTest(unittest.TestCase):
    """`_run_git_show_toplevel()` 을 실제 git 바이너리로 구동 — mock 이
    아니라 이 환경의 실제 git 출력이 화이트리스트와 실제로 맞물리는지
    확인한다(DoD 요구사항 2/4(a) — "실제 git 출력을 직접 확인해 근거를
    확보하라"). scratchpad 실측(2026-08-14, macOS git 2.50.1)과 동일한
    시나리오를 자동화된 assertion 으로 고정한다."""

    def test_real_git_in_non_git_directory_returns_none(self):
        """(a) 확인된 저장소 아님 — 실측: exit 128 +
        'fatal: not a git repository (or any of the parent directories): "
        ".git'."""
        with tempfile.TemporaryDirectory() as plain_dir:
            result = _run_git_show_toplevel(plain_dir)
        self.assertIsNone(result)

    def test_real_git_in_repository_returns_toplevel(self):
        with tempfile.TemporaryDirectory() as repo_root:
            _init_git_repo(repo_root)
            sub_dir = os.path.join(repo_root, "src")
            os.mkdir(sub_dir)
            result = _run_git_show_toplevel(sub_dir)
        self.assertEqual(os.path.realpath(result), os.path.realpath(repo_root))


class ResolveDbPathTest(unittest.TestCase):
    """(b) `_resolve_db_path()` — 명시 우선, 미설정 시 프로젝트 루트 하위 기본 경로."""

    def test_explicit_env_var_wins(self):
        with mock.patch.dict(os.environ, {ENV_DB_PATH: "/explicit/db.sqlite3"}):
            self.assertEqual(_resolve_db_path("/whatever"), "/explicit/db.sqlite3")

    def test_unset_env_var_defaults_to_project_state_dir_and_creates_it(self):
        with tempfile.TemporaryDirectory() as project_root:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_DB_PATH, None)
                result = _resolve_db_path(project_root)
            expected = LocalStateRoot(project_root).database_path()
            self.assertEqual(result, expected)
            self.assertTrue(os.path.isdir(os.path.dirname(result)))

    @unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약 (spec 대상 플랫폼)")
    def test_default_db_path_file_is_precreated_with_mode_0600(self):
        """코드 리뷰 Medium 3 — 신규 기본 db 파일은 0600 이어야 한다
        (spec §3.8, `docs/specs/2026-08-07-rein-v2-governance-
        orchestration.md:353` 부근). 수리 전에는 이 함수가 경로만
        계산하고 실제 파일 생성은 나중에(`_evaluate_event()` 의
        `sqlite3.connect()`) umask 영향을 받는 기본 권한으로 일어나
        0644 로 샜다(리뷰어 재현: `.rein/state/runtime.sqlite3` 가
        0644). 관대한 umask 아래에서도 코드가 0600 을 강제하는지
        확인한다."""
        previous_umask = os.umask(0o000)
        try:
            with tempfile.TemporaryDirectory() as project_root:
                with mock.patch.dict(os.environ, {}, clear=False):
                    os.environ.pop(ENV_DB_PATH, None)
                    db_path = _resolve_db_path(project_root)
                self.assertTrue(os.path.exists(db_path))
                mode = stat.S_IMODE(os.stat(db_path).st_mode)
                self.assertEqual(mode, 0o600)
        finally:
            os.umask(previous_umask)

    @unittest.skipUnless(os.name == "posix", "심볼릭 링크 가드는 POSIX 대상")
    @unittest.skipUnless(hasattr(os, "symlink"), "symlink 미지원 플랫폼")
    def test_preplanted_symlink_at_db_path_is_rejected(self):
        """코드 리뷰 Medium 4 — db 경로 자체가 미리 심어진 심볼릭 링크면
        거부한다(리뷰어 실측 재현: 프로젝트의 db 경로를 외부 디렉토리로
        연결한 뒤 훅을 호출해 외부 경로에 db 파일이 생기는 것을 확인)."""
        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as outside:
            state_root = LocalStateRoot(project_root)
            state_root.ensure()
            outside_target = os.path.join(outside, "outside.sqlite3")
            db_path = state_root.database_path()
            os.symlink(outside_target, db_path)

            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(ENV_DB_PATH, None)
                with self.assertRaises(OSError):
                    _resolve_db_path(project_root)

            self.assertFalse(os.path.exists(outside_target))
            self.assertTrue(os.path.islink(db_path))


class RunHookEventSelfRelianceTest(unittest.TestCase):
    """(c)/(d) 핵심 회귀 방지 — 자립 규칙이 실제 판정에 반영된다."""

    def test_all_three_env_vars_unset_still_blocks_matching_event(self):
        """정책 0개로 새어 무조건 ALLOW 로 흐르지 않는다 (핵심 축)."""
        with tempfile.TemporaryDirectory() as workdir:
            _write_active_dod(workdir)
            payload = _bash_payload("git commit -m 'ship it'", cwd=workdir)
            with mock.patch.dict(os.environ, _clear_env(), clear=True):
                decision = run_hook_event(payload)
        self.assertEqual(decision["decision"], "BLOCK")
        self.assertIn("code_review", decision["missing_requirements"])

    def test_unmatched_event_allows_even_with_policies_loaded(self):
        """(d) 로드된 정책이 있어도 매칭 안 되면 정상 ALLOW."""
        with tempfile.TemporaryDirectory() as workdir:
            payload = _read_payload(cwd=workdir)
            with mock.patch.dict(os.environ, _clear_env(), clear=True):
                decision = run_hook_event(payload)
        self.assertEqual(decision["decision"], "ALLOW")

    def test_empty_but_existing_policy_dir_allows_without_match_error(self):
        """(d) '정책 0개(정상 로드)' 는 '로드 실패' 와 다르다 — ALLOW 여야 한다."""
        with tempfile.TemporaryDirectory() as workdir:
            empty_policy_dir = os.path.join(workdir, "policies")
            os.mkdir(empty_policy_dir)
            payload = _bash_payload("git commit -m x", cwd=workdir)
            env = _clear_env()
            env[ENV_POLICY_DIR] = empty_policy_dir
            with mock.patch.dict(os.environ, env, clear=True):
                decision = run_hook_event(payload)
        self.assertEqual(decision["decision"], "ALLOW")
        self.assertEqual(decision["reason"], "no policy matched event")

    def test_missing_policy_dir_raises_policy_load_error_not_silent_allow(self):
        """(d) 정책 디렉토리 부재는 PolicyLoadError 로 명시 전파된다."""
        with tempfile.TemporaryDirectory() as workdir:
            missing_dir = os.path.join(workdir, "does-not-exist")
            payload = _bash_payload("git commit -m x", cwd=workdir)
            env = _clear_env()
            env[ENV_POLICY_DIR] = missing_dir
            with mock.patch.dict(os.environ, env, clear=True):
                with self.assertRaises(PolicyLoadError):
                    run_hook_event(payload)

    def test_project_root_resolution_failure_propagates(self):
        """(e) cwd 를 유도할 수 없으면 조용히 흡수하지 않고 명시 전파한다."""
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": {},
        }
        with mock.patch.dict(os.environ, _clear_env(), clear=True):
            with self.assertRaises(ProjectRootResolutionError):
                run_hook_event(payload)

    def test_explicit_env_vars_override_derived_defaults(self):
        """명시 환경변수 3종은 payload 유도값보다 항상 우선한다."""
        with tempfile.TemporaryDirectory() as explicit_root, tempfile.TemporaryDirectory() as decoy_cwd:
            empty_policy_dir = os.path.join(explicit_root, "policies")
            os.mkdir(empty_policy_dir)
            db_path = os.path.join(explicit_root, "runtime.sqlite3")
            payload = _read_payload(cwd=decoy_cwd)
            env = _clear_env()
            env[ENV_POLICY_DIR] = empty_policy_dir
            env[ENV_PROJECT_ROOT] = explicit_root
            env[ENV_DB_PATH] = db_path
            with mock.patch.dict(os.environ, env, clear=True):
                decision = run_hook_event(payload)
            self.assertEqual(decision["decision"], "ALLOW")
            # 명시 REIN_DB_PATH 는 `_resolve_db_path()` 의 `LocalStateRoot.
            # ensure()` 대체 경로(`.rein/state/` 자동 생성)를 타지 않는다 —
            # explicit_root 밑에 `.rein/` 이 생기지 않아야 override 가 실제로
            # 적용됐다는 방증이다.
            self.assertFalse(os.path.exists(os.path.join(explicit_root, ".rein")))
            # decoy_cwd 하위에는 아무 것도 남지 않아야 한다 — project_root 로
            # 쓰이지 않았다는 방증.
            self.assertEqual(os.listdir(decoy_cwd), [])


class RunEventContractUnchangedTest(unittest.TestCase):
    """(f) `_evaluate_event()` 추출이 `run_event()` 기존 계약을 바꾸지 않았다."""

    def test_run_event_still_defaults_to_allow_with_zero_policies_when_env_unset(self):
        payload_text = (
            '{"hook_event_name": "PreToolUse", "tool_name": "Bash", '
            '"tool_input": {"command": "git commit -m x"}}'
        )
        with mock.patch.dict(os.environ, _clear_env(), clear=True):
            response = run_event(payload_text)
        self.assertEqual(response["decision"], "ALLOW")
        self.assertEqual(response["reason"], "no policy matched event")


if __name__ == "__main__":
    unittest.main()
