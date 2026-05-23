#!/usr/bin/env bash
# Verify plugins/rein-core/hooks/pre-edit-trail-bootstrap-gate.sh:
#
#   A — trail/ absent (safe project_dir, helper exit 10)
#       → gate exit 2, stderr contains bilingual bootstrap guidance
#         (rein-bootstrap-project.py + surface instruction)
#   B — bootstrap complete: trail/ + .rein/project.json + index (helper exit 0)
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
# Fixture A — trail/ absent + in-scope edit → exit 2 + bilingual guidance
# ---------------------------------------------------------------------------
# BG-C contract (2026-05-14): the gate is path-scoped to trail/ targets only.
# Edits outside trail/ are out-of-scope and pass through. To exercise the
# block path, the envelope must declare a trail/ target via
# tool_input.file_path. Without file_path the case glob falls through to the
# `*) exit 0` arm and the test would silently pass-through.
fixture_a() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/A-XXXXXX")"
  local payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/A.err"
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
# Fixture B — bootstrap complete (trail/ + .rein/project.json + index) → gate
# passes silently. Partial-bootstrap fix (v1.3.0+1): bootstrap_check requires
# all three markers, so seed all three for the rc=0 (bootstrapped) path.
# ---------------------------------------------------------------------------
fixture_b() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/B-XXXXXX")"
  mkdir "$dir/trail" "$dir/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' > "$dir/.rein/project.json"
  printf '# trail/index.md\n' > "$dir/trail/index.md"
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
  # BG-C contract: in-scope trail/ file_path required to exercise block path.
  local payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/I.err"
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

# ===========================================================================
# BG-I fixtures (v1.3.0 deadlock fix) — path-scoped + degraded pass-through
# ===========================================================================
# These augment the original A-I contract (which covers helper/policy
# branches) with explicit assertions for the BG-C changes:
#
#   J — bootstrap incomplete + file_path = "scripts/foo.py" (out of trail/)
#       → exit 0 (path-scoped: only trail/ edits block)
#   K — bootstrap incomplete + file_path = "trail/inbox/foo.md"
#       → exit 2 (in-scope path, block preserved)
#   L — bootstrap incomplete + degraded marker + any file_path
#       → exit 0 (degraded pass-through trumps path scope)
#
# These mirror the §Design details / BG-C contract in
# /Users/jihyunkim/.claude/plans/b-prancy-valiant.md.

# ---------------------------------------------------------------------------
# Fixture J — out-of-scope file_path → exit 0 (path-scoped, deadlock escape)
# ---------------------------------------------------------------------------
# Yesterday's deadlock: this hook was blocking ALL Edit/Write/MultiEdit
# regardless of target, locking out recovery edits to scripts/ etc. BG-C
# restricts the block to file paths under trail/.
fixture_j() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/J-XXXXXX")"
  # No trail/ — bootstrap incomplete. file_path is scripts/foo.py (out of scope).
  local payload='{"tool_input":{"file_path":"scripts/foo.py"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/J.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/J.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "J: expected exit 0 (out-of-scope path), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "J: expected empty stdout, got: $out"
    return
  fi
  record_pass "J (file_path=scripts/foo.py + no trail → exit 0, path-scoped)"
}

# ---------------------------------------------------------------------------
# Fixture K — in-scope file_path (trail/...) → exit 2 (block preserved)
# ---------------------------------------------------------------------------
# Edits targeting trail/ before bootstrap still block — the gate's original
# purpose. BG-C narrowed the scope but did not relax the trail/ rule.
fixture_k() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/K-XXXXXX")"
  local payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/K.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/K.err")

  if [ "$rc" -ne 2 ]; then
    record_fail "K: expected exit 2 (trail/ path + no bootstrap), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if ! printf '%s' "$err" | grep -q "rein-bootstrap-project.py"; then
    record_fail "K: stderr missing 'rein-bootstrap-project.py'"
    echo "  stderr: $err" >&2
    return
  fi
  record_pass "K (file_path=trail/inbox/foo.md → exit 2, in-scope block)"
}

# ---------------------------------------------------------------------------
# Fixture L — degraded marker pass-through (regardless of file_path)
# ---------------------------------------------------------------------------
# When SessionStart wrote degraded marker, even trail/ edits must pass —
# governance is dormant for this session.
fixture_l() {
  local dir out err rc
  dir="$(mktemp -d "$SCRATCH_ROOT/L-XXXXXX")"
  mkdir -p "$dir/.claude/cache"
  printf 'non-git-dir\n' > "$dir/.claude/cache/.rein-session-degraded"
  # Use a trail/ path to confirm bypass is degraded-driven, not path-driven.
  local payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/L.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/L.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "L: expected exit 0 (degraded marker bypass), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "L: expected empty stdout, got: $out"
    return
  fi
  record_pass "L (degraded marker → exit 0, even on trail/ path)"
}

