#!/usr/bin/env bash
# Verify that "fresh session" and "/reload-plugins" trigger paths converge on
# identical bootstrap helper output, command, and stderr message.
#
# Two trigger paths are simulated:
#
#   Path 1 — Fresh session
#     The pre-edit-trail-bootstrap-gate.sh is invoked directly against an
#     un-bootstrapped git repo (SessionStart is NOT invoked here so it cannot
#     auto-bootstrap the tmpdir before the gate runs — the gate is tested in
#     isolation as a unit).
#     Gate receives a trail/-scoped hook-input JSON envelope → exit 2 (BLOCK)
#     with bilingual guidance on stderr.
#
#   Path 2 — /reload-plugins
#     Same as Path 1: SessionStart is NOT re-invoked (per current Claude Code
#     behaviour; this is the spec assumption for v1.1.1 — verified via direct
#     hook invocation, not platform integration). First Edit/Write fires the
#     pre-edit gate against the same un-bootstrapped state.
#     Gate receives identical trail/-scoped envelope → exit 2 (BLOCK).
#
# Equivalence assertions (the parity contract):
#   (1) Both paths' pre-edit gate exit code is 2 (BLOCK).
#   (2) Both paths' pre-edit gate stderr is byte-for-byte equal — same helper,
#       same diagnostic line, same bilingual guidance, same bootstrap command.
#   (3) The bootstrap command line ("python3 ... rein-bootstrap-project.py
#       ... --project-dir ...") extracted from each path is identical.
#
# Additional contract assertion:
#   (4) After SessionStart auto-bootstraps a git repo (BG-A path), the
#       pre-edit gate passes through silently (exit 0) — confirming that the
#       gate and SessionStart agree on bootstrap state and the gate does not
#       block a healthy project.
#
# Note on SessionStart interaction:
#   BG-A (v1.3.0) means SessionStart auto-bootstraps any git-init'd
#   un-bootstrapped project. Invoking SessionStart before the gate would leave
#   the tmpdir bootstrapped and the gate would pass (exit 0) — the opposite of
#   what Paths 1 and 2 test. Assertions (1)-(3) therefore invoke the gate
#   directly without SessionStart, testing the gate's block path in isolation.
#   Assertion (4) covers the SessionStart-first scenario separately.
#
# Scope ID:
#   reload-plugins-and-fresh-session-trigger-identical-bootstrap-flow-via-
#   same-helper-and-same-bootstrap-command

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
SESSION_START="$PLUGIN_ROOT/hooks/session-start-bootstrap.sh"
PRE_EDIT_GATE="$PLUGIN_ROOT/hooks/pre-edit-trail-bootstrap-gate.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if [ ! -x "$SESSION_START" ]; then
  echo "FAIL: $SESSION_START not executable" >&2
  exit 1
fi
if [ ! -x "$PRE_EDIT_GATE" ]; then
  echo "FAIL: $PRE_EDIT_GATE not executable" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Shared tmpdir — un-bootstrapped git repo used for Paths 1 and 2.
# SessionStart is NOT invoked against this dir so BG-A auto-bootstrap does
# not run and the dir remains un-bootstrapped throughout Paths 1 and 2.
# ---------------------------------------------------------------------------
TMPDIR_PARITY=$(mktemp -d "/tmp/rein-parity-XXXXXX")
trap 'rm -rf "$TMPDIR_PARITY"' EXIT
git -C "$TMPDIR_PARITY" init -q 2>/dev/null

# ---------------------------------------------------------------------------
# Path 1: Fresh session simulation — gate invoked directly (no SessionStart)
# ---------------------------------------------------------------------------
# Supply a trail/-scoped hook-input JSON envelope so the gate's path-scope
# filter (case */trail/*) falls through to bootstrap_check. An empty or
# non-trail file_path would exit 0 immediately without checking bootstrap state.
P1_GATE_STDERR=$(mktemp)
set +e
(
  cd "$TMPDIR_PARITY"
  printf '%s' "{\"tool_input\":{\"file_path\":\"trail/index.md\"},\"cwd\":\"$TMPDIR_PARITY\"}" | \
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PRE_EDIT_GATE" >/dev/null 2>"$P1_GATE_STDERR"
)
P1_GATE_RC=$?
set -e

if [ "$P1_GATE_RC" != "2" ]; then
  echo "FAIL: fresh session path — pre-edit gate expected exit 2 (BLOCK), got $P1_GATE_RC" >&2
  echo "--- stderr ---" >&2
  cat "$P1_GATE_STDERR" >&2
  exit 1
fi
if [ ! -s "$P1_GATE_STDERR" ]; then
  echo "FAIL: fresh session path — pre-edit gate stderr empty (expected guidance + diagnostic)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Path 2: /reload-plugins simulation
#   - SessionStart is NOT re-invoked
#   - Same tmpdir + same CLAUDE_PLUGIN_ROOT
#   - First subsequent edit fires the pre-edit gate
# ---------------------------------------------------------------------------
P2_GATE_STDERR=$(mktemp)
set +e
(
  cd "$TMPDIR_PARITY"
  printf '%s' "{\"tool_input\":{\"file_path\":\"trail/index.md\"},\"cwd\":\"$TMPDIR_PARITY\"}" | \
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PRE_EDIT_GATE" >/dev/null 2>"$P2_GATE_STDERR"
)
P2_GATE_RC=$?
set -e

