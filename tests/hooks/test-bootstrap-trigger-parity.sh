#!/usr/bin/env bash
# Verify that "fresh session" and "/reload-plugins" trigger paths converge on
# identical bootstrap helper output, command, and stderr message.
#
# Two trigger paths are simulated:
#
#   Path 1 — Fresh session
#     1. SessionStart hook runs (session-start-bootstrap.sh) → stdout = guidance
#     2. First Edit/Write/MultiEdit fires pre-edit-trail-bootstrap-gate.sh
#        → stderr = helper diagnostic + guidance, exit 2 (BLOCK)
#
#   Path 2 — /reload-plugins
#     1. SessionStart is NOT re-invoked (per current Claude Code behaviour;
#        this is the spec assumption for v1.1.1 — verified via direct hook
#        invocation, not platform integration)
#     2. First Edit/Write/MultiEdit fires pre-edit-trail-bootstrap-gate.sh
#        → stderr = helper diagnostic + guidance, exit 2 (BLOCK)
#
# Equivalence assertions (the parity contract):
#   (1) Both paths' pre-edit gate stderr is byte-for-byte equal — same helper,
#       same diagnostic line, same bilingual guidance, same bootstrap command.
#   (2) The bootstrap command line ("python3 ... rein-bootstrap-project.py
#       ... --project-dir ...") extracted from each path is identical.
#   (3) The bootstrap command appearing in Path 1's SessionStart stdout
#       matches the bootstrap command in the pre-edit gate stderr — proves
#       both hooks source the same helper output for the same project_dir.
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
# Prerequisites (Task 1.2 / 2.2 must already be working tree)
# ---------------------------------------------------------------------------
if [ ! -x "$SESSION_START" ]; then
  echo "FAIL: $SESSION_START not executable (Task 2.2 prereq)" >&2
  exit 1
fi
if [ ! -x "$PRE_EDIT_GATE" ]; then
  echo "FAIL: $PRE_EDIT_GATE not executable (Task 1.2 prereq)" >&2
  exit 1
fi

# Fresh tmpdir simulating an un-bootstrapped user project.
# - No trail/ directory
# - Not a git repo (so helper falls back to $PWD resolution)
# - CLAUDE_PROJECT_DIR unset for both paths to mirror real plugin invocation
TMPDIR_PARITY=$(mktemp -d "/tmp/rein-parity-XXXXXX")
trap 'rm -rf "$TMPDIR_PARITY"' EXIT

# ---------------------------------------------------------------------------
# Path 1: Fresh session simulation
# ---------------------------------------------------------------------------
# Step A: SessionStart hook → stdout = guidance text (no stderr)
P1_SESSION_STDOUT=$(mktemp)
(
  cd "$TMPDIR_PARITY"
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$SESSION_START" </dev/null >"$P1_SESSION_STDOUT" 2>/dev/null
)

# Step B: First Edit/Write fires pre-edit gate → stderr = guidance, exit 2
P1_GATE_STDERR=$(mktemp)
set +e
(
  cd "$TMPDIR_PARITY"
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PRE_EDIT_GATE" </dev/null >/dev/null 2>"$P1_GATE_STDERR"
)
P1_GATE_RC=$?
set -e

# Path 1 sanity checks
if [ "$P1_GATE_RC" != "2" ]; then
  echo "FAIL: fresh session path — pre-edit gate expected exit 2 (BLOCK), got $P1_GATE_RC" >&2
  echo "--- stderr ---" >&2
  cat "$P1_GATE_STDERR" >&2
  exit 1
fi
if [ ! -s "$P1_SESSION_STDOUT" ]; then
  echo "FAIL: fresh session path — session-start emitted empty stdout (expected guidance)" >&2
  exit 1
fi
if [ ! -s "$P1_GATE_STDERR" ]; then
  echo "FAIL: fresh session path — pre-edit gate stderr empty (expected guidance + diagnostic)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Path 2: /reload-plugins simulation
#   - SessionStart is NOT re-invoked
#   - Same tmpdir + same CLAUDE_PLUGIN_ROOT (Claude Code re-points the plugin
#     after reload; we model this as the same directory re-entry, since the
#     helper is path-deterministic and stateless)
#   - First subsequent edit fires the pre-edit gate
# ---------------------------------------------------------------------------
P2_GATE_STDERR=$(mktemp)
set +e
(
  cd "$TMPDIR_PARITY"
  env -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PRE_EDIT_GATE" </dev/null >/dev/null 2>"$P2_GATE_STDERR"
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
# Equivalence assertion 1: pre-edit gate stderr — byte-for-byte equal
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
# Equivalence assertion 2: bootstrap command string — identical across paths
# ---------------------------------------------------------------------------
# Match the literal "Run:" prefixed bootstrap command line. The helper emits
# it as:
#   Run: python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" --project-dir "<resolved>"
#
# The ${CLAUDE_PLUGIN_ROOT} substring is intentionally a literal in the
# guidance — Claude expands it when surfacing the command — so a simple
# grep on "python3 .* rein-bootstrap-project.py .* --project-dir" is enough.
_extract_bootstrap_cmd() {
  # grep -E for ERE; -o to capture only the matching segment of the line.
  # We grab the whole "python3 ... --project-dir ..." substring on the Run: line.
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
# Equivalence assertion 3: helper output consistency across hook entry points
#   - SessionStart stdout (Path 1) must contain the same bootstrap command
#     as the pre-edit gate stderr — proves both hooks invoke the same helper
#     with the same project_dir resolution, and the helper emits the same
#     guidance regardless of caller.
# ---------------------------------------------------------------------------
P1_SS_CMD="$(_extract_bootstrap_cmd "$P1_SESSION_STDOUT")"

if [ -z "$P1_SS_CMD" ]; then
  echo "FAIL: session-start stdout — bootstrap command not extracted" >&2
  echo "--- stdout ---" >&2
  cat "$P1_SESSION_STDOUT" >&2
  exit 1
fi
if [ "$P1_SS_CMD" != "$P1_CMD" ]; then
  echo "FAIL: session-start stdout command differs from pre-edit gate stderr command (helper inconsistency)" >&2
  echo "  session-start : $P1_SS_CMD" >&2
  echo "  pre-edit gate : $P1_CMD" >&2
  exit 1
fi

echo "test-bootstrap-trigger-parity: OK (fresh-session + reload-plugins paths emit byte-identical bootstrap stderr + identical bootstrap command + helper consistency across SessionStart and PreToolUse entry points)"
