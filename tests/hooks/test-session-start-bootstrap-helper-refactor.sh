#!/usr/bin/env bash
# test-session-start-bootstrap-helper-refactor.sh
#
# Verifies session-start-bootstrap.sh BG-A (v1.3.0) behavior and its
# delegation to the shared helper `hooks/lib/bootstrap-check.sh`.
#
# Fixtures:
#   A — git-init'd dir, REIN_NO_AUTO_BOOTSTRAP=1 (opt-out)
#       → stdout contains opt-out notice; degraded marker written (rc=0).
#       This is the opt-out branch (BG-A step 1): the hook does NOT
#       auto-bootstrap; it emits a user-visible notice and marks the session
#       degraded. This verifies the opt-out contract rather than the old
#       "emit bootstrap guidance" contract which only fires on step 5
#       (bootstrap-refused), a path unreachable on a normal writable git dir.
#
#   A2 — git-init'd dir, no opt-out (auto-bootstrap path, BG-A step 4)
#        → stdout contains "bootstrap completed automatically"; trail/ and
#        .rein/project.json created; rc=0.
#        This verifies the primary self-healing contract introduced in v1.3.0.
#
#   B — bootstrap complete (trail/ + .rein/project.json + trail/index.md)
#       → stdout silent (rc=0 path).
#
#   C — $HOME (sensitive-path)               → stdout silent (rc=11 path).
#
#   D — source pattern grep                   → hook actually source(s) the
#       shared helper (Scope ID `share-helper-via-source`).
#
# Note on the trailing-newline parity sub-test (removed):
#   The prior test asserted byte-parity between hook stdout and direct
#   bootstrap-check.sh stdout on a non-git dir. With BG-A, the hook no longer
#   forwards the helper's rc=10 guidance text to stdout on the normal un-
#   bootstrapped-git-dir path — it either auto-bootstraps (step 4) or emits
#   its own opt-out message (step 1). The parity assertion was valid for the
#   pre-BG-A "emit guidance" design; it is not a current contract and has been
#   removed to avoid testing a code path that no longer exists.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-bootstrap.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

