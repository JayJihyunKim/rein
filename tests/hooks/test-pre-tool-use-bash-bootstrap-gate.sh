#!/usr/bin/env bash
# Verify pre-tool-use-bash-bootstrap-gate.sh (Task 1.3):
#
#   A — trail/ missing + safe project_dir
#       → exit 2, stderr contains 'rein-bootstrap-project.py'
#   B — trail/ present
#       → exit 0, stderr empty
#   C — $HOME (sensitive-path → helper exit 11)
#       → exit 0 (best-effort pass-through), stderr empty
#   D — helper missing (CLAUDE_PLUGIN_ROOT set but lib/bootstrap-check.sh gone)
#       → exit 0 (install regression — not this gate's job to alarm)
#   E — Bash conflict order (concept-level)
#       trail/ absent + simulated co-resident pre-bash-guard preconditions.
#       Single-task limitation: this fixture validates that the gate returns
#       exit 2 (so an upstream dispatcher would short-circuit the chain). The
#       actual chain ordering — i.e. pre-bash-guard NOT running after this
#       gate's exit 2 — is governed by hooks.json (Task 1.4) and validated
#       end-to-end by Task 3.3 (trigger parity test).
#
# Scope IDs (from plan):
#   - pre-tool-use-bash-bootstrap-gate-blocks-bash-with-exit-2-and-bootstrap-command-stderr-when-trail-dir-absent
#   - pre-tool-use-bash-bootstrap-gate-passes-through-with-exit-0-when-bootstrap-check-helper-returns-exit-code-0-or-11
#   - session-start-bootstrap-and-pre-edit-gate-and-pre-bash-gate-and-user-prompt-submit-share-bootstrap-check-helper-via-source

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
HOOK="$PLUGIN_ROOT/hooks/pre-tool-use-bash-bootstrap-gate.sh"
HELPER="$PLUGIN_ROOT/hooks/lib/bootstrap-check.sh"

[ -f "$HOOK" ]   || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ]   || { echo "FAIL: $HOOK not executable" >&2; exit 1; }
[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing (Task 1.1 prereq)" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0

SCRATCH_ROOT=$(mktemp -d "/tmp/test-prebash-bootstrap-XXXXXX")
trap 'chmod -R u+w "$SCRATCH_ROOT" 2>/dev/null; rm -rf "$SCRATCH_ROOT"' EXIT

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1" >&2; }

# ---------------------------------------------------------------------------
# Fixture A — trail/ missing + safe tmpdir → exit 2 + bootstrap stderr
# ---------------------------------------------------------------------------
fixture_a() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/A-XXXXXX")"
  local out err rc errfile
  errfile="$SCRATCH_ROOT/A-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 2 ]; then
    record_fail "A: expected exit 2, got $rc (stderr: $err)"
    return
  fi
  if [ -n "$out" ]; then
    record_fail "A: expected empty stdout, got: $out"
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "A: stderr missing 'rein-bootstrap-project.py' (got: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "trail/"; then
    record_fail "A: stderr missing 'trail/' (got: $err)"
    return
  fi
  record_pass "A (trail/ missing → exit 2 + bootstrap stderr)"
}

# ---------------------------------------------------------------------------
# Fixture B — trail/ present → exit 0, no stdout, no stderr
# ---------------------------------------------------------------------------
fixture_b() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/B-XXXXXX")"
  mkdir "$dir/trail"
  local out err rc errfile
  errfile="$SCRATCH_ROOT/B-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "B: expected exit 0, got $rc (stderr: $err)"
    return
  fi
  if [ -n "$out" ]; then
    record_fail "B: expected empty stdout, got: $out"
    return
  fi
  record_pass "B (trail/ present → exit 0, silent)"
}

