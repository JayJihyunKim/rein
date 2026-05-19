#!/usr/bin/env bash
# Verify rein-check-plugin-drift.py validation 흡수분 hardening:
#   (1) inject hook with nonzero rc → detected
#   (2) inject hook with wrong hookEventName → detected
#   (3) inject hook with non-string additionalContext → detected
#   (4) conditional hook silent on a MATCHING path (regression) → detected
#   (5) conditional hook non-silent on a NON-MATCHING path (regression) → detected
#   (6) inject hook smoke-test does NOT leak ambient env secrets to the
#       hook subprocess (only the minimal allowlist forwards through)
#
# Option C Phase 2 (2026-05-13) 통합 후: check 함수가 (repo_root, errors) 인자 받음
# — monkeypatch module globals 대신 직접 인자 전달.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

DRIFT="$PROJECT_DIR/scripts/rein-check-plugin-drift.py"
[ -f "$DRIFT" ] || { echo "FAIL: $DRIFT missing" >&2; exit 1; }

# Export a fake secret so scenario (6) can confirm it does NOT reach the hook.
export REIN_TEST_LEAK_CANARY="should-not-reach-hook"

python3 - <<'PY' || exit 1
from __future__ import annotations

import importlib.util
import os
import pathlib
import stat
import sys
import tempfile
from typing import Optional

spec = importlib.util.spec_from_file_location("drift_checker", "scripts/rein-check-plugin-drift.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def _setup_sandbox(tdp: pathlib.Path) -> pathlib.Path:
    """Create plugins/rein-core/hooks/ inside tdp; return hooks_dir."""
    hooks_dir = tdp / "plugins" / "rein-core" / "hooks"
    hooks_dir.mkdir(parents=True)
    return hooks_dir


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


import json as _json


def _valid_stub(event: str) -> str:
    payload = _json.dumps(
        {"hookSpecificOutput": {"hookEventName": event, "additionalContext": "ok"}}
    )
    return (
        "#!/usr/bin/env bash\n"
        "set -e\n"
        f"printf '%s\\n' '{payload}'\n"
    )


VALID_EVENT = {
    "session-start-rules.sh": "SessionStart",
    "user-prompt-submit-rules.sh": "UserPromptSubmit",
    "pre-tool-use-agent-rules.sh": "PreToolUse",
    "pre-tool-use-bash-rules.sh": "PreToolUse",
}


def _populate_valid_inject_hooks(hooks_dir: pathlib.Path, skip: Optional[str] = None) -> None:
    for hook, ev in VALID_EVENT.items():
        if hook == skip:
            continue
        _write_exec(hooks_dir / hook, _valid_stub(ev))


# ─── (1) inject hook with nonzero rc ───────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    _populate_valid_inject_hooks(hooks_dir, skip="session-start-rules.sh")
    _write_exec(
        hooks_dir / "session-start-rules.sh",
        "#!/usr/bin/env bash\nexit 7\n",
    )
    errs = []
    m.check_inject_hooks_envelope(tdp, errs)
    assert any("exited nonzero rc=7" in e and "session-start-rules.sh" in e for e in errs), (
        f"(1) expected nonzero-rc detection, got: {errs}"
    )

# ─── (2) inject hook with wrong hookEventName ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    _populate_valid_inject_hooks(hooks_dir, skip="session-start-rules.sh")
    _write_exec(
        hooks_dir / "session-start-rules.sh",
        "#!/usr/bin/env bash\n"
        "set -e\n"
        "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\","
        "\"additionalContext\":\"x\"}}\\n'\n",
    )
    errs = []
    m.check_inject_hooks_envelope(tdp, errs)
    assert any(
        "hookEventName" in e
        and "session-start-rules.sh" in e
        and "expected 'SessionStart'" in e
        for e in errs
    ), f"(2) expected hookEventName-mismatch detection, got: {errs}"

# ─── (3) inject hook with non-string additionalContext ────────────────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    _populate_valid_inject_hooks(hooks_dir, skip="user-prompt-submit-rules.sh")
    _write_exec(
        hooks_dir / "user-prompt-submit-rules.sh",
        "#!/usr/bin/env bash\n"
        "set -e\n"
        "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\","
        "\"additionalContext\":42}}\\n'\n",
    )
    errs = []
    m.check_inject_hooks_envelope(tdp, errs)
    assert any(
        "additionalContext not a string" in e and "user-prompt-submit-rules.sh" in e
        for e in errs
    ), f"(3) expected additionalContext-type detection, got: {errs}"

# ─── (4) conditional hook silent on a MATCHING path (regression) ──────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    _write_exec(
        hooks_dir / "post-edit-design-plan-coverage-rule.sh",
        "#!/usr/bin/env bash\nexit 0\n",
    )
    errs = []
    m.check_conditional_event_hook(tdp, errs)
    assert any(
        "empty envelope on matching path" in e for e in errs
    ), f"(4) expected matching-path-silent detection, got: {errs}"

# ─── (5) conditional hook non-silent on a NON-MATCHING path ───────────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    _write_exec(
        hooks_dir / "post-edit-design-plan-coverage-rule.sh",
        "#!/usr/bin/env bash\n"
        "set -e\n"
        "cat >/dev/null\n"
        "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\","
        "\"additionalContext\":\"always\"}}\\n'\n",
    )
    errs = []
    m.check_conditional_event_hook(tdp, errs)
    assert any(
        "non-silent on non-matching path" in e for e in errs
    ), f"(5) expected non-matching-path-leak detection, got: {errs}"

# ─── (6) env leak: ambient secret canary must NOT reach the hook ──────────
with tempfile.TemporaryDirectory() as td:
    tdp = pathlib.Path(td)
    hooks_dir = _setup_sandbox(tdp)
    env_dump = hooks_dir.parent / "env-dump.txt"
    for hook, ev in VALID_EVENT.items():
        body = _valid_stub(ev)
        body = body.replace(
            "set -e\n",
            f"set -e\nenv > {env_dump}\n",
            1,
        )
        _write_exec(hooks_dir / hook, body)
    errs = []
    m.check_inject_hooks_envelope(tdp, errs)
    assert errs == [], f"(6) expected no errors with valid stubs, got: {errs}"
    dumped = env_dump.read_text(encoding="utf-8")
    assert "REIN_TEST_LEAK_CANARY" not in dumped, (
        f"(6) ambient secret leaked into hook env! dump:\n{dumped}"
    )

print("test-rein-validate-plugin-rules-hardening: all scenarios PASS")
PY

echo "test-rein-validate-plugin-rules-hardening: OK"
