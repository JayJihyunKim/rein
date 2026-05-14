#!/usr/bin/env python3
"""rein-validate-plugin-rules — backward-compat wrapper for rein-check-plugin-drift.py.

Option C Phase 2 (2026-05-13) 통합 후 본 도구의 5 check (rules dir / mandate /
inject hook envelope / conditional event hook / hooks.json targets) 는
`rein-check-plugin-drift.py` 에 흡수됨.

본 wrapper 는 publish gate / CI workflow 의 backward compat 을 위해 유지된다.
정확히는 통합 도구를 `--skip-parity --skip-boundary` 로 호출 — validation 부분만 실행.

호출자:
  - `scripts/rein-publish.sh` (publish gate)
  - `.github/workflows/publish-plugin.yml` (publish workflow)
  - `tests/hooks/test-rein-validate-plugin-rules*.sh` (기존 test)

Plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md (Phase 2 D3)
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

# 같은 디렉토리의 통합 도구 import (hyphen 포함 파일명이라 importlib 사용)
HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "rein_check_plugin_drift",
    HERE / "rein-check-plugin-drift.py",
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)


def main() -> int:
    # validation only — parity / boundary 는 통합 도구의 main 으로 호출
    return _mod.main(["--skip-parity", "--skip-boundary"])


if __name__ == "__main__":
    sys.exit(main())
