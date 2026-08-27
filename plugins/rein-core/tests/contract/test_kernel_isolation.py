"""plan Task 1.8 — kernel 격리 계약 테스트 (spec §3.1).

고정하는 계약 3개:
- Claude Native Hook 이름은 platform/claude 밖(kernel/engine 소스)에
  문자열로 존재하지 않는다 — 매핑 표(HOOK_EVENT_NAMES)가 native 이름의
  단일 서식지다.
- kernel/ 전 모듈은 claude/git/sqlite 심볼을 import 하지 않는다 (AST
  순회, import 0건).
- rein 패키지 전체 import 후에도 stdlib `platform` 은 표준 라이브러리
  경로에서 해석된다 (Task 1.1 sys.path 규칙 — rein/platform 이 stdlib
  이름을 가리지 않는다).
"""
import ast
import importlib
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.platform.claude.adapter import HOOK_EVENT_NAMES  # noqa: E402

_REIN_ROOT = os.path.join(_PLUGIN_ROOT, "rein")
_KERNEL_ROOT = os.path.join(_REIN_ROOT, "kernel")
_ENGINE_ROOT = os.path.join(_REIN_ROOT, "engine")

# spec §3.1 의존 규칙 — kernel 은 Claude·Git·SQLite 를 모른다.
# 보수적 substring 판정: 과잉 매칭은 사람 검토를 부를 뿐이지만 (안전),
# 미탐은 격리 붕괴를 조용히 통과시킨다.
_FORBIDDEN_IMPORT_TOKENS = ("claude", "git", "sqlite")

# 순회가 빈 디렉토리를 돌고 공허하게 통과하는 것을 막는 하한
_MIN_KERNEL_MODULES = 5


def _python_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            if filename.endswith(".py"):
                yield os.path.join(dirpath, filename)


def _read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def _imported_module_names(tree):
    """모듈 AST 의 import 대상 이름 전부 (from X import Y 의 Y 포함)."""
    names = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                names.append(node.module)
                # from X import Y — Y 가 하위 모듈일 수 있어 결합형도 본다
                names.extend(
                    "{}.{}".format(node.module, alias.name)
                    for alias in node.names
                )
            else:
                # 상대 import: from . import decision
                names.extend(alias.name for alias in node.names)
    return names


def _all_rein_modules():
    """rein 패키지 전체 모듈 이름 목록 (파일 트리 기준)."""
    modules = []
    for path in _python_files(_REIN_ROOT):
        relative = os.path.relpath(path, _PLUGIN_ROOT)
        parts = relative[: -len(".py")].split(os.sep)
        if parts[-1] == "__init__":
            parts = parts[:-1]
        modules.append(".".join(parts))
    return modules


class NativeHookNameContainmentTest(unittest.TestCase):
    """spec §3.1 — native 이름은 adapter 모듈 경계 안에서만 존재한다."""

    def test_mapping_table_is_not_empty(self):
        # 아래 부재 검사가 빈 표로 공허 통과하지 않게 하는 전제 가드
        self.assertGreaterEqual(len(HOOK_EVENT_NAMES), 6)

    def test_native_names_absent_outside_adapter_boundary(self):
        # spec §3.1 문언은 "platform/claude 안에서만 존재" — kernel/engine
        # 한정이 아니라 rein/ 전체에서 adapter 경계 밖 등장을 금지한다
        adapter_boundary = os.path.join(_REIN_ROOT, "platform", "claude")
        scanned = 0
        for path in _python_files(_REIN_ROOT):
            if path.startswith(adapter_boundary + os.sep):
                continue
            source = _read(path)
            scanned += 1
            for native_name in HOOK_EVENT_NAMES:
                self.assertNotIn(
                    native_name,
                    source,
                    msg=(
                        "{} 에 native hook 이름 {!r} 이 문자열로 "
                        "존재한다 — native 이름은 platform/claude "
                        "밖으로 새지 않는다 (spec §3.1)".format(
                            path, native_name
                        )
                    ),
                )
        self.assertGreaterEqual(scanned, _MIN_KERNEL_MODULES)


class KernelImportIsolationTest(unittest.TestCase):
    """spec §3.1 — kernel 전 모듈 AST 순회, 플랫폼 심볼 import 0건."""

    def test_kernel_modules_import_no_platform_symbols(self):
        checked = 0
        for path in _python_files(_KERNEL_ROOT):
            tree = ast.parse(_read(path), filename=path)
            checked += 1
            for module_name in _imported_module_names(tree):
                lowered = module_name.lower()
                for token in _FORBIDDEN_IMPORT_TOKENS:
                    self.assertNotIn(
                        token,
                        lowered,
                        msg=(
                            "{} 이 {!r} 를 import 한다 — kernel 은 "
                            "Claude/Git/SQLite 를 모른다 (spec §3.1)".format(
                                path, module_name
                            )
                        ),
                    )
        self.assertGreaterEqual(checked, _MIN_KERNEL_MODULES)

    def test_kernel_sources_contain_no_dynamic_import(self):
        # AST 검사는 정적 import 만 본다 — importlib/__import__ 가 있으면
        # 두 검사 모두 조용히 우회되므로 소스 문자열 수준에서 원천 금지
        # (kernel 이 동적 import 를 쓸 정당한 이유가 없다)
        checked = 0
        for path in _python_files(_KERNEL_ROOT):
            source = _read(path)
            checked += 1
            for token in ("importlib", "__import__"):
                self.assertNotIn(
                    token,
                    source,
                    msg=(
                        "{} 에 동적 import 토큰 {!r} 이 존재한다 — "
                        "kernel 격리 검사를 우회할 수 있는 경로다".format(
                            path, token
                        )
                    ),
                )
        self.assertGreaterEqual(checked, _MIN_KERNEL_MODULES)


class StdlibPlatformIntegrityTest(unittest.TestCase):
    """plan Task 1.8 (d) — rein 전체 import 후 stdlib platform 비오염."""

    def test_stdlib_platform_survives_full_rein_import(self):
        imported = []
        for module_name in _all_rein_modules():
            imported.append(importlib.import_module(module_name))
        self.assertGreaterEqual(len(imported), _MIN_KERNEL_MODULES)

        stdlib_platform = importlib.import_module("platform")
        stdlib_dir = os.path.dirname(os.path.abspath(os.__file__))
        self.assertEqual(
            os.path.dirname(os.path.abspath(stdlib_platform.__file__)),
            stdlib_dir,
            msg=(
                "stdlib platform 이 표준 라이브러리 밖({})에서 해석됐다 — "
                "rein/platform 이 이름을 가렸다 (Task 1.1 sys.path "
                "규칙 위반)".format(stdlib_platform.__file__)
            ),
        )
        # sys.modules 캐시도 stdlib 을 가리켜야 한다 (후속 import 오염 방지)
        cached = sys.modules.get("platform")
        self.assertIs(cached, stdlib_platform)

        # rein.platform 은 별도 이름 공간으로 공존한다
        rein_platform = importlib.import_module("rein.platform")
        self.assertNotEqual(
            os.path.abspath(stdlib_platform.__file__),
            os.path.abspath(rein_platform.__file__),
        )


if __name__ == "__main__":
    unittest.main()
