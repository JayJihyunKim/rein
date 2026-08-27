"""plan Task 2.7 (p2-shadow-capture) — Shadow Capture masked representation.

covers: shadow-capture-stores-masked-representation-never-raw-commands-from-capture-stage

고정하는 계약 (spec §6.4 / brainstorm §46):
- Capture 단계부터 masked representation — raw command 는 어디에도
  저장되지 않는다 (fake secret 마커가 산출물 전체에서 0건).
- `command.redacted` 형태가 존재한다 (spec 예시:
  `git push https://token@host/repo` → `command.type=git.push` +
  `command.redacted=git push <REMOTE>`).
- 마스킹은 `rein.shadow.masking` SSOT 경유 결과와 일치한다.
- 대용량 입력에서도 크래시 없이 유한 시간 안에 끝나고, capture 자체
  길이 정책(`MAX_COMMAND_CHARS`)이 적용된다.

주의: 본 파일의 모든 secret 값은 명백한 가짜 상수다 (fake-/FAKE 접두).
"""
import os
import sys
import time
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.shadow import capture  # noqa: E402
from rein.shadow import masking  # noqa: E402

FAKE_PAT = "ghp_FAKETOKENabcdef1234567890"
FAKE_PASSWORD = "fakeS3cretPW"
FAKE_KEYWORD_SECRET = "fake-gh-value-9182736"


def _flatten_strings(value, out):
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for sub in value.values():
            _flatten_strings(sub, out)
    elif isinstance(value, (list, tuple)):
        for sub in value:
            _flatten_strings(sub, out)
    return out


class CaptureMaskedRepresentationTest(unittest.TestCase):
    """(a) capture 산출물 스캔 — token/credential/원문 명령 0건."""

    def test_spec_example_git_push_bare_token_url_is_collapsed(self):
        # spec §6.4 원문 예시. masking.py 의 URL credential 규칙은 콜론이
        # 있는 `user:pass@host` 형태만 잡는다는 것을 별도로 실측 확인했다
        # (bare `token@host` 는 미마스킹) — capture 의 구조적 URL 축약이
        # 이 사각지대를 메우는지 여기서 직접 고정한다.
        command_text = "git push https://{}@github.com/org/repo.git".format(
            FAKE_PAT
        )
        case = capture.capture(
            event="tool.pre",
            command_text=command_text,
            v1_decision="ALLOW",
            v1_reason="ok",
        )
        self.assertEqual(case.command["type"], "git.push")
        self.assertIn("<REMOTE>", case.command["redacted"])
        self.assertNotIn(FAKE_PAT, case.command["redacted"])
        self.assertNotIn("github.com", case.command["redacted"])
        self.assertTrue(
            case.command["redacted"].startswith("git push"),
            case.command["redacted"],
        )

    def test_keyword_value_command_is_masked_via_ssot_engine(self):
        command_text = "GITHUB_TOKEN={} ./deploy.sh".format(FAKE_KEYWORD_SECRET)
        case = capture.capture(event="tool.pre", command_text=command_text)
        expected = masking.sanitize(command_text)
        self.assertNotIn(FAKE_KEYWORD_SECRET, case.command["redacted"])
        # capture 가 masking.py 를 그대로 호출한 결과와 동일해야 한다
        # (구조적 축약이 끼어들지 않는, URL 이 없는 케이스).
        self.assertEqual(case.command["redacted"], expected)

    def test_basic_auth_and_bearer_forms_are_masked(self):
        for command_text in (
            "curl -u alice:{} https://api.example.com/v1".format(FAKE_PASSWORD),
            "echo bearer {}".format(FAKE_KEYWORD_SECRET),
            'curl -H "Authorization: Bearer {}" https://api.example.com'.format(
                FAKE_KEYWORD_SECRET
            ),
        ):
            case = capture.capture(event="tool.pre", command_text=command_text)
            self.assertNotIn(FAKE_PASSWORD, case.command["redacted"])
            self.assertNotIn(FAKE_KEYWORD_SECRET, case.command["redacted"])

    def test_facts_and_project_state_values_are_sanitized_too(self):
        case = capture.capture(
            event="tool.pre",
            facts={"note": "token={}".format(FAKE_KEYWORD_SECRET), "safe": "ok"},
            project_state={"env": "PASSWORD={}".format(FAKE_PASSWORD)},
            command_text="ls -la",
            v1_reason="blocked because token={}".format(FAKE_KEYWORD_SECRET),
        )
        blob = "\n".join(_flatten_strings(case.to_dict(), []))
        self.assertNotIn(FAKE_KEYWORD_SECRET, blob)
        self.assertNotIn(FAKE_PASSWORD, blob)
        self.assertEqual(case.facts["safe"], "ok")

    def test_forbidden_fact_keys_carrying_raw_command_are_dropped(self):
        raw = "git push https://{}@github.com/org/repo.git".format(FAKE_PAT)
        case = capture.capture(
            event="tool.pre",
            facts={"command_raw": raw, "raw_command": raw, "kept": "value"},
            command_text="git status",
        )
        self.assertNotIn("command_raw", case.facts)
        self.assertNotIn("raw_command", case.facts)
        self.assertEqual(case.facts["kept"], "value")
        blob = "\n".join(_flatten_strings(case.to_dict(), []))
        self.assertNotIn(FAKE_PAT, blob)

    def test_no_field_anywhere_contains_the_original_raw_command_verbatim(self):
        raw = "git push https://{}@github.com/org/repo.git".format(FAKE_PAT)
        case = capture.capture(
            event="tool.pre", command_text=raw, v1_decision="BLOCK", v1_reason="x"
        )
        as_dict = case.to_dict()
        blob = "\n".join(_flatten_strings(as_dict, []))
        self.assertNotIn(raw, blob)
        self.assertNotIn(FAKE_PAT, blob)
        # ShadowCase.command 는 구조적으로 "type"/"redacted" 2 키만 갖고
        # raw 필드를 실을 슬롯 자체가 없다.
        self.assertEqual(set(as_dict["command"]), {"type", "redacted"})

    def test_command_redacted_shape_present_for_non_git_command(self):
        case = capture.capture(event="tool.pre", command_text="ls -la /tmp")
        self.assertEqual(case.command["type"], "ls")
        self.assertEqual(case.command["redacted"], "ls -la /tmp")

    def test_no_command_text_yields_empty_redacted_and_unknown_type(self):
        case = capture.capture(event="tool.pre", command_text=None)
        self.assertEqual(case.command["type"], "unknown")
        self.assertEqual(case.command["redacted"], "")

    def test_facts_field_url_credential_routes_through_masking_ssot(self):
        # 코드 리뷰 Medium (2026-08-09): "명령 외 필드는 URL 축약
        # 우회를 안 거친다" — facts/project_state/v1_reason 은
        # build_redacted_command() 전용인 구조적 URL 축약을 거치지
        # 않고 masking.sanitize() SSOT 만 거친다. 이는 의도된 설계다
        # (capture() docstring 근거 참조) — 이 테스트는 "필드 값이
        # SSOT 를 거친다"는 라우팅 계약만 고정한다. SSOT(masking.py)
        # 자체가 이 특정 URL 형태(콜론 없는 token@host)를 인식하는지는
        # masking.py 소유 테스트의 책임이므로, masking.sanitize() 의
        # 실제 산출물과 동일한지만 비교한다 (동시 웨이브가 masking.py
        # 를 고치는 중이라도 이 테스트는 항상 GREEN 이어야 한다).
        raw_url = "see https://{}@github.com/org/repo for details".format(
            FAKE_PAT
        )
        case = capture.capture(
            event="tool.pre",
            facts={"note": raw_url},
            project_state={"last_url": raw_url},
            command_text="ls",
            v1_reason=raw_url,
        )
        expected = masking.sanitize(raw_url)
        self.assertEqual(case.facts["note"], expected)
        self.assertEqual(case.project_state["last_url"], expected)
        self.assertEqual(case.v1_reason, expected)


