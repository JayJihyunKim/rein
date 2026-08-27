"""platform.git.facts.changeset_tag — ChangeSet 의 단일 Tag 결속 판정
(v2 Phase 6 worker D — testing capability `FACT_CHANGESET_TAG` 계약).

`rein.capabilities.testing.capability` 의 `TestsPassedRequirement.evaluate`
가 조회하는 `changeset.tag` fact 는 "지금 평가 대상 ChangeSet 의 현재
tag" 다 — 값이 falsy(None 포함)면 그 축은 미확보로 간주돼 보수적으로
미충족이 된다 (`if not current_tag: return False`).

이 모듈은 `rein.engine.tags.classify_path` 를 재사용한다(재구현하지
않는다, DoD 지시) — Tag 분류의 유일한 SSOT 는 그 함수다. **설계 결정**:
ChangeSet 의 모든 경로가 **같은** Tag 로 분류될 때만 그 Tag 를 반환하고,
하나라도 다른 Tag 이거나 무매치(`None`)면 전체를 `None`(판정 불가)으로
반환한다 — 혼합 ChangeSet 에 임의의 한 Tag 를 배정하면, testing
capability 의 evidence 결속 검증(`_verify_paths_classify_to_tag`, 모든
path 가 declared tag 로 재분류돼야 발급)과 반대로 "부분 일치"를 관대하게
승격하는 것이 되어 tag 축의 보수적 방향(spec §3.4 확인 불가 ≠ 충족)과
어긋난다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import tags  # noqa: E402
from rein.kernel.changeset import SCOPE_WORKTREE, ChangeSet  # noqa: E402
from rein.platform.git import facts  # noqa: E402

_RULES = tags.parse_tag_rules(
    "rules:\n"
    "  - tag: sensitive\n"
    '    pattern: ".env"\n'
    "  - tag: code\n"
    '    pattern: "*.py"\n'
    "  - tag: docs\n"
    '    pattern: "*.md"\n',
    source="<test:changeset-tag-rules>",
)


def _changeset(*paths):
    return ChangeSet(scope=SCOPE_WORKTREE, paths=paths)


class SingleTagChangesetTest(unittest.TestCase):
    def test_all_code_paths_return_code_tag(self):
        changeset = _changeset("a.py", "sub/b.py")
        self.assertEqual(
            facts.changeset_tag(changeset, tag_rules=_RULES), tags.TAG_CODE
        )

    def test_all_docs_paths_return_docs_tag(self):
        changeset = _changeset("README.md", "docs/guide.md")
        self.assertEqual(
            facts.changeset_tag(changeset, tag_rules=_RULES), tags.TAG_DOCS
        )

    def test_single_sensitive_path_returns_sensitive_tag(self):
        changeset = _changeset(".env")
        self.assertEqual(
            facts.changeset_tag(changeset, tag_rules=_RULES),
            tags.TAG_SENSITIVE,
        )


class MixedOrUncertainChangesetTest(unittest.TestCase):
    def test_mixed_code_and_docs_returns_none(self):
        changeset = _changeset("a.py", "README.md")
        self.assertIsNone(facts.changeset_tag(changeset, tag_rules=_RULES))

    def test_one_unmatched_path_returns_none_even_if_rest_agree(self):
        changeset = _changeset("a.py", "b.py", "unmatched.xyz")
        self.assertIsNone(facts.changeset_tag(changeset, tag_rules=_RULES))

    def test_all_unmatched_returns_none(self):
        changeset = _changeset("unmatched.xyz")
        self.assertIsNone(facts.changeset_tag(changeset, tag_rules=_RULES))

    def test_empty_changeset_returns_none(self):
        changeset = _changeset()
        self.assertIsNone(facts.changeset_tag(changeset, tag_rules=_RULES))

    def test_none_changeset_returns_none(self):
        self.assertIsNone(facts.changeset_tag(None, tag_rules=_RULES))


class DefaultRulesTest(unittest.TestCase):
    """tag_rules 미지정 시 배포 기본값(policies/tags.yaml) 을 쓴다."""

    def test_uses_default_tag_rules_when_not_provided(self):
        changeset = _changeset("main.py")
        self.assertEqual(facts.changeset_tag(changeset), tags.TAG_CODE)

    def test_default_rules_classify_docs(self):
        changeset = _changeset("README.md")
        self.assertEqual(facts.changeset_tag(changeset), tags.TAG_DOCS)


if __name__ == "__main__":
    unittest.main()
