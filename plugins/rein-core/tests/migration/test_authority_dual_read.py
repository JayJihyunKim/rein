"""plan Task 6.1 — authority 전환 계층의 결합 판정 계약 (spec §7 Migration
Plan, §49, Scope ID
`authority-switches-per-capability-with-dual-read-of-legacy-markers`).

**Phase 7 웨이브 3 ③-d (2026-08-24) 갱신 — legacy marker dual-read 계층
전체 제거.** 이 파일은 원래 이름대로 "dual read"(legacy marker 를 v2
와 함께 읽어 대체하는 메커니즘) 를 검증하던 스위트였다. 그 메커니즘
자체가 이번 웨이브로 코드에서 삭제됐으므로(`authority.legacy_status`
및 그 하위 함수 전부, `LegacyStatus`/`LEGACY_PASS`/`LEGACY_FAIL`/
`LEGACY_ABSENT`/`SOURCE_LEGACY` 전부 제거), legacy marker *파싱*을
직접 검증하던 클래스들(`LegacyCodeReviewMarkerTest`/
`LegacySecurityReviewMarkerTest`/`LegacyActiveTaskMarkerTest`/
`LegacyMarkerAbsentByDesignTest`)은 대상 자체가 사라져 이 파일에서
제거됐다 — 처분 근거와 후계는
`docs/reports/wave3d-test-disposition.md` 참조. 파일명은 유지한다
(다른 테스트 파일의 docstring 이 상대 경로로 이 파일을 가리키므로,
가리키는 대상을 바꾸지 않기 위해 rename 하지 않음) — 남은 내용은 이제
"legacy marker 는 판정에 완전히 불참한다"를 행위로 고정하는 스위트다.

이 스위트가 지금 고정하는 계약 세 가지:

1. 전환 플래그 로드 — 프로젝트 override(`.rein/policy/authority.yaml`)가
   있으면 그것이 우선, 없으면 배포 기본값(`policies/authority.yaml`).
   (③-d 무영향 — 이 계약은 legacy marker 와 무관하다.)
2. 결합 판정(`resolve_authority`) — v2 판정(`bool`)이 항상 최종값
   (`SOURCE_V2`) / v2 가 판정할 재료가 없으면(`None`) 보수적 미충족
   (`SOURCE_NO_MATERIAL`, legacy 대체 없음) / 미전환 capability 는
   authority 가 개입하지 않음(v1 경로 유지). 정책 손상·미지 capability
   는 fail-closed(명시 에러). legacy marker 파일이 디스크에 있어도
   이 결합 판정에 전혀 참여하지 않는다는 것을 일부 테스트가 marker
   fixture 를 일부러 써서 증명한다(`ResolveAuthorityDualReadTest`).
3. capability 격리 — authority 는 engine 계층이고 `rein.capabilities.*`
   의 어떤 구현체도 import 하지 않는다(`AuthorityModuleIsolationTest`).
"""
import ast
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import authority  # noqa: E402
from rein.kernel.requirement import REQUIREMENT_NAMES  # noqa: E402


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _dod_dir(project_root):
    return os.path.join(project_root, "trail", "dod")


def _write_codex_stamp(
    project_root,
    verdict="PASS",
    reviewed_at="2026-08-01T00:00:00Z",
    cycle="3",
    extra="",
):
    _write(
        os.path.join(_dod_dir(project_root), ".codex-reviewed"),
        "verdict: {}\nreviewed_at: {}\ncycle: {}\n{}".format(
            verdict, reviewed_at, cycle, extra
        ),
    )


def _write_security_stamp(project_root, verdict="PASS", reviewed="2026-08-01T01:00:00", cycle="3"):
    _write(
        os.path.join(_dod_dir(project_root), ".security-reviewed"),
        "verdict={}\nreviewed={}\ncycle={}\n".format(verdict, reviewed, cycle),
    )


def _write_active_dod(project_root, slug="example-task", date="2026-08-01"):
    _write(
        os.path.join(_dod_dir(project_root), "dod-{}-{}.md".format(date, slug)),
        "# DoD\n\n- date: {}\n".format(date),
    )


