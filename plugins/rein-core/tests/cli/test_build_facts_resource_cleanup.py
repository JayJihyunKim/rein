"""승인 소비 저장소 자원 정리 경계 (Phase 6 Task 6.1 Low F 최초 수리 +
Phase 6 4회차 독립 리뷰 Medium 1 재설계).

## 원래 버전 (Low F, Task 6.1) — 지금은 무효화된 전제

`run_event()`/`run_explain()` 은 원래 `_build_facts()` 가 승인 소비
저장소(sqlite 연결)를 **값으로 즉시** 열었다 — 그 반환값을 `try:`/
`finally:` 로 감싸기 이전에 다른 구성 단계(`_build_registry()`/
`_build_evidence_source()`/`sqlite_store.open_store()`)를 실행했는데,
그 단계들 중 하나라도 예외를 던지면 이미 열린 저장소 연결이
`finally` 진입 전에 함수 밖으로 새어나갔다. 최초 수리는 그 대입
직후부터 나머지 전체를 하나의 try/finally 로 감싸 해결했다.

## Medium 1 (Phase 6 4회차 독립 리뷰) 이후 — "열림" 자체가 lazy 해졌다

`approval.consumption_store` 는 더 이상 `_build_facts()` 가 값으로
채우지 않는다 — `_build_fact_resolvers()` 가 등록하는 **lazy resolver**
로 옮겨갔다(`rein/cli/__init__.py::_build_fact_resolvers()` 모듈
docstring "Medium 1"/"자원 정리" 절). 이 저장소는 이제 실제로
`context.fact("approval.consumption_store")` 가 조회될 때만 —
매칭된 policy 가 `user_approval` 을 요구하고 그 capability 구현체
(`UserApprovalRequirement.evaluate()`)가 실제로 그 fact 를 조회할
때만 — 열린다. 이는 "자원 정리 책임" 경계를 근본적으로 바꾼다:

- **열리지 않았으면 닫을 것도 없다** — 예를 들어 `_build_registry()`
  가 `runtime.evaluate()`/`evaluator.evaluate()` 호출 **이전**에
  실패하면, 그 시점까지 resolver 는 단 한 번도 조회되지 않았으므로
  저장소는 애초에 열리지 않았다. 이 경우 close() 호출 횟수는 **0**
  이어야 한다(구 버전의 "1이어야 한다"는 이제 틀린 기대치다 — 구
  버전은 저장소가 항상 즉시 열렸다는, 더 이상 참이 아닌 전제 위에
  서 있었다).
- **열렸으면 반드시 닫혀야 한다** — matched `user_approval` policy 로
  실제 평가가 일어나 resolver 가 조회되면, 정상 완료든(happy path)
  이후 어딘가에서 예외가 나든(원래 Low F 가 겨냥한 시나리오) 정확히
  1회 닫혀야 한다.

이 파일은 이 두 경계를 별도 테스트 클래스로 나눠 고정한다.
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

from rein.cli import ENV_POLICY_DIR, ENV_PROJECT_ROOT, run_event  # noqa: E402
from rein.cli.explain import run_explain  # noqa: E402
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402
from rein.platform.storage.approval_store import (  # noqa: E402
    ApprovalConsumptionStore,
    ReadOnlyApprovalConsumptionStore,
)


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
    # user_approval 은 증거 발급형 capability 다 — Medium D 수리 후
    # 버전 파일이 없으면 이 fixture 자체가 설정 오류로 차단된다(정확한
    # 동작). 이 파일의 테스트는 Medium D 가 아니라 자원 정리를 겨냥
    # 하므로, 그 차단을 피하기 위해 유효한 버전 파일을 둔다.
    with open(
        os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write('version: "1"\n')
    return policy_dir


def _write_authority_policy(project_root, switched_names=REQUIREMENT_NAMES):
    # Phase 7 결정 4(2026-08-19)로 배포 기본값이 5축→3축(code_review/
    # security_review/active_task)으로 좁혀져 user_approval 은 기본
    # 미전환(평가 시 자동 충족, evidence/fact 조회 없이 개입 안 함)이
    # 됐다 — 이 파일의 테스트들은 "user_approval 이 실제로 확인되어
    # lazy 승인 저장소가 열린다"는 전제 위에 서 있으므로, opt-in
    # override 로 5축 전부(구 배포 기본값과 동일한 구성)를 전환해
    # 옛 동작을 재현한다(원래 단언은 변경하지 않는다 — 테스트 목적은
    # "자원 정리 횟수"이지 authority 기본값 자체가 아니다).
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


class _CloseSpy:
    """승인 소비 저장소 `close()` 호출 횟수를 세는 monkeypatch 헬퍼.

    Phase 6 3회차 재리뷰 Medium C(`_open_approval_consumption_store`
    가 이미 존재하는 파일을 읽기 전용으로 열 때 `ApprovalConsumptionStore`
    대신 `ReadOnlyApprovalConsumptionStore` 를 쓰도록 바뀜, `rein/
    platform/storage/approval_store.py` 참조) 이후에는 어느 클래스가
    실제로 열리는지가 시나리오(파일 존재 여부·read_only)에 따라
    갈리므로, 이 spy 는 **두 클래스 모두**의 `close()` 를 계측한다 —
    이 파일의 관심사는 "어떤 구현체든 정확히 필요한 횟수만 닫히는가"
    이지 특정 클래스 자체가 아니다.
    """

    def __init__(self):
        self.calls = 0
        self._originals = {
            ApprovalConsumptionStore: ApprovalConsumptionStore.close,
            ReadOnlyApprovalConsumptionStore: (
                ReadOnlyApprovalConsumptionStore.close
            ),
        }

    def __enter__(self):
        spy = self
        self._patchers = []
        for cls, original in self._originals.items():

            def _spy_close(store_self, _original=original):
                spy.calls += 1
                return _original(store_self)

            patcher = mock.patch.object(cls, "close", _spy_close)
            patcher.start()
            self._patchers.append(patcher)
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        for patcher in self._patchers:
            patcher.stop()
        return False


class NotOpenedWhenFailureHappensBeforeEvaluationTest(unittest.TestCase):
    """경계 1 — 평가가 시작되기도 전에 실패하면 저장소는 애초에 열리지
    않는다 (close 호출 0회가 맞는 기대치).

    `_build_registry()` 는 `run_event()`/`run_explain()` 양쪽 모두
    `runtime.evaluate()`/`evaluator.evaluate()` 호출 **이전**에 실행된다
    — 그 시점까지는 lazy resolver 가 단 한 번도 조회되지 않았으므로,
    `_build_registry()` 가 여기서 실패하면 승인 소비 저장소는 한 번도
    열리지 않는다. `_CloseSpy` 가 0회 호출을 관측해야 이 경계가 맞다
    (구 Low F 테스트는 "저장소가 이미 즉시 열려 있다"는, Medium 1 수리
    이후로는 더 이상 참이 아닌 전제로 1회를 기대했다).
    """

    def test_run_event_registry_failure_before_evaluate_opens_nothing(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with _CloseSpy() as spy:
                with mock.patch(
                    "rein.cli._build_registry",
                    side_effect=RuntimeError("boom-registry"),
                ):
                    with mock.patch.dict(os.environ, env):
                        with self.assertRaises(RuntimeError):
                            run_event(_bash_payload())

            self.assertEqual(
                spy.calls,
                0,
                msg="_build_registry() raises before runtime.evaluate() is "
                "ever called, so the lazy approval-store resolver never "
                "fires — nothing was opened, so close() must not be "
                "called either (opened=0 implies closed=0)",
            )

    def test_run_explain_registry_failure_before_evaluate_opens_nothing(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with _CloseSpy() as spy:
                with mock.patch(
                    "rein.cli.explain._build_registry",
                    side_effect=RuntimeError("boom-registry"),
                ):
                    with mock.patch.dict(os.environ, env):
                        with self.assertRaises(RuntimeError):
                            run_explain(_bash_payload())

            self.assertEqual(
                spy.calls,
                0,
                msg="explain._build_registry() raises before "
                "evaluator.evaluate() is ever called, so the lazy "
                "approval-store resolver never fires — nothing was "
                "opened, so close() must not be called",
            )


class OpenedDuringEvaluationIsClosedExactlyOnceTest(unittest.TestCase):
    """경계 2 — 평가가 실제로 승인 소비 저장소를 조회하면(정상 완료),
    정확히 1회 닫혀야 한다.

    `_write_approval_policy()` 의 policy 는 `require: [user_approval]`
    이므로, matched policy 평가 도중 `UserApprovalRequirement.evaluate()`
    가 `context.fact("approval.consumption_store")` 를 실제로 조회한다
    (증거가 전혀 없어도 digest/action/policy.version 축까지는 항상
    확인하므로 이 조회 자체는 일어난다 — `rein/capabilities/approval/
    capability.py::UserApprovalRequirement.evaluate` 참조). 이 시나리오는
    예외 주입 없이도 "열렸으면 닫혀야 한다" 경계를 고정한다.
    """

    def test_run_event_closes_store_once_on_normal_completion(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            _write_authority_policy(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with _CloseSpy() as spy:
                with mock.patch.dict(os.environ, env):
                    response = run_event(_bash_payload())

        # sanity — user_approval 이 실제로 확인 대상이 됐어야 이 0/1
        # 회 단언이 의미가 있다(전혀 매칭되지 않았다면 애초에 이
        # 시나리오가 아니다).
        self.assertEqual(response["missing_requirements"], ["user_approval"])
        self.assertEqual(
            spy.calls,
            1,
            msg="the approval consumption store is opened lazily during "
            "evaluation (matched user_approval policy) and must be "
            "closed exactly once on normal completion",
        )

    def test_run_explain_closes_store_once_on_normal_completion(self):
        from rein.platform.storage.local import LocalStateRoot

        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            _write_authority_policy(project_root)

            # DB 파일을 미리 만들어 둔다 — Medium E 계약상 `run_explain()`
            # 은 파일이 아직 없으면 실제 자원을 전혀 열지 않는 무해한
            # 대역(`_ReadOnlyEmptyApprovalConsumptionStore`, close() 가
            # 이미 no-op)을 쓴다. 이 테스트가 겨냥하는 것은 "실제로 연
            # 자원은 반드시 닫힌다" 는 경계이므로, 실제
            # `ReadOnlyApprovalConsumptionStore` 가 열리도록 파일을
            # 미리 준비한다(`_open_approval_consumption_store` 의 "이미
            # 존재하면 read_only 여도 항상 진짜 store" 규칙).
            state_root = LocalStateRoot(project_root)
            state_root.ensure()
            ApprovalConsumptionStore.open(
                state_root.approval_consumption_path()
            ).close()

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with _CloseSpy() as spy:
                with mock.patch.dict(os.environ, env):
                    explanation = run_explain(_bash_payload())

        self.assertEqual(
            explanation["basis"]["missing_requirements"], ["user_approval"]
        )
        self.assertEqual(
            spy.calls,
            1,
            msg="run_explain must also close the lazily-opened approval "
            "consumption store exactly once on normal completion",
        )


class RunEventClosesApprovalStoreDespiteLaterFailureTest(unittest.TestCase):
    """경계 2 의 원래 Low F 취지 재현 — 저장소가 열린 *이후*(evaluate()
    가 이미 resolver 를 조회한 뒤) 별개의 단계가 실패해도 여전히
    정확히 1회 닫힌다.

    `runtime.evaluate()` 는 `evaluator.evaluate()`(resolver 를 조회하는
    지점)를 먼저 실행하고, decision 이 ALLOW 면 그 뒤에
    `_commit_pending_consumptions()` 를 실행한다 — 이 함수를 실패하도록
    주입하면 "resolver 는 이미 조회됐지만 evaluate() 자체가 나중에
    실패하는" 상황을 인위적 sqlite mock 없이도 정확히 재현할 수 있다
    (mock 대상이 `sqlite3.Connection.close` 같은 저수준 API 라면 승인
    저장소 자신의 close() 경로까지 오염시켜 이 테스트의 관측 대상을
    훼손하므로 피한다).
    """

    def test_close_called_once_when_commit_step_raises_after_resolver_fired(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            _write_authority_policy(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with _CloseSpy() as spy:
                with mock.patch(
                    "rein.engine.runtime._commit_pending_consumptions",
                    side_effect=RuntimeError("boom-commit"),
                ):
                    with mock.patch.dict(os.environ, env):
                        with self.assertRaises(RuntimeError):
                            run_event(_bash_payload())

            self.assertEqual(
                spy.calls,
                1,
                msg="the approval consumption store was already opened by "
                "the lazy resolver inside evaluator.evaluate() before "
                "_commit_pending_consumptions() raised — it must still be "
                "closed exactly once despite that later failure (Low F "
                "intent, preserved under the lazy design)",
            )


if __name__ == "__main__":
    unittest.main()
