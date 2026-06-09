#!/bin/bash
# tests/hooks/test-select-active-dod.sh
# Unit tests for .claude/hooks/lib/select-active-dod.sh (Plan A Phase 4 Task 4.1).
#
# Scope IDs covered:
#   - GI-dod-gate-active-dod-selection
#   - GI-dod-gate-selector-shared-with-codex-review (shared function exists)
#   - GI-dod-gate-cache-invalidation (no cache files created)
#
# Scenarios:
#   1. Tier 1 — .active-dod marker → blocking tier
#   2. Tier 2 — no marker + latest dod with '## 범위 연결'
#   3. Tier 0 — no candidates
#   4. Invalid marker → fallback to Tier 2 + incident log
#   5. Tie-breaker — same mtime, smaller slug wins

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-select-active-dod.sh"
echo ""

if [ ! -f "$LIB" ]; then
  _fail "select-active-dod lib not found: $LIB"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Helper: set up a sandbox with a trail/dod/ directory.
_mksandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/trail/dod"
  mkdir -p "$dir/.claude/cache"
  echo "$dir"
}

# Helper: source lib inside sandbox and run select_active_dod.
_run_select() {
  local sandbox="$1"
  (
    cd "$sandbox"
    # shellcheck disable=SC1090
    . "$LIB"
    select_active_dod
  )
}

# ---- Test 1: Tier 1 — .active-dod marker.
echo "### Test 1: tier1_activeDod마커_blocking"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-21-foo.md" <<'EOF'
# DoD foo
## 범위 연결
plan ref: docs/plans/foo.md
covers: [A1]
EOF
cat > "$S/trail/dod/.active-dod" <<EOF
path=trail/dod/dod-2026-04-21-foo.md
pinned_by=test
EOF
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "1" ] && [ "$path" = "trail/dod/dod-2026-04-21-foo.md" ]; then
  _pass "Tier 1 marker selected → tier=$tier path=$path"
else
  _fail "Tier 1 expected tier=1 path=.../foo.md, got tier=$tier path=$path"
fi
rm -rf "$S"

# ---- Test 1b (active-dod-marker-trust): marker → plan-less DoD (no '## 범위 연결')
# must still be honored as Tier 1. The marker is written on routing approval
# regardless of plan linkage; '## 범위 연결' is an OPTIONAL coverage section
# (design-plan-coverage.md), not an active-DoD qualifier. Regression for label
# pollution + Tier-0 commit block when the active work is a plan-less DoD.
echo "### Test 1b: tier1_마커_planless_dod_신뢰"
S=$(_mksandbox)
# Active work: a plan-less DoD with NO '## 범위 연결' section.
cat > "$S/trail/dod/dod-2026-06-09-planless.md" <<'EOF'
# DoD planless
## 범위
small fix, no plan
## 라우팅 추천
approved_by_user: true
EOF
# An OLDER plan-linked DoD a buggy selector would fall through to (Tier 2).
cat > "$S/trail/dod/dod-2026-06-04-planbased.md" <<'EOF'
# old plan-based dod
## 범위 연결
plan ref: docs/plans/old.md
covers: [O1]
EOF
touch -d '2026-06-04 10:00:00' "$S/trail/dod/dod-2026-06-04-planbased.md" 2>/dev/null \
  || touch -t 202606041000 "$S/trail/dod/dod-2026-06-04-planbased.md"
cat > "$S/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-2026-06-09-planless.md
pinned_by=test
EOF
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "1" ] && [ "$path" = "trail/dod/dod-2026-06-09-planless.md" ]; then
  _pass "marker → plan-less DoD honored as Tier 1 → tier=$tier path=$path"
else
  _fail "marker plan-less DoD should be Tier 1, got tier=$tier path=$path (bug: fell through to old plan-based DoD)"
fi
rm -rf "$S"

# ---- Test 2: Tier 2 — no marker, use latest DoD with 범위 연결.
echo "### Test 2: tier2_마커없음_advisory"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-20-bar.md" <<'EOF'
# old dod
## 범위 연결
plan ref: docs/plans/bar.md
covers: [B1]
EOF
# Make the second file newer by adding a small sleep (mtime resolution)
touch -d '2026-04-20 10:00:00' "$S/trail/dod/dod-2026-04-20-bar.md" 2>/dev/null \
  || touch -t 202604201000 "$S/trail/dod/dod-2026-04-20-bar.md"
cat > "$S/trail/dod/dod-2026-04-21-newer.md" <<'EOF'
# newer dod
## 범위 연결
plan ref: docs/plans/newer.md
covers: [N1]
EOF
touch -d '2026-04-21 10:00:00' "$S/trail/dod/dod-2026-04-21-newer.md" 2>/dev/null \
  || touch -t 202604211000 "$S/trail/dod/dod-2026-04-21-newer.md"
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "2" ] && [ "$path" = "trail/dod/dod-2026-04-21-newer.md" ]; then
  _pass "Tier 2 latest mtime → tier=$tier path=$path"
else
  _fail "Tier 2 expected tier=2 path=.../newer.md, got tier=$tier path=$path"
fi
rm -rf "$S"

# ---- Test 3: Tier 0 — no candidates (empty dir or DoDs without 범위 연결).
echo "### Test 3: tier0_후보없음"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-21-legacy.md" <<'EOF'
# legacy dod without 범위 연결
EOF
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "0" ] && [ -z "$path" ]; then
  _pass "Tier 0 no candidates → tier=$tier path=(empty)"
else
  _fail "Tier 0 expected tier=0 empty path, got tier=$tier path=$path"
fi
rm -rf "$S"