if [ "$P2_GATE_RC" != "2" ]; then
  echo "FAIL: reload-plugins path — pre-edit gate expected exit 2 (BLOCK), got $P2_GATE_RC" >&2
  echo "--- stderr ---" >&2
  cat "$P2_GATE_STDERR" >&2
  exit 1
fi
if [ ! -s "$P2_GATE_STDERR" ]; then
  echo "FAIL: reload-plugins path — pre-edit gate stderr empty (expected guidance + diagnostic)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Equivalence assertion 1: pre-edit gate exit code — both BLOCK (exit 2)
# (already checked per-path above; reaching here means both passed)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Equivalence assertion 2: pre-edit gate stderr — byte-for-byte equal
# ---------------------------------------------------------------------------
# Why this is the strongest single check: stderr contains both the helper's
# diagnostic line ("bootstrap-check: project_dir=... guidance_size=N source=...")
# and the full bilingual guidance text. If either path drifts in resolution
# source, dir, or guidance template, this diff fires.
if ! diff -q "$P1_GATE_STDERR" "$P2_GATE_STDERR" >/dev/null; then
  echo "FAIL: pre-edit gate stderr differs between fresh-session and reload-plugins paths" >&2
  echo "--- diff (fresh-session  vs  reload-plugins) ---" >&2
  diff "$P1_GATE_STDERR" "$P2_GATE_STDERR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Equivalence assertion 3: bootstrap command string — identical across paths
# ---------------------------------------------------------------------------
# Match the literal "Run:" prefixed bootstrap command line. The helper emits:
#   Run: python3 "<abs-path>/rein-bootstrap-project.py" --project-dir "<resolved>"
_extract_bootstrap_cmd() {
  grep -E '^Run: python3 .*rein-bootstrap-project\.py.* --project-dir ' "$1" | head -1
}

P1_CMD="$(_extract_bootstrap_cmd "$P1_GATE_STDERR")"
P2_CMD="$(_extract_bootstrap_cmd "$P2_GATE_STDERR")"

if [ -z "$P1_CMD" ]; then
  echo "FAIL: fresh session path — bootstrap command not extracted from stderr" >&2
  echo "--- stderr ---" >&2
  cat "$P1_GATE_STDERR" >&2
  exit 1
fi
if [ -z "$P2_CMD" ]; then
  echo "FAIL: reload-plugins path — bootstrap command not extracted from stderr" >&2
  echo "--- stderr ---" >&2
  cat "$P2_GATE_STDERR" >&2
  exit 1
fi
if [ "$P1_CMD" != "$P2_CMD" ]; then
  echo "FAIL: bootstrap commands differ between paths" >&2
  echo "  fresh-session : $P1_CMD" >&2
  echo "  reload-plugins: $P2_CMD" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 4: SessionStart auto-bootstrap → gate passes (exit 0)
#   BG-A contract: SessionStart on a git-init'd un-bootstrapped project runs
#   rein-bootstrap-project.py, creating trail/ + .rein/project.json.
#   After that the pre-edit gate must see a bootstrapped project and pass
#   through silently — no block, no stderr — confirming gate/SessionStart agree.
# ---------------------------------------------------------------------------
TMPDIR_AUTOBOOT=$(mktemp -d "/tmp/rein-autoboot-XXXXXX")
trap 'rm -rf "$TMPDIR_PARITY" "$TMPDIR_AUTOBOOT"' EXIT
git -C "$TMPDIR_AUTOBOOT" init -q 2>/dev/null

# Step A: SessionStart auto-bootstraps.
SS_AUTOBOOT_OUT=$(mktemp)
(
  cd "$TMPDIR_AUTOBOOT"
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$SESSION_START" </dev/null >"$SS_AUTOBOOT_OUT" 2>/dev/null
)
if ! grep -q "bootstrap completed automatically" "$SS_AUTOBOOT_OUT"; then
  echo "FAIL (assertion 4): SessionStart did not emit 'bootstrap completed automatically'" >&2
  echo "--- stdout ---" >&2
  cat "$SS_AUTOBOOT_OUT" >&2
  exit 1
fi

# Step B: pre-edit gate must pass (exit 0) on the now-bootstrapped project.
set +e
(
  cd "$TMPDIR_AUTOBOOT"
  printf '%s' "{\"tool_input\":{\"file_path\":\"trail/index.md\"},\"cwd\":\"$TMPDIR_AUTOBOOT\"}" | \
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PRE_EDIT_GATE" >/dev/null 2>/dev/null
)
AUTOBOOT_GATE_RC=$?
set -e

if [ "$AUTOBOOT_GATE_RC" != "0" ]; then
  echo "FAIL (assertion 4): pre-edit gate expected exit 0 (PASS) after SessionStart auto-bootstrap, got $AUTOBOOT_GATE_RC" >&2
  exit 1
fi

echo "test-bootstrap-trigger-parity: OK (fresh-session + reload-plugins paths emit byte-identical bootstrap stderr + identical bootstrap command; SessionStart auto-bootstrap + gate-pass assertion verified)"
