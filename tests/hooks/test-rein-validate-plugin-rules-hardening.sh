#!/usr/bin/env bash
# Verify rein-validate-plugin-rules.py hardening (Round 1 codex fix):
#   (1) inject hook with nonzero rc → detected
#   (2) inject hook with wrong hookEventName → detected
#   (3) inject hook with non-string additionalContext → detected
#   (4) conditional hook silent on a MATCHING path (regression) → detected
#   (5) conditional hook non-silent on a NON-MATCHING path (regression) → detected
#   (6) inject hook smoke-test does NOT leak ambient env secrets to the
#       hook subprocess (only the minimal allowlist forwards through)
#
# Strategy: monkeypatch HOOKS_DIR / PLUGIN_ROOT / RULES_DIR / REPO_ROOT inside
# the validator module to point at temp dirs containing synthetic hook stubs.
# This mirrors the (b)(c)(d) pattern in test-rein-validate-plugin-rules.sh.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

VALIDATOR="$PROJECT_DIR/scripts/rein-validate-plugin-rules.py"
[ -f "$VALIDATOR" ] || { echo "FAIL: $VALIDATOR missing" >&2; exit 1; }

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

spec = importlib.util.spec_from_file_location("validator", "scripts/rein-validate-plugin-rules.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def _swap(tdp: pathlib.Path):
    """Repoint module globals at a fresh sandbox; return restore-tuple."""
    orig = (m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR)
    m.REPO_ROOT = tdp
    m.PLUGIN_ROOT = tdp / "plugins" / "rein-core"
    m.RULES_DIR = m.PLUGIN_ROOT / "rules"
    m.HOOKS_DIR = m.PLUGIN_ROOT / "hooks"
    m.HOOKS_DIR.mkdir(parents=True)
    return orig


def _restore(orig):
    m.REPO_ROOT, m.PLUGIN_ROOT, m.RULES_DIR, m.HOOKS_DIR = orig


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


# Stub that emits a valid envelope; reused for unrelated hooks in each scenario
# so only ONE hook misbehaves at a time. We build the JSON payload with
# json.dumps to avoid hand-rolled brace escaping mishaps.
import json as _json


def _valid_stub(event: str) -> str:
    payload = _json.dumps(
        {"hookSpecificOutput": {"hookEventName": event, "additionalContext": "ok"}}
    )
    # Single-quote the JSON for bash; the payload contains only " not ', so
    # this is safe.
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


def _populate_valid_inject_hooks(skip: Optional[str] = None) -> None:
    for hook, ev in VALID_EVENT.items():
        if hook == skip:
            continue
        _write_exec(m.HOOKS_DIR / hook, _valid_stub(ev))


def _populate_valid_conditional() -> None:
    # Conditional hook that obeys the matching/non-matching contract.
    body = r"""#!/usr/bin/env bash
set -e
INPUT=$(cat || true)
case "$INPUT" in
  *docs/specs/*|*docs/plans/*|*trail/dod/dod-*) ;;
  *) exit 0 ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"ok"}}\n'
"""
    _write_exec(m.HOOKS_DIR / "post-write-design-plan-coverage-rule.sh", body)


# ─── (1) inject hook with nonzero rc ───────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        _populate_valid_inject_hooks(skip="session-start-rules.sh")
        _write_exec(
            m.HOOKS_DIR / "session-start-rules.sh",
            "#!/usr/bin/env bash\nexit 7\n",
        )
        errs = []
        m.check_inject_hooks_envelope(errs)
        assert any("exited nonzero rc=7" in e and "session-start-rules.sh" in e for e in errs), (
            f"(1) expected nonzero-rc detection, got: {errs}"
        )
    finally:
        _restore(orig)

# ─── (2) inject hook with wrong hookEventName ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        _populate_valid_inject_hooks(skip="session-start-rules.sh")
        # SessionStart hook lies and claims it's a UserPromptSubmit envelope.
        _write_exec(
            m.HOOKS_DIR / "session-start-rules.sh",
            "#!/usr/bin/env bash\n"
            "set -e\n"
            "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\","
            "\"additionalContext\":\"x\"}}\\n'\n",
        )
        errs = []
        m.check_inject_hooks_envelope(errs)
        assert any(
            "hookEventName" in e
            and "session-start-rules.sh" in e
            and "expected 'SessionStart'" in e
            for e in errs
        ), f"(2) expected hookEventName-mismatch detection, got: {errs}"
    finally:
        _restore(orig)

# ─── (3) inject hook with non-string additionalContext ────────────────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        _populate_valid_inject_hooks(skip="user-prompt-submit-rules.sh")
        _write_exec(
            m.HOOKS_DIR / "user-prompt-submit-rules.sh",
            "#!/usr/bin/env bash\n"
            "set -e\n"
            "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\","
            "\"additionalContext\":42}}\\n'\n",
        )
        errs = []
        m.check_inject_hooks_envelope(errs)
        assert any(
            "additionalContext not a string" in e and "user-prompt-submit-rules.sh" in e
            for e in errs
        ), f"(3) expected additionalContext-type detection, got: {errs}"
    finally:
        _restore(orig)

# ─── (4) conditional hook silent on a MATCHING path (regression) ──────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        # Always-silent stub — broken because matching paths should emit.
        _write_exec(
            m.HOOKS_DIR / "post-write-design-plan-coverage-rule.sh",
            "#!/usr/bin/env bash\nexit 0\n",
        )
        errs = []
        m.check_conditional_event_hook(errs)
        assert any(
            "empty envelope on matching path" in e for e in errs
        ), f"(4) expected matching-path-silent detection, got: {errs}"
    finally:
        _restore(orig)

# ─── (5) conditional hook non-silent on a NON-MATCHING path ───────────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        # Always-emit stub — broken because non-matching paths must stay silent.
        _write_exec(
            m.HOOKS_DIR / "post-write-design-plan-coverage-rule.sh",
            "#!/usr/bin/env bash\n"
            "set -e\n"
            "cat >/dev/null\n"
            "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\","
            "\"additionalContext\":\"always\"}}\\n'\n",
        )
        errs = []
        m.check_conditional_event_hook(errs)
        assert any(
            "non-silent on non-matching path" in e for e in errs
        ), f"(5) expected non-matching-path-leak detection, got: {errs}"
    finally:
        _restore(orig)

# ─── (6) env leak: ambient secret canary must NOT reach the hook ──────────
with tempfile.TemporaryDirectory() as td:
    orig = _swap(pathlib.Path(td))
    try:
        # Each inject hook dumps its env to a shared file and emits a valid
        # envelope so we can assert (a) no error AND (b) canary absent.
        env_dump = m.HOOKS_DIR.parent / "env-dump.txt"
        for hook, ev in VALID_EVENT.items():
            # _valid_stub already produces a correctly-escaped envelope;
            # prepend the env-dump line so each invocation overwrites the
            # shared file with that subprocess's env.
            body = _valid_stub(ev)
            body = body.replace(
                "set -e\n",
                f"set -e\nenv > {env_dump}\n",
                1,
            )
            _write_exec(m.HOOKS_DIR / hook, body)
        errs = []
        m.check_inject_hooks_envelope(errs)
        assert errs == [], f"(6) expected no errors with valid stubs, got: {errs}"
        dumped = env_dump.read_text(encoding="utf-8")
        assert "REIN_TEST_LEAK_CANARY" not in dumped, (
            f"(6) ambient secret leaked into hook env! dump:\n{dumped}"
        )
    finally:
        _restore(orig)

print("test-rein-validate-plugin-rules-hardening: all scenarios PASS")
PY

echo "test-rein-validate-plugin-rules-hardening: OK"