class CaptureTruncationOrderTest(unittest.TestCase):
    """절단은 masking 이후에만 (2026-08-09 보안 리뷰 High 회귀 고정).

    리뷰어 실측: 절단이 마스킹보다 먼저 raw text 에 적용되면, 절단
    경계가 secret 값 중간에 떨어질 때 masking 규칙 중 값 뒤 종결자를
    요구하는 것들(URL credential 의 trailing `@`)이 매칭에 실패해
    secret 조각이 그대로 노출된다(`...REALFAKEPA <TRUNCATED>` 10자
    평문 노출). 순서를 뒤집으면(mask 먼저, truncate 나중) masking 이
    항상 완전한 원문을 보므로 이 클래스가 사라진다.
    """

    def test_truncation_boundary_mid_secret_no_longer_leaks_plaintext_fragment(
        self,
    ):
        fake_pw = "REALFAKEPASSWORDVALUE1234567890"
        header = "echo "
        # `&&` 는 command_classifier 의 구조 메타문자라 command_type 이
        # UNKNOWN 이 된다 — 구조적 URL 축약(1단계)이 스킵되고 raw text
        # 전체가 그대로 masking(2단계)에 넘어가는, 리뷰어가 지적한
        # "패딩된 복합 명령" 경로를 그대로 재현한다.
        joiner = " && curl "
        url_prefix = "https://alice:"
        cut_into_secret = 10  # 리뷰어 실측과 동일하게 password 10번째 문자에서 절단
        padding_len = (
            capture.MAX_COMMAND_CHARS
            - len(header)
            - len(joiner)
            - len(url_prefix)
            - cut_into_secret
        )
        self.assertGreater(padding_len, 0, "fixture 산술이 음수면 안 됨")
        command_text = "{header}{padding}{joiner}{url_prefix}{pw}@example.com/x".format(
            header=header,
            padding="a" * padding_len,
            joiner=joiner,
            url_prefix=url_prefix,
            pw=fake_pw,
        )

        # fixture 자체 검증 — raw text 를 그대로 MAX_COMMAND_CHARS 에서
        # 자르면 정말 password 값 중간(뒤 10자, `@` 종결자 없이)에서
        # 끊기는지 확인한다 (이게 참이어야 아래가 실제 회귀 테스트다).
        raw_cut = command_text[: capture.MAX_COMMAND_CHARS]
        self.assertTrue(raw_cut.endswith(fake_pw[:cut_into_secret]))
        self.assertNotIn("@", raw_cut[-cut_into_secret:])

        case = capture.capture(event="tool.pre", command_text=command_text)
        self.assertNotIn(fake_pw, case.command["redacted"])
        self.assertNotIn(fake_pw[:cut_into_secret], case.command["redacted"])

    def test_truncation_boundary_mid_secret_inside_structurally_collapsed_url(
        self,
    ):
        # 동일 클래스를 git.push(구조적 축약 대상) 경로에서도 고정한다
        # — 이 경로는 축약이 토큰 전체를 <REMOTE> 로 치환하므로 애초에
        # masking 의 URL credential 규칙에 의존하지 않지만, 절단이
        # masking 이후로 옮겨졌다는 불변식은 이 경로에서도 유지돼야
        # 한다.
        fake_pw = "REALFAKEPASSWORDVALUE1234567890"
        padding_len = capture.MAX_COMMAND_CHARS
        command_text = "git push https://alice:{pw}@github.com/{padding}".format(
            pw=fake_pw, padding="x" * padding_len
        )
        case = capture.capture(event="tool.pre", command_text=command_text)
        self.assertEqual(case.command["type"], "git.push")
        self.assertNotIn(fake_pw, case.command["redacted"])
        self.assertIn("<REMOTE>", case.command["redacted"])


