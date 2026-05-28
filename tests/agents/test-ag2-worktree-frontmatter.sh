#!/usr/bin/env bash
# tests/agents/test-ag2-worktree-frontmatter.sh
#
# AG-2 regression: feature-builder-worker.md frontmatter + worktree-cleanup.md
# 존재 + 일반 feature-builder 변형은 isolation:worktree 미보유 (overhead 회피).
#
# Scope IDs:
#   AG2-FEATURE-BUILDER-WORKER-WITH-ISOLATION-WORKTREE-FRONTMATTER
#   AG2-WORKTREE-CLEANUP-MANUAL-PROCEDURE-DOC-WITH-MARKER-RULE
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

WORKER="plugins/rein-core/agents/feature-builder-worker.md"
CLEANUP_DOC="plugins/rein-core/docs/worktree-cleanup.md"
GENERAL_AGENTS=(
  "plugins/rein-core/agents/feature-builder.md"
  "plugins/rein-core/agents/feature-builder-fix.md"
  "plugins/rein-core/agents/feature-builder-refactor.md"
)

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

echo "=== test-ag2-worktree-frontmatter ==="

# -----------------------------------------------------------------------
# (1) feature-builder-worker.md 존재 + frontmatter 검증
# -----------------------------------------------------------------------
echo ""
echo "[1] feature-builder-worker.md presence + frontmatter"

if [ -f "$WORKER" ]; then
  pass "$WORKER exists"
else
  fail "$WORKER MISSING"
fi

# frontmatter block (first --- ... --- pair) 추출
if [ -f "$WORKER" ]; then
  FRONT=$(awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$WORKER")

  if echo "$FRONT" | grep -qE '^name:\s*feature-builder-worker\s*$'; then
    pass "frontmatter has name: feature-builder-worker"
  else
    fail "frontmatter missing or wrong name: field"
  fi

  if echo "$FRONT" | grep -qE '^isolation:\s*worktree\s*$'; then
    pass "frontmatter has isolation: worktree (AG-2 literal)"
  else
    fail "frontmatter MISSING isolation: worktree literal"
  fi

  if echo "$FRONT" | grep -qE '^description:'; then
    pass "frontmatter has description field"
  else
    fail "frontmatter MISSING description field"
  fi
fi

# -----------------------------------------------------------------------
# (2) feature-builder-worker.md 본문 — cleanup doc reference + stamp refs
# -----------------------------------------------------------------------
echo ""
echo "[2] feature-builder-worker.md body references"

if [ -f "$WORKER" ]; then
  if grep -q "docs/worktree-cleanup.md" "$WORKER"; then
    pass "worker references docs/worktree-cleanup.md"
  else
    fail "worker MISSING docs/worktree-cleanup.md reference"
  fi

  if grep -q "\.codex-reviewed" "$WORKER"; then
    pass "worker references .codex-reviewed"
  else
    fail "worker MISSING .codex-reviewed reference"
  fi

  if grep -q "\.security-reviewed" "$WORKER"; then
    pass "worker references .security-reviewed"
  else
    fail "worker MISSING .security-reviewed reference"
  fi

  if grep -q "worker-marker.json" "$WORKER"; then
    pass "worker references .rein/worker-marker.json (cleanup marker)"
  else
    fail "worker MISSING worker-marker.json reference"
  fi
fi

# -----------------------------------------------------------------------
# (3) 일반 feature-builder 변형 — isolation: 키 미보유 (overhead 회피)
# -----------------------------------------------------------------------
echo ""
echo "[3] General feature-builder variants do NOT have isolation:"

for agent in "${GENERAL_AGENTS[@]}"; do
  if [ ! -f "$agent" ]; then
    fail "$agent MISSING (cannot verify)"
    continue
  fi
  # Check only frontmatter block (first --- ... --- pair)
  FRONT=$(awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$agent")
  if echo "$FRONT" | grep -qE '^isolation:'; then
    fail "$(basename "$agent"): has isolation: key in frontmatter (overhead — should be reserved for worker only)"
  else
    pass "$(basename "$agent"): no isolation: key (single-worktree, correct)"
  fi
done

# -----------------------------------------------------------------------
# (4) worktree-cleanup.md 존재 + 4 sections
# -----------------------------------------------------------------------
echo ""
echo "[4] worktree-cleanup.md presence + sections"

if [ -f "$CLEANUP_DOC" ]; then
  pass "$CLEANUP_DOC exists"
else
  fail "$CLEANUP_DOC MISSING"
fi

if [ -f "$CLEANUP_DOC" ]; then
  for section in "## 배경" "## Rein worktree 판별 마커" "## 수동 cleanup 절차" "## stamp 소유권 규칙"; do
    if grep -q "^${section}" "$CLEANUP_DOC"; then
      pass "cleanup doc has section: $section"
    else
      fail "cleanup doc MISSING section: $section"
    fi
  done

  # WorktreeCreate matcher 미지원 사유 명시 확인
  if grep -q "WorktreeCreate\|WorktreeRemove" "$CLEANUP_DOC"; then
    pass "cleanup doc cites WorktreeCreate/Remove matcher constraint"
  else
    fail "cleanup doc MISSING WorktreeCreate/Remove citation"
  fi

  # worker-marker.json schema 정의 확인
  if grep -q "worker-marker.json" "$CLEANUP_DOC" && grep -q "schema_version" "$CLEANUP_DOC"; then
    pass "cleanup doc defines worker-marker.json schema"
  else
    fail "cleanup doc MISSING worker-marker.json schema definition"
  fi
fi

echo ""
echo "======================================"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
