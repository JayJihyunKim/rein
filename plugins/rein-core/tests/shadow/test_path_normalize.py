"""Shadow 수집 경로 정규화 — 홈 절대경로 레코드 전량 거부 수리.

covers: shadow-capture-stores-masked-representation-never-raw-commands-from-capture-stage
covers: corpus-import-rejects-cases-failing-sanitization-validation

고정하는 계약:
- 수집 단계가 프로젝트 루트 하위 절대경로를 **프로젝트 기준 상대경로**로,
  프로젝트 밖 홈 경로를 **사용자명만 치환한 형태**(`<HOME>/…`)로 축약한다.
- 축약 결과는 corpus 반입 검증(spec §6.4 private path)을 통과한다 —
  즉 절대경로를 담은 레코드가 실제로 파일에 기록된다.
- 검증기의 거부 동작 자체는 불변 — 축약을 거치지 않은 원문 절대경로는
  여전히 거부된다 (최후 관문 유지).
- 사적 경로 규칙은 **단일 정의**를 검출·정규화 양쪽이 소비한다
  (규칙이 갈라지는 결함 클래스 재발 방지).

이 결함이 Phase 2 테스트를 통과했던 원인은 "임시 디렉토리가 `/Users`
밖이라 홈 경로 형태가 재현되지 않음" 이었다. 따라서 관통 테스트는
임시 디렉토리 **안에** `Users/<name>` 세그먼트를 만들어 홈 하위 프로젝트를
실제로 재현한다 (경로 문자열이 `/Users/<name>/…` 를 포함하게 된다).
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

from rein.shadow import capture  # noqa: E402
from rein.shadow import corpus  # noqa: E402
from rein.shadow import paths  # noqa: E402

FAKE_PAT = "ghp_FAKETOKENabcdef1234567890"


class NormalizeRewritesProjectPathsRelative(unittest.TestCase):
    """프로젝트 루트 하위 경로 → 루트 기준 상대경로."""

    ROOT = "/Users/testuser/dreamline/rein-dev"

    def test_project_subpath_becomes_relative(self):
        out = paths.normalize(
            self.ROOT + "/plugins/rein-core/rein/shadow/corpus.py", self.ROOT
        )
        self.assertEqual(out, "plugins/rein-core/rein/shadow/corpus.py")

    def test_project_root_itself_becomes_dot(self):
        self.assertEqual(paths.normalize(self.ROOT, self.ROOT), ".")

    def test_project_root_with_trailing_slash_becomes_dot_not_empty(self):
        """`<root>/` 도 `.` 이다 — 빈 문자열은 "값 없음" 과 구분되지 않는다.

        code review Medium (4회차): 접두 제거가 슬래시 뒤 내용 유무를 보지
        않아 `<root>/` 가 통째로 사라졌다. `cd <root>/ && …` 같은 흔한
        관용구에서 디렉토리 신호가 조용히 소실됐다.
        """
        self.assertEqual(paths.normalize(self.ROOT + "/", self.ROOT), ".")
        self.assertEqual(
            paths.normalize("cd " + self.ROOT + "/ && npm test", self.ROOT),
            "cd . && npm test",
        )

    def test_trailing_slash_root_value_survives_capture(self):
        case = capture.capture(
            event="e", facts={"cwd": self.ROOT + "/"}, project_root=self.ROOT
        )
        self.assertEqual(case.facts["cwd"], ".")

    def test_project_path_inside_a_command_becomes_relative(self):
        out = paths.normalize("git add " + self.ROOT + "/README.md", self.ROOT)
        self.assertEqual(out, "git add README.md")

    def test_sibling_directory_sharing_a_prefix_is_not_truncated(self):
        """`…/rein-dev` 루트가 `…/rein-dev-backup/x` 를 잘라먹지 않는다."""
        out = paths.normalize(self.ROOT + "-backup/x.py", self.ROOT)
        self.assertNotIn("testuser", out)
        self.assertTrue(
            out.startswith(paths.HOME_PLACEHOLDER), "홈 축약으로 남아야 한다: " + out
        )
        self.assertTrue(out.endswith("/rein-dev-backup/x.py"), out)

    def test_multiple_occurrences_all_rewritten(self):
        text = "cp {r}/a.py {r}/b.py".format(r=self.ROOT)
        self.assertEqual(paths.normalize(text, self.ROOT), "cp a.py b.py")

    def test_trailing_slash_root_is_accepted(self):
        out = paths.normalize(self.ROOT + "/a.py", self.ROOT + "/")
        self.assertEqual(out, "a.py")

    def test_root_embedded_mid_path_is_not_stripped(self):
        """왼쪽 경계 — 루트 문자열이 다른 경로 **안에** 나타나면 자르지 않는다.

        code review Medium (2026-08-10): 오른쪽 경계만 있어
        `/tmp/prefix/Users/testuser/…/a` 가 `/tmp/prefixa` 로 오절단됐다.
        """
        embedded = "/tmp/prefix" + self.ROOT + "/a.py"
        out = paths.normalize(embedded, self.ROOT)
        self.assertNotIn("testuser", out)
        self.assertTrue(out.endswith("/a.py"), out)
        self.assertNotIn("prefixa", out)

    def test_root_inside_a_url_is_not_stripped(self):
        out = paths.normalize("https://host" + self.ROOT + "/a.py", self.ROOT)
        self.assertNotIn("testuser", out)
        self.assertNotIn("hosta", out)
        self.assertTrue(out.endswith("/a.py"), out)

    def test_root_after_a_separator_is_still_stripped(self):
        for prefix, joiner in [("git add ", " "), ('cat "', '"'), ("(", "")]:
            text = prefix + self.ROOT + "/a.py" + joiner
            self.assertIn("a.py", paths.normalize(text, self.ROOT))
            self.assertNotIn("testuser", paths.normalize(text, self.ROOT))

    def test_siblings_using_uncommon_filename_characters_are_not_truncated(self):
        """POSIX 파일명이 허용하는 문자로 이어진 형제 경로도 오절단 금지.

        code review Medium (3회차): 경계를 "경로 문자" 열거로 잡으면
        `+`/`@`/`=` 같은 문자가 빠져 `<root>+backup/a.py` 가 `.+backup/a.py`
        로 잘렸다. 잘라내지 못하더라도 사용자명은 홈 축약이 지운다.
        """
        for suffix in ["+backup", "@old", "=tmp", "%1", "#2"]:
            text = self.ROOT + suffix + "/a.py"
            out = paths.normalize(text, self.ROOT)
            self.assertNotIn("testuser", out, text)
            self.assertTrue(out.endswith(suffix + "/a.py"), "{} → {}".format(text, out))

    def test_root_embedded_after_uncommon_characters_is_not_stripped(self):
        """앞이 경로에 이어붙을 수 있는 문자면 루트로 보지 않는다."""
        for prefix in ["/tmp+", "/tmp@", "name%"]:
            text = prefix + self.ROOT + "/a.py"
            out = paths.normalize(text, self.ROOT)
            self.assertNotIn("testuser", out, text)
            self.assertTrue(out.startswith(prefix), "{} → {}".format(text, out))
            self.assertTrue(out.endswith("/a.py"), out)

    def test_root_after_an_assignment_is_stripped(self):
        """`=` 뒤는 값의 시작이므로 정상적인 루트 경계다."""
        out = paths.normalize("out=" + self.ROOT + "/a.py", self.ROOT)
        self.assertEqual(out, "out=a.py")


class NormalizeCollapsesHomePathsOutsideProject(unittest.TestCase):
    """프로젝트 밖 홈 경로 → 사용자명 세그먼트만 치환."""

    ROOT = "/Users/testuser/dreamline/rein-dev"
    HOME = paths.HOME_PLACEHOLDER

    def test_macos_home_outside_project(self):
        out = paths.normalize("/Users/testuser/other-project/secret.env", self.ROOT)
        self.assertEqual(out, self.HOME + "/other-project/secret.env")

    def test_linux_home(self):
        out = paths.normalize("/home/runner/work/rein/rein/foo.py", None)
        self.assertEqual(out, self.HOME + "/work/rein/rein/foo.py")

    def test_root_home(self):
        self.assertEqual(paths.normalize("/root/.ssh/id_rsa", None), self.HOME + "/.ssh/id_rsa")

    def test_tilde_form(self):
        self.assertEqual(paths.normalize("~/secrets/deploy_key", None), self.HOME + "/secrets/deploy_key")

    def test_tilde_other_user_form(self):
        self.assertEqual(paths.normalize("~alice/notes.txt", None), self.HOME + "/notes.txt")

    def test_windows_home(self):
        out = paths.normalize(r"C:\Users\testuser\Desktop\a.txt", None)
        self.assertEqual(out, self.HOME + r"\Desktop\a.txt")

    def test_no_project_root_still_collapses_home(self):
        """루트 미전달 경로(구버전 호출부)에서도 사용자명은 남지 않는다."""
        out = paths.normalize(self.ROOT + "/plugins/a.py", None)
        self.assertNotIn("testuser", out)
        self.assertTrue(out.startswith(self.HOME))


class NormalizeCollapsesHyphenEncodedHomeSegments(unittest.TestCase):
    """슬래시를 하이픈으로 바꿔 인코딩한 홈 경로 (도구 작업 디렉토리 관용형).

    실측 발견 (2026-08-10, 이 저장소 corpus): 슬래시 기준 규칙만으로는
    `/private/tmp/claude-501/-Users-<name>-<proj>/…` 형태에 사용자명이
    그대로 남았다 — 홈 경로 축약이 붙은 뒤에도 디스크에 49건 잔존.
    세그먼트 안에서 사용자명과 프로젝트명의 경계를 알 수 없으므로
    (하이픈이 구분자이자 이름의 일부) 세그먼트 **전체**를 치환한다.
    """

    HOME = paths.HOME_PLACEHOLDER

    def test_scratchpad_style_segment_is_collapsed(self):
        out = paths.normalize(
            "/private/tmp/claude-501/-Users-testuser-work-proj/abc/scratchpad/a.txt",
            None,
        )
        self.assertNotIn("testuser", out)
        self.assertEqual(
            out, "/private/tmp/claude-501/" + self.HOME + "/abc/scratchpad/a.txt"
        )

    def test_linux_hyphen_encoded_segment_is_collapsed(self):
        out = paths.normalize("/tmp/x/-home-runner-work-rein/y.txt", None)
        self.assertNotIn("runner", out)
        self.assertIn(self.HOME, out)

    def test_hyphen_inside_a_word_is_not_a_path_segment(self):
        for text in ["some-Users-thing", "kebab-home-case", "a-Users-b.md"]:
            self.assertEqual(paths.normalize(text, None), text, text)

    def test_standalone_token_is_not_a_path_segment(self):
        """공백 뒤 단독 토큰은 경로 세그먼트가 아니다 — 명령 옵션·식별자 보호.

        code review Medium (2026-08-10): 앞 경계를 "공백 또는 `/`" 로 두면
        `echo -Users-alice-feature` 같은 옵션/식별자가 통째로 축약된다.
        실측된 인코딩 형태는 항상 `/` 뒤 세그먼트이므로 거기로 좁힌다.
        """
        for text in [
            "echo -Users-alice-feature",
            "case -home-runner-build",
            "-Users-alice-x",
        ]:
            self.assertEqual(paths.normalize(text, None), text, text)

    def test_collapsed_segment_passes_detection(self):
        out = paths.normalize("/private/tmp/claude-501/-Users-testuser-proj/a", None)
        self.assertFalse(paths.contains_private_path(out))

    def test_detection_flags_the_raw_form(self):
        self.assertTrue(
            paths.contains_private_path("/private/tmp/c/-Users-testuser-proj/a")
        )


class NormalizeLeavesNonPrivatePathsIntact(unittest.TestCase):
    """오탐 경계 — 사적 경로가 아닌 것은 건드리지 않는다."""

    CASES = [
        "/usr/local/bin/python3",
        "/var/log/system.log",
        "/rootfs/etc/passwd",
        "/rootcause-analysis/report.md",
        "plugins/rein-core/rein/shadow/corpus.py",
        "~ish 범위의 근사치",
        "a~b 는 경로가 아니다",
        "~5/10 확률",
    ]

    def test_lookalikes_unchanged(self):
        for text in self.CASES:
            self.assertEqual(paths.normalize(text, None), text, text)

    def test_empty_and_none_safe(self):
        self.assertEqual(paths.normalize("", None), "")
        self.assertEqual(paths.normalize("", "/Users/x/p"), "")


class NormalizeIsIdempotent(unittest.TestCase):
    ROOT = "/Users/testuser/proj"

    def test_second_pass_is_a_noop(self):
        for text in [
            "/Users/testuser/proj/a/b.py",
            "/Users/testuser/elsewhere/c.py",
            "~/d.py",
        ]:
            once = paths.normalize(text, self.ROOT)
            self.assertEqual(paths.normalize(once, self.ROOT), once, text)


class DetectionRuleIsSharedNotDuplicated(unittest.TestCase):
    """검출·정규화가 같은 정의를 소비한다 (규칙 분기 방지)."""

    def test_corpus_detection_delegates_to_paths_module(self):
        self.assertTrue(paths.contains_private_path("/Users/testuser/a"))
        self.assertFalse(paths.contains_private_path("/usr/local/a"))

    def test_corpus_module_has_no_private_path_regex_of_its_own(self):
        """corpus 는 규칙을 **소비**만 한다 — 자체 정의를 두면 갈라진다.

        문자열 존재 여부 같은 대리지표 대신 실제 심볼을 본다: 자체 패턴
        객체가 없고(모듈 속성 부재), SSOT 함수를 호출한다.
        """
        self.assertFalse(
            hasattr(corpus, "_PRIVATE_PATH"),
            "corpus.py 가 사적 경로 정규식을 자체 보유하면 규칙이 갈라진다 "
            "— paths.py 정의를 소비할 것",
        )
        source_path = os.path.join(_PLUGIN_ROOT, "rein", "shadow", "corpus.py")
        with open(source_path, "r", encoding="utf-8") as handle:
            body = handle.read()
        self.assertIn("paths.contains_private_path", body)

    def test_normalized_output_passes_detection(self):
        for text in [
            "/Users/testuser/proj/a.py",
            "/home/runner/work/x.py",
            "~/secrets/key",
            r"C:\Users\testuser\a.txt",
        ]:
            out = paths.normalize(text, "/Users/testuser/proj")
            self.assertFalse(
                paths.contains_private_path(out),
                "정규화 결과가 여전히 사적 경로로 검출됨: {!r} → {!r}".format(text, out),
            )


class CaptureNormalizesEveryStringField(unittest.TestCase):
    """명령뿐 아니라 사실·프로젝트 상태·판정 사유까지 전부 축약된다."""

    ROOT = "/Users/testuser/proj"

    def _case(self, **kwargs):
        return capture.capture(
            event="pre-edit-dod-gate", project_root=self.ROOT, **kwargs
        ).to_dict()

    def test_command_field_normalized(self):
        got = self._case(command_text=self.ROOT + "/a.py")
        self.assertEqual(got["command"]["redacted"], "a.py")

    def test_facts_normalized(self):
        got = self._case(facts={"file": self.ROOT + "/a.py"})
        self.assertEqual(got["facts"]["file"], "a.py")

    def test_project_state_normalized(self):
        got = self._case(project_state={"cwd": self.ROOT})
        self.assertEqual(got["project_state"]["cwd"], ".")

    def test_reason_normalized(self):
        got = self._case(v1_reason="blocked edit of " + self.ROOT + "/a.py")
        self.assertEqual(got["v1_reason"], "blocked edit of a.py")

    def test_nested_containers_normalized(self):
        got = self._case(facts={"paths": [self.ROOT + "/a.py", {"p": "~/b.py"}]})
        self.assertEqual(
            got["facts"]["paths"],
            ["a.py", {"p": paths.HOME_PLACEHOLDER + "/b.py"}],
        )

    def test_event_and_decision_fields_are_sanitized_too(self):
        """모든 문자열 필드 — `event`/`v1_decision` 도 예외가 아니다.

        security review Info-2: 두 필드만 정화를 건너뛰어 "같은 SSOT 를
        거친다" 는 라우팅 계약에 구멍이 있었다.
        """
        case = capture.capture(
            event=self.ROOT + "/hook",
            v1_decision="/Users/testuser/x",
            project_root=self.ROOT,
        )
        self.assertEqual(case.event, "hook")
        self.assertNotIn("testuser", case.v1_decision)

    def test_without_project_root_home_is_still_collapsed(self):
        got = capture.capture(
            event="pre-edit-dod-gate", command_text="/Users/testuser/x/a.py"
        ).to_dict()
        self.assertNotIn("testuser", json.dumps(got))


class MappingKeysAreSanitizedToo(unittest.TestCase):
    """dict key 도 정화 대상이다 (code review High, 2026-08-10).

    값만 정화하고 key 를 그대로 저장하면 `facts={"/Users/alice/x": True}`
    같은 입력에서 사용자명이 그대로 남고, 반입 검증도 값만 훑기 때문에
    최후 관문마저 통과한다 — "모든 문자열 필드" 계약의 구멍.
    """

    ROOT = "/Users/testuser/proj"

    def test_key_inside_project_becomes_relative(self):
        case = capture.capture(
            event="e", facts={self.ROOT + "/a.py": 1}, project_root=self.ROOT
        )
        self.assertEqual(list(case.facts), ["a.py"])

    def test_key_outside_project_loses_username(self):
        case = capture.capture(
            event="e", facts={"/Users/testuser/other/b.py": 1}, project_root=self.ROOT
        )
        self.assertNotIn("testuser", json.dumps(case.to_dict()))

    def test_secret_in_key_is_masked(self):
        case = capture.capture(
            event="e", facts={"GITHUB_TOKEN=" + FAKE_PAT: 1}, project_root=self.ROOT
        )
        self.assertNotIn(FAKE_PAT, json.dumps(case.to_dict()))

    def test_nested_mapping_keys_sanitized(self):
        case = capture.capture(
            event="e",
            project_state={"outer": {self.ROOT + "/a.py": "v"}},
            project_root=self.ROOT,
        )
        self.assertEqual(list(case.project_state["outer"]), ["a.py"])

    def test_colliding_keys_do_not_silently_drop_data(self):
        """축약 후 같아지는 두 key 가 있어도 값이 사라지지 않는다."""
        case = capture.capture(
            event="e",
            facts={self.ROOT + "/a.py": 1, "a.py": 2},
            project_root=self.ROOT,
        )
        self.assertEqual(len(case.facts), 2, case.facts)
        self.assertEqual(sorted(case.facts.values()), [1, 2])

    def test_corpus_rejects_private_path_in_a_key(self):
        case_dict = {
            "event": "e",
            "facts": {"/Users/testuser/proj/a.py": True},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        categories = [v["category"] for v in corpus.find_violations(case_dict)]
        self.assertIn(corpus.CATEGORY_PRIVATE_PATH, categories)

    def test_violation_report_never_echoes_a_sensitive_key(self):
        """거부 사유가 민감한 key 원문을 되뿜지 않는다 (code review High, 2회차).

        위반 목록의 필드 라벨과 예외 메시지 양쪽 — 예외를 로깅하는 호출부가
        생기면 그대로 유출 경로가 된다.
        """
        secret_key = "/Users/testuser/proj/a.py"
        case_dict = {
            "event": "e",
            "facts": {secret_key: True, "GITHUB_TOKEN=" + FAKE_PAT: 1},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        violations = corpus.find_violations(case_dict)
        self.assertTrue(violations)
        blob = json.dumps(violations, ensure_ascii=False)
        self.assertNotIn("testuser", blob)
        self.assertNotIn(FAKE_PAT, blob)

        message = str(corpus.CorpusImportRejected(violations))
        self.assertNotIn("testuser", message)
        self.assertNotIn(FAKE_PAT, message)

    def test_oversized_key_is_not_reflected_in_the_report(self):
        """상한을 넘는 key 는 라벨로도 되뿜지 않는다 (code review Medium, 3회차).

        길이 관문이 라벨 판정보다 뒤에 있어, 거대한 key 원문이 위반 라벨과
        예외 메시지에 그대로 실렸다.
        """
        huge_key = "K" * (corpus.MAX_FIELD_CHARS + 1)
        case_dict = {
            "event": "e",
            "facts": {huge_key: True},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        violations = corpus.find_violations(case_dict)
        self.assertEqual(
            [v["category"] for v in violations], [corpus.CATEGORY_OVERSIZED_FIELD]
        )
        label = violations[0]["field"]
        self.assertNotIn("KKKK", label)
        self.assertLess(len(label), 100, label)

    def test_top_level_key_outside_the_schema_is_anonymous(self):
        """스키마 밖 최상위 key 이름은 라벨에 안 들어간다 (security Low-1, 2회차).

        모양 검사로는 영숫자+밑줄로 된 짧은 secret 이나 사용자명이 섞인
        식별자를 걸러낼 수 없다 — 스키마 key 집합으로 판정한다.
        """
        for key in [FAKE_PAT, "AKIAIOSFODNN7SEKRIT", "testuser_home_dir"]:
            case_dict = {
                "event": "e",
                "facts": {},
                "command": {"type": "unknown", "redacted": ""},
                "project_state": {},
                "v1_decision": "ALLOW",
                "v1_reason": "",
                "captured_at": "2026-08-10T00:00:00",
                key: "contact bob@example.com",
            }
            violations = corpus.find_violations(case_dict)
            self.assertTrue(violations, key)
            blob = json.dumps(violations) + str(
                corpus.CorpusImportRejected(violations)
            )
            self.assertNotIn(key, blob)

    def test_non_string_project_root_does_not_break_capture(self):
        """경로 객체를 받아도 레코드가 유실되지 않는다 (security Info-1)."""
        import pathlib

        case = capture.capture(
            event="e",
            facts={"file": "/Users/testuser/proj/a.py"},
            project_root=pathlib.PurePosixPath("/Users/testuser/proj"),
        )
        self.assertEqual(case.facts["file"], "a.py")

    def test_top_level_field_name_stays_readable(self):
        """최상위 필드 이름은 라벨에 남는다 — 진단 가치 보존."""
        case_dict = {
            "event": "e",
            "facts": {"hook": "x@example.com"},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        violations = corpus.find_violations(case_dict)
        self.assertEqual([v["field"] for v in violations], ["facts.<key:0>"])

    def test_nested_key_names_never_appear_in_labels(self):
        """중첩 key 이름은 검출 결과와 무관하게 라벨에 안 들어간다.

        security review Low-2: 라벨 판정이 값 검출과 같은 신호를 쓰면 그
        신호의 사각지대를 그대로 물려받는다 — 검출이 못 잡는 형태의 key 가
        **값** 위반 라벨의 조상 세그먼트로 새어나갔다. 라벨 생성을 데이터와
        분리해 그 결합 자체를 없앤다.
        """
        for key in [
            "-Users-alice-proj",       # 검출 규칙이 (오탐 회피로) 안 잡는 형태
            "/Users/alice/proj",       # 검출되는 형태
            "GITHUB_TOKEN=" + FAKE_PAT,
            "bob@example.com",
        ]:
            case_dict = {
                "event": "e",
                "facts": {key: "contact carol@example.com"},
                "command": {"type": "unknown", "redacted": ""},
                "project_state": {},
                "v1_decision": "ALLOW",
                "v1_reason": "",
                "captured_at": "2026-08-10T00:00:00",
            }
            violations = corpus.find_violations(case_dict)
            self.assertTrue(violations, key)
            blob = json.dumps(violations) + str(
                corpus.CorpusImportRejected(violations)
            )
            for leaked in ["alice", "bob", FAKE_PAT, "GITHUB_TOKEN"]:
                self.assertNotIn(leaked, blob, "{} → {}".format(key, blob))

    def test_corpus_rejects_credential_in_a_key(self):
        case_dict = {
            "event": "e",
            "facts": {"GITHUB_TOKEN=" + FAKE_PAT: True},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        categories = [v["category"] for v in corpus.find_violations(case_dict)]
        self.assertIn(corpus.CATEGORY_CREDENTIAL, categories)


class NormalizationDoesNotWeakenMasking(unittest.TestCase):
    """경로 축약이 마스킹·절단 순서 계약을 깨지 않는다."""

    ROOT = "/Users/testuser/proj"

    def test_secret_alongside_a_project_path_still_masked(self):
        """같은 명령에 프로젝트 경로와 secret 이 함께 있어도 둘 다 처리된다."""
        case = capture.capture(
            event="pre-bash-safety-guard",
            command_text="git -C {}/repo push https://{}@github.com/o/r.git".format(
                self.ROOT, FAKE_PAT
            ),
            project_root=self.ROOT,
        )
        redacted = case.command["redacted"]
        self.assertNotIn(FAKE_PAT, redacted)
        self.assertNotIn("testuser", redacted)
        self.assertIn("repo", redacted)

    def test_secret_after_path_normalization_still_masked(self):
        case = capture.capture(
            event="pre-bash-safety-guard",
            command_text="cat {}/.env GITHUB_TOKEN={}".format(self.ROOT, FAKE_PAT),
            project_root=self.ROOT,
        )
        redacted = case.command["redacted"]
        self.assertNotIn(FAKE_PAT, redacted)
        self.assertNotIn("testuser", redacted)

    def test_truncation_still_applies_after_masking(self):
        """절단은 여전히 마지막이고, 절단 경계 앞의 secret 은 이미 가려져 있다.

        경로 축약을 앞에 끼워 넣은 뒤에도 "마스킹 → 절단" 순서가 유지되는지
        방향까지 본다 — 절단이 앞서면 잘린 자리에 secret 조각이 남는다.
        """
        long_command = "echo GITHUB_TOKEN={} {}".format(
            FAKE_PAT, "a" * (capture.MAX_COMMAND_CHARS + 500)
        )
        case = capture.capture(
            event="pre-bash-safety-guard",
            command_text=long_command,
            project_root=self.ROOT,
        )
        redacted = case.command["redacted"]
        self.assertTrue(redacted.endswith(capture.TRUNCATION_MARKER))
        self.assertNotIn(FAKE_PAT, redacted)
        self.assertNotIn(FAKE_PAT[:12], redacted)


class CorpusStillRejectsUnnormalizedPrivatePaths(unittest.TestCase):
    """검증기의 거부 동작 자체는 불변 (최후 관문 유지)."""

    def test_raw_absolute_path_in_a_hand_built_case_is_rejected(self):
        case_dict = {
            "event": "pre-edit-dod-gate",
            "facts": {"file": "/Users/testuser/proj/a.py"},
            "command": {"type": "unknown", "redacted": ""},
            "project_state": {},
            "v1_decision": "ALLOW",
            "v1_reason": "",
            "captured_at": "2026-08-10T00:00:00",
        }
        violations = corpus.find_violations(case_dict)
        self.assertIn(
            corpus.CATEGORY_PRIVATE_PATH, [v["category"] for v in violations]
        )


class EndToEndHomeProjectRecordsActuallyLand(unittest.TestCase):
    """홈 하위 프로젝트를 재현해 반입까지 관통 — 이 결함의 회귀 락."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # 임시 디렉토리 **안에** 홈 형태 세그먼트를 만든다 — 이렇게 해야
        # 경로 문자열이 `/Users/<name>/…` 를 포함해 결함이 재현된다
        # (Phase 2 테스트가 이 결함을 놓친 원인이 정확히 이 재현 부재였다).
        self.root = os.path.join(self._tmp.name, "Users", "testuser", "proj")
        os.makedirs(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def _corpus_bytes(self, path):
        with open(path, "rb") as handle:
            return handle.read()

    def test_edit_hook_record_with_absolute_path_is_stored(self):
        target = os.path.join(self.root, "plugins", "rein-core", "a.py")
        case = capture.capture(
            event="pre-edit-dod-gate",
            facts={"hook": "pre-edit-dod-gate"},
            command_text=target,
            v1_decision="ALLOW",
            project_root=self.root,
        )
        corpus_path = corpus.import_case(case, self.root)

        raw = self._corpus_bytes(corpus_path)
        self.assertNotIn(b"testuser", raw)
        record = json.loads(raw.decode("utf-8").strip().splitlines()[-1])
        self.assertEqual(record["command"]["redacted"], "plugins/rein-core/a.py")

    def test_bash_hook_record_with_absolute_path_is_stored(self):
        case = capture.capture(
            event="pre-bash-safety-guard",
            facts={"hook": "pre-bash-safety-guard"},
            command_text="git add {}/README.md".format(self.root),
            v1_decision="ALLOW",
            v1_reason="edit under {}/plugins".format(self.root),
            project_root=self.root,
        )
        corpus_path = corpus.import_case(case, self.root)

        raw = self._corpus_bytes(corpus_path)
        self.assertNotIn(b"testuser", raw)
        record = json.loads(raw.decode("utf-8").strip().splitlines()[-1])
        self.assertEqual(record["command"]["redacted"], "git add README.md")
        self.assertEqual(record["v1_reason"], "edit under plugins")

    def test_path_outside_the_project_lands_with_username_removed(self):
        outside = os.path.join(self._tmp.name, "Users", "testuser", "other", "b.py")
        case = capture.capture(
            event="pre-edit-dod-gate",
            command_text=outside,
            project_root=self.root,
            v1_decision="ALLOW",
        )
        corpus_path = corpus.import_case(case, self.root)

        raw = self._corpus_bytes(corpus_path)
        self.assertNotIn(b"testuser", raw)
        record = json.loads(raw.decode("utf-8").strip().splitlines()[-1])
        self.assertIn(paths.HOME_PLACEHOLDER, record["command"]["redacted"])
        self.assertTrue(record["command"]["redacted"].endswith("/other/b.py"))


class NormalizeScalesLinearly(unittest.TestCase):
    """ReDoS 방어 — 입력을 배증해도 비용이 배증 수준에 머문다.

    단일 크기의 벽시계 상한만 재면 "느리지 않다" 는 말만 하고 **스케일링**
    은 증명하지 못한다 (code review 3회차 지적). 두 크기의 비를 본다.
    """

    ROOT = "/Users/testuser/proj"

    def _timed(self, n):
        import time

        text = (self.ROOT + "/a.py " ) * n + ("x" * (10 * n))
        best = None
        for _ in range(3):
            start = time.perf_counter()
            paths.normalize(text, self.ROOT)
            elapsed = time.perf_counter() - start
            best = elapsed if best is None else min(best, elapsed)
        return best

    def test_doubling_input_does_not_explode_cost(self):
        self._timed(500)  # warm-up
        small = self._timed(2000)
        large = self._timed(4000)
        # 선형이면 비가 ≈2. 측정 잡음과 상수항을 감안해 넉넉히 6배까지 허용
        # 하되, 이차(≈4배 이상 급증)는 걸러낸다.
        self.assertLess(
            large, max(small * 6.0, 0.05), "small={:.6f} large={:.6f}".format(small, large)
        )


if __name__ == "__main__":
    unittest.main()
