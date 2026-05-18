#!/usr/bin/env bash
# Verify the bootstrap-check helper:
#
#   A      — happy path, trail/ + .rein/project.json both present → exit 0, stdout empty
#   B      — happy path, both missing            → exit 10, bilingual guidance
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
#   H      — monorepo subdir walk-up to git root → exit 0
#   I      — nested git boundary (no marker)     → exit 10
#   J      — env hygiene (GIT_DIR/GIT_WORK_TREE) → exit 0
#   K      — partial: trail/ only                → exit 10 (PARTIAL guidance)
#   L      — partial: .rein/project.json only     → exit 10 (PARTIAL guidance)
#   M      — partial CRASH: marker+trail/ no index → exit 10 (PARTIAL guidance)
#   N      — fresh install (nothing)              → exit 10 (generic guidance)
#   O      — atomic marker-last write produces exit 0 + no .tmp leftover
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

# BG-1 (2026-05-14): "bootstrapped" requires BOTH trail/ AND .rein/project.json.
# Partial-bootstrap fix (v1.3.0+1): also requires trail/index.md (the trail-step
# completion sentinel). Tests that exercise the happy path must materialise all
# three — using a helper keeps the predicate change localised so future contract
# bumps update one site.
mk_bootstrap_marker() {
  local d="$1"
  mkdir -p "$d/trail" "$d/.rein"
  printf '{}' > "$d/.rein/project.json"
  printf '# trail/index.md\n' > "$d/trail/index.md"
}

# Helper to clear inherited env that the resolution logic must NOT see.
# Tests set their own env explicitly per-case.
run_clean() {
  # Args: invocation lines (use a subshell). Caller controls env.
  :
}

