"""plan Task 3.3 — Evidence 위조 차단 bypass 스위트 (spec §2.2).

covers: agent-written-evidence-file-alone-satisfies-no-requirement

spec §2.2 위협 모델 (원문 인용):
    "Agent 가 Evidence 파일(JSON 등)을 직접 생성하는 것만으로는 어떤
    Requirement 도 충족되지 않는다 — Evidence 는 Rein Runtime 만
    발급한다."

고정하는 계약 — 원장(runtime ledger) 대조 (사용자 결정: 서명 방식이
아니라 발급 원장 대조 우선). 저장 아키텍처 (웨이브 3 리뷰 방향 확정):

- **발급 evidence + 원장의 정본 = 로컬 파일** (LocalStateRoot 하위
  append-only JSONL 쌍 — `evidence.jsonl` + `ledger.jsonl`, 0600,
  git 미추적). Runtime 발급 경로(`record_issued`)만 이 쌍을 함께 쓴다.
- **sqlite 는 evidence 신뢰 경로에서 완전히 빠진다** (3회차 리뷰 방향
  확정 — 무효화 없는 가변 권위 캐시는 §3.8 삭제 전후 등가와 구조적으로
  양립 불가): 어느 sqlite 칸에 무엇을 주입하든, 언제 지우든 평가에
  영향 0 — 본 스위트가 구조적 보장으로 고정한다. `CachedEvidenceSource`
  는 Phase 2 원형(스냅샷성 권위 조회 캐시)으로 남고 이 경로에 배선되지
  않는다.
- 조회(`find`)는 파일 정본의 evidence 를 원장과 대조한다 — 대응 발급
  레코드가 없는 evidence 는 **형식이 Evidence 스키마와 완전히
  일치해도** 불인정이다. 따라서 evidence 저장 형식 파일에 직접 쓴
  위조 라인은 고정 5종 requirement (REQUIREMENT_NAMES) 어느 것도
  충족시키지 못한다.
- 반환 경계 계약: `find` 는 kernel `Evidence` **인스턴스**를 반환한다 —
  registry 배선된 capability 구현체(`CodeReviewRequirement.evaluate`)의
  속성 접근(`record.type`·`subject_matches`)과 그대로 결합된다.
- 실패 방향 (parse/shape/원장 정합성 일관 계층): 정본 파일의 JSON
  parse·라인 shape 실패와 "원장 대응 + 재수화 불가"는 저장 손상 =
  EvidenceStorageError 승격(판단 불능, failure_mode 소관). 파싱은
  정상이지만 원장 미대응이면 위조 의심 제외(보수, 부재 재료).

위협 모델 경계 (차단 대상 아님 — 주석으로만 명시):
    evidence 파일과 원장 파일에 **둘 다** 위조 라인을 쓰는 시나리오는
    이 스위트가 차단을 주장하지 않는다. spec §2.2 — "적대적 우회
    하드닝은 명시적 비범위 (v1 위협 모델 결정 2026-06 계승)". rein 의
    위협 모델은 정상 도구 인터페이스를 쓰는 정직한 Agent 의 규율이며,
    로컬 파일에 임의 쓰기가 가능한 적대자는 어떤 로컬 원장/서명
    체계로도 막을 수 없다 (키도 같은 로컬에 있다). 원장 대조는 "형식
    파일 생성만으로 충족" 이라는 저비용 우회 한 클래스를 닫는 장치다.
"""
import json
import os
import stat
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.capabilities.review.capability import (  # noqa: E402
    FACT_CHANGESET_REVIEW_DIGEST,
    FACT_POLICY_VERSION,
    issue_code_review_evidence,
    register_code_review,
)
from rein.engine import runtime  # noqa: E402
from rein.engine.context import EvidenceStorageError  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
)
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_RUNTIME_VERIFIED,
    evidence_fields,
    evidence_fingerprint,
    issuance_entry,
    issuance_matches,
)
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402
from rein.platform.sqlite import store as sqlite_store  # noqa: E402
from rein.platform.storage import local  # noqa: E402


