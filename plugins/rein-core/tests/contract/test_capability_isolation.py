"""plan Task 4.1 — capability 전 쌍(pairwise) 격리 정적 검사 (spec §3.1 §31).

spec §3.1 (원문 인용):
    "Capability 는 서로 직접 의존하지 않는다 (§31). Review → Security
    직접 호출 금지. 공유는 Fact/Requirement/Evidence/Policy 경유만."

spec §3.6 (§14, security_review 원문 인용):
    "code_review 와 상호 직접 호출 금지 — Policy 가 조합."

이 파일이 고정하는 계약: `rein/capabilities/` 하위의 모든 capability
패키지 쌍(A, B), A != B 에 대해 A 의 어떤 모듈도 B 를 import 하지 않는다
— 절대 import(`import rein.capabilities.security...`,
`from rein.capabilities.security import ...`)와 상대 import
(`from .. import security`, `from ..security import x`) 양쪽 모두 검사
대상이다. kernel/engine import 는 허용한다 (spec §3.1 — 공유는 kernel
어휘 경유만).

**디렉토리 순회 기반 자동 확장** (plan Task 4.1 지시 — 하드코딩 목록
금지): capability 패키지 목록은 `rein/capabilities/` 하위에서 실제로
`__init__.py` 를 가진 디렉토리를 순회해 발견한다. 이름·개수를 코드에
나열하지 않으므로, 아직 생성되지 않은 capability 패키지도 파일이
존재하는 시점부터 자동으로 검사 대상에 포함된다. 검사 쌍 개수는
발견된 패키지 수 N 에 대해 항상 N*(N-1) 로 정해진다 (`pairs =
[(a, b) for a in packages for b in packages if a != b]`) — 예: N=2 →
2방향, N=5 → 20방향. **이 숫자는 작성 시점의 스냅샷이 아니라 매 실행
마다 실제 디렉토리를 다시 순회해 재계산되므로**, 새 capability
패키지가 추가돼도 이 주석이나 `_MIN_CAPABILITY_PACKAGES` 하한값을
갱신할 필요가 없다 — 패키지가 늘어날수록 검사 범위가 자동으로
넓어진다 (이 docstring 에 특정 시점의 패키지 이름·개수를 적지 않는
것도 같은 이유 — 다음 패키지 추가 때 stale 해지는 문장을 원천적으로
만들지 않는다).

**정적 검사의 한계 — 동적 import 는 탐지 대상 밖 (의도된 범위, 하드닝
대상 아님)**: 이 검사는 `ast.Import`/`ast.ImportFrom` 정적 AST 만
순회한다. `importlib.import_module(...)` 나 `__import__(...)` 처럼
문자열로 조립되는 동적 import 경로, 혹은 `exec`/`eval` 로 생성되는
import 문은 탐지하지 못한다.
이는 구현 누락이 아니라 spec §2.2 위협 모델의 직접 귀결이다 (원문
인용): "적대적 우회 하드닝은 명시적 비범위 (v1 위협 모델 결정 2026-06
계승)". Rein v2 Governance 는 정직한 Agent 가 실수로 capability 간
결합을 만드는 것을 막는 규율 장치이지, capability 구현자가 검사 자체를
능동적으로 우회하려는 시도까지 막는 완전한 sandbox 가 아니다 (spec
§2.2: "정상적인 도구 인터페이스를 사용하는 정직한 Agent 가 Governance
절차를 임의로 우회하지 못하도록 규율한다"). 따라서 이 계약이 보장하는
범위는 정확히 "정적 import 문으로 표현된 capability 간 의존이 0건"
까지이며, "어떤 경로로도 capability 간 결합이 코드상 불가능하다" 로
확대 해석해서는 안 된다 — 계약 범위 과대해석 방지가 이 절의 목적이다.
"""
import ast
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

_CAPABILITIES_ROOT = os.path.join(_PLUGIN_ROOT, "rein", "capabilities")

# 전 쌍 검사가 빈 목록/단일 목록으로 공허하게 통과하는 것을 막는 하한 —
# 예시로 review·security 최소 2개는 항상 존재한다 (실제 전체 개수는
# 이 상수와 무관하게 디렉토리 순회로 매번 다시 세어진다)
_MIN_CAPABILITY_PACKAGES = 2


def _python_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            if filename.endswith(".py"):
                yield os.path.join(dirpath, filename)


