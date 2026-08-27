"""Phase 6 3회차 재리뷰 High 1 — 진짜 지연 계산으로 전환 (spec §3.2/§7).

## 이전 버전과의 차이 (읽기 전 필수 맥락)

이 파일은 원래(Phase 6 수리 워커 F) `_build_facts()` 가
`_declared_requirements(policies)`(trigger 만 보고 `when` 은 무시하는
근사)로 changeset 해시 계산 여부를 미리 정하던 방향을 재현·고정했다.
독립 리뷰어 3회차가 그 근사 자체의 실효성을 실증으로 반박했다: 배포
기본 policy 4개(`commit`/`push`/`push-testing`/`release`)가 전부 같은
trigger(`tool.pre`)를 공유하므로, 그 근사는 사실상 모든 tool 이벤트
(Edit/Write 같은 파일 편집 포함)에서 changeset 전체를 해싱했다 —
`when: command.type: git.commit` 같은 실제 매칭 조건은 전혀 보지 않았기
때문이다. 이 비용 게이팅은 훅 라우팅 전환의 선행 조건으로 지목됐다
(저장소 계약
`fact-resolver-computes-only-policy-demanded-facts-once-per-cycle`).

수리 후 `_build_facts()` 는 changeset 해시 3종을 전혀 계산하지 않는다
— `rein.cli._build_fact_resolvers()` 가 `EvaluationContext.
fact_resolvers` 에 lazy resolver 로만 등록하고, 실제 계산은 매칭된
policy 의 `require:` 를 평가하는 capability 구현체가
`context.fact(key)` 를 호출할 때만 일어난다(`rein/engine/runtime.py`
모듈 docstring "fact_resolvers 배선" 절, `tests/unit/
test_lazy_fact_resolution.py` 가 lazy 계약 자체의 명세).

이 파일은 이제 "declared 됐으니까 계산됐겠지"가 아니라 **실제 호출
횟수**로 그 계약을 직접 고정한다:

- `_build_facts()` 자신은 이제 이 3개 fact 를 절대 값으로 채우지 않는다
  (아래 `BuildFactsNeverComputesChangesetHashesTest`).
- 매칭되지 않는 policy(`when` 불일치)는 resolver 조회 자체를 유발하지
  않는다 — 파일 편집 이벤트에서 `_git_changeset_facts()` 가 단 한 번도
  불리지 않는다(`LazyResolverInvocationTest`, 이전 버전의 "방향 1"
  재현을 실제 계측으로 대체).
- 실제로 매칭되면 계산되고, 여러 fact/여러 조회가 같은 cycle 안에서
  겹쳐도 기반 git 연산(`_git_changeset_facts`)은 정확히 1회만 일어난다
  (`LazyResolverInvocationTest`, 이전 버전의 "방향 2" 재현을 대체하며
  "사이클당 1회" 계약까지 함께 고정).
"""
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
    FACT_CHANGESET_DIGEST,
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_CHANGESET_TAG,
    _build_fact_resolvers,
    _build_facts,
)
from rein.engine import runtime  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402


def _init_git_repo(base_dir):
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
    with open(os.path.join(base_dir, "a.py"), "w", encoding="utf-8") as handle:
        handle.write("print('hi')\n")
    subprocess.run(["git", "add", "a.py"], cwd=base_dir, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True)


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


class BuildFactsNeverComputesChangesetHashesTest(unittest.TestCase):
    """`_build_facts()` 자신은 이제 changeset 해시 3종을 절대 계산하지
    않는다 — project_root/policies/이벤트 조합과 무관하게 항상 부재."""

    def test_digest_and_tag_absent_even_for_matching_git_command_and_declared_policy(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
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
                        ["code_review"],
                        trigger="tool.pre",
                        when={"command.type": "git.commit"},
                    )
                ],
            )
        self.assertNotIn(FACT_CHANGESET_DIGEST, facts)
        self.assertNotIn(FACT_CHANGESET_SENSITIVE_DIGEST, facts)
        self.assertNotIn(FACT_CHANGESET_TAG, facts)


