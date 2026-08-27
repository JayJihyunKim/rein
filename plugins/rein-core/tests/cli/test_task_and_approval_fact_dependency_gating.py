"""Phase 6 4회차 독립 리뷰 Medium 1 — task.active/승인 관련 fact 의 진짜
지연 계산 (spec §3.2, §7).

## 배경 — 직전 수리(3회차)가 남긴 잔여 결함

`tests/cli/test_changeset_fact_dependency_gating.py` 가 이미 changeset
해시 3종(`changeset.digest`/`changeset.sensitive_digest`/`changeset.tag`)
이 값이 아니라 진짜 lazy resolver 로 바뀌었음을 고정했다. 그런데
`task.active`/`changeset.task_relevant`(`active_task` requirement 축)와
`action.current`/`approval.consumption_store`(`user_approval` requirement
축) 4개는 여전히 `_build_facts()` 안에서 `_declared_requirements()`
(trigger 만 보고 `when` 은 무시하는 근사)로 게이팅되는 **값**으로 즉시
계산됐다 — changeset 해시가 이미 겪은 것과 정확히 같은 부류의 결함이다.

독립 리뷰어 재현: `when: command.type: git.commit` 인 `active_task`
policy 를 로드한 상태에서 파일 편집(Edit) 이벤트를 평가해도 —
`command.type` fact 자체가 없어 그 policy 는 실제로는 한 번도 매칭되지
않는데도 — `task_active_identifier()`(`os.listdir` I/O 2회)가 1회
실행됐다. 이 파일은 changeset 해시 스위트와 동일한 방법론(실제 호출
횟수 계측, declared 근사가 아니라)으로 이 네 fact 전부에 대해 같은
계약을 고정한다.

## 수리

`rein.cli._build_fact_resolvers()` 가 changeset 해시 3종을 등록하던
같은 구조를 그대로 확장해 이 4개도 lazy resolver 로 등록한다(새
메커니즘 없음 — `_build_fact_resolvers()` 모듈 docstring "Medium 1" 절
참조). `task.active`/`changeset.task_relevant` 는 git.* 명령 이벤트에서
changeset 해시와 같은 `_git_changeset_facts()` closure 캐시를 공유해
"cycle 당 1회" 계약을 유지한다.
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

import subprocess  # noqa: E402

import rein.cli as rein_cli  # noqa: E402
from rein.cli import (  # noqa: E402
    ENV_POLICY_DIR,
    ENV_PROJECT_ROOT,
    FACT_ACTION_CURRENT,
    FACT_APPROVAL_CONSUMPTION_STORE,
    FACT_CHANGESET_DIGEST,
    FACT_CHANGESET_TASK_RELEVANT,
    FACT_TASK_ACTIVE,
    _build_fact_resolvers,
    _build_facts,
    run_event,
)
from rein.engine import runtime  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.platform.claude import facts as claude_facts  # noqa: E402
from rein.platform.task import facts as task_facts  # noqa: E402


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


def _loaded_policy(requirement_names, trigger="tool.pre", when=None):
    return {
        "policy_id": "test-policy",
        "fields": {
            "trigger": trigger,
            "when": when or {},
            "require": list(requirement_names),
            "failure_mode": "closed",
        },
    }


class BuildFactsNeverComputesTaskOrApprovalFactsTest(unittest.TestCase):
    """`_build_facts()` 자신은 이제 이 4개 fact 를 절대 값으로 계산하지
    않는다 — project_root/policies/이벤트 조합과 무관하게 항상 부재."""

    def test_absent_even_for_matching_active_task_and_user_approval_policies(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            os.makedirs(os.path.join(project_root, "trail", "dod"))
            with open(
                os.path.join(
                    project_root, "trail", "dod", "dod-2026-08-13-foo.md"
                ),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("# DoD\n")
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }
            facts = _build_facts(
                event,
                project_root,
                policies=[
                    _loaded_policy(
                        ["active_task"],
                        trigger="tool.pre",
                        when={"command.type": "git.commit"},
                    ),
                    _loaded_policy(
                        ["user_approval"],
                        trigger="tool.pre",
                        when={"command.type": "git.commit"},
                    ),
                ],
            )
        self.assertNotIn(FACT_TASK_ACTIVE, facts)
        self.assertNotIn(FACT_CHANGESET_TASK_RELEVANT, facts)
        self.assertNotIn(FACT_ACTION_CURRENT, facts)
        self.assertNotIn(FACT_APPROVAL_CONSUMPTION_STORE, facts)


class TaskActiveLazyInvocationTest(unittest.TestCase):
    """`task.active`/`changeset.task_relevant` — 실제 호출 횟수로 lazy
    계약을 고정한다 (리뷰어 재현 시나리오 그대로)."""

    def _count_task_active_calls(self, run):
        original = task_facts.task_active_identifier
        calls = []

        def counting(*args, **kwargs):
            calls.append((args, kwargs))
            return original(*args, **kwargs)

        with mock.patch.object(
            task_facts, "task_active_identifier", counting
        ):
            run()
        return calls

    def test_edit_event_against_git_only_active_task_policy_never_computes_task_active(
        self,
    ):
        """독립 리뷰어의 정확한 재현: `when: command.type: git.commit` 인
        `active_task` policy 를 로드한 상태에서 파일 편집 이벤트를 평가해도
        `command.type` fact 자체가 없어 `when` 이 매칭되지 않는다 — require:
        순회가 시작되지 않으므로 `task.active` resolver 는 단 한 번도
        조회되지 않아야 한다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Edit",
                "payload": {
                    "file_path": os.path.join(project_root, "a.py"),
                    "old_string": "a",
                    "new_string": "b",
                },
            }
            policies = [
                _loaded_policy(
                    ["active_task"],
                    trigger="tool.pre",
                    when={"command.type": "git.commit"},
                )
            ]

            def run():
                facts = _build_facts(event, project_root, policies=policies)
                resolvers = _build_fact_resolvers(event, project_root)
                runtime.evaluate(
                    "tool.pre", facts, policies, fact_resolvers=resolvers
                )

            calls = self._count_task_active_calls(run)
        self.assertEqual(
            calls,
            [],
            msg="Edit 이벤트에는 command.type fact 가 없어 when 매칭이 "
            "실패해야 한다 — task.active resolver 는 단 한 번도 조회되지 "
            "않아야 한다 (수리 전에는 1회 조회됐다)",
        )

    def test_matching_git_commit_event_computes_task_active_exactly_once(
        self,
    ):
        """양성 경로는 `EvaluationContext.fact()` 를 직접 조회해 확인한다
        (`test_changeset_fact_dependency_gating.py::LazyResolverInvocation
        Test.test_matching_policy_computes_changeset_exactly_once_across_
        multiple_facts` 와 동일한 관례) — registry 없이 `runtime.evaluate()`
        를 통하면 등록 구현체가 없어 존재검사 fallback(`context.evidence_for`
        만 조회, `context.fact()` 는 조회 안 함)을 타므로, "실제 policy
        require: 를 평가하는 capability 구현체가 조회할 때" 라는 계약을
        registry 의존 없이 이 방식으로 직접 고정한다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)

            def run():
                resolvers = _build_fact_resolvers(
                    {
                        "name": "tool.pre",
                        "tool": "Bash",
                        "payload": {"command": "git commit -m x"},
                    },
                    project_root,
                )
                context = EvaluationContext(fact_resolvers=resolvers)
                context.fact(FACT_TASK_ACTIVE)
                context.fact(FACT_TASK_ACTIVE)  # 같은 cycle 안 재조회

            calls = self._count_task_active_calls(run)
        self.assertEqual(
            len(calls),
            1,
            msg="task.active must be computed exactly once per cycle even "
            "when queried more than once within the same "
            "EvaluationContext (request-scoped cache, same contract as "
            "the changeset hash trio)",
        )

    def test_task_relevant_shares_git_changeset_cache_with_digest_resolver(
        self,
    ):
        """`active_task`+`code_review` 를 같은 cycle 에서 함께 요구하는
        git.* 명령 이벤트 — `changeset.task_relevant`(task_relevant 경로
        소스로 git changeset 경로가 필요) 와 `changeset.digest` 를 각각
        조회해도 기반 `_git_changeset_facts()` 호출은 1회로 묶여야 한다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }

            calls = []
            original = rein_cli._git_changeset_facts

            def counting(*args, **kwargs):
                calls.append(1)
                return original(*args, **kwargs)

            with mock.patch.object(
                rein_cli, "_git_changeset_facts", counting
            ):
                resolvers = _build_fact_resolvers(event, project_root)
                context = EvaluationContext(fact_resolvers=resolvers)
                context.fact(FACT_CHANGESET_DIGEST)
                context.fact(FACT_CHANGESET_TASK_RELEVANT)

            self.assertEqual(
                len(calls),
                1,
                msg="changeset.digest and changeset.task_relevant must "
                "share the same underlying _git_changeset_facts() "
                "computation within one cycle (cycle-scoped cache, same "
                "contract as the changeset hash trio)",
            )


