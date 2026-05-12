#!/usr/bin/env python3
"""Pre-publish validation of plugins/rein-core/rules/*.md and rule-inject hooks.

Checks:
  (1) Each `plugins/rein-core/rules/*.md` has a `## 행동 강령` section
      placed as the FIRST `## ` header after the title.
  (2) The mandate section body size <= 2048 bytes (UTF-8).
  (3) None of the 4 dev-only rules (branch-strategy, readme-style,
      versioning, legacy-shipped-pending) exist under
      `plugins/rein-core/rules/`.
  (4) Each unconditional rule-inject hook
      (session-start-rules.sh, user-prompt-submit-rules.sh,
      pre-tool-use-agent-rules.sh, pre-tool-use-bash-rules.sh)
      produces a valid JSON envelope on stdout for a smoke-test invocation.
  (5) Each hook command referenced in `plugins/rein-core/hooks/hooks.json`
      points to an existing executable file under `plugins/rein-core/hooks/`.
  (6) `post-write-design-plan-coverage-rule.sh` (a PostToolUse hook with
      conditional emit) produces a valid envelope for a matching file path
      AND stays silent (exit 0, empty stdout) for a non-matching path.

Designed to be EXTENSIBLE — additional checks can append to the same
`errors` list and reuse `main()` exit semantics. Keep the check functions
as small standalone functions so additional ones can be appended without
restructuring.

Exit code: 0 on all-pass, 1 on any failure.
"""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ROOT = REPO_ROOT / "plugins" / "rein-core"
RULES_DIR = PLUGIN_ROOT / "rules"
HOOKS_DIR = PLUGIN_ROOT / "hooks"
DEV_ONLY = {"branch-strategy", "readme-style", "versioning", "legacy-shipped-pending"}
MAX_MANDATE_BYTES = 2048

MANDATE_RE = re.compile(
    r"^#\s+.+?\n+(## 행동 강령\b.*?)(?=\n## |\Z)",
    re.DOTALL | re.MULTILINE,
)

UNCONDITIONAL_INJECT_HOOKS = (
    "session-start-rules.sh",
    "user-prompt-submit-rules.sh",
    "pre-tool-use-agent-rules.sh",
    "pre-tool-use-bash-rules.sh",
)

# Each inject hook MUST emit an envelope whose hookSpecificOutput.hookEventName
# matches Claude Code's slot identity. A mismatch (e.g. a SessionStart hook
# claiming "UserPromptSubmit") would be silently dropped by Claude Code, so
# the validator catches it at publish time.
EXPECTED_EVENT = {
    "session-start-rules.sh": "SessionStart",
    "user-prompt-submit-rules.sh": "UserPromptSubmit",
    "pre-tool-use-agent-rules.sh": "PreToolUse",
    "pre-tool-use-bash-rules.sh": "PreToolUse",
    "post-write-design-plan-coverage-rule.sh": "PostToolUse",
}


def _minimal_hook_env() -> dict[str, str]:
    """Return a minimal env for hook smoke-tests.

    Publish-time invocations carry secrets (marketplace tokens, ANTHROPIC_TOKEN,
    etc.) that MUST NOT leak into hook subprocesses. We only forward the bare
    minimum required for `bash <hook>` to function: PATH (locate interpreters),
    HOME (helpers may compute cache locations), LANG/LC_ALL (UTF-8 stdout),
    plus CLAUDE_PLUGIN_ROOT which the hooks themselves require.
    """
    return {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        "CLAUDE_PLUGIN_ROOT": str(PLUGIN_ROOT),
    }


def check_rules_dir_exists(errors: list[str]) -> None:
    if not RULES_DIR.is_dir():
        errors.append(f"{RULES_DIR.relative_to(REPO_ROOT)} not found — Phase 1 incomplete")


def check_action_mandate(errors: list[str]) -> None:
    if not RULES_DIR.is_dir():
        return
    for rule_file in sorted(RULES_DIR.glob("*.md")):
        name = rule_file.stem
        if name in DEV_ONLY:
            errors.append(f"dev-only rule shipped in plugin: {rule_file.relative_to(REPO_ROOT)}")
            continue
        try:
            body = rule_file.read_text(encoding="utf-8")
        except Exception as e:
            errors.append(f"failed to read {rule_file.relative_to(REPO_ROOT)}: {e}")
            continue
        m = MANDATE_RE.search(body)
        if not m:
            errors.append(
                f"{rule_file.relative_to(REPO_ROOT)}: missing '## 행동 강령' as first `## ` header after title"
            )
            continue
        mandate = m.group(1)
        size = len(mandate.encode("utf-8"))
        if size > MAX_MANDATE_BYTES:
            errors.append(
                f"{rule_file.relative_to(REPO_ROOT)}: action mandate size {size} > {MAX_MANDATE_BYTES} bytes"
            )