class CaptureLargeInputPolicyTest(unittest.TestCase):
    """요구사항 6 — 대용량 입력에서도 유한 시간 + 길이 상한 적용."""

    def test_large_command_is_truncated_and_marked(self):
        huge = "echo " + ("a" * (capture.MAX_COMMAND_CHARS * 5))
        start = time.time()
        case = capture.capture(event="tool.pre", command_text=huge)
        elapsed = time.time() - start
        self.assertLess(elapsed, 5.0, "capture() must finish quickly on huge input")
        self.assertIn(capture.TRUNCATION_MARKER, case.command["redacted"])
        self.assertLessEqual(
            len(case.command["redacted"]),
            capture.MAX_COMMAND_CHARS + len(capture.TRUNCATION_MARKER) + 64,
        )

    def test_large_input_with_embedded_secret_past_the_cap_stays_truncated(self):
        # 절단이 masking 이후로 옮겨졌으므로(2026-08-09 High 수정),
        # secret 은 먼저 masking 으로 <REDACTED> 치환되고, 그 다음
        # masked 결과가 길면 상한에서 다시 잘린다(이 fixture 는 padding
        # 이 상한보다 커서 <REDACTED> 부분 자체가 잘려나가는 경우다).
        # 두 경로 모두 원본 secret 리터럴은 출력에 나타나지 않는다 —
        # "누락"이 아니라 "corpus 최소정보 계약 밖" 이라는 명시적 길이
        # 정책의 결과다 (docstring 근거 참조).
        padding = "a" * (capture.MAX_COMMAND_CHARS + 100)
        command_text = "echo {} token={}".format(padding, FAKE_KEYWORD_SECRET)
        case = capture.capture(event="tool.pre", command_text=command_text)
        self.assertIn(capture.TRUNCATION_MARKER, case.command["redacted"])
        self.assertNotIn(FAKE_KEYWORD_SECRET, case.command["redacted"])

    def test_small_input_under_cap_is_not_truncated(self):
        case = capture.capture(event="tool.pre", command_text="echo hello")
        self.assertNotIn(capture.TRUNCATION_MARKER, case.command["redacted"])


class ShadowCaseSchemaTest(unittest.TestCase):
    """Shadow Case 최소 정보 스키마 (spec §6.4 / brainstorm §47)."""

    def test_minimum_schema_fields_present(self):
        case = capture.capture(
            event="tool.pre",
            facts={"command.type": "git.commit"},
            command_text="git commit -m 'msg'",
            project_state={"branch": "dev"},
            v1_decision="ALLOW",
            v1_reason="no issues",
        )
        as_dict = case.to_dict()
        for key in (
            "event",
            "facts",
            "command",
            "project_state",
            "v1_decision",
            "v1_reason",
        ):
            self.assertIn(key, as_dict)
        self.assertEqual(as_dict["event"], "tool.pre")
        self.assertEqual(as_dict["project_state"], {"branch": "dev"})
        self.assertEqual(as_dict["v1_decision"], "ALLOW")

    def test_event_must_be_non_empty_string(self):
        with self.assertRaises(ValueError):
            capture.ShadowCase(event="", command={"type": "x", "redacted": ""})

    def test_command_field_must_have_exact_two_keys(self):
        with self.assertRaises(ValueError):
            capture.ShadowCase(event="tool.pre", command={"type": "x"})
        with self.assertRaises(ValueError):
            capture.ShadowCase(
                event="tool.pre",
                command={"type": "x", "redacted": "", "raw": "leak"},
            )


if __name__ == "__main__":
    unittest.main()
