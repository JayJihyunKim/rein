"""Phase 7 웨이브 3 ③-a — `rein.cli.issue_evidence` 발급↔평가 결합 계약.

covers: v2-evidence-issuance-zero-production-callers

`rein.cli.issue_evidence` 가 생기기 전에는 `issue_code_review_evidence()`/
`issue_security_review_evidence()`(Phase 3/4)를 실제로 호출해
`LedgerVerifiedEvidenceSource.record_issued()` 까지 이어 붙이는 shell
진입점이 없었다 — 평가(`run_hook_event()`)는 이미 실 ledger 를 조회하도록
배선됐지만(Phase 6 최종 조립), 그 ledger 를 채우는 프로덕션 호출자가
없어 v2 evidence 가 한 번도 실제로 발급된 적이 없었다("zero production
callers" 갭).

이 파일이 고정하는 계약 — **digest binding 이 v1 `.review-pending`
freshness 마커를 대체한다**: `issue()` 로 발급한 evidence 는 (a) legacy
마커 파일을 전혀 만들지 않아도 그 자체로 평가를 충족시키고, (b) 발급
이후 추적 파일이 수정되면(=digest 가 바뀌면) 같은 evidence 로는 더 이상
충족되지 않는다 — 시각(mtime) 이 아니라 내용(digest) 기준 freshness.

- code_review: `CodeReviewIssuanceEvaluationBindingTest` — 번들 기본
  `commit.yaml` 정책(spec §11.1 "commit → code_review 만 요구")을 그대로
  쓴다(`tests/cli/test_run_event_fact_wiring.py`
  `EvidenceSourceWiringSafetyTest` 와 동일 픽스처 패턴 재사용).
- security_review: `SecurityReviewIssuanceEvaluationBindingTest` — 번들
  기본 세트는 security_review 를 `release.yaml`(tests_passed/code_review
  와 결합)에서만 요구해 단일 축 검증에 부적합하므로, security_review
  하나만 요구하는 전용 fixture policy 를 쓴다(`tests/bypass/
  test_forged_evidence.py::_require_policy` 와 동일 관례 — 파일
  기반이어야 하는 이유는 `issue_evidence.py` 가 `policy_dir` 에서
  `_version.yaml` 을 실제로 읽기 때문에, in-memory 정책 dict 만으로는
  policy_version 축을 검증할 수 없다).
"""
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

from rein.cli import ENV_POLICY_DIR, ENV_PROJECT_ROOT, run_hook_event  # noqa: E402
from rein.cli.issue_evidence import (  # noqa: E402
    REASON_SUBJECT_EMPTY,
    REASON_SUBJECT_UNRESOLVED,
    RefusalError,
    UsageError,
    issue,
    print_digest,
)
# 닫힌 값 계약 2상태의 실제 리터럴 — `print_digest()` 가 이 센티널을
# 그대로 반환하는지(계약서 원문 — "print it as-is") 먼저 확인한 뒤
# `issue()` 에 그대로 흘려 넣어 `RefusalError.reason` 이 대응 어휘로
# 갈리는지 검증하는 데 쓴다. 이름을 `_VALUE` 접미어로 구분해 위
# `REASON_SUBJECT_EMPTY`(발급 거부 사유 어휘, `issue_evidence.py` 상수)
# 와 혼동하지 않게 한다 — 둘은 우연히 같은 개념 축을 가리키지만 서로
# 다른 계약(subject 값 vs 거부 사유 이름)의 상수다.
from rein.kernel.changeset import (  # noqa: E402
    SUBJECT_EMPTY as REASON_SUBJECT_EMPTY_VALUE,
)

_DEFAULT_POLICY_DIR = os.path.join(_PLUGIN_ROOT, "policies", "default")


