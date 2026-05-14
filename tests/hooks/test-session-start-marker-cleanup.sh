#!/bin/bash
# tests/hooks/test-session-start-marker-cleanup.sh
# Unit tests for .claude/hooks/session-start-load-trail.sh `.active-dod` cleanup
# (묶음 C — wrapper context lifecycle hardening, Phase 3).
#
# Scope IDs covered:
#   - session-start-removes-dangling-active-dod-when-target-file-missing
#   - session-start-removes-active-dod-when-target-lacks-range-link-section
#   - session-start-removes-active-dod-when-target-archived-by-inbox-or-daily-exact-match
#   - session-start-rejects-and-removes-active-dod-when-path-violates-containment
#   - active-dod-marker-uses-first-path-line-only
#
# Scenarios:
#   1. target file missing → remove + log
#   2. target lacks `## 범위 연결` → remove + log
#   3a. archived inbox exact match → remove + log
#   3b. archived daily exact match (`# foo`) → remove + log
#   3c-3g. negative — suffix-substring 5 cases → preserve marker
#   3h. negative — slug regex metachar (`foo.bar.baz` vs `# fooXbarYbaz`) → preserve marker
#   4a-4e. path containment 5 cases (.. / absolute / metachars / symlink-escape / empty) → remove + log
#   5. (regression) valid + not archived → preserve marker
#   6. first-path-line — multiple `path=` lines → first line only

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/session-start-load-trail.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-session-start-marker-cleanup.sh"
echo ""

if [ ! -f "$HOOK" ]; then
  _fail "hook not found: $HOOK"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Helper: build sandbox with trail/dod/, trail/inbox/, trail/daily/, .claude/hooks/lib/.
_mksandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/trail/dod" "$dir/trail/inbox" "$dir/trail/daily" "$dir/trail/incidents"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/.claude/cache"
  cp "$PROJECT_DIR/.claude/hooks/lib/portable.sh" "$dir/.claude/hooks/lib/" 2>/dev/null
  echo "$dir"
}

# Helper: invoke hook with REIN_PROJECT_DIR_OVERRIDE.
_call_hook() {
  local sandbox="$1"
  REIN_PROJECT_DIR_OVERRIDE="$sandbox" \
    bash "$HOOK" >/dev/null 2>/dev/null
}

# Helper: write marker with given path content.
_write_marker() {
  local sandbox="$1"
  local content="$2"
  printf '%s\n' "$content" > "$sandbox/trail/dod/.active-dod"
}

# ---- Test 1: dangling target file missing.
echo "### Test 1: cleanup_removes_marker_when_target_file_missing"
S=$(_mksandbox)
_write_marker "$S" "path=trail/dod/dod-2026-04-01-nonexistent.md"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "target file missing" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed + log 'target file missing'"
else
  _fail "marker still present or log missing"
fi
rm -rf "$S"

# ---- Test 2: target lacks `## 범위 연결`.
echo "### Test 2: cleanup_removes_marker_when_target_lacks_range_link"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-nolink.md" <<'EOF'
# DoD without range link
some content but no required section
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-01-nolink.md"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "target lacks ## 범위 연결" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed + log 'lacks ## 범위 연결'"
else
  _fail "marker still present or log missing"
fi
rm -rf "$S"

# ---- Test 3a: archived inbox exact match.
echo "### Test 3a: cleanup_removes_marker_when_archived_inbox_exact_match"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
echo "completion record" > "$S/trail/inbox/2026-04-01-foo.md"
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "archived: matching inbox" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (inbox match)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 3b: archived daily exact heading.
echo "### Test 3b: cleanup_removes_marker_when_archived_daily_exact_heading"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-bar.md" <<'EOF'
# DoD bar
## 범위 연결
plan ref: docs/plans/bar.md
covers: [bar-id]
EOF
cat > "$S/trail/daily/2026-04-01.md" <<'EOF'
# bar
some completion content
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-01-bar.md"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "archived: matching daily" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (daily heading match)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 3c: negative — inbox suffix `bar-foo.md` should NOT match `foo`.
echo "### Test 3c: cleanup_preserves_marker_when_inbox_suffix_substring"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
echo "unrelated" > "$S/trail/inbox/2026-04-01-bar-foo.md"
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (suffix substring not matched)"
else
  _fail "marker incorrectly removed (false positive on bar-foo.md)"
fi
rm -rf "$S"

# ---- Test 3d: negative — inbox `my-foo.md` should NOT match `foo`.
echo "### Test 3d: cleanup_preserves_marker_when_inbox_prefix_substring"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
echo "unrelated" > "$S/trail/inbox/2026-04-01-my-foo.md"
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (prefix substring not matched)"
else
  _fail "marker incorrectly removed (false positive on my-foo.md)"
fi
rm -rf "$S"

# ---- Test 3e: negative — daily heading `# foo-2` should NOT match `foo`.
echo "### Test 3e: cleanup_preserves_marker_when_daily_heading_suffix_substring"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
cat > "$S/trail/daily/2026-04-01.md" <<'EOF'
# foo-2
unrelated content
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (foo-2 heading not matched)"
else
  _fail "marker incorrectly removed (false positive on foo-2)"
fi
rm -rf "$S"

# ---- Test 3f: negative — daily heading `# my-foo workaround` should NOT match.
echo "### Test 3f: cleanup_preserves_marker_when_daily_heading_prefix_substring"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
cat > "$S/trail/daily/2026-04-01.md" <<'EOF'
# my-foo workaround
unrelated content
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (my-foo heading not matched)"
else
  _fail "marker incorrectly removed (false positive on my-foo)"
