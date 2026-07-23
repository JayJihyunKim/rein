#!/usr/bin/env python3
"""Load .rein/policy/{hooks,rules}.yaml and answer policy queries.

CLI modes:
    rein-policy-loader.py <hook-name>
        Hook toggle (Task 2.7). Exit 0 if enabled, 1 if disabled.
    rein-policy-loader.py --rule-override <rule-name>
        Rule override (Task 2.8). Print override body to stdout if defined,
        else print nothing. Always exit 0.
    rein-policy-loader.py --turn-brief
        Per-turn brief (PT-7). Emit the complete UserPromptSubmit envelope
        (answer-only + response-tone + persona summaries, optional bootstrap
        prepend via env REIN_TURN_BRIEF_PREPEND) in ONE process. Always exit 0.

Fail-open: every error path (missing file, malformed yaml, missing key,
unexpected shape, missing PyYAML) returns the most permissive default — never
accidentally disable a hook or drop the user's override silently.
(Plan Tasks 2.9 + 2.10 fail-open semantics.)

Resolution order (relative to current working directory):
    .rein/policy/hooks.yaml   — hook toggles
    .rein/policy/rules.yaml   — prompt-only rule body overrides
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    # PyYAML not installed -> fail-open (Plan Task 2.10).
    # Set yaml=None so each function can return its own fail-open default
    # (enabled / no-override / 'auto'). Previously this branch did
    # sys.exit(0) at module level, which made --meta-check-policy emit
    # empty stdout instead of the contractually required 'auto'. The
    # explicit yaml=None sentinel lets callers see a well-typed answer.
    yaml = None


# Phase 4 운영 프로파일 — profile 키가 set 됐을 때 각 hook 의 기본값을 매핑.
# 개별 키 override 가 우선하고, profile 은 default 값을 흔든다. profile 매핑에
# 등재되지 않은 hook 은 모두 enabled.
#
# - lean:     단순 탐색/문서 작업. 무거운 design/coverage gate 비활성화.
# - standard: 일반 개발 (기본값). 모든 gate enabled.
# - strict:   릴리즈/보안 민감 변경. 현재 standard 와 동일하지만 향후 추가
#             strictness 옵션의 reserved slot.
PROFILE_HOOK_DEFAULTS = {
    "lean": {
        "post-edit-plan-coverage": False,
        "post-edit-spec-review-gate": False,
        "post-edit-dod-routing-check": False,
    },
    "standard": {},
    "strict": {},
}


# Umbrella keys (Wave 2 Task 1.5): a single umbrella key in hooks.yaml can toggle
# multiple individual hook keys at once. Individual key explicit entries always
# take precedence over the umbrella value. Hooks not listed here are unaffected
# by any umbrella value.
#
# - bootstrap-gate: toggles both the pre-edit and pre-tool-use-bash variants of
#   the bootstrap gate (Wave 2 bootstrap gate split).
# - pre-bash-guard: legacy compatibility umbrella (HK-2, cc-feature-adoption
#   Task 1.2). pre-bash-guard.sh was split into pre-bash-safety-guard.sh +
#   pre-bash-test-commit-gate.sh. A project that disabled the old single hook
#   via `pre-bash-guard: false` keeps BOTH halves disabled through this
#   umbrella; explicit per-hook entries still override it.
UMBRELLA_KEYS = {
    "pre-edit-trail-bootstrap-gate": "bootstrap-gate",
    "pre-tool-use-bash-bootstrap-gate": "bootstrap-gate",
    "pre-bash-safety-guard": "pre-bash-guard",
    "pre-bash-test-commit-gate": "pre-bash-guard",
}


# Registered BUILT-IN persona presets — single source of truth for the builtin
# tier (PP-3). Adding a builtin preset means adding its name here AND creating
# rules/persona/<name>.md under the plugin root. Builtin names ALWAYS win over
# same-name custom files. Names outside this set may still resolve as CUSTOM
# presets from CUSTOM_PERSONA_DIR after validation (containment + UTF-8 decode
# + char cap); anything unresolvable downgrades to DEFAULT_PERSONA (fail-safe)
# so the hook never points at a missing file.
KNOWN_PERSONA_PRESETS = {"boss-ace", "jennie"}
PERSONA_NAME_RE = re.compile(r"^[a-z0-9-]+$")
DEFAULT_PERSONA = "boss-ace"
# Custom persona tier — resolved relative to the current working directory
# (the user's project root, same convention as .rein/policy/*.yaml).
CUSTOM_PERSONA_DIR = Path(".rein/policy/persona")
CUSTOM_PERSONA_MAX_CHARS = 4000


def _normalize_enabled(raw):
    """Normalize a yaml entry to an enabled bool.

    Accepts:
        bool          -> returned as-is
        {enabled: ...} -> coerced to bool (default True if key missing)
    Anything else -> None (caller should fall through to lower-precedence default).
    """
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, dict):
        return bool(raw.get("enabled", True))
    return None


def _load_policy_data():
    """Return parsed yaml dict or None. Warn-only on parse failure."""
    if yaml is None:
        return None
    policy_path = Path(".rein/policy/hooks.yaml")
    if not policy_path.exists():
        return None
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        print(
            f"warning: failed to parse {policy_path} - using default (enabled)",
            file=sys.stderr,
        )
        return None
    if not isinstance(data, dict):
        return None
    return data


def _profile_default(data: dict, hook_name: str):
    """Look up the hook's profile-driven default. Return True/False or None when
    the profile does not set an explicit value for this hook."""
    profile = data.get("profile")
    if not isinstance(profile, str):
        return None
    profile = profile.strip().lower()
    mapping = PROFILE_HOOK_DEFAULTS.get(profile)
    if mapping is None:
        # Unknown profile name -> warn but fall through to default enabled.
        print(
            f"warning: unknown profile '{profile}' in .rein/policy/hooks.yaml - "
            "ignoring (use lean | standard | strict)",
            file=sys.stderr,
        )
        return None
    if hook_name in mapping:
        return mapping[hook_name]
    return None


def is_enabled(hook_name: str) -> bool:
    """Return True if hook is enabled (default), False only when explicitly disabled.

    Accept both documented shorthand:
        pre-bash-guard: false
    and the original structured form:
        pre-bash-guard:
          enabled: false

    Resolution order:
        1. Explicit per-hook entry (bool shorthand or {enabled: ...} mapping)
        2. Umbrella key (e.g. `bootstrap-gate`) when the hook is registered in
           UMBRELLA_KEYS and the individual entry is absent
        3. profile-driven default from PROFILE_HOOK_DEFAULTS
        4. Built-in default = True
    """
    data = _load_policy_data()
    if data is None:
        return True  # default enabled (Plan Task 2.9 missing-key default)

    # 1. explicit per-hook override
    raw = data.get(hook_name)
    normalized = _normalize_enabled(raw)
    if normalized is not None:
        return normalized
    # raw is None or unsupported shape -> fall through.

    # 2. umbrella key fallback (Wave 2 Task 1.5)
    umbrella_key = UMBRELLA_KEYS.get(hook_name)
    if umbrella_key is not None:
        umbrella_raw = data.get(umbrella_key)
        umbrella_normalized = _normalize_enabled(umbrella_raw)
        if umbrella_normalized is not None:
            return umbrella_normalized

    # 3. profile-driven default
    profile_default = _profile_default(data, hook_name)
    if profile_default is not None:
        return profile_default

    # 4. built-in default
    return True


def get_rule_override(rule_name: str):
    """Return override body for a single rule key, or None if absent.

    Reads .rein/policy/rules.yaml. Fail-open on every error path: missing
    file, parse error, non-dict top-level, missing or malformed entry —
    all yield None, signalling "use default body" upstream.
    Only a string value at `<rule_name>.override` is returned.
    """
    if yaml is None:
        return None
    policy_path = Path(".rein/policy/rules.yaml")
    if not policy_path.exists():
        return None
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        # Malformed yaml -> fail-open per Plan Task 2.10.
        # Emit warning so the user sees something is wrong, but never block.
        print(
            f"warning: failed to parse {policy_path} - using default",
            file=sys.stderr,
        )
        return None
    if not isinstance(data, dict):
        return None
    rule_cfg = data.get(rule_name)
    if not isinstance(rule_cfg, dict):
        return None
    override = rule_cfg.get("override")
    if not isinstance(override, str):
        return None
    return override


def get_meta_check_policy() -> str:
    """Return effective meta-check policy: 'true' | 'false' | 'auto'.

    Reads .rein/policy/meta-check.yaml's top-level `enabled` field.
    Fail-open at every error path: missing file, PyYAML absent, parse
    error, non-dict top-level, missing `enabled`, or value outside
    {'true', 'false', 'auto'} all yield 'auto'.

    Scope ID: G3-MC-POLICY
    """
    if yaml is None:
        return "auto"
    policy_path = Path(".rein/policy/meta-check.yaml")
    if not policy_path.exists():
        return "auto"
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        print(
            f"warning: failed to parse {policy_path} - using default 'auto'",
            file=sys.stderr,
        )
        return "auto"
    if not isinstance(data, dict):
        return "auto"
    enabled = data.get("enabled")
    if enabled is True:
        return "true"
    if enabled is False:
        return "false"
    if isinstance(enabled, str):
        normalized = enabled.strip().lower()
        if normalized in ("true", "false", "auto"):
            return normalized
    return "auto"


def get_persona() -> tuple[bool, object]:
    """Return (enabled, preset_raw) for the persona layer — NEUTRAL default.

    Reads .rein/policy/persona.yaml's top-level {enabled, preset}. The
    persona layer is active ONLY when the file parses to a dict whose
    `enabled` is literally the bool True (`data.get("enabled") is True`).
    Every other state — missing file, PyYAML absent, parse error, non-dict
    top-level, absent/string/int `enabled`, explicit false — yields
    (False, DEFAULT_PERSONA): the persona layer stays OFF (PP-2 neutral
    default).

    The second element is the RAW `preset` value (no validation here — it
    may be a non-str: number, list, None...). Format validation and
    downgrade are unified at the consumption point via
    resolve_persona_source() -> _validate_persona_name() (PP-3) so there is
    exactly one interpretation path and no double validation.

    Scope ID: PP-2, PP-3
    """
    if yaml is None:
        return (False, DEFAULT_PERSONA)
    policy_path = Path(".rein/policy/persona.yaml")
    if not policy_path.exists():
        return (False, DEFAULT_PERSONA)
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        print(
            f"warning: failed to parse {policy_path} - persona stays off",
            file=sys.stderr,
        )
        return (False, DEFAULT_PERSONA)
    if not isinstance(data, dict):
        return (False, DEFAULT_PERSONA)
    enabled = data.get("enabled") is True
    preset = data.get("preset")
    return (enabled, preset)


def _leading_fence_awk_mismatch(text: str) -> bool:
    """True iff the lenient parser sees a leading frontmatter fence but the
    hook's awk does NOT — the general (P)∧¬(A) invariant (spec §4).

    (P) parser view: str.splitlines()[0].strip() == "---" (splitlines splits
        on \\r, \\r\\n and unicode line separators — the same lenient view
        the frontmatter parsers use).
    (A) awk view: the leading raw \\n-record (text.split("\\n",1)[0]) is
        byte-exact "---". MUST be a \\n-literal split on newline-PRESERVING
        text — never str.splitlines() (which strips a trailing \\r / U+2028
        and would hide CRLF / bare-CR / unicode-separator fences).

    Reject (True) iff (P) and not (A). One rule closes padded ` --- `, CRLF
    `---\\r`, bare-CR `---\\r`(no \\n in file), and unicode line-separator
    terminators uniformly; exact `---`(LF) fences and no-frontmatter files
    are untouched (returns False).
    """
    if not text:
        return False
    lines = text.splitlines()
    parser_sees_fence = bool(lines) and lines[0].strip() == "---"
    awk_sees_exact = text.split("\n", 1)[0] == "---"
    return parser_sees_fence and not awk_sees_exact


def _validate_persona_name(raw) -> str | None:
    """FORMAT-ONLY validation: return the candidate name when `raw` is a
    non-empty string matching ^[a-z0-9-]+$ (blocks path traversal /
    substitution chars / hidden `_`-prefixed files), else None. Membership
    and downgrade decisions live in resolve_persona_source()."""
    if not isinstance(raw, str):
        return None
    candidate = raw.strip()
    if not candidate or not PERSONA_NAME_RE.match(candidate):
        return None
    return candidate


def resolve_persona_source(preset_raw) -> tuple[str, str | None]:
    """Resolve the raw preset value to (name, source_path) — the single
    trusted interpretation point (D2) shared by --persona / --persona-file
    and the turn brief.

    Name-level rules:
        format violation           -> DEFAULT_PERSONA
        builtin member             -> name kept (path depends on plugin root)
        non-member, valid custom   -> name kept (cwd-based validation, root-
                                      independent, so --persona stays
                                      deterministic even without a root)
        non-member, invalid custom -> DEFAULT_PERSONA (PP-3 extended)

    Path-level: _resolve_persona_file() applies D1 — CLAUDE_PLUGIN_ROOT
    unset means the invariant layer is unresolvable, so the path is always
    None regardless of tier.
    """
    name = _validate_persona_name(preset_raw)
    if name is None:
        name = DEFAULT_PERSONA
    path = _resolve_persona_file(name)
    if path is None and name != DEFAULT_PERSONA:
        # unresolvable custom/typo -> known-good downgrade (PP-3 확장)
        if name not in KNOWN_PERSONA_PRESETS and not _custom_persona_valid(name):
            name = DEFAULT_PERSONA
            path = _resolve_persona_file(name)
    return (name, path)


def _resolve_persona_file(name):
    """Return the persona source file path for `name`, or None.

    D1: without CLAUDE_PLUGIN_ROOT the invariant layer cannot be resolved,
    so NO source path is ever emitted (not even a custom-only one). Builtin
    names resolve exclusively under the plugin root (same-name customs are
    ignored — builtin wins); non-builtin names resolve from
    CUSTOM_PERSONA_DIR only after _custom_persona_valid().
    """
    root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if not root:
        return None  # D1: invariant layer unresolvable -> no path, ever
    try:
        # .resolve(): the CLI contract promises an ABSOLUTE path — a relative
        # CLAUDE_PLUGIN_ROOT would otherwise leak through (integrated-review fix;
        # custom tier already resolves). Wrapped fail-open: a pathological root
        # (e.g. over-long path -> OSError ENAMETOOLONG) or a .resolve()/is_file()
        # filesystem error must yield None, never crash the caller — every CLI
        # persona path (--persona / --persona-file / --persona-greeting) promises
        # empty output + exit 0.
        builtin = (Path(root) / "rules" / "persona" / f"{name}.md").resolve()
        if name in KNOWN_PERSONA_PRESETS:
            return str(builtin) if builtin.is_file() else None  # builtin wins; same-name custom ignored
        if _custom_persona_valid(name):
            return str((CUSTOM_PERSONA_DIR / f"{name}.md").resolve())
        return None
    except Exception:
        return None  # filesystem resolution failure -> fail-open (no path)


def _custom_persona_valid(name) -> bool:
    """True iff `.rein/policy/persona/<name>.md` (cwd-relative) is a safe
    custom persona source: realpath containment inside the persona dir
    (blocks symlink escape), a regular file, UTF-8 decodable, at most
    CUSTOM_PERSONA_MAX_CHARS characters, AND free of a (P)∧¬(A) leading
    fence mismatch (spec §4 fail-safe). Any exception -> False (fail-safe).
    """
    try:
        base = CUSTOM_PERSONA_DIR.resolve()
        cand = base / f"{name}.md"
        real = cand.resolve()
        if real.parent != base:
            return False  # containment violated (symlink escape)
        if not real.is_file():
            return False
        # newline-PRESERVING read: read_bytes().decode() keeps \r / U+2028 so
        # the (A) awk view is computed on raw newlines. Path.read_text() would
        # universal-newline normalize and hide CRLF / bare-CR fences.
        text = real.read_bytes().decode("utf-8")
        if len(text) > CUSTOM_PERSONA_MAX_CHARS:
            return False
        if _leading_fence_awk_mismatch(text):
            return False  # (P)∧¬(A) open fence -> fail-safe reject
        return True
    except Exception:
        return False


def _read_frontmatter_summary(path) -> str | None:
    """Return the `summary:` field from a leading `---` frontmatter block.

    Task 3.1: only when the file's FIRST line is `---` AND the block is
    CLOSED by a second `---`, return the first `^summary:\\s*(.+)$` match
    found inside the block. Closure is mandatory (integrated-review fix —
    an unclosed fence makes the hook's awk strip swallow the whole body, so
    accepting its summary here would report a preset that injects nothing).
    Everything else — path None, unreadable file, no leading frontmatter,
    closed without a match, never closed — yields None (fail-open).
    """
    if not path:
        return None
    try:
        text = Path(path).read_text(encoding="utf-8")
    except Exception:
        return None
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    summary = None
    for line in lines[1:]:
        if line.strip() == "---":
            return summary  # closed — summary valid only now
        if summary is None:
            m = re.match(r"^summary:\s*(.+)$", line)
            if m:
                summary = m.group(1).strip()
    return None  # never closed — no valid frontmatter


def _read_frontmatter_greeting(path) -> str | None:
    """Return the `greeting:` field from a leading `---` frontmatter block.

    Sibling of _read_frontmatter_summary but matches `^greeting:`. Used only
    on already-trusted presets (builtin) or _custom_persona_valid-validated
    customs, so the lenient parser view (splitlines) is correct here — the
    (P)∧¬(A) fence fail-safe lives in _custom_persona_valid, not here.
    Closure mandatory; everything else -> None (fail-open).
    """
    if not path:
        return None
    try:
        text = Path(path).read_text(encoding="utf-8")
    except Exception:
        return None
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    greeting = None
    for line in lines[1:]:
        if line.strip() == "---":
            return greeting  # closed — greeting valid only now
        if greeting is None:
            m = re.match(r"^greeting:\s*(.+)$", line)
            if m:
                greeting = m.group(1).strip()
    return None  # never closed — no valid frontmatter


def _read_text_or_empty(path: Path) -> str:
    """Read a file's text, returning '' on any error (fail-open)."""
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def get_turn_brief() -> str:
    """Assemble the per-turn UserPromptSubmit additionalContext body in ONE
    process (PT-7).

    Composition (separated by '\\n\\n---\\n\\n'):
        [optional prepend] + answer-only summary + response-tone summary
        + persona summary (only when the persona layer is enabled)

    The answer-only summary is the ONLY hard requirement; response-tone and
    persona are optional and skipped when absent. The optional prepend comes
    from env REIN_TURN_BRIEF_PREPEND (the hook's bash-computed bootstrap
    advisory) so a single Python process can both compose the body AND
    json-encode the envelope — no second spawn (PT-8 perf contract).

    Fail-open at every path: CLAUDE_PLUGIN_ROOT unset/empty, or the answer-only
    summary missing/unreadable, yields ''. All reads are guarded. Files are
    read under the trusted CLAUDE_PLUGIN_ROOT, so no path-traversal surface.

    Scope ID: PT-7
    """
    root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if not root:
        return ""
    short_dir = Path(root) / "rules" / "short"

    answer_only = _read_text_or_empty(short_dir / "answer-only-summary.md")
    if not answer_only.strip():
        return ""  # hard requirement absent -> no-op (fail-open)

    parts = [answer_only.rstrip("\n")]

    response_tone = _read_text_or_empty(short_dir / "response-tone-summary.md")
    if response_tone.strip():
        parts.append(response_tone.rstrip("\n"))

    enabled, preset_raw = get_persona()
    if enabled:
        persona = _read_text_or_empty(short_dir / "persona-summary.md")
        if persona.strip():
            # Task 3.1: the nudge text is preset-agnostic; append ONE line
            # naming the ACTIVE preset (resolved via the single trusted
            # interpretation point) plus its frontmatter summary when present.
            name, source_path = resolve_persona_source(preset_raw)
            summary = _read_frontmatter_summary(source_path)
            if summary:
                active_line = f"활성 프리셋: {name} — {summary}"
            else:
                active_line = f"활성 프리셋: {name}"
            parts.append(persona.rstrip("\n") + "\n" + active_line)

    body = "\n\n---\n\n".join(parts)

    prepend = os.environ.get("REIN_TURN_BRIEF_PREPEND", "")
    if prepend.strip():
        body = prepend.rstrip("\n") + "\n---\n\n" + body

    return body


