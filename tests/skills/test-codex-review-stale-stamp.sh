#!/bin/bash
# tests/skills/test-codex-review-stale-stamp.sh
# Unit tests for scripts/rein-codex-review.sh::_resolve_diff_base
# (묶음 C — wrapper context lifecycle hardening, Phase 2 — 원 스위트 목적).
#
# Phase 7 웨이브 3 ③-d 전수 재조준. `_resolve_diff_base()` 의 legacy
# `trail/dod/.codex-reviewed` stamp 읽기 경로(fresh/stale 판정 + diff_base
# 필드 채택 + GE-2 조상 검증) 전체가 이 웨이브에서 제거됐다 — 함수는 이제
# 무조건 `HEAD~1` → (부재 시) 빈 트리 SHA 순으로만 판정한다
# (rein-codex-review.sh 자신의 "Phase 7 wave 3 ③-d" 주석 참조: "Dropping
# the stamp-preference branch is a no-op in practice, not a behavior
# change" — 원래도 stamp 의 staleness self-heal 이 HEAD 이동 직후 즉시
# stamp 를 버렸으므로, 사실상 stamp 경로가 항상 죽은 무게였다는 설명).
#
# 원 스위트의 8개 케이스(1~4, 6~8)는 전부 이 제거된 stamp 판정부(신선도
# 비교/파싱 실패 fail-safe/조상 위조 거부)를 검증했다 — 함수가 stamp 를
# 아예 읽지 않게 된 지금은 "정당 소멸": 무대체가 아니라, 아래 재구성된
# 4개 케이스(A~D)가 그 자리를 대체한다 — "stamp 내용이 무엇이든(신선하든
# 오래됐든 파싱 불가든 조작됐든) 완전히 무시되고 HEAD~1/빈 트리만 쓰인다"
# 는 단일 불변식으로 원 8개 케이스의 의도(신선도/파싱/위조 각각의 개별
# 판정 분기가 더 이상 존재하지 않는다는 사실 자체)를 전부 흡수한다. 원
# Test 5("stamp 없음 → HEAD~1")만 이 재조준에서도 그대로 유효해 Test A로
# 남는다.
#
# Scope IDs covered (④ 새 프레임 — 원 3개는 이 웨이브로 소멸, 후계 표기):
#   - wrapper-diff-base-unconditionally-head-tilde-1-ignores-any-stamp (신설,
#     구 wrapper-detects-stale-stamp-when-reviewed-at-iso-before-head-commit-iso
#     + wrapper-treats-iso-parse-failure-as-stale-fail-safe 의 후계 — 두
#     판정 분기 자체가 사라졌으므로 "무조건 무시" 로 흡수)
#   - wrapper-stale-stamp-falls-back-to-head-tilde-1-then-empty-tree (존속 —
#     이제 "stale" 조건 없이 항상 성립)
#
# Scenarios:
#   A. No stamp at all → HEAD~1 (regression, 원 Test 5 그대로)
#   B. No stamp, HEAD~1 absent (initial commit) → EMPTY_TREE_SHA (원 Test 4 를
#      stamp 없이 일반화 — 빈 트리 폴백 자체는 stamp 유무와 무관하다)
#   C. "그럴듯한" stamp(신선한 timestamp + 실제 조상 SHA인 diff_base, 원
#      Test 1/2/3 을 하나로 병합) → 완전히 무시되고 HEAD~1 그대로
#   D. 적대적 stamp(위조 SHA / 다른 브랜치 SHA / orphan SHA, 원 Test 6/7/8
#      을 하나로 병합) → 역시 완전히 무시되고 HEAD~1 그대로 (판정부 자체가
#      없으니 위조 인젝션 표면도 없다)

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

# Helper: build sandbox with git repo + selector lib stub.
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

# ---- Test A: No stamp at all → HEAD~1 (regression, 원 Test 5).
echo "### Test A: no_legacy_marker_present_falls_back_to_head_tilde_1"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
# No .codex-reviewed file (never written by anything anymore — ③-d).
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "no legacy marker → HEAD~1 ($result)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
rm -rf "$S"

