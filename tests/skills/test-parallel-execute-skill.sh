#!/usr/bin/env bash
# tests/skills/test-parallel-execute-skill.sh
#
# Phase 2 regression: parallel-execute SKILL.md presence + frontmatter +
# section/keyword contract (wave scheduler, worker dispatch contract, parent
# integration) + NFR body size <= 6144 bytes.
#
# Scope IDs:
#   EXEC-SKILL-WAVE-DETERMINISTIC-SCHEDULER-MUTATING-SOLO
#   EXEC-SKILL-WORKER-EDIT-ONLY-CONTRACT-RESULT-SCHEMA
#   EXEC-SKILL-PARENT-CLEAN-START-DELTA-VALIDATION-WAVE-COMMIT
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

SKILL="plugins/rein-core/skills/parallel-execute/SKILL.md"
SIZE_BUDGET=6144

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

# grep_body PATTERN LABEL  — fixed-string grep on the skill body
grep_body() {
  if grep -qF -- "$1" "$SKILL"; then
    pass "$2"
  else
    fail "$2 (missing literal: $1)"
  fi
}

echo "=== test-parallel-execute-skill ==="

# -----------------------------------------------------------------------
# (1) presence + frontmatter
# -----------------------------------------------------------------------
echo ""
echo "[1] SKILL.md presence + frontmatter"

if [ -f "$SKILL" ]; then
  pass "$SKILL exists"
else
  fail "$SKILL MISSING"
  # Cannot continue meaningfully without the file.
  echo ""
  echo "======================================"
  echo "PASS: $PASS  FAIL: $FAIL"
  echo "SOME CHECKS FAILED"
  exit 1
fi

# frontmatter block (first --- ... --- pair)
FRONT=$(awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$SKILL")

if echo "$FRONT" | grep -qE '^name:[[:space:]]*parallel-execute[[:space:]]*$'; then
  pass "frontmatter has name: parallel-execute"
else
  fail "frontmatter missing or wrong name: field"
fi

if echo "$FRONT" | grep -qE '^description:'; then
  pass "frontmatter has description field"
else
  fail "frontmatter MISSING description field"
fi

# -----------------------------------------------------------------------
# (2) Task 2.1 — wave derivation + deterministic scheduler keywords
# -----------------------------------------------------------------------
echo ""
echo "[2] wave derivation + deterministic scheduler keywords"

grep_body "위상정렬" "body has 위상정렬 (topo-sort)"
grep_body "ready" "body has ready (ready set)"
grep_body "mutating" "body has mutating"
grep_body "단독" "body has 단독 (mutating solo)"
grep_body "병렬 dispatch" "body has 병렬 dispatch"

# scheduler must consume the Phase 1 emitter as canonical-order SSOT
grep_body "rein-validate-coverage-matrix.py schedule" "scheduler consumes schedule emitter (SSOT)"

# -----------------------------------------------------------------------
# (3) Task 2.2 — worker dispatch contract + result schema keywords
# -----------------------------------------------------------------------
echo ""
echo "[3] worker dispatch contract + result schema keywords"

# common result schema keys (both variants)
grep_body "task_id" "result schema key task_id"
grep_body "status" "result schema key status"
grep_body "changed_files" "result schema key changed_files"
grep_body "blocked_reason" "result schema key blocked_reason"
grep_body "recommendation" "result schema key recommendation"
grep_body "summary" "result schema key summary"

# edit_only variant prohibitions
grep_body "커밋 금지" "edit_only forbids commit (커밋 금지)"
grep_body "stamp 금지" "edit_only forbids stamp (stamp 금지)"

# mutating variant
grep_body "변경성 명령 허용" "mutating allows mutating commands (변경성 명령 허용)"
grep_body "단독 웨이브" "mutating runs as solo wave (단독 웨이브)"
grep_body "예상 부작용 경로" "mutating scope includes side-effect paths (예상 부작용 경로)"

# -----------------------------------------------------------------------
# (4) Task 2.3 — parent integration (barrier) keywords
# -----------------------------------------------------------------------
echo ""
echo "[4] parent integration (barrier) keywords"

grep_body "클린" "parent: clean start (클린)"
grep_body "porcelain" "parent: porcelain delta source"
grep_body "델타" "parent: delta (델타)"
grep_body "부분집합" "parent: subset check (부분집합)"
grep_body "reject" "parent: reject on violation"
grep_body "웨이브당 1커밋" "parent: one commit per wave (웨이브당 1커밋)"

# literal commands the parent must run
grep_body "git status --porcelain" "parent: git status --porcelain literal"
grep_body "git ls-files --others --exclude-standard" "parent: untracked enumeration literal"

# security L1 carryover: path traversal + root containment (standard #7 reject set)
grep_body ".." "parent: .. normalization mentioned"
grep_body "containment" "parent: project-root containment check"
grep_body "절대경로" "parent: absolute path in reject set"
grep_body "realpath" "parent: realpath/symlink containment"

# -----------------------------------------------------------------------
# (5) NFR — body size <= 6144 bytes
# -----------------------------------------------------------------------
echo ""
echo "[5] NFR body size <= ${SIZE_BUDGET} bytes"

BYTES=$(wc -c < "$SKILL" | tr -d '[:space:]')
if [ "$BYTES" -le "$SIZE_BUDGET" ]; then
  pass "SKILL.md is ${BYTES} bytes (<= ${SIZE_BUDGET})"
else
  fail "SKILL.md is ${BYTES} bytes (> ${SIZE_BUDGET} budget)"
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
