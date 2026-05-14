#!/usr/bin/env bash
# test-policy-yaml-fallback.sh - Plugin-First Restructure Phase 2 Task 2.9.
#
# Verifies rein-policy-loader.py BEHAVIOR for the "key present yaml file but
# requested key absent" axis. Different from test-policy-hooks-toggle.sh
# (Fixture E) in that we exercise BOTH cli modes (hook toggle + rule override)
# and BOTH policy files (hooks.yaml + rules.yaml) in dedicated fixtures so a
# regression on one path does not hide a regression on the other.
#
# Loader contract (Plan §622-634): when the policy yaml exists but is missing
# the key the caller asked about, return the **default**:
#   - is_enabled(<hook>)     -> True  (exit 0)
#   - get_rule_override(<r>) -> None  (empty stdout, exit 0)
#
# Fixtures (each in its own mktemp -d cwd; loader resolves .rein/policy/*.yaml
# relative to cwd, so we never touch the rein-dev repo's own .rein/ tree):
#   Fixture A: hooks.yaml has only `other-hook`, query `pre-bash-guard` -> exit 0
#   Fixture B: rules.yaml empty file, query rule override `code-style`    -> empty stdout, exit 0
#   Fixture C: rules.yaml has only `security`, query
#       - `code-style` -> empty stdout, exit 0 (missing key default)
#       - `security`   -> "Custom security" stdout, exit 0 (present key)
#
# Scope ID: policy-yaml-fallback-to-plugin-default-when-key-missing
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"

if [ ! -x "$LOADER" ]; then
  echo "FAIL: loader missing or not executable: $LOADER" >&2
  exit 1
fi

# Each fixture is its own subdir under TMP_ROOT so the loader's relative
# .rein/policy/{hooks,rules}.yaml lookups stay isolated per case.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

ok() {
  echo "  ok: $1"
}

# run_loader: invoke loader from $1=workdir with the remaining argv. Writes
# stdout to <workdir>/stdout and stderr to <workdir>/stderr. Echoes the exit
# code on its own stdout (single line) so the caller captures it via $().
# bash 3.2 compatible — no mapfile, no process substitution required.
run_loader() {
  local workdir="$1"; shift
  set +e
  ( cd "$workdir" && python3 "$LOADER" "$@" </dev/null \
      >"$workdir/stdout" 2>"$workdir/stderr" )
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

# -----------------------------------------------------------------------------
# Fixture A: hooks.yaml has only `other-hook`, query `pre-bash-guard`.
# Default behavior is enabled (exit 0) per is_enabled(... default=True).
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
cat >"$A_DIR/.rein/policy/hooks.yaml" <<'YAML'
other-hook:
  enabled: false
YAML
A_RC="$(run_loader "$A_DIR" "pre-bash-guard")"
[ "$A_RC" = "0" ] || fail "Fixture A: expected exit 0 (default enabled), got $A_RC"
ok "Fixture A: hooks.yaml has only other-hook, queried pre-bash-guard -> exit 0"

# -----------------------------------------------------------------------------
# Fixture B: rules.yaml is empty (parses to None). Query rule override.
# Default behavior is None (empty stdout), exit 0.
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
: >"$B_DIR/.rein/policy/rules.yaml"
B_RC="$(run_loader "$B_DIR" "--rule-override" "code-style")"
[ "$B_RC" = "0" ] || fail "Fixture B: expected exit 0 (empty yaml -> None), got $B_RC"
if [ -s "$B_DIR/stdout" ]; then
  echo "  loader stdout captured:" >&2
  cat "$B_DIR/stdout" >&2
  fail "Fixture B: expected empty stdout (no override), got non-empty"
fi
# stderr: empty yaml is valid yaml (parses to None), so no warning expected.
if [ -s "$B_DIR/stderr" ]; then
  echo "  loader stderr captured:" >&2
  cat "$B_DIR/stderr" >&2
  fail "Fixture B: expected empty stderr, got non-empty"
fi
ok "Fixture B: empty rules.yaml -> empty stdout + exit 0"

# -----------------------------------------------------------------------------
# Fixture C: rules.yaml has only `security`. Two queries:
#   C1: code-style -> empty stdout, exit 0 (missing key default)
#   C2: security   -> "Custom security" stdout, exit 0 (present key returned)
# Both queries share the same .rein/policy/ to prove that one missing key
# does not poison the present key (and vice versa).
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein/policy"
cat >"$C_DIR/.rein/policy/rules.yaml" <<'YAML'
security:
  override: "Custom security"
YAML

# C1: missing key. Reuse run_loader (writes to $C_DIR/stdout|stderr).
C1_RC="$(run_loader "$C_DIR" "--rule-override" "code-style")"
[ "$C1_RC" = "0" ] || fail "Fixture C1: expected exit 0 (missing key), got $C1_RC"
if [ -s "$C_DIR/stdout" ]; then
  echo "  loader stdout captured:" >&2
  cat "$C_DIR/stdout" >&2
  fail "Fixture C1: expected empty stdout for missing key, got non-empty"
fi
ok "Fixture C1: rules.yaml has only security, queried code-style -> empty stdout"

# C2: present key — must NOT be regressed by the C1 query (loader is stateless,
# but we still cover it explicitly). Write to dedicated files so we don't
# clobber C1's outputs (in case of debugging).
C2_STDOUT="$C_DIR/c2.stdout"
C2_STDERR="$C_DIR/c2.stderr"
set +e
( cd "$C_DIR" && python3 "$LOADER" --rule-override security </dev/null \
    >"$C2_STDOUT" 2>"$C2_STDERR" )
C2_RC=$?
set -e
[ "$C2_RC" = "0" ] || fail "Fixture C2: expected exit 0 (present key), got $C2_RC"
C2_BODY="$(cat "$C2_STDOUT")"
[ "$C2_BODY" = "Custom security" ] || \
  fail "Fixture C2: expected stdout='Custom security', got='$C2_BODY'"
ok "Fixture C2: rules.yaml has only security, queried security -> 'Custom security'"

echo "test-policy-yaml-fallback: OK (4/4 assertions)"