def check_inject_hooks_envelope(errors: list[str]) -> None:
    env = _minimal_hook_env()
    for hook in UNCONDITIONAL_INJECT_HOOKS:
        hook_path = HOOKS_DIR / hook
        if not hook_path.exists():
            errors.append(f"inject hook missing: {hook_path.relative_to(REPO_ROOT)}")
            continue
        if not (hook_path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"inject hook not executable: {hook_path.relative_to(REPO_ROOT)}")
            continue
        try:
            res = subprocess.run(
                ["bash", str(hook_path)],
                input="",
                capture_output=True,
                text=True,
                timeout=10,
                env=env,
            )
        except subprocess.TimeoutExpired:
            errors.append(f"inject hook timeout: {hook}")
            continue
        if res.returncode != 0:
            errors.append(f"inject hook exited nonzero rc={res.returncode}: {hook}")
            continue
        out = res.stdout.strip()
        if not out:
            errors.append(f"inject hook produced empty envelope (expected unconditional inject): {hook}")
            continue
        try:
            data = json.loads(out)
        except json.JSONDecodeError as e:
            errors.append(f"inject hook envelope invalid JSON: {hook} ({e})")
            continue
        hso = data.get("hookSpecificOutput")
        if not isinstance(hso, dict):
            errors.append(f"inject hook envelope missing hookSpecificOutput object: {hook}")
            continue
        ev = hso.get("hookEventName")
        if not isinstance(ev, str) or not ev:
            errors.append(f"inject hook hookEventName not a non-empty string: {hook} (got {ev!r})")
            continue
        expected_event = EXPECTED_EVENT.get(hook)
        if expected_event and ev != expected_event:
            errors.append(
                f"inject hook hookEventName {ev!r} != expected {expected_event!r}: {hook}"
            )
            continue
        ac = hso.get("additionalContext")
        if not isinstance(ac, str):
            errors.append(
                f"inject hook additionalContext not a string (got {type(ac).__name__}): {hook}"
            )


def check_conditional_event_hook(errors: list[str]) -> None:
    """Verify post-write-design-plan-coverage-rule.sh dual behavior.

    This PostToolUse hook reads tool_input.file_path from stdin and either:
      (a) emits a valid PostToolUse envelope when the path matches the design
          or plan glob (e.g. docs/specs/*.md), or
      (b) silently exits 0 with no stdout otherwise.

    Both branches must hold; a regression in either silently breaks the rule
    delivery contract. Smoke-test each branch with crafted stdin.
    """
    hook = "post-write-design-plan-coverage-rule.sh"
    hook_path = HOOKS_DIR / hook
    if not hook_path.exists():
        errors.append(f"conditional hook missing: {hook}")
        return
    if not (hook_path.stat().st_mode & stat.S_IXUSR):
        errors.append(f"conditional hook not executable: {hook}")
        return
    env = _minimal_hook_env()

    # (a) Matching path → envelope expected.
    try:
        res = subprocess.run(
            ["bash", str(hook_path)],
            input='{"tool_input":{"file_path":"docs/specs/foo.md"}}',
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
    except subprocess.TimeoutExpired:
        errors.append(f"conditional hook timeout (matching path): {hook}")
        return
    if res.returncode != 0:
        errors.append(
            f"conditional hook nonzero rc on matching path: {hook} rc={res.returncode}"
        )
        return
    out = res.stdout.strip()
    if not out:
        errors.append(f"conditional hook empty envelope on matching path: {hook}")
        return
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        errors.append(f"conditional hook invalid JSON on matching path: {hook} ({e})")
        return
    hso = data.get("hookSpecificOutput")
    if not isinstance(hso, dict):
        errors.append(
            f"conditional hook envelope missing hookSpecificOutput object on matching path: {hook}"
        )
    else:
        expected_event = EXPECTED_EVENT.get(hook)
        ev = hso.get("hookEventName")
        if expected_event and ev != expected_event:
            errors.append(
                f"conditional hook wrong hookEventName on matching path: {hook} got {ev!r} expected {expected_event!r}"
            )
        if not isinstance(hso.get("additionalContext"), str):
            errors.append(
                f"conditional hook additionalContext not a string on matching path: {hook}"
            )

    # (b) Non-matching path → silent exit 0 (no stdout).
    try:
        res2 = subprocess.run(
            ["bash", str(hook_path)],
            input='{"tool_input":{"file_path":"src/foo.py"}}',
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
    except subprocess.TimeoutExpired:
        errors.append(f"conditional hook timeout (non-matching path): {hook}")
        return
    if res2.returncode != 0:
        errors.append(
            f"conditional hook nonzero rc on non-matching path: {hook} rc={res2.returncode}"
        )
    if res2.stdout.strip():
        errors.append(f"conditional hook non-silent on non-matching path: {hook}")


def check_hooks_json_targets(errors: list[str]) -> None:
    hooks_json_path = HOOKS_DIR / "hooks.json"
    if not hooks_json_path.exists():
        errors.append(f"hooks.json missing: {hooks_json_path.relative_to(REPO_ROOT)}")
        return
    try:
        manifest = json.loads(hooks_json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        errors.append(f"hooks.json invalid JSON: {e}")
        return
    marker = "${CLAUDE_PLUGIN_ROOT}/hooks/"
    for event, slots in manifest.get("hooks", {}).items():
        for slot in slots:
            for hook in slot.get("hooks", []):
                cmd = hook.get("command", "")
                if marker not in cmd:
                    errors.append(f"{event}: command does not use plugin root marker: {cmd}")
                    continue
                rel = cmd.split(marker, 1)[1]
                target = HOOKS_DIR / rel
                if not target.exists():
                    errors.append(f"{event}: hooks.json references missing hook: {rel}")
                    continue
                if not (target.stat().st_mode & stat.S_IXUSR):
                    errors.append(f"{event}: hooks.json target not executable: {rel}")


def main() -> int:
    errors: list[str] = []
    check_rules_dir_exists(errors)
    check_action_mandate(errors)
    check_inject_hooks_envelope(errors)
    check_conditional_event_hook(errors)
    check_hooks_json_targets(errors)
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        print(f"FAIL: rein-validate-plugin-rules found {len(errors)} error(s)", file=sys.stderr)
        return 1
    print("OK: all plugin rules valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
