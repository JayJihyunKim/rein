"""Phase 6 4회차 독립 리뷰 Medium 2 — `_open_approval_consumption_store`
의 오류 분류 정정 (spec §3.4 판단불능 ≠ 부재 경계).

## 재현

`_open_approval_consumption_store`(`rein/cli/__init__.py`)는 db 경로의
실제 파일 종류를 `os.lstat` 로 먼저 확인한다. 수리 전에는 `except
OSError:` 로 그 호출을 너무 넓게 받아, "파일이 정말 없음"
(`FileNotFoundError`)과 "lstat 자체가 다른 이유로 실패함"(예: 상위
디렉터리 권한 거부 → `PermissionError`)을 똑같이 "부재"로 흡수했다.

독립 리뷰어 재현: 권한 오류가 나는 상황에서 **설명 경로**
(`run_explain`, `read_only=True`)는 이 broad except 를 타고 무해한 빈
대역(`_ReadOnlyEmptyApprovalConsumptionStore`)으로 "소비되지 않음"
판정을 조용히 내리는데, **실제 실행 경로**(`run_event`, `read_only=
False`)는 같은 권한 오류를 다시 만날 수 있어(실제 저장소를 열려는
시도) 설명과 실행이 반대 판정을 낼 위험이 있었다 — 직전 라운드에 고친
매달린 심볼릭 링크 결함과 같은 클래스: "오류"를 "부재"로 흡수하면 안
되는 지점에서 흡수했다.

## 수리

`FileNotFoundError`(POSIX ENOENT)만 "진짜 없음"으로 흡수한다. 그 밖의
`OSError`(권한 거부 등)는 판단 재료를 확보하지 못한 상태이지 "부재"가
아니므로 그대로 전파한다. 두 호출부(`run_event`/`run_explain`) 모두
같은 `_open_approval_consumption_store()` 를 거치고, Medium 1 수리
이후에는 그 함수가 lazy fact resolver 안에서 호출되므로(`rein/cli/
__init__.py::_build_fact_resolvers()` 참조), 전파된 예외는
`EvaluationContext._resolve()` 에 의해 `FactResolutionError` 로 감싸져
evaluator 의 `failure_mode` 로 안전하게 흡수된다 — 두 함수 모두 같은
이유로 같은 판정(fail-closed BLOCK)에 도달한다.
"""
import json
import os
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
    ENV_POLICY_DIR,
    ENV_PROJECT_ROOT,
    _open_approval_consumption_store,
    run_event,
)
from rein.cli.explain import run_explain  # noqa: E402
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402
from rein.platform.storage.local import LocalStateRoot  # noqa: E402


def _init_git_repo(base_dir):
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
    with open(
        os.path.join(base_dir, ".gitignore"), "w", encoding="utf-8"
    ) as handle:
        handle.write(".rein/\ntrail/\n")
    subprocess.run(["git", "add", ".gitignore"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "gitignore"], cwd=base_dir, check=True
    )


