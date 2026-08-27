"""platform.task.facts.{is_task_relevant_path,changeset_task_relevant} —
v1 IS_SOURCE 동등 재현 (v2 Phase 6 worker D — spec §3.6 §6.3, active_task
capability 계약).

v1 `hooks/pre-edit-dod-gate.sh` (라인 233-339) 의 IS_SOURCE 판정 cascade:

1. 경로 기반 면제(runtime state / trail / .gitkeep) — `.gitignore` 는
   예외의 예외로 먼저 걸러져 그대로 소스 판정으로 진입한다.
2. generated/vendored 제외 (source-dir 판정보다 우선, tightening-only)
3. 소스 디렉토리 화이트리스트 (`*/src/*` 등 + rein-internal 경로)
4. doc/data/lock 확장자 제외 (source-dir 밖에서만 적용)
5. 소스 확장자 화이트리스트 (additive)

`rein.capabilities.task.capability.FACT_CHANGESET_TASK_RELEVANT` 계약:
값은 `bool` 또는 `None`(미확보) 이어야 한다 — 이 모듈은 항상 `bool` 을
반환한다(fact 미확보는 상위 fact resolver 배선의 관심사이지 이 순수
분류 함수의 관심사가 아니다).
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.platform.task import facts  # noqa: E402


class ExemptionTest(unittest.TestCase):
    """runtime state / trail / .gitkeep 는 항상 무관 — gitignore 는 예외."""

    def test_trail_path_is_not_relevant(self):
        self.assertFalse(facts.is_task_relevant_path("trail/dod/dod-x.md"))
        self.assertFalse(
            facts.is_task_relevant_path("project/trail/inbox/x.md")
        )

    def test_claude_cache_path_is_not_relevant(self):
        self.assertFalse(
            facts.is_task_relevant_path(".claude/cache/state.json")
        )

    def test_claude_rein_state_path_is_not_relevant(self):
        self.assertFalse(
            facts.is_task_relevant_path(".claude/.rein-state/stage.json")
        )

    def test_gitkeep_is_not_relevant(self):
        self.assertFalse(facts.is_task_relevant_path("empty/.gitkeep"))

    def test_gitignore_is_relevant_despite_looking_like_an_exemption(self):
        # v1: .gitignore 는 case 문 최상단에서 fall-through 되어 아래 소스
        # 판정(디렉토리 화이트리스트 3번째 항목)으로 진입 — IS_SOURCE=true.
        self.assertTrue(facts.is_task_relevant_path(".gitignore"))
        self.assertTrue(facts.is_task_relevant_path("sub/dir/.gitignore"))


class GeneratedVendoredTest(unittest.TestCase):
    """generated/vendored 제외는 디렉토리 화이트리스트보다 우선한다."""

    def test_node_modules_and_vendor_are_not_relevant(self):
        self.assertFalse(
            facts.is_task_relevant_path("app/node_modules/pkg/index.js")
        )
        self.assertFalse(
            facts.is_task_relevant_path("vendor/foo/lib/x.go")
        )

    def test_dist_build_next_generated_pycache_are_not_relevant(self):
        for fragment in (
            "dist",
            "build",
            ".next",
            "generated",
            "__generated__",
            "__pycache__",
        ):
            with self.subTest(fragment=fragment):
                self.assertFalse(
                    facts.is_task_relevant_path(
                        "app/{}/output.py".format(fragment)
                    )
                )

    def test_min_js_generated_dot_pb2_pb_go_are_not_relevant(self):
        self.assertFalse(facts.is_task_relevant_path("static/app.min.js"))
        self.assertFalse(
            facts.is_task_relevant_path("src/api.generated.ts")
        )
        self.assertFalse(facts.is_task_relevant_path("proto/foo_pb2.py"))
        self.assertFalse(facts.is_task_relevant_path("proto/foo.pb.go"))

    def test_generated_exclusion_wins_over_source_directory(self):
        # tightening-only 순서: src/ 안에 있어도 generated/ 는 비소스.
        self.assertFalse(
            facts.is_task_relevant_path("src/generated/api.ts")
        )
        self.assertFalse(
            facts.is_task_relevant_path("app/vendor/foo/lib/x.go")
        )


class SourceDirectoryTest(unittest.TestCase):
    """디렉토리 화이트리스트 — 확장자와 무관하게 관련."""

    def test_common_source_directories_are_relevant(self):
        for fragment in (
            "src",
            "app",
            "services",
            "apps",
            "lib",
            "components",
            "hooks",
            "store",
            "types",
            "models",
            "schemas",
            "repositories",
            "routers",
            "alembic",
        ):
            with self.subTest(fragment=fragment):
                self.assertTrue(
                    facts.is_task_relevant_path(
                        "project/{}/thing.json".format(fragment)
                    )
                )

    def test_scripts_top_level_and_nested_are_relevant(self):
        self.assertTrue(facts.is_task_relevant_path("scripts/deploy.py"))
        self.assertTrue(
            facts.is_task_relevant_path("tools/scripts/deploy.py")
        )

    def test_top_level_source_directory_without_parent_segment_is_relevant(
        self,
    ):
        # 회귀 테스트 — v1 의 `*/src/*` 류 패턴은 절대 경로(항상 앞에 '/')
        # 를 전제로 쓰였다. v2 ChangeSet.paths 는 repo-relative(앞에 '/'
        # 없음)라 최상위 `src/main.py` 처럼 부모 세그먼트가 없는 경로가
        # 순수 문자열 매칭으로는 "/src/" 부분 문자열을 갖지 못해 놓칠 뻔
        # 했다 — is_task_relevant_path 는 가상 루트 슬래시를 보정해
        # 이 경우도 잡아야 한다.
        for fragment in ("src", "app", "lib", "components"):
            with self.subTest(fragment=fragment):
                self.assertTrue(
                    facts.is_task_relevant_path(
                        "{}/main.py".format(fragment)
                    )
                )

    def test_top_level_claude_rules_without_parent_segment_is_relevant(self):
        self.assertTrue(facts.is_task_relevant_path(".claude/rules/foo.md"))
        self.assertTrue(
            facts.is_task_relevant_path(".claude/skills/foo/SKILL.md")
        )

    def test_rein_internal_claude_paths_are_relevant(self):
        for path in (
            ".claude/rules/foo.md",
            ".claude/skills/foo/SKILL.md",
            ".claude/agents/foo.md",
            ".claude/workflows/foo.md",
            ".claude/CLAUDE.md",
            ".claude/orchestrator.md",
            ".claude/settings.json",
        ):
            with self.subTest(path=path):
                self.assertTrue(facts.is_task_relevant_path(path))

    def test_agents_md_root_and_nested_are_relevant(self):
        self.assertTrue(facts.is_task_relevant_path("AGENTS.md"))
        self.assertTrue(facts.is_task_relevant_path("packages/api/AGENTS.md"))


class NonSourceExtensionTest(unittest.TestCase):
    """source-dir 밖의 doc/data/lock 확장자는 무관 — dir 안이면 여전히 관련."""

    def test_doc_extensions_outside_source_dir_are_not_relevant(self):
        for ext in ("md", "txt", "rst", "adoc"):
            with self.subTest(ext=ext):
                self.assertFalse(
                    facts.is_task_relevant_path("README.{}".format(ext))
                )

    def test_data_and_lock_extensions_outside_source_dir_are_not_relevant(
        self,
    ):
        for ext in (
            "json",
            "yaml",
            "yml",
            "toml",
            "ini",
            "csv",
            "xml",
            "env",
            "lock",
            "sum",
        ):
            with self.subTest(ext=ext):
                self.assertFalse(
                    facts.is_task_relevant_path("config.{}".format(ext))
                )

    def test_data_extension_inside_source_dir_is_still_relevant(self):
        # (2) 디렉토리 화이트리스트가 (3) 확장자 제외보다 먼저 결정한다 —
        # source-dir 내부는 확장자 제외 규칙에 도달하지 않는다.
        self.assertTrue(facts.is_task_relevant_path("src/schema.json"))


class SourceExtensionTest(unittest.TestCase):
    """디렉토리로 안 잡힌 소스 확장자는 additive 로 관련."""

    def test_common_source_extensions_are_relevant(self):
        for ext in (
            "go",
            "rs",
            "py",
            "ts",
            "tsx",
            "js",
            "jsx",
            "mjs",
            "cjs",
            "java",
            "kt",
            "rb",
            "php",
            "c",
            "h",
            "cpp",
            "sh",
            "swift",
            "cs",
        ):
            with self.subTest(ext=ext):
                self.assertTrue(
                    facts.is_task_relevant_path("root_file.{}".format(ext))
                )

    def test_dockerfile_makefile_mk_are_relevant(self):
        self.assertTrue(facts.is_task_relevant_path("Dockerfile"))
        self.assertTrue(facts.is_task_relevant_path("services/api/Dockerfile"))
        self.assertTrue(facts.is_task_relevant_path("Makefile"))
        self.assertTrue(facts.is_task_relevant_path("build.mk"))

    def test_unknown_extension_defaults_to_not_relevant(self):
        # GMF-3 방향: 목록 누락은 보수적으로 "비관련"(게이트 미적용) —
        # 과차단 방지가 v1 의 명시적 선택.
        self.assertFalse(facts.is_task_relevant_path("notes.xyz123"))


class ChangesetCombinationTest(unittest.TestCase):
    """ChangeSet 전체의 관련성 — 하나라도 관련이면 전체가 관련(FN 방지)."""

    def test_any_relevant_path_makes_whole_changeset_relevant(self):
        self.assertTrue(
            facts.changeset_task_relevant(("README.md", "src/main.py"))
        )

    def test_all_irrelevant_paths_is_not_relevant(self):
        self.assertFalse(
            facts.changeset_task_relevant(("README.md", "CHANGELOG.md"))
        )

    def test_empty_changeset_is_not_relevant(self):
        self.assertFalse(facts.changeset_task_relevant(()))


if __name__ == "__main__":
    unittest.main()
