#!/bin/bash
# tests/hooks/test-active-dod-auto-write.sh
# Unit tests for .claude/hooks/post-write-dod-routing-check.sh auto-write extension
# (묶음 C — wrapper context lifecycle hardening, Phase 1).
#
# Scope IDs covered:
#   - active-dod-auto-write-on-routing-approval-creates-marker-with-target-path
#   - active-dod-write-uses-mktemp-rename-atomic-with-no-partial-read
#   - active-dod-write-skipped-when-approval-line-not-in-routing-section
#
# Scenarios:
#   1. routing approval (in section) + approved_by_user: true → marker created
#   2. atomic write — concurrent reader sees no partial line / empty file
#   3. skip when approved_by_user: pending (in section)
#   4. skip when approved_by_user: true is OUTSIDE routing section
#   5. skip when approved_by_user: false (in section)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/.claude/hooks/post-write-dod-routing-check.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-active-dod-auto-write.sh"
echo ""

if [ ! -f "$HOOK" ]; then
  _fail "hook not found: $HOOK"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Helper: create sandbox with isolated trail/dod/.
_mksandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/trail/dod"
  echo "$dir"
}

# Helper: invoke hook with REIN_PROJECT_DIR_OVERRIDE.
# stdin = JSON {"tool_input":{"file_path":"<path>"}}
_call_hook() {
  local sandbox="$1"
  local file_path="$2"
  REIN_PROJECT_DIR_OVERRIDE="$sandbox" \
    bash "$HOOK" <<EOF 2>/dev/null
{"tool_input":{"file_path":"$file_path"}}
EOF
}

# ---- Test 1: routing approval (in section) creates marker.
echo "### Test 1: auto_write_routing_section_approved_creates_marker"
S=$(_mksandbox)
DOD="$S/trail/dod/dod-2026-04-27-test-foo.md"
cat > "$DOD" <<'EOF'
# DoD test-foo
## 라우팅 추천
```yaml
agent: feature-builder
skills: [codex-review]
approved_by_user: true
```
## 범위 연결
plan ref: docs/plans/foo.md
covers: [foo-id]
EOF
_call_hook "$S" "$DOD"
if [ -f "$S/trail/dod/.active-dod" ]; then
  expected="path=trail/dod/dod-2026-04-27-test-foo.md"
  actual=$(cat "$S/trail/dod/.active-dod")
  if [ "$actual" = "$expected" ]; then
    _pass "marker created with correct path"
  else
    _fail "marker content mismatch — expected '$expected', got '$actual'"
  fi
else
  _fail "marker not created"
fi
rm -rf "$S"

# ---- Test 2: atomic write — concurrent reader sees no partial content.
echo "### Test 2: auto_write_atomic_no_partial_read"
S=$(_mksandbox)
DOD="$S/trail/dod/dod-2026-04-27-atomic.md"
cat > "$DOD" <<'EOF'
# DoD atomic
## 라우팅 추천
```yaml
approved_by_user: true
```
EOF

# Reader loop in background — captures any non-empty read.
READER_OUT=$(mktemp)
(
  for _ in $(seq 1 50); do
    if [ -f "$S/trail/dod/.active-dod" ]; then
      cat "$S/trail/dod/.active-dod" >> "$READER_OUT" 2>/dev/null
      printf '\n---\n' >> "$READER_OUT"
    fi
  done
) &
READER_PID=$!

_call_hook "$S" "$DOD"
sleep 0.1
kill "$READER_PID" 2>/dev/null
wait "$READER_PID" 2>/dev/null

# Verify: every non-empty captured snapshot is exactly the full canonical line.
# Acceptable lines: empty (file not yet present) or `path=trail/dod/dod-2026-04-27-atomic.md`.
PARTIAL=0
while IFS= read -r line; do
  case "$line" in
    "" | "---" | "path=trail/dod/dod-2026-04-27-atomic.md") ;;
    *) PARTIAL=1; break ;;
  esac
done < "$READER_OUT"

if [ "$PARTIAL" = "0" ] && [ -f "$S/trail/dod/.active-dod" ]; then
  _pass "no partial content observed by concurrent reader"
else
  _fail "partial content observed (PARTIAL=$PARTIAL); reader log:"
  head -20 "$READER_OUT" >&2
fi

rm -f "$READER_OUT"
rm -rf "$S"

# ---- Test 3: skip when approved_by_user: pending.
echo "### Test 3: auto_write_skipped_when_pending"
S=$(_mksandbox)
DOD="$S/trail/dod/dod-2026-04-27-pending.md"
cat > "$DOD" <<'EOF'
# DoD pending
## 라우팅 추천
```yaml
approved_by_user: pending
```
EOF
_call_hook "$S" "$DOD"
if [ ! -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker NOT created (approved_by_user: pending)"
else
  _fail "marker incorrectly created for pending approval"
fi
rm -rf "$S"

# ---- Test 4: skip when approved_by_user: true is OUTSIDE routing section.
echo "### Test 4: auto_write_skipped_when_outside_routing_section"
S=$(_mksandbox)
DOD="$S/trail/dod/dod-2026-04-27-outside.md"
cat > "$DOD" <<'EOF'
# DoD outside
## 라우팅 추천
```yaml
approved_by_user: pending
```

## 본문
```
approved_by_user: true
```
This text mentions approved_by_user: true outside the routing section.
EOF
_call_hook "$S" "$DOD"
if [ ! -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker NOT created (approved_by_user: true outside section)"
else
  _fail "marker incorrectly created — section-scoped grep failed"
fi
rm -rf "$S"

# ---- Test 5: skip when approved_by_user: false.
echo "### Test 5: auto_write_skipped_when_false"
S=$(_mksandbox)
DOD="$S/trail/dod/dod-2026-04-27-false.md"
cat > "$DOD" <<'EOF'
# DoD false
## 라우팅 추천
```yaml
approved_by_user: false
```
EOF
_call_hook "$S" "$DOD"
if [ ! -f "$S/trail/dod/.active-dod" ]; then
  _pass "marker NOT created (approved_by_user: false)"
else
  _fail "marker incorrectly created for false approval"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
