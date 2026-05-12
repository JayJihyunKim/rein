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
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    # PyYAML not installed -> fail-open (Plan Task 2.10).
    # Without yaml we cannot parse the policy; default to enabled / no-override.
    # We still want CLI dispatch to exit 0 cleanly so the caller treats us as
    # "no change". `sys.exit(0)` here is a final fail-open; the rest of the
    # module never executes.
    sys.exit(0)


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
        "post-write-spec-review-gate": False,
        "post-write-dod-routing-check": False,
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
UMBRELLA_KEYS = {
    "pre-edit-trail-bootstrap-gate": "bootstrap-gate",
    "pre-tool-use-bash-bootstrap-gate": "bootstrap-gate",
}


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
            "usage: rein-policy-loader.py <hook-name> | --rule-override <rule-name>",
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

    # Default mode: hook toggle query (Task 2.7).
    hook_name = sys.argv[1]
    return 0 if is_enabled(hook_name) else 1


if __name__ == "__main__":
    sys.exit(main())
