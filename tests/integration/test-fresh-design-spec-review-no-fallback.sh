#!/bin/bash
# tests/integration/test-fresh-design-spec-review-no-fallback.sh
# End-to-end regression for 묶음 C — wrapper context lifecycle hardening.
#
# Reproduces the 5-time recurrence pattern (group 8 item 3) at integration level:
#   - Fresh design + new DoD + routing approval → wrapper picks Tier 1 (correct DoD),
#     no Tier 2 fallback to unrelated stale DoD.
#   - Stale stamp + new commit → wrapper self-heals (HEAD~1 base, not stamp's stale base).
#
# Ties together:
#   - plugins/rein-core/hooks/post-edit-dod-routing-check.sh (Phase 1 auto-write)
#   - plugins/rein-core/hooks/session-start-load-trail.sh (Phase 3 cleanup)
#   - plugins/rein-core/hooks/lib/select-active-dod.sh (Tier 1/2 selection)
#   - scripts/rein-codex-review.sh::_resolve_diff_base (Phase 2 self-healing)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_DIR/scripts/rein-codex-review.sh"
SELECTOR_LIB="$PROJECT_DIR/plugins/rein-core/hooks/lib/select-active-dod.sh"
POST_WRITE_HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-dod-routing-check.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "## test-fresh-design-spec-review-no-fallback.sh"
echo ""

# Helper: build sandbox repo with full hook layout.
_mksandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/trail/dod" "$dir/trail/inbox" "$dir/trail/daily" "$dir/trail/incidents"
  mkdir -p "$dir/.claude/hooks/lib"
  # Copy the full lib/ tree so newly-added helpers (project-dir.sh, etc.)
  # source-resolve cleanly without per-helper additions here.
  cp -R "$PROJECT_DIR/plugins/rein-core/hooks/lib/." "$dir/.claude/hooks/lib/" 2>/dev/null
  cp "$POST_WRITE_HOOK" "$dir/.claude/hooks/"
  git -C "$dir" init -q -b main 2>/dev/null
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Tester
  echo "$dir"
}

# Helper: invoke select_active_dod from sandbox.
_run_select() {
  local sandbox="$1"
  (
    cd "$sandbox" || exit 1
    . "$sandbox/.claude/hooks/lib/select-active-dod.sh"
    select_active_dod
  )
}

# Helper: invoke wrapper as subshell + capture DIFF_BASE.
_get_diff_base() {
  local sandbox="$1"
  REIN_PROJECT_DIR_OVERRIDE="$sandbox" bash -c '
    cd "$1" || exit 1
    . "$2" </dev/null 2>/dev/null
    printf "%s" "$DIFF_BASE"
  ' _ "$sandbox" "$WRAPPER"
}

# Helper: invoke post-write hook (auto-write).
_call_post_write() {
  local sandbox="$1"
  local file_path="$2"
  REIN_PROJECT_DIR_OVERRIDE="$sandbox" \
    bash "$sandbox/.claude/hooks/post-edit-dod-routing-check.sh" <<EOF 2>/dev/null
{"tool_input":{"file_path":"$file_path"}}
EOF
}

# ============================================================
# Scenario 1: Fresh design + new DoD + routing approval
# Pre-fix: Tier 2 fallback to stale unrelated DoD
# Post-fix: Tier 1 with auto-written marker
# ============================================================
echo "### Scenario 1: fresh_design_with_routing_approval_picks_tier_1"
S=$(_mksandbox)

# Old completed DoD (would be Tier 2 fallback target without fix).
cat > "$S/trail/dod/dod-2026-04-20-old-stale.md" <<'EOF'
# DoD old-stale (completed last week)
## 범위 연결
plan ref: docs/plans/old.md
covers: [old-id]
EOF
touch -t 202604201000 "$S/trail/dod/dod-2026-04-20-old-stale.md" 2>/dev/null

