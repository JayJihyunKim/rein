#!/usr/bin/env bash
# test-feature-builder-variants.sh — AG-1: feature-builder agent split parity.
#
# 배경: AG-1 (cc-feature-adoption Phase 1 Task 1.6) 에서 feature-builder 가
# 세 개의 변형 에이전트로 분리되었다:
#   - feature-builder       : add-feature / build-from-scratch 전담
#   - feature-builder-fix   : 버그 수정 전담 (reproduction-first 전략)
#   - feature-builder-refactor : 리팩토링 전담 (researcher-first 전략)
#
# 본 테스트가 검증하는 것:
#   (1) 세 에이전트 파일이 모두 존재한다.
#   (2) 각 파일의 frontmatter `name:` 이 정확한 값을 가진다.
#   (3) 세 파일 모두 공유 stamp 구조 참조를 포함한다
#       (.codex-reviewed 와 .security-reviewed 가 각각 언급되어야 한다).
#   (4) routing-procedure.md 에 DoD 키워드 → 변형 에이전트 감지 규칙이
#       존재한다 (버그/fix 키워드 → feature-builder-fix,
#                  refactor 키워드 → feature-builder-refactor).
#
# Scope ID: AG-1-feature-builder-split
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

AGENTS_DIR="plugins/rein-core/agents"
ROUTING="plugins/rein-core/rules/routing-procedure.md"

pass_count=0
fail_count=0

