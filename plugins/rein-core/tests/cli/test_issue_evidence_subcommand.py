"""Phase 7 웨이브 3 ③-a — `bin/rein issue-evidence` CLI 표면 계약.

covers: v2-evidence-issuance-zero-production-callers

`rein.cli.issue_evidence` 의 발급↔평가 결합 자체(digest 산정이
evaluate() 와 같은 코드 경로를 재사용하는가, digest binding 이 legacy
freshness 마커를 대체하는가)는 `tests/contract/
test_issue_evidence_binding.py` 가 in-process 로 고정한다. 이 파일은 그
계약을 실제 `bin/rein` 프로세스 경계 너머로 노출하는 얇은 CLI 표면만
검증한다 — subprocess, 무해 입력만(`tests/cli/
test_hook_subcommand_native_response.py` 관례와 동일):

(a) `--print-digest` 가 evaluate() 시점 fact(`_build_fact_resolvers()`
    가 lazy 로 계산하는 것과 동일한 값)와 정확히 같은 문자열을 낸다.
(b) 발급 거부 5종(digest-mismatch/subject-empty/subject-unresolved/
    verdict-not-pass/malformed) 전부 — exit 2 + 한 줄 JSON `{"issued":
    false, "reason": ...}`, evidence.jsonl/ledger.jsonl 은 발급 시도
    전후 byte-identical(부분 쓰기 없음 — 인터페이스 계약 "NO partial
    writes").
(c) 발급 성공 — exit 0 + 한 줄 JSON `{"issued": true, "requirement":
    ..., "subject": ...}`.
(d) usage/env 결함(미지 capability·인자 누락·비 git 디렉터리) 전부
    exit 1.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.cli import (  # noqa: E402
    _build_fact_resolvers,
    FACT_CHANGESET_REVIEW_DIGEST,
)
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.kernel.changeset import SUBJECT_UNRESOLVED  # noqa: E402

_BIN_REIN = os.path.join(_PLUGIN_ROOT, "bin", "rein")
_SUBPROCESS_TIMEOUT_SECONDS = 30
_ENV_VARS_TO_CLEAR = ("REIN_POLICY_DIR", "REIN_PROJECT_ROOT", "REIN_DB_PATH")


def _init_git_repo(base_dir):
    """빈 git 저장소 + 초기 커밋 1개, `.rein/` gitignore 포함.

    gitignore 가 없으면 evidence 발급의 부수효과(`.rein/state/*.jsonl`
    쓰기)가 발급 전/후 WORKTREE changeset digest 를 서로 다르게 만든다
    — `tests/cli/test_run_event_fact_wiring.py::_init_git_repo` 와 동일
    이유(중복 구현이지만 공유 헬퍼 모듈이 없어 관례상 각자 반복한다).
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
    `_init_git_repo` 직후 worktree 는 HEAD 와 clean 하다(WORKTREE
    changeset 이 빈 집합). 빈 집합은 공허하게 전부 허용목록에 속해
    `changeset.review_digest` 가 `SUBJECT_EMPTY` 로 계산된다(`rein.
    platform.git.facts.review_digest()` docstring) — code_review evidence
    발급 자체가 거부된다. 이 헬퍼로 허용목록 밖 실질 코드 변경을 남겨
    리뷰 digest 가 항상 non-empty 실제 digest 이게 한다(다른 ③-a 테스트
    파일들과 동일 관례).
    """
    with open(
        os.path.join(project_root, "a.py"), "w", encoding="utf-8"
    ) as handle:
        handle.write(content)


def _clean_env(extra=None):
    env = dict(os.environ)
    for key in _ENV_VARS_TO_CLEAR:
        env.pop(key, None)
    if extra:
        env.update(extra)
    return env


def _run_issue_evidence(args, cwd, extra_env=None):
    return subprocess.run(
        [sys.executable, _BIN_REIN, "issue-evidence"] + list(args),
        cwd=cwd,
        env=_clean_env(extra_env),
        capture_output=True,
        text=True,
        timeout=_SUBPROCESS_TIMEOUT_SECONDS,
    )


def _state_file_bytes(project_root):
    state_dir = os.path.join(project_root, ".rein", "state")
    result = {}
    for name in ("evidence.jsonl", "ledger.jsonl"):
        path = os.path.join(state_dir, name)
        try:
            with open(path, "rb") as handle:
                result[name] = handle.read()
        except FileNotFoundError:
            result[name] = None
    return result


class PrintDigestMatchesEvaluationFactTest(unittest.TestCase):
    """(a) `--print-digest` == evaluate() 시점 fact 값(같은 fixture)."""

    def test_code_review_print_digest_equals_evaluation_time_fact(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            # 허용목록 밖 실질 코드 변경 — 빈 changeset 이면 두 값 모두
            # SUBJECT_EMPTY 로 공허하게 일치해 이 비교가 무의미해진다
            # (`_write_code_change` docstring 참조).
            _write_code_change(project_root)
            proc = _run_issue_evidence(
                ["code_review", "--print-digest"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            cli_digest = proc.stdout.strip()

            resolvers = _build_fact_resolvers(
                {"tool": "Bash", "payload": {"command": "git status"}},
                project_root,
            )
            # 2026-08-20 개정 — code_review 의 subject 는 이제 `changeset.
            # digest`(WORKTREE 전체)가 아니라 `changeset.review_digest`
            # (검토 면제 허용목록 제외)다(spec §3.6 "리뷰 digest 범위" 절).
            evaluation_digest = EvaluationContext(
                fact_resolvers=resolvers
            ).fact(FACT_CHANGESET_REVIEW_DIGEST)
        self.assertEqual(
            cli_digest,
            evaluation_digest,
            msg="issue-evidence --print-digest must compute the exact "
            "same value the evaluator resolves for changeset.review_digest "
            "— same underlying function call, not a re-derivation",
        )


class PrintSubjectListsCertifiedPathsTest(unittest.TestCase):
    """`--print-subject` (both capabilities, 2026-08-20 code review round 3
    refinement — replaces the code_review-only `--print-subject-paths`) —
    for code_review, the JSON `paths` field lists exactly the WORKTREE
    staged/unstaged/untracked paths that survive the review-exemption
    allowlist filter, i.e. the same path set `review_digest()`/
    `--print-digest` hashes (single source: `rein.platform.git.facts.
    review_subject_paths()`), and `subject` is that same digest — both
    values come from ONE `--print-subject` invocation (atomic snapshot)."""

    def test_lists_staged_unstaged_untracked_and_excludes_allowlist(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            # A second tracked file so "staged" and "unstaged" can each be
            # exercised on a distinct file (a.py stays the staged one).
            with open(
                os.path.join(project_root, "b.py"), "w", encoding="utf-8"
            ) as handle:
                handle.write("print('b')\n")
            subprocess.run(
                ["git", "add", "b.py"], cwd=project_root, check=True
            )
            subprocess.run(
                ["git", "commit", "-q", "-m", "add b.py"],
                cwd=project_root,
                check=True,
            )

            # staged change (a.py)
            _write_code_change(project_root, "print('staged')\n")
            subprocess.run(
                ["git", "add", "a.py"], cwd=project_root, check=True
            )
            # unstaged change (b.py, tracked but not staged)
            with open(
                os.path.join(project_root, "b.py"), "w", encoding="utf-8"
            ) as handle:
                handle.write("print('unstaged')\n")
            # untracked code file (never git-added)
            with open(
                os.path.join(project_root, "c.py"), "w", encoding="utf-8"
            ) as handle:
                handle.write("print('untracked')\n")
            # allowlisted untracked files — must NOT appear in the output.
            with open(
                os.path.join(project_root, "notes.md"), "w", encoding="utf-8"
            ) as handle:
                handle.write("note\n")
            os.makedirs(os.path.join(project_root, "docs"), exist_ok=True)
            with open(
                os.path.join(project_root, "docs", "guide.txt"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("guide\n")
            os.makedirs(os.path.join(project_root, "trail"), exist_ok=True)
            with open(
                os.path.join(project_root, "trail", "note.txt"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("trail note\n")

            proc = _run_issue_evidence(
                ["code_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            response = json.loads(proc.stdout)
            self.assertTrue(response["subject"].startswith("sha256:"))
            paths = set(response["paths"])
            self.assertEqual(
                paths,
                {"a.py", "b.py", "c.py"},
                msg="expected staged (a.py) + unstaged (b.py) + untracked "
                "(c.py), excluding notes.md/docs/**/trail/** — got "
                "{!r}".format(paths),
            )


class PrintSubjectNewlineContainingPathTest(unittest.TestCase):
    """[Phase 7 wave 3 ③-a code review round 4, High-1 regression] a
    newline-containing untracked filename must round-trip through
    `--print-subject`'s JSON `paths` array as exactly ONE element.

    git allows newline-containing filenames (created here via python
    `open()` — the shell itself cannot easily construct one). This test
    pins the CLI-side half of the round-4 fix: the wire format between
    `bin/rein issue-evidence` and its caller is JSON (`json.dump`), which
    is boundary-safe regardless of embedded newlines — the corruption this
    finding is about happened one layer up, where consumers (the codex-
    review wrapper, and the security-reviewer/code-reviewer instruction
    snippets) used to flatten this same `paths` array into newline-joined
    text and split it back apart with `head`/`tail`, silently turning one
    newline-containing path into two. This test guards the CLI's half of
    that contract (the JSON payload itself must never split the path) so
    a regression here cannot slip back in unnoticed; the wrapper's own
    NUL-safe consumption of this JSON is separately covered by
    `tests/scripts/test-codex-review-evidence-issuance.sh`.
    """

    def test_newline_containing_untracked_path_is_one_element(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            newline_name = "dir_line\nbreak.py"
            with open(
                os.path.join(project_root, newline_name),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("print('newline path')\n")

            proc = _run_issue_evidence(
                ["code_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            response = json.loads(proc.stdout)
            paths = response["paths"]
            self.assertEqual(
                len(paths),
                2,
                msg="expected exactly 2 path entries (a.py + the "
                "newline-containing file) — a split would silently "
                "inflate this count; got {!r}".format(paths),
            )
            self.assertEqual(
                set(paths),
                {"a.py", newline_name},
                msg="the newline-containing filename must appear intact, "
                "as a single path string, in the JSON paths array — got "
                "{!r}".format(paths),
            )


class PrintSubjectEmptySetTest(unittest.TestCase):
    """Empty certified set (clean tree, or only allowlisted changes) →
    `{"subject": "empty:no-subject", "paths": []}` + exit 0 — not a usage
    error, not exit 2."""

    def test_clean_tree_yields_empty_subject_and_paths(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                ["code_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response, {"subject": "empty:no-subject", "paths": []})

    def test_allowlisted_only_untracked_change_yields_empty_subject_and_paths(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            with open(
                os.path.join(project_root, "notes.md"), "w", encoding="utf-8"
            ) as handle:
                handle.write("note\n")
            proc = _run_issue_evidence(
                ["code_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response, {"subject": "empty:no-subject", "paths": []})


class PrintSubjectSecurityReviewSupportedTest(unittest.TestCase):
    """security_review now DOES support `--print-subject` (2026-08-20 code
    review round 3 — surface expansion so `agents/security-reviewer.md`
    can consume the exact certified path set; the old code_review-only
    `--print-subject-paths` restriction is gone)."""

    def test_security_review_print_subject_succeeds(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                ["security_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertIn("subject", response)
        self.assertIn("paths", response)
        # Clean tree, default (sensitive) profile — nothing sensitive
        # changed, so this is the empty sentinel with no paths.
        self.assertEqual(response, {"subject": "empty:no-subject", "paths": []})

    def test_security_review_strict_profile_sensitive_allowlisted_path_is_certified(
        self,
    ):
        """(5b) Regression — a sensitive∩allowlist path (e.g. `trail/
        .npmrc`) staged under a strict-profile fixture must appear in the
        `--print-subject` certified paths AND the subject digest must be
        non-empty (strict ⊇ sensitive conservative invariant, spec §3.6/
        §14 — the allowlist must not silently exempt a sensitive file just
        because its path looks like a doc/trail path)."""
        with tempfile.TemporaryDirectory() as project_root, \
                tempfile.TemporaryDirectory() as policy_dir:
            _init_git_repo(project_root)
            # policy_dir deliberately lives OUTSIDE the project_root git
            # repo (a plain non-git tempdir) — `resolve_policy_version_
            # digest_scope()` then takes the s5 "non-git context" path and
            # reads the worktree `_version.yaml` directly, no commit
            # needed. `REIN_POLICY_DIR` has no requirement that the policy
            # directory live inside the reviewed repo (`_resolve_policy_
            # dir()` just returns the explicit env value verbatim).
            with open(
                os.path.join(policy_dir, "_version.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("version: 1\ndigest_scope: strict\n")

            os.makedirs(
                os.path.join(project_root, "trail"), exist_ok=True
            )
            with open(
                os.path.join(project_root, "trail", ".npmrc"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("//registry.example/:_authToken=deadbeef\n")
            subprocess.run(
                ["git", "add", "trail/.npmrc"],
                cwd=project_root,
                check=True,
            )

            proc = _run_issue_evidence(
                ["security_review", "--print-subject"],
                cwd=project_root,
                extra_env={
                    "REIN_PROJECT_ROOT": project_root,
                    "REIN_POLICY_DIR": policy_dir,
                },
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertTrue(
            response["subject"].startswith("sha256:"),
            msg="expected a non-sentinel digest — got {!r}".format(
                response["subject"]
            ),
        )
        self.assertIn(
            "trail/.npmrc",
            response["paths"],
            msg="sensitive file trail/.npmrc must remain a certified "
            "review target even though its path is docs/trail-shaped — "
            "got paths={!r}".format(response["paths"]),
        )


class PrintSubjectMutualExclusivityTest(unittest.TestCase):
    """`--print-subject` cannot be combined with `--print-digest` or
    the issuance args (`--verdict`/`--reviewed-digest`) — exit 1."""

    def test_print_digest_and_print_subject_are_mutually_exclusive(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                ["code_review", "--print-digest", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")

    def test_print_subject_cannot_combine_with_verdict_args(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                [
                    "code_review",
                    "--print-subject",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    "sha256:" + "0" * 64,
                ],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")


class PrintSubjectMatchesPrintDigestSubjectTest(unittest.TestCase):
    """The `--print-subject` JSON `paths` field, fed back through the same
    content-digest machinery, reconstructs exactly the `subject` field (and
    the separate `--print-digest` value) — direct proof the two CLI modes
    share one path-set function (`rein.platform.git.facts.
    review_subject_paths()`) rather than two independently-derived
    boundaries that could diverge."""

    def test_subject_paths_reconstruct_the_same_digest(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            with open(
                os.path.join(project_root, "notes.md"), "w", encoding="utf-8"
            ) as handle:
                handle.write("note\n")

            subject_proc = _run_issue_evidence(
                ["code_review", "--print-subject"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(
                subject_proc.returncode, 0, msg=subject_proc.stderr
            )
            response = json.loads(subject_proc.stdout)
            paths = response["paths"]
            self.assertIn("a.py", paths)
            self.assertNotIn("notes.md", paths)

            digest_proc = _run_issue_evidence(
                ["code_review", "--print-digest"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(
                digest_proc.returncode, 0, msg=digest_proc.stderr
            )
            digest = digest_proc.stdout.strip()
            self.assertEqual(
                response["subject"],
                digest,
                msg="--print-subject's JSON subject field does not match "
                "the separate --print-digest value",
            )

            from rein.kernel.changeset import (
                SCOPE_WORKTREE,
                ChangeSet,
            )
            from rein.platform.git.facts import changeset_digest

            reconstructed = changeset_digest(
                ChangeSet(scope=SCOPE_WORKTREE, paths=tuple(paths)),
                cwd=project_root,
            )
            self.assertEqual(
                reconstructed,
                digest,
                msg="--print-subject's paths field does not reconstruct "
                "the same digest --print-digest returned — the two CLI "
                "modes have diverged from a single source",
            )


class IssuanceSuccessTest(unittest.TestCase):
    """(c) 발급 성공 — exit 0 + `{"issued": true, ...}`."""

    def test_code_review_success_json_shape(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            digest_proc = _run_issue_evidence(
                ["code_review", "--print-digest"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
            self.assertEqual(digest_proc.returncode, 0, msg=digest_proc.stderr)
            digest = digest_proc.stdout.strip()

            proc = _run_issue_evidence(
                [
                    "code_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    digest,
                ],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(
            response, {"issued": True, "requirement": "code_review", "subject": digest}
        )


class RefusalNoPartialWriteTest(unittest.TestCase):
    """(b) 발급 거부 5종 — exit 2 + JSON reason + 파일 byte-identical."""

    def test_code_review_refusal_classes_leave_ledger_untouched(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            env = {"REIN_PROJECT_ROOT": project_root}

            digest_proc = _run_issue_evidence(
                ["code_review", "--print-digest"], cwd=project_root, extra_env=env
            )
            self.assertEqual(digest_proc.returncode, 0, msg=digest_proc.stderr)
            digest = digest_proc.stdout.strip()

            # 최초 발급 — 이 이후의 모든 거부 시도가 이 상태를 바꾸지
            # 않아야 한다(스냅샷 기준선).
            success = _run_issue_evidence(
                [
                    "code_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(success.returncode, 0, msg=success.stderr)
            baseline = _state_file_bytes(project_root)
            self.assertIsNotNone(baseline["evidence.jsonl"])
            self.assertIsNotNone(baseline["ledger.jsonl"])

            cases = [
                (
                    "digest-mismatch",
                    [
                        "code_review",
                        "--verdict",
                        "PASS",
                        "--reviewed-digest",
                        "sha256:" + "0" * 64,
                    ],
                ),
                (
                    "verdict-not-pass",
                    [
                        "code_review",
                        "--verdict",
                        "NEEDS-FIX",
                        "--reviewed-digest",
                        digest,
                    ],
                ),
                (
                    "malformed",
                    [
                        "code_review",
                        "--verdict",
                        "",
                        "--reviewed-digest",
                        digest,
                    ],
                ),
            ]
            for expected_reason, args in cases:
                with self.subTest(reason=expected_reason):
                    proc = _run_issue_evidence(
                        args, cwd=project_root, extra_env=env
                    )
                    self.assertEqual(proc.returncode, 2, msg=proc.stderr)
                    response = json.loads(proc.stdout)
                    self.assertEqual(
                        response, {"issued": False, "reason": expected_reason}
                    )
                    self.assertEqual(
                        _state_file_bytes(project_root),
                        baseline,
                        msg="refusal ({}) must not touch evidence.jsonl/"
                        "ledger.jsonl — no partial writes".format(
                            expected_reason
                        ),
                    )

    def test_security_review_sentinel_refusal_subject_empty(self):
        """subject-empty sentinel (Test PARTIAL 3a, code review round 2 —
        renamed from `test_security_review_sentinel_refusals`: the old name
        said "refusals", plural, implying both closed-value sentinels
        (subject-empty/subject-unresolved), but the body only ever exercised
        subject-empty. Split into one test per sentinel — see
        `test_security_review_sentinel_refusal_subject_unresolved` below for
        the other half.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            env = {"REIN_PROJECT_ROOT": project_root}

            # 최초 code_review 발급 — 다음 두 거부 시도가 이미 존재하는
            # 파일을 건드리지 않는지 확인할 기준선.
            digest_proc = _run_issue_evidence(
                ["code_review", "--print-digest"], cwd=project_root, extra_env=env
            )
            self.assertEqual(digest_proc.returncode, 0, msg=digest_proc.stderr)
            code_digest = digest_proc.stdout.strip()
            success = _run_issue_evidence(
                [
                    "code_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    code_digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(success.returncode, 0, msg=success.stderr)
            baseline = _state_file_bytes(project_root)

            # sensitive 변경이 없는 상태 — security_review digest 는
            # SUBJECT_EMPTY 여야 한다.
            sec_digest_proc = _run_issue_evidence(
                ["security_review", "--print-digest"],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(
                sec_digest_proc.returncode, 0, msg=sec_digest_proc.stderr
            )
            sec_digest = sec_digest_proc.stdout.strip()

            refuse_proc = _run_issue_evidence(
                [
                    "security_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    sec_digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(refuse_proc.returncode, 2, msg=refuse_proc.stderr)
            self.assertEqual(
                json.loads(refuse_proc.stdout),
                {"issued": False, "reason": "subject-empty"},
            )
            self.assertEqual(_state_file_bytes(project_root), baseline)

    def test_security_review_sentinel_refusal_subject_unresolved(self):
        """subject-unresolved sentinel — the other half of the plural name
        `test_security_review_sentinel_refusals` used to only half-cover
        (Test PARTIAL 3a, code review round 2). See
        `test_security_review_sentinel_refusal_subject_empty` above for the
        subject-empty half.

        Triggered by making WORKTREE changeset acquisition itself fail
        (`git status --porcelain -z --untracked-files=all`, invoked by
        `rein.cli._git_changeset_facts` via `worktree_changeset()`) while
        project-root resolution (`git rev-parse --show-toplevel`, used by
        `issue_evidence._resolve_project_root()`) still succeeds — a
        corrupted `.git/index` produces exactly that split (verified
        locally: rev-parse exits 0 against a corrupted index; `git status`/
        `git diff --cached` both exit 128 with "index file smaller than
        expected"). This is the only sentinel of the two that requires an
        actual git-command failure — subject-empty only requires "no
        sensitive changes", no corruption needed (see the sibling test).
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_code_change(project_root)
            env = {"REIN_PROJECT_ROOT": project_root}

            # 최초 code_review 발급 — 다음 거부 시도가 이미 존재하는 파일을
            # 건드리지 않는지 확인할 기준선 (index 손상 이전에 수행).
            digest_proc = _run_issue_evidence(
                ["code_review", "--print-digest"], cwd=project_root, extra_env=env
            )
            self.assertEqual(digest_proc.returncode, 0, msg=digest_proc.stderr)
            code_digest = digest_proc.stdout.strip()
            success = _run_issue_evidence(
                [
                    "code_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    code_digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(success.returncode, 0, msg=success.stderr)
            baseline = _state_file_bytes(project_root)

            index_path = os.path.join(project_root, ".git", "index")
            with open(index_path, "wb") as handle:
                handle.write(b"not a valid git index\n")

            sec_digest_proc = _run_issue_evidence(
                ["security_review", "--print-digest"],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(
                sec_digest_proc.returncode, 0, msg=sec_digest_proc.stderr
            )
            sec_digest = sec_digest_proc.stdout.strip()
            self.assertEqual(sec_digest, SUBJECT_UNRESOLVED)

            refuse_proc = _run_issue_evidence(
                [
                    "security_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    sec_digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(refuse_proc.returncode, 2, msg=refuse_proc.stderr)
            self.assertEqual(
                json.loads(refuse_proc.stdout),
                {"issued": False, "reason": "subject-unresolved"},
            )
            self.assertEqual(_state_file_bytes(project_root), baseline)

    def test_security_review_digest_mismatch_after_start_of_review_change(self):
        """(5) 보안축 review-start→변경→거부 타임라인 (Finding 5, code review round 1).

        리뷰 시작 시점에 sensitive digest 를 캡처한 뒤, 리뷰 도중 sensitive
        파일이 다시 바뀌면 그 OLD digest 로는 발급이 거부돼야 한다
        (digest-mismatch) — security_review 축도 code_review 축과 동일한
        "리뷰 시작 시점 값으로 결속" 계약을 지킴을 고정한다(Finding 2,
        `rein-mark-security-reviewed.sh --reviewed-digest` 가 소비하는
        바로 그 CLI 계약을 subprocess 경계 너머로 검증).
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            env = {"REIN_PROJECT_ROOT": project_root}

            # 리뷰 시작 시점 — sensitive 파일(default sensitive profile 의
            # `.env`) 최초 생성 + digest 캡처.
            with open(
                os.path.join(project_root, ".env"), "w", encoding="utf-8"
            ) as handle:
                handle.write("SECRET=1\n")
            start_digest_proc = _run_issue_evidence(
                ["security_review", "--print-digest"],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(
                start_digest_proc.returncode, 0, msg=start_digest_proc.stderr
            )
            start_digest = start_digest_proc.stdout.strip()

            # 리뷰 도중 — sensitive 파일이 다시 바뀐다.
            with open(
                os.path.join(project_root, ".env"), "w", encoding="utf-8"
            ) as handle:
                handle.write("SECRET=2\n")

            proc = _run_issue_evidence(
                [
                    "security_review",
                    "--verdict",
                    "PASS",
                    "--reviewed-digest",
                    start_digest,
                ],
                cwd=project_root,
                extra_env=env,
            )
            self.assertEqual(proc.returncode, 2, msg=proc.stderr)
            self.assertEqual(
                json.loads(proc.stdout),
                {"issued": False, "reason": "digest-mismatch"},
            )
            self.assertFalse(
                os.path.exists(
                    os.path.join(project_root, ".rein", "state", "ledger.jsonl")
                ),
                msg="digest-mismatch refusal must not write ledger.jsonl",
            )


class UsageDefectExitCodeTest(unittest.TestCase):
    """(d) usage/env 결함 — 전부 exit 1."""

    def test_unknown_capability(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                ["not_a_real_capability", "--print-digest"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")

    def test_missing_args_neither_print_digest_nor_verdict_pair(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            proc = _run_issue_evidence(
                ["code_review"],
                cwd=project_root,
                extra_env={"REIN_PROJECT_ROOT": project_root},
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")

    def test_missing_capability_argument_entirely(self):
        with tempfile.TemporaryDirectory() as project_root:
            proc = _run_issue_evidence([], cwd=project_root)
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)

    def test_not_a_git_repository(self):
        # REIN_PROJECT_ROOT 를 일부러 넘기지 않는다 — 이 테스트가 겨냥하는
        # 것은 자립 규칙(cwd 에서 git toplevel 유도)이므로 REIN_PROJECT_ROOT
        # 를 비운 채 cwd 만 비 git 디렉터리로 지정한다. 명시
        # REIN_PROJECT_ROOT 자체가 non-git 인 경우는
        # test_explicit_non_git_project_root 가 별도로 고정한다(Finding 4,
        # code review round 1 — 명시 값도 이제 git 검증을 거친다).
        with tempfile.TemporaryDirectory() as non_git_dir:
            proc = _run_issue_evidence(
                ["code_review", "--print-digest"], cwd=non_git_dir
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")

    def test_explicit_non_git_project_root(self):
        """(4) 명시 non-git `REIN_PROJECT_ROOT` → exit 1, not exit 2 (digest-mismatch/subject-unresolved 대신).

        수리 전에는 명시 `REIN_PROJECT_ROOT` 를 git 검증 없이 그대로
        신뢰해, non-git 경로를 명시하면 하위 digest 산정이 실패하며
        `subject-unresolved`(exit 2)로 잘못 분류됐다 — "저장소 자체가
        없음"은 판정을 시작조차 못 하는 usage/env 결함(exit 1)이지,
        "판정은 진행했지만 subject 를 못 정한" 사건(exit 2)이 아니다.
        `cwd` 는 실제 git 저장소로 둬서(별도 fixture) 이 테스트가 자립
        규칙이 아니라 명시 값 검증 경로만 겨냥하게 한다.
        """
        with tempfile.TemporaryDirectory() as git_cwd, tempfile.TemporaryDirectory() as non_git_root:
            _init_git_repo(git_cwd)
            proc = _run_issue_evidence(
                ["security_review", "--print-digest"],
                cwd=git_cwd,
                extra_env={"REIN_PROJECT_ROOT": non_git_root},
            )
        self.assertEqual(proc.returncode, 1, msg=proc.stdout)
        self.assertEqual(proc.stdout, "")
        self.assertFalse(
            os.path.exists(os.path.join(non_git_root, ".rein")),
            msg="usage-defect rejection must not create any runtime state "
            "directory",
        )


if __name__ == "__main__":
    unittest.main()
