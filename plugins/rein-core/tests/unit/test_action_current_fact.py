"""platform.claude.facts.current_action_identifier — action.current fact
(v2 Phase 6 worker D — approval capability `FACT_ACTION_CURRENT` 계약,
v2 Phase 6 5회차 재리뷰 수리 워커 N — High 결속 우회 시정).

`rein.capabilities.approval.capability` 의 `user_approval` Evidence 는
"현재 action" 과 결속된다(spec §3.6 §21) — 승인 발급 시점의 action 식별자
와 평가 시점의 action 식별자가 문자열 동등 비교로 일치해야 승인이
유효하다. 이 모듈은 `rein.platform.claude.adapter.normalize_event` 가
만드는 정규화 이벤트 dict(`{"name": ..., "tool": ..., "payload": ...}`)
로부터 **결정적** 식별자 문자열을 만든다 — 같은 이벤트는 항상 같은
문자열이 나와야 발급/평가 두 시점의 결속이 성립한다.

`FACT_ACTION_CURRENT` 계약: 값은 `str`(비어있지 않음) 또는 `None`(현재
action 없음/미확보) 이어야 한다 — capability 의
`UserApprovalRequirement.evaluate` 는 그 외 타입을 `FactResolutionError`
로 거부한다.

## 보안 시정 회귀 테스트 (v2 Phase 6 재리뷰 High A / High B)

`SecretLeakageTest` / `LongCommonPrefixCollisionTest` 는 재리뷰가 실제
재현으로 지적한 두 결함을 고정한다:

- High A(유출): Bash 명령에 담긴 비밀값(`deploy --password hunter2`)이
  fact 값에 원문 그대로 남아 응답 JSON 으로 유출되던 경로.
- High B(충돌): 200자 절단으로 앞 200자가 같은 서로 다른 명령이 동일
  식별자를 얻어 승인이 오적용되던 경로.

수리 후 `current_action_identifier` 는 세부 정보(Bash 명령/대상 경로)
원문을 절대 반환하지 않고, 항상 전체(미절단) 내용의 sha256 digest 로
치환한다 — `facts.py` 모듈 docstring "보안 시정" 절 참조.

## 승인 결속 우회 회귀 테스트 (v2 Phase 6 5회차 재리뷰 High)

`PayloadBindingRegressionTest` 는 5회차 독립 리뷰어가 실제로 재현한
승인 우회 두 경로를 고정한다 — 이전 구현(4회차까지)이 Bash 는
`command` 전체를, 그 외 도구는 `file_path`/`notebook_path`/`path` 중
하나만 detail 로 봤기 때문에, `content`/`url` 같은 다른 키가 다른 두
요청이 같은 action 식별자를 받아 첫 요청에 대한 승인이 두 번째 요청에
그대로 적용될 수 있었다:

- `Write(path=A, content=SAFE)` vs `Write(path=A, content=DANGEROUS)`
- `WebFetch(url=allowed.example)` vs `WebFetch(url=other.example)`

`CanonicalSerializationTest` 는 수리 방식(payload 전체를 결정적으로
직렬화 후 해싱)이 요구하는 두 성질을 고정한다 — 키 순서만 다른 동등
payload 는 같은 식별자, 같은 입력을 반복하면 항상 같은 식별자.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.platform.claude import facts  # noqa: E402
from rein.platform.claude.adapter import normalize_event  # noqa: E402


def _bash_event(command):
    return normalize_event(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command},
        }
    )


class BashActionTest(unittest.TestCase):
    def test_bash_action_includes_event_and_tool_prefix(self):
        # event 이름/tool 이름은 Claude 어댑터가 정하는 고정 어휘라
        # 비밀값을 담지 않는다 — 그대로 남아 있어도 안전하다.
        identifier = facts.current_action_identifier(
            _bash_event("git push origin main")
        )
        self.assertIn("tool.pre", identifier)
        self.assertIn("Bash", identifier)

    def test_missing_command_still_produces_an_identifier(self):
        event = normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {},
            }
        )
        identifier = facts.current_action_identifier(event)
        self.assertIsInstance(identifier, str)
        self.assertTrue(identifier)

    def test_long_bash_command_produces_bounded_length_identifier(self):
        long_command = "echo " + ("x" * 500)
        identifier = facts.current_action_identifier(_bash_event(long_command))
        self.assertLess(len(identifier), len(long_command))
        self.assertNotIn(long_command, identifier)


class FilePathActionTest(unittest.TestCase):
    def test_edit_tool_identifier_is_deterministic_per_path(self):
        event = normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Edit",
                "tool_input": {"file_path": "/repo/src/main.py"},
            }
        )
        first = facts.current_action_identifier(event)
        second = facts.current_action_identifier(event)
        self.assertEqual(first, second)

    def test_notebook_edit_uses_notebook_path(self):
        first = facts.current_action_identifier(
            normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "NotebookEdit",
                    "tool_input": {"notebook_path": "/repo/nb.ipynb"},
                }
            )
        )
        second = facts.current_action_identifier(
            normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "NotebookEdit",
                    "tool_input": {"notebook_path": "/repo/other.ipynb"},
                }
            )
        )
        self.assertNotEqual(first, second)


class NoToolActionTest(unittest.TestCase):
    def test_agent_lifecycle_event_without_tool_still_produces_identifier(
        self,
    ):
        event = normalize_event(
            {
                "hook_event_name": "SubagentStart",
                "agent_id": "abc123",
                "agent_type": "builder",
            }
        )
        identifier = facts.current_action_identifier(event)
        self.assertIsInstance(identifier, str)
        self.assertIn("agent.started", identifier)


class MalformedEventTest(unittest.TestCase):
    def test_missing_name_returns_none(self):
        self.assertIsNone(facts.current_action_identifier({}))

    def test_non_dict_event_returns_none(self):
        self.assertIsNone(facts.current_action_identifier(None))
        self.assertIsNone(facts.current_action_identifier("tool.pre"))

    def test_result_type_is_str_or_none(self):
        event = normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
            }
        )
        self.assertIsInstance(facts.current_action_identifier(event), str)
        self.assertIsNone(facts.current_action_identifier({}))


class DeterminismTest(unittest.TestCase):
    def test_same_event_yields_same_identifier(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git push"},
        }
        first = facts.current_action_identifier(normalize_event(payload))
        second = facts.current_action_identifier(normalize_event(payload))
        self.assertEqual(first, second)

    def test_different_commands_yield_different_identifiers(self):
        first = facts.current_action_identifier(_bash_event("git push"))
        second = facts.current_action_identifier(_bash_event("git force-push"))
        self.assertNotEqual(first, second)


class SecretLeakageTest(unittest.TestCase):
    """High A 회귀 방지 — Bash 명령/파일 경로에 담긴 비밀값이 fact 값에
    원문으로 남지 않는다 (재리뷰 재현: `deploy --password hunter2`).
    """

    def test_bash_command_secret_is_not_present_in_identifier(self):
        identifier = facts.current_action_identifier(
            _bash_event("deploy --password hunter2")
        )
        self.assertNotIn("hunter2", identifier)
        self.assertNotIn("deploy --password hunter2", identifier)
        self.assertNotIn("password", identifier)

    def test_file_path_is_not_present_in_identifier(self):
        event = normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Edit",
                "tool_input": {"file_path": "/repo/secrets/api_key.txt"},
            }
        )
        identifier = facts.current_action_identifier(event)
        self.assertNotIn("/repo/secrets/api_key.txt", identifier)
        self.assertNotIn("api_key", identifier)


class LongCommonPrefixCollisionTest(unittest.TestCase):
    """High B 회귀 방지 — 200자 절단으로 서로 다른 명령이 같은 식별자를
    얻던 결함. 긴 공통 접두사(이전 200자 상한을 넘는 길이) + 서로 다른
    꼬리를 가진 두 Bash 명령은 반드시 다른 식별자를 받아야 승인 오적용이
    재발하지 않는다.
    """

    def test_commands_sharing_a_long_prefix_yield_different_identifiers(self):
        prefix = "echo " + ("x" * 250)
        first = facts.current_action_identifier(
            _bash_event(prefix + " && rm -rf /some/path")
        )
        second = facts.current_action_identifier(
            _bash_event(prefix + " && echo done")
        )
        self.assertNotEqual(first, second)

    def test_paths_sharing_a_long_prefix_yield_different_identifiers(self):
        prefix = "/repo/" + ("dir/" * 60)
        first = facts.current_action_identifier(
            normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Edit",
                    "tool_input": {"file_path": prefix + "a.py"},
                }
            )
        )
        second = facts.current_action_identifier(
            normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Edit",
                    "tool_input": {"file_path": prefix + "b.py"},
                }
            )
        )
        self.assertNotEqual(first, second)


class PayloadBindingRegressionTest(unittest.TestCase):
    """5회차 재리뷰 High 회귀 방지 — 리뷰어가 실제로 재현한 승인 우회
    두 경로. 모듈 docstring "승인 결속 우회 회귀 테스트" 절 참조.
    """

    def test_write_same_path_different_content_yields_different_identifiers(
        self,
    ):
        # 이전 구현은 file 지향 도구에서 `file_path` 만 detail 로 봤다 —
        # `content` 가 바뀌어도 식별자가 같았다(승인 우회 재현 1).
        def _write_event(content):
            return normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Write",
                    "tool_input": {
                        "file_path": "/repo/a.py",
                        "content": content,
                    },
                }
            )

        safe = facts.current_action_identifier(_write_event("SAFE"))
        dangerous = facts.current_action_identifier(
            _write_event("DANGEROUS")
        )
        self.assertNotEqual(
            safe,
            dangerous,
            msg="same-path Write calls with different content must not "
            "collide — a SAFE-content approval must not silently cover "
            "a DANGEROUS-content request",
        )

    def test_webfetch_different_urls_yield_different_identifiers(self):
        # `url` 은 `_PATH_PAYLOAD_KEYS` 화이트리스트에 없었으므로 이전
        # 구현은 detail 자체를 못 만들었다 — 도구가 같으면 대상이 완전히
        # 달라도 식별자가 같았다(승인 우회 재현 2).
        def _webfetch_event(url):
            return normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "WebFetch",
                    "tool_input": {"url": url},
                }
            )

        allowed = facts.current_action_identifier(
            _webfetch_event("https://allowed.example")
        )
        other = facts.current_action_identifier(
            _webfetch_event("https://other.example")
        )
        self.assertNotEqual(
            allowed,
            other,
            msg="WebFetch calls to different URLs must not collide — an "
            "approval for allowed.example must not cover other.example",
        )

    def test_webfetch_same_url_repeated_yields_same_identifier(self):
        # 같은 논리적 action 은 여전히 같은 식별자를 받아야 한다 —
        # 결속 자체를 깨뜨리는 방향(모든 요청을 서로 다르게 만드는)의
        # 과잉 수정이 아니었는지 확인.
        event = normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "WebFetch",
                "tool_input": {"url": "https://allowed.example"},
            }
        )
        first = facts.current_action_identifier(event)
        second = facts.current_action_identifier(event)
        self.assertEqual(first, second)


class CanonicalSerializationTest(unittest.TestCase):
    """수리 방식(payload 전체 결정적 직렬화 후 해싱)이 요구하는 두
    성질 — 키 순서 무관성 + 반복 호출 결정성.
    """

    def test_key_order_does_not_affect_identifier(self):
        # 의미상 동등한 payload(키 순서만 다름)는 같은 식별자를 받아야
        # 한다 — sort_keys 직렬화가 이를 보장한다.
        event_a = {
            "name": "tool.pre",
            "tool": "Write",
            "payload": {"file_path": "/repo/a.py", "content": "hello"},
        }
        event_b = {
            "name": "tool.pre",
            "tool": "Write",
            "payload": {"content": "hello", "file_path": "/repo/a.py"},
        }
        self.assertEqual(
            facts.current_action_identifier(event_a),
            facts.current_action_identifier(event_b),
        )

    def test_repeated_identical_call_yields_same_identifier(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git status"},
        }
        first = facts.current_action_identifier(normalize_event(payload))
        second = facts.current_action_identifier(normalize_event(payload))
        third = facts.current_action_identifier(normalize_event(payload))
        self.assertEqual(first, second)
        self.assertEqual(second, third)


if __name__ == "__main__":
    unittest.main()
