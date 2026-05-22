#!/bin/bash
# tests/skills/test-codex-review-stale-stamp.sh
# Unit tests for scripts/rein-codex-review.sh::_resolve_diff_base staleness self-healing
# (묶음 C — wrapper context lifecycle hardening, Phase 2).
#
# Scope IDs covered:
#   - wrapper-detects-stale-stamp-when-reviewed-at-iso-before-head-commit-iso
#   - wrapper-treats-iso-parse-failure-as-stale-fail-safe
#   - wrapper-stale-stamp-falls-back-to-head-tilde-1-then-empty-tree
#
# Scenarios:
#   1. Fresh stamp (reviewed_at = HEAD ISO + 1초) → use stamp.diff_base
#   2. Stale stamp (reviewed_at far in past) → ignore + HEAD~1 fallback
#   3. Parse failure (reviewed_at = "garbage") → fail-safe + HEAD~1 fallback
#   4. Initial commit (HEAD~1 absent) + stale stamp → EMPTY_TREE_SHA
#   5. (regression) No stamp → HEAD~1 fallback

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_DIR/scripts/rein-codex-review.sh"
# select-active-dod lives in the plugin SSOT after Option C Phase 3 removed
# the dev `.claude/hooks/` overlay; fall back to the overlay for legacy envs.
if [ -f "$PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" ]; then
  SELECTOR_LIB="$PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh"
else
  SELECTOR_LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
fi
EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-codex-review-stale-stamp.sh"
echo ""

if [ ! -f "$WRAPPER" ]; then
  _fail "wrapper not found: $WRAPPER"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Helper: build sandbox with git repo + selector lib stub + fixture stamp.
_mksandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/trail/dod"
  mkdir -p "$dir/.claude/hooks/lib"
  cp "$SELECTOR_LIB" "$dir/.claude/hooks/lib/"
  # GE-1: select-active-dod.sh sources its sibling path-containment.sh — copy it
  # too so sourcing the selector is clean in the sandbox.
  cp "$(dirname "$SELECTOR_LIB")/path-containment.sh" "$dir/.claude/hooks/lib/" 2>/dev/null || true
  git -C "$dir" init -q -b main 2>/dev/null
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Tester
  echo "$dir"
}

# Helper: invoke wrapper as subshell + capture _resolve_diff_base via DIFF_BASE.
# Source script computes DIFF_BASE during init (line ~144).
_get_diff_base() {
  local sandbox="$1"
  REIN_PROJECT_DIR_OVERRIDE="$sandbox" bash -c '
    cd "$1" || exit 1
    # Source wrapper non-interactively (BASH_SOURCE != $0 → skips main).
    # PROMPT_BODY empty → code-review mode default.
    . "$2" </dev/null 2>/dev/null
    printf "%s" "$DIFF_BASE"
  ' _ "$sandbox" "$WRAPPER"
}

# ---- Test 1: Fresh stamp + valid ancestor diff_base → use stored diff_base.
# GE-2: a fresh stamp's diff_base must now also be a real ancestor commit, so
# this test uses HEAD~1 (real ancestor) instead of a fabricated SHA.
echo "### Test 1: wrapper_uses_stamp_diff_base_when_stamp_is_fresh_and_valid_ancestor"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
git -C "$S" commit --allow-empty -q -m "third commit"
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
# Fresh: stamp_iso > head_iso (e.g. 1 hour later)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
h = datetime.fromisoformat('$HEAD_ISO')
print((h + timedelta(hours=1)).isoformat())
")
REAL_BASE=$(git -C "$S" rev-parse HEAD~1)   # real ancestor of HEAD
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $REAL_BASE
verdict: PASS
cycle: test
scope: test
active_dod: trail/dod/dod-foo.md
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$REAL_BASE" ]; then
  _pass "fresh stamp + valid ancestor → stored diff_base ($result)"
else
  _fail "expected fresh valid-ancestor diff_base=$REAL_BASE, got: $result"
fi
rm -rf "$S"

