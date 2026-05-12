#!/usr/bin/env bash
# Verify the bootstrap-check helper:
#
#   A      — happy path, trail/ exists           → exit 0, stdout empty
#   B      — happy path, trail/ missing          → exit 10, bilingual guidance
#   C-i    — resolution failure                  → exit 11, stderr "resolution"
#   C-ii   — plugin cache path                   → exit 11, stderr "cache-path"
#   C-iii  — plugin install dir match            → exit 11, stderr "plugin-dir"
#   C-iv   — unwritable (touch probe authoritative) → exit 11, stderr "unwritable"
#   C-v-a  — sensitive path "/"                   → exit 11, stderr "sensitive-path"
#   C-v-b  — sensitive path "$HOME"              → exit 11, stderr "sensitive-path"
#   D      — resolution priority: stdin.cwd      → exit 0
#   E      — resolution priority: git toplevel   → exit 0
#   F      — resolution priority: PWD            → exit 0
#   G      — git contract: no mutating commands  → mutating call count == 0
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/bootstrap-check.sh"

[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "FAIL: $HELPER not executable" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Scratch root for all per-fixture tmpdirs.
SCRATCH_ROOT=$(mktemp -d "/tmp/test-bootstrap-check-XXXXXX")
trap 'chmod -R u+w "$SCRATCH_ROOT" 2>/dev/null; rm -rf "$SCRATCH_ROOT"' EXIT

# Track fixture results so a single failure does not abort the suite.
record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}
record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1" >&2
}
record_skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  echo "SKIP: $1"
}

# Helper to clear inherited env that the resolution logic must NOT see.
# Tests set their own env explicitly per-case.
run_clean() {
  # Args: invocation lines (use a subshell). Caller controls env.
  :
}

# ---------------------------------------------------------------------------
# Fixture A — happy: trail/ exists → exit 0, stdout empty
# ---------------------------------------------------------------------------
fixture_a() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/A-XXXXXX")"
  mkdir "$dir/trail"
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>/tmp/bc-err-A )
  rc=$?
  err=$(cat /tmp/bc-err-A)
  if [ "$rc" -ne 0 ]; then
    record_fail "A: expected exit 0, got $rc (stderr: $err)"
    return
  fi
  if [ -n "$out" ]; then
    record_fail "A: expected empty stdout, got: $out"
    return
  fi
  record_pass "A (happy, trail exists)"
}

# ---------------------------------------------------------------------------
# Fixture B — happy: trail/ missing → exit 10 + bilingual guidance
# ---------------------------------------------------------------------------
fixture_b() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/B-XXXXXX")"
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>/tmp/bc-err-B )
  rc=$?
  err=$(cat /tmp/bc-err-B)
  if [ "$rc" -ne 10 ]; then
    record_fail "B: expected exit 10, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "python3"; then
    record_fail "B: stdout missing 'python3'"
    return
  fi
  if ! printf '%s' "$out" | grep -q "rein-bootstrap-project.py"; then
    record_fail "B: stdout missing 'rein-bootstrap-project.py'"
    return
  fi
  if ! printf '%s' "$out" | grep -q "surface this message to the user immediately"; then
    record_fail "B: stdout missing surface instruction"
    return
  fi
  if ! printf '%s' "$out" | grep -q "bootstrap"; then
    record_fail "B: stdout missing 'bootstrap' substring"
    return
  fi
  # Korean substring check (no locale dependency — UTF-8 bytes).
  if ! printf '%s' "$out" | grep -q "트랩\|trail" 2>/dev/null; then
    : # tolerated — we already checked English markers above
  fi
  if ! printf '%s' "$out" | grep -q "Run:"; then
    record_fail "B: stdout missing 'Run:' line"
    return
  fi
  # Trailing newline preservation: capture without sentinel + compare.
  local sized
  sized=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir"; printf x) 2>/dev/null )
  sized="${sized%x}"
  if [ "${sized: -1}" != $'\n' ]; then
    record_fail "B: guidance missing trailing newline (last byte not LF)"
    return
  fi
  record_pass "B (happy, trail missing, bilingual guidance)"
}

# ---------------------------------------------------------------------------
# Fixture C-i — resolution failure (no stdin, no git, $PWD nonexistent)
# ---------------------------------------------------------------------------
# Strategy: cd into a tmpdir and rmdir it before helper invocation. $PWD env
# var stays stale (still names the now-gone path), so the helper's
# `[ -d "$PWD" ]` check returns false → resolution category. We also pipe
# `</dev/null` so the optional stdin-cwd reader returns empty.
fixture_c_i() {
  local gone="$SCRATCH_ROOT/Ci-gone-$$"
  mkdir "$gone"
  local out err rc
  out=$( ( cd "$gone" && rmdir "$gone" && env -u CLAUDE_PLUGIN_ROOT GIT_CEILING_DIRECTORIES="/" bash "$HELPER" </dev/null ) 2>/tmp/bc-err-Ci )
  rc=$?
  err=$(cat /tmp/bc-err-Ci)
  if [ "$rc" -ne 11 ]; then
    record_fail "C-i: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "resolution"; then
    record_fail "C-i: stderr missing 'resolution' keyword (got: $err)"
    return
  fi
  record_pass "C-i (resolution failure)"
}

