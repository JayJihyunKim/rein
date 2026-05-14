#!/usr/bin/env bash
# tests/scripts/test-rein-check-plugin-drift-boundary.sh
# Option C Phase 2 — boundary check + validator 흡수 + dead allowlist 제거 검증
#
# Plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md (Phase 2 Task 2.5)
# covers: [S1, S2, S3]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIFT="$REPO_ROOT/scripts/rein-check-plugin-drift.py"
WRAPPER="$REPO_ROOT/scripts/rein-validate-plugin-rules.py"

pass=0
fail=0

record_pass() {
  pass=$((pass + 1))
  echo "PASS: $1"
}
record_fail() {
  fail=$((fail + 1))
  echo "FAIL: $1" >&2
}

# T1 (S3): dead `skills/rules-prompt` allowlist 제거
echo "=== T1 (S3): dead allowlist 제거 ==="
if grep -E '(skills/rules-prompt|skills-rules-prompt)' "$DRIFT" >/dev/null 2>&1; then
  record_fail "T1: skills/rules-prompt allowlist 가 소스에 남아있음"
else
  record_pass "T1 (S3): skills/rules-prompt allowlist 제거 확인"
fi

# T2 (S1): boundary check — isolated fixture 의 shared 7 mirror 감지
# Option C Phase 3 (shared rule overlay 폐기) 이후 본 repo .claude/rules/ 에는
# shared rule mirror 가 없으므로, T2 는 tmpdir fixture 로 시나리오 격리 검증.
echo "=== T2 (S1): boundary check (isolated 7-mirror fixture) ==="
T2ROOT=$(mktemp -d)
trap 'rm -rf "$T2ROOT" "${TMPROOT:-}"' EXIT
mkdir -p "$T2ROOT/.claude/rules" "$T2ROOT/plugins/rein-core/rules" "$T2ROOT/plugins/rein-core/hooks"
for name in code-style security testing answer-only-mode subagent-review design-plan-coverage background-jobs; do
  echo "# $name" > "$T2ROOT/.claude/rules/$name.md"
done
out=$(python3 "$DRIFT" --repo-root "$T2ROOT" --skip-parity --skip-validation 2>&1)
rc=$?
shared_violations=$(printf '%s' "$out" | grep -c '^BOUNDARY:.*\.claude/rules/.*\.md$' || true)
if [ "$rc" = "1" ] && [ "$shared_violations" = "7" ]; then
  record_pass "T2 (S1): boundary check 가 shared 7 mirror 모두 감지"
else
  record_fail "T2 (S1): expected 7 shared boundary violations, got $shared_violations (rc=$rc)"
fi

# T3: boundary check — 임시 shared rule mirror 만 있을 때
echo "=== T3 (S1 추가): isolated shared rule mirror 시나리오 ==="
# 임시 repo root 만들어 shared rule mirror 1개만 두기
TMPROOT=$(mktemp -d)
mkdir -p "$TMPROOT/.claude/rules"
mkdir -p "$TMPROOT/plugins/rein-core/rules"
mkdir -p "$TMPROOT/plugins/rein-core/hooks"
echo "# Code Style Rules" > "$TMPROOT/.claude/rules/code-style.md"
out=$(python3 "$DRIFT" --repo-root "$TMPROOT" --skip-parity --skip-validation 2>&1)
rc=$?
if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'BOUNDARY:.*code-style.md'; then
  record_pass "T3 (S1): isolated mirror 감지 — exit 1 + stderr boundary 위반 path"
else
  record_fail "T3 (S1): isolated boundary 미작동 (rc=$rc)"
fi

# T4 (S1): dev-only rule 은 boundary 위반 아님 (overlay 에 있어도 OK)
echo "=== T4 (S1 negative): dev-only rule 은 OK ==="
rm "$TMPROOT/.claude/rules/code-style.md"
echo "# Branch Strategy" > "$TMPROOT/.claude/rules/branch-strategy.md"
out=$(python3 "$DRIFT" --repo-root "$TMPROOT" --skip-parity --skip-validation 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  record_pass "T4 (S1): dev-only rule 은 boundary 위반 아님"
else
  record_fail "T4 (S1): dev-only rule 이 잘못 boundary 위반 (rc=$rc)"
fi

# T5 (S2): validation 흡수 — 통합 도구로 validation 부분만 PASS
echo "=== T5 (S2): validation 흡수 ==="
out=$(python3 "$DRIFT" --skip-parity --skip-boundary 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  record_pass "T5 (S2): validation (mandate + inject envelope + conditional + hooks.json) PASS"
else
  record_fail "T5 (S2): validation fail (rc=$rc)"
fi

# T6 (S2): wrapper backward compat (rein-validate-plugin-rules.py)
echo "=== T6 (S2): wrapper backward compat ==="
out=$(python3 "$WRAPPER" 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
  record_pass "T6 (S2): wrapper PASS (validation 부분만 호출)"
else
  record_fail "T6 (S2): wrapper fail (rc=$rc)"
fi

# T7 (전체): 본 repo full check — Option C Phase 3 cleanup 이후 OK
# Phase 3 가 shared rule mirror 7 + overlay hooks/skills/agents 를 모두 폐기.
# 따라서 본 repo 의 full check 는 boundary 0 + parity OK + validation OK.
echo "=== T7 (S1 종합): post-cleanup repo full check ==="
out=$(python3 "$DRIFT" 2>&1)
rc=$?
violation_count=$(printf '%s' "$out" | grep -c '^BOUNDARY:' || true)
if [ "$rc" = "0" ] && [ "$violation_count" = "0" ]; then
  record_pass "T7 (S1): post-cleanup full check PASS (boundary 0, parity+validation OK)"
else
  record_fail "T7 (S1): expected post-cleanup PASS, got BOUNDARY $violation_count (rc=$rc)"
fi

# T8 (S5 invariant): .claude/rules/ 에 정확히 4 dev-only 파일만 잔존
# Phase 3 Task 3.6 가 shared 7 파일 삭제 후 dev-only 4 (branch-strategy /
# legacy-shipped-pending / readme-style / versioning) 만 남아야 함.
# T7 의 boundary check 는 stray non-shared 파일을 잡지 못하므로 별도 assertion.
echo "=== T8 (S5 invariant): dev-only 4 파일 정확 일치 ==="
expected_files="branch-strategy.md
legacy-shipped-pending.md
readme-style.md
versioning.md"
actual_files=$(cd "$REPO_ROOT/.claude/rules" && /bin/ls *.md 2>/dev/null | LC_ALL=C sort)
if [ "$actual_files" = "$expected_files" ]; then
  record_pass "T8 (S5): .claude/rules/ 가 정확히 4 dev-only 파일만 보유"
else
  record_fail "T8 (S5): expected exact 4 dev-only files, got:
$actual_files"
fi

# Summary
echo
echo "=========================================="
echo "test-rein-check-plugin-drift-boundary: pass=$pass fail=$fail"
echo "=========================================="
exit $fail