# ---- Test 2: Stale stamp → ignore + HEAD~1 fallback.
echo "### Test 2: wrapper_detects_stale_stamp_when_reviewed_at_iso_before_head_commit_iso"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
FAKE_BASE="deadbeef0000000000000000000000000000bbbb"
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: 2020-01-01T00:00:00Z
reviewer: codex
diff_base: $FAKE_BASE
verdict: PASS
cycle: test
scope: test
active_dod: trail/dod/dod-foo.md
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "stale stamp ignored → HEAD~1 ($result)"
elif [ "$result" = "$FAKE_BASE" ]; then
  _fail "stale stamp NOT detected — wrapper used stale diff_base ($FAKE_BASE)"
else
  _fail "stale stamp expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test 3: Parse failure → fail-safe + HEAD~1 fallback.
echo "### Test 3: wrapper_treats_iso_parse_failure_as_stale_fail_safe"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
FAKE_BASE="deadbeef0000000000000000000000000000cccc"
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: not-an-iso-timestamp-garbage
reviewer: codex
diff_base: $FAKE_BASE
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "parse failure → fail-safe HEAD~1 ($result)"
elif [ "$result" = "$FAKE_BASE" ]; then
  _fail "parse failure NOT fail-safed — wrapper used stamp diff_base ($FAKE_BASE)"
else
  _fail "parse failure expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test 4: Initial commit (HEAD~1 absent) + stale stamp → EMPTY_TREE_SHA.
echo "### Test 4: wrapper_stale_stamp_falls_back_to_empty_tree_when_no_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "only commit"
FAKE_BASE="deadbeef0000000000000000000000000000dddd"
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: 2020-01-01T00:00:00Z
diff_base: $FAKE_BASE
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$EMPTY_TREE_SHA" ]; then
  _pass "stale + initial commit → EMPTY_TREE_SHA"
else
  _fail "expected EMPTY_TREE_SHA=$EMPTY_TREE_SHA, got: $result"
fi
rm -rf "$S"

# ---- Test 5: No stamp at all → HEAD~1 fallback (regression).
echo "### Test 5: wrapper_falls_back_to_head_tilde_1_when_no_stamp_present"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
# No .codex-reviewed file
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "no stamp → HEAD~1 ($result)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test 6 (GE-2): Fresh stamp + NON-EXISTENT SHA → fall back to HEAD~1.
echo "### Test 6: GE2_fresh_stamp_nonexistent_sha_falls_back_to_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
print((datetime.fromisoformat('$HEAD_ISO') + timedelta(hours=1)).isoformat())
")
FORGED="deadbeef0000000000000000000000000000aaaa"   # not a real object
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $FORGED
verdict: PASS
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "fresh + non-existent SHA → HEAD~1 ($result)"
elif [ "$result" = "$FORGED" ]; then
  _fail "non-existent SHA accepted unverified ($FORGED)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test 7 (GE-2): Fresh stamp + OTHER-BRANCH SHA (not ancestor of HEAD) → HEAD~1.
echo "### Test 7: GE2_fresh_stamp_other_branch_sha_falls_back_to_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit (main)"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
# Create a sibling branch commit that is NOT an ancestor of HEAD.
git -C "$S" checkout -q -b sidebranch HEAD~1
git -C "$S" commit --allow-empty -q -m "side commit"
OTHER_BRANCH_SHA=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q main
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
print((datetime.fromisoformat('$HEAD_ISO') + timedelta(hours=1)).isoformat())
")
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $OTHER_BRANCH_SHA
verdict: PASS
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "fresh + other-branch SHA (non-ancestor) → HEAD~1 ($result)"
elif [ "$result" = "$OTHER_BRANCH_SHA" ]; then
  _fail "other-branch non-ancestor SHA accepted ($OTHER_BRANCH_SHA)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test 8 (GE-2): Fresh stamp + ORPHAN commit SHA (no shared history) → HEAD~1.
echo "### Test 8: GE2_fresh_stamp_orphan_commit_sha_falls_back_to_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
git -C "$S" checkout -q --orphan orphanbranch
git -C "$S" commit --allow-empty -q -m "orphan root"
ORPHAN_SHA=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q main
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
print((datetime.fromisoformat('$HEAD_ISO') + timedelta(hours=1)).isoformat())
")
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $ORPHAN_SHA
verdict: PASS
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "fresh + orphan SHA (no shared history) → HEAD~1 ($result)"
elif [ "$result" = "$ORPHAN_SHA" ]; then
  _fail "orphan SHA accepted ($ORPHAN_SHA)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