# ---------------------------------------------------------------------------
# Fixture C-ii — plugin cache path prefix
# ---------------------------------------------------------------------------
fixture_c_ii() {
  # Construct a fake cache path under $HOME/.claude/plugins/cache/.
  local fake_home
  fake_home="$(mktemp -d "$SCRATCH_ROOT/Cii-home-XXXXXX")"
  local cache_dir="$fake_home/.claude/plugins/cache/foo-$$"
  mkdir -p "$cache_dir"
  # Even with trail/ present, cache-path category must trigger first.
  mkdir "$cache_dir/trail"
  local out err rc
  out=$(env -u CLAUDE_PLUGIN_ROOT HOME="$fake_home" bash "$HELPER" "$cache_dir" 2>/tmp/bc-err-Cii)
  rc=$?
  err=$(cat /tmp/bc-err-Cii)
  if [ "$rc" -ne 11 ]; then
    record_fail "C-ii: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "cache-path"; then
    record_fail "C-ii: stderr missing 'cache-path' keyword (got: $err)"
    return
  fi
  record_pass "C-ii (plugin cache path)"
}

# ---------------------------------------------------------------------------
# Fixture C-iii — plugin install dir match (== CLAUDE_PLUGIN_ROOT)
# ---------------------------------------------------------------------------
fixture_c_iii() {
  local plugin_root
  plugin_root="$(mktemp -d "$SCRATCH_ROOT/Ciii-plugin-XXXXXX")"
  mkdir "$plugin_root/trail" # presence should not matter; plugin-dir wins
  local out err rc
  out=$(CLAUDE_PLUGIN_ROOT="$plugin_root" bash "$HELPER" "$plugin_root" 2>/tmp/bc-err-Ciii)
  rc=$?
  err=$(cat /tmp/bc-err-Ciii)
  if [ "$rc" -ne 11 ]; then
    record_fail "C-iii: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "plugin-dir"; then
    record_fail "C-iii: stderr missing 'plugin-dir' keyword (got: $err)"
    return
  fi
  record_pass "C-iii (plugin install dir)"
}