def _write_project_authority_policy(project_root, names):
    _write(
        os.path.join(project_root, ".rein", "policy", "authority.yaml"),
        "switched:\n" + "".join("  - {}\n".format(name) for name in names),
    )


class AuthorityPolicyLoadTest(unittest.TestCase):
    """정책 로드 — 배포 기본값 / 프로젝트 override 우선순위."""

    def test_default_policy_used_when_project_has_no_override_file(self):
        with tempfile.TemporaryDirectory() as project_root:
            switched = authority.load_authority_policy(project_root=project_root)
        # Phase 7 결정 4(사용자 결정, 2026-08-19) — 배포 기본값은 실배선
        # 3축(code_review/security_review/active_task)만 전환한다.
        # 이전(Task 6.1, 2026-08-12)의 "5종 전부" 결정은 폐기됐다 — 남은
        # 2축(tests_passed/user_approval)은 증거 발급 배선이 프로덕션에
        # 0건이라 전환 상태에서 매칭 정책을 만나면 legacy 대체값도 항상
        # ABSENT 라서 영구 차단되는 지뢰였다(근거: authority.py 의
        # DEFAULT_SWITCHED_CAPABILITIES 주석, docs/reports/
        # v2-phase-gates.md "Task 6.1 종결" 절). "단언 약화" 가 아니라
        # 정확한 3축 집합 동등 비교로 갱신한다.
        self.assertEqual(
            switched, frozenset({"code_review", "security_review", "active_task"})
        )

    def test_project_override_takes_precedence_over_default(self):
        with tempfile.TemporaryDirectory() as project_root:
            _write_project_authority_policy(project_root, ["code_review"])
            switched = authority.load_authority_policy(project_root=project_root)
        self.assertEqual(switched, frozenset({"code_review"}))

    def test_none_project_root_uses_deployed_default_directly(self):
        # 위 test_default_policy_used_when_project_has_no_override_file 과
        # 동일한 3축 배포 기본값(Phase 7 결정 4, 2026-08-19) — project_root
        # 가 아예 None 인 경로도 같은 상수를 그대로 반환하는지 확인한다.
        switched = authority.load_authority_policy(project_root=None)
        self.assertEqual(
            switched, frozenset({"code_review", "security_review", "active_task"})
        )

    def test_default_is_an_internal_constant_not_a_shipped_policies_file(self):
        # 배포 기본값은 plugins/rein-core/policies/ 아래 파일이 아니라 이
        # 모듈의 내부 상수다 — governance policy 전용 디렉토리(스키마
        # trigger/when/require/failure_mode 로 폐쇄, kernel/policy.py)에
        # authority 전환 플래그를 얹으면 그 디렉토리의 폐쇄 스키마 계약과
        # 충돌한다(실측: tests/contract/test_default_policy_matrix.py 의
        # DirectoryIsolationTest 가 policies/ 바로 아래 로드 시 발생하는
        # 스키마 충돌 자체를 계약으로 고정하고 있다 — 그 디렉토리에 세
        # 번째 스키마 파일을 두면 그 테스트가 기대하는 에러 메시지가
        # 깨진다). 값 자체는 REQUIREMENT_NAMES 5종 전부가 아니라 그
        # 부분집합 3축(Phase 7 결정 4, 2026-08-19) — REQUIREMENT_NAMES 는
        # 여전히 5종 고정 어휘이므로 부분집합 비교로 그 사실도 함께
        # 고정한다.
        self.assertEqual(
            authority.DEFAULT_SWITCHED_CAPABILITIES,
            frozenset({"code_review", "security_review", "active_task"}),
        )
        self.assertLess(authority.DEFAULT_SWITCHED_CAPABILITIES, frozenset(REQUIREMENT_NAMES))
        self.assertFalse(hasattr(authority, "DEFAULT_POLICY_PATH"))

    def test_default_excludes_evidence_issuance_unwired_axes(self):
        # 신규(항목 a) — tests_passed/user_approval 이 배포 기본값에서
        # 명시적으로 빠졌음을 직접 단언한다. 사유: 두 축은 증거 발급
        # 진입점(observe_test_run/issue_user_approval_evidence — 재편입
        # 조건의 정본은 canonical spec §3.6 "전환 유예" 절)의
        # 프로덕션 호출자가 0건이라(당시 legacy_status() 도 이 두 축엔
        # 항상 LEGACY_ABSENT 를 반환했다 — 그 함수는 ③-d 로 제거됐다),
        # 전환 상태에서 이 두 축을 요구하는 정책을 만나면 v2 evidence
        # 를 얻지 못해 resolve_authority() 가 항상 satisfied=False 로
        # fail-closed 된다(③-d 이후로는 legacy 대체 자체가 없으므로
        # 이 결론은 오히려 더 직접적으로 성립한다). 그 요구를 실제로
        # 발동시킬 판정부(push/태그 시점 게이트, one-shot 승인 집행부)
        # 가 v1 에도 v2 에도 없으므로 이는 "정상적인 보수적 차단"이
        # 아니라 빠져나갈 길이 없는 영구 차단이다 — 그래서 기본값에서
        # 뺐다(재편입 조건은 authority.py DEFAULT_SWITCHED_CAPABILITIES
        # 주석 참조).
        self.assertNotIn("tests_passed", authority.DEFAULT_SWITCHED_CAPABILITIES)
        self.assertNotIn("user_approval", authority.DEFAULT_SWITCHED_CAPABILITIES)

    def test_authority_policies_directory_has_no_authority_yaml(self):
        # 실측 가드 — 배포 policies/ 디렉토리에 authority.yaml 이 다시
        # 생기면(회귀) DirectoryIsolationTest 가 깨지는 방식으로만 뒤늦게
        # 드러난다. 이 테스트가 authority 모듈 자신의 스위트에서 그
        # 전제를 직접 고정한다.
        policies_root = os.path.join(_PLUGIN_ROOT, "policies")
        self.assertFalse(
            os.path.isfile(os.path.join(policies_root, "authority.yaml")),
            msg=(
                "plugins/rein-core/policies/ 는 governance policy 전용"
                "디렉토리다 — authority 전환 플래그를 여기 두지 않는다"
            ),
        )

    def test_empty_switched_set_expressed_via_none_sentinel(self):
        # Medium 6-3 — D3 subset 문법은 빈 block sequence 를 표현할 방법이
        # 없다(빈 `switched:` 는 파싱 에러, flow style `[]` 는 명시 거부).
        # authority 자신의 폐쇄 스키마 안에서 스칼라 sentinel `none` 하나로
        # "전부 미전환" 을 표현한다 (문법 확장 없이).
        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: none\n",
            )
            switched = authority.load_authority_policy(project_root=project_root)
        self.assertEqual(switched, frozenset())

    def test_empty_block_sequence_syntax_still_rejected_by_the_shared_parser(self):
        # 대조군 — D3 grammar 를 건드리지 않았다는 사실 자체를 고정한다.
        # 빈 `switched:` (뒤에 항목 없음) 는 여전히 파싱 에러다.
        with self.assertRaises(authority.AuthorityPolicyError):
            authority.parse_authority_policy("switched:\n", source="<test>")

    def test_authority_override_coexists_with_other_dot_rein_policy_files(self):
        # .rein/policy/ 는 v1 파일(hooks.yaml/persona.yaml/rules.yaml) +
        # testing capability 의 testing.yaml 과 공존하는 디렉토리다 —
        # authority.yaml 로더가 디렉토리를 스캔하지 않고 자기 이름의
        # 파일만 읽는지, 그리고 그 반대(기존 파일 로더가 authority.yaml
        # 존재로 영향받지 않는지) 둘 다 확인한다.
        with tempfile.TemporaryDirectory() as project_root:
            policy_dir = os.path.join(project_root, ".rein", "policy")
            os.makedirs(policy_dir, exist_ok=True)
            # 이질 스키마의 v1/다른 capability 파일들 — authority 로더가
            # 이들을 읽으려 시도하면 파싱 에러가 나야 정상인데, 그런 일이
            # 없어야 한다(디렉토리 스캔 없음).
            _write(os.path.join(policy_dir, "hooks.yaml"), "not: valid: authority: schema\n")
            _write(os.path.join(policy_dir, "persona.yaml"), "persona: jennie\n")
            _write(os.path.join(policy_dir, "rules.yaml"), "- rule one\n- rule two\n")
            _write(
                os.path.join(policy_dir, "testing.yaml"),
                "testing:\n  commands:\n    - id: unit\n      run: pytest\n      tag: code\n",
            )
            _write_project_authority_policy(project_root, ["code_review"])

            switched = authority.load_authority_policy(project_root=project_root)
            self.assertEqual(switched, frozenset({"code_review"}))

            # 반대 방향 — testing capability 의 실제 로더가 authority.yaml
            # 의 존재로 영향받지 않는지도 확인 (같은 디렉토리, 다른 파일명).
            from rein.capabilities.testing.capability import load_testing_config

            testing_config = load_testing_config(
                os.path.join(policy_dir, "testing.yaml")
            )
            self.assertEqual(len(testing_config.commands), 1)


