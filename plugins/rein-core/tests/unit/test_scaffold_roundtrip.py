"""plan Task 1.1 walking skeleton 왕복 테스트.

bin/rein 을 실제 subprocess 로 구동한다 — SPIKE-1 이 측정할 경로
(인터프리터 기동 / import / policy load / git fact / SQLite open / 평가 왕복)
그대로를 테스트가 지나가게 하기 위해서다.
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
_BIN_REIN = os.path.join(_PLUGIN_ROOT, "bin", "rein")
_REPO_ROOT = os.path.dirname(os.path.dirname(_PLUGIN_ROOT))

_ENV_POLICY_DIR = "REIN_POLICY_DIR"
_ENV_DB_PATH = "REIN_DB_PATH"
_SUBPROCESS_TIMEOUT_SECONDS = 30

_DECISION_FIELDS = ("reason", "policy", "missing_requirements", "evidence_refs")

# 대표 policy fixture 3개 — scope 밖 파일을 만들지 않기 위해 inline 문자열로
# 두고 tempfile 로 실로더 경로에 태운다 (plan Task 1.1 측정 충실도 계약).
#
# `_version.yaml` 도 이 dict 에 포함한다 (Phase 6 마무리 수리 워커 H) —
# 아래 3개 fixture 중 두 개(`require-review-on-bash.yaml`/
# `require-tests-on-write.yaml`)가 code_review/tests_passed(둘 다
# 증거 발급형)를 선언하므로, 버전 메타데이터 파일이 없으면
# `rein.cli._load_policy_version_fact` 가 설정 오류로 명시 차단한다
# (`rein/cli/__init__.py::_load_policy_version_fact` docstring "Medium D"
# 절 — 독립 리뷰어가 이 계약을 확정했다: 증거 발급형 requirement 를
# 요구하는 정책 세트라면 버전 부재는 항상 설정 오류다, project_root 유무와
# 무관). `load_policies()` 는 이 예약 파일명을 4필드 policy 스키마
# 파싱에서 건너뛰므로(`rein.kernel.policy.VERSION_FILENAME`), 이
# fixture 로더 루프에 그대로 얹어도 다른 3개 파일의 로딩에 영향이 없다.
_POLICY_FIXTURES = {
    "_version.yaml": "version: 1\n",
    "require-review-on-bash.yaml": (
        "trigger: tool.pre\n"
        "when:\n"
        "  tool: Bash\n"
        "require:\n"
        "  - code_review\n"
        "failure_mode: closed\n"
    ),
    "require-tests-on-write.yaml": (
        "# 다중 requirement 형태의 대표 fixture\n"
        "trigger: tool.pre\n"
        "when:\n"
        "  tool: Write\n"
        "require:\n"
        "  - tests_passed\n"
        "  - code_review\n"
        "failure_mode: closed\n"
    ),
    "require-active-task-on-completion.yaml": (
        "trigger: task.completed\n"
        "require:\n"
        "  - active_task\n"
        "failure_mode: ask_user\n"
    ),
}


def _tool_pre_payload(tool_name):
    return {
        "hook_event_name": "PreToolUse",
        "tool_name": tool_name,
        "tool_input": {"command": "ls"},
    }


class ScaffoldRoundtripTest(unittest.TestCase):
    def _run_rein(self, payload, cwd, extra_env=None):
        env = dict(os.environ)
        # 바깥 세션의 runtime 환경변수가 테스트 결정성을 깨지 않게 제거
        env.pop(_ENV_POLICY_DIR, None)
        env.pop(_ENV_DB_PATH, None)
        env.update(extra_env or {})
        proc = subprocess.run(
            [sys.executable, _BIN_REIN],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            cwd=cwd,
            env=env,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        return json.loads(proc.stdout)

    def test_bin_rein_is_executable(self):
        self.assertTrue(
            os.access(_BIN_REIN, os.X_OK),
            msg="{} must carry the executable bit".format(_BIN_REIN),
        )

    def test_tool_pre_defaults_to_allow_without_policies(self):
        with tempfile.TemporaryDirectory() as workdir:
            response = self._run_rein(_tool_pre_payload("Bash"), cwd=workdir)
            self.assertEqual(response["decision"], "ALLOW")
            for field in _DECISION_FIELDS:
                self.assertIn(field, response)
            self.assertIsNone(response["policy"])
            self.assertEqual(response["missing_requirements"], [])
            # 기본 실행은 어떤 런타임 산출물도 cwd 에 남기면 안 된다
            self.assertEqual(os.listdir(workdir), [])

    def test_policy_fixtures_flow_through_real_loader(self):
        with tempfile.TemporaryDirectory() as workdir:
            policy_dir = os.path.join(workdir, "policies")
            os.mkdir(policy_dir)
            for name, text in _POLICY_FIXTURES.items():
                fixture_path = os.path.join(policy_dir, name)
                with open(fixture_path, "w", encoding="utf-8") as handle:
                    handle.write(text)
            db_path = os.path.join(workdir, "runtime.sqlite3")
            env = {_ENV_POLICY_DIR: policy_dir, _ENV_DB_PATH: db_path}

            # fixture 가 실로더를 지나 평가에 실제로 반영되는지: 매칭 이벤트는
            # evidence 부재로 BLOCK (spec 3.4 — 정상 평가 결과다)
            blocked = self._run_rein(
                _tool_pre_payload("Bash"), cwd=workdir, extra_env=env
            )
            self.assertEqual(blocked["decision"], "BLOCK")
            self.assertEqual(blocked["policy"], "require-review-on-bash")
            self.assertEqual(blocked["missing_requirements"], ["code_review"])

            allowed = self._run_rein(
                _tool_pre_payload("Read"), cwd=workdir, extra_env=env
            )
            self.assertEqual(allowed["decision"], "ALLOW")

            # SQLite open 경로가 실제로 돌았고, 산출물은 temp 안에만 존재
            self.assertTrue(os.path.exists(db_path))
            self.assertEqual(
                sorted(os.listdir(workdir)), ["policies", "runtime.sqlite3"]
            )

    def test_git_branch_fact_matches_repository(self):
        probe = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            cwd=_REPO_ROOT,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
        )
        self.assertEqual(probe.returncode, 0, msg=probe.stderr)
        expected_branch = probe.stdout.strip()

        response = self._run_rein(_tool_pre_payload("Read"), cwd=_REPO_ROOT)
        self.assertEqual(response["facts"]["git.branch"], expected_branch)


if __name__ == "__main__":
    unittest.main()