def _require_policy(requirement_name):
    """requirement 1종을 fail-closed 로 요구하는 policy fixture."""
    return {
        "policy_id": "require-{}".format(requirement_name),
        "fields": kernel_policy.parse_policy(
            "trigger: tool.pre\n"
            "when:\n"
            "  tool: Bash\n"
            "require:\n"
            "  - {}\n"
            "failure_mode: closed\n".format(requirement_name),
            source="<test:require-{}>".format(requirement_name),
        ),
    }


def _forged_record(requirement_name):
    """형식 완전 위조 — Evidence dict 스키마(§3.5 필드 계약) 그대로.

    producer 문자열까지 최상위 신뢰 등급(runtime_verified)을 참칭한다 —
    형식 축으로는 정상 발급 레코드와 구분 불가능한 최악 케이스.
    """
    return {
        "type": requirement_name,
        "subject": "digest:forged-{}".format(requirement_name),
        "result": "PASS",
        "created_at": "2026-08-10T00:00:00+00:00",
        "producer": PRODUCER_RUNTIME_VERIFIED,
        "policy_version": "1",
        "metadata": {},
    }


class _LedgerSourceMixin(unittest.TestCase):
    """파일 정본(LocalStateRoot) + 원장 대조 evidence source 공통 준비."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = local.LocalStateRoot(tmp.name)
        self.root.ensure()
        self.source = sqlite_store.LedgerVerifiedEvidenceSource(self.root)

    def _decide(self, requirement_name, source=None, registry=None, facts=None):
        merged_facts = {"tool": "Bash"}
        merged_facts.update(facts or {})
        return runtime.evaluate(
            "tool.pre",
            merged_facts,
            [_require_policy(requirement_name)],
            evidence_source=source if source is not None else self.source,
            registry=registry,
        )

    def _append_raw(self, path, text):
        """Agent 의 직접 쓰기 시뮬레이션 — runtime 발급 API 를 안 거친다."""
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)

    def _forge_evidence_line(self, requirement_name, fields):
        """evidence 저장 형식 파일에 위조 라인을 직접 append 한다.

        라인 형식은 runtime 이 쓰는 형식과 완전히 일치시킨다 — 형식
        축으로는 구분 불가능한 위조다 (spec §2.2 의 위협 그 자체).
        """
        self._append_raw(
            self.root.evidence_path(),
            json.dumps(
                {
                    sqlite_store.EVIDENCE_LINE_REQUIREMENT: requirement_name,
                    sqlite_store.EVIDENCE_LINE_FIELDS: fields,
                }
            )
            + "\n",
        )


class ForgedEvidenceFileTest(_LedgerSourceMixin):
    """(a) — evidence 저장 형식 파일 직접 생성은 5종 전부 미충족."""

    def test_forged_file_line_satisfies_no_requirement(self):
        for name in REQUIREMENT_NAMES:
            self._forge_evidence_line(name, _forged_record(name))
        # 주입 자체는 실제로 파일에 존재한다 — 아래 미충족이 "주입 실패"
        # 로 공허하게 통과하는 것을 막는 전제 가드
        with open(self.root.evidence_path(), "r", encoding="utf-8") as handle:
            self.assertEqual(
                len(handle.read().splitlines()), len(REQUIREMENT_NAMES)
            )
        for name in REQUIREMENT_NAMES:
            # 원장 대조 실패 → 불인정 (형식 완전 일치와 무관)
            self.assertEqual(self.source.find(name), ())
            decision = self._decide(name)
            self.assertEqual(
                decision["decision"],
                DECISION_BLOCK,
                msg=(
                    "forged evidence file line for {!r} must not satisfy "
                    "the requirement (spec §2.2)".format(name)
                ),
            )

    def test_forged_alongside_issued_only_issued_is_recognized(self):
        # 정상 발급 레코드 옆에 위조 라인을 끼워 넣어도, 인정 범위는
        # 원장 대응이 있는 레코드로 한정된다 (레코드 단위 대조)
        name = "code_review"
        issued = self.source.record_issued(name, _forged_record(name))
        forged = _forged_record(name)
        forged["subject"] = "digest:smuggled"
        self._forge_evidence_line(name, forged)

        self.assertEqual(self.source.find(name), (issued,))
        self.assertEqual(self._decide(name)["decision"], DECISION_ALLOW)

    def test_tampered_issued_record_loses_recognition(self):
        # 발급 후 정본 파일의 필드를 바꾸면(subject 변조) fingerprint 가
        # 달라져 원장 대응이 끊긴다 — 파싱은 정상이므로 손상 승격이
        # 아니라 위조 의심 제외(보수)다. 변조본은 불인정
        name = "tests_passed"
        self.source.record_issued(name, _forged_record(name))
        path = self.root.evidence_path()
        with open(path, "r", encoding="utf-8") as handle:
            line = json.loads(handle.read().splitlines()[0])
        line[sqlite_store.EVIDENCE_LINE_FIELDS]["subject"] = "digest:tampered"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(line) + "\n")

        self.assertEqual(self.source.find(name), ())
        self.assertEqual(self._decide(name)["decision"], DECISION_BLOCK)

    def test_bucket_relabeled_issued_line_is_not_recognized(self):
        # 재리뷰 High 1 (리뷰어 재현 경로) — 정상 발급된 user_approval
        # 라인의 **바깥 bucket 만** tests_passed 로 변조: fields 자체는
        # 무변조라 fingerprint·원장 대응이 살아 있다. 조회 시
        # record.type == requirement bucket 재검증(발급 3중 검증과 대칭)
        # 이 없으면 tests_passed 정책이 ALLOW 되는 교차 인정 구멍
        self.source.record_issued(
            "user_approval", _forged_record("user_approval")
        )
        path = self.root.evidence_path()
        with open(path, "r", encoding="utf-8") as handle:
            line = json.loads(handle.read().splitlines()[0])
        line[sqlite_store.EVIDENCE_LINE_REQUIREMENT] = "tests_passed"
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(line) + "\n")

        self.assertEqual(self.source.find("tests_passed"), ())
        self.assertEqual(
            self._decide("tests_passed")["decision"], DECISION_BLOCK
        )
        # 변조로 라인이 이동했으니 원 bucket 쪽도 부재다 (반사 이익 없음)
        self.assertEqual(self.source.find("user_approval"), ())

    def test_same_size_same_mtime_replacement_is_not_recognized(self):
        # 재리뷰 High 3 — 같은 바이트 길이 + mtime 보존 교체는 stat
        # 서명(mtime_ns, size) 캐시를 통과해 폐기된 evidence 가 계속
        # 인정되는 구멍이었다. mtime 은 invalidation hint 일 뿐 validity
        # 근거가 아니다 — find 는 매 조회 정본을 재읽는다
        name = "code_review"
        issued = self.source.record_issued(name, _forged_record(name))
        self.assertEqual(self.source.find(name), (issued,))

        path = self.root.evidence_path()
        stat_before = os.stat(path)
        with open(path, "r", encoding="utf-8") as handle:
            content = handle.read()
        tampered = content.replace(
            "digest:forged-code_review", "digest:fogred-code_review"
        )
        self.assertEqual(len(tampered), len(content))  # 같은 크기 교체
        self.assertNotEqual(tampered, content)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(tampered)
        os.utime(
            path, ns=(stat_before.st_atime_ns, stat_before.st_mtime_ns)
        )

        self.assertEqual(self.source.find(name), ())
        self.assertEqual(self._decide(name)["decision"], DECISION_BLOCK)


class RuntimeIssuancePathTest(_LedgerSourceMixin):
    """(b) — 원장 기록 동반 발급 경로로 넣은 evidence 만 인정."""

    def test_issued_record_is_recognized_for_every_requirement(self):
        for name in REQUIREMENT_NAMES:
            record = _forged_record(name)  # 내용 동일 — 경로만 다르다
            issued = self.source.record_issued(name, record)
            self.assertEqual(self.source.find(name), (issued,))
            self.assertEqual(self._decide(name)["decision"], DECISION_ALLOW)

    def test_issuance_accepts_kernel_evidence_dataclass(self):
        # Runtime 내부 발급물(kernel Evidence 인스턴스)도 §3.5 필드로
        # 정규화되어 저장·인정된다. 저장 형태는 JSONL 라인(dict), 반환
        # 경계는 Evidence 인스턴스다
        evidence = Evidence(
            type="code_review",
            subject="digest:abc123",
            result="PASS",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_RUNTIME_VERIFIED,
            policy_version="1",
        )
        issued = self.source.record_issued("code_review", evidence)
        self.assertEqual(issued, evidence)
        with open(self.root.evidence_path(), "r", encoding="utf-8") as handle:
            (line,) = handle.read().splitlines()
        self.assertEqual(
            json.loads(line),
            {
                sqlite_store.EVIDENCE_LINE_REQUIREMENT: "code_review",
                sqlite_store.EVIDENCE_LINE_FIELDS: evidence_fields(evidence),
            },
        )
        self.assertEqual(self.source.find("code_review"), (evidence,))

    def test_find_returns_kernel_evidence_instances(self):
        # 반환 경계 계약 — dict 가 아니라 재수화된 Evidence 인스턴스.
        # dict 반환은 capability evaluate 의 record.type 접근에서
        # AttributeError 를 만든다 (부모 barrier 통합 검증에서 실측)
        name = "code_review"
        self.source.record_issued(name, _forged_record(name))
        (record,) = self.source.find(name)
        self.assertIsInstance(record, Evidence)

    def test_issuance_rejects_records_outside_schema(self):
        # 발급 시점 검증 — §3.5 계약을 통과하지 못하는 레코드는 저장
        # 전에 거부된다 (나중에 find 가 손상으로 오인할 반쪽을 안 만든다)
        bad = _forged_record("code_review")
        bad["producer"] = "self_signed"  # PRODUCERS 폐쇄 집합 밖
        with self.assertRaises(ValueError):
            self.source.record_issued("code_review", bad)
        self.assertEqual(self.source.find("code_review"), ())

    def test_issuance_rejects_bucket_type_mismatch(self):
        # 리뷰 지적 A — record.type ≠ requirement bucket 이면 발급 거부.
        # user_approval evidence 를 tests_passed 칸에 넣어 tests_passed
        # 정책을 통과시키는 교차 인정 경로를 발급 시점에 닫는다
        record = _forged_record("user_approval")
        with self.assertRaises(ValueError):
            self.source.record_issued("tests_passed", record)
        self.assertEqual(self.source.find("tests_passed"), ())
        self.assertEqual(self.source.find("user_approval"), ())
        # 거부는 저장 전이다 — 정본 파일에 반쪽 기록이 남지 않는다
        self.assertFalse(os.path.exists(self.root.evidence_path()))
        self.assertFalse(os.path.exists(self.root.ledger_path()))
        self.assertEqual(
            self._decide("tests_passed")["decision"], DECISION_BLOCK
        )

    def test_issuance_rejects_unknown_requirement_bucket(self):
        # 리뷰 지적 A — 고정 5종 밖 bucket 이름은 발급 자체를 거부한다
        record = _forged_record("code_review")
        record["type"] = "custom_gate"
        with self.assertRaises(ValueError):
            self.source.record_issued("custom_gate", record)
        self.assertFalse(os.path.exists(self.root.evidence_path()))

    def test_absent_evidence_stays_absent(self):
        # 원장 계층이 '부재'(정상 조회 0건) 어휘를 바꾸지 않는다
        self.assertEqual(self.source.find("user_approval"), ())
        self.assertEqual(
            self._decide("user_approval")["decision"], DECISION_BLOCK
        )

    @unittest.skipUnless(os.name == "posix", "POSIX 권한 계약 (spec §3.8)")
    def test_state_files_are_created_private(self):
        # 정본 쌍은 신규 생성 시 0600 이어야 한다 (spec §3.8 "신규 로컬
        # 파일 0600" — storage.local 의 0600 계약 재사용을 직접 확인)
        self.source.record_issued("code_review", _forged_record("code_review"))
        for path in (self.root.evidence_path(), self.root.ledger_path()):
            self.assertEqual(
                stat.S_IMODE(os.stat(path).st_mode),
                0o600,
                msg="{} must be created with 0600".format(path),
            )


class LedgerCorrespondenceTest(unittest.TestCase):
    """kernel 순수 함수 — evidence ↔ 발급 레코드 대응 판정 (storage 무관)."""

    def setUp(self):
        self.record = _forged_record("code_review")

    def test_entry_derived_at_issuance_matches_same_record(self):
        entry = issuance_entry(self.record)
        self.assertTrue(issuance_matches(self.record, entry))

    def test_missing_or_degenerate_entry_never_matches(self):
        # 원장 대응 부재(None)·빈 레코드는 보수적으로 불인정 재료다
        self.assertFalse(issuance_matches(self.record, None))
        self.assertFalse(issuance_matches(self.record, {}))
        self.assertFalse(issuance_matches(self.record, "not-a-mapping"))

    def test_entry_of_one_record_does_not_match_another(self):
        other = _forged_record("code_review")
        other["subject"] = "digest:other"
        entry = issuance_entry(self.record)
        self.assertFalse(issuance_matches(other, entry))

    def test_fingerprint_is_stable_across_dict_and_dataclass(self):
        # 발급 시(인스턴스) fingerprint 와 저장 JSON 왕복 후(dict)
        # fingerprint 가 일치해야 대조가 성립한다 — 정규화 대칭성
        evidence = Evidence(
            type="code_review",
            subject="digest:abc123",
            result="PASS",
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_RUNTIME_VERIFIED,
            policy_version="1",
        )
        self.assertEqual(
            evidence_fingerprint(evidence),
            evidence_fingerprint(evidence_fields(evidence)),
        )

    def test_fingerprint_differs_when_any_identity_field_differs(self):
        base = evidence_fingerprint(self.record)
        for field_name, changed in (
            ("type", "security_review"),
            ("subject", "digest:changed"),
            ("result", "NEEDS-FIX"),
            ("created_at", "2026-08-11T00:00:00+00:00"),
            ("producer", "agent_attested"),
            ("policy_version", "2"),
            ("metadata", {"note": "x"}),
        ):
            variant = dict(self.record)
            variant[field_name] = changed
            self.assertNotEqual(
                base,
                evidence_fingerprint(variant),
                msg="field {!r} must participate in the "
                "fingerprint".format(field_name),
            )


class ReviewCapabilityIntegrationTest(_LedgerSourceMixin):
    """registry 배선 + 원장 소스 실결합 관통 (부모 barrier 결함 회귀).

    Task 3.1 산출물(`register_code_review` → `CodeReviewRequirement`)과
    `LedgerVerifiedEvidenceSource` 를 실제
    `runtime.evaluate(..., registry=...)` 로 결합한다. capability 의
    evaluate 는 레코드 **속성 접근**(`record.type`·`record.result`·kernel
    `subject_matches` 의 `.subject`)을 쓰므로, find 의 Evidence 재수화
    반환 계약이 없으면 이 경로는 AttributeError 로 깨진다.
    """

    DIGEST = "digest:integration"

    def setUp(self):
        super().setUp()
        self.registry = RequirementRegistry()
        register_code_review(self.registry)
        self.facts = {
            FACT_CHANGESET_REVIEW_DIGEST: self.DIGEST,
            FACT_POLICY_VERSION: "1",
        }

    def _issue(self, digest=None):
        """실제 Runtime 발급 게이트(Task 3.1)를 지나 원장 동반 저장."""
        digest = digest or self.DIGEST
        evidence = issue_code_review_evidence(
            {"verdict": "PASS", "reviewed_digest": digest},
            current_digest=digest,
            policy_version="1",
        )
        return self.source.record_issued("code_review", evidence)

    def _decide_review(self, facts=None):
        return self._decide(
            "code_review",
            registry=self.registry,
            facts=facts if facts is not None else self.facts,
        )

    def test_issued_evidence_with_matching_digest_allows(self):
        # (i) 정상 발급 + digest fact 일치 → capability 결합 판정 ALLOW
        self._issue()
        self.assertEqual(self._decide_review()["decision"], DECISION_ALLOW)

    def test_forged_injection_blocks_even_with_matching_facts(self):
        # (ii) subject·version 까지 현재 fact 와 일치시킨 최강 위조 —
        # capability 의 digest·version 축은 전부 통과하는 내용이므로,
        # 원장 대조가 유일한 차단 지점이다
        forged = _forged_record("code_review")
        forged["subject"] = self.DIGEST
        forged["result"] = "PASS"
        self._forge_evidence_line("code_review", forged)
        self.assertEqual(self._decide_review()["decision"], DECISION_BLOCK)

    def test_issued_evidence_with_stale_digest_blocks(self):
        # (iii) 발급 evidence 라도 평가 시점 digest fact 와 불일치(발급 후
        # 코드 수정)면 미충족 — 원장 인정이 validity 축을 대체하지 않는다
        self._issue(digest="digest:reviewed-then-edited")
        self.assertEqual(self._decide_review()["decision"], DECISION_BLOCK)


class StorageCorruptionTest(_LedgerSourceMixin):
    """리뷰 지적 C — 정본 손상은 판단 불능(EvidenceStorageError) 승격.

    일관 계층: 정본 파일의 parse·shape 실패와 "원장 대응 + 재수화 불가"
    는 저장 손상(판단 불능 — failure_mode 소관)이고, 파싱 정상 + 원장
    미대응은 위조 의심 제외(보수 — 부재 재료)다. 손상을 조용히 제외하면
    '위조 주입'과 '손상'이 섞여 부재 위장이 된다 (spec §3.4 부재 ≠
    판단 불능).
    """

    def _assert_escalates(self, requirement_name="code_review"):
        with self.assertRaises(EvidenceStorageError):
            self.source.find(requirement_name)
        # failure_mode 관통 — 판단 불능은 fail-closed BLOCK 으로 수렴하되
        # 사유가 '부재'(missing evidence)가 아니라 evaluation failure 다
        decision = self._decide(requirement_name)
        self.assertEqual(decision["decision"], DECISION_BLOCK)
        self.assertIn("evaluation failure", decision["reason"])

    def test_broken_json_evidence_line_escalates(self):
        self.source.record_issued(
            "code_review", _forged_record("code_review")
        )
        self._append_raw(self.root.evidence_path(), "{not-json\n")
        self._assert_escalates()

    def test_broken_json_ledger_line_escalates(self):
        self.source.record_issued(
            "code_review", _forged_record("code_review")
        )
        self._append_raw(self.root.ledger_path(), "{not-json\n")
        self._assert_escalates()

    def test_non_mapping_evidence_line_escalates(self):
        self._append_raw(
            self.root.evidence_path(), json.dumps("just-a-string") + "\n"
        )
        self._assert_escalates()

    def test_malformed_evidence_line_shape_escalates(self):
        # requirement/fields 키 결손 라인은 runtime 이 쓸 수 없는 형태 —
        # 조용히 건너뛰면 손상이 부재로 위장되므로 승격한다
        self._append_raw(
            self.root.evidence_path(), json.dumps({"weird": True}) + "\n"
        )
        self._assert_escalates()

    def test_undecodable_evidence_file_escalates(self):
        # 재리뷰 Medium — UTF-8 로 decode 되지 않는 정본은 parse 실패와
        # 같은 손상 계층이다 (UnicodeDecodeError 도 판단 불능으로 번역)
        with open(self.root.evidence_path(), "wb") as handle:
            handle.write(b"\xff\xfe\x00garbage")
        self._assert_escalates()

    @unittest.skipUnless(os.name == "posix", "권한 기반 OSError 주입")
    def test_unreadable_evidence_file_escalates(self):
        # 손상 4종 중 OSError 축 — 정본을 읽을 수 없으면 판단 재료 확보
        # 실패 = 판단 불능이다 (부재로 위장 금지)
        self.source.record_issued(
            "code_review", _forged_record("code_review")
        )
        path = self.root.evidence_path()
        os.chmod(path, 0)
        self.addCleanup(os.chmod, path, 0o600)
        self._assert_escalates()

    def test_ledger_matched_unrehydratable_record_escalates(self):
        # 원장 대응인데 §3.5 재수화 불가 — 발급 시점 검증(record_issued)
        # 을 통과한 레코드만 정본에 저장되므로 이 상태는 정상 경로가
        # 만들 수 없다 = 저장 손상. 아래에서 원장 라인을 테스트가 직접
        # 쓰는 것은 손상 상태의 기계적 재현이다 (evidence+원장 동시
        # 위조 — 위협 모델 밖 — 와 기계적으로 같지만, 여기서 고정하는
        # 계약은 "손상을 부재로 위장하지 않는다" 는 실패 방향이다)
        bad = _forged_record("code_review")
        bad["producer"] = "self_signed"  # Evidence 재수화가 거부하는 값
        self._append_raw(
            self.root.ledger_path(), json.dumps(issuance_entry(bad)) + "\n"
        )
        self._forge_evidence_line("code_review", bad)
        self._assert_escalates()


class SqliteExclusionTest(_LedgerSourceMixin):
    """3회차 방향 확정 — evidence 신뢰 경로에서 sqlite **완전 제거**.

    무효화 배선 없는 가변 권위 캐시는 §3.8 삭제 전후 등가와 구조적으로
    양립 불가다 (3회차 리뷰 실증 2건: 교차-bucket 캐시 슬롯 서빙,
    채워진 슬롯이 이후 발급을 가림). 구멍별 패치 대신 증거 서빙 경로를
    `LedgerVerifiedEvidenceSource` 단독(파일 정본 매 조회 재읽기)으로
    고정한다 — **sqlite 에 무엇이 있든, 언제 지우든 평가에 영향 0**
    이 구조적 보장이다. `CachedEvidenceSource` 는 Phase 2 원형(스냅샷성
    권위 조회 캐시)으로 원복됐고 evidence 신뢰 경로에 배선되지 않는다.
    """

    def setUp(self):
        super().setUp()
        self.db_path = self.root.database_path()
        self.store = sqlite_store.SqliteStore.open(self.db_path)
        self.addCleanup(lambda: self.store.close())

    def test_cross_bucket_cache_slot_injection_has_no_effect(self):
        # 3회차 리뷰어 재현 1 — **정상 발급된** user_approval 레코드를
        # tests_passed 캐시 슬롯에 주입: 원장 대응이 살아 있는 진짜
        # 레코드라 fingerprint 검증으로는 못 거른다. 증거 경로가 sqlite
        # 를 아예 읽지 않으므로 교차 인정이 성립하지 않는다
        issued = self.source.record_issued(
            "user_approval", _forged_record("user_approval")
        )
        self.store.put(
            sqlite_store.SECTION_EVIDENCE_INDEX,
            "tests_passed",
            [evidence_fields(issued)],
        )
        self.assertEqual(self.source.find("tests_passed"), ())
        self.assertEqual(
            self._decide("tests_passed")["decision"], DECISION_BLOCK
        )
        # 원 bucket 은 정본 기준 그대로 인정된다
        self.assertEqual(self.source.find("user_approval"), (issued,))

    def test_forged_records_in_any_section_have_no_effect(self):
        # 어느 sqlite 칸에 형식 완전 위조를 주입해도 decision 은 파일
        # 정본 기준으로 유지된다 (미발급 → BLOCK)
        name = "tests_passed"
        for section in sqlite_store.SECTIONS:
            self.store.put(section, name, [_forged_record(name)])
        self.assertEqual(self.source.find(name), ())
        self.assertEqual(self._decide(name)["decision"], DECISION_BLOCK)

    def test_later_issuance_is_recognized_immediately(self):
        # 3회차 리뷰어 재현 2 의 교정 방향 — X 발급 → 조회(웜업) → Y
        # 발급 → **즉시** X+Y 인정. 캐시가 없으므로 "sqlite 를 지워야
        # 보이는 evidence" 라는 상태 자체가 존재하지 않는다
        name = "code_review"
        x = self.source.record_issued(name, _forged_record(name))
        self.assertEqual(self.source.find(name), (x,))  # 웜업 조회
        y = self.source.record_issued(
            name, dict(_forged_record(name), subject="digest:second")
        )
        self.assertEqual(self.source.find(name), (x, y))
        self.assertEqual(self._decide(name)["decision"], DECISION_ALLOW)

    def test_sqlite_disposal_never_changes_decision(self):
        # §3.8 등가 — 부재 시점에도, 발급 후에도, sqlite 삭제는 decision
        # 을 바꾸지 못한다 (증거 경로가 sqlite 를 읽지 않으므로 자명하고,
        # 이 테스트는 그 구조가 후퇴하지 않게 고정한다)
        name = "security_review"
        absent_before = self._decide(name)
        self.assertEqual(absent_before["decision"], DECISION_BLOCK)
        sqlite_store.remove_store_files(self.db_path)
        self.assertEqual(self._decide(name), absent_before)

        issued_before = None
        self.source.record_issued(name, _forged_record(name))
        issued_before = self._decide(name)
        self.assertEqual(issued_before["decision"], DECISION_ALLOW)
        sqlite_store.remove_store_files(self.db_path)
        self.assertEqual(self._decide(name), issued_before)

    def test_state_root_disposal_converges_to_absence(self):
        # 별개 시나리오 — 정본 파일까지 지우면 부재(정상 BLOCK, 재발급
        # 요구)로 수렴한다. 정본은 로컬 전용 산출물이고 (spec §2.3 —
        # Ledger·Runtime Evidence Index 는 git 동기화 안 함) 프로젝트의
        # 영구 SoT 가 아니므로, 이 소실은 계약 위반이 아니라 "발급을
        # 다시 받아라" 는 보수적 수렴이다
        name = "code_review"
        self.source.record_issued(name, _forged_record(name))
        self.assertEqual(len(self.source.find(name)), 1)

        os.remove(self.root.evidence_path())
        os.remove(self.root.ledger_path())
        fresh = sqlite_store.LedgerVerifiedEvidenceSource(self.root)
        self.assertEqual(fresh.find(name), ())
        self.assertEqual(
            self._decide(name, source=fresh)["decision"], DECISION_BLOCK
        )


class _StubAuthority:
    """스냅샷성 권위 소스 스텁 — 같은 입력에 같은 답."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        return self._records


class CachedSourceCorruptionDegradationTest(unittest.TestCase):
    """Phase 2 원형 `CachedEvidenceSource` 의 손상 강등 (2회차 Medium 유지).

    verify 조합은 3회차에서 구조적으로 제거됐다 — 이 테스트는 남은
    원형의 "캐시 손상(형태 포함) = 권위 소스 강등" 계약만 고정한다.
    evidence 신뢰 경로가 아니다 (그 경로는 SqliteExclusionTest).
    """

    def test_scalar_cache_slot_degrades_to_authority(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = local.LocalStateRoot(tmp.name)
        root.ensure()
        store = sqlite_store.SqliteStore.open(root.database_path())
        self.addCleanup(store.close)

        records = ({"type": "code_review", "result": "PASS"},)
        source = sqlite_store.CachedEvidenceSource(
            store, _StubAuthority(records)
        )
        # scalar 캐시 값: tuple(42) 는 TypeError — miss 강등으로 권위
        # 소스 결과가 서빙돼야 한다 (raw TypeError 전파 금지)
        store.put(sqlite_store.SECTION_EVIDENCE_INDEX, "code_review", 42)
        self.assertEqual(source.find("code_review"), records)


if __name__ == "__main__":
    unittest.main()