def _read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def _capability_packages(capabilities_root):
    """`__init__.py` 를 가진 하위 디렉토리 전부 — 이름은 하드코딩하지 않는다.

    `rein/capabilities/__init__.py` 자신(부모 패키지)은 capabilities_root
    "안의 디렉토리"가 아니라 그 파일 자체이므로 여기서 자연히 제외된다.
    `__pycache__` 등 dunder/hidden 디렉토리도 제외한다.
    """
    packages = []
    for entry in sorted(os.listdir(capabilities_root)):
        full = os.path.join(capabilities_root, entry)
        if not os.path.isdir(full):
            continue
        if entry.startswith("__") or entry.startswith("."):
            continue
        if not os.path.isfile(os.path.join(full, "__init__.py")):
            continue
        packages.append(entry)
    return tuple(packages)


def _module_dotted_name(path, plugin_root):
    """파일 경로 → 점 구분 모듈 이름. `__init__.py` 는 자신의 패키지 이름."""
    relative = os.path.relpath(path, plugin_root)
    parts = relative[: -len(".py")].split(os.sep)
    is_init = parts[-1] == "__init__"
    if is_init:
        parts = parts[:-1]
    return ".".join(parts), is_init


def _module_package(dotted_name, is_init):
    """모듈의 `__package__` — 상대 import 해석의 기준점.

    패키지 자신을 나타내는 `__init__.py` 파일의 `__package__` 는 자신의
    dotted name 그대로다 (Python 런타임 규약). 일반 모듈은 마지막
    구성요소를 뗀 것이 소속 패키지다.
    """
    if is_init:
        return dotted_name
    if "." not in dotted_name:
        return ""
    return dotted_name.rsplit(".", 1)[0]


def _resolve_relative_base(package, level):
    """`level` 개 선행 점(.)을 `package` 기준으로 절대 패키지 경로로 해석.

    importlib._bootstrap._resolve_name 과 동일한 규약: level=1 은 현재
    package 자신, level=2 는 한 단계 위, ... 이다.
    """
    if not package:
        return ""
    bits = package.split(".")
    strip = level - 1
    if strip <= 0:
        base_bits = bits
    elif strip >= len(bits):
        base_bits = []
    else:
        base_bits = bits[: len(bits) - strip]
    return ".".join(base_bits)


def _resolved_import_names(path, plugin_root, tree):
    """모듈 AST 의 import 대상을 절대 dotted name 으로 정규화해 나열.

    절대 import 는 그대로, 상대 import(level > 0)는 현재 파일의
    `__package__` 를 기준으로 절대 경로로 해석한다 — 두 형태 모두 같은
    비교 기준(절대 dotted name)으로 수렴시켜야 경계 검사가 단일 판정
    으로 닫힌다.
    """
    dotted_name, is_init = _module_dotted_name(path, plugin_root)
    package = _module_package(dotted_name, is_init)
    names = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            level = node.level or 0
            if level > 0:
                base = _resolve_relative_base(package, level)
                if node.module:
                    target = "{}.{}".format(base, node.module) if base else (
                        node.module
                    )
                    names.append(target)
                    names.extend(
                        "{}.{}".format(target, alias.name)
                        for alias in node.names
                    )
                else:
                    names.extend(
                        "{}.{}".format(base, alias.name) if base else (
                            alias.name
                        )
                        for alias in node.names
                    )
            else:
                if node.module:
                    names.append(node.module)
                    names.extend(
                        "{}.{}".format(node.module, alias.name)
                        for alias in node.names
                    )
                else:
                    names.extend(alias.name for alias in node.names)
    return names


def _package_imports(package_root, plugin_root):
    """패키지 하위 모든 .py 파일의 경로 → 정규화된 import 이름 목록."""
    imports = {}
    for path in _python_files(package_root):
        tree = ast.parse(_read(path), filename=path)
        imports[path] = _resolved_import_names(path, plugin_root, tree)
    return imports


class CapabilityDiscoveryTest(unittest.TestCase):
    """디렉토리 순회 발견이 공허하게 통과하지 않도록 하는 전제 가드."""

    def test_discovers_at_least_review_and_security(self):
        packages = _capability_packages(_CAPABILITIES_ROOT)
        self.assertGreaterEqual(len(packages), _MIN_CAPABILITY_PACKAGES)
        self.assertIn("review", packages)
        self.assertIn("security", packages)


