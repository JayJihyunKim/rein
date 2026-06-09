#!/usr/bin/env bash
# test-policy-loader-persona.sh - 페르소나 프리셋 loader 단위·drift 회귀 테스트.
#
# Plan: docs/plans/2026-06-09-persona-preset-implementation.md Task 2.1.
# Scope ID: PP-6, PP-2 (PP-5 drift via assert (a)).
#
# Verifies `rein-policy-loader.py --persona` across every fail-open branch of
# get_persona() / _validate_persona_name(). Contract: ALL error/downgrade paths
# (missing file, parse error, non-dict top-level, missing `enabled`/`preset`,
# PyYAML absent, format violation, unregistered name) yield the default
# `boss-ace` on stdout with exit 0. Only an explicit `enabled: false` disables
# (empty stdout). The validated active preset name is the ONLY thing the hook
# composes into a `${PERSONA}.md` path, so this test pins the trust boundary.
#
# Harness pattern mirrors test-policy-yaml-fails-open.sh: each fixture uses a
# fresh temp cwd so the loader's relative `.rein/policy/persona.yaml` resolution
# is isolated and the rein-dev repo's own .rein/ is never touched.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"
FALLBACK_LOADER="$PROJECT_DIR/scripts/rein-policy-loader.py"

if [ ! -x "$PLUGIN_LOADER" ]; then
  echo "FAIL: plugin loader missing or not executable: $PLUGIN_LOADER" >&2
  exit 1
fi
if [ ! -x "$FALLBACK_LOADER" ]; then
  echo "FAIL: fallback loader missing or not executable: $FALLBACK_LOADER" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
fail() {
  echo "FAIL: $1" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

# Run `--persona` in a freshly created temp cwd whose .rein/policy/persona.yaml
# content is $1 (or no file when $1 is the literal token __NOFILE__). Captures
# stdout to the global PERSONA_OUT and exit code to PERSONA_RC. Each call gets
# its own subdir so fixtures never leak into one another. Runs with the DEFAULT
# PYTHONPATH (the PyYAML-absent shim in assert (c) is isolated separately).
run_persona() {
  local body="$1"
  local d
  d="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
  mkdir -p "$d/.rein/policy"
  if [ "$body" != "__NOFILE__" ]; then
    printf '%s' "$body" >"$d/.rein/policy/persona.yaml"
  fi
  set +e
  PERSONA_OUT="$(cd "$d" && python3 "$PLUGIN_LOADER" --persona 2>/dev/null)"
  PERSONA_RC=$?
  set -e
}

# Assert that the given persona.yaml body yields the default `boss-ace` preset
# on stdout with exit 0 (the universal fail-open / downgrade contract).
expect_default() {
  local label="$1" body="$2"
  run_persona "$body"
  [ "$PERSONA_RC" = "0" ] || fail "$label: expected exit 0, got $PERSONA_RC"
  [ "$PERSONA_OUT" = "boss-ace" ] || fail "$label: expected stdout 'boss-ace', got '$PERSONA_OUT'"
  ok "$label"
}

# -----------------------------------------------------------------------------
# (a) byte-identical drift guard (PP-5): the two loader copies (plugin SSOT +
#     root fallback) must be byte-for-byte identical. A drift here would let the
#     plugin and fallback resolvers disagree on persona validation.
# -----------------------------------------------------------------------------
if diff "$PLUGIN_LOADER" "$FALLBACK_LOADER" >/dev/null 2>&1; then
  ok "(a) two loader copies byte-identical (diff empty)"
else
  echo "  --- diff plugin vs fallback ---" >&2
  diff "$PLUGIN_LOADER" "$FALLBACK_LOADER" >&2 || true
  fail "(a) loader copies differ (PP-5 drift): plugin SSOT and root fallback must be byte-identical"
fi

# -----------------------------------------------------------------------------
# (b) fail-open BEFORE validation — all yield default `boss-ace`:
#     missing file / parse-error YAML / non-dict top-level / `enabled` absent /
#     `preset` absent.
# -----------------------------------------------------------------------------
expect_default "(b1) missing persona.yaml -> default-ON boss-ace" "__NOFILE__"
expect_default "(b2) parse-error YAML (enabled: : :) -> boss-ace" $'enabled: : :\n'
expect_default "(b3) non-dict top-level (- a) -> boss-ace" $'- a\n'
expect_default "(b4) enabled key absent (preset only) -> boss-ace" $'preset: boss-ace\n'
expect_default "(b5) preset key absent (enabled only) -> boss-ace" $'enabled: true\n'

# -----------------------------------------------------------------------------
# (c) PyYAML-absent branch — shim a fake `yaml.py` that raises ImportError on
#     `import yaml`, place it FIRST on PYTHONPATH so the loader's top-level
#     `import yaml` hits it, falling into `except ImportError: yaml = None` and
#     then get_persona()'s `if yaml is None: return (True, DEFAULT_PERSONA)`.
#     This makes the PyYAML-absent fail-open an automatic assert (no manual
#     justification). Cleaned up via the global TMP_ROOT trap; also isolated to
#     a subshell so the poisoned PYTHONPATH never leaks to other asserts.
# -----------------------------------------------------------------------------
FAKE_DIR="$TMP_ROOT/fakeyaml"
mkdir -p "$FAKE_DIR"
printf '%s\n' 'raise ImportError("simulated missing PyYAML")' >"$FAKE_DIR/yaml.py"
C_DIR="$(mktemp -d "$TMP_ROOT/noyaml.XXXXXX")"
mkdir -p "$C_DIR/.rein/policy"
# A perfectly valid persona.yaml: proves the downgrade is driven by the absent
# PyYAML branch, not by a parse/shape error.
printf '%s\n%s\n' 'enabled: true' 'preset: boss-ace' >"$C_DIR/.rein/policy/persona.yaml"
set +e
C_OUT="$(
  cd "$C_DIR" && \
  PYTHONPATH="$FAKE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$PLUGIN_LOADER" --persona 2>/dev/null
)"
C_RC=$?
set -e
[ "$C_RC" = "0" ] || fail "(c) PyYAML absent: expected exit 0, got $C_RC"
[ "$C_OUT" = "boss-ace" ] || fail "(c) PyYAML absent: expected stdout 'boss-ace', got '$C_OUT'"
# Sanity: confirm the shim actually broke `import yaml` (guard against a stdlib
# path or installed PyYAML silently shadowing the fake and giving a false pass).
set +e
SHIM_PROBE="$(
  cd "$C_DIR" && \
  PYTHONPATH="$FAKE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -c 'import yaml' 2>&1
)"
SHIM_RC=$?
set -e
[ "$SHIM_RC" != "0" ] || fail "(c) PyYAML shim ineffective: 'import yaml' unexpectedly succeeded (fake not first on PYTHONPATH)"
case "$SHIM_PROBE" in
  *"simulated missing PyYAML"*) : ;;
  *) fail "(c) PyYAML shim ineffective: import error was not the simulated one: $SHIM_PROBE" ;;