def _write_approval_policy(project_root):
    policy_dir = os.path.join(project_root, "policies")
    os.makedirs(policy_dir, exist_ok=True)
    with open(
        os.path.join(policy_dir, "10-approval.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "trigger: tool.pre\n"
            "when:\n"
            "  tool: Bash\n"
            "require:\n"
            "  - user_approval\n"
            "failure_mode: closed\n"
        )
    with open(
        os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write('version: "1"\n')
    return policy_dir


def _write_authority_policy(project_root, switched_names=REQUIREMENT_NAMES):
    # Phase 7 결정 4(2026-08-19)로 배포 기본값이 5축→3축(code_review/
    # security_review/active_task)으로 좁혀져 user_approval 은 기본
    # 미전환(평가 시 자동 충족, fact 조회 없이 개입 안 함)이 됐다 —
    # 이 파일의 통합 경계 테스트(`ExplainAndRunEventAgreeOnPermissionErrorTest`)
    # 는 "user_approval 이 실제로 확인되어 lazy 승인 저장소 fact 가
    # 조회된다"는 전제 위에 서 있으므로, opt-in override 로 5축 전부
    # (구 배포 기본값과 동일 구성)를 전환해 옛 동작을 재현한다. 원
    # 단언(오류 분류/parity)은 변경하지 않는다.
    policy_dir = os.path.join(project_root, ".rein", "policy")
    os.makedirs(policy_dir, exist_ok=True)
    with open(
        os.path.join(policy_dir, "authority.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "switched:\n"
            + "".join("  - {}\n".format(name) for name in switched_names)
        )


def _bash_payload(command="ls"):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )


def _patched_lstat_raising_at(target_path, error):
    """`os.lstat` 을 감싸 `target_path` 호출에서만 지정한 예외를 던진다."""
    original = os.lstat

    def _faulty(path, *args, **kwargs):
        if path == target_path:
            raise error
        return original(path, *args, **kwargs)

    return _faulty


class OpenApprovalConsumptionStoreErrorClassificationTest(unittest.TestCase):
    """`_open_approval_consumption_store()` 단위 — FileNotFoundError 만
    부재로 흡수하고, 나머지 OSError 는 전파해야 한다."""

    def test_file_not_found_is_absorbed_as_absent(self):
        with tempfile.TemporaryDirectory() as project_root:
            # db 경로 자체와 그 부모 디렉터리도 아직 없다 — 진짜 부재.
            store = _open_approval_consumption_store(
                project_root, read_only=True
            )
        # 무해한 read-only 대역이 반환된다 — 예외가 아니다.
        self.assertFalse(store.is_consumed("anything"))

    def test_permission_error_during_lstat_propagates_not_absorbed(self):
        with tempfile.TemporaryDirectory() as project_root:
            db_path = LocalStateRoot(project_root).approval_consumption_path()
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(
                    PermissionError,
                    msg="a PermissionError while checking the db path must "
                    "not be silently absorbed as 'file absent' — that "
                    "would make run_explain() report 'not consumed' while "
                    "the real run_event() path may see a different "
                    "outcome (Medium 2)",
                ):
                    _open_approval_consumption_store(
                        project_root, read_only=True
                    )

    def test_not_a_directory_error_during_lstat_propagates_not_absorbed(
        self,
    ):
        """경로 구성요소가 디렉터리가 아닌 경우(`NotADirectoryError`) —
        FileNotFoundError 가 아닌 다른 OSError 부류도 함께 확인한다."""
        with tempfile.TemporaryDirectory() as project_root:
            db_path = LocalStateRoot(project_root).approval_consumption_path()
            faulty = _patched_lstat_raising_at(
                db_path, NotADirectoryError(20, "Not a directory")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(NotADirectoryError):
                    _open_approval_consumption_store(
                        project_root, read_only=False
                    )

    def test_read_only_and_writable_paths_both_propagate_the_same_error(
        self,
    ):
        """`read_only=True`/`False` 양쪽 모두(설명·실행 두 호출부에
        대응) 같은 오류 분류를 공유한다 — 어느 한쪽만 고쳐지는 회귀를
        막는다."""
        with tempfile.TemporaryDirectory() as project_root:
            db_path = LocalStateRoot(project_root).approval_consumption_path()
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with self.assertRaises(PermissionError):
                    _open_approval_consumption_store(
                        project_root, read_only=True
                    )
                with self.assertRaises(PermissionError):
                    _open_approval_consumption_store(
                        project_root, read_only=False
                    )


class ExplainAndRunEventAgreeOnPermissionErrorTest(unittest.TestCase):
    """통합 경계 — 실제 `run_event()`/`run_explain()` 왕복에서도 권한
    오류가 두 함수를 갈라놓지 않는다 (Medium 1 의 lazy 화 이후에는
    evaluator 의 failure_mode 로 흡수되어 두 함수 모두 동일하게
    BLOCK 한다)."""

    def test_both_entry_points_block_identically_on_lstat_permission_error(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            _write_authority_policy(project_root)
            db_path = LocalStateRoot(project_root).approval_consumption_path()

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            faulty = _patched_lstat_raising_at(
                db_path, PermissionError(13, "Permission denied")
            )
            with mock.patch("os.lstat", faulty):
                with mock.patch.dict(os.environ, env):
                    explanation = run_explain(_bash_payload())
                    response = run_event(_bash_payload())

        for label, result in (
            ("run_explain", explanation),
            ("run_event", response),
        ):
            self.assertEqual(
                result["decision"],
                "BLOCK",
                msg="{} must fail closed on a permission error while "
                "opening the approval consumption store, not silently "
                "treat it as 'not consumed'".format(label),
            )
            self.assertIn(
                "Permission denied",
                result["reason"],
                msg="{} reason must surface the underlying permission "
                "error, not swallow it".format(label),
            )

        self.assertEqual(explanation["decision"], response["decision"])


if __name__ == "__main__":
    unittest.main()