class ApprovalFactsLazyInvocationTest(unittest.TestCase):
    """`action.current`/`approval.consumption_store` — 실제 호출 횟수로
    lazy 계약을 고정한다."""

    def _count_action_current_calls(self, run):
        original = claude_facts.current_action_identifier
        calls = []

        def counting(*args, **kwargs):
            calls.append((args, kwargs))
            return original(*args, **kwargs)

        with mock.patch.object(
            claude_facts, "current_action_identifier", counting
        ):
            run()
        return calls

    def test_edit_event_against_git_only_user_approval_policy_never_computes_action_current(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Edit",
                "payload": {
                    "file_path": os.path.join(project_root, "a.py"),
                    "old_string": "a",
                    "new_string": "b",
                },
            }
            policies = [
                _loaded_policy(
                    ["user_approval"],
                    trigger="tool.pre",
                    when={"command.type": "git.commit"},
                )
            ]

            def run():
                facts = _build_facts(event, project_root, policies=policies)
                resolvers = _build_fact_resolvers(event, project_root)
                runtime.evaluate(
                    "tool.pre", facts, policies, fact_resolvers=resolvers
                )

            calls = self._count_action_current_calls(run)
        self.assertEqual(
            calls,
            [],
            msg="Edit 이벤트에는 command.type fact 가 없어 when 매칭이 "
            "실패해야 한다 — action.current resolver 는 단 한 번도 "
            "조회되지 않아야 한다",
        )

    def test_edit_event_against_git_only_user_approval_policy_never_opens_approval_store(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Edit",
                "payload": {
                    "file_path": os.path.join(project_root, "a.py"),
                    "old_string": "a",
                    "new_string": "b",
                },
            }
            policies = [
                _loaded_policy(
                    ["user_approval"],
                    trigger="tool.pre",
                    when={"command.type": "git.commit"},
                )
            ]

            opened = []
            resolvers = _build_fact_resolvers(
                event, project_root, opened_approval_store=opened
            )
            facts = _build_facts(event, project_root, policies=policies)
            runtime.evaluate(
                "tool.pre", facts, policies, fact_resolvers=resolvers
            )

            self.assertEqual(
                opened,
                [],
                msg="the approval consumption store must not be opened at "
                "all when the matched-trigger policy's when: clause never "
                "actually matches",
            )


