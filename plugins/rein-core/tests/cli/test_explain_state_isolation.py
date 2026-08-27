"""Phase 6 Task 6.1 수리 워커 F — Medium E 재현 + 회귀 방지 (spec §3.1, §7).

독립 리뷰어 지적(부모 판정 타당함): `run_explain()` 이 `rein.cli.
_build_facts()` 공유 조립 경로를 타면서, `user_approval` 이 declared 인
프로젝트에서는 승인 소비 DB 파일(`.rein/state/approval-consumption.
sqlite3`)과 스키마를 **생성**한다 — 실행 전후로 그 파일의 존재 여부가
바뀐다. `explain` 은 진단 도구다(`rein/cli/doctor.py` 의 "진단은 상태를
바꾸지 않는다" 계약과 동일 정신) — 소비하지는 않지만(그건 이미 이전
라운드에서 고쳐졌다, `explain.py` 모듈 docstring "진단은 상태를 바꾸지
않는다" 절), 파일/스키마를 새로 만드는 것 자체가 이미 상태 변화다.

이 파일의 첫 테스트는 **수리 전에는 실패했어야 할** 재현 테스트다.
두 번째 테스트는 "읽기 전용으로 만드는 것이 판정 결과를 바꾸지 않는가"
(수리가 새 결함을 만들지 않았는지)를 고정하는 parity 회귀 방지 테스트다
— `run_explain()` 이 아직 DB 파일이 없는 fresh 프로젝트에서 내린 판정이,
그 직후 같은 이벤트를 `run_event()`(실제로 DB 를 만드는 진짜 평가
경로)로 평가한 결과와 정확히 같아야 한다(파일이 없다 = 아무 것도 소비된
적이 없다는 사실 자체는 파일 생성 여부와 무관하게 참이므로, 두 결과가
달라지면 그건 이 수리가 새로 만든 결함이다).

## Phase 6 3회차 재리뷰 Medium C — 두 경계 추가

위 두 테스트는 "파일 자체가 없는 상태"만 검사했다 — 독립 리뷰어가 3회차
에서 그 커버리지 밖의 두 경계를 실제로 재현했다:

1. **이미 존재하는 빈 정규 파일** — `_open_approval_consumption_store`
   가 예전에는 `os.path.exists()` 만 보고 이미 있는 파일은 무조건 쓰기
   가능한 실제 store 로 열었다(`ApprovalConsumptionStore.__init__` 이
   무조건 스키마를 보장). 0바이트 빈 파일에 대해 이 호출 하나만으로
   파일 크기가 0 → ~12288 바이트로 바뀌었다 — 진단이 상태를 바꾸는
   부작용(`ExplainDoesNotMutateExistingEmptyFileTest`).
2. **매달린 심볼릭 링크** — `os.path.exists()` 는 심볼릭 링크를
   따라가므로, 대상이 없는 매달린 링크는 "파일 없음"으로 오인정돼
   explain 은 무해한 대역으로 조용히 통과했다. 반면 실제 `run_event()`
   경로(`ApprovalConsumptionStore.open` 의 `_reject_symlink_or_special`,
   `os.lstat` 기반)는 링크 자체를 감지해 거부한다 — explain 은 통과,
   실제 실행은 차단이라는 판정 갈라짐이었다
   (`ExplainAndRunEventAgreeOnDanglingSymlinkTest`).

수리(`rein/cli/__init__.py::_open_approval_consumption_store`,
`rein/platform/storage/approval_store.py::
open_read_only_approval_consumption_store`)는 두 경로 모두 `os.lstat`
기반 판정을 공유하고, 이미 존재하는 정규 파일은 SQLite read-only URI
연결로 열어 스키마 생성 자체를 시도하지 않는다. 아래 두 클래스가 그
경계를 고정한다.

## Phase 6 4회차 독립 리뷰 Medium 1 — 심볼릭 링크 경계의 관측 방식 갱신

`approval.consumption_store` 가 lazy fact resolver 로 옮겨간 뒤에는
(위 "매달린 심볼릭 링크" 경계에서 던지던) `OSError` 가 evaluator 의
`FactResolutionError -> failure_mode` 경로로 흡수된다 — 더 이상 raw
예외로 관측되지 않고 안전한 BLOCK decision 으로 관측된다(여전히
fail-closed, 여전히 두 함수가 일치, 관측 방식만 "raise" 에서 "decision
dict" 로 바뀌었다). `ExplainAndRunEventAgreeOnDanglingSymlinkTest` 가
갱신된 계약을 고정한다.
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
    # user_approval 은 증거 발급형 capability 다 — Medium D 수리 후
    # 버전 파일이 없으면 이 fixture 자체가 설정 오류로 차단된다(정확한
    # 동작). 이 파일의 테스트는 Medium D 가 아니라 Medium E/Low F 를
    # 겨냥하므로, 그 차단을 피하기 위해 유효한 버전 파일을 둔다.
    with open(
        os.path.join(policy_dir, "_version.yaml"), "w", encoding="utf-8"
    ) as handle:
        handle.write('version: "1"\n')
    return policy_dir


def _write_authority_policy(project_root, switched_names=REQUIREMENT_NAMES):
    # Phase 7 결정 4(2026-08-19)로 배포 기본값이 5축→3축(code_review/
    # security_review/active_task)으로 좁혀져 user_approval 은 기본
    # 미전환(평가 시 자동 충족, fact 조회 없이 개입 안 함)이 됐다 —
    # 이 파일의 심볼릭 링크 경계 테스트는 "user_approval 이 실제로
    # 확인되어 lazy 승인 저장소 fact 가 조회된다"는 전제 위에 서 있으므로,
    # opt-in override 로 5축 전부(구 배포 기본값과 동일 구성)를 전환해
    # 옛 동작을 재현한다. 원 단언(파일 시스템 상태 부작용/parity)은
    # 변경하지 않는다.
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


class ExplainDoesNotCreateApprovalConsumptionDbTest(unittest.TestCase):
    """재현 + 수리 고정 — explain 은 승인 소비 DB 파일을 새로 만들지 않는다."""

    def test_db_file_existence_unchanged_after_run_explain(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            db_path = LocalStateRoot(project_root).approval_consumption_path()

            self.assertFalse(
                os.path.exists(db_path),
                msg="fixture sanity — db must not exist before explain runs",
            )

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                run_explain(_bash_payload())

            self.assertFalse(
                os.path.exists(db_path),
                msg="run_explain (a diagnostic, read-only entry point) "
                "must not create the approval consumption db file as a "
                "side effect — this is the state-changing bug under test",
            )


class ExplainDecisionParityWithFreshRunEventTest(unittest.TestCase):
    """회귀 방지 — read-only 대체가 실제 판정 결과를 바꾸지 않는다."""

    def test_explain_and_subsequent_run_event_agree_on_fresh_project(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                explanation = run_explain(_bash_payload())
                # run_explain 이 파일을 만들지 않았음을 여기서도 확인 —
                # 그래야 아래 run_event() 호출이 "이미 있던 파일"이
                # 아니라 정말로 최초 생성을 수행하는 것이 보장된다.
                db_path = LocalStateRoot(project_root).approval_consumption_path()
                self.assertFalse(os.path.exists(db_path))

                response = run_event(_bash_payload())

        self.assertEqual(
            explanation["decision"],
            response["decision"],
            msg="explain's read-only stand-in for a not-yet-created "
            "approval store must agree with the real (file-creating) "
            "store's answer on a fresh project — a stand-in that behaves "
            "differently would just move the Medium 2/4 divergence bug "
            "to a new place",
        )
        self.assertEqual(
            explanation["basis"]["missing_requirements"],
            response["missing_requirements"],
        )


class ExplainDoesNotMutateExistingEmptyFileTest(unittest.TestCase):
    """재현 + 수리 고정 — 이미 존재하는 빈 정규 파일은 explain 이 건드리지 않는다.

    Phase 6 3회차 재리뷰 Medium C 경계 1. 수리 전에는 이 테스트가
    실패했다(0 바이트 → ~12288 바이트로 커짐, `ApprovalConsumptionStore`
    가 스키마를 보장하며 파일에 실제로 씀).
    """

    def test_pre_existing_empty_db_file_size_unchanged_after_run_explain(self):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            state_root = LocalStateRoot(project_root)
            state_root.ensure()
            db_path = state_root.approval_consumption_path()

            # 빈 정규 파일을 미리 심어 둔다 — 예: 다른 도구가 경로만
            # 예약해 둔 상태, 또는 이전 실행이 스키마 생성 전에 중단된
            # 상태를 흉내낸다.
            with open(db_path, "wb"):
                pass
            self.assertEqual(
                os.path.getsize(db_path),
                0,
                msg="fixture sanity — db file must start empty",
            )

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
            with mock.patch.dict(os.environ, env):
                run_explain(_bash_payload())

            self.assertEqual(
                os.path.getsize(db_path),
                0,
                msg="run_explain must not write to a pre-existing empty "
                "approval consumption db file — schema creation "
                "(CREATE TABLE IF NOT EXISTS) must not run through a "
                "diagnostic call (this is the state-changing bug under "
                "test: file grew from 0 to ~12288 bytes before the fix)",
            )


class ExplainAndRunEventAgreeOnDanglingSymlinkTest(unittest.TestCase):
    """재현 + 수리 고정 — 매달린 심볼릭 링크에서 explain 과 run_event 의
    판정이 갈리지 않는다.

    Phase 6 3회차 재리뷰 Medium C 경계 2. 수리 전에는 `os.path.exists()`
    가 심볼릭 링크를 따라가 대상이 없는 링크를 "파일 없음"으로 오인정
    했다 — explain 은 무해한 대역으로 조용히 통과(예외 없음), 실제
    `run_event()` 경로는 `_reject_symlink_or_special` 이 lstat 로 링크
    자체를 감지해 `OSError` 를 던졌다. 그 수리로 두 경로 모두 같은
    `os.lstat` 판정을 공유해 **둘 다 `OSError` 를 raise** 하는 것으로
    parity 를 표현했다(구 버전 — 아래 갱신 참조).

    ## Phase 6 4회차 독립 리뷰 Medium 1 이후 — 메커니즘이 바뀌었다
    (raise 가 아니라 failure_mode BLOCK)

    `approval.consumption_store` 가 `_build_facts()` 안에서 즉시 계산되던
    값에서 `_build_fact_resolvers()` 의 lazy resolver 로 옮겨간 뒤에는,
    이 `OSError` 가 `EvaluationContext._resolve()` 에 의해
    `FactResolutionError`(`EvidenceStorageError` 하위 타입 — "판단 재료를
    확보하지 못해 판단 자체를 수행하지 못한 상태", `rein/engine/
    context.py` 모듈 docstring "fact 해석 실패의 지위" 절)로 감싸진다.
    이 예외는 `evaluator.evaluate()` 의 `require:` 순회 catch(`except
    EvidenceStorageError`)를 타고 매칭된 policy 의 `failure_mode` 로
    안전하게 흡수된다 — 이 저장소가 다른 모든 lazy fact resolver
    (changeset 해시 등)에 이미 적용해 온 것과 정확히 같은 경로다. 즉
    두 함수 모두 이제 raw `OSError` 를 던지는 대신 **failure_mode 로
    안전하게 BLOCK** 한다(테스트 policy 는 `failure_mode: closed`) —
    fail-closed 라는 안전 결과와 "두 함수가 같은 판정을 낸다"는 parity
    는 그대로 보존됐고, 판정에 도달하는 메커니즘만(raise → 통제된
    Evaluation Failure) 바뀌었다. reason 문자열에 원래 원인(심볼릭 링크
    거부)이 그대로 남아 있어야 이 흡수가 "조용한 통과"가 아님을
    보증한다.
    """

    def test_both_entry_points_block_via_failure_mode_on_dangling_symlink(
        self,
    ):
        with tempfile.TemporaryDirectory() as project_root:
            _init_git_repo(project_root)
            policy_dir = _write_approval_policy(project_root)
            _write_authority_policy(project_root)
            state_root = LocalStateRoot(project_root)
            state_root.ensure()
            db_path = state_root.approval_consumption_path()

            # 대상이 존재하지 않는(매달린) 심볼릭 링크를 db 경로에 미리
            # 심어 둔다 — 공격자가 사전에 링크를 심어두는 시나리오와
            # 동일 재료(`_reject_symlink_or_special` docstring 참조).
            os.symlink(
                os.path.join(project_root, "does-not-exist.sqlite3"), db_path
            )
            self.assertTrue(os.path.islink(db_path))
            self.assertFalse(
                os.path.exists(db_path),
                msg="fixture sanity — the symlink must be dangling",
            )

            env = {
                ENV_POLICY_DIR: policy_dir,
                ENV_PROJECT_ROOT: project_root,
            }
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
                msg="{} must fail closed when the approval consumption "
                "store path is a dangling symlink — falling back to the "
                "harmless empty stand-in (or a silent ALLOW) would be the "
                "Medium C regression, even though the mechanism is now a "
                "failure_mode decision rather than a raised "
                "OSError".format(label),
            )
            self.assertIn(
                "not a regular file",
                result["reason"],
                msg="{} reason must surface the original symlink "
                "rejection text, not swallow it into a generic "
                "message".format(label),
            )

        self.assertEqual(
            explanation["decision"],
            response["decision"],
            msg="explain and run_event must still agree (parity) on this "
            "boundary even though the underlying mechanism changed from "
            "a raised OSError to a lazy FactResolutionError -> "
            "failure_mode BLOCK",
        )


if __name__ == "__main__":
    unittest.main()
