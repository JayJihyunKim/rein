"""security_review "digest scope 프로필" 기반부 테스트 (spec §3.6, 2026-08-19).

`docs/specs/2026-08-07-rein-v2-governance-orchestration.md` §3.6 "digest
scope 프로필" 절이 고정하는 계약을 이 워커의 scope(기반부만 — capability
평가·cli 배선은 후속 워커) 안에서 검증한다:

1. 정책 폴더 `_version.yaml` 의 `digest_scope` 필드 4상태
   (`rein.kernel.policy` — `DigestScopeProfileLoaderTest`).
2. strict 범위 subject digest 산정 함수(`rein.platform.git.facts.
   strict_security_digest`)의 허용목록 경계(`*.md` 임의 위치 /
   `docs/**` / `trail/**` 재귀 — `StrictDigestAllowlistBoundaryTest`).
3. 버전-only 특례 2파일의 positive/negative
   (`StrictDigestVersionOnlyExceptionTest`).
4. 닫힌 값 계약 2상태(`SUBJECT_EMPTY`/`SUBJECT_UNRESOLVED`,
   `StrictDigestClosedValueContractTest`).

**2026-08-20 보강 (리뷰 지적 — 위 §3.6 기반부만으로는 미해결이던 3가지)**:

5. **sensitive 분류 우선** — `strict_security_digest()` 가 문서/trail
   허용목록을 sensitive 분류보다 먼저 적용하던 결함 수리
   (`StrictDigestSensitivePriorityTest`). `docs/.env`/`trail/.npmrc`/
   `secrets/*.md` 처럼 문서 계열 경로 모양이어도 태그 규칙상 sensitive
   면 강제 검토 대상이어야 한다(보수 불변식 strict ⊇ sensitive).
6. **정책 버전 선언의 git 상태·수명주기 판정** — `_version.yaml` 의 유효
   선언 = HEAD 커밋 내용(git 저장소+추적 시), 5상태(s1~s5) + malformed
   교차 계약(m1~m3) (`rein.platform.git.facts.
   resolve_policy_version_digest_scope` — `DigestScopeGitLifecycleTest`/
   `DigestScopeMalformedCrossStateTest`). worktree 를 그대로 읽으면
   미커밋 편집만으로 strict→sensitive 무음 강등이 가능했다.
7. **복구 커밋 동반 변경** — m2(HEAD malformed + 순수 복구 스테이징)
   상태에서 strict 프로필이 강제되면, 동반 staged 된 sensitive 경로도
   digest 계산에 실제로 포함된다(`RecoveryCommitSiblingPathScenarioTest`
   — 5·6 의 조합이 end-to-end 로 성립함을 확인).

fixture 는 `tests/cli/test_changeset_fact_dependency_gating.py` 의
`_init_git_repo` 관례(tempdir + 실 git 서브프로세스)를 재사용한다 —
`subprocess.run` 직결 호출은 Claude Code 의 Bash 툴 commit-msg 게이트를
거치지 않는 별도 경로이므로 커밋 메시지 형식 제약이 없다(이 파일
자체는 그 게이트를 시험하지 않는다, 무관 관심사).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

# self-locating sys.path 주입 — discover top-level 이 tests/unit 이어도
# plugin root 의 rein 패키지를 import 할 수 있게 한다 (관례 계승,
# test_changeset_digest.py 와 동일 패턴).
_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel import policy  # noqa: E402
from rein.kernel.changeset import SUBJECT_EMPTY, SUBJECT_UNRESOLVED  # noqa: E402
from rein.platform.git import facts  # noqa: E402


# ---------------------------------------------------------------------------
# 실 git 저장소 fixture — `tests/cli/test_changeset_fact_dependency_gating.py`
# 의 `_init_git_repo` 관례를 재사용(subprocess 직결, Bash 툴 게이트 무관).


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
    """공통 초기 커밋 — `scripts/rein.sh`/plugin.json 버전-only 특례 대상
    2파일을 HEAD 에 존재시켜(diff 대조 기준선) 이후 staged 변경으로
    버전-only 판정을 시험할 수 있게 한다.
    """
    _init_git_repo(base_dir)
    _write(base_dir, "scripts/rein.sh", 'VERSION="1.0.0"\n')
    _write(
        base_dir,
        _PLUGIN_JSON_REL,
        json.dumps({"name": "rein", "version": "1.0.0"}, indent=2) + "\n",
    )
    _write(base_dir, "src/app.py", "x = 1\n")
    _commit_all(base_dir, "seed")


class _TempVersionDir(object):
    """`_version.yaml` fixture 를 임시 디렉토리에 써서 실 로더에 태운다
    (`tests/unit/test_policy_version_loader.py` 의 `_TempVersionDir` 와
    동일 관례 — 저장소 트리에 fixture 파일을 남기지 않는다).
    """

    def __init__(self, text):
        self._text = text
        self._tempdir = None

    def __enter__(self):
        self._tempdir = tempfile.TemporaryDirectory()
        path = os.path.join(self._tempdir.name, policy.VERSION_FILENAME)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(self._text)
        return self._tempdir.name

    def __exit__(self, *exc_info):
        self._tempdir.cleanup()


# ---------------------------------------------------------------------------
# 1. 정책 폴더 digest_scope 4상태 (spec §3.6, rein.kernel.policy).


class DigestScopeProfileLoaderTest(unittest.TestCase):
    def test_unset_defaults_to_sensitive(self):
        with _TempVersionDir("version: 1\n") as policy_dir:
            result = policy.load_policy_version(policy_dir)
        self.assertEqual(result.digest_scope, policy.DIGEST_SCOPE_SENSITIVE)

    def test_explicit_sensitive_is_accepted(self):
        with _TempVersionDir(
            "version: 1\ndigest_scope: sensitive\n"
        ) as policy_dir:
            result = policy.load_policy_version(policy_dir)
        self.assertEqual(result.digest_scope, policy.DIGEST_SCOPE_SENSITIVE)

    def test_explicit_strict_is_accepted(self):
        with _TempVersionDir(
            "version: 1\ndigest_scope: strict\n"
        ) as policy_dir:
            result = policy.load_policy_version(policy_dir)
        self.assertEqual(result.digest_scope, policy.DIGEST_SCOPE_STRICT)

    def test_unknown_value_is_load_time_error(self):
        with _TempVersionDir(
            "version: 1\ndigest_scope: loose\n"
        ) as policy_dir:
            with self.assertRaises(policy.PolicyVersionError) as caught:
                policy.load_policy_version(policy_dir)
        self.assertIn("digest_scope", str(caught.exception))

    def test_repository_declaration_resolves_to_strict(self):
        # 실제 저장소 선언 (.rein/policy/security-axis/_version.yaml) 이
        # strict 로 정확히 읽히는지 — 워커 항목 4의 결과를 여기서 직접
        # 재확인한다 (fixture 가 아니라 실 파일).
        # _PLUGIN_ROOT = .../plugins/rein-core — repo root 는 그 조부모.
        repo_root = os.path.dirname(os.path.dirname(_PLUGIN_ROOT))
        security_axis_dir = os.path.join(
            repo_root, ".rein", "policy", "security-axis"
        )
        if not os.path.isdir(security_axis_dir):
            self.skipTest(
                "저장소 .rein/policy/security-axis 부재 — plugin 단독 "
                "체크아웃 등 이 파일이 없는 환경에서는 건너뛴다"
            )
        result = policy.load_policy_version(security_axis_dir)
        self.assertEqual(result.digest_scope, policy.DIGEST_SCOPE_STRICT)


# ---------------------------------------------------------------------------
# 2. strict 범위 허용목록 경계 (rein.platform.git.facts.strict_security_digest).


class StrictDigestAllowlistBoundaryTest(unittest.TestCase):
    def test_md_anywhere_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "deep/nested/dir/notes.md", "note\n")
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_docs_recursive_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/guide.txt", "guide\n")
            _write(base_dir, "docs/a/b/c/deep.txt", "deep\n")
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_trail_recursive_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "trail/inbox/entry.md", "entry\n")
            _write(base_dir, "trail/dod/.spec-reviews/x.reviewed", "r\n")
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_mixed_allow_and_nonallow_is_nonempty_digest(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/guide.md", "guide\n")
            _write(base_dir, "src/app.py", "x = 2\n")  # 실질 코드 변경
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
            self.assertTrue(digest.startswith("sha256:"))

    def test_nonallowlisted_change_alone_is_nonempty_digest(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "src/app.py", "x = 999\n")
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))


# ---------------------------------------------------------------------------
# 3. 버전-only 특례 2파일 — positive/negative.


class StrictDigestVersionOnlyExceptionTest(unittest.TestCase):
    def test_rein_sh_version_only_change_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "scripts/rein.sh", 'VERSION="1.0.1"\n')
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_rein_sh_version_plus_other_line_is_not_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(
                base_dir,
                "scripts/rein.sh",
                'VERSION="1.0.1"\necho "not a version line"\n',
            )
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))

    def test_plugin_json_version_only_change_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(
                base_dir,
                _PLUGIN_JSON_REL,
                json.dumps({"name": "rein", "version": "1.0.1"}, indent=2)
                + "\n",
            )
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_plugin_json_other_key_change_is_not_allowlisted(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(
                base_dir,
                _PLUGIN_JSON_REL,
                json.dumps(
                    {"name": "rein-renamed", "version": "1.0.1"}, indent=2
                )
                + "\n",
            )
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
            self.assertNotEqual(digest, SUBJECT_EMPTY)
            self.assertTrue(digest.startswith("sha256:"))


# ---------------------------------------------------------------------------
# 4. 닫힌 값 계약 2상태 — SUBJECT_EMPTY / SUBJECT_UNRESOLVED.


class StrictDigestClosedValueContractTest(unittest.TestCase):
    def test_no_staged_changes_returns_subject_empty(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_all_staged_allowlisted_returns_subject_empty(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/x.md", "x\n")
            _write(base_dir, "trail/y.md", "y\n")
            _stage_all(base_dir)
            self.assertEqual(
                facts.strict_security_digest(cwd=base_dir), SUBJECT_EMPTY
            )

    def test_git_failure_returns_subject_unresolved(self):
        with tempfile.TemporaryDirectory() as base_dir:
            # git 저장소가 아닌 디렉토리 — `git diff --cached` 가 비0
            # 종료해 staged 경로 획득 자체가 실패한다.
            digest = facts.strict_security_digest(cwd=base_dir)
            self.assertEqual(digest, SUBJECT_UNRESOLVED)

    def test_nonexistent_cwd_returns_subject_unresolved(self):
        digest = facts.strict_security_digest(
            cwd="/nonexistent/path/for/strict-digest-test"
        )
        self.assertEqual(digest, SUBJECT_UNRESOLVED)

    def test_empty_and_unresolved_are_distinct_nonempty_strings(self):
        # Evidence.subject 계약(비어있지 않은 문자열) 을 만족하고, 둘은
        # 서로 다른 값이며, 실제 digest 값 공간("sha256:<hex>")과도
        # 겹치지 않는다 (kernel/changeset.py SUBJECT_EMPTY/UNRESOLVED
        # 정의 근거의 재확인).
        self.assertTrue(SUBJECT_EMPTY)
        self.assertTrue(SUBJECT_UNRESOLVED)
        self.assertNotEqual(SUBJECT_EMPTY, SUBJECT_UNRESOLVED)
        self.assertFalse(SUBJECT_EMPTY.startswith("sha256:"))
        self.assertFalse(SUBJECT_UNRESOLVED.startswith("sha256:"))


# ---------------------------------------------------------------------------
# 5. sensitive 분류 우선 — 보수 불변식 strict ⊇ sensitive (2026-08-20 보강).


class StrictDigestSensitivePriorityTest(unittest.TestCase):
    """태그 규칙상 sensitive 로 분류되는 경로는 허용목록 판정에서 제외된다
    — 문서 계열 경로(`*.md`/`docs/**`/`trail/**`)로 위장해도 basename 이
    sensitive 패턴이면 강제 검토 대상."""

    def test_docs_env_is_not_exempted(self):
        # docs/** 허용목록 경로지만 basename 이 `.env` — sensitive 우선.
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/.env", "SECRET=1\n")
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
        self.assertNotEqual(digest, SUBJECT_EMPTY)
        self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
        self.assertTrue(digest.startswith("sha256:"))

    def test_trail_npmrc_is_not_exempted(self):
        # trail/** 허용목록 경로지만 basename 이 `.npmrc` — sensitive 우선.
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "trail/.npmrc", "//registry/:_authToken=x\n")
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
        self.assertNotEqual(digest, SUBJECT_EMPTY)
        self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
        self.assertTrue(digest.startswith("sha256:"))

    def test_secrets_markdown_is_not_exempted(self):
        # `.md` 확장자 허용목록(임의 위치)과 `secrets/` 경로 패턴이 정면
        # 충돌하는 조합 — secrets/ 패턴(sensitive)이 .md 허용목록보다
        # 우선해야 한다.
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "secrets/runbook.md", "token: abc\n")
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
        self.assertNotEqual(digest, SUBJECT_EMPTY)
        self.assertNotEqual(digest, SUBJECT_UNRESOLVED)
        self.assertTrue(digest.startswith("sha256:"))

    def test_strict_target_set_is_superset_of_sensitive_classification(self):
        """대표 sensitive 패턴 각각이 (문서류 접두/확장자로 위장해도)
        strict 비허용(검토 대상) 집합에서 빠지지 않는다 — strict ⊇
        sensitive 불변식의 대표 표본 확인(전수 아님, policies/tags.yaml
        규칙 커버리지 대표 추출: basename 매칭·경로 매칭·확장자 겹침
        조합 각 1개 이상)."""
        from rein.engine.tags import TAG_SENSITIVE, classify_path, load_tag_rules

        representative_paths = (
            ".env",
            "docs/.env",
            "id_rsa",
            "trail/id_rsa",
            "a/b/secrets/notes.md",
            ".npmrc",
            "config/firebase-adminsdk-xyz.json",
            ".kube/config",
        )
        rules = load_tag_rules()
        for path in representative_paths:
            with self.subTest(path=path):
                self.assertEqual(
                    classify_path(path, rules),
                    TAG_SENSITIVE,
                    "이 표본 자체가 sensitive 로 분류되지 않으면 이 "
                    "테스트가 검증하려는 전제가 성립하지 않는다",
                )
                with tempfile.TemporaryDirectory() as base_dir:
                    _seed_repo(base_dir)
                    _write(base_dir, path, "x\n")
                    _stage_all(base_dir)
                    digest = facts.strict_security_digest(cwd=base_dir)
                self.assertNotEqual(
                    digest,
                    SUBJECT_EMPTY,
                    msg="{!r} 은 sensitive 분류인데 strict digest 에서 "
                    "허용목록으로 조용히 면제됐다 (strict ⊇ sensitive "
                    "위반)".format(path),
                )

    def test_pure_allowlist_regression_still_holds(self):
        """기존 허용목록 순수 케이스 회귀 유지 — sensitive 우선 검사를
        추가해도 진짜 문서/trail 파일(sensitive 아님)은 여전히 면제."""
        with tempfile.TemporaryDirectory() as base_dir:
            _seed_repo(base_dir)
            _write(base_dir, "docs/guide.md", "guide\n")
            _write(base_dir, "trail/inbox/entry.md", "entry\n")
            _stage_all(base_dir)
            digest = facts.strict_security_digest(cwd=base_dir)
        self.assertEqual(digest, SUBJECT_EMPTY)


# ---------------------------------------------------------------------------
# 6. 정책 버전 선언의 git 상태·수명주기 판정 — s1~s5 (2026-08-20 보강).


class DigestScopeGitLifecycleTest(unittest.TestCase):
    """`rein.platform.git.facts.resolve_policy_version_digest_scope` —
    spec §3.6 "선언의 유효 기준" 절 s1~s5(malformed 은 별도 클래스)."""

    def _policy_dir(self, base_dir):
        return os.path.join(base_dir, "policy")

    def _write_version(self, base_dir, text):
        _write(base_dir, "policy/_version.yaml", text)

    def test_s1_clean_committed_declaration_is_used(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            _commit_all(base_dir, "add version file")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_STRICT,
            )

    def test_s1_clean_absent_defaults_to_sensitive(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            policy_dir = self._policy_dir(base_dir)
            os.makedirs(policy_dir, exist_ok=True)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_SENSITIVE,
            )

    def test_s2_pure_staged_add_uses_head_absent_default(self):
        # 최초 추가(HEAD 부재) — staged 만 있고 커밋 전이면 기본값 사용.
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_SENSITIVE,
            )

    def test_s2_pure_staged_modification_uses_head_pre_change_value(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\n")  # 기본(sensitive)
            _commit_all(base_dir, "seed version")
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            _stage_all(base_dir)
            # worktree=index(strict 선언) 이지만 HEAD 는 여전히 구 선언
            # (sensitive) — 커밋 전까지는 HEAD 기준.
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_SENSITIVE,
            )

    def test_s2_pure_staged_deletion_uses_head_value(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            _commit_all(base_dir, "seed version")
            os.remove(os.path.join(base_dir, "policy", "_version.yaml"))
            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_STRICT,
            )

    def test_s3_tracked_unstaged_edit_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\n")
            _commit_all(base_dir, "seed version")
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            # staged 하지 않음 — worktree 만 편집된 상태.
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )

    def test_s3_tracked_unstaged_deletion_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\n")
            _commit_all(base_dir, "seed version")
            os.remove(os.path.join(base_dir, "policy", "_version.yaml"))
            # staged 하지 않음 — worktree 삭제만.
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )

    def test_s4_untracked_new_file_has_no_authority_and_warns(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            # staged 도, 커밋도 안 됨 — 완전 신규 untracked 파일.
            with self.assertWarns(RuntimeWarning):
                result = facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )
            self.assertEqual(result, policy.DIGEST_SCOPE_SENSITIVE)

    def test_s5_non_git_context_falls_back_to_worktree_load(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            with open(
                os.path.join(policy_dir, "_version.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("version: 1\ndigest_scope: strict\n")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_STRICT,
            )

    # -- 전이 2종 --------------------------------------------------------

    def test_transition_untracked_to_staged_to_committed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            policy_dir = self._policy_dir(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")

            with self.assertWarns(RuntimeWarning):
                self.assertEqual(
                    facts.resolve_policy_version_digest_scope(policy_dir),
                    policy.DIGEST_SCOPE_SENSITIVE,
                )  # s4 — untracked

            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_SENSITIVE,
            )  # s2 — HEAD 부재, 커밋 전

            _commit_all(base_dir, "commit version")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_STRICT,
            )  # s1 — 커밋 후 발효

    def test_transition_existing_to_staged_delete_to_absent(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            policy_dir = self._policy_dir(base_dir)
            self._write_version(base_dir, "version: 1\ndigest_scope: strict\n")
            _commit_all(base_dir, "seed version")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_STRICT,
            )  # s1

            os.remove(os.path.join(base_dir, "policy", "_version.yaml"))
            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_STRICT,
            )  # s2 — staged 삭제, 커밋 전(HEAD 의 구 선언 기준)

            _commit_all(base_dir, "remove version file")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_SENSITIVE,
            )  # s1 — 부재 발효


# ---------------------------------------------------------------------------
# 6a. git 실행 실패 vs 비-git 오분류 수리 (High, 2026-08-20 리뷰 지적).


class DigestScopeGitExecutionFailureVsNonGitTest(unittest.TestCase):
    """`resolve_policy_version_digest_scope()` 의 최초 git 조회
    (`rev-parse --show-toplevel` 계열)가 실패하면 `_run_git()` 은
    비-git 저장소·timeout·프로세스 실행 오류를 전부 `None` 하나로
    합친다. 수리 전에는 이 함수가 그 `None` 을 곧바로 s5(비 git 문맥)로
    판정해 worktree 파일을 직접(신뢰하며) 읽었다 — git 이 진짜로
    "저장소 아님" 이라고 답한 것과, git 호출 자체가 timeout/프로세스
    오류로 죽은 것을 구분하지 못했다.

    리뷰어 재현: `policy_dir` 는 strict 로 committed 된 실제 git
    저장소이고, 지금은 커밋되지 않은(unstaged) 편집으로 로컬 worktree
    파일이 `sensitive` 로 바뀐 상태(정상 경로라면 s3 — tracked
    미스테이징 divergence → `PolicyVersionGitStateError`, 모호 상태
    fail-closed). 이 상태에서 최초 git 조회만 프로세스 오류로 실패하게
    주입하면, 수리 전 코드는 s5 로 오판해 그 미스테이징 worktree 파일
    (`sensitive`)을 그대로 신뢰해 반환했다 — strict 저장소가 순간적인
    git 실행 실패 하나로 조용히 sensitive 로 강등되는 경로였다. 수리
    후에는 "확실히 비-git" 신호(git 이 정상 실행되어 "not a git
    repository" 로 응답)와 "판정 실패"(그 밖의 모든 실행 실패)를
    구분해, 후자는 `PolicyVersionGitStateError` 로 fail-closed 해야
    한다 — 비-git 문맥(진짜 git 저장소 밖)은 여전히 s5 로 정상 동작
    해야 한다(회귀 대조군).
    """

    def _policy_dir(self, base_dir):
        return os.path.join(base_dir, "policy")

    def _write_version(self, base_dir, text):
        _write(base_dir, "policy/_version.yaml", text)

    def test_execution_failure_on_initial_git_query_is_fail_closed_not_demoted(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            _commit_all(base_dir, "seed strict version")
            # 미스테이징 편집 — 정상 경로라면 s3(모호, fail-closed).
            self._write_version(
                base_dir, "version: 1\ndigest_scope: sensitive\n"
            )
            policy_dir = self._policy_dir(base_dir)

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if "--show-toplevel" in args or "--is-inside-work-tree" in args:
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(
                facts.subprocess, "run", side_effect=_flaky_run
            ):
                with self.assertRaises(
                    facts.PolicyVersionGitStateError,
                    msg="git 조회 실행 실패(timeout)는 '비-git 문맥' 이 "
                    "아니다 — worktree 의 미스테이징 sensitive 편집을 "
                    "신뢰해 조용히 강등하면 안 되고, 상태 판정 실패로 "
                    "fail-closed 해야 한다",
                ):
                    facts.resolve_policy_version_digest_scope(policy_dir)

    def test_confirmed_non_git_context_still_resolves_as_s5(self):
        # 회귀 대조군 — 진짜 git 저장소 밖은 여전히 s5(비 git 문맥)로
        # 정상 동작해야 한다(수리가 실행 실패만 구분해야지, 진짜 비-git
        # 판정 자체를 막으면 안 된다).
        with tempfile.TemporaryDirectory() as policy_dir:
            with open(
                os.path.join(policy_dir, "_version.yaml"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("version: 1\ndigest_scope: strict\n")
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir),
                policy.DIGEST_SCOPE_STRICT,
            )


# ---------------------------------------------------------------------------
# 6a-2. policy_dir 자체가 존재하지 않는 경우 — git 조회 실패와 별개 상태.
# `subprocess.run(cwd=<존재하지 않는 경로>)` 는 git 이 실행되기도 전에
# `FileNotFoundError`(OSError)를 던진다 — git 은 호출된 적이 없으므로 그
# 부재를 `_GIT_QUERY_ERROR`(git 조회 실패) 로 흡수하면 문구가 엉뚱하게
# git 을 지목한다. 부재(ENOENT)만 이 상태로 분류하고, 경로가 일반 파일인
# 경우 등 다른 OSError 는 여전히 판정 실패(fail-closed) 로 흐른다.


class PolicyDirDoesNotExistTest(unittest.TestCase):
    """policy_dir 부재는 git 조회 실패와 구분된 fail-closed 사유를 내야
    한다 — 문구가 "git query failed"/"unable to confirm" 을 언급하지
    않고, git 이 호출되지 않았다는 것과 그 경로를 명시해야 한다."""

    def _nonexistent_policy_dir(self, base_dir):
        # base_dir 자체는 존재하지만(TemporaryDirectory), 그 하위의
        # "policy" 는 한 번도 만들어지지 않는다 — 진짜 부재.
        return os.path.join(base_dir, "policy")

    def test_dangling_symlink_is_reported_as_unresolvable_not_missing(self):
        # 링크 자체는 존재하지만(lexists) 대상이 없다 — "존재하지 않음" 이
        # 아니라 "경로 해소 불가(매달린 링크)" 로 안내해야 사용자가 링크를
        # 고치지, 없는 폴더를 새로 만들려 하지 않는다. fail-closed 유지.
        with tempfile.TemporaryDirectory() as base_dir:
            link_path = os.path.join(base_dir, "policy")
            os.symlink(os.path.join(base_dir, "gone"), link_path)
            with self.assertRaises(facts.PolicyVersionGitStateError) as ctx:
                facts.resolve_policy_version_digest_scope(link_path)
            message = str(ctx.exception)
            self.assertIn("dangling symbolic link", message)
            self.assertNotIn("does not exist", message)
            self.assertIn("git was not invoked", message)

    def test_regular_file_path_is_not_reported_as_missing(self):
        # 경로가 존재하지만 디렉터리가 아니다 — "존재하지 않음" 이 아니라
        # 판정 실패(fail-closed) 로 흘러야 한다. 부재 문구를 내면 사용자가
        # 엉뚱하게 "폴더를 만들라" 는 안내를 받는다.
        with tempfile.TemporaryDirectory() as base_dir:
            policy_file = os.path.join(base_dir, "policy")
            with open(policy_file, "w") as handle:
                handle.write("not a directory\n")
            with self.assertRaises(facts.PolicyVersionGitStateError) as ctx:
                facts.resolve_policy_version_digest_scope(policy_file)
            message = str(ctx.exception)
            self.assertNotIn("does not exist", message)
            self.assertIn("unable to confirm", message)

    def test_digest_scope_reports_missing_dir_without_mentioning_git_query(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            policy_dir = self._nonexistent_policy_dir(base_dir)
            self.assertFalse(os.path.isdir(policy_dir))
            with self.assertRaises(
                facts.PolicyVersionGitStateError
            ) as ctx:
                facts.resolve_policy_version_digest_scope(policy_dir)
            message = str(ctx.exception)
            self.assertIn(policy_dir, message)
            self.assertNotIn("git query failed", message)
            self.assertNotIn("unable to confirm", message)

    def test_absent_worktree_reports_missing_dir_without_mentioning_git_query(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            policy_dir = self._nonexistent_policy_dir(base_dir)
            self.assertFalse(os.path.isdir(policy_dir))
            with self.assertRaises(
                facts.PolicyVersionGitStateError
            ) as ctx:
                facts.resolve_policy_version_for_absent_worktree(policy_dir)
            message = str(ctx.exception)
            self.assertIn(policy_dir, message)
            self.assertNotIn("git query failed", message)
            self.assertNotIn("unable to confirm", message)

    def test_message_does_not_blame_git_and_names_the_directory(self):
        with tempfile.TemporaryDirectory() as base_dir:
            policy_dir = self._nonexistent_policy_dir(base_dir)
            with self.assertRaises(
                facts.PolicyVersionGitStateError
            ) as ctx:
                facts.resolve_policy_version_digest_scope(policy_dir)
            message = str(ctx.exception)
            self.assertIn(
                "does not exist",
                message,
                msg="문구가 '디렉터리가 존재하지 않는다'는 실제 원인을 "
                "명시해야 한다",
            )
            self.assertIn(
                "git was not invoked",
                message,
                msg="git 이 호출된 적조차 없다는 것을 명시해 git 을 "
                "디버깅하도록 오도하지 않는다",
            )


# ---------------------------------------------------------------------------
# 6b. malformed 교차 계약 m1~m3 (+ s1 clean+malformed 무복구 경계 사례).


class DigestScopeMalformedCrossStateTest(unittest.TestCase):
    def _policy_dir(self, base_dir):
        return os.path.join(base_dir, "policy")

    def _write_version(self, base_dir, text):
        _write(base_dir, "policy/_version.yaml", text)

    def _seed_malformed_head(self, base_dir):
        """malformed 선언이 이미 HEAD 에 있는 시작 상태 — spec §3.6
        m2/m3 원문의 "비게이팅 유입(merge/외부 커밋)" 시나리오를
        그대로 흉내 낸다(게이팅된 경로로는 이 상태에 도달할 수 없다는
        것이 m1 이 막는 바로 그 경로 — 여기서는 시작 상태를 직접
        만들어 이미 malformed 인 HEAD 를 다루는 나머지 계약(m2/m3/
        clean+malformed)을 시험한다)."""
        _init_git_repo(base_dir)
        self._write_version(base_dir, "version: 1\ndigest_scope: bogus\n")
        _commit_all(base_dir, "malformed head (non-gated ingestion)")

    def test_m1_staged_malformed_candidate_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(base_dir, "version: 1\n")
            _commit_all(base_dir, "seed valid version")
            self._write_version(base_dir, "version: 1\ndigest_scope: bogus\n")
            _stage_all(base_dir)
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )

    def test_m2_malformed_head_with_valid_recovery_staging_forces_strict(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_malformed_head(base_dir)
            self._write_version(base_dir, "version: 1\n")  # 유효 수정
            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_STRICT,
            )

    def test_m2_malformed_head_with_staged_deletion_forces_strict(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_malformed_head(base_dir)
            os.remove(os.path.join(base_dir, "policy", "_version.yaml"))
            _stage_all(base_dir)
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_STRICT,
            )

    def test_m3_malformed_head_with_unstaged_divergence_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_malformed_head(base_dir)
            self._write_version(base_dir, "version: 1\n")  # worktree 편집만
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )

    def test_m3_malformed_head_with_malformed_restaging_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_malformed_head(base_dir)
            self._write_version(
                base_dir, "version: 1\ndigest_scope: still-bogus\n"
            )
            _stage_all(base_dir)
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )

    def test_clean_malformed_head_without_recovery_is_fail_closed(self):
        # s1 + malformed — worktree/index/HEAD 전부 동일(malformed) 하고
        # 복구 스테이징이 전혀 진행 중이 아닌 경우.
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_malformed_head(base_dir)
            with self.assertRaises(facts.PolicyVersionGitStateError):
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                )


# ---------------------------------------------------------------------------
# 6c. 후속 git 조회(HEAD/index)의 3상태(FOUND/ABSENT/ERROR) 구분 — 후속
# 리뷰 지적 재현 + 수리 확인 (2026-08-20).
#
# 직전 수리(`DigestScopeGitExecutionFailureVsNonGitTest`, 위)는 최초
# `rev-parse --show-toplevel` 조회만 "확실히 비-git" 대 "판정 자체가
# 실패했다"로 구분했다. 그런데 `resolve_policy_version_digest_scope()`/
# `resolve_policy_version_for_absent_worktree()` 의 **후속** 조회(HEAD
# 내용 `show`, index 내용 `cat-file blob :0:`)는 여전히 공용
# `_run_git()`(부재·오류를 `None` 하나로 합침)을 그대로 썼다 — 아래 두
# 클래스가 각각 두 함수에 대해 그 결함의 재현(RED 였던 상태) + 수리
# 확인(현재 GREEN) + 회귀(진짜 ABSENT 의미론 유지)를 고정한다.


class DigestScopeGitLifecycleQueryFailureTest(unittest.TestCase):
    """`resolve_policy_version_digest_scope()` 의 후속 조회(HEAD/index) 3상태
    구분 — 리뷰어 재현: `policy_dir` 는 strict 로 clean 하게 committed 된
    실제 git 저장소(worktree == index == HEAD, 정상 경로라면 s1)다. 이
    상태에서 HEAD 조회(`git show HEAD:_version.yaml`)만 프로세스 오류로
    실패하게 주입하면, worktree/index 는 정상 조회되어 서로 일치하는데
    `head_bytes` 만 확인 실패다. 수리 전에는 이 실패를 "HEAD 에 파일
    없음"(`None`)으로 흡수해 s2(최초 staged-add) 분기로 새 곧장
    `DIGEST_SCOPE_SENSITIVE` 기본값을 반환했다 — clean committed strict
    선언이 순간적인 git 실행 실패 하나로 조용히 sensitive 로 강등되는,
    fail-closed 계약 직접 위반."""

    def _policy_dir(self, base_dir):
        return os.path.join(base_dir, "policy")

    def _write_version(self, base_dir, text):
        _write(base_dir, "policy/_version.yaml", text)

    def test_head_query_failure_on_clean_committed_strict_is_fail_closed_not_demoted(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            _commit_all(base_dir, "seed strict version")  # clean, s1
            policy_dir = self._policy_dir(base_dir)

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if (
                    len(args) >= 2
                    and args[0] == "git"
                    and args[1] == "show"
                    and any(
                        isinstance(a, str) and a.startswith("HEAD:")
                        for a in args
                    )
                ):
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(
                facts.subprocess, "run", side_effect=_flaky_run
            ):
                with self.assertRaises(
                    facts.PolicyVersionGitStateError,
                    msg="HEAD 조회 실행 실패(timeout)는 'HEAD 에 파일 "
                    "없음' 이 아니다 — clean committed strict 선언을 "
                    "신뢰해 조용히 sensitive 로 강등하면 안 되고, 상태 "
                    "판정 실패로 fail-closed 해야 한다",
                ):
                    facts.resolve_policy_version_digest_scope(policy_dir)

    def test_index_query_failure_on_clean_committed_strict_is_fail_closed(
        self,
    ):
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            _commit_all(base_dir, "seed strict version")  # clean, s1
            policy_dir = self._policy_dir(base_dir)

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if (
                    len(args) >= 2
                    and args[0] == "git"
                    and args[1] == "cat-file"
                    and "blob" in args
                ):
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(
                facts.subprocess, "run", side_effect=_flaky_run
            ):
                with self.assertRaises(
                    facts.PolicyVersionGitStateError,
                    msg="index 조회 실행 실패는 'index 에 파일 없음' 이 "
                    "아니다 — 상태 판정 실패로 fail-closed 해야 한다",
                ):
                    facts.resolve_policy_version_digest_scope(policy_dir)

    def test_confirmed_absence_in_head_still_resolves_normally_regression(
        self,
    ):
        # 회귀 대조군 — 진짜 부재(HEAD 에 경로 없음, s2 최초 staged-add)는
        # 실패 주입 없이도 여전히 정상적으로 DIGEST_SCOPE_SENSITIVE
        # 기본값으로 판정돼야 한다(3상태 구분이 진짜 ABSENT 판정 자체를
        # 막으면 안 된다).
        with tempfile.TemporaryDirectory() as base_dir:
            _init_git_repo(base_dir)
            self._write_version(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            _stage_all(base_dir)  # HEAD 부재, 순수 staged-add
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(
                    self._policy_dir(base_dir)
                ),
                policy.DIGEST_SCOPE_SENSITIVE,
            )


class AbsentWorktreeGitLifecycleQueryFailureTest(unittest.TestCase):
    """`resolve_policy_version_for_absent_worktree()` 의 세 git 조회
    (toplevel 확인·index 내용·HEAD 내용) 전부가 이전에는 공용
    `_run_git()`(부재·오류를 `None` 하나로 합침)을 그대로 썼다 — 직전
    수리 당시 "이 함수는 그대로 둔다"는 판단이 이번 리뷰 지적으로
    뒤집혔다. 이 클래스는 두 조회(HEAD/index) 실패 주입 재현 + 기존
    정상 경로(진짜 부재 → ABSENT 의미론) 회귀 유지를 함께 고정한다
    (이 함수를 직접 호출하는 단위 테스트가 이전에는 없었다 — 기존
    커버리지는 `tests/cli/test_changeset_fact_dependency_gating.py::
    PolicyVersionStagedDeletionReachesLifecycleResolutionTest` 가
    `_evaluate_event()` 관통 경로로만 간접 확인했다)."""

    def _policy_dir(self, base_dir):
        return os.path.join(base_dir, "policy")

    def _write_version(self, base_dir, text):
        _write(base_dir, "policy/_version.yaml", text)

    def _seed_staged_deletion(self, base_dir, version_text):
        _init_git_repo(base_dir)
        self._write_version(base_dir, version_text)
        _commit_all(base_dir, "seed version")
        os.remove(os.path.join(base_dir, "policy", "_version.yaml"))
        _stage_all(base_dir)

    def test_head_query_failure_during_staged_deletion_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_staged_deletion(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            policy_dir = self._policy_dir(base_dir)

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if (
                    len(args) >= 2
                    and args[0] == "git"
                    and args[1] == "show"
                    and any(
                        isinstance(a, str) and a.startswith("HEAD:")
                        for a in args
                    )
                ):
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(
                facts.subprocess, "run", side_effect=_flaky_run
            ):
                with self.assertRaises(facts.PolicyVersionGitStateError):
                    facts.resolve_policy_version_for_absent_worktree(
                        policy_dir
                    )

    def test_index_query_failure_during_staged_deletion_is_fail_closed(self):
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_staged_deletion(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            policy_dir = self._policy_dir(base_dir)

            real_run = subprocess.run

            def _flaky_run(args, **kwargs):
                if (
                    len(args) >= 2
                    and args[0] == "git"
                    and args[1] == "cat-file"
                    and "blob" in args
                ):
                    raise subprocess.TimeoutExpired(cmd=args, timeout=5)
                return real_run(args, **kwargs)

            with mock.patch.object(
                facts.subprocess, "run", side_effect=_flaky_run
            ):
                with self.assertRaises(facts.PolicyVersionGitStateError):
                    facts.resolve_policy_version_for_absent_worktree(
                        policy_dir
                    )

    def test_staged_deletion_with_valid_head_returns_head_policy_version_regression(
        self,
    ):
        # 회귀 — 실패 주입 없는 정상 경로에서는 여전히 s2(staged 삭제,
        # HEAD 기준 평가)가 성립해야 한다.
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_staged_deletion(
                base_dir, "version: 1\ndigest_scope: strict\n"
            )
            policy_dir = self._policy_dir(base_dir)
            result = facts.resolve_policy_version_for_absent_worktree(
                policy_dir
            )
            self.assertIsNotNone(result)
            self.assertEqual(
                result.digest_scope, policy.DIGEST_SCOPE_STRICT
            )

    def test_committed_deletion_is_genuine_absence_regression(self):
        # 회귀 — staged 삭제가 실제로 커밋되면(진짜 부재) None 이어야
        # 한다(3상태 구분이 진짜 ABSENT 판정 자체를 막으면 안 된다).
        with tempfile.TemporaryDirectory() as base_dir:
            self._seed_staged_deletion(base_dir, "version: 1\n")
            policy_dir = self._policy_dir(base_dir)
            _commit_all(base_dir, "commit the deletion")
            result = facts.resolve_policy_version_for_absent_worktree(
                policy_dir
            )
            self.assertIsNone(result)


# ---------------------------------------------------------------------------
# 7. 복구 커밋 동반 변경 — m2 강제 strict 상태에서 동반 staged sensitive
# 경로가 실제로 digest 계산에 포함된다 (5·6 의 조합, end-to-end).


class RecoveryCommitSiblingPathScenarioTest(unittest.TestCase):
    def _seed_malformed_head(self, base_dir):
        _init_git_repo(base_dir)
        _write(base_dir, "policy/_version.yaml", "version: 1\ndigest_scope: bogus\n")
        _commit_all(base_dir, "malformed head (non-gated ingestion)")

    def test_sibling_sensitive_path_is_included_in_strict_digest_during_recovery(
        self,
    ):
        with tempfile.TemporaryDirectory() as with_sibling_dir, tempfile.TemporaryDirectory() as without_sibling_dir:
            for base_dir in (with_sibling_dir, without_sibling_dir):
                self._seed_malformed_head(base_dir)
                _write(base_dir, "policy/_version.yaml", "version: 1\n")  # 유효 복구

            # 동반 staged 민감 경로 — with_sibling_dir 에만 존재. docs/
            # 허용목록 접두어를 갖지만 basename 이 sensitive(.env) 라
            # A 의 불변식이 없으면 조용히 면제됐을 경로다.
            _write(with_sibling_dir, "docs/.env", "SECRET=1\n")

            for base_dir in (with_sibling_dir, without_sibling_dir):
                _stage_all(base_dir)

            policy_dir_with = os.path.join(with_sibling_dir, "policy")
            policy_dir_without = os.path.join(without_sibling_dir, "policy")

            # m2 순수 복구 스테이징 — 두 저장소 모두 strict 강제.
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir_with),
                policy.DIGEST_SCOPE_STRICT,
            )
            self.assertEqual(
                facts.resolve_policy_version_digest_scope(policy_dir_without),
                policy.DIGEST_SCOPE_STRICT,
            )

            digest_with = facts.strict_security_digest(cwd=with_sibling_dir)
            digest_without = facts.strict_security_digest(cwd=without_sibling_dir)

        self.assertNotEqual(digest_with, SUBJECT_EMPTY)
        self.assertNotEqual(digest_with, SUBJECT_UNRESOLVED)
        self.assertNotEqual(digest_without, SUBJECT_EMPTY)
        self.assertNotEqual(digest_without, SUBJECT_UNRESOLVED)
        self.assertNotEqual(
            digest_with,
            digest_without,
            msg="동반 staged 민감 경로(docs/.env)가 strict digest 계산에 "
            "실제로 반영돼야 한다 — A 의 sensitive 우선 불변식이 docs/ "
            "허용목록보다 앞서 적용된 결과가 m2 복구 상태에서도 유지됨",
        )


if __name__ == "__main__":
    unittest.main()
