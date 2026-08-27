"""plan Task 3.4 (p3-shadow-replay) — Shadow Replay + mismatch 4분류.

covers: shadow-replay-classifies-every-v1-v2-mismatch-into-four-causes

고정하는 계약 (spec §6.4 / brainstorm §47~§48):
- Corpus replay 로 v1 vs v2 decision 을 대조하고, mismatch 를 4분류
  (v2 bug / v1 bug / intentional policy change / insufficient case
  data)로 **남김없이** 분류한다.
- **미분류 mismatch 0건**: 분류 누락이 있으면 리포트 생성이 명시
  예외로 실패한다 — 조용한 부분 리포트 금지.
- 위험한 false-allow 방향(v1 BLOCK → v2 ALLOW)은 리포트에서 별도
  표기·집계된다.
- Migration Acceptance: 고정 절대 수치 계약 금지 — 리포트는 집계·분류
  사실만 담고 합격/불합격 판정을 내리지 않는다 (전부 mismatch 인
  corpus 도 리포트 생성 자체는 성공해야 한다).
- corpus 파일은 읽기 전용 — replay 가 corpus 를 변경하지 않는다.
- 모든 파일 생성은 temp 디렉토리 한정 (실전 corpus 접근 금지).
- (웨이브 3 코드 리뷰 1회차 High 회귀) `build_report()` 는 호출자
  제공 match 판정을 신뢰하지 않는다 — outcome 은 폐쇄 스키마로
  검증되고(`matched` 슬롯 자체가 없음, 미지/결손 필드는 명시 예외),
  match 는 v1_decision vs v2_decision 재계산으로만 정해진다. 거짓
  `matched=True` 주입으로 미분류 0건 계약을 조용히 우회할 수 없다.
"""
import json
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.shadow import corpus  # noqa: E402
from rein.shadow import replay  # noqa: E402


def _policies():
    """kernel/policy.py 로더 산출물 형태의 fixture policy.

    commit.pre 는 tests_passed(고정 5종 requirement) 를 요구하고,
    evidence_source 미지정(NullEvidenceSource)이라 항상 부재 → BLOCK.
    그 외 이벤트는 매칭 policy 없음 → 기본 ALLOW.
    """
    return [
        {
            "policy_id": "commit-requires-tests",
            "fields": {
                "trigger": "commit.pre",
                "when": {},
                "require": ["tests_passed"],
                "failure_mode": "closed",
            },
        }
    ]


def _case(event, v1_decision, v1_reason=""):
    """Shadow Case 최소 정보 스키마 (spec §6.4) 형태의 corpus 레코드."""
    return {
        "event": event,
        "facts": {},
        "command": {"type": "ls", "redacted": "ls"},
        "project_state": {},
        "v1_decision": v1_decision,
        "v1_reason": v1_reason,
        "captured_at": "2026-08-10T00:00:00",
    }