class AuthorityPolicyFailClosedTest(unittest.TestCase):
    """정책 파일 손상 / 미지 capability 이름 — 조용한 통과 금지."""

    def test_corrupt_policy_file_raises_instead_of_falling_back_silently(self):
        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: not-a-list\n",
            )
            with self.assertRaises(authority.AuthorityPolicyError):
                authority.load_authority_policy(project_root=project_root)

    def test_unsupported_top_level_field_rejected(self):
        with self.assertRaises(authority.AuthorityPolicyError):
            authority.parse_authority_policy(
                "switched:\n  - code_review\nextra_field: true\n",
                source="<test>",
            )

    def test_missing_switched_field_rejected(self):
        with self.assertRaises(authority.AuthorityPolicyError):
            authority.parse_authority_policy("other: 1\n", source="<test>")

    def test_unknown_capability_name_in_policy_file_rejected(self):
        with self.assertRaises(authority.AuthorityPolicyError):
            authority.parse_authority_policy(
                "switched:\n  - not_a_real_capability\n", source="<test>"
            )

    def test_duplicate_capability_name_in_policy_file_rejected(self):
        with self.assertRaises(authority.AuthorityPolicyError):
            authority.parse_authority_policy(
                "switched:\n  - code_review\n  - code_review\n", source="<test>"
            )

    def test_unreadable_policy_file_raises(self):
        with tempfile.TemporaryDirectory() as project_root:
            missing_default = os.path.join(project_root, "nope.yaml")
            with self.assertRaises(authority.AuthorityPolicyError):
                authority._load_policy_file(missing_default)

    def test_unknown_capability_name_query_rejected(self):
        with self.assertRaises(authority.UnknownCapabilityError):
            authority.is_switched("not_a_real_capability")

    def test_unknown_capability_name_in_resolve_authority_rejected(self):
        with tempfile.TemporaryDirectory() as project_root:
            with self.assertRaises(authority.UnknownCapabilityError):
                authority.resolve_authority(
                    "not_a_real_capability", None, project_root
                )

    # (③-d 로 제거됨: test_unknown_capability_name_in_legacy_status_rejected
    # — `legacy_status()` 자체가 삭제되어 대상이 사라졌다. 동일 계약
    # ["미지 capability 이름은 UnknownCapabilityError로 fail-closed"] 은
    # 바로 위 test_unknown_capability_name_query_rejected(`is_switched`)
    # 와 test_unknown_capability_name_in_resolve_authority_rejected
    # (`resolve_authority`) 가 이미 커버한다 — legacy_status 는 이
    # 검증 대상이던 세 함수(`is_switched`/`resolve_authority`/
    # `legacy_status`) 중 하나였을 뿐이라 무대체 소멸이 아니다.)

    def test_override_path_is_a_directory_fails_closed_not_treated_as_absent(self):
        # Medium 6-2 — 이전 구현은 override 경로가 존재하지만 일반
        # 파일이 아니면(디렉터리 등) `os.path.isfile()` 이 False 를
        # 반환해 "override 없음"으로 조용히 배포 기본값으로 흘렀다.
        # 경로에 뭔가 존재하는데 읽을 수 없는 형태라면 손상으로 거부
        # 해야 한다 — 부재와 손상을 구분하지 못하면 안 된다.
        with tempfile.TemporaryDirectory() as project_root:
            override_path = os.path.join(
                project_root, ".rein", "policy", "authority.yaml"
            )
            os.makedirs(override_path)
            with self.assertRaises(authority.AuthorityPolicyError):
                authority.load_authority_policy(project_root=project_root)

    def test_dangling_symlink_override_path_fails_closed_not_defaulted(self):
        # High 2 (Phase 6 4회차 리뷰) — 리뷰어 재현: `os.path.exists()`
        # 는 심볼릭 링크를 따라가 그 **대상**이 존재하는지 본다. 링크가
        # 매달려 있으면(대상이 없으면) `exists()` 는 `False` 를 반환해
        # "override 없음"과 구별되지 않았다 — 이전 구현은 그 결과 손상된
        # override 를 배포 기본값(5종 전부 전환)으로 조용히 대체했다
        # (`silently_defaulted 5`, fail-open: 정책 손상이 authority 의
        # 적용 범위를 오히려 넓힌다). lstat 기반 구현은 이 경로 자체에
        # "뭔가 있다"(심볼릭 링크)는 사실을 놓치지 않고 명시 거부한다.
        with tempfile.TemporaryDirectory() as project_root:
            override_path = os.path.join(
                project_root, ".rein", "policy", "authority.yaml"
            )
            os.makedirs(os.path.dirname(override_path), exist_ok=True)
            os.symlink(
                os.path.join(project_root, "does-not-exist.yaml"),
                override_path,
            )
            with self.assertRaises(authority.AuthorityPolicyError):
                authority.load_authority_policy(project_root=project_root)

    def test_valid_symlink_override_path_is_still_rejected(self):
        # 대상이 실제로 존재하는(매달리지 않은) 심볼릭 링크도 거부한다
        # — 이 저장소의 다른 방어(`rein.platform.storage.approval_store.
        # _reject_symlink_or_special`)와 동일하게, 대상이 무엇을
        # 가리키는지와 무관하게 심볼릭 링크 자체를 거부한다(TOCTOU
        # 완화 — 링크는 검사와 사용 사이에 다른 곳을 가리키도록 바뀔 수
        # 있다). "매달린 링크만 특별 취급"이 아니라 "심볼릭 링크는
        # 전부 특별 취급"임을 고정한다.
        with tempfile.TemporaryDirectory() as project_root:
            target_path = os.path.join(project_root, "real-authority.yaml")
            _write(target_path, "switched:\n  - code_review\n")
            override_path = os.path.join(
                project_root, ".rein", "policy", "authority.yaml"
            )
            os.makedirs(os.path.dirname(override_path), exist_ok=True)
            os.symlink(target_path, override_path)
            with self.assertRaises(authority.AuthorityPolicyError):
                authority.load_authority_policy(project_root=project_root)

    def test_inaccessible_override_path_fails_closed_not_defaulted(self):
        # "접근 불가"(권한 거부 등)도 부재로 위장하지 않는다 — 이
        # 함수는 `FileNotFoundError`(ENOENT)만 "진짜 부재"로 인정한다.
        # 그 외 `OSError` 는 손상과 동일하게 명시 거부한다(모듈 docstring
        # "lstat 로 진짜 부재만..." 절 — approval_store 의
        # `_reject_symlink_or_special` 과 달리 이 함수는 파일을 새로
        # 만들지 않으므로, 접근 불가를 "아직 없으니 안전"으로 흡수할
        # 이유가 없다).
        from unittest import mock

        with tempfile.TemporaryDirectory() as project_root:
            with mock.patch(
                "os.lstat", side_effect=PermissionError("denied")
            ):
                with self.assertRaises(authority.AuthorityPolicyError):
                    authority.load_authority_policy(project_root=project_root)


