#!/bin/bash
# tests/hooks/test-path-containment.sh
# Unit tests for plugins/rein-core/hooks/lib/path-containment.sh (GE-1).
#
# Shared validator extracted from session-start-load-trail.sh inline 4-check so
# select-active-dod.sh (Tier 1) and the session-start cleanup hook share one
# copy (no drift). Contract:
#   validate_repo_relative_path <project_dir> <path>
#     return 0 + no output  → path safe
#     return 1 + reason       → path unsafe (reason substrings: "empty path",
#                               "metachars", ".. segment", "outside PROJECT_DIR")

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/path-containment.sh"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-path-containment.sh"
echo ""

if [ ! -f "$LIB" ]; then
  _fail "path-containment lib not found: $LIB"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# shellcheck disable=SC1090
. "$LIB"

if ! declare -F validate_repo_relative_path >/dev/null 2>&1; then
  _fail "validate_repo_relative_path not defined after sourcing"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/trail/dod"
echo "ok" > "$SANDBOX/trail/dod/dod-real.md"

# ---- Test 1: valid repo-relative path → 0.
reason=$(validate_repo_relative_path "$SANDBOX" "trail/dod/dod-real.md"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$reason" ]; then
  _pass "valid relative path accepted"
else
  _fail "valid relative path rejected (rc=$rc reason=$reason)"
fi

# ---- Test 2: empty path → 1 + "empty path".
reason=$(validate_repo_relative_path "$SANDBOX" ""); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -q "empty path"; then
  _pass "empty path rejected"
else
  _fail "empty path not rejected (rc=$rc reason=$reason)"
fi

# ---- Test 3: shell metachars → 1 + "metachars".
reason=$(validate_repo_relative_path "$SANDBOX" "trail/dod/dod-foo.md;rm -rf /"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -q "metachars"; then
  _pass "metachar path rejected"
else
  _fail "metachar path not rejected (rc=$rc reason=$reason)"
fi

# ---- Test 4: `..` traversal → 1 + ".. segment".
reason=$(validate_repo_relative_path "$SANDBOX" "../../etc/passwd"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -q ".. segment"; then
  _pass ".. traversal rejected"
else
  _fail ".. traversal not rejected (rc=$rc reason=$reason)"
fi

# ---- Test 5: absolute path outside project → 1 + "outside PROJECT_DIR".
reason=$(validate_repo_relative_path "$SANDBOX" "/etc/passwd"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -q "outside PROJECT_DIR"; then
  _pass "absolute external path rejected"
else
  _fail "absolute external path not rejected (rc=$rc reason=$reason)"
fi

# ---- Test 6: symlink escape (realpath resolves outside) → 1 + "outside PROJECT_DIR".
ln -s /etc/passwd "$SANDBOX/trail/dod/escape-link.md"
reason=$(validate_repo_relative_path "$SANDBOX" "trail/dod/escape-link.md"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$reason" | grep -q "outside PROJECT_DIR"; then
  _pass "symlink escape rejected by commonpath"
else
  _fail "symlink escape not rejected (rc=$rc reason=$reason)"
fi

rm -rf "$SANDBOX"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