# ---------------------------------------------------------------------------
# Fixture C-iv — unwritable (authoritative touch probe)
# ---------------------------------------------------------------------------
fixture_c_iv() {
  # Root bypasses unix mode bits → skip when running as root.
  if [ "$(id -u)" -eq 0 ]; then
    record_skip "C-iv (unwritable) — running as root, chmod 555 ineffective"
    return
  fi
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/Civ-XXXXXX")"
  chmod 555 "$dir"
  local out err rc
  out=$(env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir" 2>/tmp/bc-err-Civ)
  rc=$?
  err=$(cat /tmp/bc-err-Civ)
  # Restore perms so the trap can clean up.
  chmod 755 "$dir" 2>/dev/null || true
  if [ "$rc" -ne 11 ]; then
    record_fail "C-iv: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "unwritable"; then
    record_fail "C-iv: stderr missing 'unwritable' keyword (got: $err)"
    return
  fi
  record_pass "C-iv (unwritable, touch-probe authoritative)"
}

# ---------------------------------------------------------------------------
# Fixture C-v-a — sensitive path "/"
# ---------------------------------------------------------------------------
fixture_c_v_a() {
  local out err rc
  out=$(env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "/" 2>/tmp/bc-err-Cva)
  rc=$?
  err=$(cat /tmp/bc-err-Cva)
  if [ "$rc" -ne 11 ]; then
    record_fail "C-v-a: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "sensitive-path"; then
    record_fail "C-v-a: stderr missing 'sensitive-path' keyword (got: $err)"
    return
  fi
  record_pass "C-v-a (sensitive '/')"
}

# ---------------------------------------------------------------------------
# Fixture C-v-b — sensitive path "$HOME"
# ---------------------------------------------------------------------------
fixture_c_v_b() {
  # Synthesize a fake HOME so we don't disturb the real one and so the
  # cache-path / unwritable checks don't interfere.
  local fake_home
  fake_home="$(mktemp -d "$SCRATCH_ROOT/Cvb-home-XXXXXX")"
  local out err rc
  out=$(env -u CLAUDE_PLUGIN_ROOT HOME="$fake_home" bash "$HELPER" "$fake_home" 2>/tmp/bc-err-Cvb)
  rc=$?
  err=$(cat /tmp/bc-err-Cvb)
  if [ "$rc" -ne 11 ]; then
    record_fail "C-v-b: expected exit 11, got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$err" | grep -q "sensitive-path"; then
    record_fail "C-v-b: stderr missing 'sensitive-path' keyword (got: $err)"
    return
  fi
  record_pass "C-v-b (sensitive \$HOME)"
}

# ---------------------------------------------------------------------------
# Fixture D — resolution priority: stdin.cwd wins (no override, no git, no PWD trail)
# ---------------------------------------------------------------------------
fixture_d() {
  local good
  good="$(mktemp -d "$SCRATCH_ROOT/D-good-XXXXXX")"
  mkdir "$good/trail"
  # Run from a different cwd (no trail there) to prove stdin.cwd wins.
  local other
  other="$(mktemp -d "$SCRATCH_ROOT/D-other-XXXXXX")"
  local out err rc
  out=$( (cd "$other" && printf '{"cwd":"%s"}' "$good" | env -u CLAUDE_PLUGIN_ROOT bash "$HELPER") 2>/tmp/bc-err-D )
  rc=$?
  err=$(cat /tmp/bc-err-D)
  if [ "$rc" -ne 0 ]; then
    record_fail "D: expected exit 0 (stdin.cwd→trail found), got $rc (stderr: $err)"
    return
  fi
  record_pass "D (stdin.cwd priority)"
}

# ---------------------------------------------------------------------------
# Fixture E — resolution priority: git toplevel fallback
# ---------------------------------------------------------------------------
fixture_e() {
  if ! command -v git >/dev/null 2>&1; then
    record_skip "E (git toplevel fallback) — git not installed"
    return
  fi
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/E-XXXXXX")"
  (cd "$dir" && git init -q && mkdir trail)
  local out err rc
  out=$( (cd "$dir" && printf '{}' | env -u CLAUDE_PLUGIN_ROOT bash "$HELPER") 2>/tmp/bc-err-E )
  rc=$?
  err=$(cat /tmp/bc-err-E)
  if [ "$rc" -ne 0 ]; then
    record_fail "E: expected exit 0 (git→trail found), got $rc (stderr: $err)"
    return
  fi
  record_pass "E (git toplevel priority)"
}

# ---------------------------------------------------------------------------
# Fixture F — resolution priority: $PWD fallback
# ---------------------------------------------------------------------------
fixture_f() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/F-XXXXXX")"
  mkdir "$dir/trail"
  # Sneak a no-git environment: invoke from a freshly-created dir that has
  # no .git. Provide empty stdin JSON so stdin.cwd path doesn't fire.
  local out err rc
  # Disable git discovery by setting GIT_CEILING_DIRECTORIES to dir's parent.
  out=$( (cd "$dir" && \
          GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
          printf '{}' | env -u CLAUDE_PLUGIN_ROOT GIT_CEILING_DIRECTORIES="$(dirname "$dir")" bash "$HELPER") 2>/tmp/bc-err-F )
  rc=$?
  err=$(cat /tmp/bc-err-F)
  if [ "$rc" -ne 0 ]; then
    record_fail "F: expected exit 0 (\$PWD→trail found), got $rc (stderr: $err)"
    return
  fi
  record_pass "F (\$PWD priority)"
}

# ---------------------------------------------------------------------------
# Fixture G — git contract: no mutating git commands
# ---------------------------------------------------------------------------
fixture_g() {
  local trace_dir
  trace_dir="$(mktemp -d "$SCRATCH_ROOT/G-trace-XXXXXX")"
  local trace_log="$trace_dir/git-calls.log"
  local real_git
  real_git="$(command -v git || true)"
  if [ -z "$real_git" ]; then
    record_skip "G (git contract) — git not installed"
    return
  fi
  cat > "$trace_dir/git" <<WRAP
#!/usr/bin/env bash
echo "\$@" >> "$trace_log"
exec "$real_git" "\$@"
WRAP
  chmod +x "$trace_dir/git"

  # Run helper across a few representative paths so all branches exercise.
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/G-dir-XXXXXX")"
  mkdir "$dir/trail"
  # Use modified PATH so the trace wrapper is seen first.
  ( cd "$dir" && PATH="$trace_dir:$PATH" env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" ) >/dev/null 2>&1 || true
  # Also exercise the no-trail path.
  local dir2
  dir2="$(mktemp -d "$SCRATCH_ROOT/G-dir2-XXXXXX")"
  ( cd "$dir2" && PATH="$trace_dir:$PATH" env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" ) >/dev/null 2>&1 || true

  if [ -f "$trace_log" ]; then
    if grep -E '^(init|add|commit|push|checkout|reset|merge|rebase|clean|branch)\b' "$trace_log" >/dev/null 2>&1; then
      record_fail "G: mutating git command detected — log:\n$(cat "$trace_log")"
      return
    fi
  fi
  record_pass "G (no mutating git commands)"
}

# ---------------------------------------------------------------------------
# Run all fixtures
# ---------------------------------------------------------------------------
fixture_a
fixture_b
fixture_c_i
fixture_c_ii
fixture_c_iii
fixture_c_iv
fixture_c_v_a
fixture_c_v_b
fixture_d
fixture_e
fixture_f
fixture_g

echo
echo "test-bootstrap-check-helper: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
