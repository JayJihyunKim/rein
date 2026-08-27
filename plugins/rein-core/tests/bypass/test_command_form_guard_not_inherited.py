"""spec §3.6 "digest scope 프로필" 절 — v1 명령 형태 검사(TOCTOU 가드) 비계승.

spec §3.6 원문(요지, `docs/specs/2026-08-07-rein-v2-governance-orchestration.md`
§3.6 security_review 절 "v1 면제의 명령 형태 검사(TOCTOU 가드) 비계승" 항):
    "v1 의 단독-명령·서브셸 금지 검사는 이관하지 않는다 ... digest 내용
    결속은 평가 사이클 사이의 대상 변경을 무효화한다 ... 이미 허용된
    같은 복합 명령 내부의 stage→commit 변경은 재평가되지 않으므로 차단
    하지 못한다 ... 이 간극은 §2.2 정직한 에이전트 위협 모델 + §3.2 의
    실행 규율 범위에서 수용한다."

`rein/platform/git/facts.py` 의 `strict_security_digest()`(spec §3.6
"digest scope 프로필" 절, 2026-08-19 신설)는 v1
`hooks/lib/security-review-gate.sh` 의 subject digest 산정 로직 4개
(`_sx_path_is_doc_or_trail`/`_sx_version_only_rein_sh`/
`_sx_version_only_plugin_json`/`_sx_classify_paths`)만 python 으로
재현한다 — 그 옆에 있던 **명령 형태 검사**(`_sx_command_has_eval_or_
subshell`/`_sx_command_form_ok`, TOCTOU 가드: eval/서브셸/process
substitution 사용 여부·단독 단순 명령 형태 여부를 판정해 그 판정에
따라 커밋을 막는 v1 전용 로직)는 spec 이 명시적으로 "비계승"을 결정한
항목이다 — subject digest 산정과는 별개 관심사이고, 옮기지 않아도
되는 근거(간극 수용 범위)가 spec 원문에 이미 있다.

이 스위트는 그 비계승 결정이 실제로 지켜지고 있음을 정적으로 고정한다
— v2 평가 경로(`rein/` 패키지 트리)의 **실제 코드**(주석·docstring 제외)
어디에도 v1 명령 형태 검사의 식별자(`_sx_command_*` 계열)나 그 재구현이
없다. `tests/bypass/test_marker_bypass_removed.py` 가 이미 확립한
"코드만 스캔(docstring/주석 제외) + 자기매칭 함정 회피" 관례를 그대로
재사용한다(`_code_only`/`_python_files`/`_REIN_PACKAGE_ROOT` import) —
그 관례를 재구현하지 않는다. 이 파일의 여러 docstring 자신이 `_sx_
command_*` 식별자를 실제로 인용하는 것은(위 문단들) 이 비계승 결정을
설명하는 정당한 문서화이지 인식 경로가 아니다 — `_code_only` 가 이를
스캔에서 제외한다(`test_marker_bypass_removed.py` 의 동일 원칙).

**한계** (`test_marker_bypass_removed.py` 모듈 docstring "정적 검사의
한계" 절과 동일 성격): 이 스캔은 리터럴 identifier substring 매치다.
조립된 문자열이나 다른 이름으로 같은 TOCTOU 판정 로직을 재구현하면
잡지 못한다 — 정직한 Agent 가 실수로 v1 식별자를 그대로 복제하는 것을
막는 규율 장치이지, 의미론적으로 동등한 로직의 존재를 전부 잡는 검사가
아니다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

# 기존 bypass 스위트의 code-only 스캔 관례를 재사용한다 (재구현 금지) —
# `_code_only`(docstring/주석을 지운 소스), `_python_files`(재귀 .py
# 목록), `_REIN_PACKAGE_ROOT`(스캔 루트) 셋 다 그대로 가져다 쓴다.
from tests.bypass.test_marker_bypass_removed import (  # noqa: E402
    _REIN_PACKAGE_ROOT,
    _code_only,
    _python_files,
)

# v1 TOCTOU 가드 식별자 — `hooks/lib/security-review-gate.sh` 의 실제
# 함수명(모듈 docstring 인용). 조립하지 않고 리터럴로 둔다: 이 파일
# 자신은 이 이름들을 "코드"로 정의/호출하지 않고 문자열 상수로만
# 다루므로(할당문 우변), `_code_only` 스캔 대상(`rein/` 패키지 트리)에
# 이 테스트 파일 자체가 포함되지 않는 한(스캔 루트가 `rein/` 하나로
# 고정돼 있으므로 포함되지 않는다, 아래 자기매칭 회피 테스트가 그
# 전제를 고정한다) 자기매칭 위험이 없다.
_TOCTOU_GUARD_IDENTIFIERS = (
    "_sx_command_has_eval_or_subshell",
    "_sx_command_form_ok",
)

# 더 넓은 계열 탐지 — v1 이 이 TOCTOU 가드류에 일관되게 쓰는 이름
# 접두어. 위 정확한 이름 2개만으로는 앞으로 v1 쪽에 같은 계열의 새
# 헬퍼가 추가돼도 이 스위트가 못 잡는다 — 접두어 자체의 부재까지
# 함께 고정해 더 보수적으로(과잉 탐지 방향으로) 검증한다.
_TOCTOU_GUARD_PREFIX = "_sx_"


class CommandFormGuardNotInheritedTest(unittest.TestCase):
    def test_scan_root_excludes_this_suite_itself(self):
        # `test_marker_bypass_removed.py` 와 동일한 전제 가드 — 스캔
        # 루트(`rein/`)가 `tests/` 를 포함하지 않아야 이 파일 자신의
        # 식별자 상수 리터럴이 자기 자신을 위반으로 오탐하지 않는다.
        this_file = os.path.abspath(__file__)
        self.assertFalse(
            this_file.startswith(_REIN_PACKAGE_ROOT + os.sep),
            msg="bypass 스위트 자신이 스캔 루트(rein/) 밖에 있어야 한다",
        )

    def test_exact_v1_toctou_guard_identifiers_absent_from_v2_code(self):
        """v1 함수명 2개가 v2 실제 코드(주석/docstring 제외)에 0건."""
        self.assertTrue(os.path.isdir(_REIN_PACKAGE_ROOT))
        offenders = []
        scanned = 0
        for path in _python_files(_REIN_PACKAGE_ROOT):
            scanned += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            code_only = _code_only(source)
            for identifier in _TOCTOU_GUARD_IDENTIFIERS:
                if identifier in code_only:
                    offenders.append((path, identifier))
        self.assertGreater(
            scanned,
            0,
            msg="스캔된 .py 파일이 0건이면 아래 부재 단언이 공허하게 통과한다",
        )
        self.assertEqual(
            offenders,
            [],
            msg=(
                "v2 소스의 실제 코드에서 v1 명령 형태(TOCTOU) 가드 식별자 "
                "발견 — spec §3.6 이 명시한 비계승 결정 위반 (docstring/"
                "주석 속 설명 인용은 제외됨): {!r}".format(offenders)
            ),
        )

    def test_v1_toctou_guard_prefix_family_absent_from_v2_code(self):
        """`_sx_` 접두어 계열 전체가 v2 실제 코드에 0건 (더 보수적인 상위 검사)."""
        self.assertTrue(os.path.isdir(_REIN_PACKAGE_ROOT))
        offenders = []
        scanned = 0
        for path in _python_files(_REIN_PACKAGE_ROOT):
            scanned += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            code_only = _code_only(source)
            if _TOCTOU_GUARD_PREFIX in code_only:
                offenders.append(path)
        self.assertGreater(scanned, 0)
        self.assertEqual(
            offenders,
            [],
            msg=(
                "v2 소스의 실제 코드에서 v1 전용 명명 접두어 {!r} 발견 — "
                "strict_security_digest() 는 subject digest 산정만 "
                "재현하고 명령 형태 검사는 재구현하지 않아야 한다 (spec "
                "§3.6): {!r}".format(_TOCTOU_GUARD_PREFIX, offenders)
            ),
        )


if __name__ == "__main__":
    unittest.main()