# ---------------------------------------------------------------------------
# Fixture A — happy: trail/ + .rein/project.json both present → exit 0, stdout empty
# ---------------------------------------------------------------------------
fixture_a() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/A-XXXXXX")"
  mk_bootstrap_marker "$dir"
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
# Fixture B — happy: trail/ and marker both missing → exit 10 + bilingual guidance
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
  if ! printf '%s' "$out" | grep -q "trail/"; then
    record_fail "B: stdout missing 'trail/' substring (BG-1 guidance phrasing)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "\.rein/project\.json"; then
    record_fail "B: stdout missing '.rein/project.json' substring (BG-1 marker phrasing)"
    return
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
  mk_bootstrap_marker "$good"
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
  (cd "$dir" && git init -q)
  mk_bootstrap_marker "$dir"
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
  mk_bootstrap_marker "$dir"
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
  mk_bootstrap_marker "$dir"
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
# Fixture H — monorepo subdir walkup: trail/ at git root, stdin.cwd = subdir.
# Regression for 2026-05-12 hotfix (bootstrap-check.sh stdin.cwd → git-root
# walkup). Before the fix, stdin.cwd was selected verbatim → trail/ lookup
# at subdir → exit 10. After the fix, `git -C $stdin_cwd rev-parse` walks up
# to the git root → trail/ found → exit 0. Exit code alone is the assertion
# (helper is silent on exit 0, so source= label can only be observed on exit
# 10 path; fixture J below covers the exit-10 source label).
# ---------------------------------------------------------------------------
fixture_h() {
  if ! command -v git >/dev/null 2>&1; then
    record_skip "H (monorepo subdir walkup) — git not installed"
    return
  fi
  local root
  root="$(mktemp -d "$SCRATCH_ROOT/H-root-XXXXXX")"
  (cd "$root" && git init -q && mkdir -p apps/web)
  mk_bootstrap_marker "$root"
  local sub="$root/apps/web"
  # Confirm preconditions: subdir has no trail/, root has trail/ + marker.
  [ ! -d "$sub/trail" ] || { record_fail "H: precondition - subdir trail/ should not exist"; return; }
  [ -d "$root/trail" ] || { record_fail "H: precondition - root trail/ should exist"; return; }
  [ -f "$root/.rein/project.json" ] || { record_fail "H: precondition - root marker should exist"; return; }
  local out err rc
  local other
  other="$(mktemp -d "$SCRATCH_ROOT/H-other-XXXXXX")"
  out=$( (cd "$other" && printf '{"cwd":"%s"}' "$sub" | env -u CLAUDE_PLUGIN_ROOT bash "$HELPER") 2>"$SCRATCH_ROOT/bc-err-H" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-H")
  if [ "$rc" -ne 0 ]; then
    record_fail "H: expected exit 0 (git walk-up subdir → root → trail/ found), got $rc (stderr: $err)"
    return
  fi
  record_pass "H (monorepo subdir → git-root walkup)"
}

# ---------------------------------------------------------------------------
# Fixture I — nested git boundary: subdir has its own .git/. Walk-up must
# STOP at the nested boundary (not escape to outer root). With trail/ ONLY
# at the outer root and missing at the subdir, expected: exit 10 (walk-up
# returns subdir, no trail/ there). If walk-up incorrectly escaped to the
# outer root, exit would be 0 (false positive). Guidance text on stderr
# must reference the subdir as the resolved project_dir.
# ---------------------------------------------------------------------------
fixture_i() {
  if ! command -v git >/dev/null 2>&1; then
    record_skip "I (nested git boundary) — git not installed"
    return
  fi
  local root
  root="$(mktemp -d "$SCRATCH_ROOT/I-root-XXXXXX")"
  (cd "$root" && git init -q)
  mk_bootstrap_marker "$root"
  local sub="$root/sub-project"
  mkdir -p "$sub"
  (cd "$sub" && git init -q)
  # Subdir has NO trail/ on purpose. If walk-up respects nested boundary,
  # it returns $sub → trail/ at $sub missing → exit 10.
  local out err rc
  local other
  other="$(mktemp -d "$SCRATCH_ROOT/I-other-XXXXXX")"
  out=$( (cd "$other" && printf '{"cwd":"%s"}' "$sub" | env -u CLAUDE_PLUGIN_ROOT bash "$HELPER") 2>"$SCRATCH_ROOT/bc-err-I" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-I")
  if [ "$rc" -ne 10 ]; then
    record_fail "I: expected exit 10 (nested git boundary stops walk-up at subdir, no trail/), got $rc (stderr: $err)"
    return
  fi
  # Resolved project_dir on exit-10 diagnostic should be $sub (nested root),
  # not the outer $root. This proves walk-up stopped at the nested boundary.
  local sub_real
  sub_real="$(cd "$sub" && pwd -P)"
  if ! echo "$err" | grep -qF "project_dir=$sub_real"; then
    record_fail "I: expected project_dir=$sub_real on exit-10 diagnostic, got: $err"
    return
  fi
  # Walk-up branch should be reported via source=git-from-stdin.
  if ! echo "$err" | grep -q "source=git-from-stdin"; then
    record_fail "I: expected source=git-from-stdin in stderr, got: $err"
    return
  fi
  record_pass "I (nested git boundary respected)"
}

# ---------------------------------------------------------------------------
# Fixture J — env hygiene: polluted GIT_DIR / GIT_WORK_TREE must NOT redirect
# walk-up. Caller env is "dirty" (env vars point to an unrelated git repo),
# but the helper's git invocation is sanitized with `env -u GIT_DIR
# -u GIT_WORK_TREE ...`. Without sanitization, walk-up would resolve to the
# polluted target, finding (or missing) trail/ at the wrong place.
# ---------------------------------------------------------------------------
fixture_j() {
  if ! command -v git >/dev/null 2>&1; then
    record_skip "J (env hygiene GIT_DIR/GIT_WORK_TREE) — git not installed"
    return
  fi
  # Target monorepo: trail/+marker at root, no trail/ at subdir (same as H).
  local root
  root="$(mktemp -d "$SCRATCH_ROOT/J-root-XXXXXX")"
  (cd "$root" && git init -q && mkdir -p apps/web)
  mk_bootstrap_marker "$root"
  local sub="$root/apps/web"
  # Decoy: a separate git repo that does NOT have trail/. If env sanitation
  # fails, git -C would honor GIT_DIR pointing here, find no trail/ → exit 10
  # (false negative on the H-equivalent path).
  local decoy
  decoy="$(mktemp -d "$SCRATCH_ROOT/J-decoy-XXXXXX")"
  (cd "$decoy" && git init -q)
  local out err rc
  local other
  other="$(mktemp -d "$SCRATCH_ROOT/J-other-XXXXXX")"
  # Export polluted GIT_DIR / GIT_WORK_TREE pointing at the decoy. With
  # sanitation, the helper's `git -C "$sub" rev-parse` ignores them and walks
  # up to $root → trail/ found → exit 0.
  out=$( (cd "$other" \
    && GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" \
       printf '{"cwd":"%s"}' "$sub" \
    | env -u CLAUDE_PLUGIN_ROOT \
        GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" \
        bash "$HELPER") 2>"$SCRATCH_ROOT/bc-err-J" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-J")
  if [ "$rc" -ne 0 ]; then
    record_fail "J: expected exit 0 (env sanitation isolates walk-up from polluted GIT_DIR), got $rc (stderr: $err)"
    return
  fi
  record_pass "J (env hygiene: GIT_DIR/GIT_WORK_TREE ignored during walk-up)"
}

# ---------------------------------------------------------------------------
# Fixture K — partial-bootstrap: trail/ alone is not "bootstrapped".
# Regression for 2026-05-14 BG-1 spec — overlay residue or unrelated processes
# can drop a trail/ into a project. Pre-BG-1 the helper exited 0 here, silently
# turning gate hooks into no-ops on a half-bootstrapped repo. Post-BG-1 the
# marker (.rein/project.json) is required → exit 10. With the partial-bootstrap
# fix (v1.3.0+1) this is the PARTIAL branch (one component present, two
# missing): guidance must say "PARTIAL state" and name the missing marker.
# ---------------------------------------------------------------------------
fixture_k() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/K-XXXXXX")"
  mkdir "$dir/trail"
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>"$SCRATCH_ROOT/bc-err-K" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-K")
  if [ "$rc" -ne 10 ]; then
    record_fail "K: expected exit 10 (trail/ alone insufficient), got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "\.rein/project\.json"; then
    record_fail "K: guidance must name '.rein/project.json' marker when trail/ alone present (got: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "PARTIAL state"; then
    record_fail "K: trail/ alone is partial state — guidance must say 'PARTIAL state' (got: $out)"
    return
  fi
  record_pass "K (partial: trail/ alone insufficient)"
}

# ---------------------------------------------------------------------------
# Fixture L — partial-bootstrap symmetric: .rein/project.json alone is not
# "bootstrapped". A residual marker without an accompanying trail/ (e.g. user
# deleted trail/ manually) must also fail closed → exit 10 PARTIAL branch with
# guidance that names trail/.
# ---------------------------------------------------------------------------
fixture_l() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/L-XXXXXX")"
  mkdir -p "$dir/.rein"
  printf '{}' > "$dir/.rein/project.json"
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>"$SCRATCH_ROOT/bc-err-L" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-L")
  if [ "$rc" -ne 10 ]; then
    record_fail "L: expected exit 10 (marker alone insufficient), got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "trail/"; then
    record_fail "L: guidance must name 'trail/' when marker alone present (got: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "PARTIAL state"; then
    record_fail "L: marker alone is partial state — guidance must say 'PARTIAL state' (got: $out)"
    return
  fi
  record_pass "L (partial: marker alone insufficient)"
}

# ---------------------------------------------------------------------------
# Fixture M — partial-bootstrap CRASH SCENARIO: marker + trail/ present but
# trail/index.md MISSING. This is the exact failure mode the v1.3.0+1 fix
# targets (codex round 1 missed defect #3): rein-bootstrap-project.py crashed
# (SIGINT / disk full / kill) AFTER mkdir created trail/ + .rein/ but BEFORE
# write_text_if_missing wrote trail/index.md. Pre-fix the BG-1 two-marker
# check (trail dir + marker) reported exit 0 here → FALSE PASS, and downstream
# session-start-load-trail.sh would crash reading the absent index. Post-fix:
# trail/index.md is a required third marker → exit 10 PARTIAL branch.
# Asserts: (1) exit 10, (2) "PARTIAL state" phrasing, (3) missing list names
# trail/index.md, (4) present list names trail/ and the marker, (5) the
# re-run command is flagged idempotent/safe.
# ---------------------------------------------------------------------------
fixture_m() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/M-XXXXXX")"
  mkdir -p "$dir/trail" "$dir/.rein"
  printf '{}' > "$dir/.rein/project.json"
  # Deliberately DO NOT create trail/index.md — simulates the mid-bootstrap
  # crash after the marker was (pre-fix) written but before index.md.
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>"$SCRATCH_ROOT/bc-err-M" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-M")
  if [ "$rc" -ne 10 ]; then
    record_fail "M: expected exit 10 (marker+trail/ but no index.md = partial), got $rc (stderr: $err)"
    return
  fi
  if ! printf '%s' "$out" | grep -q "PARTIAL state"; then
    record_fail "M: guidance must say 'PARTIAL state' for crash-mid-bootstrap (got: $out)"
    return
  fi
  # Missing list must name trail/index.md.
  if ! printf '%s' "$out" | grep -qE 'Missing:.*trail/index\.md'; then
    record_fail "M: Missing line must name 'trail/index.md' (got: $out)"
    return
  fi
  # Present list must name trail/ and .rein/project.json.
  if ! printf '%s' "$out" | grep -qE 'Present:.*trail/'; then
    record_fail "M: Present line must name 'trail/' (got: $out)"
    return
  fi
  if ! printf '%s' "$out" | grep -qE 'Present:.*\.rein/project\.json'; then
    record_fail "M: Present line must name '.rein/project.json' (got: $out)"
    return
  fi
  # Re-run command must be flagged safe/idempotent.
  if ! printf '%s' "$out" | grep -qi "idempotent"; then
    record_fail "M: partial guidance must flag the re-run as idempotent/safe (got: $out)"
    return
  fi
  # stderr diagnostic should still carry project_dir + guidance_size.
  if ! printf '%s' "$err" | grep -q "project_dir="; then
    record_fail "M: stderr must carry project_dir diagnostic (got: $err)"
    return
  fi
  record_pass "M (partial crash: marker+trail/ but no index.md)"
}