def get_all_rule_overrides() -> dict:
    """Return all rule overrides as {rule_name: override_body}.

    Only keys with a string `override` value are included.
    """
    result = {}
    for rule_name in ("code-style", "security", "testing"):
        override = get_rule_override(rule_name)
        if override is not None:
            result[rule_name] = override
    return result


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: rein-policy-loader.py <hook-name> | --rule-override <rule-name> | --meta-check-policy | --persona | --persona-file | --persona-greeting <name> | --turn-brief",
            file=sys.stderr,
        )
        return 0  # fail-open - never block a hook due to internal usage error

    if sys.argv[1] == "--rule-override":
        # Task 2.8 CLI: print override body (or nothing) and always exit 0.
        if len(sys.argv) < 3:
            return 0  # fail-open: missing rule-name argv
        rule_name = sys.argv[2]
        override = get_rule_override(rule_name)
        if override is not None:
            sys.stdout.write(override)
        return 0

    if sys.argv[1] == "--meta-check-policy":
        # G3 Phase 2 Task 2.1: print effective meta-check policy
        # ('true' | 'false' | 'auto') to stdout, always exit 0.
        sys.stdout.write(get_meta_check_policy())
        return 0

    if sys.argv[1] == "--persona":
        # PP-4: print the RESOLVED active preset name (one line) when enabled,
        # nothing when disabled (neutral default). Interpretation of the raw
        # preset value is unified in resolve_persona_source(). Always exit 0
        # so the hook never breaks the SessionStart envelope.
        enabled, preset = get_persona()
        if enabled:
            sys.stdout.write(resolve_persona_source(preset)[0])
        return 0

    if sys.argv[1] == "--persona-file":
        # Single trusted boundary for the hook (spec §10): print the resolved
        # persona source path (one line) when the layer is enabled AND a path
        # resolves (D1: no CLAUDE_PLUGIN_ROOT -> always empty), else empty
        # stdout. Always exit 0.
        enabled, preset = get_persona()
        if enabled:
            path = resolve_persona_source(preset)[1]
            if path is not None:
                sys.stdout.write(path)
        return 0

    if sys.argv[1] == "--persona-greeting":
        # Greeting boundary (spec OQ2): print the stored `greeting:` line for a
        # VALIDATED builtin or custom preset named on argv, else empty stdout,
        # always exit 0 (fail-open). Does NOT reuse resolve_persona_source(),
        # which downgrades typos to boss-ace and would leak a wrong greeting
        # (High-1). _resolve_persona_file() returns None (never a downgrade) for
        # invalid / typo / traversal / unresolved / (P)∧¬(A)-fence customs.
        if len(sys.argv) < 3:
            return 0
        name = _validate_persona_name(sys.argv[2])
        if name is None:
            return 0  # format violation / traversal / empty -> empty stdout
        path = _resolve_persona_file(name)  # None on D1 / missing / invalid custom
        if path is None:
            return 0
        greeting = _read_frontmatter_greeting(path)
        if greeting:
            sys.stdout.write(greeting)
        return 0

    if sys.argv[1] == "--turn-brief":
        # PT-7: emit the COMPLETE per-turn UserPromptSubmit envelope in one
        # process. get_turn_brief() composes the body (answer-only +
        # response-tone + persona summaries, with optional bootstrap prepend
        # via env); empty body -> no-op (no envelope). Always exit 0 so the
        # hook never breaks the turn.
        body = get_turn_brief()
        if body:
            envelope = {
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": body,
                }
            }
            sys.stdout.write(json.dumps(envelope) + "\n")
        return 0

    # Default mode: hook toggle query (Task 2.7).
    hook_name = sys.argv[1]
    return 0 if is_enabled(hook_name) else 1


if __name__ == "__main__":
    sys.exit(main())