pass() {
  echo "  PASS: $1"
  pass_count=$((pass_count + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  fail_count=$((fail_count + 1))
}

echo "=== test-feature-builder-variants ==="

# -----------------------------------------------------------------------
# (1) 세 에이전트 파일 존재 확인
# -----------------------------------------------------------------------
echo ""
echo "[1] Agent file existence"

for agent_file in \
  "$AGENTS_DIR/feature-builder.md" \
  "$AGENTS_DIR/feature-builder-fix.md" \
  "$AGENTS_DIR/feature-builder-refactor.md"
do
  if [ -f "$agent_file" ]; then
    pass "$agent_file exists"
  else
    fail "$agent_file MISSING"
  fi
done

# -----------------------------------------------------------------------
# (2) frontmatter name: 값 검증
# -----------------------------------------------------------------------
echo ""
echo "[2] Frontmatter name: values"

check_name() {
  local file="$1"
  local expected_name="$2"
  if [ ! -f "$file" ]; then
    fail "cannot check name — file missing: $file"
    return
  fi
  # frontmatter 블록 내의 name: 라인 추출 (--- 으로 감싼 첫 블록)
  local actual
  actual=$(awk '/^---/{if(++n==2) exit} n==1 && /^name:/{print $2}' "$file" | head -1)
  if [ "$actual" = "$expected_name" ]; then
    pass "$(basename "$file"): name = $actual"
  else
    fail "$(basename "$file"): expected name=$expected_name, got name=$actual"
  fi
}

check_name "$AGENTS_DIR/feature-builder.md"           "feature-builder"
check_name "$AGENTS_DIR/feature-builder-fix.md"       "feature-builder-fix"
check_name "$AGENTS_DIR/feature-builder-refactor.md"  "feature-builder-refactor"

# -----------------------------------------------------------------------
# (3) 세 에이전트 모두 공유 stamp 구조 참조 포함
#     .codex-reviewed 와 .security-reviewed 가 각각 언급되어야 한다.
# -----------------------------------------------------------------------
echo ""
echo "[3] Shared stamp structure — .codex-reviewed + .security-reviewed in all three agents"

for agent_file in \
  "$AGENTS_DIR/feature-builder.md" \
  "$AGENTS_DIR/feature-builder-fix.md" \
  "$AGENTS_DIR/feature-builder-refactor.md"
do
  if [ ! -f "$agent_file" ]; then
    fail "cannot check stamp — file missing: $agent_file"
    continue
  fi
  base="$(basename "$agent_file")"
  if grep -q "\.codex-reviewed" "$agent_file"; then
    pass "$base: contains .codex-reviewed reference"
  else
    fail "$base: MISSING .codex-reviewed reference"
  fi
  if grep -q "\.security-reviewed" "$agent_file"; then
    pass "$base: contains .security-reviewed reference"
  else
    fail "$base: MISSING .security-reviewed reference"
  fi
done

# -----------------------------------------------------------------------
# (4) routing-procedure.md 에 키워드 → 변형 에이전트 감지 규칙 존재
# -----------------------------------------------------------------------
echo ""
echo "[4] routing-procedure.md — variant-agent keyword detection rule"

if [ ! -f "$ROUTING" ]; then
  fail "$ROUTING MISSING"
else
  # fix/bug 키워드 → feature-builder-fix 매핑
  if grep -q "feature-builder-fix" "$ROUTING"; then
    pass "routing-procedure.md: feature-builder-fix referenced"
  else
    fail "routing-procedure.md: MISSING feature-builder-fix mapping"
  fi

  # refactor 키워드 → feature-builder-refactor 매핑
  if grep -q "feature-builder-refactor" "$ROUTING"; then
    pass "routing-procedure.md: feature-builder-refactor referenced"
  else
    fail "routing-procedure.md: MISSING feature-builder-refactor mapping"
  fi

  # bug/fix 키워드 (한국어 포함) 가 명시되어 있어야 한다
  if grep -qE "(bug|버그|fix|수정)" "$ROUTING"; then
    pass "routing-procedure.md: bug/fix/버그/수정 keyword present"
  else
    fail "routing-procedure.md: MISSING bug/fix keyword detection"
  fi

  # refactor 키워드 (한국어 포함) 가 명시되어 있어야 한다
  if grep -qE "(refactor|리팩터|리팩토링)" "$ROUTING"; then
    pass "routing-procedure.md: refactor/리팩터/리팩토링 keyword present"
  else
    fail "routing-procedure.md: MISSING refactor keyword detection"
  fi

  # approved_by_user 확인 요구가 명시되어 있어야 한다
  if grep -q "approved_by_user" "$ROUTING"; then
    pass "routing-procedure.md: approved_by_user confirmation requirement present"
  else
    fail "routing-procedure.md: MISSING approved_by_user confirmation for variant selection"
  fi
fi

# -----------------------------------------------------------------------
# (5) feature-builder.md 의 범위가 add-feature/build-from-scratch 로 한정
#     (fix-bug 와 리팩토링을 더 이상 담당으로 나열하지 않아야 한다)
# -----------------------------------------------------------------------
echo ""
echo "[5] feature-builder.md scope narrowed — fix-bug and refactoring removed from scope"

if [ -f "$AGENTS_DIR/feature-builder.md" ]; then
  # 담당 섹션에서 fix-bug 제거 검증 (다른 에이전트로 위임 문구는 허용)
  if grep -q "feature-builder-fix" "$AGENTS_DIR/feature-builder.md" || \
     ! grep -qE "^- 버그 수정 \(fix-bug\)" "$AGENTS_DIR/feature-builder.md"; then
    pass "feature-builder.md: fix-bug no longer in own scope (delegated or removed)"
  else
    fail "feature-builder.md: still claims fix-bug as own scope without delegation"
  fi

  # 담당 섹션에서 refactoring 제거 검증
  if grep -q "feature-builder-refactor" "$AGENTS_DIR/feature-builder.md" || \
     ! grep -qE "^- 기존 코드 리팩토링" "$AGENTS_DIR/feature-builder.md"; then
    pass "feature-builder.md: refactoring no longer in own scope (delegated or removed)"
  else
    fail "feature-builder.md: still claims refactoring as own scope without delegation"
  fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "======================================"
echo "PASS: $pass_count  FAIL: $fail_count"
if [ "$fail_count" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
