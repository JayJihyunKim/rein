"""plan Task 2.7 (p2-shadow-capture) — Corpus 반입 Sanitization Validation.

covers: corpus-import-rejects-cases-failing-sanitization-validation

고정하는 계약 (spec §6.4):
- token/password/secret/authorization header/private path/email/
  API key/URL credential 8 categories 중 하나라도 검출되면 반입
  거부 — 조용한 필터링이 아니라 `CorpusImportRejected` 명시 예외.
- 검증 통과 case 만 corpus 파일(`shadow-corpus.jsonl`)에 append 된다.
- 저장은 `platform.storage.local` 의 0600 계약을 재사용한다.
- 모든 파일 생성은 temp 디렉토리 한정 (저장소 트리 잔여물 0).

주의: 본 파일의 모든 secret 값은 명백한 가짜 상수다 (fake-/FAKE 접두).
"""
import json
import os
import stat
import sys
import tempfile
import time
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.shadow import capture  # noqa: E402
from rein.shadow import corpus  # noqa: E402
from rein.shadow import paths  # noqa: E402

FAKE_PAT = "ghp_FAKETOKENabcdef1234567890"
FAKE_PASSWORD = "fakeS3cretPW"
FAKE_SECRET = "fake-secret-value-772"


def _mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class SanitizationValidationRejectionTest(unittest.TestCase):
    """(b) 민감정보 포함 케이스 주입 → 반입 거부."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.project_root = tmp.name

    def _corpus_file_absent_or_empty(self):
        path = os.path.join(
            self.project_root, ".rein", "state", corpus.CORPUS_FILENAME
        )
        self.assertFalse(
            os.path.exists(path) and os.path.getsize(path) > 0,
            "rejected import must not write to the corpus file",
        )

    def test_token_in_facts_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {"note": "token={}".format(FAKE_SECRET)},
            "command": {"type": "ls", "redacted": "ls -la"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        categories = {v["category"] for v in ctx.exception.violations}
        self.assertIn(corpus.CATEGORY_CREDENTIAL, categories)
        self._corpus_file_absent_or_empty()

    def test_password_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {},
            "command": {
                "type": "curl",
                "redacted": "curl --password {} host".format(FAKE_PASSWORD),
            },
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected):
            corpus.import_case(case, self.project_root)
        self._corpus_file_absent_or_empty()

    def test_secret_keyword_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {"env": "API_SECRET={}".format(FAKE_SECRET)},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected):
            corpus.import_case(case, self.project_root)
        self._corpus_file_absent_or_empty()

    def test_authorization_header_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {},
            "command": {
                "type": "curl",
                "redacted": "curl -H 'Authorization: Bearer {}' host".format(
                    FAKE_SECRET
                ),
            },
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected):
            corpus.import_case(case, self.project_root)
        self._corpus_file_absent_or_empty()

    def test_api_key_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {"env": "API_KEY={}".format(FAKE_SECRET)},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected):
            corpus.import_case(case, self.project_root)
        self._corpus_file_absent_or_empty()

    def test_url_credential_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {},
            "command": {
                "type": "git.push",
                "redacted": "git push https://alice:{}@github.com/org/repo.git".format(
                    FAKE_PASSWORD
                ),
            },
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected):
            corpus.import_case(case, self.project_root)
        self._corpus_file_absent_or_empty()

    def test_email_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {"reporter": "someone@example.com"},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        categories = {v["category"] for v in ctx.exception.violations}
        self.assertIn(corpus.CATEGORY_EMAIL, categories)
        self._corpus_file_absent_or_empty()

    def test_private_path_is_rejected(self):
        for path_value in (
            "/Users/alice/secret-project",
            "/home/bob/.ssh/id_rsa",
            r"C:\Users\carol\AppData",
        ):
            with self.subTest(path_value=path_value):
                case = {
                    "event": "tool.pre",
                    "facts": {"path": path_value},
                    "command": {"type": "ls", "redacted": "ls"},
                    "project_state": {},
                    "v1_decision": "ALLOW",
                    "v1_reason": "",
                }
                with self.assertRaises(corpus.CorpusImportRejected) as ctx:
                    corpus.import_case(case, self.project_root)
                categories = {v["category"] for v in ctx.exception.violations}
                self.assertIn(corpus.CATEGORY_PRIVATE_PATH, categories)
        self._corpus_file_absent_or_empty()

    def test_tilde_home_path_is_rejected(self):
        # 코드 리뷰 Medium (2026-08-09): `~/secrets/deploy_key` 같은
        # POSIX 관용 표기가 /Users, /home, /root, C:\Users 4가지 기존
        # 패턴 어디에도 안 걸려 검출을 통과했다.
        for path_value in (
            "~/secrets/deploy_key",
            "~/.ssh/id_rsa",
            "~alice/private/notes.txt",
        ):
            with self.subTest(path_value=path_value):
                case = {
                    "event": "tool.pre",
                    "facts": {"path": path_value},
                    "command": {"type": "ls", "redacted": "ls"},
                    "project_state": {},
                    "v1_decision": "ALLOW",
                    "v1_reason": "",
                }
                with self.assertRaises(corpus.CorpusImportRejected) as ctx:
                    corpus.import_case(case, self.project_root)
                categories = {v["category"] for v in ctx.exception.violations}
                self.assertIn(corpus.CATEGORY_PRIVATE_PATH, categories)
        self._corpus_file_absent_or_empty()

    def test_private_path_lookalikes_are_not_false_positives(self):
        case = {
            "event": "tool.pre",
            "facts": {
                "note": (
                    "mounted /rootfs read-only, see /rootcause docs; "
                    "a~b is not a path; unlimited ~ish scope; "
                    "about ~5/10 chance; roughly ~a dozen items"
                )
            },
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        # should not raise
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))

    def test_rejection_message_contains_field_and_category(self):
        case = {
            "event": "tool.pre",
            "facts": {"note": "token={}".format(FAKE_SECRET)},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        message = str(ctx.exception)
        self.assertIn(corpus.CATEGORY_CREDENTIAL, message)
        # 최상위 필드 이름은 남고, 중첩 key 이름은 위치 표기로 대체된다
        # (2026-08-10 security review Low-2 — 거부 사유가 caller 데이터를
        # 되뿜지 않도록 라벨 생성을 데이터와 분리했다. 상세 근거는
        # `corpus._iter_string_fields` docstring).
        self.assertIn("facts.<key:0>", message)
        self.assertNotIn("note", message)

    def test_capture_output_of_a_leaky_command_still_passes_because_capture_already_masked(
        self,
    ):
        # capture() 가 이미 §6.4 예시를 마스킹했으므로, 그 산출물은 corpus
        # 반입 검증도 통과해야 한다 (capture -> corpus 파이프라인 정합성).
        case = capture.capture(
            event="tool.pre",
            command_text="git push https://{}@github.com/org/repo.git".format(
                FAKE_PAT
            ),
            v1_decision="ALLOW",
            v1_reason="ok",
        )
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))

    def test_bare_keyword_value_in_v1_reason_is_rejected(self):
        # 보안 리뷰 High-1 — capture 경유 통합 확인. 이전엔 v1_reason 의
        # 구분자 없는 `token X` 형태가 masking.mask() 어디에도 안 걸려
        # corpus 반입까지 그대로 통과(디스크 평문 기록)했다. masking.py
        # 수정(신규 `_BARE_KEYWORD_VALUE` 규칙) 이후에는 capture() 단계
        # 에서 이미 마스킹되므로, capture 산출물을 corpus 에 반입해도
        # 위반이 없어야 한다(=capture 가 제 역할을 한다는 통합 증거).
        case = capture.capture(
            event="tool.pre",
            command_text="ls -la",
            v1_reason="blocked: token {} detected in argument".format(FAKE_PAT),
        )
        self.assertNotIn(FAKE_PAT, case.v1_reason)
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))

    def test_bare_keyword_value_directly_in_corpus_dict_is_rejected(self):
        # capture() 를 거치지 않고 caller 가 직접 만든 dict 도 corpus 의
        # 독립 두 번째 관문에서 잡혀야 한다(capture 신뢰 전제 없음).
        case = {
            "event": "tool.pre",
            "facts": {},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "BLOCK",
            "v1_reason": "blocked: token {} detected in argument".format(FAKE_PAT),
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        categories = {v["category"] for v in ctx.exception.violations}
        self.assertIn(corpus.CATEGORY_CREDENTIAL, categories)
        self._corpus_file_absent_or_empty()


class OversizedFieldRejectionTest(unittest.TestCase):
    """보안 리뷰 High-2(b) — facts/project_state/v1_reason 길이 상한 부재.

    상한 초과 필드는 **거부**한다(절단해서 그대로 쓰지 않는다) — R1-B
    의 교훈("조용한 절단으로 비밀값 조각이 남는 실수를 반복하지 말 것")
    을 corpus.py 쪽에서도 지킨다. 근거는 `corpus.MAX_FIELD_CHARS`
    정의부 주석 참조.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.project_root = tmp.name

    def _corpus_file_absent_or_empty(self):
        path = os.path.join(
            self.project_root, ".rein", "state", corpus.CORPUS_FILENAME
        )
        self.assertFalse(
            os.path.exists(path) and os.path.getsize(path) > 0,
            "rejected import must not write to the corpus file",
        )

    def test_field_over_cap_is_rejected(self):
        case = {
            "event": "tool.pre",
            "facts": {"note": "a" * (corpus.MAX_FIELD_CHARS + 1)},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        categories = {v["category"] for v in ctx.exception.violations}
        self.assertEqual(categories, {corpus.CATEGORY_OVERSIZED_FIELD})
        self._corpus_file_absent_or_empty()

    def test_field_exactly_at_cap_is_accepted(self):
        case = {
            "event": "tool.pre",
            "facts": {"note": "a" * corpus.MAX_FIELD_CHARS},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        self.assertEqual(corpus.validate_case(case), [])
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))

    def test_secret_straddling_the_cap_boundary_leaves_no_fragment_on_disk(self):
        # R1-B 회귀 방지 — 상한을 넘는 필드에 secret 이 경계에 걸쳐
        # 있어도(마치 이전 라운드의 truncation-order 버그처럼), "절단
        # 해서 일부만 저장" 이 아니라 "레코드 전체를 거부" 하므로 파일에
        # 어떤 조각도 남지 않는다.
        padding = "a" * (corpus.MAX_FIELD_CHARS - 10)
        straddling_secret = padding + "token=" + FAKE_SECRET
        self.assertGreater(len(straddling_secret), corpus.MAX_FIELD_CHARS)
        case = {
            "event": "tool.pre",
            "facts": {"note": straddling_secret},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        with self.assertRaises(corpus.CorpusImportRejected) as ctx:
            corpus.import_case(case, self.project_root)
        categories = {v["category"] for v in ctx.exception.violations}
        self.assertEqual(categories, {corpus.CATEGORY_OVERSIZED_FIELD})
        self._corpus_file_absent_or_empty()

    def test_command_field_truncated_by_capture_stays_under_cap_and_is_accepted(
        self,
    ):
        # capture.py 는 command.redacted 를 MAX_COMMAND_CHARS(4096) +
        # TRUNCATION_MARKER(13자) ≈ 4109자까지 정상적으로 절단해 넘길 수
        # 있다 — corpus 의 MAX_FIELD_CHARS(8192) 가 그보다 낮으면 정상
        # 절단된 command 조차 매번 거부당하는 회귀가 생긴다. 여기서
        # 그 여유가 실제로 확보돼 있는지 고정한다.
        huge_command = "echo " + ("x" * (capture.MAX_COMMAND_CHARS * 3))
        case = capture.capture(event="tool.pre", command_text=huge_command)
        self.assertIn(capture.TRUNCATION_MARKER, case.command["redacted"])
        self.assertLessEqual(
            len(case.command["redacted"]), corpus.MAX_FIELD_CHARS
        )
        self.assertEqual(corpus.validate_case(case), [])
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))


