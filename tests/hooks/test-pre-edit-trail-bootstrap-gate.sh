#!/usr/bin/env bash
# Verify plugins/rein-core/hooks/pre-edit-trail-bootstrap-gate.sh:
#
#   A — trail/ absent (safe project_dir, helper exit 10)
#       → gate exit 2, stderr contains bilingual bootstrap guidance
#         (rein-bootstrap-project.py + surface instruction)
#   B — trail/ present (helper exit 0)
#       → gate exit 0, empty stdout + empty stderr (silent pass)
#   C — helper exit 11 (sensitive path: invoked from $HOME)
#       → gate exit 0 (best-effort pass-through, no block)
#   D — helper file missing (CLAUDE_PLUGIN_ROOT points to dir without
#       hooks/lib/bootstrap-check.sh)
#       → gate exit 0 (graceful degrade — install regression, not gate's job)
#   E — CLAUDE_PLUGIN_ROOT unset (gate invoked outside plugin runtime)
#       → gate exit 0 (graceful degrade)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/pre-edit-trail-bootstrap-gate.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0

SCRATCH_ROOT=$(mktemp -d "/tmp/test-pre-edit-gate-XXXXXX")
trap 'chmod -R u+w "$SCRATCH_ROOT" 2>/dev/null; rm -rf "$SCRATCH_ROOT"' EXIT

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}
record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1" >&2
}

# ---------------------------------------------------------------------------
# Fixture A — trail/ absent → gate blocks with exit 2 + bilingual guidance
# ---------------------------------------------------------------------------
fixture_a() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/A-XXXXXX")"
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/A.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/A.err")

  if [ "$rc" -ne 2 ]; then
    record_fail "A: expected exit 2 (BLOCK), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "A: stderr missing 'rein-bootstrap-project.py'"
    echo "  stderr: $err" >&2
    return
  fi
  if ! printf '%s' "$err" | grep -q "surface this message to the user immediately"; then
    record_fail "A: stderr missing surface instruction"
    echo "  stderr: $err" >&2
    return
  fi
  if ! printf '%s' "$err" | grep -q "Run:"; then
    record_fail "A: stderr missing 'Run:' line"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "A: expected empty stdout, got: $out"
    return
  fi
  record_pass "A (trail absent → exit 2 + bilingual guidance on stderr)"
}

# ---------------------------------------------------------------------------
# Fixture B — trail/ present → gate passes silently
# ---------------------------------------------------------------------------
fixture_b() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/B-XXXXXX")"
  mkdir "$dir/trail"
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/B.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/B.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "B: expected exit 0 (PASS), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "B: expected empty stdout, got: $out"
    return
  fi
  # Helper emits a one-line diagnostic on success path? Per helper source,
  # success path is silent (no stderr). Enforce that contract here.
  if [ -n "$err" ]; then
    record_fail "B: expected empty stderr, got: $err"
    return
  fi
  record_pass "B (trail present → silent exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture C — helper exit 11 (sensitive path) → gate passes (best-effort)
