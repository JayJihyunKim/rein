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


def is_enabled(hook_name: str) -> bool:
    """Return True if hook is enabled (default), False only when explicitly disabled."""
    policy_path = Path(".rein/policy/hooks.yaml")
    if not policy_path.exists():
        return True  # default enabled (Plan Task 2.9 missing-key default)
    try:
        data = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    except Exception:
        # Malformed yaml -> fail-open per Plan Task 2.10.
        # Emit a one-line warning so a human notices, but never block.
        print(
            f"warning: failed to parse {policy_path} - using default (enabled)",
            file=sys.stderr,
        )
        return True
    if not isinstance(data, dict):
        # Top-level must be a mapping; otherwise treat as missing (default).
        return True
    raw = data.get(hook_name)
    if not isinstance(raw, dict):
        # Missing key OR non-dict shape -> default enabled.
        return True
    enabled = raw.get("enabled", True)
    return bool(enabled)


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