# ---- Test B: No stamp, HEAD~1 absent (initial commit) → EMPTY_TREE_SHA.
echo "### Test B: no_legacy_marker_initial_commit_falls_back_to_empty_tree"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "only commit"
result=$(_get_diff_base "$S")
if [ "$result" = "$EMPTY_TREE_SHA" ]; then
  _pass "initial commit, no legacy marker → EMPTY_TREE_SHA"
else
  _fail "expected EMPTY_TREE_SHA=$EMPTY_TREE_SHA, got: $result"
fi
rm -rf "$S"

# ---- Test C: plausible-looking stamp (fresh timestamp + real ancestor SHA,
# consolidates original Tests 1/2/3) → still fully ignored, HEAD~1 wins.
echo "### Test C: plausible_legacy_marker_content_is_fully_ignored"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit"
git -C "$S" commit --allow-empty -q -m "third commit"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
h = datetime.fromisoformat('$HEAD_ISO')
print((h + timedelta(hours=1)).isoformat())
")
REAL_ANCESTOR=$(git -C "$S" rev-parse HEAD~1)
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $REAL_ANCESTOR
verdict: PASS
cycle: test
scope: test
active_dod: trail/dod/dod-foo.md
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "fresh-looking legacy marker ignored → HEAD~1 ($result)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1 regardless of marker content, got: $result"
fi
rm -rf "$S"

# ---- Test D: adversarial stamp content (forged / other-branch / orphan SHA
# in diff_base — consolidates original GE-2 Tests 6/7/8) → also fully
# ignored. There is no ancestor-verification branch to bypass anymore
# because the stamp is never read at all — this pins that the removal did
# not silently reopen a forgery-injection surface.
echo "### Test D: adversarial_legacy_marker_diff_base_is_fully_ignored"
S=$(_mksandbox)
git -C "$S" commit --allow-empty -q -m "first commit"
git -C "$S" commit --allow-empty -q -m "second commit (main)"
HEAD_TILDE_1=$(git -C "$S" rev-parse HEAD~1)
git -C "$S" checkout -q -b sidebranch HEAD~1
git -C "$S" commit --allow-empty -q -m "side commit"
OTHER_BRANCH_SHA=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q main
HEAD_ISO=$(git -C "$S" log -1 --format=%cI HEAD)
FRESH_ISO=$(python3 -c "
from datetime import datetime, timedelta
print((datetime.fromisoformat('$HEAD_ISO') + timedelta(hours=1)).isoformat())
")
FORGED_SHA="deadbeef0000000000000000000000000000aaaa"
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $OTHER_BRANCH_SHA
verdict: PASS
EOF
result=$(_get_diff_base "$S")
if [ "$result" = "$HEAD_TILDE_1" ]; then
  _pass "other-branch SHA in legacy marker ignored → HEAD~1 ($result)"
elif [ "$result" = "$OTHER_BRANCH_SHA" ]; then
  _fail "other-branch non-ancestor SHA leaked through ($OTHER_BRANCH_SHA)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result"
fi
# Re-check with a plain forged (non-existent object) SHA too — same sandbox,
# same HEAD, only the marker content differs.
cat > "$S/trail/dod/.codex-reviewed" <<EOF
reviewed_at: $FRESH_ISO
reviewer: codex
diff_base: $FORGED_SHA
verdict: PASS
EOF
result2=$(_get_diff_base "$S")
if [ "$result2" = "$HEAD_TILDE_1" ]; then
  _pass "forged non-existent SHA in legacy marker ignored → HEAD~1 ($result2)"
elif [ "$result2" = "$FORGED_SHA" ]; then
  _fail "forged non-existent SHA leaked through unverified ($FORGED_SHA)"
else
  _fail "expected HEAD~1=$HEAD_TILDE_1, got: $result2"
fi
rm -rf "$S"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