fi
rm -rf "$S"

# ---- Test 3g: negative — daily heading `# foo archived` should NOT match.
echo "### Test 3g: cleanup_preserves_marker_when_daily_heading_trailing_text"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-01-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
cat > "$S/trail/daily/2026-04-01.md" <<'EOF'
# foo archived
unrelated content
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-01-foo.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (foo archived heading not matched)"
else
  _fail "marker incorrectly removed (false positive on '# foo archived')"
fi
rm -rf "$S"

# ---- Test 3h: slug regex metachar — `.` 가 ERE wildcard 로 false-match 되지 않음.
# Security finding fix: SLUG="foo.bar.baz" 가 daily heading "# fooXbarYbaz" 와
# ERE 로 매칭되면 안 됨. awk literal compare 가 정상 동작하면 marker 보존.
echo "### Test 3h: cleanup_preserves_marker_when_slug_metachar_does_not_match_literal_daily_heading"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-27-foo.bar.baz.md" <<'EOF'
# DoD with metachar slug
## 범위 연결
plan ref: docs/plans/x.md
covers: [foo-bar-baz]
EOF
# Daily heading is "# fooXbarYbaz" — would ERE-match `foo.bar.baz` (`.` = wildcard).
echo "# fooXbarYbaz" > "$S/trail/daily/2026-04-26.md"
_write_marker "$S" "path=trail/dod/dod-2026-04-27-foo.bar.baz.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker preserved (literal SLUG vs ERE-substr daily heading)"
else
  _fail "marker incorrectly removed (regex metachar false-match)"
fi
rm -rf "$S"

# ---- Test 4a: path containment — `..` segment.
echo "### Test 4a: cleanup_rejects_marker_with_dotdot_segment"
S=$(_mksandbox)
_write_marker "$S" "path=../../etc/passwd"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q ".. segment" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (.. segment)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 4b: path containment — absolute path (metachars / leading slash).
echo "### Test 4b: cleanup_rejects_marker_with_absolute_path"
S=$(_mksandbox)
_write_marker "$S" "path=/etc/passwd"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   ( grep -q "metachars" "$S/trail/incidents/active-dod-cleanup.log" || \
     grep -q "outside PROJECT_DIR" "$S/trail/incidents/active-dod-cleanup.log" ); then
  _pass "marker removed (absolute path)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 4c: path containment — metachars (semicolon / shell injection).
echo "### Test 4c: cleanup_rejects_marker_with_metachars"
S=$(_mksandbox)
_write_marker "$S" "path=trail/dod/dod-foo.md;rm -rf /"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "metachars" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (shell metachars rejected)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 4d: path containment — symlink escape (realpath/commonpath rejection).
# Plan Task 3.4 명세. realpath 가 sandbox 외부로 resolve 시 commonpath != PROJECT_DIR 거부.
echo "### Test 4d: cleanup_rejects_marker_when_symlink_resolves_outside_project_dir"
S=$(_mksandbox)
# Arrange: symlink target = /etc/passwd (sandbox 외부, 실재 파일).
ln -s /etc/passwd "$S/trail/dod/escape-link.md"
_write_marker "$S" "path=trail/dod/escape-link.md"
# Act
_call_hook "$S"
# Assert: realpath/commonpath 가 sandbox 외부로 판정 → marker 삭제 + log.
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "outside PROJECT_DIR" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (symlink escape rejected by commonpath)"
else
  _fail "marker still present or wrong log (expected 'outside PROJECT_DIR')"
fi
rm -rf "$S"

# ---- Test 4e: empty path (malformed marker — first-path-line fail-safe).
echo "### Test 4e: cleanup_rejects_marker_with_empty_path"
S=$(_mksandbox)
printf '\n' > "$S/trail/dod/.active-dod"
_call_hook "$S"
if [ ! -f "$S/trail/dod/.active-dod" ] && \
   grep -q "empty path" "$S/trail/incidents/active-dod-cleanup.log" 2>/dev/null; then
  _pass "marker removed (empty path)"
else
  _fail "marker still present or wrong log"
fi
rm -rf "$S"

# ---- Test 5: regression — valid target + not archived → preserve.
echo "### Test 5: cleanup_preserves_marker_when_target_valid_and_not_archived"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-27-active.md" <<'EOF'
# DoD active
## 범위 연결
plan ref: docs/plans/active.md
covers: [active-id]
EOF
_write_marker "$S" "path=trail/dod/dod-2026-04-27-active.md"
_call_hook "$S"
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "valid marker preserved"
else
  _fail "valid marker incorrectly removed"
fi
rm -rf "$S"

# ---- Test 6: first-path-line — multiple path= lines, first wins.
echo "### Test 6: cleanup_uses_first_path_line_only_when_multiple_lines"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-27-first.md" <<'EOF'
# DoD first
## 범위 연결
plan ref: docs/plans/first.md
covers: [first-id]
EOF
# Multi-line marker — first line is valid; second is bogus.
{
  echo "path=trail/dod/dod-2026-04-27-first.md"
  echo "path=trail/dod/dod-bogus-second.md"
} > "$S/trail/dod/.active-dod"
_call_hook "$S"
# Valid first line + valid target + not archived → preserved.
if [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "first path= line used; bogus second line ignored; marker preserved"
else
  _fail "marker removed — first-line contract failed"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
