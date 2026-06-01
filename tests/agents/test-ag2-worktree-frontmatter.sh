#!/usr/bin/env bash
# tests/agents/test-ag2-worktree-frontmatter.sh
#
# WORKTREE-MACHINERY-DISCARD regression (Phase 3 / Task 3.3):
# feature-builder-worker.md is now a SAME-TREE edit-only parallel worker.
# The worktree machinery (isolation:worktree frontmatter, worker-marker.json,
# worker-result.json, git worktree, cleanup) and the worktree-cleanup.md doc
# are DISCARDED. The worker reports via a structured result returned as its
# final message (Phase 2 parallel-execute 6-key schema).
#
# Scope ID:
#   WORKTREE-MACHINERY-DISCARD
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

echo "=== test-ag2-worktree-frontmatter (same-tree edit-only worker) ==="

# -----------------------------------------------------------------------
# (1) feature-builder-worker.md exists + frontmatter has NO isolation:worktree
# -----------------------------------------------------------------------
echo ""
echo "[1] feature-builder-worker.md presence + frontmatter (no worktree isolation)"

if [ -f "$WORKER" ]; then
  pass "$WORKER exists"
else
  fail "$WORKER MISSING"
fi

# frontmatter block (first --- ... --- pair) extraction
if [ -f "$WORKER" ]; then
  FRONT=$(awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$WORKER")

  if echo "$FRONT" | grep -qE '^name:\s*feature-builder-worker\s*$'; then
    pass "frontmatter has name: feature-builder-worker"
  else
    fail "frontmatter missing or wrong name: field"
  fi

  if echo "$FRONT" | grep -qE '^isolation:\s*worktree\s*$'; then
    fail "frontmatter still has isolation: worktree (must be removed — same-tree model)"
  else
    pass "frontmatter has NO isolation: worktree (same-tree model)"
  fi

  if echo "$FRONT" | grep -qE '^description:'; then
    pass "frontmatter has description field"
  else
    fail "frontmatter MISSING description field"
  fi
fi

# -----------------------------------------------------------------------
# (2) body has NO worktree machinery references
# -----------------------------------------------------------------------
echo ""
echo "[2] feature-builder-worker.md body has NO worktree machinery"

if [ -f "$WORKER" ]; then
  for token in "worker-marker.json" "worker-result.json" "git worktree" "cleanup"; do
    if grep -qi "$token" "$WORKER"; then
      fail "worker still references discarded machinery: '$token'"
    else
      pass "worker has NO reference to '$token'"
    fi
  done
fi

# -----------------------------------------------------------------------
# (3) body has the same-tree edit-only contract + structured result schema
# -----------------------------------------------------------------------
echo ""
echo "[3] feature-builder-worker.md body has edit-only contract + result schema"

if [ -f "$WORKER" ]; then
  if grep -q "edit_only" "$WORKER"; then
    pass "worker declares edit_only mode"
  else
    fail "worker MISSING edit_only"
  fi

  if grep -q "선언 scope" "$WORKER"; then
    pass "worker restricts editing to 선언 scope (declared scope)"
  else
    fail "worker MISSING '선언 scope' (declared-scope restriction)"
  fi

  if grep -q "커밋 금지" "$WORKER"; then
    pass "worker prohibits commit (커밋 금지)"
  else
    fail "worker MISSING '커밋 금지' (commit prohibition)"
  fi

  if grep -q "구조화 결과" "$WORKER"; then
    pass "worker returns 구조화 결과 (structured result)"
  else
    fail "worker MISSING '구조화 결과' (structured result)"
  fi

  # Phase 2 6-key result schema must be present (returned as final message)
  for key in "task_id" "status" "changed_files" "blocked_reason" "recommendation" "summary"; do
    if grep -q "$key" "$WORKER"; then
      pass "worker result schema includes key: $key"
    else
      fail "worker result schema MISSING key: $key"
    fi
  done
fi

# -----------------------------------------------------------------------
# (4) general feature-builder variants still have NO isolation: key
# -----------------------------------------------------------------------
echo ""
echo "[4] General feature-builder variants do NOT have isolation:"

for agent in "${GENERAL_AGENTS[@]}"; do
  if [ ! -f "$agent" ]; then
    fail "$agent MISSING (cannot verify)"
    continue
  fi
  FRONT=$(awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$agent")
  if echo "$FRONT" | grep -qE '^isolation:'; then
    fail "$(basename "$agent"): has isolation: key in frontmatter (should have none)"
  else
    pass "$(basename "$agent"): no isolation: key (correct)"
  fi
done

# -----------------------------------------------------------------------
# (5) worktree-cleanup.md is DISCARDED (must not exist)
# -----------------------------------------------------------------------
echo ""
echo "[5] worktree-cleanup.md is discarded"

if [ -f "$CLEANUP_DOC" ]; then
  fail "$CLEANUP_DOC STILL EXISTS (must be deleted — worktree machinery discarded)"
else
  pass "$CLEANUP_DOC does not exist (discarded)"
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
