"""Phase 6 Task 6.1 수리 워커 B — Medium 5 재현 + 회귀 방지 (spec §7).

독립 리뷰어 지적(부모 판정 타당함): `cli/__init__.py::run_event()` 가
`_build_registry()` 로 5 capability 를 실제로 등록해도, `facts` 는
여전히 `tool`/`git.branch` 2개뿐이었다 — 등록된 구현체는 판단 재료를
전혀 얻지 못해 항상 보수적으로 미충족(False)을 반환한다. 이 파일의
첫 두 테스트는 **수리 전에는 실패했어야 할** 재현 테스트다:

1. `command.type` fact 가 없으면 `policies/default/commit.yaml` 의
   `when: command.type: git.commit` 이 단 한 번도 매칭되지 않는다 —
   `git commit` 이벤트조차 "no policy matched event" 로 항상 ALLOW.
2. `changeset.digest`/`changeset.sensitive_digest` 가 없으면
   code_review/security_review/tests_passed capability 의 `evaluate()`
   는 fact 확인 단계에서 즉시 미충족을 반환한다(다른 모든 재료가
   맞아도).

나머지는 수리 후 회귀 방지 테스트다 — 특히 "정상 상태(활성 리뷰 표식
정상)의 이벤트가 ALLOW 로 나오는가"(이번 수리의 핵심 증거).

## evidence_source 배선 (Phase 6 최종 조립 워커 추가)

이 파일은 원래 "`evidence_source` 를 의도적으로 미배선한 판단이 왜
안전한지" 를 `EvidenceSourceStaysUnwiredSafetyTest` 로 증명했다 —
그 시점엔 `policy.version` fact 의 출처가 없어서, evidence_source 를
실 ledger 로 연결하면 **어떤** evidence 레코드든 존재하는 순간 v2 가
무조건 False 를 내(버전 축을 검증할 수 없으므로) legacy PASS 를
부당하게 뒤집는 landmine 이 있었다(`rein/cli/__init__.py` 모듈
docstring 의 옛 "evidence_source 를 의도적으로 배선하지 않는다" 절).

`policies/default/_version.yaml` 이 생기고 `_build_facts()` 가
`policy.version` 을 실제로 채우게 된 뒤에는 그 전제가 바뀌었다 —
`run_event()` 는 이제 `evidence_source` 를 실 ledger 로 연결한다
(`_build_evidence_source()`). 그 결과 아래 클래스는 이름과 내용을
바꿨다: 이제는 "evidence_source 가 안전하게 연결됐다" 를 증명한다 —
유효한(현재 subject digest 와 일치하는) v2 evidence 는 단독으로
ALLOW 할 수 있고, 무효한(stale, subject 불일치) v2 evidence 는
**legacy marker 유무와 무관하게** BLOCK 한다.

**2026-08-20(spec §3.6 판정 상태표, ③-a) → 2026-08-24(③-d) 개정 이력**
— ③-a 는 code_review/security_review 축을 "증거 레코드가 존재하면
v2 가 이긴다"에서 "현재 subject 에 결합된 **유효** 증거가 있을 때만
v2 가 이긴다"로 좁히고, 무효 판정은 legacy PASS 로 대체됐다(전환기
안전판 — 과거 사이클의 무효 증거 1건이 legacy 신선 PASS 를 영구
차단하던 실측 함정을 닫기 위함). **③-d 로 그 legacy 대체 자체가
완전히 제거됐다** — 이제 "무효 v2 증거"의 최종 결말은 legacy 로의
위임이 아니라 **v2 자신의 False 가 그대로 최종 판정**이다(marker
내용과 무관). 아래 두 테스트가 이 최종 상태를 고정한다 — 각각
"landmine 이 닫혀 있다"는 취지는 유지하되, 닫히는 방식이 "legacy 로
안전하게 위임"에서 "v2 의 보수적 False 가 그대로 안전하게 최종값"으로
바뀌었다.
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
    FACT_CHANGESET_DIGEST,
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_CHANGESET_SENSITIVE_DIGEST,
    FACT_COMMAND_TYPE,
    FACT_TASK_EXISTS,
    _build_fact_resolvers,
    _build_facts,
    _build_registry,
    run_event,
)
from rein.engine import runtime  # noqa: E402
from rein.kernel.changeset import SUBJECT_EMPTY  # noqa: E402
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.capabilities.review.capability import (  # noqa: E402
    REQUIREMENT_NAME as CODE_REVIEW_NAME,
    issue_code_review_evidence,
)
from rein.platform.sqlite.store import LedgerVerifiedEvidenceSource  # noqa: E402
from rein.platform.storage.local import LocalStateRoot  # noqa: E402

_DEFAULT_POLICY_DIR = os.path.join(_PLUGIN_ROOT, "policies", "default")


class _StaticEvidenceSource:
    def __init__(self, records_by_requirement):
        self._records = records_by_requirement

    def find(self, requirement_name):
        return self._records.get(requirement_name, ())


def _init_git_repo(base_dir):
    """빈 git 저장소 + 초기 커밋 1개 — WORKTREE changeset 계산이 성립하려면
    유효한 git 저장소가 있어야 한다(`worktree_changeset` 계약).

    `.gitignore` 로 `.rein/` 를 커밋해 둔다 — 실제 rein-bootstrapped
    프로젝트는 처음부터 이 패턴을 갖는다(`platform/storage/local.py`
    모듈 docstring "Runtime State 는 Git 으로 동기화하지 않는다" 절).
    이게 없으면 evidence 발급이 `.rein/state/{ledger,evidence}.jsonl`
    을 쓰는 순간 그 새 파일들이 `git status` 의 untracked 항목으로
    잡혀, evidence 발급 **전/후**에 계산한 WORKTREE changeset digest 가
    서로 달라진다 — evidence 발급이라는 부수효과가 스스로 자신이
    결속한 digest 를 무효화하는 결함처럼 보이는 상황(실제로는 fixture
    의 gitignore 결손)을 만든다.
    """
    subprocess.run(["git", "init", "-q"], cwd=base_dir, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"], cwd=base_dir, check=True
    )
    subprocess.run(["git", "config", "user.name", "t"], cwd=base_dir, check=True)
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
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=base_dir, check=True)


def _bash_payload(command):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_active_dod(project_root, slug="fixture-task", date="2026-08-19"):
    # Phase 7 결정 1(2026-08-19 사용자 결정) — 기본 commit.yaml 의
    # `when:` 에 `task.exists: "true"` 가 추가돼, 활성 작업(v1 글롭 미러
    # shim — `trail/dod/dod-*.md` 파일 존재만, 완료 여부 무관)이 없으면 commit.yaml
    # 자체가 매칭되지 않는다(정책 미매칭 → ALLOW, `rein.platform.task.
    # facts.task_exists()` 가 값을 낸다). 이 파일의 테스트들은 원래
    # "commit.yaml 이 실제로 매칭돼 code_review 를 요구한다"는 전제
    # 위에 서 있으므로, 활성 작업 픽스처를 심어 그 전제를 복원한다
    # (원 단언은 변경하지 않는다 — `tests/contract/
    # test_commit_policy_task_conditioning.py` 의 동일 패턴 재사용).
    dod_dir = _dod_dir(project_root)
    os.makedirs(dod_dir, exist_ok=True)
    with open(
        os.path.join(dod_dir, "dod-{}-{}.md".format(date, slug)),
        "w",
        encoding="utf-8",
    ) as handle:
        handle.write("# DoD\n\n- date: {}\n".format(date))


def _write_code_change(project_root, content="print('changed')\n"):
    """`a.py`(`_init_git_repo` 가 커밋해 둔 파일)에 미커밋 편집을 남긴다.

    **2026-08-20 개정(spec §3.6 "리뷰 digest 범위" 절) 대응** —
    `_init_git_repo` 직후에는 worktree 가 HEAD 와 완전히 clean 하다.
    `_write_active_dod()` 만 추가하면 WORKTREE changeset 에는 `trail/
    dod/dod-*.md` 하나만 남는데, 그 경로는 리뷰 digest 의 검토 면제
    허용목록(`trail/**`)에 속해 `changeset.review_digest` 가
    `SUBJECT_EMPTY` 로 계산된다 — code_review evidence 발급 자체가
    거부되거나(발급 테스트), "subject 불일치" 를 검증하려던 테스트가
    실제로는 "subject 비어있음" 경로를 타 버린다(의도한 축과 다른 축을
    검증하게 되는 조용한 오류). 이 헬퍼로 허용목록 밖의 실질 코드 변경을
    worktree 에 남겨 리뷰 digest 가 항상 non-empty 실제 digest 이게
    한다."""
    with open(
        os.path.join(project_root, "a.py"), "w", encoding="utf-8"
    ) as handle:
        handle.write(content)


def _write_codex_stamp(project_root, verdict="PASS", reviewed_at=None, cycle="1"):
    dod_dir = _dod_dir(project_root)
    os.makedirs(dod_dir, exist_ok=True)
    if reviewed_at is None:
        reviewed_at = "2026-08-12T00:00:00Z"
    with open(
        os.path.join(dod_dir, ".codex-reviewed"), "w", encoding="utf-8"
    ) as handle:
        handle.write(
            "verdict: {}\nreviewed_at: {}\ncycle: {}\n".format(
                verdict, reviewed_at, cycle
            )
        )


class CommandTypeFactWiringTest(unittest.TestCase):
    """(1) 재현 + 수리 고정 — command.type fact 없이는 어떤 git policy 도 매칭되지 않았다."""

    def test_git_commit_event_now_matches_default_commit_policy(self):
        # ③-d 갱신 — 이전에는 `_write_active_dod()` 하나만으로도(리뷰
        # digest 허용목록 밖 변경이 전혀 없는 상태) BLOCK 을 기대했다.
        # legacy 대체가 제거된 지금은 `changeset.review_digest` 가
        # 허용목록 밖 실질 변경이 하나도 없으면 `SUBJECT_EMPTY` 로
        # 계산되고, `CodeReviewRequirement.evaluate()` 는 그 상태를
        # 종국 상태표대로 **충족**(True)으로 곧장 판정한다(legacy
        # marker 유무와 무관 — spec §3.6 "subject-empty → 충족" 행,
        # `tests/migration/test_authority_valid_evidence_state_table.py
        # ::SubjectEmptyStateTableTest` 가 같은 계약을 authority 계층
        # 단위로 고정한다). 이 테스트가 검증하려던 "commit.yaml 이
        # 실제로 매칭돼 code_review 미충족으로 BLOCK" 이라는 원래 취지를
        # 보존하려면 검토 대상이 될 실질 코드 변경이 있어야 한다 —
        # `_write_code_change()` 로 허용목록 밖 변경을 추가한다.
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_active_dod(project_root)
            _write_code_change(project_root)
            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m 'work'"))

        # 수리 전에는 "no policy matched event" 로 항상 ALLOW 였다 —
        # 이제는 실제로 commit.yaml 이 매칭되어 code_review 미충족으로
        # BLOCK 된다(legacy marker 없음, 정상 평가 BLOCK).
        self.assertEqual(response["decision"], "BLOCK")
        self.assertEqual(response["missing_requirements"], [CODE_REVIEW_NAME])
        self.assertEqual(response["facts"][FACT_COMMAND_TYPE], "git.commit")

    def test_non_bash_tool_never_gets_command_type_fact(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            payload = json.dumps(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Read",
                    "tool_input": {"file_path": "a.py"},
                }
            )
            env = {ENV_PROJECT_ROOT: project_root}
            with mock.patch.dict(os.environ, env):
                response = run_event(payload)
        self.assertNotIn(FACT_COMMAND_TYPE, response["facts"])

    def test_non_git_bash_command_classified_but_no_policy_effect(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("ls -la"))
        self.assertEqual(response["facts"][FACT_COMMAND_TYPE], "ls")
        self.assertEqual(response["decision"], "ALLOW")
        self.assertEqual(response["reason"], "no policy matched event")


class ChangesetDigestGatingTest(unittest.TestCase):
    """changeset.digest 가 실제로 code_review 판정 재료가 되는가(Medium 5 원래 취지).

    Phase 6 3회차 재리뷰 High 1 이후 `_build_facts()` 는 changeset 해시
    3종(`changeset.digest`/`changeset.sensitive_digest`/`changeset.tag`)
    을 전혀 값으로 계산하지 않는다(`rein/cli/__init__.py` 모듈 docstring
    "비용 게이팅" 절) — 실제 계산은 `_build_fact_resolvers()` 가 등록한
    lazy resolver 가 `EvaluationContext.fact()` 조회 시점에만 수행한다.
    이 클래스는 그 lazy 경로를 통해서도 "digest 가 실제로 계산되면
    code_review 판정 재료가 된다"는 원래 취지(Medium 5)와 "sensitive
    경로만 sensitive_digest 에 반영된다"는 계약이 여전히 성립함을
    `_build_fact_resolvers()` + `EvaluationContext` 로 직접 고정한다.
    "언제 계산이 생략/수행되는가"(비용 게이팅 자체, 이전에는
    `_build_facts()`의 declared 근사가 담당했으나 이제는 실제 policy
    매칭이 담당한다)의 상세 재현/회귀 테스트는 `tests/cli/
    test_changeset_fact_dependency_gating.py` 참조.
    """

    def test_digest_resolver_produces_sha256_digest_for_real_changeset(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            resolvers = _build_fact_resolvers(event, project_root)
            digest = EvaluationContext(fact_resolvers=resolvers).fact(
                FACT_CHANGESET_DIGEST
            )
        self.assertIsNotNone(digest)
        self.assertTrue(digest.startswith("sha256:"))

    def test_no_fact_resolvers_registered_without_project_root(self):
        """`project_root` 가 없으면 resolver 자체를 등록하지 않는다 —
        `EvaluationContext(fact_resolvers=None)` 과 동일한 효과."""
        event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
        self.assertIsNone(_build_fact_resolvers(event, None))

    def test_sensitive_digest_only_covers_sensitive_tagged_paths(self):
        """`.env` 류만 sensitive_digest 에 반영되고, 나머지 code 변경은 무시된다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}

            # sensitive 파일이 없는 상태 — 닫힌 값 계약(spec §3.6, 2026-08-19)에
            # 따라 "계산됐고 0건" 은 부재(None)가 아니라 SUBJECT_EMPTY(충족 방향).
            resolvers_before = _build_fact_resolvers(event, project_root)
            digest_before = EvaluationContext(
                fact_resolvers=resolvers_before
            ).fact(FACT_CHANGESET_SENSITIVE_DIGEST)
            self.assertEqual(digest_before, SUBJECT_EMPTY)

            # sensitive 파일 + 비sensitive(code) 파일을 함께 추가한다 —
            # 전체 changeset 과 sensitive-only changeset 이 실제로
            # 달라야(경로 집합이 다름) 이 테스트가 "sensitive 만 걸러진다"
            # 를 의미 있게 검증한다(sensitive 파일 하나만 있으면 우연히
            # 두 digest 가 같아져 이 축을 검증하지 못한다).
            with open(
                os.path.join(project_root, ".env"), "w", encoding="utf-8"
            ) as handle:
                handle.write("SECRET=1\n")
            with open(
                os.path.join(project_root, "b.py"), "w", encoding="utf-8"
            ) as handle:
                handle.write("print('unrelated code change')\n")

            # 새 resolver 그룹 — 새 EvaluationContext(=새 cycle)이므로
            # 이전 cycle 의 cache 와 섞이지 않는다.
            resolvers_after = _build_fact_resolvers(event, project_root)
            context_after = EvaluationContext(fact_resolvers=resolvers_after)
            sensitive_digest_after = context_after.fact(
                FACT_CHANGESET_SENSITIVE_DIGEST
            )
            full_digest_after = context_after.fact(FACT_CHANGESET_DIGEST)
            self.assertIsNotNone(sensitive_digest_after)
            self.assertTrue(sensitive_digest_after.startswith("sha256:"))
            # 전체 digest(.env + b.py) 와 sensitive-only digest(.env 만)
            # 는 서로 다른 값이어야 한다 — code 변경이 sensitive digest
            # 에 새어들면 이 단언이 잡는다.
            self.assertNotEqual(
                full_digest_after,
                sensitive_digest_after,
            )