A_DIR=""
A2_DIR=""
B_DIR=""
A_OUT=""
A2_OUT=""
B_OUT=""
C_OUT=""
cleanup() {
  rm -rf "$A_DIR" "$A2_DIR" "$B_DIR" 2>/dev/null || true
  rm -f "$A_OUT" "$A2_OUT" "$B_OUT" "$C_OUT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture A: git-init'd dir + REIN_NO_AUTO_BOOTSTRAP=1 (opt-out branch)
# ---------------------------------------------------------------------------
# BG-A step 1: hook detects rc=10 from helper but skips auto-bootstrap due to
# the opt-out env var. It writes a degraded marker and emits a Korean/English
# notice so the user understands monitoring is inactive for this session.
# This is the principal way to test the hook's rc=10 branch without triggering
# auto-bootstrap (which would succeed and leave the dir bootstrapped).
A_DIR="$(mktemp -d "/tmp/ssb-A-XXXXXX")"
git -C "$A_DIR" init -q 2>/dev/null
A_OUT="$(mktemp)"
set +e
( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_NO_AUTO_BOOTSTRAP=1 bash "$HOOK" </dev/null >"$A_OUT" 2>/dev/null )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { echo "FAIL (A): exit $A_RC expected 0" >&2; exit 1; }

grep -q "REIN_NO_AUTO_BOOTSTRAP" "$A_OUT" || {
  echo "FAIL (A): stdout missing REIN_NO_AUTO_BOOTSTRAP opt-out notice" >&2
  echo "--- A stdout ---" >&2
  cat "$A_OUT" >&2
  exit 1
}

# Degraded marker must be written so downstream gates pass through silently.
A_DEGRADED_MARKER="$A_DIR/.claude/cache/.rein-session-degraded"
if [ ! -f "$A_DEGRADED_MARKER" ]; then
  echo "FAIL (A): degraded marker not written at $A_DEGRADED_MARKER" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture A2: git-init'd dir, auto-bootstrap (BG-A step 4, the primary path)
# ---------------------------------------------------------------------------
# On a writable git-init'd dir without opt-out, SessionStart runs
# rein-bootstrap-project.py, creates trail/ + .rein/project.json, and emits
# the "bootstrap completed automatically" notice. This is the v1.3.0 self-
# healing contract — the main new behavior of BG-A.
A2_DIR="$(mktemp -d "/tmp/ssb-A2-XXXXXX")"
git -C "$A2_DIR" init -q 2>/dev/null
A2_OUT="$(mktemp)"
set +e
( cd "$A2_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$A2_OUT" 2>/dev/null )
A2_RC=$?
set -e
[ "$A2_RC" = "0" ] || { echo "FAIL (A2): exit $A2_RC expected 0" >&2; exit 1; }

grep -q "bootstrap completed automatically" "$A2_OUT" || {
  echo "FAIL (A2): stdout missing 'bootstrap completed automatically'" >&2
  echo "--- A2 stdout ---" >&2
  cat "$A2_OUT" >&2
  exit 1
}

# trail/ and .rein/project.json must have been created.
if [ ! -d "$A2_DIR/trail" ]; then
  echo "FAIL (A2): trail/ directory not created by auto-bootstrap" >&2
  exit 1
fi
if [ ! -f "$A2_DIR/.rein/project.json" ]; then
  echo "FAIL (A2): .rein/project.json not created by auto-bootstrap" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture B: bootstrap complete (trail/ + .rein/project.json + index) → silent (rc=0)
# ---------------------------------------------------------------------------
# Partial-bootstrap fix (v1.3.0+1): bootstrap_check requires all three
# markers — trail/ dir, .rein/project.json, and trail/index.md. Seed all
# three so the helper takes the rc=0 (bootstrapped) path.
#
# ONBOARD-1: also seed the .rein/.onboarded marker so this fixture represents
# an already-onboarded existing user. Without it, the rc=0 path now emits the
# first-session backfill primer (SCOPE-BACKFILL) — that behavior is covered by
# test-onboarding-primer.sh. This fixture asserts only the degraded-clear rc=0
# silence, so it must look like a user who has already seen the primer.
B_DIR="$(mktemp -d "/tmp/ssb-B-XXXXXX")"
mkdir "$B_DIR/trail" "$B_DIR/.rein"
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' > "$B_DIR/.rein/project.json"
printf '# trail/index.md\n' > "$B_DIR/trail/index.md"
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$B_DIR/.rein/.onboarded"
B_OUT="$(mktemp)"
set +e
( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$B_OUT" 2>/dev/null )
B_RC=$?
set -e
[ "$B_RC" = "0" ] || { echo "FAIL (B): exit $B_RC expected 0" >&2; exit 1; }
if [ -s "$B_OUT" ]; then
  echo "FAIL (B): stdout non-empty: $(head -c 200 "$B_OUT")" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture C: $HOME (helper exit 11 sensitive-path) → stdout silent
# ---------------------------------------------------------------------------
C_OUT="$(mktemp)"
set +e
( cd "$HOME" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$C_OUT" 2>/dev/null )
C_RC=$?
set -e
[ "$C_RC" = "0" ] || { echo "FAIL (C): exit $C_RC expected 0" >&2; exit 1; }
if grep -q "rein-bootstrap-project.py" "$C_OUT"; then
  echo "FAIL (C): helper exit 11 should be silent but got advisory" >&2
  echo "--- C stdout ---" >&2
  cat "$C_OUT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture D: helper source 패턴 검증 (Scope ID share-helper-via-source)
# Hook source 가 `source` 또는 `.` 로 bootstrap-check.sh 를 로드하는지 grep.
# ---------------------------------------------------------------------------
if ! grep -E '(^|[[:space:]])(source|\.)[[:space:]]+("?\$\{?CLAUDE_PLUGIN_ROOT\}?"?)?/?[^[:space:]]*hooks/lib/bootstrap-check\.sh' "$HOOK" >/dev/null; then
  echo "FAIL (D): hook does not 'source' bootstrap-check.sh (Scope ID share-via-source 위반)" >&2
  echo "--- hook source ---" >&2
  cat "$HOOK" >&2
  exit 1
fi

echo "test-session-start-bootstrap-helper-refactor: OK (A opt-out notice + A2 auto-bootstrap + B silent + C unsafe-silent + D source pattern)"