class CapabilityPairwiseIsolationTest(unittest.TestCase):
    """spec §3.1 §31 — capability 패키지 전 쌍 상호 import 0건.

    **정적 AST 검사다 — 동적 import 는 탐지 범위 밖** (모듈 docstring
    "정적 검사의 한계" 절 참조). `importlib.import_module()` /
    `__import__()` 로 문자열 조립된 capability 간 결합은 이 검사를
    통과해도 실제로는 존재할 수 있다. 이는 구현 누락이 아니라 spec
    §2.2 위협 모델(정직한 Agent 규율, 적대적 우회 하드닝은 명시적
    비범위)의 의도된 경계다 — 이 클래스의 GREEN 은 "정적 import 문
    수준에서 capability 간 의존 0건" 만을 의미한다.
    """

    def test_no_capability_package_imports_another(self):
        packages = _capability_packages(_CAPABILITIES_ROOT)
        self.assertGreaterEqual(len(packages), _MIN_CAPABILITY_PACKAGES)

        # packages 는 바로 위에서 디렉토리 순회로 매 실행마다 새로
        # 발견된 것이다 — 아래 pairs 는 그 개수 N 에 대해 항상 N*(N-1)
        # 쌍이 된다 (특정 패키지 이름·개수를 하드코딩하지 않으므로
        # 새 capability 패키지가 추가돼도 이 테스트를 수정할 필요가
        # 없다: N=2 → 2쌍, N=5 → 20쌍, ...).
        pairs = tuple(
            (source, target)
            for source in packages
            for target in packages
            if source != target
        )
        self.assertEqual(len(pairs), len(packages) * (len(packages) - 1))

        imports_by_package = {
            name: _package_imports(
                os.path.join(_CAPABILITIES_ROOT, name), _PLUGIN_ROOT
            )
            for name in packages
        }
        total_files_checked = sum(
            len(files) for files in imports_by_package.values()
        )
        self.assertGreater(total_files_checked, 0)

        violations = []
        for source, target in pairs:
            forbidden_exact = "rein.capabilities.{}".format(target)
            forbidden_prefix = forbidden_exact + "."
            for path, names in imports_by_package[source].items():
                for name in names:
                    if name == forbidden_exact or name.startswith(
                        forbidden_prefix
                    ):
                        violations.append((path, name))
        self.assertEqual(
            violations,
            [],
            msg=(
                "capability 간 직접 import 발견 — Review/Security 등은 "
                "서로 직접 의존하지 않는다 (spec §3.1 §31), 공유는 "
                "Fact/Requirement/Evidence/Policy 경유만: {!r}".format(
                    violations
                )
            ),
        )

    def test_kernel_and_engine_imports_are_not_flagged(self):
        # kernel/engine import 는 허용 대상이다 — 오탐 방지 가드.
        # review capability 는 실제로 kernel 을 import 하므로(발급
        # 함수가 Evidence/Requirement 를 쓴다), 이 경로가 위반으로
        # 잡히면 pairwise 검사 자체가 과도하게 넓다는 신호다.
        packages = _capability_packages(_CAPABILITIES_ROOT)
        imports_by_package = {
            name: _package_imports(
                os.path.join(_CAPABILITIES_ROOT, name), _PLUGIN_ROOT
            )
            for name in packages
        }
        review_all_names = [
            name
            for names in imports_by_package.get("review", {}).values()
            for name in names
        ]
        self.assertTrue(
            any(
                candidate.startswith("rein.kernel")
                for candidate in review_all_names
            ),
            msg="review capability 가 kernel 을 import 하지 않는다 — "
            "테스트 전제(kernel import 존재) 자체가 무너졌다",
        )


class RelativeImportResolutionTest(unittest.TestCase):
    """상대 import 해석 helper 의 단위 계약 — pairwise 검사의 정확성 기반."""

    def test_single_dot_resolves_to_own_package(self):
        # from . import x  (package="rein.capabilities.review", level=1)
        base = _resolve_relative_base("rein.capabilities.review", level=1)
        self.assertEqual(base, "rein.capabilities.review")

    def test_double_dot_resolves_to_parent_package(self):
        # from .. import security  (level=2) → rein.capabilities 로 해석
        base = _resolve_relative_base("rein.capabilities.review", level=2)
        self.assertEqual(base, "rein.capabilities")

    def test_relative_import_of_sibling_capability_is_detected(self):
        # from ..security import capability — sibling capability 를
        # 가리키는 상대 import 도 절대 경로로 정규화되어야 pairwise
        # 검사가 이를 잡을 수 있다
        tree = ast.parse(
            "from ..security import capability\n", filename="<test>"
        )
        names = _resolved_import_names(
            os.path.join(_CAPABILITIES_ROOT, "review", "capability.py"),
            _PLUGIN_ROOT,
            tree,
        )
        self.assertIn("rein.capabilities.security.capability", names)


if __name__ == "__main__":
    unittest.main()