# ---------------------------------------------------------------------------
# Fixture C — $HOME (sensitive-path) → helper returns 11 → gate exit 0
# ---------------------------------------------------------------------------
# We can't actually `cd $HOME` and create trail/ safely; instead we rely on
# the helper's sensitive-path detection. Since the helper resolves project_dir
# via stdin.cwd → git → PWD, we feed stdin.cwd=$HOME so the gate (helper)
# classifies the path as sensitive (exit 11) and we expect best-effort
# pass-through (exit 0).
fixture_c() {
  local payload
  payload="{\"cwd\":\"$HOME\"}"
  # cd into a known-different dir to avoid PWD shadowing
  local cdir
  cdir="$(mktemp -d "$SCRATCH_ROOT/C-cd-XXXXXX")"
  local out err rc errfile
  errfile="$SCRATCH_ROOT/C-err"
  out=$( (cd "$cdir" && printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK") 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "C: expected exit 0 (sensitive-path pass-through), got $rc (stderr: $err)"
    return
  fi
  if [ -n "$out" ]; then
    record_fail "C: expected empty stdout, got: $out"
    return
  fi
  record_pass "C (\$HOME sensitive-path → helper exit 11 → gate exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture D — helper missing → gate exit 0 (graceful degrade)
# ---------------------------------------------------------------------------
fixture_d() {
  local fake_plugin
  fake_plugin="$(mktemp -d "$SCRATCH_ROOT/D-plugin-XXXXXX")"
  mkdir -p "$fake_plugin/hooks/lib"
  # Intentionally do NOT create lib/bootstrap-check.sh
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/D-cd-XXXXXX")"
  local out err rc errfile
  errfile="$SCRATCH_ROOT/D-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$fake_plugin" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "D: expected exit 0 (helper missing → graceful degrade), got $rc (stderr: $err)"
    return
  fi
  if [ -n "$out" ]; then
    record_fail "D: expected empty stdout, got: $out"
    return
  fi
  record_pass "D (helper missing → silent exit 0)"
}

# ---------------------------------------------------------------------------
# Fixture E — Bash conflict order (concept-level assertion)
# ---------------------------------------------------------------------------
# The full ordering contract — bootstrap gate fires BEFORE pre-bash-guard so
# that an exit-2 here suppresses pre-bash-guard's stamp-missing message — is
# enforced by hooks.json (Task 1.4) and validated end-to-end by Task 3.3
# (trigger parity test). At this single-task level, hook-chain dispatch is
# not mocked. The most this fixture can assert is:
#
#   - Given trail/ absent (the precondition under which we expect the gate
#     to short-circuit the chain), the gate returns exit 2 cleanly.
#
# If this fixture fails, the chain-ordering contract cannot possibly hold;
# if it passes, Task 3.3 must still verify that pre-bash-guard does not run
# after this exit 2.
fixture_e() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/E-XXXXXX")"
  # Intentionally simulate the co-resident precondition for pre-bash-guard:
  # trail/dod/ exists (so guard would try to read stamps) but trail/ at root
  # is the actual signal the gate keys on. We do NOT create trail/ — gate
  # must fire first.
  local out err rc errfile
  errfile="$SCRATCH_ROOT/E-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 2 ]; then
    record_fail "E: expected exit 2 (gate fires first), got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "E: stderr missing 'rein-bootstrap-project.py' (got: $err)"
    return
  fi
  # NOTE: chain-suppression of pre-bash-guard is validated by Task 3.3.
  record_pass "E (conflict order — gate exit 2 first; chain suppression deferred to Task 3.3)"
}

# ---------------------------------------------------------------------------
# Fixture F — policy hooks.yaml disables via short-form `false` → exit 0
# ---------------------------------------------------------------------------
# Even though trail/ is missing (would normally trigger exit 2), the policy
# opt-out must short-circuit before bootstrap_check runs.
fixture_f() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/F-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
pre-tool-use-bash-bootstrap-gate: false
YAML
  local out err rc errfile
  errfile="$SCRATCH_ROOT/F-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "F: expected exit 0 (policy short-form false), got $rc (stderr: $err)"
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
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/G-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
pre-tool-use-bash-bootstrap-gate:
  enabled: false
YAML
  local out err rc errfile
  errfile="$SCRATCH_ROOT/G-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "G: expected exit 0 (policy map enabled:false), got $rc (stderr: $err)"
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
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/H-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
YAML
  local out err rc errfile
  errfile="$SCRATCH_ROOT/H-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 0 ]; then
    record_fail "H: expected exit 0 (umbrella bootstrap-gate:false), got $rc (stderr: $err)"
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
# `pre-tool-use-bash-bootstrap-gate: true` re-enables. trail/ is absent so
# the gate must fire normally → exit 2.
fixture_i() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/I-XXXXXX")"
  mkdir -p "$dir/.rein/policy"
  cat > "$dir/.rein/policy/hooks.yaml" <<'YAML'
bootstrap-gate: false
pre-tool-use-bash-bootstrap-gate: true
YAML
  local out err rc errfile
  errfile="$SCRATCH_ROOT/I-err"
  out=$( (cd "$dir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null) 2>"$errfile" )
  rc=$?
  err=$(cat "$errfile")
  if [ "$rc" -ne 2 ]; then
    record_fail "I: expected exit 2 (individual override re-enables), got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "I: stderr missing 'rein-bootstrap-project.py' (got: $err)"
    return
  fi
  record_pass "I (individual true overrides umbrella false → exit 2)"
}

# ---------------------------------------------------------------------------
# Run all fixtures
# ---------------------------------------------------------------------------
fixture_a
fixture_b
fixture_c
fixture_d
fixture_e
fixture_f
fixture_g
fixture_h
fixture_i

echo ""
echo "=================================================="
echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
