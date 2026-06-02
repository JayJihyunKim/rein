#!/usr/bin/env bash
# tests/agents/test-plan-path-consistency.sh
#
# plan 경로 일관성 회귀: plan 작성 가이드가 skill 디렉토리에서 plugin docs/
# 절차 문서로 이전된 상태를 잠근다. 과거 `plugins/rein-core/skills/writing-plans/`
# 가 부재(a)하고, `docs/writing-plans-procedure.md` 가 frontmatter 없는 산문
# 문서로 존재(b)하며, plan-writer 에이전트가 새 docs 경로를 가리키고 옛 skill
# 경로 언급이 없음(c)을 검증한다. 라우팅 규칙 2곳도 `writing-plans` 토큰을
# 더는 노출하지 않으며 routing-map 은 byte 예산(<=800) 안에 머문다(d, e).
#
# 주의: assertion (c) 는 plan-writer.md 한 파일로 scope 한정 — docs/ 등의
# 역사적 언급으로 인한 false-fail 을 피한다.
#
# Scope ID: regression-test (plan-path-consistency)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

OLD_SKILL_DIR="plugins/rein-core/skills/writing-plans"
PROC_DOC="plugins/rein-core/docs/writing-plans-procedure.md"
PLAN_WRITER="plugins/rein-core/agents/plan-writer.md"
ROUTING_MAP="plugins/rein-core/rules/routing-map.md"
ROUTING_PROC="plugins/rein-core/rules/routing-procedure.md"

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

echo "=== test-plan-path-consistency ==="

# -----------------------------------------------------------------------
# (a) 옛 skill 디렉토리 부재
# -----------------------------------------------------------------------
echo ""
echo "[a] old skill dir ABSENT: $OLD_SKILL_DIR"

if [ ! -d "$OLD_SKILL_DIR" ]; then
  pass "$OLD_SKILL_DIR does not exist"
else
  fail "$OLD_SKILL_DIR STILL EXISTS"
fi

# -----------------------------------------------------------------------
# (b) 절차 문서 존재 + 첫 줄이 frontmatter 구분자('---') 가 아님
# -----------------------------------------------------------------------
echo ""
echo "[b] procedure doc present, no frontmatter first line: $PROC_DOC"

if [ -f "$PROC_DOC" ]; then
  first_line="$(head -n 1 "$PROC_DOC")"
  if [ "$first_line" != "---" ]; then
    pass "$PROC_DOC exists and first line is not '---'"
  else
    fail "$PROC_DOC first line IS frontmatter delimiter '---'"
  fi
else
  fail "$PROC_DOC MISSING"
fi

# -----------------------------------------------------------------------
# (c) plan-writer.md: 새 docs 경로 포함 + 옛 skill 경로 미포함
#     (scope 한정: plan-writer.md 한 파일)
# -----------------------------------------------------------------------
echo ""
echo "[c] plan-writer references new docs path, not old skill path"

if [ -f "$PLAN_WRITER" ]; then
  if grep -qF "$PROC_DOC" "$PLAN_WRITER"; then
    if ! grep -qF ".claude/skills/writing-plans" "$PLAN_WRITER"; then
      pass "$PLAN_WRITER references '$PROC_DOC' and not '.claude/skills/writing-plans'"
    else
      fail "$PLAN_WRITER still references '.claude/skills/writing-plans'"
    fi
  else
    fail "$PLAN_WRITER does NOT reference '$PROC_DOC'"
  fi
else
  fail "$PLAN_WRITER MISSING"
fi

# -----------------------------------------------------------------------
# (d) routing-map.md: 'writing-plans' 토큰 미포함 + byte 수 <= 800
# -----------------------------------------------------------------------
echo ""
echo "[d] routing-map: no 'writing-plans' token, <= 800 bytes"

if [ -f "$ROUTING_MAP" ]; then
  if ! grep -qF "writing-plans" "$ROUTING_MAP"; then
    bytes="$(wc -c < "$ROUTING_MAP" | tr -d '[:space:]')"
    if [ "$bytes" -le 800 ]; then
      pass "$ROUTING_MAP has no 'writing-plans' token and is $bytes bytes (<= 800)"
    else
      fail "$ROUTING_MAP is $bytes bytes (> 800)"
    fi
  else
    fail "$ROUTING_MAP still contains 'writing-plans' token"
  fi
else
  fail "$ROUTING_MAP MISSING"
fi

# -----------------------------------------------------------------------
# (e) routing-procedure.md: 'writing-plans' 토큰 미포함
# -----------------------------------------------------------------------
echo ""
echo "[e] routing-procedure: no 'writing-plans' token"

if [ -f "$ROUTING_PROC" ]; then
  if ! grep -qF "writing-plans" "$ROUTING_PROC"; then
    pass "$ROUTING_PROC has no 'writing-plans' token"
  else
    fail "$ROUTING_PROC still contains 'writing-plans' token"
  fi
else
  fail "$ROUTING_PROC MISSING"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "======================================"
TOTAL=$((PASS + FAIL))
echo "PASS: $PASS  FAIL: $FAIL  ($PASS/$TOTAL PASS)"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
