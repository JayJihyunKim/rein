"""plan Task 2.4 — Change Tags 분류 + 비직결 계약 테스트 (spec §3.3).

fixture 는 inline 문자열 + tempfile 로 실로더 경로에 태운다 (저장소
트리에 fixture 파일을 남기지 않는다 — 워커 scope 계약). 배포 기본값
policies/tags.yaml 만 예외로 직접 로드한다 (scope 내 배포 파일).

고정 대상:
- 분류 테이블: code/docs/sensitive 각각 + 무태그 경로(None)
  + 우선순위 겹침 — 선언 순서 = 우선순위, 첫 매치 승리
- 로더 폐쇄 스키마: rules[].tag/pattern 2필드 밖 키·3종 밖 tag·직접
  decision 필드는 전부 로드 시점 명시 에러 (fail-closed)
- D3 subset 파서 경유: subset 밖 YAML 은 source:line 명시 에러
- 비직결 계약: tags 모듈 공개 표면에 decision/block/allow 류 API 부재
  (Tag → Policy → Requirements 경유만 — Tag 직접 차단 경로 없음)
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

from rein.engine import tags  # noqa: E402

_FIXTURE_SOURCE = "inline-tags.yaml"

# 분류 테이블 fixture — 선언 순서 = 우선순위 (첫 매치 승리).
# sensitive → code → docs 순서라 겹침은 항상 보수적으로 해소된다.
_FIXTURE_RULES = (
    "rules:\n"
    "  - tag: sensitive\n"
    '    pattern: ".env"\n'
    "  - tag: sensitive\n"
    '    pattern: "*/secrets/*"\n'
    "  - tag: code\n"
    '    pattern: "*.py"\n'
    "  - tag: docs\n"
    '    pattern: "docs/*"\n'
    "  - tag: docs\n"
    '    pattern: "*.md"\n'
)

# 동일 pattern 집합, docs 를 code 앞에 선언 — 우선순위가 하드코딩이
# 아니라 선언 순서에서 온다는 것을 고정한다.
_DOCS_BEFORE_CODE_RULES = (
    "rules:\n"
    "  - tag: docs\n"
    '    pattern: "docs/*"\n'
    "  - tag: code\n"
    '    pattern: "*.py"\n'
)

# 비직결 계약 — tags 공개 표면에 존재해서는 안 되는 이름 조각.
# spec §3.3: Tag 는 행동을 직접 결정하지 않는다 (직접 차단 경로 없음).
_FORBIDDEN_NAME_FRAGMENTS = (
    "decision",
    "decide",
    "block",
    "allow",
    "deny",
    "ask",
    "enforce",
    "require",
    "approve",
    "reject",
    "verdict",
    "gate",
)

# tags 모듈 소스가 끌어와서는 안 되는 계층 (decision/requirement 직결 금지)
_FORBIDDEN_IMPORT_PATHS = (
    "rein.kernel.decision",
    "rein.kernel.requirement",
    "rein.engine.evaluator",
    "rein.engine.runtime",
)


class ClassificationTableTest(unittest.TestCase):
    """경로 → Tag 분류 테이블 (inline fixture 규칙 기준)."""

    def setUp(self):
        self.rules = tags.parse_tag_rules(_FIXTURE_RULES, _FIXTURE_SOURCE)

    def test_code_path(self):
        self.assertEqual(tags.classify_path("src/app.py", self.rules), "code")

    def test_docs_paths(self):
        self.assertEqual(tags.classify_path("README.md", self.rules), "docs")
        self.assertEqual(
            tags.classify_path("docs/guide/setup.txt", self.rules), "docs"
        )

    def test_sensitive_paths(self):
        # basename 매칭 — 루트와 중첩 디렉토리 모두
        self.assertEqual(tags.classify_path(".env", self.rules), "sensitive")
        self.assertEqual(
            tags.classify_path("config/.env", self.rules), "sensitive"
        )
        # 전체 경로 매칭 ('/' 포함 pattern)
        self.assertEqual(
            tags.classify_path("app/secrets/token.txt", self.rules),
            "sensitive",
        )

    def test_untagged_path_returns_none(self):
        self.assertIsNone(tags.classify_path("assets/logo.png", self.rules))
        self.assertIsNone(tags.classify_path("data/blob.bin", self.rules))

    def test_empty_path_returns_none(self):
        self.assertIsNone(tags.classify_path("", self.rules))

    def test_overlap_sensitive_wins_over_code(self):
        # '*/secrets/*' (sensitive) 와 '*.py' (code) 둘 다 매치 — 먼저
        # 선언된 sensitive 가 이긴다
        self.assertEqual(
            tags.classify_path("app/secrets/rotate.py", self.rules),
            "sensitive",
        )

    def test_overlap_code_wins_over_docs(self):
        # '*.py' (code) 와 'docs/*' (docs) 둘 다 매치 — code 선언이 먼저
        self.assertEqual(
            tags.classify_path("docs/build.py", self.rules), "code"
        )

    def test_overlap_priority_is_declaration_order(self):
        # 같은 pattern 집합이라도 선언 순서가 바뀌면 승자가 바뀐다
        reversed_rules = tags.parse_tag_rules(
            _DOCS_BEFORE_CODE_RULES, _FIXTURE_SOURCE
        )
        self.assertEqual(
            tags.classify_path("docs/build.py", reversed_rules), "docs"
        )

    def test_path_normalization(self):
        # './' 접두어와 backslash 구분자는 분류 전에 정규화된다
        self.assertEqual(
            tags.classify_path("./src/app.py", self.rules), "code"
        )
        self.assertEqual(
            tags.classify_path("config\\.env", self.rules), "sensitive"
        )


class TagRulesLoaderTest(unittest.TestCase):
    """폐쇄 스키마 로더 — 스키마 밖은 전부 로드 시점 명시 에러."""

    def _assert_parse_error(self, text, *expected_fragments):
        with self.assertRaises(tags.TagRulesError) as caught:
            tags.parse_tag_rules(text, _FIXTURE_SOURCE)
        message = str(caught.exception)
        self.assertIn(
            _FIXTURE_SOURCE, message, msg="에러는 source 를 명시해야 한다"
        )
        for fragment in expected_fragments:
            self.assertIn(fragment, message)
        return message

    def test_valid_rules_parse_in_declaration_order(self):
        rules = tags.parse_tag_rules(_FIXTURE_RULES, _FIXTURE_SOURCE)
        self.assertEqual(
            [(rule.tag, rule.pattern) for rule in rules],
            [
                ("sensitive", ".env"),
                ("sensitive", "*/secrets/*"),
                ("code", "*.py"),
                ("docs", "docs/*"),
                ("docs", "*.md"),
            ],
        )

    def test_unknown_top_level_field_is_load_time_error(self):
        self._assert_parse_error(
            _FIXTURE_RULES + "mode: strict\n",
            "unsupported top-level field",
            "'mode'",
        )

    def test_missing_rules_key_is_load_time_error(self):
        self._assert_parse_error("# 빈 파일\n", "rules")

    def test_rules_must_be_a_sequence(self):
        self._assert_parse_error("rules: code\n", "block sequence")

    def test_rule_unknown_field_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n"
            '    pattern: "*.py"\n'
            "    severity: high\n",
            "unsupported field",
            "'severity'",
        )

    def test_rule_direct_decision_field_is_load_time_error(self):
        # spec §3.3 — Tag 직접 차단 경로 없음: 규칙에 decision 류 필드가
        # 실리는 것 자체를 데이터 층에서 거부한다
        self._assert_parse_error(
            "rules:\n"
            "  - tag: sensitive\n"
            '    pattern: ".env"\n'
            "    decision: BLOCK\n",
            "unsupported field",
            "'decision'",
            "never carry decision fields",
        )

    def test_rule_tag_outside_three_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: config\n"
            '    pattern: "*.toml"\n',
            "code, docs, sensitive",
            "'config'",
        )

    def test_rule_missing_pattern_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n",
            "missing required field",
            "'pattern'",
        )

    def test_rule_missing_tag_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            '  - pattern: "*.py"\n',
            "missing required field",
            "'tag'",
        )

    def test_rule_pattern_must_be_scalar(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n"
            "    pattern:\n"
            '      - "*.py"\n',
            "pattern",
            "scalar",
        )

    def test_empty_pattern_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n"
            '    pattern: ""\n',
            "pattern",
        )

    def test_duplicate_rule_is_load_time_error(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n"
            '    pattern: "*.py"\n'
            "  - tag: code\n"
            '    pattern: "*.py"\n',
            "duplicate",
        )

    def test_flow_style_is_rejected_via_subset_parser(self):
        # D3 fail-closed — subset 밖 구문은 source:line 명시 에러
        message = self._assert_parse_error(
            "rules: [{tag: code}]\n", "flow style"
        )
        self.assertIn("{}:1".format(_FIXTURE_SOURCE), message)

    def test_block_scalar_is_rejected_via_subset_parser(self):
        self._assert_parse_error(
            "rules:\n"
            "  - tag: code\n"
            "    pattern: |\n"
            "      *.py\n",
            "block scalar",
        )

    def test_load_error_names_file_path(self):
        with tempfile.TemporaryDirectory() as workdir:
            path = os.path.join(workdir, "tags.yaml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("rules:\n  - tag: code\n    action: go\n")
            with self.assertRaises(tags.TagRulesError) as caught:
                tags.load_tag_rules(path)
            self.assertIn(path, str(caught.exception))

    def test_unreadable_file_is_explicit_error(self):
        with tempfile.TemporaryDirectory() as workdir:
            path = os.path.join(workdir, "absent.yaml")
            with self.assertRaises(tags.TagRulesError) as caught:
                tags.load_tag_rules(path)
            self.assertIn(path, str(caught.exception))


class ShippedDefaultsTest(unittest.TestCase):
    """배포 기본값 policies/tags.yaml — D3 subset 파서로 로드된다."""

    @classmethod
    def setUpClass(cls):
        cls.rules = tags.load_tag_rules()

    def test_default_path_points_into_policies_dir(self):
        self.assertTrue(
            tags.DEFAULT_RULES_PATH.endswith(
                os.path.join("policies", "tags.yaml")
            )
        )
        self.assertTrue(os.path.isfile(tags.DEFAULT_RULES_PATH))

    def test_shipped_rules_use_only_three_tags(self):
        self.assertTrue(self.rules)
        for rule in self.rules:
            self.assertIn(rule.tag, tags.TAG_NAMES)

    def test_shipped_classification_table(self):
        table = {
            ".env": "sensitive",
            "config/.env.production": "sensitive",
            "deploy/id_rsa": "sensitive",
            "certs/server.pem": "sensitive",
            "rein/engine/tags.py": "code",
            "hooks/pre-commit.sh": "code",
            "plugins/rein-core/policies/tags.yaml": "code",
            "README.md": "docs",
            "LICENSE": "docs",
            "docs/notes/setup.txt": "docs",
            "assets/logo.png": None,
            "data/model.bin": None,
        }
        for path, expected in table.items():
            self.assertEqual(
                tags.classify_path(path, self.rules),
                expected,
                msg="path={!r}".format(path),
            )

    def test_shipped_overlap_resolves_conservatively(self):
        # sensitive 규칙이 code 규칙보다 앞 — 겹치면 sensitive
        self.assertEqual(
            tags.classify_path("secrets/rotate.sh", self.rules), "sensitive"
        )
        # code 규칙이 docs 규칙보다 앞 — docs 트리의 스크립트는 code
        self.assertEqual(
            tags.classify_path("docs/build.py", self.rules), "code"
        )

    def test_shipped_sensitive_precedes_code_precedes_docs(self):
        order = [rule.tag for rule in self.rules]
        self.assertIn("sensitive", order)
        self.assertIn("code", order)
        self.assertIn("docs", order)
        last_sensitive = max(
            i for i, tag in enumerate(order) if tag == "sensitive"
        )
        first_code = min(i for i, tag in enumerate(order) if tag == "code")
        last_code = max(i for i, tag in enumerate(order) if tag == "code")
        first_docs = min(i for i, tag in enumerate(order) if tag == "docs")
        self.assertLess(last_sensitive, first_code)
        self.assertLess(last_code, first_docs)


    def test_cloud_and_tool_credential_files_are_sensitive(self):
        # 보안 리뷰 지적 반영분 — 자격증명을 담는 흔한 형식들이
        # 일반 code(*.json) 로 새지 않는지 고정한다.
        for path in (
            "keys/my-firebase-adminsdk-abc123.json",
            "deploy/service-account-prod.json",
            "gcp-sa-key.json",
            ".docker/config.json",
            "home/.kube/config",
        ):
            self.assertEqual(
                tags.classify_path(path, self.rules),
                "sensitive",
                msg="{} 는 sensitive 로 분류돼야 한다".format(path),
            )

    def test_kubeconfig_rule_does_not_over_match_bare_config(self):
        # `.kube/config` 경로 문맥으로만 한정 — 일반 config 파일까지
        # sensitive 로 끌어올리면 오탐이 심해진다.
        self.assertNotEqual(
            tags.classify_path("app/config", self.rules), "sensitive"
        )
        self.assertNotEqual(
            tags.classify_path("config", self.rules), "sensitive"
        )


class NonDecisionContractTest(unittest.TestCase):
    """Tag → Policy → Requirements 경유 계약 — Tag 직결 API 부재 고정."""

    def test_public_surface_has_no_decision_api(self):
        # 모듈 dir() 순회 — decision/block/allow 류 이름이 공개 표면에
        # 존재하지 않는다 (Tag 만으로 decision 이 나오는 API 부재)
        for name in dir(tags):
            if name.startswith("_"):
                continue
            lowered = name.lower()
            for fragment in _FORBIDDEN_NAME_FRAGMENTS:
                self.assertNotIn(
                    fragment,
                    lowered,
                    msg=(
                        "tags 공개 표면에 decision 류 이름 {!r} 가 있다 "
                        "(Tag → Policy → Requirements 경유 계약 위반)"
                    ).format(name),
                )

    def test_classify_returns_bare_tag_name_or_none(self):
        rules = tags.parse_tag_rules(_FIXTURE_RULES, _FIXTURE_SOURCE)
        result = tags.classify_path("src/app.py", rules)
        # 반환값은 평문 태그 이름 str — decision 형태 객체가 아니다
        self.assertIsInstance(result, str)
        self.assertIn(result, tags.TAG_NAMES)
        self.assertIsNone(tags.classify_path("assets/logo.png", rules))

    def test_tag_names_are_exactly_three(self):
        self.assertEqual(
            sorted(tags.TAG_NAMES), ["code", "docs", "sensitive"]
        )

    def test_module_does_not_import_decision_or_requirement_layers(self):
        with open(tags.__file__, "r", encoding="utf-8") as handle:
            source = handle.read()
        for forbidden in _FORBIDDEN_IMPORT_PATHS:
            self.assertNotIn(
                forbidden,
                source,
                msg="tags.py 가 {} 계층에 직결됨".format(forbidden),
            )


if __name__ == "__main__":
    unittest.main()
