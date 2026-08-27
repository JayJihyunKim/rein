"""Phase 6 최종 조립 워커 — 과차단 검증 (DoD `dod-2026-08-12-v2-phase6-authority.md`).

**Phase 7 웨이브 3 ③-d (2026-08-24) 갱신**: legacy marker(`.codex-
reviewed`/`.security-reviewed`) dual-read 계층 전체가 제거됐다. 아래
시나리오 1/3 은 원래 legacy marker fixture 만으로 code_review/
security_review 를 충족/미충족시켰다 — 그 마커는 이제 판정에 전혀
참여하지 않으므로(`_write_codex_stamp`/`_write_security_stamp` 는
inert fixture 로만 남긴다), 실제 v2 evidence(ledger 발급, `_issue_
valid_code_review_evidence`/`_issue_valid_security_review_evidence`
헬퍼)로 대체했다. 이 파일이 쓰는 임시 git 저장소는 `policies/` 파일
자체가(untracked) worktree changeset 에 섞여 code_review 의 review
digest 를 항상 non-empty 실제 digest 로 만든다 — subject-empty
지름길이 없다(그래서 여기서는 실제 evidence 발급이 필수다, 다른 파일의
`_write_code_change()` 와 동일한 이유).

이 파일은 실제 `run_event()` 진입점을 실제 임시 git 저장소 + 실제 v2
evidence 픽스처로 통과시켜, "부품은 다 있지만 연결이 안 돼 있던" 상태
(`rein/cli/__init__.py`/`rein/cli/explain.py` 최종 조립 이전)에서라면
전부 잘못된 방향(과차단 또는 놓침)으로 나왔을 4개 시나리오를 고정한다:

1. 활성 작업이 있고 리뷰·보안 표식이 정상인 상태의 `git commit` → 통과.
2. 활성 작업이 있는 상태의 소스 파일 편집(Edit) → 통과.
3. 표식이 없거나 오래된 상태 → 차단(막아야 할 건 여전히 막는다).
4. 활성 작업과 무관한 파일 편집 → 통과(관련성 판정이 작동한다 —
   task.active 가 없어도 changeset.task_relevant=False 면 충족).

이 조립 이전에는:
- `policy.version` fact 가 없어 code_review/security_review 의
  evidence 발급형 evaluate() 가 항상 미충족을 반환했다(시나리오 1 이
  legacy dual read 없이는 항상 BLOCK).
- `active_task` requirement 를 요구하는 policy 를 로드해도 `task.active`
  /`changeset.task_relevant` fact 가 전혀 채워지지 않아
  `ActiveTaskRequirement.evaluate()` 가 언제나 "없음+관련성 미확보(보수
  적으로 True)" 로 미충족을 반환했다(시나리오 2·4 가 항상 BLOCK —
  관련 없는 편집조차 막혔다, v1.6.5 GSD-2 가 고친 바로 그 결함의 v2
  재발).

배포 기본 policy 세트(`policies/default/`)는 `active_task` 를 요구하는
policy 를 포함하지 않으므로(이 워커 scope 밖 — policy 세트 자체는
다른 워커 산출물), 이 파일은 그 requirement 를 실제로 exercised 하기
위한 전용 임시 policy_dir 을 구성한다.
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
from rein.capabilities.review.capability import (  # noqa: E402
    REQUIREMENT_NAME as CODE_REVIEW_NAME,
    issue_code_review_evidence,
)
from rein.capabilities.security.capability import (  # noqa: E402
    REQUIREMENT_NAME as SECURITY_REVIEW_NAME,
    issue_security_review_evidence,
)
from rein.platform.sqlite.store import LedgerVerifiedEvidenceSource  # noqa: E402
from rein.platform.storage.local import LocalStateRoot  # noqa: E402

_VERSION_YAML = 'version: "1"\n'

_COMMIT_POLICY_YAML = (
    "trigger: tool.pre\n"
    "when:\n"
    "  command.type: git.commit\n"
    "require:\n"
    "  - code_review\n"
    "  - security_review\n"
    "failure_mode: closed\n"
)

_EDIT_POLICY_YAML = (
    "trigger: tool.pre\n"
    "when:\n"
    "  tool: Edit\n"
    "require:\n"
    "  - active_task\n"
    "failure_mode: closed\n"
)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _init_git_repo(base_dir):
    """빈 git 저장소 + 초기 커밋 1개 (+ `.rein/` gitignore).

    gitignore 이유는 `tests/cli/test_run_event_fact_wiring.py` 의
    `_init_git_repo` 와 동일 — evidence/legacy marker 쓰기가
    `.rein/`/`trail/` 아래 새 파일을 남기면, gitignore 없이는 그 파일들이
    다음 changeset digest 계산에 untracked 항목으로 섞여 든다. `trail/`
    은 `rein.platform.task.facts` 의 `_ALWAYS_IRRELEVANT_PATTERNS` 로
    이미 changeset.task_relevant 판정에서 제외되지만, changeset.digest
    자체(code_review/security_review 축)는 그 필터를 타지 않으므로
    별개로 gitignore 가 필요하다.
    """
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
    _write(os.path.join(base_dir, ".gitignore"), ".rein/\ntrail/\n")
    os.makedirs(os.path.join(base_dir, "src"), exist_ok=True)
    with open(
        os.path.join(base_dir, "src", "existing.py"), "w", encoding="utf-8"
    ) as handle:
        handle.write("print('existing')\n")
    subprocess.run(["git", "add", "-A"], cwd=base_dir, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True)


def _write_policy_dir(project_root):
    policy_dir = os.path.join(project_root, "policies")
    _write(os.path.join(policy_dir, "_version.yaml"), _VERSION_YAML)
    _write(os.path.join(policy_dir, "10-commit.yaml"), _COMMIT_POLICY_YAML)
    _write(os.path.join(policy_dir, "20-edit.yaml"), _EDIT_POLICY_YAML)
    return policy_dir


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_codex_stamp(
    project_root, verdict="PASS", reviewed_at="2026-08-01T00:00:00Z", cycle="3"
):
    _write(
        os.path.join(_dod_dir(project_root), ".codex-reviewed"),
        "verdict: {}\nreviewed_at: {}\ncycle: {}\n".format(
            verdict, reviewed_at, cycle
        ),
    )


def _write_security_stamp(
    project_root, verdict="PASS", reviewed="2026-08-01T01:00:00", cycle="3"
):
    _write(
        os.path.join(_dod_dir(project_root), ".security-reviewed"),
        "verdict={}\nreviewed={}\ncycle={}\n".format(verdict, reviewed, cycle),
    )


def _write_active_dod(project_root, slug="active-work", date="2026-08-01"):
    _write(
        os.path.join(_dod_dir(project_root), "dod-{}-{}.md".format(date, slug)),
        "# DoD\n\n- date: {}\n".format(date),
    )


def _current_review_digest(project_root):
    """`run_event()` 와 동일한 계산 경로(`rein.platform.git.facts`)로
    현재 code review subject digest 를 직접 구한다 — 응답 facts 에는
    이 값이 노출되지 않는다(`rein/cli/__init__.py` `_resolve_review_
    digest` 가 `_record()` 를 호출하지 않는 의도적 비노출 — 다른 여러
    changeset 계열 resolver 와 달리). 재구현이 아니라 프로덕션이 쓰는
    바로 그 함수를 그대로 호출한다."""
    from rein.platform.git import facts as git_changeset_facts

    changeset = git_changeset_facts.worktree_changeset(cwd=project_root)
    return git_changeset_facts.review_digest(changeset, cwd=project_root)


def _current_sensitive_digest(project_root):
    """`_current_review_digest` 와 대칭 — security_review subject
    (sensitive profile 기본값)."""
    from rein.engine import tags as tag_rules
    from rein.platform.git import facts as git_changeset_facts

    changeset = git_changeset_facts.worktree_changeset(cwd=project_root)
    rules = tag_rules.load_tag_rules()
    return git_changeset_facts.sensitive_security_digest(
        changeset, cwd=project_root, tag_rules=rules
    )


def _issue_valid_code_review_evidence(project_root, digest):
    state_root = LocalStateRoot(project_root)
    evidence_source = LedgerVerifiedEvidenceSource(state_root)
    evidence = issue_code_review_evidence(
        {"verdict": "PASS", "reviewed_digest": digest},
        current_digest=digest,
        policy_version="1",
    )
    evidence_source.record_issued(CODE_REVIEW_NAME, evidence)


def _issue_valid_security_review_evidence(project_root, digest):
    state_root = LocalStateRoot(project_root)
    evidence_source = LedgerVerifiedEvidenceSource(state_root)
    evidence = issue_security_review_evidence(
        {"verdict": "PASS", "reviewed_digest": digest},
        current_sensitive_digest=digest,
        policy_version="1",
    )
    evidence_source.record_issued(SECURITY_REVIEW_NAME, evidence)


def _write_sensitive_change(project_root, content="SECRET=shh\n"):
    """`.env` — `policies/tags.yaml` 의 sensitive 분류 첫 규칙(패턴
    `.env`)에 걸리는 파일을 만들어 security_review 의 subject 가
    `SUBJECT_EMPTY`(자동 충족)로 지름길 나지 않고 실제 digest 를 갖게
    한다."""
    _write(os.path.join(project_root, ".env"), content)


def _bash_payload(command):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )


def _edit_payload(file_path):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Edit",
            "tool_input": {
                "file_path": file_path,
                "old_string": "a",
                "new_string": "b",
            },
        }
    )


class NormalCommitWithActiveTaskAndValidStampsAllowsTest(unittest.TestCase):
    """(1) 활성 작업 존재 + 리뷰·보안 표식 정상 + git commit → 통과."""

    def test_commit_allows_when_active_task_exists_and_stamps_are_valid(self):
        # ③-d 갱신 — legacy `.codex-reviewed`/`.security-reviewed` 표식은
        # 이제 판정에 참여하지 않는다(모듈 docstring 참조). 실제 v2
        # evidence 를 발급해 ALLOW 의 실원인이 v2 증거임을 검증한다.
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            _write_active_dod(project_root)
            _write_sensitive_change(project_root)
            # legacy marker 는 inert fixture 로 남긴다 — 있어도 무관함을
            # 계속 증명한다.
            _write_codex_stamp(project_root, verdict="PASS")
            _write_security_stamp(project_root, verdict="PASS")

            _issue_valid_code_review_evidence(
                project_root, _current_review_digest(project_root)
            )
            _issue_valid_security_review_evidence(
                project_root, _current_sensitive_digest(project_root)
            )

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m 'ship it'"))

        self.assertEqual(
            response["decision"],
            "ALLOW",
            msg="normal state (active task present, valid code+security "
            "review v2 evidence) must not be over-blocked: reason={!r} "
            "missing={!r}".format(
                response["reason"], response.get("missing_requirements")
            ),
        )


class ActiveTaskSourceEditAllowsTest(unittest.TestCase):
    """(2) 활성 작업이 있는 상태의 소스 파일 편집(Edit) → 통과."""

    def test_edit_allows_when_active_task_exists(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            _write_active_dod(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(
                    _edit_payload(os.path.join(project_root, "src", "existing.py"))
                )

        self.assertEqual(
            response["decision"],
            "ALLOW",
            msg="active task present must satisfy active_task regardless "
            "of edited-path relevance (v1.6.5 semantics): reason={!r} "
            "missing={!r}".format(
                response["reason"], response.get("missing_requirements")
            ),
        )
        self.assertEqual(response["facts"].get("task.active"), "dod-2026-08-01-active-work")


class MissingOrStaleStampsStillBlockTest(unittest.TestCase):
    """(3) 표식이 없거나 오래된 상태 → 차단(과차단 수리가 놓침을 만들지 않았는지)."""

    def test_commit_without_any_stamps_blocks(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            _write_active_dod(project_root)
            # 표식을 전혀 남기지 않는다.

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m x"))

        self.assertEqual(response["decision"], "BLOCK")
        self.assertIn("code_review", response["missing_requirements"])

    def test_commit_with_stale_security_evidence_blocks(self):
        """보안 축 evidence 가 현재 subject 와 어긋난(stale) 상태 —
        code_review 는 유효한데 security_review 만 미충족이어야 한다
        (두 축의 독립성 확인).

        **③-d 갱신, 구 이름 `..._with_stale_security_stamp_blocks`** —
        v1 M2(`.security-reviewed` 가 `.codex-reviewed` 보다 오래되면
        FAIL)는 legacy marker 교차비교 메커니즘 자체와 함께 제거됐다
        (`.codex-reviewed`/`.security-reviewed` 는 이제 읽히지 않는다,
        모듈 docstring 참조). "staleness" 의 종국 의미론은 이제 v2
        evidence 자신의 subject 불일치다 — security evidence 의 subject
        가 현재 sensitive digest 와 다르면(예: 발급 이후 재편집) 무효다.
        이 테스트는 code_review 에는 유효한 evidence 를, security_review
        에는 무관한(불일치) subject 의 evidence 를 발급해 그 독립성을
        고정한다.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            _write_active_dod(project_root)
            _write_sensitive_change(project_root)

            _issue_valid_code_review_evidence(
                project_root, _current_review_digest(project_root)
            )
            # security_review 는 무관한 subject 로 발급 — 현재 sensitive
            # digest 와 어긋난(stale) 상태를 재현한다.
            _issue_valid_security_review_evidence(project_root, "sha256:" + "a" * 64)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m x"))

        self.assertEqual(response["decision"], "BLOCK")
        self.assertEqual(response["missing_requirements"], ["security_review"])

    def test_edit_without_active_task_and_relevant_path_blocks(self):
        """활성 작업이 전혀 없고, 편집 대상이 소스(관련) 경로면 여전히 차단."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            # 활성 dod 파일을 만들지 않는다 — task.active 는 None.

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(
                    _edit_payload(os.path.join(project_root, "src", "existing.py"))
                )

        self.assertEqual(response["decision"], "BLOCK")
        self.assertIn("active_task", response["missing_requirements"])
        self.assertIsNone(response["facts"].get("task.active"))
        self.assertTrue(response["facts"].get("changeset.task_relevant"))


class UnrelatedEditWithoutActiveTaskAllowsTest(unittest.TestCase):
    """(4) 활성 작업과 무관한 파일 편집 → 통과 (관련성 판정이 작동)."""

    def test_edit_of_irrelevant_path_allows_without_active_task(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_policy_dir(project_root)
            # 활성 dod 파일을 만들지 않는다 — task.active 는 None. 편집
            # 대상은 `rein.platform.task.facts._NONSOURCE_EXT_PATTERNS`
            # (`*.md`)에 걸리는 non-source 문서 — changeset.task_relevant
            # 는 False 여야 한다.
            doc_path = os.path.join(project_root, "NOTES.md")
            with open(doc_path, "w", encoding="utf-8") as handle:
                handle.write("scratch notes\n")

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_edit_payload(doc_path))

        self.assertEqual(
            response["decision"],
            "ALLOW",
            msg="editing a path irrelevant to task governance must not be "
            "blocked even with no active task — relevance judgment must "
            "actually run: reason={!r} missing={!r} facts={!r}".format(
                response["reason"],
                response.get("missing_requirements"),
                response["facts"],
            ),
        )
        self.assertIsNone(response["facts"].get("task.active"))
        self.assertFalse(response["facts"].get("changeset.task_relevant"))


if __name__ == "__main__":
    unittest.main()