esac
ok "(c) PyYAML absent (PYTHONPATH shim) -> exit 0 + boss-ace"

# -----------------------------------------------------------------------------
# (d) path-injection downgrade (PP-3 format allowlist ^[a-z0-9-]+$): a preset
#     value carrying traversal / substitution / whitespace chars must downgrade
#     to boss-ace so the hook never composes a malicious `${PERSONA}.md` path.
# -----------------------------------------------------------------------------
expect_default "(d1) preset ../x (traversal) -> boss-ace" $'enabled: true\npreset: "../x"\n'
expect_default "(d2) preset a/b (slash) -> boss-ace" $'enabled: true\npreset: "a/b"\n'
expect_default "(d3) preset \$(x) (substitution) -> boss-ace" $'enabled: true\npreset: "$(x)"\n'
expect_default "(d4) preset empty string -> boss-ace" $'enabled: true\npreset: ""\n'

# -----------------------------------------------------------------------------
# (e) unregistered-name downgrade (PP-3 membership): a name that PASSES the
#     format allowlist but is not in KNOWN_PERSONA_PRESETS must downgrade to
#     boss-ace (so the hook never points at a missing rules/persona/<x>.md).
# -----------------------------------------------------------------------------
expect_default "(e1) preset mentor (format OK, unregistered) -> boss-ace" $'enabled: true\npreset: mentor\n'
expect_default "(e2) preset does-not-exit (unregistered) -> boss-ace" $'enabled: true\npreset: does-not-exit\n'

# -----------------------------------------------------------------------------
# (f) opt-out: explicit `enabled: false` -> empty stdout (persona disabled).
# -----------------------------------------------------------------------------
run_persona $'enabled: false\npreset: boss-ace\n'
[ "$PERSONA_RC" = "0" ] || fail "(f) opt-out: expected exit 0, got $PERSONA_RC"
[ -z "$PERSONA_OUT" ] || fail "(f) opt-out: expected EMPTY stdout, got '$PERSONA_OUT'"
ok "(f) enabled: false -> empty stdout (opt-out)"

# -----------------------------------------------------------------------------
# (g) happy path: a fully valid {enabled: true, preset: boss-ace} -> boss-ace.
# -----------------------------------------------------------------------------
expect_default "(g) enabled:true, preset:boss-ace -> boss-ace" $'enabled: true\npreset: boss-ace\n'

echo ""
echo "test-policy-loader-persona: OK ($PASS asserts passed)"