class AuthorityModuleIsolationTest(unittest.TestCase):
    """authority 는 engine 계층 — `rein.capabilities.*` 구현체를 import
    하지 않는다(spec §3.1 §31/§4.1 capability 간 직접 의존 금지의 대칭
    원칙). 이 테스트는 그 구분을 주석이 아니라 정적 검사로 고정한다:
    `rein/engine/authority.py` 의 AST 에 `import rein.capabilities...` /
    `from rein.capabilities... import ...` 형태가 0건이어야 한다.

    (③-d 로 제거됨: test_security_legacy_status_cross_checks_via_files_only
    — `legacy_status()`/`_legacy_security_review_status` 자체가
    삭제되어 "legacy 교차비교가 파일 두 개만 읽어 완결된다"는 대상이
    사라졌다. `.codex-reviewed`/`.security-reviewed` 교차비교 메커니즘
    자체가 코드에서 제거됐으므로 후계 테스트는 불필요 — 부재 증명은
    `tests/bypass/test_marker_bypass_removed.py` 의 정적 회귀 핀이
    맡는다. 이 클래스의 나머지 계약(capability 미-import)은 아래
    유일한 테스트가 이미 커버하고 있어 무대체 소멸이 아니다.)
    """

    def test_authority_module_imports_no_capability_implementation(self):
        source_path = authority.__file__
        with open(source_path, "r", encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), filename=source_path)
        offenders = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.startswith("rein.capabilities"):
                        offenders.append(alias.name)
            elif isinstance(node, ast.ImportFrom):
                module = node.module or ""
                if module.startswith("rein.capabilities"):
                    offenders.append(module)
        self.assertEqual(
            offenders,
            [],
            msg=(
                "rein/engine/authority.py imports a capability "
                "implementation — engine 계층은 capability 구현을 직접 "
                "끌어오지 않는다(spec §3.1 §31/§4.1): {!r}".format(offenders)
            ),
        )