# ---------------------------------------------------------------------------
# Fixture N — fresh install still produces the GENERIC (non-partial) message.
# Guards against the partial-state branch over-firing: when NOTHING exists
# (truly fresh install / plugin enabled but never bootstrapped), the guidance
# must remain the original "bootstrap not initialized" template and must NOT
# claim a PARTIAL state. This is the negative control for fixtures K/L/M.
# ---------------------------------------------------------------------------
fixture_n() {
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/N-XXXXXX")"
  # No trail/, no .rein/, no index — truly fresh.
  local out err rc
  out=$( (cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir") 2>"$SCRATCH_ROOT/bc-err-N" )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/bc-err-N")
  if [ "$rc" -ne 10 ]; then
    record_fail "N: expected exit 10 (fresh install), got $rc (stderr: $err)"
    return
  fi
  if printf '%s' "$out" | grep -q "PARTIAL state"; then
    record_fail "N: fresh install must NOT claim 'PARTIAL state' (over-firing) — got: $out"
    return
  fi
  if ! printf '%s' "$out" | grep -q "bootstrap not initialized"; then
    record_fail "N: fresh install must use the generic 'bootstrap not initialized' template (got: $out)"
    return
  fi
  record_pass "N (fresh install uses generic, non-partial guidance)"
}

# ---------------------------------------------------------------------------
# Fixture O — atomic marker-last write: verify rein-bootstrap-project.py writes
# .rein/project.json AFTER trail/index.md, so a successful run is observed by
# the helper as fully bootstrapped (exit 0), and an interrupted run can never
# leave the marker without the index. We assert ordering directly: after a
# real bootstrap run, the marker's mtime must be >= trail/index.md's mtime.
# This is the producer-side half of the fix (the helper change is the
# consumer-side half exercised by K/L/M/N).
# ---------------------------------------------------------------------------
fixture_o() {
  local boot_py
  boot_py="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"
  if [ ! -f "$boot_py" ]; then
    record_skip "O (atomic marker-last) — bootstrap script missing at $boot_py"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    record_skip "O (atomic marker-last) — python3 not installed"
    return
  fi
  local dir
  dir="$(mktemp -d "$SCRATCH_ROOT/O-XXXXXX")"
  # Run the real bootstrap. Non-git dir → script uses project_dir in-place.
  if ! python3 "$boot_py" --project-dir "$dir" >/dev/null 2>"$SCRATCH_ROOT/bc-err-O"; then
    record_fail "O: bootstrap run failed (stderr: $(cat "$SCRATCH_ROOT/bc-err-O"))"
    return
  fi
  local marker="$dir/.rein/project.json"
  local index="$dir/trail/index.md"
  if [ ! -f "$marker" ]; then
    record_fail "O: bootstrap did not create .rein/project.json"
    return
  fi
  if [ ! -f "$index" ]; then
    record_fail "O: bootstrap did not create trail/index.md"
    return
  fi
  # No leftover temp file from the atomic write.
  if [ -e "$dir/.rein/project.json.tmp" ]; then
    record_fail "O: atomic write left behind .rein/project.json.tmp"
    return
  fi
  # Ordering: marker mtime must be >= index mtime (marker written last).
  # Use python3 for portable mtime comparison (stat flags differ GNU/BSD).
  if ! python3 -c '
import os, sys
marker, index = sys.argv[1], sys.argv[2]
sys.exit(0 if os.path.getmtime(marker) >= os.path.getmtime(index) else 1)
' "$marker" "$index"; then
    record_fail "O: .rein/project.json mtime must be >= trail/index.md mtime (marker must be written last)"
    return
  fi
  # The freshly-bootstrapped dir must now read as fully bootstrapped (exit 0).
  local rc
  ( cd "$dir" && env -u CLAUDE_PLUGIN_ROOT bash "$HELPER" "$dir" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    record_fail "O: helper must report exit 0 after a real bootstrap, got $rc"
    return
  fi
  record_pass "O (atomic marker-last write + post-bootstrap exit 0)"
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
fixture_h
fixture_i
fixture_j
fixture_k
fixture_l
fixture_m
fixture_n
fixture_o

echo
echo "test-bootstrap-check-helper: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
