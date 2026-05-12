#!/usr/bin/env bash
# test-session-start-bootstrap-helper-refactor.sh
#
# Verifies session-start-bootstrap.sh delegates the bootstrap predicate to
# the shared helper `hooks/lib/bootstrap-check.sh` and preserves the legacy
# external emit contract (plain stdout, no JSON envelope).
#
# Fixtures:
#   A — trail/ missing on a safe project_dir → stdout contains the helper
#       bilingual guidance (rc=10 emit path).
#   B — trail/ present                       → stdout silent (rc=0 path).
#   C — $HOME (sensitive-path)               → stdout silent (rc=11 path).
#   D — source pattern grep                   → hook actually source(s) the
#       shared helper (Scope ID `share-helper-via-source`).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-bootstrap.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

A_DIR=""
B_DIR=""
A_OUT=""
B_OUT=""
C_OUT=""
A_DIRECT_OUT=""
cleanup() {
  rm -rf "$A_DIR" "$B_DIR" 2>/dev/null || true
  rm -f "$A_OUT" "$B_OUT" "$C_OUT" "$A_DIRECT_OUT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture A: trail/ 부재 → stdout 에 bootstrap 안내 substring (rc=10)
# ---------------------------------------------------------------------------
A_DIR="$(mktemp -d "/tmp/ssb-A-XXXXXX")"
A_OUT="$(mktemp)"
set +e
( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" </dev/null >"$A_OUT" 2>/dev/null )
A_RC=$?
set -e
[ "$A_RC" = "0" ] || { echo "FAIL (A): exit $A_RC expected 0" >&2; exit 1; }
grep -q "rein-bootstrap-project.py" "$A_OUT" || {
  echo "FAIL (A): stdout missing bootstrap command" >&2
  echo "--- A stdout ---" >&2
  cat "$A_OUT" >&2
  exit 1
}
grep -q "surface this message to the user immediately" "$A_OUT" || {
  echo "FAIL (A): stdout missing surface instruction" >&2
  echo "--- A stdout ---" >&2
  cat "$A_OUT" >&2
  exit 1
}

# Fixture A 확장 — byte-level trailing-newline parity:
# bootstrap-check helper 의 직접 stdout 과 session-start hook 의 stdout 이
# byte-for-byte 동일해야 한다 (Codex Round 1: plain $(...) capture 가
# trailing \n 을 strip 하던 회귀의 regression 가드).
A_DIRECT_OUT="$(mktemp)"
HELPER="$PROJECT_DIR/plugins/rein-core/hooks/lib/bootstrap-check.sh"
set +e
( cd "$A_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HELPER" </dev/null >"$A_DIRECT_OUT" 2>/dev/null )
A_DIRECT_RC=$?
set -e
[ "$A_DIRECT_RC" = "10" ] || {
  echo "FAIL (A trailing newline): helper direct exit $A_DIRECT_RC expected 10 (trail/ missing on safe dir)" >&2
  exit 1
}
if ! diff -q "$A_OUT" "$A_DIRECT_OUT" >/dev/null; then
  echo "FAIL (A trailing newline): session-start hook stdout differs from helper direct output" >&2
  echo "diff:" >&2
  diff "$A_OUT" "$A_DIRECT_OUT" >&2
  echo "hook stdout size: $(wc -c < "$A_OUT")" >&2
  echo "helper direct size: $(wc -c < "$A_DIRECT_OUT")" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture B: trail/ 존재 → stdout silent (rc=0)
# ---------------------------------------------------------------------------
B_DIR="$(mktemp -d "/tmp/ssb-B-XXXXXX")"
mkdir "$B_DIR/trail"
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

echo "test-session-start-bootstrap-helper-refactor: OK (A advisory + A trailing-newline parity + B silent + C unsafe-silent + D source pattern)"
