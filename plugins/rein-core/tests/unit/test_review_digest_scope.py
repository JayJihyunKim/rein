"""code_review "리뷰 digest 범위" 기반부 테스트 (spec §3.6, 2026-08-20 보강,
Phase 7 웨이브 3 ③-a).

`docs/specs/2026-08-07-rein-v2-governance-orchestration.md` §3.6
code_review 절 "리뷰 digest 범위 + 발급 배선 전환 계약"이 고정하는
`rein.platform.git.facts.review_digest()` 의 계약을 검증한다 — 이
워커의 scope(fact 산정 함수 자체)에 한정, capability 평가 결합·authority
게이팅은 `tests/migration/test_authority_valid_evidence_state_table.py`
가 별도로 다룬다.

Scope ID `code-review-evidence-issued-by-runtime-binding-verdict-to-
current-digest` 의 "리뷰 digest 범위 (§3.6 개정)" 측정 지점 6종:

1. WORKTREE 의 staged/unstaged/untracked 변경 각각 포함
   (`ReviewDigestWorktreeScopeInclusionTest`).
2. `*.md`(임의 위치)/`docs/**`/`trail/**` 각각 제외 positive
   (`ReviewDigestAllowlistBoundaryTest`).
3. 허용·비허용 혼합 변경 → non-empty digest (같은 클래스).
4. 버전-only 특례 2파일은 code_review 에서 **비제외**(strict security
   digest 와 대비, `ReviewDigestVersionOnlyExceptionNotAppliedTest`).
5. 리뷰 시작 digest 캡처 후 trail 도장·기록 쓰기 → digest 불변
   (`ReviewDigestUnaffectedByTrailWritesTest` — 이 배선 결함의 원본 실측
   재현·회귀 고정).
6. 실제 코드 변경 → 발급 시점 불일치 미발급(`ReviewDigestIssuanceTimeMismatchRefusalTest`).

허용목록 predicate 는 strict security digest scope 프로필과 **같은
정본**(`_strict_path_is_allowlisted_doc_or_trail`)을 재사용한다 — 이
파일은 그 재사용이 실제로 성립함(패턴을 다시 나열하지 않음)을
간접적으로도 검증한다: `tests/unit/test_security_digest_scope.py` 의
`StrictDigestAllowlistBoundaryTest` 와 동일한 경계 fixture 를 그대로
반복해, 두 함수가 허용목록 경계에서 항상 같은 판정을 내림을 보인다
(`ReviewVsStrictAllowlistParityTest`).

fixture 는 `tests/unit/test_security_digest_scope.py` 의 `_init_git_repo`/
`_write`/`_stage_all`/`_commit_all` 관례를 그대로 재사용한다(실 git
서브프로세스, tempdir 격리).
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

from rein.capabilities.review.capability import (  # noqa: E402
    ReviewDigestMismatch,
    issue_code_review_evidence,
)
from rein.kernel.changeset import SUBJECT_EMPTY, SUBJECT_UNRESOLVED  # noqa: E402
from rein.kernel.evidence import PRODUCER_RUNTIME_VERIFIED  # noqa: E402
from rein.platform.git import facts  # noqa: E402
from rein.platform.sqlite import store as sqlite_store  # noqa: E402
from rein.platform.storage import local  # noqa: E402


def _git(args, cwd, check=True):
    return subprocess.run(
        ("git",) + tuple(args), cwd=cwd, check=check, capture_output=True
    )


def _init_git_repo(base_dir):
    _git(("init", "-q"), base_dir)
    _git(("config", "user.email", "t@example.com"), base_dir)
    _git(("config", "user.name", "t"), base_dir)


def _write(base_dir, rel_path, content):
    full_path = os.path.join(base_dir, rel_path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _stage_all(base_dir):
    _git(("add", "-A"), base_dir)


def _commit_all(base_dir, message="fixture commit"):
    _git(("add", "-A"), base_dir)
    _git(("commit", "-q", "-m", message), base_dir)


_PLUGIN_JSON_REL = "plugins/rein-core/.claude-plugin/plugin.json"


def _seed_repo(base_dir):
    """공통 초기 커밋 — `tests/unit/test_security_digest_scope.py::_seed_repo`
    와 동일 관례(버전-only 특례 2파일을 HEAD 에 존재시켜 diff 대조 기준선
    을 만든다)."""
    _init_git_repo(base_dir)
    _write(base_dir, "scripts/rein.sh", 'VERSION="1.0.0"\n')
    _write(
        base_dir,
        _PLUGIN_JSON_REL,
        json.dumps({"name": "rein", "version": "1.0.0"}, indent=2) + "\n",
    )
    _write(base_dir, "src/app.py", "x = 1\n")
    _commit_all(base_dir, "seed")


def _review_digest(base_dir):
    """WORKTREE changeset 을 계산해 `review_digest()` 에 그대로 넘긴다 —
    `rein.cli._git_changeset_facts()` 의 "단일 pass" 호출 형태를 최소
    재현(테스트 전용, cli 배선 자체는 별도 워커/파일 소관)."""
    changeset = facts.worktree_changeset(cwd=base_dir)
    return facts.review_digest(changeset, cwd=base_dir)


# ---------------------------------------------------------------------------
# 1. WORKTREE staged/unstaged/untracked 각각 포함.


class ReviewDigestWorktreeScopeInclusionTest(unittest.TestCase):
    def test_staged_change_is_included(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/app.py", "x = 2\n")
            _stage_all(base_dir)
            digest = _review_digest(base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
            self.assertTrue(digest.startswith("sha256:"))

    def test_unstaged_change_is_included(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            # 스테이징하지 않는다 — tracked 파일의 미스테이징 편집.
            _write(base_dir, "src/app.py", "x = 3\n")
            digest = _review_digest(base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))

    def test_untracked_change_is_included(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/new_module.py", "y = 1\n")
            digest = _review_digest(base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))

    def test_staged_and_unstaged_and_untracked_together_all_contribute(self):
        """세 클래스 각각이 실제로 digest 에 기여하는지 검증한다 (Test PARTIAL
        3c, code review round 2 — 이전 버전은 세 클래스를 동시에 갖춘 뒤
        `assertNotEqual(digest, SUBJECT_EMPTY)` 만 확인했다. non-empty 확인
        만으로는 예컨대 untracked 클래스 하나가 조용히 무시돼도 다른 두
        클래스만으로 이미 non-empty 였다면 테스트가 통과했을 것이다 — 세
        클래스를 각자 다른 파일에 배정해, 전체 digest 를 기준선으로 삼고 한
        클래스씩 되돌릴 때마다 digest 가 실제로 바뀌는지 확인한다.
        """
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            # "unstaged" 클래스 전용 파일 — clean 상태로 커밋해 둔다(staged
            # 클래스가 쓰는 src/app.py 와 분리해, 한 클래스를 되돌릴 때 다른
            # 클래스가 같이 사라지지 않게 한다).
            _write(base_dir, "src/unstaged_target.py", "u = 0\n")
            _commit_all(base_dir, "seed unstaged target")

            # 세 클래스를 각자 다른 파일에 동시에 만든다.
            _write(base_dir, "src/app.py", "x = 4\n")                 # staged
            _stage_all(base_dir)
            _write(base_dir, "src/unstaged_target.py", "u = 1\n")     # unstaged (tracked, 미스테이징)
            _write(base_dir, "src/untracked.py", "z = 1\n")           # untracked (신규)

            digest_all = _review_digest(base_dir)
            self.assertNotEqual(digest_all, SUBJECT_EMPTY)
            self.assertNotEqual(digest_all, SUBJECT_UNRESOLVED)
            self.assertTrue(digest_all.startswith("sha256:"))

            # untracked 클래스만 제거 → digest 가 바뀌어야 한다.
            os.remove(os.path.join(base_dir, "src/untracked.py"))
            digest_without_untracked = _review_digest(base_dir)
            self.assertNotEqual(
                digest_without_untracked,
                digest_all,
                "removing the untracked-only file did not change the "
                "digest — the untracked class is not actually "
                "contributing",
            )
            _write(base_dir, "src/untracked.py", "z = 1\n")  # 복원 — 다음 비교는 다시 3클래스 기준

            # unstaged 클래스만 제거 (해당 파일을 HEAD 상태로 되돌림) →
            # digest 가 바뀌어야 한다.
            _git(("checkout", "HEAD", "--", "src/unstaged_target.py"), base_dir)
            digest_without_unstaged = _review_digest(base_dir)
            self.assertNotEqual(
                digest_without_unstaged,
                digest_all,
                "discarding the unstaged-only edit did not change the "
                "digest — the unstaged class is not actually "
                "contributing",
            )
            _write(base_dir, "src/unstaged_target.py", "u = 1\n")  # 복원

            # staged 클래스만 제거 (해당 파일을 HEAD 상태로 되돌림 — index +
            # worktree 둘 다) → digest 가 바뀌어야 한다.
            _git(("checkout", "HEAD", "--", "src/app.py"), base_dir)
            digest_without_staged = _review_digest(base_dir)
            self.assertNotEqual(
                digest_without_staged,
                digest_all,
                "discarding the staged-only change did not change the "
                "digest — the staged class is not actually contributing",
            )


# ---------------------------------------------------------------------------
# 2/3. 허용목록 경계 positive 3종 + 혼합 변경 → non-empty.


class ReviewDigestAllowlistBoundaryTest(unittest.TestCase):
    def test_md_anywhere_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "deep/nested/dir/notes.md", "note\n")
            digest = _review_digest(base_dir)
            self.assertEqual(digest, SUBJECT_EMPTY)

    def test_docs_recursive_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/guide.txt", "guide\n")
            _write(base_dir, "docs/a/b/c/deep.txt", "deep\n")
            digest = _review_digest(base_dir)
            self.assertEqual(digest, SUBJECT_EMPTY)

    def test_trail_recursive_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "trail/inbox/entry.md", "entry\n")
            _write(base_dir, "trail/dod/.spec-reviews/x.reviewed", "r\n")
            digest = _review_digest(base_dir)
            self.assertEqual(digest, SUBJECT_EMPTY)

    def test_mixed_allow_and_nonallow_is_nonempty_digest(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/guide.md", "guide\n")
            _write(base_dir, "src/app.py", "x = 2\n")  # 실질 코드 변경
            digest = _review_digest(base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
            self.assertTrue(digest.startswith("sha256:"))

    def test_no_worktree_changes_returns_subject_empty(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            digest = _review_digest(base_dir)
            self.assertEqual(digest, SUBJECT_EMPTY)


# ---------------------------------------------------------------------------
# 4. 버전-only 특례 2파일은 code_review 에서 비제외 (strict 와 대비).


class ReviewDigestVersionOnlyExceptionNotAppliedTest(unittest.TestCase):
    def test_rein_sh_version_only_change_is_not_allowlisted_for_review(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "scripts/rein.sh", 'VERSION="1.0.1"\n')
            digest = _review_digest(base_dir)
            # strict_security_digest 라면 이 변경은 SUBJECT_EMPTY(면제)
            # 지만, code_review 는 버전 라인 변경도 검토 대상이다(spec
            # §3.6 명시 — 특례를 코드리뷰에 적용하지 않는다).
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))
            # 대비 확인 — 같은 staged 변경을 strict 프로필로는 여전히
            # 면제로 판정한다(정본이 갈라지는 게 아니라 특례 적용 여부만
            # 다르다는 것을 같은 fixture 로 직접 대조).
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_plugin_json_version_only_change_is_not_allowlisted_for_review(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(
                base_dir,
                _PLUGIN_JSON_REL,
                json.dumps({"name": "rein", "version": "1.0.1"}, indent=2)
                + "\n",
            )
            digest = _review_digest(base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )


# ---------------------------------------------------------------------------
# 5. 리뷰 시작 digest 캡처 후 trail 도장·기록 쓰기 → digest 불변.
#
# 이 클래스가 §3.6 개정을 촉발한 실측 결함의 직접 회귀 고정이다 — 배선
# 전 구현(전체 WORKTREE digest, trail/ 포함)에서는 이 시나리오가
# self-invalidating 이었다(발급 시점 재계산 digest 가 캡처 시점과
# 달라져 발급이 상시 거부됐다).


class ReviewDigestUnaffectedByTrailWritesTest(unittest.TestCase):
    def test_digest_unchanged_after_writing_codex_review_stamp(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/app.py", "x = 2\n")  # 실질 코드 변경
            captured = _review_digest(base_dir)
            self.assertNotEqual(captured, SUBJECT_EMPTY)

            # 리뷰 완료 후 trail/dod/.codex-reviewed 도장을 쓴다(v1 legacy
            # 표식 병행 기록 — spec §3.6 "전환기 동안 legacy 표식 병행
            # 기록을 유지" 절).
            _write(
                base_dir,
                "trail/dod/.codex-reviewed",
                "verdict: PASS\nreviewed_at: 2026-08-20T00:00:00Z\n"
                "cycle: 1\n",
            )
            recaptured = _review_digest(base_dir)
            self.assertEqual(
                captured,
                recaptured,
                msg="trail/dod/ 도장 쓰기는 trail/** 허용목록에 속해 "
                "review digest 를 바꾸지 않아야 한다 — 배선 전 구현의 "
                "self-invalidation 결함 회귀 고정",
            )

    def test_digest_unchanged_after_writing_evidence_ledger_record(self):
        """Test PARTIAL 3b (code review round 2): the name promises an
        actual evidence+ledger record write, but the previous body only
        wrote a `trail/inbox/*.md` note — already covered by the sibling
        `_codex_review_stamp` test's `trail/**` allowlist claim, and not
        what "evidence_ledger_record" says it tests. This version writes a
        REAL evidence+ledger entry via the same store writer `bin/rein
        issue-evidence` uses (`LedgerVerifiedEvidenceSource.record_issued`,
        appending to `.rein/state/evidence.jsonl` + `.rein/state/
        ledger.jsonl` under the fixture root) and asserts the review digest
        is unaffected.
        """
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/app.py", "x = 3\n")
            captured = _review_digest(base_dir)

            # `.rein/` must be gitignored BEFORE anything writes under it —
            # otherwise the evidence/ledger files below would show up as
            # untracked (non-allowlisted) WORKTREE changes and trivially
            # change the digest, which would make this test's premise
            # false rather than true (same reasoning as `tests/cli/
            # test_issue_evidence_subcommand.py::_init_git_repo`). Stage +
            # commit ONLY .gitignore (not `-A`) so the still-uncommitted
            # src/app.py edit captured above stays exactly as it was.
            _write(base_dir, ".gitignore", ".rein/\n")
            _git(("add", ".gitignore"), base_dir)
            _git(("commit", "-q", "-m", "chore(test): gitignore .rein"), base_dir)

            root = local.LocalStateRoot(base_dir)
            root.ensure()
            source = sqlite_store.LedgerVerifiedEvidenceSource(root)
            record = {
                "type": "code_review",
                "subject": captured,
                "result": "PASS",
                "created_at": "2026-08-20T00:00:00+00:00",
                "producer": PRODUCER_RUNTIME_VERIFIED,
                "policy_version": "1",
                "metadata": {},
            }
            source.record_issued("code_review", record)

            # Confirm the write actually landed before trusting "unchanged"
            # below — an evidence write that silently no-ops would make the
            # digest-unchanged assertion vacuously true.
            evidence_path = os.path.join(
                base_dir, ".rein", "state", "evidence.jsonl"
            )
            ledger_path = os.path.join(base_dir, ".rein", "state", "ledger.jsonl")
            self.assertTrue(os.path.exists(evidence_path))
            self.assertTrue(os.path.exists(ledger_path))

            recaptured = _review_digest(base_dir)
            self.assertEqual(
                captured,
                recaptured,
                msg="writing a real v2 evidence+ledger record changed the "
                "review digest — this is the exact self-invalidation bug "
                "this test class regression-locks (evidence issuance must "
                "not make its own subject stale)",
            )


# ---------------------------------------------------------------------------
# 6. 실제 코드 변경 → 발급 시점 불일치 미발급.


class ReviewDigestIssuanceTimeMismatchRefusalTest(unittest.TestCase):
    def test_code_change_after_capture_causes_issuance_mismatch_refusal(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/app.py", "x = 2\n")
            reviewed_digest = _review_digest(base_dir)
            self.assertNotEqual(reviewed_digest, SUBJECT_EMPTY)

            # 리뷰 이후 코드가 또 바뀐다 — 발급 시점 재계산 digest 가
            # 리뷰가 주장한 digest 와 달라진다.
            _write(base_dir, "src/app.py", "x = 999\n")
            current_digest = _review_digest(base_dir)
            self.assertNotEqual(current_digest, reviewed_digest)

            with self.assertRaises(ReviewDigestMismatch):
                issue_code_review_evidence(
                    {"verdict": "PASS", "reviewed_digest": reviewed_digest},
                    current_digest=current_digest,
                    policy_version="1",
                )


# ---------------------------------------------------------------------------
# 경계 정본 단일화의 간접 확인 — strict security digest 와 review digest
# 가 문서/trail 허용목록 판정에서 항상 일치함(재구현이 아니라 재사용).


class ReviewVsStrictAllowlistParityTest(unittest.TestCase):
    def test_md_docs_trail_allowlisted_in_both_functions(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "notes.md", "n\n")
            _write(base_dir, "docs/guide.md", "g\n")
            _write(base_dir, "trail/dod/x.md", "x\n")
            review_value = _review_digest(base_dir)
            _stage_all(base_dir)
            strict_value = facts.strict_security_digest(cwd=base_dir)
            self.assertEqual(review_value, SUBJECT_EMPTY)
            self.assertEqual(strict_value, SUBJECT_EMPTY)


if __name__ == "__main__":
    unittest.main()