# ---- Test 4: Invalid marker (target file missing) → falls back to Tier 2 + log.
echo "### Test 4: tier1_무효마커_fallback_로그"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-21-real.md" <<'EOF'
# real dod
## 범위 연결
plan ref: docs/plans/real.md
covers: [R1]
EOF
cat > "$S/trail/dod/.active-dod" <<'EOF'
path=trail/dod/dod-does-not-exist.md
EOF
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "2" ] && [ "$path" = "trail/dod/dod-2026-04-21-real.md" ]; then
  _pass "invalid marker → fallback to Tier 2 tier=$tier path=$path"
else
  _fail "invalid marker → expected tier=2 real.md, got tier=$tier path=$path"
fi
# Also check the incident log was appended
log="$S/trail/incidents/invalid-active-dod-marker.log"
if [ -f "$log" ] && grep -q 'marker target does not exist' "$log"; then
  _pass "invalid marker logged to incident log"
else
  _fail "invalid marker log missing or wrong: $log"
fi
rm -rf "$S"

# ---- Test 4b (묶음 C Phase 3 회귀): multi-line `path=` marker — selector uses first line only.
# Scope: active-dod-marker-uses-first-path-line-only (selector half regression).
echo "### Test 4b: 마커_다중path라인_첫번째사용"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-21-first.md" <<'EOF'
# DoD first
## 범위 연결
plan ref: docs/plans/first.md
covers: [F1]
EOF
# Multi-line marker — first line is valid; second is bogus.
{
  echo "path=trail/dod/dod-2026-04-21-first.md"
  echo "path=trail/dod/dod-bogus-second-line.md"
} > "$S/trail/dod/.active-dod"
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "1" ] && [ "$path" = "trail/dod/dod-2026-04-21-first.md" ]; then
  _pass "selector reads first path= line only (multi-line marker) → tier=$tier path=$path"
else
  _fail "selector first-path-line contract failed — expected tier=1 first.md, got tier=$tier path=$path"
fi
rm -rf "$S"

# ---- Test 4c (GE-1): Tier 1 marker → EXTERNAL absolute path to a *valid* DoD
# (has `## 범위 연결`) must be rejected. Without containment validation the
# selector would grant Tier 1 blocking authority to a file outside the project.
echo "### Test 4c: GE-1_marker_external_absolute_valid_dod_rejected"
S=$(_mksandbox)
EXT=$(mktemp -d)
cat > "$EXT/evil-external-dod.md" <<'EOF'
# evil external dod
## 범위 연결
plan ref: x
covers: [E1]
EOF
# In-project fallback so a correct selector lands on Tier 2 (not Tier 0).
cat > "$S/trail/dod/dod-2026-05-22-fallback.md" <<'EOF'
# real fallback dod
## 범위 연결
plan ref: docs/plans/fallback.md
covers: [FB1]
EOF
printf 'path=%s\n' "$EXT/evil-external-dod.md" > "$S/trail/dod/.active-dod"
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "2" ] && [ "$path" = "trail/dod/dod-2026-05-22-fallback.md" ]; then
  _pass "external absolute valid-DoD marker → Tier 1 rejected, Tier 2 fallback (tier=$tier)"
else
  _fail "external valid-DoD marker should be rejected, got tier=$tier path=$path"
fi
log="$S/trail/incidents/invalid-active-dod-marker.log"
if [ -f "$log" ] && grep -qi 'containment' "$log"; then
  _pass "external marker logged with containment reason"
else
  _fail "external marker containment log missing: $log"
fi
rm -rf "$S" "$EXT"

# ---- Test 4d (GE-1): Tier 1 marker → `..` traversal to a *valid* sibling DoD
# must be rejected by the `..`-segment check.
echo "### Test 4d: GE-1_marker_dotdot_traversal_valid_dod_rejected"
S=$(_mksandbox)
# Sibling valid DoD reachable from CWD=$S via `../<basename>-evil.md`.
SIB="${S}-evil.md"
cat > "$SIB" <<'EOF'
# sibling evil dod
## 범위 연결
plan ref: x
covers: [S1]
EOF
cat > "$S/trail/dod/dod-2026-05-22-fallback.md" <<'EOF'
# real fallback dod
## 범위 연결
plan ref: docs/plans/fallback.md
covers: [FB1]
EOF
printf 'path=../%s\n' "$(basename "$SIB")" > "$S/trail/dod/.active-dod"
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
if [ "$tier" = "2" ]; then
  _pass "dotdot-traversal valid-DoD marker → Tier 1 rejected, Tier 2 fallback (tier=$tier)"
else
  _fail "dotdot marker should be rejected → Tier 2, got tier=$tier"
fi
if grep -qi 'containment' "$S/trail/incidents/invalid-active-dod-marker.log" 2>/dev/null; then
  _pass "dotdot marker logged with containment reason"
else
  _fail "dotdot marker containment log missing"
fi
rm -rf "$S" "$SIB"

# ---- Test 5: Cache file regression — no dod-gate-validator* should be created.
echo "### Test 5: cache파일_미생성"
S=$(_mksandbox)
cat > "$S/trail/dod/dod-2026-04-21-x.md" <<'EOF'
## 범위 연결
plan ref: docs/plans/x.md
covers: [X1]
EOF
_run_select "$S" >/dev/null
forbidden=$(find "$S/.claude/cache" -maxdepth 1 -name 'dod-gate-validator*' 2>/dev/null)
if [ -z "$forbidden" ]; then
  _pass "no dod-gate-validator* cache files created"
else
  _fail "forbidden cache files present: $forbidden"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