class ReplayFixtureTest(unittest.TestCase):
    """fixture corpus 를 temp 디렉토리에 직접 쓰는 공통 기반."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmpdir = tmp.name

    def _write_corpus(self, cases, filename=None):
        path = os.path.join(self.tmpdir, filename or corpus.CORPUS_FILENAME)
        with open(path, "w", encoding="utf-8") as handle:
            for case in cases:
                handle.write(json.dumps(case, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        return path

    def _standard_corpus(self):
        """5 case: match 2 + mismatch 2(위험 1) + 재료 결손 1.

        line 1: tool.pre / v1 ALLOW → v2 ALLOW (policy 미매칭) — match
        line 2: commit.pre / v1 BLOCK → v2 BLOCK (evidence 부재) — match
        line 3: commit.pre / v1 ALLOW → v2 BLOCK — mismatch (비위험)
        line 4: tool.pre / v1 BLOCK → v2 ALLOW — mismatch (위험 false-allow)
        line 5: v1_decision 부재 — insufficient case data 자동 분류 대상
        """
        broken = _case("tool.pre", "ALLOW")
        del broken["v1_decision"]
        return self._write_corpus(
            [
                _case("tool.pre", "ALLOW"),
                _case("commit.pre", "BLOCK", "v1 gate blocked"),
                _case("commit.pre", "ALLOW"),
                _case("tool.pre", "BLOCK", "v1 gate blocked"),
                broken,
            ]
        )

    def _standard_classifications(self):
        return {
            replay.case_key(3): replay.CLASSIFICATION_INTENTIONAL_POLICY_CHANGE,
            replay.case_key(4): replay.CLASSIFICATION_V2_BUG,
        }


class ClassificationVocabularyTest(unittest.TestCase):
    def test_vocabulary_is_closed_to_the_four_spec_classes(self):
        """spec §6.4 mismatch 4분류 어휘가 상수로 폐쇄돼 있다."""
        self.assertEqual(
            set(replay.CLASSIFICATIONS),
            {
                "v2 bug",
                "v1 bug",
                "intentional policy change",
                "insufficient case data",
            },
        )
        self.assertEqual(len(replay.CLASSIFICATIONS), 4)


class ReportGenerationTest(ReplayFixtureTest):
    """(a) 전부 분류된 corpus → 리포트 생성 성공 + 미분류 0건."""

    def test_fully_classified_corpus_produces_report(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        self.assertEqual(report["total_cases"], 5)
        self.assertEqual(report["matches"], 2)
        self.assertEqual(len(report["mismatches"]), 3)
        self.assertEqual(report["unclassified_mismatches"], 0)

    def test_classification_counts_cover_all_four_classes(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        counts = report["classification_counts"]
        self.assertEqual(set(counts), set(replay.CLASSIFICATIONS))
        self.assertEqual(counts[replay.CLASSIFICATION_V2_BUG], 1)
        self.assertEqual(counts[replay.CLASSIFICATION_V1_BUG], 0)
        self.assertEqual(
            counts[replay.CLASSIFICATION_INTENTIONAL_POLICY_CHANGE], 1
        )
        self.assertEqual(
            counts[replay.CLASSIFICATION_INSUFFICIENT_CASE_DATA], 1
        )
        # 모든 mismatch 가 4분류 중 하나에 귀속 — 남김없이 (spec §6.4)
        self.assertEqual(sum(counts.values()), len(report["mismatches"]))

    def test_report_is_json_serializable_and_corpus_stays_untouched(self):
        path = self._standard_corpus()
        with open(path, "rb") as handle:
            before = handle.read()
        report = replay.generate_report(
            path, _policies(), classifications=self._standard_classifications()
        )
        json.dumps(report)  # 직렬화 가능 dict 계약
        with open(path, "rb") as handle:
            self.assertEqual(before, handle.read(), "corpus 는 읽기 전용")


class UnclassifiedMismatchTest(ReplayFixtureTest):
    """(b) 분류 입력에 없는 mismatch → 리포트 생성 실패 (핵심 계약)."""

    def test_missing_classification_fails_report_generation(self):
        classifications = self._standard_classifications()
        del classifications[replay.case_key(4)]
        with self.assertRaises(replay.UnclassifiedMismatchError) as ctx:
            replay.generate_report(
                self._standard_corpus(),
                _policies(),
                classifications=classifications,
            )
        self.assertIn(replay.case_key(4), ctx.exception.case_keys)

    def test_no_classification_input_at_all_fails_when_mismatch_exists(self):
        with self.assertRaises(replay.UnclassifiedMismatchError) as ctx:
            replay.generate_report(self._standard_corpus(), _policies())
        # insufficient(line 5) 는 자동 분류되므로 미분류는 line 3·4 뿐
        self.assertEqual(
            sorted(ctx.exception.case_keys),
            sorted([replay.case_key(3), replay.case_key(4)]),
        )

    def test_unknown_classification_value_is_rejected(self):
        classifications = self._standard_classifications()
        classifications[replay.case_key(4)] = "wontfix"
        with self.assertRaises(replay.UnknownClassificationError):
            replay.generate_report(
                self._standard_corpus(),
                _policies(),
                classifications=classifications,
            )

    def test_incomparable_non_string_classification_values_are_explicit(self):
        """2회차 리뷰 Medium 회귀: 서로 비교 불가능한 비문자열 분류값이
        섞여도 정렬 TypeError 가 아니라 UnknownClassificationError."""
        for first, second in ((None, 42), (["v2 bug"], "wontfix")):
            classifications = {
                replay.case_key(3): first,
                replay.case_key(4): second,
            }
            with self.assertRaises(replay.UnknownClassificationError):
                replay.generate_report(
                    self._standard_corpus(),
                    _policies(),
                    classifications=classifications,
                )

    def test_single_non_string_classification_value_is_rejected(self):
        """단독 비문자열(None/int/unhashable)도 전부 명시 거부."""
        for bad in (None, 42, ["v2 bug"]):
            classifications = self._standard_classifications()
            classifications[replay.case_key(4)] = bad
            with self.assertRaises(replay.UnknownClassificationError):
                replay.generate_report(
                    self._standard_corpus(),
                    _policies(),
                    classifications=classifications,
                )

    def test_mixed_type_dangling_keys_are_explicit(self):
        """같은 클래스 결함의 key 측: 비문자열 key(어떤 case_key 와도
        불일치)가 문자열 dangling key 와 섞여도 정렬 TypeError 없이
        DanglingClassificationError."""
        classifications = self._standard_classifications()
        classifications[42] = replay.CLASSIFICATION_V1_BUG
        classifications[replay.case_key(1)] = replay.CLASSIFICATION_V1_BUG
        with self.assertRaises(replay.DanglingClassificationError):
            replay.generate_report(
                self._standard_corpus(),
                _policies(),
                classifications=classifications,
            )

    def test_classification_for_non_mismatch_case_is_rejected(self):
        classifications = self._standard_classifications()
        # line 1 은 match — mismatch 아닌 case 에 분류를 달면 입력 드리프트
        classifications[replay.case_key(1)] = replay.CLASSIFICATION_V1_BUG
        with self.assertRaises(replay.DanglingClassificationError):
            replay.generate_report(
                self._standard_corpus(),
                _policies(),
                classifications=classifications,
            )


class DangerousFalseAllowTest(ReplayFixtureTest):
    """(c) v1 BLOCK → v2 ALLOW 위험 방향 별도 표기·집계 (spec §6.4 §48)."""

    def test_false_allow_mismatch_is_separately_aggregated(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        danger = report["dangerous_false_allow"]
        self.assertEqual(danger["count"], 1)
        self.assertEqual(danger["case_keys"], [replay.case_key(4)])

    def test_false_allow_flag_marks_only_the_dangerous_direction(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        by_key = {entry["case_key"]: entry for entry in report["mismatches"]}
        self.assertTrue(by_key[replay.case_key(4)]["dangerous_false_allow"])
        # v1 ALLOW → v2 BLOCK 은 보수적 방향 — 위험 표기 없음
        self.assertFalse(by_key[replay.case_key(3)]["dangerous_false_allow"])


class InsufficientCaseDataTest(ReplayFixtureTest):
    """(d) v2 평가·대조 재료 결손 → insufficient case data 자동 분류."""

    def test_missing_v1_decision_is_auto_classified(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        by_key = {entry["case_key"]: entry for entry in report["mismatches"]}
        entry = by_key[replay.case_key(5)]
        self.assertEqual(
            entry["classification"], replay.CLASSIFICATION_INSUFFICIENT_CASE_DATA
        )
        self.assertTrue(entry["auto_classified"])
        self.assertIsNone(entry["v2_decision"])
        self.assertTrue(entry["insufficient_reason"])

    def test_missing_event_and_bad_facts_are_auto_classified(self):
        no_event = _case("tool.pre", "ALLOW")
        del no_event["event"]
        bad_facts = _case("tool.pre", "ALLOW")
        bad_facts["facts"] = "not-a-mapping"
        path = self._write_corpus([no_event, bad_facts])
        report = replay.generate_report(path, _policies())
        counts = report["classification_counts"]
        self.assertEqual(
            counts[replay.CLASSIFICATION_INSUFFICIENT_CASE_DATA], 2
        )
        for entry in report["mismatches"]:
            self.assertTrue(entry["auto_classified"])

    def test_explicit_classification_overrides_auto_insufficient(self):
        classifications = self._standard_classifications()
        classifications[replay.case_key(5)] = (
            replay.CLASSIFICATION_INTENTIONAL_POLICY_CHANGE
        )
        report = replay.generate_report(
            self._standard_corpus(), _policies(), classifications=classifications
        )
        by_key = {entry["case_key"]: entry for entry in report["mismatches"]}
        entry = by_key[replay.case_key(5)]
        self.assertEqual(
            entry["classification"],
            replay.CLASSIFICATION_INTENTIONAL_POLICY_CHANGE,
        )
        self.assertFalse(entry["auto_classified"])


class NoFixedThresholdTest(ReplayFixtureTest):
    """(e) 고정 절대 수치 임계 없음 — 집계 사실만, 판정 없음 (spec §48)."""

    _JUDGMENT_KEYS = {
        "verdict",
        "passed",
        "pass",
        "fail",
        "failed",
        "acceptance",
        "accepted",
        "threshold",
        "match_rate",
        "score",
    }

    def _all_keys(self, value):
        keys = set()
        if isinstance(value, dict):
            for key, sub in value.items():
                keys.add(key)
                keys |= self._all_keys(sub)
        elif isinstance(value, list):
            for sub in value:
                keys |= self._all_keys(sub)
        return keys

    def test_report_contains_no_judgment_vocabulary(self):
        report = replay.generate_report(
            self._standard_corpus(),
            _policies(),
            classifications=self._standard_classifications(),
        )
        self.assertFalse(self._all_keys(report) & self._JUDGMENT_KEYS)

    def test_all_mismatch_corpus_still_produces_a_report(self):
        """일치율 0% 라도 리포트 생성은 성공 — 수치 게이트가 없다는 행위 증거."""
        path = self._write_corpus(
            [_case("commit.pre", "ALLOW"), _case("tool.pre", "BLOCK")]
        )
        report = replay.generate_report(
            path,
            _policies(),
            classifications={
                replay.case_key(1): replay.CLASSIFICATION_INTENTIONAL_POLICY_CHANGE,
                replay.case_key(2): replay.CLASSIFICATION_V2_BUG,
            },
        )
        self.assertEqual(report["matches"], 0)
        self.assertEqual(len(report["mismatches"]), 2)


class CorpusFormatTest(ReplayFixtureTest):
    """조용한 부분 로드 금지 — 깨진 줄은 명시 예외."""

    def test_malformed_jsonl_line_is_an_explicit_error(self):
        path = os.path.join(self.tmpdir, corpus.CORPUS_FILENAME)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(_case("tool.pre", "ALLOW")) + "\n")
            handle.write("{not-json\n")
        with self.assertRaises(replay.CorpusFormatError) as ctx:
            replay.generate_report(path, _policies())
        self.assertIn("2", str(ctx.exception))

    def test_non_object_json_line_is_an_explicit_error(self):
        path = os.path.join(self.tmpdir, corpus.CORPUS_FILENAME)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write('["not", "an", "object"]\n')
        with self.assertRaises(replay.CorpusFormatError):
            replay.generate_report(path, _policies())


def _outcome(key, v1, v2, insufficient=False, insufficient_reason=None):
    """replay_corpus 산출물 형태의 outcome dict (폐쇄 7필드 스키마)."""
    return {
        "case_key": key,
        "event": None if insufficient else "tool.pre",
        "v1_decision": v1,
        "v2_decision": None if insufficient else v2,
        "v2_reason": None if insufficient else "fixture reason",
        "insufficient": insufficient,
        "insufficient_reason": insufficient_reason,
    }


class BuildReportInputHardeningTest(unittest.TestCase):
    """웨이브 3 코드 리뷰 1회차 High 회귀 — 공개 `build_report()` 가
    호출자 제공 match 판정을 신뢰해 미분류 0건 계약이 조용히 우회되던
    경로를 봉쇄한다. match 는 항상 v1 vs v2 decision 재계산."""

    def test_forged_matched_field_is_rejected(self):
        """리뷰어 실증 경로 그대로: BLOCK→ALLOW outcome 에 matched=True
        를 실어도 깨끗한 리포트가 나오지 않는다 — 스키마 밖 필드라
        명시 예외. 거짓 필드를 실을 슬롯 자체가 없다."""
        forged = _outcome("line:1", "BLOCK", "ALLOW")
        forged["matched"] = True
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([forged])

    def test_mismatch_is_recomputed_from_decisions(self):
        """matched 필드 없이도 BLOCK→ALLOW 는 재계산으로 mismatch —
        분류가 없으면 미분류 예외로 실패한다 (핵심 계약 유지)."""
        with self.assertRaises(replay.UnclassifiedMismatchError) as ctx:
            replay.build_report([_outcome("line:1", "BLOCK", "ALLOW")])
        self.assertEqual(ctx.exception.case_keys, ["line:1"])

    def test_recomputed_mismatch_lands_in_report_with_danger_flag(self):
        report = replay.build_report(
            [_outcome("line:1", "BLOCK", "ALLOW")],
            classifications={"line:1": replay.CLASSIFICATION_V2_BUG},
        )
        self.assertEqual(report["matches"], 0)
        self.assertEqual(len(report["mismatches"]), 1)
        self.assertEqual(report["dangerous_false_allow"]["count"], 1)

    def test_matching_decisions_count_as_match_without_caller_flag(self):
        report = replay.build_report([_outcome("line:1", "ALLOW", "ALLOW")])
        self.assertEqual(report["matches"], 1)
        self.assertEqual(report["mismatches"], [])

    def test_missing_required_field_is_rejected(self):
        outcome = _outcome("line:1", "ALLOW", "ALLOW")
        del outcome["v1_decision"]
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([outcome])

    def test_decision_outside_vocabulary_is_rejected(self):
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([_outcome("line:1", "PERMIT", "ALLOW")])
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([_outcome("line:1", "ALLOW", "granted")])

    def test_insufficient_outcome_must_not_carry_v2_decision(self):
        """결손 표기로 실제 평가 결과를 숨기는 경로 봉쇄 — insufficient
        outcome 은 v2_decision=None 강제."""
        outcome = _outcome(
            "line:1", "BLOCK", None, insufficient=True,
            insufficient_reason="event field is missing",
        )
        outcome["v2_decision"] = "ALLOW"
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([outcome])

    def test_insufficient_flag_must_be_boolean(self):
        outcome = _outcome("line:1", "ALLOW", "ALLOW")
        outcome["insufficient"] = "no"
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([outcome])

    def test_non_mapping_outcome_is_rejected(self):
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report([42])

    def test_duplicate_case_key_is_rejected(self):
        """중복 key 는 분류 입력의 대응을 모호하게 만든다 — 명시 거부."""
        with self.assertRaises(replay.OutcomeSchemaError):
            replay.build_report(
                [
                    _outcome("line:1", "ALLOW", "ALLOW"),
                    _outcome("line:1", "ALLOW", "ALLOW"),
                ]
            )

    def test_replay_corpus_outcomes_have_no_matched_slot(self):
        """정상 산출 경로에도 matched 슬롯이 없다 — 스키마 자체에서 제거."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, corpus.CORPUS_FILENAME)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps(_case("tool.pre", "ALLOW")) + "\n")
            outcomes = replay.replay_corpus(path, _policies())
        self.assertEqual(len(outcomes), 1)
        self.assertNotIn("matched", outcomes[0])


if __name__ == "__main__":
    unittest.main()