# New DoD with routing approval.
NEW_DOD="$S/trail/dod/dod-2026-04-27-new-work.md"
cat > "$NEW_DOD" <<'EOF'
# DoD new-work (current)
## 라우팅 추천
```yaml
agent: feature-builder
approved_by_user: true
```
## 범위 연결
plan ref: docs/plans/new.md
covers: [new-id]
EOF
touch -t 202604271000 "$NEW_DOD" 2>/dev/null  # newer mtime than old-stale

# Trigger Phase 1 auto-write hook.
_call_post_write "$S" "$NEW_DOD"

# Verify .active-dod was created with new DoD path.
if [ -f "$S/trail/dod/.active-dod" ]; then
  marker=$(cat "$S/trail/dod/.active-dod")
  expected="path=trail/dod/dod-2026-04-27-new-work.md"
  if [ "$marker" = "$expected" ]; then
    _pass "Phase 1 auto-write created marker for new work DoD"
  else
    _fail "marker content mismatch — got: $marker"
  fi
else
  _fail "Phase 1 auto-write did NOT create marker"
fi

# Verify select_active_dod picks Tier 1 (the new DoD), NOT Tier 2 (old-stale).
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s' "$result" | cut -f2)
if [ "$tier" = "1" ] && [ "$path" = "trail/dod/dod-2026-04-27-new-work.md" ]; then
  _pass "select_active_dod returns Tier 1 with new work DoD"
elif [ "$tier" = "2" ] && [ "$path" = "trail/dod/dod-2026-04-20-old-stale.md" ]; then
  _fail "5번 재현 패턴 재발 — Tier 2 fallback to old-stale DoD"
else
  _fail "unexpected tier=$tier path=$path"
fi
rm -rf "$S"

# ============================================================
# Scenario 2: Stale stamp + new commit
# Pre-fix: wrapper used stale stamp.diff_base → false freshness HIGH
# Post-fix: wrapper detects stale ISO, falls back to HEAD~1
# ============================================================
echo "### Scenario 2: stale_stamp_after_new_commit_self_heals_to_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit (review base)"
git -C "$S" commit --allow-empty -q -m "second commit (after PASS)"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
STALE_BASE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# Stamp from past PASS — stored diff_base no longer valid for current HEAD.
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: 2020-01-01T00:00:00Z
reviewer: codex
diff_base: $STALE_BASE
verdict: PASS
cycle: old-cycle
scope: old
active_dod: trail/dod/dod-old.md
EOF

# Wrapper computes DIFF_BASE — Phase 2 self-healing should pick HEAD~1, not stale.
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "Phase 2 self-heal: stale stamp detected, fell back to HEAD~1"
elif [ "$result" = "$STALE_BASE" ]; then
  _fail "5번 재현 패턴 재발 — wrapper used stale stamp.diff_base"
else
  _fail "unexpected diff_base: $result (expected HEAD~1=$HEAD_TILDE_1)"
fi
rm -rf "$S"

# ============================================================
# Scenario 3: Cleanup of dangling marker (lifecycle exit)
# Pre-fix: stale .active-dod from prior session pointed to gone DoD
# Post-fix: session-start cleanup removes invalid markers
# ============================================================
echo "### Scenario 3: session_start_cleans_up_dangling_marker_from_prior_session"
S=$(_mksandbox)

# Marker from prior session pointing to non-existent DoD.
echo "path=trail/dod/dod-2026-03-01-gone.md" > "$S/trail/dod/.active-dod"

# Invoke session-start hook.
REIN_PROJECT_DIR_OVERRIDE="$S" \
  bash "$PROJECT_DIR/plugins/rein-core/hooks/session-start-load-trail.sh" >/dev/null 2>/dev/null

if [ ! -f "$S/trail/dod/.active-dod" ]; then
  _pass "Phase 3 cleanup removed dangling marker"
else
  _fail "dangling marker NOT cleaned up"
fi

# After cleanup, select_active_dod should fall through to Tier 0.
result=$(_run_select "$S")
tier=$(printf '%s' "$result" | cut -f1)
if [ "$tier" = "0" ]; then
  _pass "after cleanup, no candidate DoD → Tier 0 (no false fallback)"
else
  _fail "expected Tier 0 after cleanup, got tier=$tier"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