# ---------------------------------------------------------------------------
# Fixture M — monorepo subdir + git-root degraded marker (HIGH-2 fix)
# ---------------------------------------------------------------------------
# codex-review NEEDS-FIX round 1: SessionStart writes the degraded marker
# under <git_root>/.claude/cache/, but pre-BG-C marker lookup used raw
# PROJECT_DIR_HINT="${PWD:-.}", which in a monorepo workflow (cwd is
# apps/web subdir, git root is the repo root) misses the marker entirely.
# The gate then blocks every trail/ edit for the rest of the session,
# leaving the user with no recovery path. This fixture pins the git-root
# walkup pattern: marker at <repo_root>/.claude/cache/, stdin.cwd points
# at a subdir, gate must still find the marker and pass through.
fixture_m() {
  local repo_root subdir out err rc
  repo_root="$(mktemp -d "$SCRATCH_ROOT/M-XXXXXX")"
  ( cd "$repo_root" && git init -q )
  # Write marker at git-root level (SessionStart's authoritative location).
  mkdir -p "$repo_root/.claude/cache"
  printf 'non-git-dir\n' > "$repo_root/.claude/cache/.rein-session-degraded"
  # Create a subdir to simulate apps/web in a monorepo. The session's cwd
  # in the envelope points at the subdir, not the repo root.
  subdir="$repo_root/apps/web"
  mkdir -p "$subdir"
  # in-scope (trail/) path so the gate would normally block; degraded
  # marker must take priority and short-circuit to exit 0.
  local payload
  payload="$(printf '{"cwd":"%s","tool_input":{"file_path":"trail/inbox/foo.md"}}' "$subdir")"
  out=$(
    cd "$subdir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$repo_root")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/M.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/M.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "M: expected exit 0 (degraded marker at git-root, cwd=subdir), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "M: expected empty stdout, got: $out"
    return
  fi
  record_pass "M (monorepo subdir + git-root degraded marker → exit 0, HIGH-2 fix)"
}

# ---------------------------------------------------------------------------
# Fixture N — bootstrap-complete contract on in-scope trail/ path
# ---------------------------------------------------------------------------
# codex-review NEEDS-FIX round 1 test-coverage gap: fixture B only validates
# the path-scope early-exit (no file_path → out-of-scope arm). It does NOT
# exercise the bootstrap_check rc=0 path with an in-scope file_path. This
# fixture explicitly seeds the full bootstrap contract (trail/ +
# .rein/project.json + trail/index.md — partial-bootstrap fix v1.3.0+1),
# sets an in-scope file_path under trail/, and asserts the gate reaches
# bootstrap_check and gets rc=0 → silent pass. Without this fixture, a
# regression that broke bootstrap_check's rc=0 success path could pass
# tests via the path-scope short-circuit alone.
fixture_n() {
  local dir out err rc payload
  dir="$(mktemp -d "$SCRATCH_ROOT/N-XXXXXX")"
  mkdir -p "$dir/trail" "$dir/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
    > "$dir/.rein/project.json"
  printf '# trail/index.md\n' > "$dir/trail/index.md"
  # in-scope trail/ path forces the case-glob to fall through (not exit 0
  # via *) → invokes bootstrap_check, which must return rc=0 because all
  # three markers (trail/, .rein/project.json, trail/index.md) are present.
  payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$dir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$dir")" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/N.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/N.err")

  if [ "$rc" -ne 0 ]; then
    record_fail "N: expected exit 0 (bootstrap-complete + in-scope trail/), got $rc"
    echo "  stderr: $err" >&2
    return
  fi
  if [ -n "$out" ]; then
    record_fail "N: expected empty stdout, got: $out"
    return
  fi
  record_pass "N (trail/ + .rein/project.json + trail/index.md + in-scope file_path → exit 0 via bootstrap_check rc=0)"
}

# ---------------------------------------------------------------------------
# Fixture O — BC-INFO1-siblings-2: poisoned git env must not redirect the
# no-stdin marker-root resolution to a decoy. The marker root feeds
# rein_is_degraded(); without the env -u sanitize on the no-stdin fallback,
# a poisoned GIT_DIR/GIT_WORK_TREE makes PROJECT_DIR_HINT resolve to a decoy
# whose degraded marker pass-throughs this gate (BYPASS). With the fix the
# resolution falls back to the real (non-degraded, trail-absent) project and
# the in-scope trail/ edit is correctly blocked (exit 2).
# ---------------------------------------------------------------------------
fixture_o() {
  local realdir decoy out err rc
  realdir="$(mktemp -d "$SCRATCH_ROOT/O-real-XXXXXX")"   # trail absent, NOT degraded
  decoy="$(mktemp -d "$SCRATCH_ROOT/O-decoy-XXXXXX")"
  git -C "$decoy" init -q >/dev/null 2>&1
  mkdir -p "$decoy/.claude/cache"
  : > "$decoy/.claude/cache/.rein-session-degraded"      # decoy is degraded
  local payload='{"tool_input":{"file_path":"trail/inbox/foo.md"}}'
  out=$(
    cd "$realdir" \
    && env -u GIT_CEILING_DIRECTORIES CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
       GIT_CEILING_DIRECTORIES="$(dirname "$realdir")" \
       GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" \
       bash "$HOOK" <<<"$payload" 2>"$SCRATCH_ROOT/O.err"
  )
  rc=$?
  err=$(cat "$SCRATCH_ROOT/O.err")

  if [ "$rc" -ne 2 ]; then
    record_fail "O: poisoned GIT_DIR latched decoy → gate bypassed (expected exit 2 BLOCK, got $rc) [BC-INFO1-siblings-2]"
    echo "  stderr: $err" >&2
    return
  fi
  record_pass "O (poisoned git env does not redirect marker-root to decoy → in-scope trail edit still blocked)"
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
fixture_j
fixture_k
fixture_l
fixture_m
fixture_n
fixture_o

echo
echo "test-pre-edit-trail-bootstrap-gate: pass=$PASS_COUNT fail=$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
