"""plan Task 4.3 — tests_passed Evidence 자격 4조건 (spec §5.2).

spec §5.2 (원문 인용):
    "Evidence 자격 조건 4개 (모두 충족 시에만 `tests_passed` 발급):
    1. 선언된 명령: 실행 명령이 선언 목록의 `run` 과 일치 (exact 또는
       선언 prefix + 추가 인자). 미선언 명령 실행은 자격 없음.
    2. runtime_verified 만: Rein Runtime 이 실행을 직접 관측한 경우만
       (spawn + exit code 확인). Agent 의 '테스트 돌렸고 통과했다'
       보고(agent_attested)는 `tests_passed` 로 불인정.
    3. subject = 실행 시점 code digest.
    4. 실행 중 변경 무효: 실행 종료 시점 digest 가 시작 시점과 다르면
       Evidence 를 발급하지 않는다."

검증 축 (plan Task 4.3 Steps):
(a) 미선언 명령 실행 → 미발급.
(b) agent 보고만(agent_attested) → 불인정 — 발급 API 자체가 관측 없는
    경로를 제공하지 않는 구조 + evaluate() 의 producer 축 재확인 양쪽.
(c) 실행 중 파일 수정(시작/종료 digest 불일치) → 미발급.
(d) 정상 경로(선언 명령 + spawn 관측 exit 0 + digest 안정) → 발급.
(e) 설정 로더 — 정상 스키마 로드 / 미지 필드·tag 거부 / 파일 부재 =
    미설정.
(f) exit code 비0 → 미발급.
(g) [사이클 B 리뷰 1회차 High] 자기진술 축 — 호출자가 명시하는 `tag`
    인자가 declared.tag 와 다르면 미발급.
(h) [사이클 B 리뷰 2회차 High 근본 수리] 실분류 축 — (g)만으로는
    호출자가 `tag="docs"` 라고 자기진술만 하고 실제로는 code 경로를
    `paths` 로 건네도 통과했다(리뷰어 실증). 신뢰된 `tag_rules` 로
    `paths` 전부를 실제 재분류해 declared.tag 와 대조하지 않으면 미발급
    — 자기진술은 통과하지만 실분류가 다른 "동태 오결속" 시나리오,
    혼합 경로, `tag_rules` 미제공(재검증 불가) 전부 거부 방향이다.
(i) [사이클 B 리뷰 2회차 High 근본 수리] 평가 단계 tag 축 —
    `TestsPassedRequirement.evaluate` 가 `Evidence.metadata["tag"]` 를
    평가 대상 ChangeSet 의 현재 tag fact(`changeset.tag`)와 대조한다.
    발급 시점 결속이 성립해도 평가 시점에 다시 확인하지 않으면 다른
    tag 의 ChangeSet 평가에 재사용될 수 있다.

실제 subprocess spawn 을 사용한다(진짜 runtime_verified 관측을 검증하기
위해 mock 하지 않는다) — 단 fixture 명령은 전부 `sys.executable -c`
급 무해한 명령이고 실행은 tmp 디렉토리에 격리된다(실전 위험 명령 실행
금지, worker 지침 준수). tag 분류는 `rein.engine.tags` 를 읽기·import
만 한다(편집 금지 — 부모 지침).
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

from rein.capabilities.testing.capability import (  # noqa: E402
    FACT_CHANGESET_DIGEST,
    FACT_CHANGESET_TAG,
    FACT_POLICY_COMPATIBLE_VERSIONS,
    FACT_POLICY_VERSION,
    REQUIREMENT_NAME,
    ChangesetTagMismatch,
    TestCommand,
    TestingConfig,
    TestingConfigError,
    TestRunDigestMismatch,
    TestRunFailed,
    TestRunSpawnError,
    TestsPassedEvidenceRefusal,
    TestsPassedRequirement,
    UndeclaredTestCommand,
    VERDICT_PASS,
    find_declared_command,
    load_testing_config,
    observe_test_run,
    parse_testing_config,
    register_tests_passed,
)
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.engine.registry import RequirementRegistry  # noqa: E402
from rein.engine.tags import TagRule  # noqa: E402 - 읽기·import 만, 편집 금지
from rein.kernel.changeset import content_digest  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    PRODUCER_RUNTIME_VERIFIED,
)

_PY = sys.executable
# 무해한 fixture 명령 — 실제 위험 명령 실행 금지 지침 준수
_CMD_PASS = '{} -c "pass"'.format(_PY)
_CMD_FAIL = '{} -c "import sys; sys.exit(1)"'.format(_PY)

# tag 별 fixture 파일명 + 그 파일명을 정확히 그 tag 로 분류하는 규칙 —
# (h) 실분류 축 테스트가 "자기진술은 맞지만 실제 파일은 다른 tag" 를
# 재현하려면 tag 마다 서로 다른 확장자가 필요하다.
_TAG_FILENAMES = {
    "code": "tracked.py",
    "docs": "tracked.md",
    "sensitive": "tracked.secret",
}
_TAG_RULES = (
    TagRule(tag="code", pattern="*.py"),
    TagRule(tag="docs", pattern="*.md"),
    TagRule(tag="sensitive", pattern="*.secret"),
)

_CMD_WRITE_TRACKED = (
    '{} -c "open(\'{}\', \'w\').write(\'mutated\')"'.format(
        _PY, _TAG_FILENAMES["code"]
    )
)

_UNSET = object()  # "인자 미지정 → 기본값 사용" 과 "명시적 None" 을 구분하는 sentinel


def _fs_reader(base):
    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


class _StubEvidenceSource:
    """조회는 항상 정상 수행되는 evidence 소스 (부재/존재만 제어)."""

    def __init__(self, records=()):
        self._records = tuple(records)

    def find(self, requirement_name):
        if requirement_name == REQUIREMENT_NAME:
            return self._records
        return ()


class _TmpDirMixin(unittest.TestCase):
    """spawn 격리용 tmp 디렉토리 + tag-aware 내용 기반 digest 헬퍼 공통 준비.

    기본 tag 는 "code"(`self.tag`/`self.paths`/`self.tag_rules`) — 대부분의
    테스트는 이 기본값만으로 동작한다. tag 결속을 다루는 테스트만
    `_use_tag(tag)` 로 다른 tag/paths 조합으로 전환한다(실제로 그 tag 로
    분류되는 파일명을 쓴다 — (h) 실분류 축이 자기진술만으로 통과하지
    않기 때문).
    """

    DEFAULT_TAG = "code"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.reader = _fs_reader(self.base)
        self.tag_rules = _TAG_RULES
        self._use_tag(self.DEFAULT_TAG)

    def _use_tag(self, tag):
        self.tag = tag
        self.paths = (_TAG_FILENAMES[tag],)

    def _digest(self, paths=None):
        return content_digest(paths if paths is not None else self.paths, self.reader)

    def _write(self, filename, content=b"original\n"):
        with open(os.path.join(self.base, filename), "wb") as handle:
            handle.write(content)

    def _write_tracked(self, content=b"original\n"):
        self._write(self.paths[0], content=content)

    def _config(self, *commands):
        return TestingConfig(commands=commands)

    def _make_evidence(self, digest, tag=_UNSET, **overrides):
        resolved_tag = self.tag if tag is _UNSET else tag
        fields = dict(
            type=REQUIREMENT_NAME,
            subject=digest,
            result=VERDICT_PASS,
            created_at="2026-08-10T00:00:00+00:00",
            producer=PRODUCER_RUNTIME_VERIFIED,
            policy_version="1",
            metadata=(
                {"tag": resolved_tag} if resolved_tag is not None else {}
            ),
        )
        fields.update(overrides)
        return Evidence(**fields)

    def _context(
        self,
        records,
        digest=None,
        policy_version="1",
        compatible=None,
        tag=_UNSET,
    ):
        facts = {}
        if digest is not None:
            facts[FACT_CHANGESET_DIGEST] = digest
        if policy_version is not None:
            facts[FACT_POLICY_VERSION] = policy_version
        if compatible is not None:
            facts[FACT_POLICY_COMPATIBLE_VERSIONS] = tuple(compatible)
        resolved_tag = self.tag if tag is _UNSET else tag
        if resolved_tag is not None:
            facts[FACT_CHANGESET_TAG] = resolved_tag
        return EvaluationContext(
            facts=facts, evidence_source=_StubEvidenceSource(records)
        )


# ---------------------------------------------------------------------------
# (e) 설정 로더


class ConfigLoaderTest(unittest.TestCase):
    def test_missing_file_is_unconfigured_not_an_error(self):
        # 파일 부재 = testing.configured fact 재료("미설정") — 에러 아님
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(
                load_testing_config(os.path.join(tmp, "testing.yaml"))
            )

    def test_valid_config_loads_commands_in_order(self):
        text = (
            "testing:\n"
            "  commands:\n"
            "    - id: unit\n"
            "      run: pytest tests/unit\n"
            "      tag: code\n"
            "    - id: docs-lint\n"
            "      run: markdownlint docs\n"
            "      tag: docs\n"
        )
        config = parse_testing_config(text, source="<test>")
        self.assertEqual(
            config.commands,
            (
                TestCommand(id="unit", run="pytest tests/unit", tag="code"),
                TestCommand(
                    id="docs-lint", run="markdownlint docs", tag="docs"
                ),
            ),
        )

    def test_empty_commands_object_is_valid_but_distinct_from_absent_file(
        self,
    ):
        # D3 subset 파서는 flow style(`[]`)을 지원하지 않으므로(D3 거부
        # 목록) "0개 명령 선언"을 실제 YAML 텍스트로 왕복시킬 수는 없다
        # — 그 문법 자체가 subset 밖이다. 이 테스트는 그래도 "파일이
        # 존재하되 0개 선언"과 "파일이 아예 없음(None)"이 TestingConfig
        # 값 수준에서 서로 다른 상태로 유지된다는 불변식만 확인한다.
        config = TestingConfig(commands=())
        self.assertEqual(config.commands, ())
        self.assertIsNotNone(config)  # 파일 존재 + 0개 선언 ≠ 미설정(None)

    def test_unsupported_top_level_field_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n  commands: []\nextra: 1\n", source="<test>"
            )

    def test_missing_testing_key_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config("other: 1\n", source="<test>")

    def test_unsupported_testing_section_field_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n  commands: []\n  extra: 1\n", source="<test>"
            )

    def test_missing_commands_field_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config("testing:\n  id: x\n", source="<test>")

    def test_command_unsupported_field_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n"
                "  commands:\n"
                "    - id: unit\n"
                "      run: pytest\n"
                "      tag: code\n"
                "      extra: nope\n",
                source="<test>",
            )

    def test_command_missing_field_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n  commands:\n    - id: unit\n      run: pytest\n",
                source="<test>",
            )

    def test_command_invalid_tag_is_rejected(self):
        # tag 는 rein.engine.tags.TAG_NAMES 밖 값을 거부한다
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n"
                "  commands:\n"
                "    - id: unit\n"
                "      run: pytest\n"
                "      tag: not-a-real-tag\n",
                source="<test>",
            )

    def test_command_empty_run_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n"
                "  commands:\n"
                "    - id: unit\n"
                "      run: ''\n"
                "      tag: code\n",
                source="<test>",
            )

    def test_duplicate_command_id_is_rejected(self):
        with self.assertRaises(TestingConfigError):
            parse_testing_config(
                "testing:\n"
                "  commands:\n"
                "    - id: unit\n"
                "      run: pytest a\n"
                "      tag: code\n"
                "    - id: unit\n"
                "      run: pytest b\n"
                "      tag: code\n",
                source="<test>",
            )

    def test_load_testing_config_reads_from_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "testing.yaml")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "testing:\n"
                    "  commands:\n"
                    "    - id: unit\n"
                    "      run: pytest tests/unit\n"
                    "      tag: code\n"
                )
            config = load_testing_config(path)
            self.assertEqual(len(config.commands), 1)
            self.assertEqual(config.commands[0].id, "unit")


# ---------------------------------------------------------------------------
# 선언 매칭 (조건 1의 순수 판정 부분)


class DeclaredCommandMatchingTest(unittest.TestCase):
    def setUp(self):
        self.config = TestingConfig(
            commands=(
                TestCommand(id="unit", run="pytest tests/unit", tag="code"),
            )
        )

    def test_exact_match(self):
        self.assertEqual(
            find_declared_command(self.config, "pytest tests/unit"),
            self.config.commands[0],
        )

    def test_prefix_with_additional_args_matches(self):
        self.assertEqual(
            find_declared_command(
                self.config, "pytest tests/unit -v --maxfail=1"
            ),
            self.config.commands[0],
        )

    def test_unrelated_command_does_not_match(self):
        self.assertIsNone(
            find_declared_command(self.config, "pytest tests/integration")
        )

    def test_superstring_token_does_not_falsely_match(self):
        # "pytest" 가 "pytest2" 의 문자열 접두사라는 이유만으로
        # 오매칭되지 않는다 — 토큰 단위 비교 (모듈 docstring 참조)
        config = TestingConfig(
            commands=(TestCommand(id="p", run="pytest", tag="code"),)
        )
        self.assertIsNone(find_declared_command(config, "pytest2 tests"))

    def test_none_config_has_no_declared_commands(self):
        self.assertIsNone(find_declared_command(None, "pytest tests/unit"))

    def test_unparseable_command_is_conservatively_undeclared(self):
        # 짝 안맞는 인용 — 매칭 재료 없음, 안전측(미선언) 판정
        self.assertIsNone(
            find_declared_command(self.config, "pytest 'unterminated")
        )


# ---------------------------------------------------------------------------
# (a) 미선언 명령 실행 → 미발급


class UndeclaredCommandTest(_TmpDirMixin):
    def test_undeclared_command_refuses_before_any_evidence(self):
        self._write_tracked()
        config = self._config(
            TestCommand(id="unit", run="pytest tests/unit", tag="code")
        )
        with self.assertRaises(UndeclaredTestCommand):
            observe_test_run(
                _CMD_PASS,  # 선언 목록에 없는 명령
                config,
                self.tag,
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_unconfigured_project_refuses_any_command(self):
        self._write_tracked()
        with self.assertRaises(UndeclaredTestCommand):
            observe_test_run(
                _CMD_PASS,
                None,  # 미설정 프로젝트
                self.tag,
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )


# ---------------------------------------------------------------------------
# (b) agent_attested 는 tests_passed 로 불인정 — 구조 + 평가 재확인


class AgentAttestedNotAcceptedTest(_TmpDirMixin):
    def test_issuance_api_has_no_agent_report_entry_point(self):
        # observe_test_run 은 exit_code/verdict/report 류를 인자로 받지
        # 않는다 — 항상 스스로 spawn 해야만 Evidence 가 나온다. signature
        # 에 그런 우회 경로가 없다는 것을 구조적으로 고정한다.
        import inspect

        params = set(inspect.signature(observe_test_run).parameters)
        self.assertFalse(params & {"exit_code", "verdict", "report", "result"})

    def test_agent_attested_record_does_not_satisfy_even_with_matching_digest(
        self,
    ):
        # evidence 저장소에 producer=agent_attested 레코드가 (다른 경로로)
        # 섞여 있어도 evaluate() 는 이를 충족 재료로 인정하지 않는다 —
        # digest·version·result·tag 가 전부 일치해도 producer 축이 막는다
        # (spec §5.2 조건 2 의 평가 시점 재확인, 클래스 docstring 참조)
        digest = self._digest()
        record = self._make_evidence(digest, producer=PRODUCER_AGENT_ATTESTED)
        requirement = TestsPassedRequirement()
        self.assertFalse(
            requirement.evaluate(self._context((record,), digest=digest))
        )

    def test_runtime_verified_record_does_satisfy(self):
        # 대조군 — 동일 조건에서 producer 만 runtime_verified 면 충족
        digest = self._digest()
        record = self._make_evidence(digest)
        requirement = TestsPassedRequirement()
        self.assertTrue(
            requirement.evaluate(self._context((record,), digest=digest))
        )


# ---------------------------------------------------------------------------
# (c) 실행 중 파일 수정(시작/종료 digest 불일치) → 미발급


class DigestMismatchTest(_TmpDirMixin):
    def test_command_that_mutates_tracked_file_refuses_issuance(self):
        # tracked.py 는 처음엔 부재 — 명령이 spawn 도중 이를 써서
        # 시작(부재)/종료(존재) digest 가 달라진다. exit code 는 0 이라
        # 그 축은 통과하지만, digest 축이 발급을 막는다.
        config = self._config(
            TestCommand(id="write", run=_CMD_WRITE_TRACKED, tag="code")
        )
        with self.assertRaises(TestRunDigestMismatch):
            observe_test_run(
                _CMD_WRITE_TRACKED,
                config,
                self.tag,
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )
        # 실제로 파일이 쓰였는지(명령이 정말 spawn 됐는지) 확인 —
        # 진짜 실행 관측이지 mock 이 아니다
        self.assertTrue(
            os.path.exists(os.path.join(self.base, self.paths[0]))
        )


# ---------------------------------------------------------------------------
# (f) exit code 비0 → 미발급


class NonZeroExitTest(_TmpDirMixin):
    def test_failing_command_refuses_issuance(self):
        self._write_tracked()
        config = self._config(
            TestCommand(id="fail", run=_CMD_FAIL, tag="code")
        )
        with self.assertRaises(TestRunFailed):
            observe_test_run(
                _CMD_FAIL,
                config,
                self.tag,
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_spawn_failure_for_nonexistent_binary_is_distinguished(self):
        config = self._config(
            TestCommand(
                id="ghost", run="this-binary-does-not-exist-anywhere", tag="code"
            )
        )
        with self.assertRaises(TestRunSpawnError):
            observe_test_run(
                "this-binary-does-not-exist-anywhere",
                config,
                self.tag,
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )


# ---------------------------------------------------------------------------
# (d) 정상 경로 — 발급 (producer=runtime_verified, subject=시작 digest)


class NormalIssuanceTest(_TmpDirMixin):
    def test_declared_stable_passing_command_issues_evidence(self):
        self._write_tracked()
        start_digest = self._digest()
        config = self._config(
            TestCommand(id="unit", run=_CMD_PASS, tag="code")
        )
        evidence = observe_test_run(
            _CMD_PASS,
            config,
            self.tag,
            self.paths,
            self.reader,
            self.tag_rules,
            policy_version="1",
            cwd=self.base,
            created_at="2026-08-10T00:00:00+00:00",
        )
        self.assertEqual(evidence.type, REQUIREMENT_NAME)
        self.assertEqual(evidence.subject, start_digest)
        self.assertEqual(evidence.result, VERDICT_PASS)
        self.assertEqual(evidence.producer, PRODUCER_RUNTIME_VERIFIED)
        self.assertEqual(evidence.policy_version, "1")
        self.assertEqual(evidence.created_at, "2026-08-10T00:00:00+00:00")
        self.assertEqual(evidence.metadata, {"tag": "code"})

    def test_declared_prefix_with_extra_args_is_eligible(self):
        self._write_tracked()
        config = self._config(
            TestCommand(id="unit", run=_PY + ' -c "pass"', tag="code")
        )
        # 선언 그대로가 아니라 추가 인자를 붙여 실행해도 자격이 있다.
        # python3 -c 는 추가 위치 인자를 sys.argv 로 받되 무시하므로
        # 여전히 exit 0 이다.
        command = _PY + ' -c "pass" extra-arg'
        evidence = observe_test_run(
            command,
            config,
            self.tag,
            self.paths,
            self.reader,
            self.tag_rules,
            policy_version="1",
            cwd=self.base,
        )
        self.assertEqual(evidence.result, VERDICT_PASS)

    def test_refusals_share_a_distinguishable_base(self):
        for exc in (
            UndeclaredTestCommand,
            TestRunFailed,
            TestRunDigestMismatch,
            TestRunSpawnError,
            ChangesetTagMismatch,
        ):
            self.assertTrue(issubclass(exc, TestsPassedEvidenceRefusal))


# ---------------------------------------------------------------------------
# (g) [사이클 B 리뷰 1회차 High] 자기진술 축 — 호출자가 명시하는 `tag`
# 인자가 declared.tag 와 다르면 spawn 이전에 거부한다.


class ChangesetTagBindingTest(_TmpDirMixin):
    def test_docs_declared_command_cannot_issue_for_code_changeset(self):
        # tag: docs 로 선언된 명령을, 자기진술 tag="code" 로 호출하면
        # 실제 실행이 정상 통과(exit 0)했을 명령이라도 발급되지 않는다.
        self._write_tracked()
        config = self._config(
            TestCommand(id="docs-check", run=_CMD_PASS, tag="docs")
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                _CMD_PASS,
                config,
                "code",  # 선언은 docs 인데 code 라고 자기진술
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_tag_mismatch_is_rejected_before_spawn(self):
        # 구조적 증명: 선언된 run 이 애초에 spawn 불가능한 명령이라도
        # (spawn 됐다면 TestRunSpawnError 가 났을 것) 자기진술 tag 불일치
        # 시 ChangesetTagMismatch 가 먼저 발생한다 — tag 결속 확인이
        # spawn 이전 단계에서 수행된다는 증거.
        config = self._config(
            TestCommand(
                id="ghost-docs",
                run="this-binary-does-not-exist-anywhere",
                tag="docs",
            )
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                "this-binary-does-not-exist-anywhere",
                config,
                "code",
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_matching_self_declared_tag_and_real_docs_path_issues(self):
        # 정상 결속 경로 — 자기진술 tag 가 declared.tag 와 같고, 실제
        # paths 도 그 tag 로 분류된다.
        self._use_tag("docs")
        self._write_tracked()  # tracked.md — docs 로 분류됨
        config = self._config(
            TestCommand(id="docs-check", run=_CMD_PASS, tag="docs")
        )
        evidence = observe_test_run(
            _CMD_PASS,
            config,
            "docs",
            self.paths,
            self.reader,
            self.tag_rules,
            policy_version="1",
            cwd=self.base,
        )
        self.assertEqual(evidence.result, VERDICT_PASS)
        self.assertEqual(evidence.metadata, {"tag": "docs"})

    def test_sensitive_tag_also_binds(self):
        # code/docs 뿐 아니라 sensitive 도 동일 규율 — 3종 전부 결속
        self._use_tag("sensitive")
        self._write_tracked()  # tracked.secret — sensitive 로 분류됨
        config = self._config(
            TestCommand(id="sec-check", run=_CMD_PASS, tag="sensitive")
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                _CMD_PASS,
                config,
                "docs",  # 자기진술부터 어긋남
                self.paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )
        evidence = observe_test_run(
            _CMD_PASS,
            config,
            "sensitive",
            self.paths,
            self.reader,
            self.tag_rules,
            policy_version="1",
            cwd=self.base,
        )
        self.assertEqual(evidence.metadata, {"tag": "sensitive"})


# ---------------------------------------------------------------------------
# (h) [사이클 B 리뷰 2회차 High 근본 수리] 실분류 축 — 신뢰된 tag_rules 로
# paths 를 실제 재분류해 declared.tag 와 대조한다. 자기진술(g)만으로는
# 막히지 않는 "같은 tag 문자열 + 다른 분류의 실경로" 동태 오결속을 막는다.


class ChangesetTagClassificationTest(_TmpDirMixin):
    def test_matching_self_declared_tag_with_misclassified_path_is_rejected(
        self,
    ):
        # 리뷰어 실증 시나리오 그대로: 호출자가 tag="docs" 라고
        # 자기진술하고(declared.tag 와 문자열로는 일치 — (g) 축 통과)
        # 실제로는 code 로 분류되는 경로를 paths 로 건넨다. (g)만
        # 있었다면 이 호출은 발급까지 진행됐을 것이다.
        code_paths = (_TAG_FILENAMES["code"],)
        self._write(code_paths[0], content=b"print('hi')\n")
        config = self._config(
            TestCommand(id="docs-check", run=_CMD_PASS, tag="docs")
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                _CMD_PASS,
                config,
                "docs",  # 자기진술은 declared.tag 와 일치 — (g) 축 통과
                code_paths,  # 그러나 실제 경로는 code 로 분류됨
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_missing_tag_rules_is_conservatively_rejected(self):
        # tag_rules 자체가 없으면(None) 재검증이 불가능하므로, 자기진술이
        # declared.tag 와 일치해도(문자열 축은 통과) 보수적으로 거부한다
        # — 확인 불가를 결속 확인됨으로 승격하지 않는다.
        self._write_tracked()  # 기본 tag="code" fixture
        config = self._config(
            TestCommand(id="unit", run=_CMD_PASS, tag="code")
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                _CMD_PASS,
                config,
                "code",
                self.paths,
                self.reader,
                None,  # tag_rules 미제공
                policy_version="1",
                cwd=self.base,
            )

    def test_mixed_paths_partial_match_is_rejected(self):
        # paths 중 하나라도 declared.tag 로 분류되지 않으면(혼합
        # ChangeSet) 전체 발급을 거부한다 — 부분 일치로 완화하지 않는다.
        self._use_tag("docs")
        self._write_tracked()  # tracked.md — docs 로 분류됨
        self._write("tracked.py", content=b"print('hi')\n")  # code 로 분류됨
        mixed_paths = self.paths + ("tracked.py",)
        config = self._config(
            TestCommand(id="docs-check", run=_CMD_PASS, tag="docs")
        )
        with self.assertRaises(ChangesetTagMismatch):
            observe_test_run(
                _CMD_PASS,
                config,
                "docs",
                mixed_paths,
                self.reader,
                self.tag_rules,
                policy_version="1",
                cwd=self.base,
            )

    def test_correctly_classified_paths_issue_evidence(self):
        # 정상 전 경로 — 자기진술도 일치하고 실제 재분류도 일치한다
        self._use_tag("sensitive")
        self._write_tracked()  # tracked.secret — sensitive 로 분류됨
        config = self._config(
            TestCommand(id="sec-check", run=_CMD_PASS, tag="sensitive")
        )
        evidence = observe_test_run(
            _CMD_PASS,
            config,
            "sensitive",
            self.paths,
            self.reader,
            self.tag_rules,
            policy_version="1",
            cwd=self.base,
        )
        self.assertEqual(evidence.metadata, {"tag": "sensitive"})


# ---------------------------------------------------------------------------
# (i) [사이클 B 리뷰 2회차 High 근본 수리] 평가 단계 tag 축 — 발급된
# evidence 의 metadata["tag"] 가 지금 평가 대상 ChangeSet 의 현재
# tag(changeset.tag fact)와 다시 일치해야 충족이다.


class TagAxisEvaluationTest(_TmpDirMixin):
    def setUp(self):
        super().setUp()
        self._use_tag("docs")
        self._write_tracked()
        self.digest = self._digest()
        self.evidence = self._make_evidence(self.digest, tag="docs")
        self.requirement = TestsPassedRequirement()

    def test_matching_metadata_tag_and_fact_tag_is_met(self):
        self.assertTrue(
            self.requirement.evaluate(
                self._context(
                    (self.evidence,), digest=self.digest, tag="docs"
                )
            )
        )

    def test_mismatched_fact_tag_is_unmet_despite_other_axes_matching(self):
        # digest/version/producer/result 전부 일치해도, 평가 대상
        # ChangeSet 의 현재 tag 가 evidence 의 결속 tag 와 다르면 미충족
        self.assertFalse(
            self.requirement.evaluate(
                self._context(
                    (self.evidence,), digest=self.digest, tag="code"
                )
            )
        )

    def test_absent_tag_fact_is_conservatively_unmet(self):
        self.assertFalse(
            self.requirement.evaluate(
                self._context(
                    (self.evidence,), digest=self.digest, tag=None
                )
            )
        )

    def test_metadata_without_tag_is_unmet(self):
        # metadata 에 tag 가 아예 없는(구버전/직접 조작) 레코드는 어떤
        # 현재 tag fact 와도 일치할 수 없다 — 보수적으로 미충족
        bare_evidence = self._make_evidence(self.digest, tag=None)
        self.assertFalse(
            self.requirement.evaluate(
                self._context(
                    (bare_evidence,), digest=self.digest, tag="docs"
                )
            )
        )


# ---------------------------------------------------------------------------
# policy version 축 (digest 와 독립, spec §3.4) — review/security 패턴 준용


class PolicyVersionAxisTest(_TmpDirMixin):
    def setUp(self):
        super().setUp()
        self._write_tracked()
        self.digest = self._digest()
        self.evidence = self._make_evidence(self.digest)
        self.requirement = TestsPassedRequirement()

    def _evaluate(self, policy_version, compatible=None):
        return self.requirement.evaluate(
            self._context(
                (self.evidence,),
                digest=self.digest,
                policy_version=policy_version,
                compatible=compatible,
            )
        )

    def test_same_digest_different_policy_version_is_unmet(self):
        self.assertFalse(self._evaluate(policy_version="2"))

    def test_declared_compatible_version_is_met(self):
        self.assertTrue(
            self._evaluate(policy_version="2", compatible=("1",))
        )

    def test_undeclared_version_is_unmet_despite_other_declarations(self):
        self.assertFalse(
            self._evaluate(policy_version="3", compatible=("2",))
        )

    def test_absent_policy_version_fact_is_conservatively_unmet(self):
        self.assertFalse(self._evaluate(policy_version=None))

    def test_absent_digest_fact_is_conservatively_unmet(self):
        requirement = TestsPassedRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((self.evidence,), digest=None)
            )
        )

    def test_evidence_alone_is_not_satisfaction_after_edit(self):
        # 발급 후 코드가 또 수정되면(subject != 현재 digest) 미충족
        self._write_tracked(content=b"edited\n")
        current = self._digest()
        self.assertNotEqual(current, self.digest)
        requirement = TestsPassedRequirement()
        self.assertFalse(
            requirement.evaluate(
                self._context((self.evidence,), digest=current)
            )
        )


# ---------------------------------------------------------------------------
# 등록 계약 (spec §3.1 §32 — 명시 코드 등록, import 부작용 아님)


class RegistrationTest(unittest.TestCase):
    def test_registration_is_explicit_not_import_side_effect(self):
        registry = RequirementRegistry()
        self.assertFalse(registry.is_registered(REQUIREMENT_NAME))
        implementation = register_tests_passed(registry)
        self.assertTrue(registry.is_registered(REQUIREMENT_NAME))
        self.assertIs(registry.resolve(REQUIREMENT_NAME), implementation)
        self.assertEqual(implementation.name, REQUIREMENT_NAME)
        self.assertIsInstance(implementation, TestsPassedRequirement)


if __name__ == "__main__":
    unittest.main()
