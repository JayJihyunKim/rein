#!/usr/bin/env python3
"""rein-check-plugin-drift — boundary + parity + validation for the rein-core plugin SSOT.

Option C unified tool (2026-05-13 통합): drift checker + plugin rules validator 흡수.

Three concerns checked in a single tool:

  (1) Shared-rule boundary (Option C 핵심):
      `.claude/rules/<shared>.md` 존재 시 fail. shared rule 은 plugin SSOT 만 보유,
      maintainer overlay 에 mirror 금지. dev-only 4종 (branch-strategy / readme-style /
      versioning / legacy-shipped-pending) 은 `.claude/rules/` 에 남아도 OK (dev-only
      runtime rules).

  (2) sha256 parity (Option C Phase 3 완료 전 transitional):
      plugins/rein-core/{hooks,skills,agents} ↔ .claude/{hooks,skills,agents} byte parity.
      Phase 3 후엔 .claude/{hooks,skills,agents} 가 폐기되어 trivially pass.
      OVERLAY-ONLY / HASH-MISMATCH 는 여전히 fail (intentional plugin-only PLUGIN-ONLY
      는 allowlist).

  (3) Plugin rules validation (이전 rein-validate-plugin-rules.py 흡수):
      - 7 shared rule 각 `## 행동 강령` mandate section 존재 + size ≤ 2048 bytes
      - dev-only 4종이 plugins/rein-core/rules/ 에 진입 안 함
      - 4 unconditional inject hook (session-start-rules, user-prompt-submit-rules,
        pre-tool-use-agent-rules, pre-tool-use-bash-rules) envelope JSON 유효
      - conditional emit hook (post-edit-design-plan-coverage-rule) matching path 시
        envelope + non-matching path 시 silent
      - hooks.json 의 모든 command 가 실제 실행 가능

Exit codes:
  0  모든 check pass
  1  drift / boundary violation / validation error 1+ 발생
  2  internal error (plugin tree missing 등)

CLI:
  python3 rein-check-plugin-drift.py [--repo-root <path>] [--quiet]
                                     [--skip-parity] [--skip-boundary] [--skip-validation]

Plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md (Phase 2)
Spec ref: docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md (S1, S2, S3)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

PREFIX = "rein-check-plugin-drift:"

# ──────────────────────────────────────────────────────────────────────────
# Shared rule boundary (Option C)
# ──────────────────────────────────────────────────────────────────────────

# 7 shared rules — plugin SSOT 만 보유. `.claude/rules/` 에 있으면 boundary 위반.
SHARED_RULES = frozenset({
    "code-style",
    "security",
    "testing",
    "design-plan-coverage",
    "subagent-review",
    "answer-only-mode",
    "background-jobs",
})

# 4 dev-only rules — `.claude/rules/` 에만 (plugin SSOT 진입 금지). 위반 시 (3) 의
# check_action_mandate 가 detect.
DEV_ONLY = frozenset({
    "branch-strategy",
    "readme-style",
    "versioning",
    "legacy-shipped-pending",
})

# ──────────────────────────────────────────────────────────────────────────
# sha256 parity (transitional)
# ──────────────────────────────────────────────────────────────────────────

# Filename suffixes ignored ONLY on the .claude/ (dev overlay) side.
OVERLAY_IGNORE_SUFFIXES = (".example",)

# Filenames ignored anywhere in the walk.
IGNORE_NAMES = frozenset({
    ".DS_Store",
    ".gitkeep",
    "__pycache__",
})

# Plugin-native artifacts that intentionally have no .claude/ mirror.
# Path-prefix relative to plugins/rein-core/ — exact match in either tree allowlist.
PLUGIN_ONLY_PATHS = frozenset({
    Path("hooks/hooks.json"),
    Path("hooks/session-start-rules.sh"),
})

# Domain-skill exclusion (placeholder for future domain plugins).
DOMAIN_SKILL_DIRS: frozenset[str] = frozenset()

# ──────────────────────────────────────────────────────────────────────────
# Plugin rules validation (validator 흡수)
# ──────────────────────────────────────────────────────────────────────────

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

EXPECTED_EVENT = {
    "session-start-rules.sh": "SessionStart",
    "user-prompt-submit-rules.sh": "UserPromptSubmit",
    "pre-tool-use-agent-rules.sh": "PreToolUse",
    "pre-tool-use-bash-rules.sh": "PreToolUse",
    "post-edit-design-plan-coverage-rule.sh": "PostToolUse",
}


# ══════════════════════════════════════════════════════════════════════════
# (1) Boundary check — Option C
# ══════════════════════════════════════════════════════════════════════════


def check_shared_rule_boundary(repo_root: Path, errors: list[str]) -> None:
    """Fail when shared rule mirror exists in `.claude/rules/`.

    Option C 의 핵심 boundary — shared rule 은 plugin SSOT 만 보유한다.
    overlay 에 mirror 가 있으면 dual-write 부담이 silent drift 누적.
    """
    overlay_rules = repo_root / ".claude" / "rules"
    if not overlay_rules.is_dir():
        return
    for rule_file in sorted(overlay_rules.glob("*.md")):
        stem = rule_file.stem
        if stem in SHARED_RULES:
            errors.append(
                f"BOUNDARY: shared rule mirrored in overlay (plugin SSOT 만 보유 해야): "
                f"{rule_file.relative_to(repo_root)}"
            )


# ══════════════════════════════════════════════════════════════════════════
# (2) sha256 parity — transitional
# ══════════════════════════════════════════════════════════════════════════


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_ignored(rel_path: Path, *, side: str) -> bool:
    parts = rel_path.parts
    if not parts:
        return True
    if any(p.startswith(".") for p in parts):
        return True
    if any(p in IGNORE_NAMES for p in parts):
        return True
    if len(parts) >= 1 and parts[0] in DOMAIN_SKILL_DIRS:
        return True
    if side == "overlay":
        if rel_path.name.endswith(OVERLAY_IGNORE_SUFFIXES):
            return True
    return False


def _walk_files(root: Path, *, side: str) -> Dict[Path, str]:
    out: Dict[Path, str] = {}
    if not root.exists():
        return out
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        if _is_ignored(rel, side=side):
            continue
        out[rel] = _sha256(p)
    return out


def _is_plugin_only_allowed(category: str, rel: Path) -> bool:
    return Path(category) / rel in PLUGIN_ONLY_PATHS


def _diff_trees(plugin_files: Dict[Path, str],
                overlay_files: Dict[Path, str],
                category: str) -> List[str]:
    """Return parity issues for the (plugin, overlay) pair.

    Option C 의 의도: plugin SSOT 가 SSOT. overlay 는 transition 단계에서만 존재
    (Phase 3 후 폐기). 따라서:

    - HASH-MISMATCH: 양쪽에 같은 파일 있는데 byte 다름 → 실제 drift. FAIL.
    - OVERLAY-ONLY: overlay 에만 있음 → stray maintainer-only file 또는 leftover.
      Option C 후엔 발생 안 해야 함. FAIL.
    - PLUGIN-ONLY: plugin SSOT 에만 있음 → **Option C 의 자연 상태**. OK (no emit).

    PLUGIN_ONLY_PATHS allowlist 는 legacy 호환용 (특수 plugin-native artifact 검증
    가능) 으로 유지하되 현재 PLUGIN-ONLY 가 default OK 라 미사용.
    """
    drift: List[str] = []
    plugin_keys = set(plugin_files)
    overlay_keys = set(overlay_files)

    for rel in sorted(plugin_keys & overlay_keys):
        if plugin_files[rel] != overlay_files[rel]:
            drift.append(
                f"  HASH-MISMATCH {category}/{rel}\n"
                f"    plugin  sha256={plugin_files[rel]}\n"
                f"    overlay sha256={overlay_files[rel]}"
            )
    # PLUGIN-ONLY 는 Option C 후 자연 상태 — emit 안 함
    for rel in sorted(overlay_keys - plugin_keys):
        drift.append(f"  OVERLAY-ONLY {category}/{rel}")
    return drift


def check_sha256_parity(repo_root: Path, errors: list[str]) -> None:
    """hooks/skills/agents byte parity check (transitional)."""
    plugin_root = repo_root / "plugins" / "rein-core"
    claude_root = repo_root / ".claude"
    if not plugin_root.exists():
        errors.append(f"plugin root missing: {plugin_root.relative_to(repo_root)}")
        return

    categories: Iterable[Tuple[str, Path, Path]] = (
        ("hooks",  plugin_root / "hooks",  claude_root / "hooks"),
        ("skills", plugin_root / "skills", claude_root / "skills"),
        ("agents", plugin_root / "agents", claude_root / "agents"),
    )

    for cat, p_root, s_root in categories:
        p_files = _walk_files(p_root, side="plugin")
        s_files = _walk_files(s_root, side="overlay")
        drift = _diff_trees(p_files, s_files, cat)
        if drift:
            errors.append(f"PARITY {cat} ({len(drift)} drift entries):")
            errors.extend(drift)


# ══════════════════════════════════════════════════════════════════════════
# (3) Plugin rules validation (validator 흡수)
# ══════════════════════════════════════════════════════════════════════════


def _minimal_hook_env(plugin_root: Path) -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        "CLAUDE_PLUGIN_ROOT": str(plugin_root),
    }


def check_rules_dir_exists(repo_root: Path, errors: list[str]) -> None:
    rules_dir = repo_root / "plugins" / "rein-core" / "rules"
    if not rules_dir.is_dir():
        errors.append(f"VALIDATION: {rules_dir.relative_to(repo_root)} not found")


def check_action_mandate(repo_root: Path, errors: list[str]) -> None:
    rules_dir = repo_root / "plugins" / "rein-core" / "rules"
    if not rules_dir.is_dir():
        return
    for rule_file in sorted(rules_dir.glob("*.md")):
        name = rule_file.stem
        if name in DEV_ONLY:
            errors.append(
                f"VALIDATION: dev-only rule shipped in plugin: "
                f"{rule_file.relative_to(repo_root)}"
            )
            continue
        try:
            body = rule_file.read_text(encoding="utf-8")
        except Exception as e:
            errors.append(f"VALIDATION: failed to read {rule_file.relative_to(repo_root)}: {e}")
            continue
        m = MANDATE_RE.search(body)
        if not m:
            errors.append(
                f"VALIDATION: {rule_file.relative_to(repo_root)}: "
                f"missing '## 행동 강령' as first `## ` header after title"
            )
            continue
        mandate = m.group(1)
        size = len(mandate.encode("utf-8"))
        if size > MAX_MANDATE_BYTES:
            errors.append(
                f"VALIDATION: {rule_file.relative_to(repo_root)}: "
                f"action mandate size {size} > {MAX_MANDATE_BYTES} bytes"
            )


def check_inject_hooks_envelope(repo_root: Path, errors: list[str]) -> None:
    plugin_root = repo_root / "plugins" / "rein-core"
    hooks_dir = plugin_root / "hooks"
    env = _minimal_hook_env(plugin_root)
    for hook in UNCONDITIONAL_INJECT_HOOKS:
        hook_path = hooks_dir / hook
        if not hook_path.exists():
            errors.append(f"VALIDATION: inject hook missing: {hook_path.relative_to(repo_root)}")
            continue
        if not (hook_path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"VALIDATION: inject hook not executable: {hook_path.relative_to(repo_root)}")
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
            errors.append(f"VALIDATION: inject hook timeout: {hook}")
            continue
        if res.returncode != 0:
            errors.append(f"VALIDATION: inject hook exited nonzero rc={res.returncode}: {hook}")
            continue
        out = res.stdout.strip()
        if not out:
            errors.append(
                f"VALIDATION: inject hook produced empty envelope "
                f"(expected unconditional inject): {hook}"
            )
            continue
        try:
            data = json.loads(out)
        except json.JSONDecodeError as e:
            errors.append(f"VALIDATION: inject hook envelope invalid JSON: {hook} ({e})")
            continue
        hso = data.get("hookSpecificOutput")
        if not isinstance(hso, dict):
            errors.append(
                f"VALIDATION: inject hook envelope missing hookSpecificOutput object: {hook}"
            )
            continue
        ev = hso.get("hookEventName")
        if not isinstance(ev, str) or not ev:
            errors.append(
                f"VALIDATION: inject hook hookEventName not a non-empty string: "
                f"{hook} (got {ev!r})"
            )
            continue
        expected_event = EXPECTED_EVENT.get(hook)
        if expected_event and ev != expected_event:
            errors.append(
                f"VALIDATION: inject hook hookEventName {ev!r} != expected "
                f"{expected_event!r}: {hook}"
            )
            continue
        ac = hso.get("additionalContext")
        if not isinstance(ac, str):
            errors.append(
                f"VALIDATION: inject hook additionalContext not a string "
                f"(got {type(ac).__name__}): {hook}"
            )


def check_conditional_event_hook(repo_root: Path, errors: list[str]) -> None:
    plugin_root = repo_root / "plugins" / "rein-core"
    hooks_dir = plugin_root / "hooks"
    hook = "post-edit-design-plan-coverage-rule.sh"
    hook_path = hooks_dir / hook
    if not hook_path.exists():
        errors.append(f"VALIDATION: conditional hook missing: {hook}")
        return
    if not (hook_path.stat().st_mode & stat.S_IXUSR):
        errors.append(f"VALIDATION: conditional hook not executable: {hook}")
        return
    env = _minimal_hook_env(plugin_root)

    # X4.C.3: this hook fast-path-skips its envelope when the resolved project's
    # .rein/state.json reports mode=answer. With no project dir pinned, the hook
    # subprocess falls through to `git rev-parse --show-toplevel` and inherits the
    # maintainer repo's live state.json — making this default-emission contract
    # non-deterministic (green in CI's fresh checkout, red in a live session).
    # Pin an isolated empty project dir so the check verifies the legacy /
    # state-absent envelope contract.
    with tempfile.TemporaryDirectory(prefix="rein-drift-iso-") as iso_dir:
        env["CLAUDE_PROJECT_DIR"] = iso_dir

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
            errors.append(f"VALIDATION: conditional hook timeout (matching path): {hook}")
            return
        if res.returncode != 0:
            errors.append(
                f"VALIDATION: conditional hook nonzero rc on matching path: "
                f"{hook} rc={res.returncode}"
            )
            return
        out = res.stdout.strip()
        if not out:
            errors.append(f"VALIDATION: conditional hook empty envelope on matching path: {hook}")
            return
        try:
            data = json.loads(out)
        except json.JSONDecodeError as e:
            errors.append(f"VALIDATION: conditional hook invalid JSON on matching path: {hook} ({e})")
            return
        hso = data.get("hookSpecificOutput")
        if not isinstance(hso, dict):
            errors.append(
                f"VALIDATION: conditional hook envelope missing hookSpecificOutput object "
                f"on matching path: {hook}"
            )
        else:
            expected_event = EXPECTED_EVENT.get(hook)
            ev = hso.get("hookEventName")
            if expected_event and ev != expected_event:
                errors.append(
                    f"VALIDATION: conditional hook wrong hookEventName on matching path: "
                    f"{hook} got {ev!r} expected {expected_event!r}"
                )
            if not isinstance(hso.get("additionalContext"), str):
                errors.append(
                    f"VALIDATION: conditional hook additionalContext not a string "
                    f"on matching path: {hook}"
                )

        # (b) Non-matching path → silent exit 0.
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
            errors.append(f"VALIDATION: conditional hook timeout (non-matching path): {hook}")
            return
        if res2.returncode != 0:
            errors.append(
                f"VALIDATION: conditional hook nonzero rc on non-matching path: "
                f"{hook} rc={res2.returncode}"
            )
        if res2.stdout.strip():
            errors.append(f"VALIDATION: conditional hook non-silent on non-matching path: {hook}")


def check_hooks_json_targets(repo_root: Path, errors: list[str]) -> None:
    plugin_root = repo_root / "plugins" / "rein-core"
    hooks_dir = plugin_root / "hooks"
    hooks_json_path = hooks_dir / "hooks.json"
    if not hooks_json_path.exists():
        errors.append(f"VALIDATION: hooks.json missing: {hooks_json_path.relative_to(repo_root)}")
        return
    try:
        manifest = json.loads(hooks_json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        errors.append(f"VALIDATION: hooks.json invalid JSON: {e}")
        return
    marker = "${CLAUDE_PLUGIN_ROOT}/hooks/"
    try:
        hooks_dir_resolved = hooks_dir.resolve()
    except (OSError, RuntimeError):
        hooks_dir_resolved = hooks_dir
    for event, slots in manifest.get("hooks", {}).items():
        for slot in slots:
            for hook in slot.get("hooks", []):
                cmd = hook.get("command", "")
                if marker not in cmd:
                    errors.append(
                        f"VALIDATION: {event}: command does not use plugin root marker: {cmd}"
                    )
                    continue
                rel = cmd.split(marker, 1)[1]
                target = hooks_dir / rel
                # Path containment — `rel` 이 `..` 같은 traversal 포함 시 target 이
                # hooks_dir 외부 가능. resolve 후 relative_to 로 containment 강제.
                try:
                    target_resolved = target.resolve()
                    target_resolved.relative_to(hooks_dir_resolved)
                except (ValueError, OSError, RuntimeError):
                    errors.append(
                        f"VALIDATION: {event}: hooks.json target escapes hooks dir "
                        f"(path traversal 위험): {rel}"
                    )
                    continue
                if not target.exists():
                    errors.append(
                        f"VALIDATION: {event}: hooks.json references missing hook: {rel}"
                    )
                    continue
                if not (target.stat().st_mode & stat.S_IXUSR):
                    errors.append(
                        f"VALIDATION: {event}: hooks.json target not executable: {rel}"
                    )


# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(prog="rein-check-plugin-drift")
    ap.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repo root (defaults to script's parent dir).",
    )
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress success message; failure list still goes to stderr.",
    )
    ap.add_argument(
        "--skip-parity",
        action="store_true",
        help="Skip sha256 parity check (Option C Phase 3 후엔 자연 폐기).",
    )
    ap.add_argument(
        "--skip-boundary",
        action="store_true",
        help="Skip shared-rule boundary check (debug only).",
    )
    ap.add_argument(
        "--skip-validation",
        action="store_true",
        help="Skip plugin rules validation (이전 rein-validate-plugin-rules.py 흡수분).",
    )
    args = ap.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    plugin_root = repo_root / "plugins" / "rein-core"

    if not plugin_root.exists():
        print(f"{PREFIX} plugin root missing: {plugin_root}", file=sys.stderr)
        return 2

    errors: list[str] = []

    if not args.skip_boundary:
        check_shared_rule_boundary(repo_root, errors)

    if not args.skip_parity:
        check_sha256_parity(repo_root, errors)

    if not args.skip_validation:
        check_rules_dir_exists(repo_root, errors)
        check_action_mandate(repo_root, errors)
        check_inject_hooks_envelope(repo_root, errors)
        check_conditional_event_hook(repo_root, errors)
        check_hooks_json_targets(repo_root, errors)

    if errors:
        print(
            f"{PREFIX} {len(errors)} issue(s) detected "
            f"(boundary / parity / validation):",
            file=sys.stderr,
        )
        for e in errors:
            print(e, file=sys.stderr)
        print(
            f"\n{PREFIX} fix: see "
            f"`plugins/rein-core/rules/design-plan-coverage.md` for boundary policy, "
            f"`branch-strategy.md` for parity rationale, "
            f"`docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md` for "
            f"Option C migration plan.",
            file=sys.stderr,
        )
        return 1

    if not args.quiet:
        print(
            f"{PREFIX} OK — boundary + parity + validation all pass "
            f"(plugins/rein-core/ ↔ .claude/)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