class ResolveAuthorityDualReadTest(unittest.TestCase):
    """결합 판정 — DoD 최소 케이스 + 경계.

    **③-d 갱신** — 이 클래스 이름·개별 테스트 다수는 ③-a 시절("v1
    marker 단독으로도 인정되는 dual read")의 유산이다. legacy marker
    대체가 제거된 지금 이 클래스는 그 반대, 즉 **legacy marker 가 더
    이상 판정에 참여하지 않는다**는 것을 고정한다 — marker fixture 를
    일부러 쓰거나 안 써서 결과가 바뀌지 않음을 증명하는 케이스가
    다수다. 클래스 이름은 유지한다(파일 자체의 "dual read" 이름을
    유지하는 것과 동일한 사유 — 다른 파일이 이 스위트를 가리키는
    docstring 참조가 있다).

    (c) "미전환 축은 개입하지 않는다"는 일반 계약은 이미
    `test_unswitched_capability_is_not_intercepted` (아래)가 override 로
    미전환시킨 축을 통해 고정하고 있다 — 이 클래스의 신규 테스트
    (`test_default_policy_does_not_switch_evidence_issuance_unwired_axes`)
    는 같은 계약을 "override 없이도 배포 기본값 자체가 이미 미전환인
    축"이라는 새 시나리오로 재확인할 뿐, 메커니즘 자체는 이 포인터가
    가리키는 테스트가 원본이다.
    """

    def test_none_with_fresh_legacy_marker_present_is_conservatively_unmet(self):
        # ③-d 갱신 — 이전 이름은 test_v1_marker_only_is_recognized_via_
        # dual_read 였고, v2 evidence 없음(None) + legacy PASS 조합이
        # "인정"(satisfied=True, SOURCE_LEGACY)으로 이어지는 것을
        # 고정했다. legacy 대체가 제거된 지금, 신선 PASS marker 가
        # 디스크에 있어도(marker 는 판정에 완전히 불참) v2_satisfied=
        # None(판정할 재료 없음)은 보수적으로 미충족이다 — spec §3.6
        # 위 모듈 docstring 계약 2 "resolve_authority: None→False+비
        # legacy source" 를 이 케이스가 직접 고정한다.
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="PASS")
            result = authority.resolve_authority(
                "code_review", None, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertFalse(result.satisfied)
        self.assertEqual(result.source, authority.SOURCE_NO_MATERIAL)

    def test_v2_false_wins_regardless_of_legacy_marker_content(self):
        # legacy marker 는 PASS 내용이지만 v2 evidence 가 명시적으로
        # 미충족 → v2 승(marker 는 읽히지도 않으므로 "충돌"이라는
        # 개념 자체가 이제 없다 — 결과는 marker 내용과 무관하게 v2 그대로).
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="PASS")
            result = authority.resolve_authority(
                "code_review", False, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertFalse(result.satisfied)
        self.assertEqual(result.source, authority.SOURCE_V2)

    def test_v2_true_wins_regardless_of_legacy_marker_content(self):
        # legacy marker 는 FAIL 내용(verdict NEEDS-FIX)이지만 v2
        # evidence 가 충족 → v2 승.
        with tempfile.TemporaryDirectory() as project_root:
            _write_codex_stamp(project_root, verdict="NEEDS-FIX")
            result = authority.resolve_authority(
                "code_review", True, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertTrue(result.satisfied)
        self.assertEqual(result.source, authority.SOURCE_V2)

    def test_unswitched_capability_is_not_intercepted(self):
        # code_review 만 전환된 프로젝트에서 security_review 는 authority
        # 가 판정에 개입하지 않는다 — legacy PASS 든 v2 True 든 무관.
        with tempfile.TemporaryDirectory() as project_root:
            _write_project_authority_policy(project_root, ["code_review"])
            _write_security_stamp(project_root, verdict="PASS")
            result = authority.resolve_authority(
                "security_review", True, project_root
            )
        self.assertFalse(result.intercepted)
        self.assertIsNone(result.satisfied)
        self.assertIsNone(result.source)

    def test_default_policy_switches_all_three_wired_axes_when_project_has_no_override(
        self,
    ):
        # Phase 7 결정 4(2026-08-19) 이후의 배포 기본값 — code_review/
        # security_review/active_task 3축. 여기서는 code_review 로 v2
        # evidence 승리 경로를 대표 확인한다(집합 전체의 동등 비교는
        # AuthorityPolicyLoadTest.
        # test_default_policy_used_when_project_has_no_override_file 이
        # 이미 고정한다 — 이 테스트는 resolve_authority 결합까지 실제로
        # 이어지는지를 행위로 재확인하는 것이 목적).
        with tempfile.TemporaryDirectory() as project_root:
            result = authority.resolve_authority(
                "code_review", True, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertEqual(result.source, authority.SOURCE_V2)

    def test_default_policy_does_not_switch_evidence_issuance_unwired_axes(self):
        # tests_passed/user_approval 은 더 이상 배포 기본값에 없다(Phase 7
        # 결정 4, 2026-08-19 — AuthorityPolicyLoadTest.
        # test_default_excludes_evidence_issuance_unwired_axes 와 동일
        # 사유). override 없이 이 두 축을 resolve_authority 로 조회하면
        # authority 가 판정에 전혀 개입하지 않아야 한다
        # (intercepted=False, satisfied/source 는 placeholder None) — v2
        # true 를 명시적으로 넘겨도(user_approval) 결과가 뒤집히지
        # 않는다는 것까지 함께 고정한다(개입하지 않는다는 계약이 v2
        # 값의 진위와 무관함을 보이기 위해).
        with tempfile.TemporaryDirectory() as project_root:
            result_tests = authority.resolve_authority(
                "tests_passed", None, project_root
            )
            result_approval = authority.resolve_authority(
                "user_approval", True, project_root
            )
        self.assertFalse(result_tests.intercepted)
        self.assertIsNone(result_tests.satisfied)
        self.assertIsNone(result_tests.source)
        self.assertFalse(result_approval.intercepted)
        self.assertIsNone(result_approval.satisfied)
        self.assertIsNone(result_approval.source)

    def test_corrupt_project_policy_fails_closed_instead_of_defaulting(self):
        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched:\n  - code_review\nbogus_field: 1\n",
            )
            with self.assertRaises(authority.AuthorityPolicyError):
                authority.resolve_authority("code_review", None, project_root)

    def test_switched_capability_with_no_v2_material_is_not_satisfied(self):
        # tests_passed: 더 이상 배포 기본값에 없으므로(Phase 7 결정 4,
        # 2026-08-19) 이 테스트는 override 로 명시 전환한다 — opt-in
        # 경로가 여전히 동작한다는 것도 이 테스트가 함께 고정한다. 원래
        # 이름("...no_legacy_evidence...")은 legacy 대체 존재를 전제한
        # 표현이었다 — ③-d 이후로는 "v2 가 판정할 재료 자체가 없음"만
        # 남는다. 취지(전환된 증거발급형 capability + v2 재료 없음 →
        # fail-closed, 조용한 통과 금지)는 그대로다.
        with tempfile.TemporaryDirectory() as project_root:
            _write_project_authority_policy(project_root, ["tests_passed"])
            result = authority.resolve_authority(
                "tests_passed", None, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertFalse(result.satisfied)
        self.assertEqual(result.source, authority.SOURCE_NO_MATERIAL)

    def test_active_task_none_with_fresh_legacy_dod_file_present_is_still_unmet(
        self,
    ):
        # ③-d 갱신 — 이전 이름은 test_active_task_dual_read_end_to_end
        # 였고, `trail/dod/dod-*.md` pending 파일(legacy marker)이
        # 있으면 v2_satisfied=None 이 satisfied=True(SOURCE_LEGACY)로
        # 인정됐다. active_task 도 code_review 와 동일한 결합 규칙을
        # 따르는지(모듈이 축 전체 공용 결합기임을 확인 — capability별
        # 결합 규칙이 하나라도 잘못 배선되면 이 테스트가 잡는다) 여기서
        # 재확인한다: dod 파일이 디스크에 있어도 resolve_authority 에
        # None 을 직접 넘기면 보수적으로 미충족이다(marker 는 이제
        # 판정에 불참 — 실제 evaluator 배선에서는 애초에 active_task
        # 가 fact 판정형이라 registry 가 있으면 이 None 경로 자체에
        # 도달하지 않는다, `authority.FACT_JUDGED_CAPABILITIES` 참조 —
        # 이 테스트는 resolve_authority 단위 계약만 고정한다).
        with tempfile.TemporaryDirectory() as project_root:
            _write_active_dod(project_root)
            result = authority.resolve_authority(
                "active_task", None, project_root
            )
        self.assertTrue(result.intercepted)
        self.assertFalse(result.satisfied)
        self.assertEqual(result.source, authority.SOURCE_NO_MATERIAL)

    def test_v2_satisfied_truthy_string_is_rejected_not_coerced(self):
        # Medium 6-1 — 이전 구현은 `bool(v2_satisfied)` 로 무조건 강제
        # 변환했다. 문자열 `"false"` 는 비어있지 않으므로 Python 에서
        # 항상 truthy 다 — `bool("false") == True` 함정으로 실제로는
        # "미충족"을 뜻하려던 호출자의 의도가 조용히 "충족"으로 승격될
        # 수 있었다. 이제는 None/bool 이외 타입을 명시 거부한다.
        with tempfile.TemporaryDirectory() as project_root:
            with self.assertRaises(authority.AuthorityError):
                authority.resolve_authority(
                    "code_review", "false", project_root
                )

    def test_v2_satisfied_zero_int_is_rejected_not_coerced(self):
        # bool 은 int 의 하위형이므로 `isinstance(0, bool)` 은 False —
        # 0/1 같은 int 도 강제 변환 대상이 아니라 거부 대상이다.
        with tempfile.TemporaryDirectory() as project_root:
            with self.assertRaises(authority.AuthorityError):
                authority.resolve_authority("code_review", 0, project_root)

    def test_switched_injection_bypasses_policy_load(self):
        # switched 를 직접 주입하면 project_root 의 정책 파일을 읽지
        # 않는다 — 손상된 정책 파일이 있어도 주입값이 그대로 쓰인다.
        with tempfile.TemporaryDirectory() as project_root:
            _write(
                os.path.join(project_root, ".rein", "policy", "authority.yaml"),
                "switched: not-a-list\n",
            )
            result = authority.resolve_authority(
                "code_review",
                True,
                project_root,
                switched=frozenset({"code_review"}),
            )
        self.assertTrue(result.intercepted)
        self.assertTrue(result.satisfied)


if __name__ == "__main__":
    unittest.main()