# ---------------------------------------------------------------------------
# Synthesize a "sensitive path" by passing $HOME as project_dir via PWD,
# using a fake HOME so we don't disturb the real one.
fixture_c() {
  local fake_home out err rc
  fake_home="$(mktemp -d "$SCRATCH_ROOT/C-home-XXXXXX")"
  out=$(
    cd "$fake_home" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       HOME="$fake_home" \
       GIT_CEILING_DIRECTORIES="$(dirname "$fake_home")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/C.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/C.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "C: expected exit 0 (best-effort pass on helper exit 11), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  # The helper writes a one-line stderr diagnostic + category keyword. The
  # gate must NOT suppress those (they're useful for debugging) but MUST NOT
  # block on them. We assert pass-through behavior: rc 0. stderr content
  # is the helper's, not the gate's — accept it as-is.
  record_pass "C (helper exit 11 sensitive-path → gate exit 0 pass-through)"
}

# ---------------------------------------------------------------------------
# Fixture D — helper file missing → gate exit 0 (graceful degrade)
# ---------------------------------------------------------------------------
fixture_d() {
  local empty_plugin out err rc
  empty_plugin="$(mktemp -d "$SCRATCH_ROOT/D-plugin-XXXXXX")"
  # Deliberately do NOT create hooks/lib/bootstrap-check.sh under empty_plugin.
  out=$(
    env CLAUDE_PLUGIN_ROOT="$empty_plugin" \
        bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/D.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/D.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "D: expected exit 0 (graceful degrade, helper missing), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "D: expected empty stdout, got: $out"
    return
  fi
  if [ -n "$err" ]; then
    record_fail "D: expected empty stderr (silent degrade), got: $err"
    return
  fi
  record_pass "D (helper missing → graceful exit 0, silent)"
}

# ---------------------------------------------------------------------------
# Fixture E — CLAUDE_PLUGIN_ROOT unset → gate exit 0 (graceful degrade)
# ---------------------------------------------------------------------------
fixture_e() {
  local out err rc
  out=$(
    env -u CLAUDE_PLUGIN_ROOT \
        bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/E.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/E.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "E: expected exit 0 (graceful degrade, CLAUDE_PLUGIN_ROOT unset), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "E: expected empty stdout, got: $out"
    return
  fi
  if [ -n "$err" ]; then
    record_fail "E: expected empty stderr (silent degrade), got: $err"
    return
  fi
  record_pass "E (CLAUDE_PLUGIN_ROOT unset → graceful exit 0, silent)"
}

# ---------------------------------------------------------------------------
# Fixture F — policy hooks.yaml disables via short-form `false` → exit 0
# ---------------------------------------------------------------------------
# Even though trail/ is missing (would normally trigger exit 2), the policy
# opt-out must short-circuit before bootstrap_check runs.
fixture_f() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/F-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
pre-edit-trail-bootstrap-gate: false
YAML
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/F.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/F.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "F: expected exit 0 (policy short-form false), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "F: expected empty stdout, got: $out"
    return
  fi
  record_pass "F (policy short-form 'false' → exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture G — policy hooks.yaml disables via map `{enabled: false}` → exit 0
# ---------------------------------------------------------------------------
fixture_g() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/G-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
pre-edit-trail-bootstrap-gate:
  enabled: false
YAML
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/G.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/G.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "G: expected exit 0 (policy map enabled:false), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "G: expected empty stdout, got: $out"
    return
  fi
  record_pass "G (policy map 'enabled: false' → exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture H — umbrella `bootstrap-gate: false` disables this hook → exit 0
# ---------------------------------------------------------------------------
fixture_h() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/H-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
YAML
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/H.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/H.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "H: expected exit 0 (umbrella bootstrap-gate:false), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "H: expected empty stdout, got: $out"
    return
  fi
  record_pass "H (umbrella 'bootstrap-gate: false' → exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture I — individual hook setting overrides umbrella
# ---------------------------------------------------------------------------
# umbrella `bootstrap-gate: false` would disable, BUT individual
# `pre-edit-trail-bootstrap-gate: true` re-enables. trail/ is absent so
# the gate must fire normally → exit 2.
fixture_i() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/I-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
pre-edit-trail-bootstrap-gate: true
YAML
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" </dev/null 2>"$SCRATCH_ROOT/I.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/I.err")

  if [ "$rc" -ne 2 ]; then
    record_fail "I: expected exit 2 (individual override re-enables), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "I: stderr missing 'rein-bootstrap-project.py'"
    echo "  stderr: $err" >&2
    return
  fi
  record_pass "I (individual true overrides umbrella false → exit 2)"
}

fixture_a
fixture_b
fixture_c
fixture_d
fixture_e
fixture_f
fixture_g
fixture_h
fixture_i

echo
echo "test-pre-edit-trail-bootstrap-gate: pass=$PASS_COUNT fail=$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