class CleanCaseImportTest(unittest.TestCase):
    """검증 통과 case 는 corpus 파일에 append 된다 (0600, temp 한정)."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.project_root = tmp.name

    def _clean_case(self, note="ok"):
        return {
            "event": "tool.pre",
            "facts": {"note": note},
            "command": {"type": "ls", "redacted": "ls -la"},
            "project_state": {"branch": "dev"},
            "v1_decision": "ALLOW",
            "v1_reason": "no issues",
        }

    def test_validate_case_returns_empty_list_for_clean_case(self):
        self.assertEqual(corpus.validate_case(self._clean_case()), [])

    def test_clean_case_is_written_as_jsonl(self):
        path = corpus.import_case(self._clean_case(), self.project_root)
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
        self.assertEqual(len(lines), 1)
        parsed = json.loads(lines[0])
        self.assertEqual(parsed["event"], "tool.pre")

    def test_multiple_imports_append_not_overwrite(self):
        corpus.import_case(self._clean_case("first"), self.project_root)
        path = corpus.import_case(self._clean_case("second"), self.project_root)
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
        self.assertEqual(len(lines), 2)
        notes = [json.loads(line)["facts"]["note"] for line in lines]
        self.assertEqual(notes, ["first", "second"])

    @unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약")
    def test_corpus_file_is_created_with_mode_0600(self):
        path = corpus.import_case(self._clean_case(), self.project_root)
        self.assertEqual(_mode(path), 0o600)

    def test_shadow_case_object_accepted_directly(self):
        case = capture.capture(event="tool.pre", command_text="ls -la")
        path = corpus.import_case(case, self.project_root)
        self.assertTrue(os.path.exists(path))


def _build_email_redos_repro(n):
    """리뷰어 원 재현 형태 — `@` 하나 + 유효한 TLD 로 끝나지 않는 도메인
    모양 구간(길이 n). 수정 전 `_EMAIL.search()` 단독 호출 기준 n=500
    →1000→2000→4000 에서 ≈4배씩 증가(2차)했던 구성 그대로."""
    return "x@" + ("a." * n) + "!"


def _build_email_no_at_worst_case(n):
    """`@` 가 전혀 없는 순수 반복 문자열 — 도메인 구조 수정만으로는 안
    잡히는 두 번째(더 근본적인) 원인(local-part 문자클래스가 뒤이어 `@`
    를 못 찾을 때 모든 시작 위치에서 재시도)을 단독으로 겨냥한다."""
    return "a" * n


def _build_email_many_at_worst_case(n):
    """`@` 가 매우 많은(문자열 절반) 최악 케이스 — `_contains_email()` 의
    while 루프가 `@` 개수만큼 반복하므로, `@` 개수 자체가 O(n) 일 때도
    전체가 선형을 유지하는지 확인한다(각 반복이 고정 폭 window 만 스캔
    하므로 총합은 O(n) 이어야 한다)."""
    return "a@" * (n // 2)


class CorpusValidationRedosScalingTest(unittest.TestCase):
    """보안 리뷰 High-2 — corpus 검증 경로 전체를 대상으로 한 스케일링
    회귀. `_EMAIL`/`_contains_email` 자체(정규식·window 스캔 구조 수정
    검증, 상한 게이트를 우회해 직접 호출)와 `_PRIVATE_PATH`(이전 라운드
    수정 대상, 이번 리뷰가 놓치지 않았는지 재확인) 양쪽을 n=20k/40k/
    80k/200k 에서 측정한다. 판정 방식은 masking.py 쪽 스케일링 테스트와
    동일(n/2n 비율 ~2.0, 임계값 3.0)."""

    _SIZES = (20000, 40000, 80000, 200000)

    def _assert_linear(self, timed_fn, label):
        timed_fn(2000)  # warm-up

        timings = [timed_fn(n) for n in self._SIZES]
        if timings[0] <= 0:
            self.skipTest("측정 해상도 부족 (t=0) — 환경 재시도 필요")

        for i in range(len(self._SIZES) - 1):
            ratio = timings[i + 1] / timings[i] if timings[i] > 0 else 0
            self.assertLess(
                ratio, 3.0,
                "%s n=%d→%d 비율 %.2f — 선형이면 ~2.0, 2차 회귀면 ~4.0 근방"
                " (t=%.5fs/%.5fs)"
                % (label, self._SIZES[i], self._SIZES[i + 1], ratio,
                   timings[i], timings[i + 1]),
            )
        self.assertLess(
            timings[-1], 5.0,
            "%s n=%d 절대시간 %.2fs — ReDoS 회귀 의심"
            % (label, self._SIZES[-1], timings[-1]),
        )

    def _timed(self, fn, builder):
        def _run(n):
            text = builder(n)
            start = time.perf_counter()
            fn(text)
            return time.perf_counter() - start
        return _run

    def test_contains_email_scales_linearly_on_redos_repro(self):
        self._assert_linear(
            self._timed(corpus._contains_email, _build_email_redos_repro),
            "_contains_email(redos_repro)",
        )

    def test_contains_email_scales_linearly_with_no_at_sign(self):
        # 도메인 구조 수정만으로는 안 잡히던 두 번째 원인 전용 재현.
        self._assert_linear(
            self._timed(corpus._contains_email, _build_email_no_at_worst_case),
            "_contains_email(no_at)",
        )

    def test_contains_email_scales_linearly_with_many_at_signs(self):
        self._assert_linear(
            self._timed(corpus._contains_email, _build_email_many_at_worst_case),
            "_contains_email(many_at)",
        )

    def test_private_path_scales_linearly(self):
        # 이전 라운드(물결표 경로 검출) 수정 대상 — 이번 리뷰가 명시
        # 지목하지 않았지만 "corpus 검증 경로 전체" 요구사항에 따라
        # 함께 재확인한다.
        # 규칙 자체는 2026-08-10 부터 `rein.shadow.paths` SSOT 소유다
        # (수집 단계 경로 축약과 정의를 공유) — 검증 경로의 스케일링
        # 요구는 그대로이므로 대상 심볼만 SSOT 로 옮겨 유지한다.
        self._assert_linear(
            self._timed(
                lambda t: paths.PRIVATE_PATH.search(t),
                lambda n: "~" + ("a" * n),
            ),
            "PRIVATE_PATH(tilde_no_slash)",
        )

    def test_find_violations_end_to_end_is_fast_at_review_requested_scale(self):
        # review 의 정확한 재현 형태("30KB 평범한 점 포함 텍스트, 비밀값
        # 0")를 확장한 버전 — n=20k/40k/80k/200k 는 전부 MAX_FIELD_CHARS
        # (8192) 를 넘으므로, 실전에서는 정규식이 아니라 길이 상한이
        # 먼저 이 필드를 거부해 빠르다(방어적 격리가 실제로 작동함을
        # 확인 — 정규식 자체의 선형성은 위 `_contains_email`/
        # `_PRIVATE_PATH` 전용 테스트가 별도로 증명한다).
        normal_sentence = "This is a normal sentence with many dots. "
        for n in self._SIZES:
            text = (normal_sentence * ((n // len(normal_sentence)) + 1))[:n]
            case_dict = {
                "event": "tool.pre",
                "facts": {"note": text},
                "command": {"type": "ls", "redacted": "ls"},
                "project_state": {},
                "v1_decision": "ALLOW",
                "v1_reason": "",
            }
            start = time.perf_counter()
            violations = corpus.find_violations(case_dict)
            elapsed = time.perf_counter() - start
            self.assertLess(
                elapsed, 1.0,
                "find_violations n=%d 가 %.2fs 소요 — 성능 회귀 의심"
                % (n, elapsed),
            )
            self.assertEqual(
                {v["category"] for v in violations},
                {corpus.CATEGORY_OVERSIZED_FIELD},
            )

    def test_find_violations_end_to_end_is_fast_under_the_cap_with_clean_content(
        self,
    ):
        # 상한 아래(정규식이 실제로 끝까지 스캔하는 경로)에서도 정상
        # 텍스트(secret 없음)에 대해 빠르고 위반 없이 통과하는지 확인 —
        # 리뷰가 정확히 묘사한 "30KB 평범한 점 포함 텍스트" 형태를
        # 상한 이하 크기로 축소해 재현(원문은 상한에 걸려 다른 사유로
        # 거부되므로, "정규식 자체가 빠르고 정확하다" 를 보이려면 상한
        # 아래 크기가 필요하다).
        normal_sentence = "This is a normal sentence with many dots. "
        text = (normal_sentence * ((corpus.MAX_FIELD_CHARS // len(normal_sentence))))
        text = text[: corpus.MAX_FIELD_CHARS]
        case_dict = {
            "event": "tool.pre",
            "facts": {"note": text},
            "command": {"type": "ls", "redacted": "ls"},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
        }
        start = time.perf_counter()
        violations = corpus.find_violations(case_dict)
        elapsed = time.perf_counter() - start
        self.assertLess(elapsed, 1.0, "%.2fs 소요 — 성능 회귀 의심" % elapsed)
        self.assertEqual(violations, [])


if __name__ == "__main__":
    unittest.main()
