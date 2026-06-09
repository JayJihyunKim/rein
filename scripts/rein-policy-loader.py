#!/usr/bin/env python3
"""Load .rein/policy/{hooks,rules}.yaml and answer policy queries.

Two CLI modes:
    rein-policy-loader.py <hook-name>
        Hook toggle (Task 2.7). Exit 0 if enabled, 1 if disabled.
    rein-policy-loader.py --rule-override <rule-name>
        Rule override (Task 2.8). Print override body to stdout if defined,
        else print nothing. Always exit 0.

Fail-open: every error path (missing file, malformed yaml, missing key,
unexpected shape, missing PyYAML) returns the most permissive default — never
accidentally disable a hook or drop the user's override silently.
(Plan Tasks 2.9 + 2.10 fail-open semantics.)

Resolution order (relative to current working directory):
    .rein/policy/hooks.yaml   — hook toggles
    .rein/policy/rules.yaml   — prompt-only rule body overrides
"""
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


# Registered persona presets — single source of truth for membership
# validation (PP-3). Adding a preset means adding its name here AND creating
# rules/persona/<name>.md. A name that passes the format allowlist but is not
# listed here is downgraded to the default preset (fail-safe) so the hook
# never points at a missing rules/persona/<typo>.md (which would silently
# skip persona injection entirely).
KNOWN_PERSONA_PRESETS = {"boss-ace"}
PERSONA_NAME_RE = re.compile(r"^[a-z0-9-]+$")
DEFAULT_PERSONA = "boss-ace"


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


def get_persona() -> tuple[bool, str]:
    """Return (enabled, preset) for the active persona layer.

    Reads .rein/policy/persona.yaml's top-level {enabled, preset}.
    Fail-open at every error path: missing file, PyYAML absent, parse
    error, non-dict top-level, missing/non-bool `enabled`, missing/invalid
    `preset` all yield (True, DEFAULT_PERSONA). Only an explicit
    `enabled: false` disables. The returned preset name is ALWAYS validated
    (format allowlist ^[a-z0-9-]+$ AND membership in KNOWN_PERSONA_PRESETS);
    any failure downgrades to DEFAULT_PERSONA (PP-3).

    Scope ID: PP-2, PP-3
    """
    if yaml is None:
        return (True, DEFAULT_PERSONA)
    policy_path = Path(".rein/policy/persona.yaml")
    if not policy_path.exists():
        return (True, DEFAULT_PERSONA)
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        print(
            f"warning: failed to parse {policy_path} - using default persona",
            file=sys.stderr,
        )
        return (True, DEFAULT_PERSONA)
    if not isinstance(data, dict):
        return (True, DEFAULT_PERSONA)
    enabled = False if data.get("enabled") is False else True
    preset = _validate_persona_name(data.get("preset"))
    return (enabled, preset)


def _validate_persona_name(raw) -> str:
    """Return a trusted preset name, downgrading to DEFAULT_PERSONA on any
    validation failure (PP-3): non-str, empty, format violation
    (path traversal / substitution chars), or not in KNOWN_PERSONA_PRESETS."""
    if not isinstance(raw, str):
        return DEFAULT_PERSONA
    candidate = raw.strip()
    if not candidate or not PERSONA_NAME_RE.match(candidate):
        return DEFAULT_PERSONA
    if candidate not in KNOWN_PERSONA_PRESETS:
        return DEFAULT_PERSONA
    return candidate


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
            "usage: rein-policy-loader.py <hook-name> | --rule-override <rule-name> | --meta-check-policy | --persona",
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
        # PP-4: print the validated active preset name (one line) when enabled,
        # nothing when disabled. Always exit 0 so the hook never breaks the
        # SessionStart envelope.
        enabled, preset = get_persona()
        if enabled:
            sys.stdout.write(preset)
        return 0

    # Default mode: hook toggle query (Task 2.7).
    hook_name = sys.argv[1]
    return 0 if is_enabled(hook_name) else 1


if __name__ == "__main__":
    sys.exit(main())