def _init_git_repo(base_dir):
    """빈 git 저장소 + 초기 커밋 1개, `.rein/` gitignore 포함.

    `.rein/` 를 gitignore 해 두지 않으면 evidence 발급(`.rein/state/
    {ledger,evidence}.jsonl` 쓰기)의 부수효과가 발급 전/후 WORKTREE
    changeset digest 를 서로 다르게 만든다 — `tests/cli/
    test_run_event_fact_wiring.py::_init_git_repo` 와 동일 이유·동일
    패턴(중복 구현이지만 두 테스트 파일 사이에 공유 헬퍼 모듈이 없어
    관례상 각자 반복한다).
    """
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"],
        cwd=base_dir,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "t"], cwd=base_dir, check=True
    )
    with open(
        os.path.join(base_dir, ".gitignore"), "w", encoding="utf-8"
    ) as handle:
        handle.write(".rein/\n")
    subprocess.run(["git", "add", ".gitignore"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "gitignore"], cwd=base_dir, check=True
    )
    with open(os.path.join(base_dir, "a.py"), "w", encoding="utf-8") as handle:
        handle.write("print('hi')\n")
    subprocess.run(["git", "add", "a.py"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True
    )


def _write_code_change(project_root, content="print('changed')\n"):
    """`a.py`(`_init_git_repo` 가 커밋해 둔 파일)에 미커밋 편집을 남긴다.

    **2026-08-20 개정(spec §3.6 "리뷰 digest 범위" 절) 대응** —
    `_init_git_repo` 직후 worktree 는 HEAD 와 clean 하다. `_write_active_
    dod()` 만 추가하면 WORKTREE changeset 에는 `trail/dod/dod-*.md`
    하나만 남는데, 그 경로는 리뷰 digest 의 검토 면제 허용목록(`trail/
    **`)에 속해 `changeset.review_digest` 가 `SUBJECT_EMPTY` 로 계산된다
    — code_review evidence 발급 자체가 거부된다(closed-value 계약). 이
    헬퍼로 허용목록 밖 실질 코드 변경을 남겨 리뷰 digest 가 항상
    non-empty 실제 digest 이게 한다(`tests/cli/test_run_event_fact_
    wiring.py::_write_code_change` 와 동일 관례).
    """
    with open(
        os.path.join(project_root, "a.py"), "w", encoding="utf-8"
    ) as handle:
        handle.write(content)


def _write_active_dod(project_root, slug="fixture-task", date="2026-08-19"):
    """Phase 7 결정 1 — `commit.yaml` 의 `when: task.exists: "true"` 를 채운다.

    `tests/cli/test_run_hook_event_self_reliance.py::_write_active_dod`
    와 동일 관례.
    """
    dod_dir = os.path.join(project_root, "trail", "dod")
    os.makedirs(dod_dir, exist_ok=True)
    with open(
        os.path.join(dod_dir, "dod-{}-{}.md".format(date, slug)),
        "w",
        encoding="utf-8",
    ) as handle:
        handle.write("# DoD\n\n- date: {}\n".format(date))


def _bash_payload(command, cwd):
    return {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": cwd,
    }


def _security_only_policy_dir(base_dir):
    """security_review 단독 요구 정책 — 번들 `release.yaml` 의 3축 결합을 피한다."""
    policy_dir = os.path.join(base_dir, "policies")
    os.makedirs(policy_dir, exist_ok=True)
    with open(
        os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write('version: "1"\n')
    with open(
        os.path.join(policy_dir, "security.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "trigger: tool.pre\n"
            "when:\n"
            "  tool: Bash\n"
            "require:\n"
            "  - security_review\n"
            "failure_mode: closed\n"
        )
    return policy_dir


class CodeReviewIssuanceEvaluationBindingTest(unittest.TestCase):
    """(a) code_review — digest binding 이 legacy freshness 마커를 대체한다."""

    def test_issued_evidence_alone_satisfies_evaluation_without_legacy_marker(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_active_dod(project_root)
            # 허용목록 밖 실질 코드 변경 — review digest 가 SUBJECT_EMPTY
            # 가 아니라 실제 subject 를 내게 한다(위 헬퍼 docstring 참조).
            _write_code_change(project_root)
            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                before = run_hook_event(
                    _bash_payload("git commit -m x", project_root)
                )
                self.assertEqual(
                    before["decision"],
                    "BLOCK",
                    msg="precondition — no evidence issued yet, must be "
                    "unmet",
                )

                digest = print_digest("code_review")
                evidence = issue("code_review", "PASS", digest)
                self.assertEqual(evidence.subject, digest)

                after = run_hook_event(
                    _bash_payload("git commit -m x", project_root)
                )
        self.assertEqual(
            after["decision"],
            "ALLOW",
            msg="CLI-issued evidence alone (no .codex-reviewed/.review-"
            "pending legacy marker anywhere in the fixture) must satisfy "
            "code_review — this is the zero-production-callers gap being "
            "closed",
        )

    def test_edit_after_issuance_makes_evaluation_unmet_again(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_active_dod(project_root)
            # 허용목록 밖 실질 코드 변경 — review digest 가 SUBJECT_EMPTY
            # 가 아니라 실제 subject 를 내게 한다(위 헬퍼 docstring 참조).
            _write_code_change(project_root)
            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                digest = print_digest("code_review")
                issue("code_review", "PASS", digest)
                allowed = run_hook_event(
                    _bash_payload("git commit -m x", project_root)
                )
                self.assertEqual(allowed["decision"], "ALLOW")

                # 발급 후 추적 파일을 편집 — digest 가 바뀐다
                with open(
                    os.path.join(project_root, "a.py"),
                    "a",
                    encoding="utf-8",
                ) as handle:
                    handle.write("print('more')\n")

                after_edit = run_hook_event(
                    _bash_payload("git commit -m x", project_root)
                )
        self.assertEqual(
            after_edit["decision"],
            "BLOCK",
            msg="editing a tracked file after issuance must invalidate "
            "the bound evidence — digest binding (content-based) replaces "
            "the v1 .review-pending freshness marker (mtime-based)",
        )


class SecurityReviewIssuanceEvaluationBindingTest(unittest.TestCase):
    """(b) security_review — success + post-edit invalidation + 두 센티널 거부."""

    def test_issued_evidence_satisfies_and_post_edit_invalidates(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            with open(
                os.path.join(project_root, ".env"), "w", encoding="utf-8"
            ) as handle:
                handle.write("API_KEY=old\n")
            policy_dir = _security_only_policy_dir(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                before = run_hook_event(_bash_payload("echo hi", project_root))
                self.assertEqual(before["decision"], "BLOCK")

                digest = print_digest("security_review")
                self.assertNotIn(
                    digest, (REASON_SUBJECT_EMPTY, REASON_SUBJECT_UNRESOLVED)
                )
                evidence = issue("security_review", "PASS", digest)
                self.assertEqual(evidence.subject, digest)

                allowed = run_hook_event(_bash_payload("echo hi", project_root))
                self.assertEqual(allowed["decision"], "ALLOW")

                # 발급 후 sensitive 파일을 추가 편집 — sensitive digest 가 바뀐다
                with open(
                    os.path.join(project_root, ".env"),
                    "a",
                    encoding="utf-8",
                ) as handle:
                    handle.write("SECOND_KEY=new\n")

                after_edit = run_hook_event(
                    _bash_payload("echo hi", project_root)
                )
        self.assertEqual(
            after_edit["decision"],
            "BLOCK",
            msg="editing the sensitive file after issuance must "
            "invalidate the bound security_review evidence",
        )

    def test_subject_empty_refusal_when_no_sensitive_changes(self):
        """sensitive 변경이 아예 없으면(빈 subject) 발급 시도는 거부된다.

        평가측(`SecurityReviewRequirement.evaluate`)은 이 상태를 evidence
        없이도 이미 충족으로 판정한다(spec §3.6 닫힌 값 계약) — 발급측은
        그 대칭으로 "발급할 대상이 없다"는 사유를 명시 거부로 낸다.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _security_only_policy_dir(project_root)
            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                digest = print_digest("security_review")
                self.assertEqual(digest, REASON_SUBJECT_EMPTY_VALUE)
                with self.assertRaises(RefusalError) as ctx:
                    issue("security_review", "PASS", digest)
        self.assertEqual(ctx.exception.reason, REASON_SUBJECT_EMPTY)

    def test_explicit_non_git_project_root_is_usage_error(self):
        """명시 `REIN_PROJECT_ROOT` 가 non-git 이면 usage 결함(exit 1 대상)
        — subject-unresolved 발급 거부(exit 2 대상)가 아니다 (Medium
        finding, code review round 1). 수리 전에는 `_resolve_project_root()`
        가 명시 값을 git 검증 없이 그대로 반환해, 이 시나리오가
        `print_digest()` 를 통과해 `subject-unresolved` 로 잘못
        분류됐다 — "저장소 자체가 없음"은 판정을 시작조차 못 하는
        환경 결함이지, "판정은 진행했지만 subject 를 못 정한" 사건이
        아니다. 이제는 `print_digest()`/`issue()` 둘 다 project_root
        해소 단계에서 `UsageError` 로 즉시 실패한다 — subject digest
        산정 단계까지 가지 않는다."""
        with tempfile.TemporaryDirectory() as non_git_dir:
            policy_dir = _security_only_policy_dir(non_git_dir)
            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: non_git_dir,
            }
            with mock.patch.dict(os.environ, env):
                with self.assertRaises(UsageError):
                    print_digest("security_review")
                with self.assertRaises(UsageError):
                    issue("security_review", "PASS", "sha256:" + "0" * 64)


if __name__ == "__main__":
    unittest.main()