class NormalStateAllowsCommitOverBlockingRegressionTest(unittest.TestCase):
    """(3) 이번 수리의 핵심 증거 — 정상 상태(실제 v2 리뷰 증거)의 이벤트가
    ALLOW 로 나오는가.

    실제 `run_event()` 를 REIN_PROJECT_ROOT/REIN_POLICY_DIR 을 배선한
    상태로 정확히 통과시킨다(hook 이 부르는 것과 동일한 진입점).
    **③-d 갱신** — 이전에는 legacy `.codex-reviewed` PASS 표식만으로
    dual-read 가 ALLOW 로 이어졌다(evidence_source 미배선). legacy
    대체가 제거된 지금은 실제 v2 evidence(ledger 발급)가 있어야
    ALLOW 된다 — 이 클래스는 그 전환을 반영해 "실제 v2 증거가 legacy
    marker 유무와 무관하게 ALLOW 를 낸다"/"v2 증거도 legacy marker 도
    없으면 여전히 BLOCK"의 대비를 고정한다.
    """

    def test_normal_commit_with_valid_v2_review_evidence_allows(self):
        # ③-d 갱신 — 이전 이름은
        # test_normal_commit_with_valid_legacy_review_stamp_allows 였고
        # legacy PASS 표식 단독으로 ALLOW 를 기대했다. 지금은 실제 v2
        # evidence(ledger 발급)가 있어야 하고, legacy marker 는 부재
        # 여도(또는 있어도) 무관함을 함께 증명한다.
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            # 활성 작업 픽스처 — commit.yaml 이 실제로 매칭된 상태에서
            # v2 evidence 가 ALLOW 의 실원인임을 검증한다(픽스처가 없으면
            # "정책 미매칭 ALLOW" 로 공허하게 통과한다, Medium 2 리뷰).
            _write_active_dod(project_root)
            _write_code_change(project_root)

            # review digest 를 `run_event()` 와 완전히 동일한 계산
            # 경로(`rein.platform.git.facts`)로 직접 구한다 — 응답 facts
            # 에는 이 값이 노출되지 않는다(`_resolve_review_digest` 는
            # `_record()` 를 호출하지 않는 유일한 changeset 계열
            # resolver — 의도적 응답 비노출, `rein/cli/__init__.py`
            # `_build_fact_resolvers` 참조). 재구현이 아니라 프로덕션이
            # 쓰는 바로 그 함수를 그대로 호출한다.
            from rein.platform.git import facts as git_changeset_facts

            changeset = git_changeset_facts.worktree_changeset(cwd=project_root)
            current_digest = git_changeset_facts.review_digest(
                changeset, cwd=project_root
            )
            self.assertNotIn(
                current_digest,
                (None, SUBJECT_EMPTY),
                msg="fixture must produce a real, non-empty review digest "
                "for this test to exercise the subject-matching axis",
            )

            state_root = LocalStateRoot(project_root)
            evidence_source = LedgerVerifiedEvidenceSource(state_root)
            evidence = issue_code_review_evidence(
                {"verdict": "PASS", "reviewed_digest": current_digest},
                current_digest=current_digest,
                policy_version="1",
            )
            evidence_source.record_issued(CODE_REVIEW_NAME, evidence)

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            # 실제 run_event() 가 위에서 발급한 ledger evidence 를
            # 스스로 연결해(`_build_evidence_source()`) 읽는지 확인한다.
            with mock.patch.dict(os.environ, env):
                decision = run_event(_bash_payload("git commit -m 'ship it'"))

        self.assertEqual(
            decision["decision"],
            "ALLOW",
            msg="normal state (valid v2 code review evidence) must not be "
            "over-blocked by the v2 wiring — decision={!r} reason={!r}".format(
                decision["decision"], decision["reason"]
            ),
        )

    def test_same_commit_without_review_evidence_still_blocks(self):
        """대조군 — v2 증거도 legacy marker 도 없으면 여전히 BLOCK 이어야
        위 ALLOW 테스트가 의미 있다. **③-d 갱신** — 이전 이름은
        test_same_commit_without_review_stamp_still_blocks 였다(legacy
        marker 부재를 대조했다); 지금은 legacy marker 자체가 판정에
        참여하지 않으므로 v2 증거 부재를 대조한다."""
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            _write_active_dod(project_root)
            _write_code_change(project_root)
            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m 'ship it'"))
        self.assertEqual(response["decision"], "BLOCK")
        self.assertIn(CODE_REVIEW_NAME, response["missing_requirements"])


