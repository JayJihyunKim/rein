"""Task 6.1 선행1(a) — `bin/rein hook` native 응답 변환 + exit code 계약
(DoD `dod-2026-08-12-v2-phase6-authority.md` Task 6.1 선행1).

`bin/rein` 이 raw kernel `Decision.to_dict()` 대신 `adapter.
to_native_response()` 를 거친 native 응답을 출력하는 새 서브커맨드
(`hook`)를 고정한다 — 이 서브커맨드가 Task 6.1 본작업(hooks.json 라우팅
전환, 이 파일 범위 밖)이 실제로 가리킬 대상이다. 자립 규칙 자체
(정책 0개로 새지 않음)의 세부 축은
`tests/cli/test_run_hook_event_self_reliance.py` 가 담당하고, 이 파일은
"native 응답 형태 + exit code + 기존 인자없음 경로 회귀 없음" 에
집중한다.

검증 축:
(a) PreToolUse BLOCK → `hookSpecificOutput.permissionDecision == "deny"`.
(b) 종료 계열(Stop) BLOCK → 소문자 `decision == "block"`.
(c) ALLOW → 비간섭 응답(`{}`).
(d) exit code — 정상 처리(ALLOW/BLOCK 무관)는 항상 exit 0, JSON 본문으로
    표현된다. 순수 입력 결함(JSONDecodeError/UnknownHookEventError)만
    기존 계약대로 exit 1.
(e) 미포착 예외 주입 → native BLOCK(조용한 ALLOW 아님) — in-process 로
    `rein.cli.run_hook_event` 를 mock 해 예외를 주입한다(worker 지침 —
    subprocess 로 bin/rein 을 실행하는 테스트는 무해 입력만).
(f) 회귀 방지 — 인자 없는 기존 경로는 `hook` 서브커맨드 추가 이후에도
    여전히 대문자 raw decision 을 낸다.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

_BIN_REIN = os.path.join(_PLUGIN_ROOT, "bin", "rein")
_SUBPROCESS_TIMEOUT_SECONDS = 30
_ENV_POLICY_DIR = "REIN_POLICY_DIR"
_ENV_PROJECT_ROOT = "REIN_PROJECT_ROOT"
_ENV_DB_PATH = "REIN_DB_PATH"
_ALL_THREE_ENV_VARS = (_ENV_POLICY_DIR, _ENV_PROJECT_ROOT, _ENV_DB_PATH)

_STOP_ACTIVE_TASK_POLICY_YAML = (
    "trigger: session.stop\n"
    "require:\n"
    "  - active_task\n"
    "failure_mode: closed\n"
)
_VERSION_YAML = 'version: "1"\n'


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _write_active_dod(project_root, slug="fixture-task", date="2026-08-19"):
    # Phase 7 결정 1(2026-08-19 사용자 결정) — 기본 commit.yaml 의
    # `when:` 에 `task.exists: "true"` 가 추가돼, `trail/dod/dod-*.md`
    # 글롭에 매치되는 파일이 하나도 없으면 commit.yaml 자체가 매칭되지
    # 않는다. `task.exists` 는 v1 `dod_exists` glob 의 독립 미러 shim —
    # 완료 여부(inbox 대조)·날짜 형식과 무관하게 파일 존재만 본다
    # (`rein.platform.task.facts.task_exists()` 참조, High-1 리뷰 후
    # 확정 — `tests/contract/test_commit_policy_task_conditioning.py`
    # 와 결정 번호 동일). `test_pretooluse_block_maps_to_permission_
    # deny` 는 "PreToolUse BLOCK 이 hookSpecificOutput.permissionDecision
    # == deny 로 매핑되는가"를 겨냥하므로, commit.yaml 이 실제로 매칭돼
    # BLOCK 이 발동해야 그 매핑을 검증할 수 있다 — 활성 작업 픽스처로
    # 그 전제를 복원한다(원 단언은 변경하지 않는다).
    _write(
        os.path.join(
            project_root, "trail", "dod", "dod-{}-{}.md".format(date, slug)
        ),
        "# DoD\n\n- date: {}\n".format(date),
    )


def _clean_env(extra=None):
    env = dict(os.environ)
    for key in _ALL_THREE_ENV_VARS:
        env.pop(key, None)
    if extra:
        env.update(extra)
    return env


def _run_hook_subprocess(payload_text, cwd, extra_env=None):
    return subprocess.run(
        [sys.executable, _BIN_REIN, "hook"],
        input=payload_text,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=_clean_env(extra_env),
        timeout=_SUBPROCESS_TIMEOUT_SECONDS,
    )


def _bash_payload(command, cwd):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
            "cwd": cwd,
        }
    )


def _read_payload(cwd):
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": {"file_path": "/tmp/whatever"},
            "cwd": cwd,
        }
    )


def _stop_payload(cwd):
    return json.dumps({"hook_event_name": "Stop", "cwd": cwd})


def _load_bin_rein_module():
    """bin/rein 을 실행 없이 모듈로 로드한다 (in-process 예외 주입용).

    `tests/cli/test_doctor_explain.py::_load_bin_rein_module()` 과
    동일한 관례(확장자 없는 스크립트라 `SourceFileLoader` 를 명시).
    """
    loader = importlib.machinery.SourceFileLoader(
        "rein_bin_rein_under_test_hook", _BIN_REIN
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class HookNativeResponseShapeTest(unittest.TestCase):
    """(a)/(b)/(c)/(d) native 응답 형태 — subprocess, 무해 입력만."""

    def test_pretooluse_block_maps_to_permission_deny(self):
        with tempfile.TemporaryDirectory() as workdir:
            _write_active_dod(workdir)
            proc = _run_hook_subprocess(
                _bash_payload("git commit -m x", workdir), cwd=workdir
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertIn("hookSpecificOutput", response)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("permissionDecisionReason", specific)
        self.assertNotIn("decision", response)

    def test_pretooluse_allow_maps_to_empty_response(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = _run_hook_subprocess(_read_payload(workdir), cwd=workdir)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response, {})

    def test_stop_block_maps_to_lowercase_decision(self):
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, "policies")
            _write(os.path.join(policy_dir, "_version.yaml"), _VERSION_YAML)
            _write(
                os.path.join(policy_dir, "stop.yaml"),
                _STOP_ACTIVE_TASK_POLICY_YAML,
            )
            proc = _run_hook_subprocess(
                _stop_payload(project_root),
                cwd=project_root,
                extra_env={
                    _ENV_POLICY_DIR: policy_dir,
                    _ENV_PROJECT_ROOT: project_root,
                },
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        self.assertEqual(response.get("decision"), "block")
        self.assertIn("reason", response)
        self.assertNotIn("hookSpecificOutput", response)

    def test_stop_allow_maps_to_empty_response(self):
        """비교축 — 같은 Stop 이벤트라도 매칭 정책이 없으면 비간섭 응답."""
        with tempfile.TemporaryDirectory() as project_root:
            proc = _run_hook_subprocess(
                _stop_payload(project_root), cwd=project_root
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(json.loads(proc.stdout), {})


class HookSelfRelianceEndToEndTest(unittest.TestCase):
    """(d) 자립 규칙의 subprocess 종단 확인 — exit code 계약 포함."""

    def test_policy_dir_missing_maps_to_block_not_silent_exit(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = _run_hook_subprocess(
                _read_payload(workdir),
                cwd=workdir,
                extra_env={
                    _ENV_POLICY_DIR: os.path.join(workdir, "does-not-exist")
                },
            )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("judgement failure", specific["permissionDecisionReason"])

    def test_project_root_undecidable_maps_to_block(self):
        payload = json.dumps(
            {"hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": {}}
        )
        with tempfile.TemporaryDirectory() as workdir:
            proc = _run_hook_subprocess(payload, cwd=workdir)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        response = json.loads(proc.stdout)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("judgement failure", specific["permissionDecisionReason"])

    def test_json_decode_error_keeps_exit_one_contract(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = _run_hook_subprocess("not valid json", cwd=workdir)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")

    def test_unknown_hook_event_keeps_exit_one_contract(self):
        payload = json.dumps({"hook_event_name": "TotallyUnsupportedHook"})
        with tempfile.TemporaryDirectory() as workdir:
            proc = _run_hook_subprocess(payload, cwd=workdir)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")


class HookSubcommandFailClosedMappingTest(unittest.TestCase):
    """(e) 미포착 예외 주입 → native BLOCK, in-process mock (worker 지침)."""

    def _run_hook_main_with_stdin(self, payload_text):
        bin_rein = _load_bin_rein_module()
        buffer = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(payload_text)):
            with mock.patch.object(sys, "argv", ["rein", "hook"]):
                with redirect_stdout(buffer):
                    exit_code = bin_rein.main()
        return exit_code, buffer.getvalue()

    def test_unhandled_exception_maps_to_native_block_not_silent_allow(self):
        payload_text = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "cwd": "/tmp",
            }
        )
        with mock.patch("rein.cli.run_hook_event", side_effect=RuntimeError("boom")):
            exit_code, stdout_text = self._run_hook_main_with_stdin(payload_text)
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("judgement failure", specific["permissionDecisionReason"])
        self.assertIn("boom", specific["permissionDecisionReason"])

    def test_unhandled_exception_on_stop_maps_to_lowercase_block(self):
        payload_text = json.dumps({"hook_event_name": "Stop", "cwd": "/tmp"})
        with mock.patch(
            "rein.cli.run_hook_event",
            side_effect=RuntimeError("stop boom"),
        ):
            exit_code, stdout_text = self._run_hook_main_with_stdin(payload_text)
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response.get("decision"), "block")
        self.assertIn("stop boom", response["reason"])

    def test_malformed_payload_still_emits_native_block_not_raw_decision(self):
        """payload 가 dict 조차 아닌 극단 입력에도 crash 없이 native BLOCK 을 낸다.

        코드 리뷰 High 지적(이름-방향 불일치) — 수리 전 이 테스트의
        이름은 "valid fail-closed" 였지만 단언은 raw kernel decision
        (대문자 `BLOCK`)을 그대로 요구했다: hook_name 을 못 구하면
        (payload 가 dict 조차 아님) `to_native_response()` 가
        `UnknownHookEventError` 를 던지고, 수리 전 `_run_hook()` 은 그
        경우 raw decision 을 그대로 stdout 에 냈다. 이 서브커맨드의
        전제 자체가 "raw decision 을 Claude Code 가 차단으로 해석하지
        않는다"(Task 6.1 선행1 모듈 docstring)이므로 이는 안전한
        폴백이 아니었다 — 리뷰어가 실제로 이 갭을 지적했다. 이제는
        hook_name 을 모르는 극단 입력에서도 실제 native 스키마(범용
        `decision`/`reason` 소문자 형태, `_minimal_native_block()`)로
        수렴한다.
        """
        exit_code, stdout_text = self._run_hook_main_with_stdin("42")
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response.get("decision"), "block")
        self.assertNotEqual(response.get("decision"), "BLOCK")
        self.assertIn("reason", response)
        self.assertNotIn("hookSpecificOutput", response)


class HookNativeConversionFailureFailsClosedTest(unittest.TestCase):
    """코드 리뷰 High — native 변환·직렬화 실패도 fail-closed 경계 안.

    수리 전에는 `_run_hook()` 이 `run_hook_event()` 호출까지만 예외를
    감쌌고, 그 뒤의 native 변환(`to_native_response()`)은
    `UnknownHookEventError` 만 잡았다 — engine 이 잘못된 decision 값을
    반환하거나 변환기 내부에서 다른 예외가 나면 stdout 없이 예외가
    탈출해 exit 1(이 저장소 규약에서 exit 1 은 비차단/통과)이 됐다.
    이 클래스는 리뷰어가 실제로 재현한 두 경로(잘못된 decision 값
    주입, 변환기 자체의 예외) + 직렬화 실패 경로를 모두 native BLOCK
    또는 exit 2 로 수렴시키는지 고정한다.
    """

    def _run_hook_main_with_stdin(self, payload_text):
        bin_rein = _load_bin_rein_module()
        buffer = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(payload_text)):
            with mock.patch.object(sys, "argv", ["rein", "hook"]):
                with redirect_stdout(buffer):
                    exit_code = bin_rein.main()
        return exit_code, buffer.getvalue()

    def test_invalid_decision_value_from_run_hook_event_still_blocks(self):
        """리뷰어 재현 시나리오 — engine 이 ALLOW/BLOCK/ASK_USER 가 아닌
        값을 반환하면 `to_native_response()` 가 `ValueError` 를 던진다.
        수리 전에는 이 예외가 잡히지 않아 exit 1 로 탈출했다."""
        payload_text = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "cwd": "/tmp",
            }
        )
        invalid_decision = {
            "decision": "MAYBE",
            "reason": "invalid decision value injected by test",
            "policy": None,
            "missing_requirements": [],
            "evidence_refs": [],
        }
        with mock.patch(
            "rein.cli.run_hook_event", return_value=invalid_decision
        ):
            exit_code, stdout_text = self._run_hook_main_with_stdin(
                payload_text
            )
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")

    def test_invalid_decision_value_on_stop_maps_to_lowercase_block(self):
        payload_text = json.dumps({"hook_event_name": "Stop", "cwd": "/tmp"})
        invalid_decision = {
            "decision": "MAYBE",
            "reason": "invalid decision value injected by test",
            "policy": None,
            "missing_requirements": [],
            "evidence_refs": [],
        }
        with mock.patch(
            "rein.cli.run_hook_event", return_value=invalid_decision
        ):
            exit_code, stdout_text = self._run_hook_main_with_stdin(
                payload_text
            )
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        self.assertEqual(response.get("decision"), "block")
        self.assertNotIn("hookSpecificOutput", response)

    def test_to_native_response_internal_exception_still_blocks(self):
        """변환기 자체가(잘못된 decision 값이 아니라) 다른 이유로 예외를
        던지는 경우 — 수리 전에는 `UnknownHookEventError` 만 잡혔으므로
        이 예외는 그대로 탈출했다."""
        payload_text = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "cwd": "/tmp",
            }
        )
        well_formed_decision = {
            "decision": "BLOCK",
            "reason": "some real block reason",
            "policy": "some-policy",
            "missing_requirements": [],
            "evidence_refs": [],
        }
        with mock.patch(
            "rein.cli.run_hook_event", return_value=well_formed_decision
        ):
            with mock.patch(
                "rein.platform.claude.adapter.to_native_response",
                side_effect=RuntimeError("adapter internal boom"),
            ):
                exit_code, stdout_text = self._run_hook_main_with_stdin(
                    payload_text
                )
        self.assertEqual(exit_code, 0)
        response = json.loads(stdout_text)
        specific = response["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")

    def test_native_response_serialization_failure_degrades_to_exit_2(self):
        """마스킹·JSON 직렬화 예외 — native 응답 자체가 직렬화 불가한
        값을 담고 있으면 최종 emit 단계에서 실패한다. 이 경우는
        `_minimal_native_block()` 을 다시 호출해도 해결되지 않으므로
        (변환기가 아니라 값 자체의 문제) exit 2(차단 방향 종료)로
        수렴해야 한다 — 부분적으로 깨진 JSON 을 exit 0 으로 내보내
        소비자가 파싱에 실패한 채 통과시키는 것보다 안전하다."""

        class _Unserializable:
            pass

        payload_text = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
                "cwd": "/tmp",
            }
        )
        well_formed_decision = {
            "decision": "BLOCK",
            "reason": "x",
            "policy": None,
            "missing_requirements": [],
            "evidence_refs": [],
        }
        bad_native = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": _Unserializable(),
            }
        }
        with mock.patch(
            "rein.cli.run_hook_event", return_value=well_formed_decision
        ):
            with mock.patch(
                "rein.platform.claude.adapter.to_native_response",
                return_value=bad_native,
            ):
                exit_code, stdout_text = self._run_hook_main_with_stdin(
                    payload_text
                )
        self.assertEqual(exit_code, 2)
        # 실패한 직렬화의 부분 결과물이 stdout 에 새지 않아야 한다 —
        # 소비자가 깨진 JSON 을 파싱 시도하다 알 수 없는 상태로 남는
        # 것보다, "아무 것도 없음 + exit 2" 가 명확한 차단 신호다.
        self.assertEqual(stdout_text, "")


class ArgLessPathRegressionTest(unittest.TestCase):
    """(f) `hook` 서브커맨드 신설 이후에도 인자 없는 경로는 그대로다."""

    def test_no_args_path_still_returns_uppercase_raw_decision(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = subprocess.run(
                [sys.executable, _BIN_REIN],
                input=json.dumps(
                    {
                        "hook_event_name": "PreToolUse",
                        "tool_name": "Read",
                        "tool_input": {},
                    }
                ),
                capture_output=True,
                text=True,
                cwd=workdir,
                env=_clean_env(),
                timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            response = json.loads(proc.stdout)
            self.assertEqual(response["decision"], "ALLOW")
            for field in ("reason", "policy", "missing_requirements", "evidence_refs"):
                self.assertIn(field, response)
            # 기본 실행은 산출물을 남기지 않는다 — hook 서브커맨드가 추가돼도
            # 인자 없는 경로는 여전히 어떤 런타임 산출물도 cwd 에 남기지 않는다.
            self.assertEqual(os.listdir(workdir), [])

    def test_hook_subcommand_is_listed_alongside_existing_ones(self):
        with tempfile.TemporaryDirectory() as workdir:
            proc = subprocess.run(
                [sys.executable, _BIN_REIN, "bogus-subcommand"],
                input="",
                capture_output=True,
                text=True,
                cwd=workdir,
                env=_clean_env(),
                timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("hook", proc.stderr)
        self.assertIn("doctor", proc.stderr)
        self.assertIn("explain", proc.stderr)


if __name__ == "__main__":
    unittest.main()