class LazyResolverInvocationTest(unittest.TestCase):
    """`_build_fact_resolvers()` 로 등록된 changeset 해시 resolver 가
    "조회될 때만" 계산되는지를 `_git_changeset_facts` 호출 횟수로 직접
    계측한다 — declared heuristic 이 아니라 실제 evaluate() 경로."""

    def _count_git_changeset_calls(self, run):
        original = rein_cli._git_changeset_facts
        calls = []

        def counting(*args, **kwargs):
            calls.append((args, kwargs))
            return original(*args, **kwargs)

        with mock.patch.object(rein_cli, "_git_changeset_facts", counting):
            run()
        return calls

    def test_edit_event_against_git_only_policy_never_computes_changeset(self):
        """이전 버전의 "방향 1"(waste on undeclared/unmatched) 실제 재현
        지점 — 파일 편집 이벤트에는 `command.type` fact 자체가 없어
        `when: command.type: git.commit` 이 매칭되지 않는다. `require:`
        순회가 시작되지 않으므로 resolver 는 단 한 번도 조회되지 않는다
        (배포 기본 policy 세트가 실제로 겪던 문제와 동일한 조합)."""
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
                    ["code_review"],
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

            calls = self._count_git_changeset_calls(run)
        self.assertEqual(
            calls,
            [],
            msg="Edit 이벤트에는 command.type fact 가 없어 when 매칭이 "
            "실패해야 한다 — require: 순회 자체가 시작되지 않으므로 "
            "changeset 해시 resolver 는 단 한 번도 조회되지 않아야 한다",
        )

    def test_unrelated_read_event_never_computes_changeset(self):
        """git.* 명령이 아닌 Bash 명령·다른 tool 이벤트에서도 when 이
        매칭되지 않으면 동일하게 호출되지 않는다 (대조군)."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "ls -la"},
            }
            policies = [
                _loaded_policy(
                    ["code_review"],
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

            calls = self._count_git_changeset_calls(run)
        self.assertEqual(calls, [])

    def test_matching_policy_computes_changeset_exactly_once_across_multiple_facts(
        self,
    ):
        """이전 버전의 "방향 2"(missed computation) 취지를 대체 — 실제로
        매칭되면 계산되고, digest/sensitive_digest 를 같은 cycle 안에서
        여러 번·여러 fact 로 조회해도(code_review + security_review 가
        각각 다른 fact 를 쓰는 실제 상황과 동등) 기반 git 연산은
        정확히 1회만 일어난다 — "사이클당 1회" 계약."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }

            def run():
                resolvers = _build_fact_resolvers(event, project_root)
                context = EvaluationContext(fact_resolvers=resolvers)
                # code_review 가 changeset.digest 를 조회하고, 같은
                # cycle 안에서 security_review 가 changeset.sensitive_
                # digest 를, tests_passed 가 changeset.tag 를 조회하는
                # 실제 상황과 동등하게 3개 fact 를 모두, 일부는 반복해서
                # 조회한다.
                context.fact(FACT_CHANGESET_DIGEST)
                context.fact(FACT_CHANGESET_DIGEST)
                context.fact(FACT_CHANGESET_SENSITIVE_DIGEST)
                context.fact(FACT_CHANGESET_TAG)

            calls = self._count_git_changeset_calls(run)
        self.assertEqual(
            len(calls),
            1,
            msg="digest/sensitive_digest/tag 를 여러 번·여러 fact 로 "
            "조회해도 기반 git 연산(_git_changeset_facts)은 cycle 당 "
            "1회만 일어나야 한다 (resolver 그룹 내부 closure 메모)",
        )

    def test_new_resolver_group_is_a_new_cycle(self):
        """request-scoped: `_build_fact_resolvers()` 를 다시 호출하면
        (= 새 이벤트/새 cycle) 캐시가 공유되지 않고 다시 계산된다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }

            def run():
                first = _build_fact_resolvers(event, project_root)
                EvaluationContext(fact_resolvers=first).fact(
                    FACT_CHANGESET_DIGEST
                )
                second = _build_fact_resolvers(event, project_root)
                EvaluationContext(fact_resolvers=second).fact(
                    FACT_CHANGESET_DIGEST
                )

            calls = self._count_git_changeset_calls(run)
        self.assertEqual(len(calls), 2)


class PolicyVersionCacheSharingTest(unittest.TestCase):
    """`_build_facts()` 의 `policy_version_out` 과 `_build_fact_resolvers()`
    의 `policy_version_cache` 가 같은 cycle 안에서 빈 list 하나를 공유하면
    (`_evaluate_event()` 배선과 동등), `security_review` 가 declared 인
    cycle 에서도 (non-git `policy_dir` 한정, spec §3.6 s5) `_version.yaml`
    이 두 번 읽히지 않는다.

    **2026-08-20 갱신 (spec §3.6 "선언의 유효 기준" 절 보강 반영)** — 예전
    계약은 "캐시가 있으면 `_security_digest_scope_profile()` 자체가
    호출되지 않는다"였다. git 상태·수명주기 판정(s1~s5/m1~m3, `rein.
    platform.git.facts.resolve_policy_version_digest_scope`)이 들어오면서
    이 계약은 더 이상 안전하지 않다 — 캐시된 `PolicyVersion` 은 naive
    worktree 읽기의 산물이라 git 상태를 반영하지 않으므로, 그 값을 무조건
    신뢰하면 미커밋 편집만으로 strict→sensitive 무음 강등이 다시
    가능해진다(이 보강이 고치는 바로 그 결함). 새 계약: `_security_
    digest_scope_profile()` 은 **항상** 호출되지만(git 상태를 매번
    새로 판정해야 하므로), non-git `policy_dir`(s5) 한정으로 캐시된
    `PolicyVersion` 힌트를 재사용해 `load_policy_version()` 자체의
    재호출만 피한다 — 아래 테스트는 이 갱신된 경계를 고정한다."""

    def _write_version_file(self, policy_dir, text):
        with open(
            os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
        ) as handle:
            handle.write(text)

    def test_shared_cache_still_selects_strict_digest_scope(self):
        """(a) strict 선언 `policy_dir` 로 `_build_fact_resolvers(policy_dir=
        ...)` 를 관통하면 여전히 STAGED 기준 `strict_security_digest()`
        가 선택되고, 캐시된 `PolicyVersion` 힌트가 있으므로(non-git
        `policy_dir`, s5) `load_policy_version()` 재호출은 생략된다 —
        `_security_digest_scope_profile()` 자체는 (git 상태를 매번 새로
        판정해야 하므로) 호출되지만, 내부에서 파일을 다시 읽지는
        않는다."""
        from rein.kernel import policy as policy_module
        from rein.platform.git import facts as git_facts_module

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._write_version_file(policy_dir, "version: 1\ndigest_scope: strict\n")
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }
            policies = [
                _loaded_policy(
                    ["security_review"],
                    trigger="tool.pre",
                    when={"command.type": "git.commit"},
                )
            ]
            policy_version_cache = []
            _build_facts(
                event,
                project_root,
                policies=policies,
                policy_dir=policy_dir,
                policy_version_out=policy_version_cache,
            )
            self.assertEqual(
                len(policy_version_cache),
                1,
                msg="_build_facts() 가 policy_dir 를 받으면 항상 정확히 "
                "1개(로드된 PolicyVersion)를 append 해야 한다",
            )
            resolvers = _build_fact_resolvers(
                event,
                project_root,
                policy_dir=policy_dir,
                policy_version_cache=policy_version_cache,
            )
            context = EvaluationContext(fact_resolvers=resolvers)

            with mock.patch.object(
                policy_module,
                "load_policy_version",
                wraps=policy_module.load_policy_version,
            ) as load_mock, mock.patch.object(
                git_facts_module,
                "strict_security_digest",
                wraps=git_facts_module.strict_security_digest,
            ) as strict_mock, mock.patch.object(
                rein_cli, "_git_changeset_facts"
            ) as worktree_mock:
                context.fact(FACT_CHANGESET_SENSITIVE_DIGEST)

            load_mock.assert_not_called()
            strict_mock.assert_called_once()
            worktree_mock.assert_not_called()

    def test_shared_cache_reads_version_file_exactly_once_per_cycle(self):
        """(b) `security_review` 가 declared 이고 `changeset.sensitive_
        digest` 가 실제로 조회되는 cycle 에서, `policy_version_cache` 를
        공유하면 `load_policy_version()` 은 cycle 당 정확히 1회만 불린다
        — 공유하지 않으면(기존 하위호환 경로, `policy_version_cache` 를
        넘기지 않음) 같은 조건에서 2회 불린다는 대조군도 함께 고정한다."""
        from rein.kernel import policy as policy_module

        def _run_cycle(project_root, policy_dir, share_cache):
            self._write_version_file(policy_dir, "version: 1\n")
            event = {
                "name": "tool.pre",
                "tool": "Bash",
                "payload": {"command": "git commit -m x"},
            }
            policies = [
                _loaded_policy(
                    ["security_review"],
                    trigger="tool.pre",
                    when={"command.type": "git.commit"},
                )
            ]
            policy_version_cache = [] if share_cache else None
            _build_facts(
                event,
                project_root,
                policies=policies,
                policy_dir=policy_dir,
                policy_version_out=policy_version_cache,
            )
            resolver_kwargs = {"policy_dir": policy_dir}
            if share_cache:
                resolver_kwargs["policy_version_cache"] = policy_version_cache
            resolvers = _build_fact_resolvers(event, project_root, **resolver_kwargs)
            EvaluationContext(fact_resolvers=resolvers).fact(
                FACT_CHANGESET_SENSITIVE_DIGEST
            )

        def _count_load_policy_version_calls(run):
            original = policy_module.load_policy_version
            calls = []

            def counting(*args, **kwargs):
                calls.append((args, kwargs))
                return original(*args, **kwargs)

            with mock.patch.object(policy_module, "load_policy_version", counting):
                run()
            return calls

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            shared_calls = _count_load_policy_version_calls(
                lambda: _run_cycle(project_root, policy_dir, share_cache=True)
            )
        self.assertEqual(
            len(shared_calls),
            1,
            msg="policy_version_cache 를 공유하면 `_version.yaml` 은 cycle 당 "
            "정확히 1회만 읽혀야 한다 (_build_facts() 의 1회로 충분)",
        )

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            unshared_calls = _count_load_policy_version_calls(
                lambda: _run_cycle(project_root, policy_dir, share_cache=False)
            )
        self.assertEqual(
            len(unshared_calls),
            2,
            msg="캐시를 공유하지 않는 기존 하위호환 경로는 이전과 동일하게 "
            "여전히 2회(각자 독립적으로) 읽어야 한다 — 이 대조군이 "
            "깨지면 공유 경로의 '1회' 단언이 우연이 아님을 보증할 수 "
            "없다",
        )


class PolicyVersionStagedDeletionReachesLifecycleResolutionTest(unittest.TestCase):
    """리뷰 지적 수리(2026-08-20) — 재현 + 회귀 방지.

    `_evaluate_event()`(`_build_facts()` 경유)는 수명주기 판정보다 먼저
    worktree 기반 `_load_policy_version_fact()` 를 호출했고, 그 함수는
    `os.path.exists(version_path)` 가 거짓이면(파일이 worktree 에 물리적
    으로 없으면) 그 부재가 "진짜 미설정"인지 "아직 커밋되지 않은 staged
    삭제"(spec §3.6 s2 — HEAD 기준 평가가 여전히 유효)인지 구분하지 않고
    곧바로 `PolicyVersionError` 를 던졌다(`security_review` 같은 증거
    발급형 requirement 가 declared 인 정책 세트에서, Medium D 랜드마인
    가드). 그 결과 `_evaluate_event()` 전체가 예외로 죽어, digest_scope
    축(`rein.platform.git.facts.resolve_policy_version_digest_scope`)이
    이미 올바르게 구현해 둔 s2("HEAD 기준 평가")/m2("strict 강제 복구
    평가") 판정에 실제 CLI 경로에서는 결코 도달하지 못했다(단위 테스트
    `tests/unit/test_security_digest_scope.py::DigestScopeGitLifecycleTest`
    /`DigestScopeMalformedCrossStateTest` 는 그 함수를 직접 호출해서만
    통과했다 — `_evaluate_event()` 를 관통한 적이 없었다).

    아래 3케이스(리뷰어 재현)는 `_version.yaml` 을 커밋 후 삭제해 staged
    상태로 남긴 policy_dir 에 대해 `_evaluate_event()` 를 직접 관통시켜,
    설계 계약이 실 CLI 경로에서 성립함을 고정한다:

    1. valid strict HEAD + staged 삭제 → HEAD 프로필 평가(strict)
    2. valid sensitive HEAD + staged 삭제 → HEAD 프로필 평가(sensitive)
    3. malformed HEAD + staged 삭제 → m2 strict 복구 평가

    수리 전에는 세 케이스 모두 `_evaluate_event()` 호출 시점에
    `PolicyVersionError` 가 그대로 전파돼 테스트가 실패했다(RED).
    """

    def _git(self, args, cwd, check=True):
        return subprocess.run(
            ("git",) + tuple(args), cwd=cwd, check=check, capture_output=True
        )

    def _init_repo(self, base_dir):
        self._git(("init", "-q"), base_dir)
        self._git(("config", "user.email", "t@example.com"), base_dir)
        self._git(("config", "user.name", "t"), base_dir)

    def _write(self, base_dir, rel_path, content):
        full_path = os.path.join(base_dir, rel_path)
        os.makedirs(os.path.dirname(full_path) or base_dir, exist_ok=True)
        with open(full_path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def _commit_all(self, base_dir, message="seed"):
        self._git(("add", "-A"), base_dir)
        self._git(("commit", "-q", "-m", message), base_dir)

    def _stage_all(self, base_dir):
        self._git(("add", "-A"), base_dir)

    def _make_policy_dir_with_staged_deletion(self, base_dir, version_text):
        """독립 policy_dir 저장소: `security_review` 요구 policy 1개를
        `_version.yaml`(version_text)과 함께 커밋한 뒤, `_version.yaml`
        만 삭제해 staged 상태로 남긴다(s2/m2 재현 공통 준비 — 삭제는
        커밋되지 않는다, "staged" 가 핵심)."""
        self._init_repo(base_dir)
        self._write(
            base_dir,
            "commit.yaml",
            "trigger: tool.pre\n"
            "when:\n"
            "  command.type: git.commit\n"
            "require:\n"
            "  - security_review\n"
            "failure_mode: closed\n",
        )
        self._write(base_dir, "_version.yaml", version_text)
        self._commit_all(base_dir, "seed")
        os.remove(os.path.join(base_dir, "_version.yaml"))
        self._stage_all(base_dir)

    def _commit_event(self):
        return {
            "name": "tool.pre",
            "tool": "Bash",
            "payload": {"command": "git commit -m x"},
        }

    def test_valid_strict_head_staged_deletion_uses_head_profile(self):
        """케이스 1 — valid strict HEAD + staged 삭제 → strict 로 평가."""
        from rein.platform.git import facts as git_facts_module

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._make_policy_dir_with_staged_deletion(
                policy_dir, "version: 1\ndigest_scope: strict\n"
            )
            with mock.patch.object(
                git_facts_module,
                "strict_security_digest",
                wraps=git_facts_module.strict_security_digest,
            ) as strict_mock, mock.patch.object(
                rein_cli, "_git_changeset_facts"
            ) as worktree_mock:
                decision = rein_cli._evaluate_event(
                    self._commit_event(), policy_dir, project_root, ":memory:"
                )

        self.assertIn("facts", decision)
        strict_mock.assert_called_once()
        worktree_mock.assert_not_called()

    def test_valid_sensitive_head_staged_deletion_uses_head_profile(self):
        """케이스 2 — valid sensitive HEAD + staged 삭제 → sensitive 로 평가."""
        from rein.platform.git import facts as git_facts_module

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._make_policy_dir_with_staged_deletion(
                policy_dir, "version: 1\ndigest_scope: sensitive\n"
            )
            with mock.patch.object(
                git_facts_module,
                "strict_security_digest",
                wraps=git_facts_module.strict_security_digest,
            ) as strict_mock, mock.patch.object(
                rein_cli,
                "_git_changeset_facts",
                wraps=rein_cli._git_changeset_facts,
            ) as worktree_mock:
                decision = rein_cli._evaluate_event(
                    self._commit_event(), policy_dir, project_root, ":memory:"
                )

        self.assertIn("facts", decision)
        strict_mock.assert_not_called()
        worktree_mock.assert_called_once()

    def test_malformed_head_staged_deletion_forces_strict_recovery(self):
        """케이스 3 — malformed HEAD + staged 삭제 → m2 strict 강제 복구 평가."""
        from rein.platform.git import facts as git_facts_module

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._make_policy_dir_with_staged_deletion(
                policy_dir, "version: 1\ndigest_scope: bogus\n"
            )
            with mock.patch.object(
                git_facts_module,
                "strict_security_digest",
                wraps=git_facts_module.strict_security_digest,
            ) as strict_mock, mock.patch.object(
                rein_cli, "_git_changeset_facts"
            ) as worktree_mock:
                decision = rein_cli._evaluate_event(
                    self._commit_event(), policy_dir, project_root, ":memory:"
                )

        self.assertIn("facts", decision)
        strict_mock.assert_called_once()
        worktree_mock.assert_not_called()

    def test_committed_deletion_is_genuine_absence_and_still_gates(self):
        """대조군 — staged 삭제가 실제로 커밋되면(설계: "커밋으로 부재
        발효") 그 시점부터는 진짜 미설정이다. `security_review` 가
        declared 이므로 Medium D 랜드마인 가드가 여전히 발동해야 한다
        (이 수리가 진짜 부재 케이스의 fail-closed 를 조용히 없애지
        않았음을 확인)."""
        from rein.kernel.policy import PolicyVersionError

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._make_policy_dir_with_staged_deletion(
                policy_dir, "version: 1\ndigest_scope: strict\n"
            )
            self._commit_all(policy_dir, "commit the deletion")

            with self.assertRaises(PolicyVersionError):
                rein_cli._evaluate_event(
                    self._commit_event(), policy_dir, project_root, ":memory:"
                )

    def test_unstaged_deletion_of_tracked_file_is_ambiguous_fail_closed(self):
        """대조군 — 삭제가 staged 되지 않으면(index 는 여전히 이전 내용을
        가리킴) s3 와 동일한 모호성이라 fail-closed 여야 한다(landmine
        가드로 조용히 흡수되면 안 된다 — index 에는 여전히 유효한 tracked
        선언이 있는데도 버전 검증 없이 통과하는 길이 열리기 때문)."""
        from rein.platform.git.facts import PolicyVersionGitStateError

        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._init_repo(policy_dir)
            self._write(
                policy_dir,
                "commit.yaml",
                "trigger: tool.pre\n"
                "when:\n"
                "  command.type: git.commit\n"
                "require:\n"
                "  - security_review\n"
                "failure_mode: closed\n",
            )
            self._write(policy_dir, "_version.yaml", "version: 1\n")
            self._commit_all(policy_dir, "seed")
            os.remove(os.path.join(policy_dir, "_version.yaml"))
            # staged 하지 않음 — worktree 삭제만.

            with self.assertRaises(PolicyVersionGitStateError):
                rein_cli._evaluate_event(
                    self._commit_event(), policy_dir, project_root, ":memory:"
                )


class PolicyVersionGitQueryFailureReachesEvaluateEventTest(unittest.TestCase):
    """CLI 관통 경로 — 후속 git 조회(HEAD/index) 실패 주입이
    `_evaluate_event()` 를 통해서도 실패 방향(차단)으로 떨어지는지 고정
    한다(리뷰 지적, 2026-08-20). 단위 테스트(`tests/unit/
    test_security_digest_scope.py::DigestScopeGitLifecycleQueryFailureTest`)
    는 `resolve_policy_version_digest_scope()` 를 직접 호출해서만 이
    계약을 확인했다 — 이 클래스는 위
    `PolicyVersionStagedDeletionReachesLifecycleResolutionTest` 가 이미
    고정한 "`_evaluate_event()` 관통" 계약을, 부재가 아니라 clean
    committed 상태에서의 git 조회 실패 시나리오에 적용한다.

    `resolve_policy_version_digest_scope()` 는 `_load_policy_version_
    fact()`(worktree 직접 존재 확인) 경로가 아니라 `_security_digest_
    scope_profile()` → `_resolve_sensitive_digest()` lazy resolver 경로로
    도달한다 — `security_review` 가 declared 이고 실제로 `changeset.
    sensitive_digest` fact 가 evaluate() 도중 조회될 때만 호출된다
    (`PolicyVersionCacheSharingTest` 가 이미 고정한 배선과 동일).
    """

    def _git(self, args, cwd, check=True):
        return subprocess.run(
            ("git",) + tuple(args), cwd=cwd, check=check, capture_output=True
        )

    def _init_repo(self, base_dir):
        self._git(("init", "-q"), base_dir)
        self._git(("config", "user.email", "t@example.com"), base_dir)
        self._git(("config", "user.name", "t"), base_dir)

    def _write(self, base_dir, rel_path, content):
        full_path = os.path.join(base_dir, rel_path)
        os.makedirs(os.path.dirname(full_path) or base_dir, exist_ok=True)
        with open(full_path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def _commit_all(self, base_dir, message="seed"):
        self._git(("add", "-A"), base_dir)
        self._git(("commit", "-q", "-m", message), base_dir)

    def _commit_event(self):
        return {
            "name": "tool.pre",
            "tool": "Bash",
            "payload": {"command": "git commit -m x"},
        }

    def test_head_query_failure_on_clean_committed_strict_blocks_through_evaluate_event(
        self,
    ):
        """리뷰어 재현 — clean committed strict `policy_dir` 에서 HEAD
        조회만 실패하게 주입하면 `_evaluate_event()` 의 평가가 실패
        방향(차단)으로 떨어져야 한다. `resolve_policy_version_digest_
        scope()` 는 `changeset.sensitive_digest` 의 **lazy fact
        resolver**(`_resolve_sensitive_digest`) 안에서 호출되므로, 거기서
        일어나는 `PolicyVersionGitStateError` 는 `_evaluate_event()` 밖으로
        직접 전파되지 않는다 — `rein.engine.context.EvaluationContext.
        fact()` 가 이를 잡아 'fact resolution failed' 로 재포장하고,
        `rein.engine.evaluator` 가 requirement 평가 실패로 흡수해
        `failure_mode: closed` 규칙에 따라 BLOCK 결정으로 떨어뜨린다
        (staged-삭제 경로의 `resolve_policy_version_for_absent_worktree()`
        가 `_build_facts()` 에서 **직접**(lazy 아님) 호출돼 예외가 그대로
        전파되는 것과는 다른 경로 — 위
        `PolicyVersionStagedDeletionReachesLifecycleResolutionTest` 참조).

        수리 전에는 HEAD 조회 실패가 s2(최초 staged-add) 오판 분기로 새
        `DIGEST_SCOPE_SENSITIVE` 로 조용히 강등되고 평가가 정상 진행돼
        결정이 이 실패와 무관하게 나왔다(fail-closed 계약 위반, 즉
        "실패 방향으로 안 떨어짐")."""
        with tempfile.TemporaryDirectory() as project_root, tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            self._init_repo(policy_dir)
            self._write(
                policy_dir,
                "commit.yaml",
                "trigger: tool.pre\n"
                "when:\n"
                "  command.type: git.commit\n"
                "require:\n"
                "  - security_review\n"
                "failure_mode: closed\n",
            )
            self._write(
                policy_dir,
                "_version.yaml",
                "version: 1\ndigest_scope: strict\n",
            )
            self._commit_all(policy_dir, "seed strict version")  # clean, s1

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if (
                    len(args) >= 2
                    and args[0] == "git"
                    and args[1] == "show"
                    and kwargs.get("cwd") == policy_dir
                    and any(
                        isinstance(a, str) and a.startswith("HEAD:")
                        for a in args
                    )
                ):
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(subprocess, "run", side_effect=_flaky_run):
                decision = rein_cli._evaluate_event(
                    self._commit_event(),
                    policy_dir,
                    project_root,
                    ":memory:",
                )

        self.assertEqual(
            decision["decision"],
            "BLOCK",
            msg="HEAD 조회 실행 실패가 조용히 흡수돼 평가가 정상 진행되면 "
            "안 된다 — failure_mode closed 는 이 상태 판정 실패를 반드시 "
            "차단 방향으로 떨어뜨려야 한다: reason={!r}".format(
                decision.get("reason")
            ),
        )
        self.assertIn(
            "unable to confirm HEAD content",
            decision.get("reason") or "",
            msg="차단 사유가 실제로 이 HEAD 조회 실패에서 비롯됐는지 "
            "확인 — 다른 이유로 우연히 BLOCK 이 나온 게 아니어야 한다",
        )


if __name__ == "__main__":
    unittest.main()