class EvidenceSourceWiringSafetyTest(unittest.TestCase):
    """(4) evidence_source 배선의 안전성 — landmine 조건과 정상 조건을 대비한다.

    첫 테스트는 옛 landmine(policy.version 없이 evidence_source 만
    배선하면 무슨 일이 일어나는지)을 다뤘었다. **2026-08-20(③-a) →
    2026-08-24(③-d) 개정 이력**: ③-a 는 이 landmine 을 "legacy 로
    안전하게 위임"해서 닫았다. ③-d 는 legacy 위임 자체를 없앴으므로,
    이 landmine 은 이제 다른 방식으로 닫혀 있어야 한다 — "판정 재료가
    불완전하면 v2 는 보수적으로 False 를 계산하고, 그 False 가 (legacy
    안전판 없이) 그대로 최종 BLOCK 이 된다"가 fail-closed 방향의 안전한
    닫힘이다(무모한 ALLOW 로 새지 않는다). 아래 두 테스트가 이 최종
    상태를 고정한다.
    """

    def test_evidence_source_without_policy_version_now_safely_blocks(self):
        """**2026-08-20(③-a) → 2026-08-24(③-d) 갱신, 구 이름
        `..._now_safely_defers_to_legacy_pass`** — 구 landmine(policy.
        version 결손이 v2 를 '모름'이 아니라 '거짓으로 앎'으로 만들어
        legacy PASS 로의 폴백을 막던 버그)은 ③-a 가 "legacy 로 위임"
        해서 닫았다. legacy 위임 자체가 ③-d 로 제거된 지금은, 이
        시나리오(policy.version 결손 → `CodeReviewRequirement.
        evaluate()` 가 `current_digest`/`current_version` 어느 쪽도
        확보 못 해 곧장 False)가 legacy 로 새지 않고 **그대로 BLOCK**
        으로 끝난다는 것이 새로운 "안전하게 닫힘"이다 — stray evidence
        레코드가 하나 있다는 사실만으로 조용히 ALLOW 로 새지 않는다.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)

            state_root = LocalStateRoot(project_root)
            evidence_source = LedgerVerifiedEvidenceSource(state_root)
            # ledger 에 code_review evidence 를 하나 발급한다 — digest 는
            # 지금 이 changeset 과 무관해도 된다("레코드가 존재한다는
            # 사실 자체가 evidence_present 를 True 로 바꾼다"는 축은
            # ③-a 이후 게이팅에 쓰이지 않는다).
            stray_evidence = issue_code_review_evidence(
                {"verdict": "PASS", "reviewed_digest": "unrelated-digest"},
                current_digest="unrelated-digest",
                policy_version="v1",
            )
            evidence_source.record_issued(CODE_REVIEW_NAME, stray_evidence)

            # 의도적으로 policy_dir 을 넘기지 않는다(2-인자 호출) —
            # policy.version fact 가 결손인 상태를 그대로 재현한다.
            # `_build_facts()` 의 2-인자 경로는 (문서화된 대로) task.exists
            # 를 포함한 lazy fact 8종을 전혀 계산하지 않고, 아래
            # `runtime.evaluate()` 호출도 `fact_resolvers` 를 넘기지
            # 않으므로 commit.yaml 의 `when: task.exists: "true"` 조건화
            # (Phase 7 결정 1)는 이 경로에서 trail/dod 픽스처로 복원할
            # 수 없다 — task.exists 는 facts dict 에 직접 주입해
            # commit.yaml 이 매칭되게 한다.
            event = {"tool": "Bash", "payload": {"command": "git commit -m x"}}
            facts = _build_facts(event, project_root)
            facts[FACT_TASK_EXISTS] = "true"
            registry = _build_registry()
            policies = runtime.load_policies(_DEFAULT_POLICY_DIR)

            hypothetical_decision = runtime.evaluate(
                "tool.pre",
                facts,
                policies,
                evidence_source=evidence_source,
                registry=registry,
                project_root=project_root,
            )

        self.assertEqual(
            hypothetical_decision["decision"],
            "BLOCK",
            msg="the landmine is closed the ③-d way: an incomplete v2 "
            "judgment (no policy.version, no resolvable review-digest "
            "subject) blocks outright — there is no legacy safety net "
            "left to defer to, and a stray unrelated evidence record "
            "must not masquerade as satisfaction",
        )
        self.assertIn(CODE_REVIEW_NAME, hypothetical_decision["missing_requirements"])

    def test_actual_run_event_with_stray_stale_evidence_blocks(self):
        """**2026-08-20(③-a) → 2026-08-24(③-d) 갱신, 구 이름
        `..._defers_to_legacy_pass`(그 이전엔 `..._correctly_blocks`)**
        — policy.version 이 채워진 상태에서 subject 가 어긋난(stale)
        v2 evidence 가 있으면, ③-a 는 신선한 legacy PASS 가 최종
        판정을 내도록(ALLOW) 개정했었다(전환기 안전판). legacy 위임
        자체가 ③-d 로 제거된 지금은, marker 가 신선 PASS 내용이어도
        읽히지 않으므로 v2 의 False(stale evidence 는 무효)가 그대로
        최종 BLOCK 이다 — 이름도 그 최종 결말("`_blocks`")로 되돌린다.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            # legacy marker 는 PASS 내용이지만 ③-d 이후로는 읽히지 않는다
            # — inert fixture, "여전히 무관함"을 이 실제 run_event() 경로
            # 에서도 증명하기 위해 남김.
            _write_codex_stamp(project_root, verdict="PASS")
            _write_active_dod(project_root)
            # 허용목록 밖 실질 코드 변경 — review digest 가 SUBJECT_EMPTY
            # 가 아니라 실제 subject 를 내게 한다(위 헬퍼 docstring 참조,
            # "subject 불일치" 축을 검증하려면 subject 자체가 있어야 한다).
            _write_code_change(project_root)

            state_root = LocalStateRoot(project_root)
            evidence_source = LedgerVerifiedEvidenceSource(state_root)
            stray_evidence = issue_code_review_evidence(
                {"verdict": "PASS", "reviewed_digest": "unrelated-digest"},
                current_digest="unrelated-digest",
                policy_version="1",
            )
            evidence_source.record_issued(CODE_REVIEW_NAME, stray_evidence)

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                response = run_event(_bash_payload("git commit -m x"))

        self.assertEqual(
            response["decision"],
            "BLOCK",
            msg="stale (subject-mismatched) v2 evidence must not be "
            "rescued by a legacy PASS marker any more (③-d — legacy "
            "dual-read removed) — v2's own False stands as the final "
            "judgement",
        )
        self.assertIn(CODE_REVIEW_NAME, response["missing_requirements"])

    def test_actual_run_event_with_valid_matching_evidence_allows_without_legacy(
        self,
    ):
        """유효한(현재 digest 일치) v2 evidence 만으로 legacy marker 없이 ALLOW.

        end-to-end 로 evidence_source 배선이 실제로 동작함을 증명한다 —
        legacy `.codex-reviewed` 표식을 아예 만들지 않는다.
        """
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            # 활성 작업 픽스처 — commit.yaml 이 실제로 매칭된 상태에서
            # v2 evidence 가 (legacy marker 없이) ALLOW 의 실원인임을
            # 검증한다(픽스처가 없으면 "정책 미매칭 ALLOW" 로 공허하게
            # 통과한다, Medium 2 리뷰).
            _write_active_dod(project_root)
            # 허용목록 밖 실질 코드 변경 — review digest 가 SUBJECT_EMPTY
            # 로 계산되면 evidence 발급 자체가 거부된다(§3.6 리뷰 digest
            # 범위 절 closed-value 계약) — 이 테스트가 검증하려는 "유효한
            # 실제 digest 매칭 evidence" 축을 살리려면 subject 자체가
            # 있어야 한다.
            _write_code_change(project_root)

            env = {
                ENV_POLICY_DIR: _DEFAULT_POLICY_DIR,
                ENV_PROJECT_ROOT: project_root,
            }
            # 실제 WORKTREE changeset digest 를 run_event() 와 동일한
            # 경로로 계산해, 그 digest 로 발급된 evidence 를 ledger 에
            # 미리 심어 둔다.
            with mock.patch.dict(os.environ, env):
                event = {
                    "tool": "Bash",
                    "payload": {"command": "git commit -m x"},
                }
                facts = _build_facts(
                    event,
                    project_root,
                    policies=runtime.load_policies(_DEFAULT_POLICY_DIR),
                    policy_dir=_DEFAULT_POLICY_DIR,
                )
                # changeset.review_digest 는 이제 `_build_facts()` 가 값으로
                # 채우지 않는다(Phase 6 3회차 재리뷰 High 1) — `run_event()`
                # 가 실제로 쓰는 것과 동일한 lazy resolver 경로
                # (`_build_fact_resolvers()`)로 조회해야 같은 값을 얻는다.
                # **2026-08-20 개정**: code_review 의 subject 는 이제
                # `changeset.digest`(WORKTREE 전체)가 아니라 `changeset.
                # review_digest`(검토 면제 허용목록 제외) — evaluate() 가
                # 실제로 비교하는 subject 와 일치시켜야 evidence 가 유효
                # 하다(spec §3.6 "리뷰 digest 범위" 절).
                resolvers = _build_fact_resolvers(event, project_root)
                current_digest = EvaluationContext(
                    fact_resolvers=resolvers
                ).fact(FACT_CHANGESET_REVIEW_DIGEST)

                state_root = LocalStateRoot(project_root)
                evidence_source = LedgerVerifiedEvidenceSource(state_root)
                valid_evidence = issue_code_review_evidence(
                    {"verdict": "PASS", "reviewed_digest": current_digest},
                    current_digest=current_digest,
                    policy_version="1",
                )
                evidence_source.record_issued(CODE_REVIEW_NAME, valid_evidence)

                response = run_event(_bash_payload("git commit -m x"))

        self.assertEqual(
            response["decision"],
            "ALLOW",
            msg="a valid, digest-matching v2 evidence record alone (no "
            "legacy marker at all) must satisfy code_review — proves "
            "evidence_source is genuinely wired end-to-end",
        )


if __name__ == "__main__":
    unittest.main()