class ResponseTransparencyTest(unittest.TestCase):
    """`run_event()` 의 응답 `facts` 는 실제로 조회된 lazy fact 만
    반영한다 — 조회되지 않았으면 응답에도 없다(진짜 lazy 를 응답에서도
    있는 그대로 반영)."""

    def test_task_active_absent_from_response_when_policy_never_matches(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = os.path.join(project_root, "policies")
            os.makedirs(policy_dir, exist_ok=True)
            with open(
                os.path.join(policy_dir, "10-active-task.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(
                    "trigger: tool.pre\n"
                    "when:\n"
                    "  command.type: git.commit\n"
                    "require:\n"
                    "  - active_task\n"
                    "failure_mode: closed\n"
                )
            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            payload = json.dumps(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Edit",
                    "tool_input": {
                        "file_path": os.path.join(project_root, "a.py"),
                        "old_string": "a",
                        "new_string": "b",
                    },
                }
            )
            with mock.patch.dict(os.environ, env):
                response = run_event(payload)

        self.assertEqual(response["decision"], "ALLOW")
        self.assertEqual(response["reason"], "no policy matched event")
        self.assertNotIn("task.active", response["facts"])
        self.assertNotIn("changeset.task_relevant", response["facts"])

    def test_task_active_present_in_response_when_policy_actually_matches(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            os.makedirs(os.path.join(project_root, "trail", "dod"))
            with open(
                os.path.join(
                    project_root, "trail", "dod", "dod-2026-08-13-foo.md"
                ),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("# DoD\n")
            policy_dir = os.path.join(project_root, "policies")
            os.makedirs(policy_dir, exist_ok=True)
            with open(
                os.path.join(policy_dir, "10-active-task.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(
                    "trigger: tool.pre\n"
                    "when:\n"
                    "  command.type: git.commit\n"
                    "require:\n"
                    "  - active_task\n"
                    "failure_mode: closed\n"
                )
            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            payload = json.dumps(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "git commit -m x"},
                }
            )
            with mock.patch.dict(os.environ, env):
                response = run_event(payload)

        self.assertEqual(response["decision"], "ALLOW")
        self.assertEqual(
            response["facts"].get("task.active"), "dod-2026-08-13-foo"
        )


if __name__ == "__main__":
    unittest.main()
