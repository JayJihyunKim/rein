#!/usr/bin/env bash
# tests/scripts/test-plugin-drift-detection.sh — Option C Phase 2 갱신 (2026-05-13)
#
# Verifies scripts/rein-check-plugin-drift.py parity check:
#   A. On the live tree, parity check (with boundary + validation skipped)
#      exits 0.
#   B. Hash mismatch fixture (same file path in both, different content) →
#      exit 1 + HASH-MISMATCH line.
#   C. Overlay-only fixture (file in `.claude/` only) → exit 1 + OVERLAY-ONLY
#      line.
#   D. `.example` suffix on overlay side is silently ignored (no drift).
#
# Option C 의 Phase 2 변경 후: PLUGIN-ONLY 는 default OK (plugin SSOT 가 SSOT).
# 따라서 옛 B/D/F2 (PLUGIN-ONLY drift expected) test 는 의미 없음 — 제거됨.
# parity check 와 boundary / validation 은 별도 (test-rein-check-plugin-drift-boundary.sh).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIFT_PY="$PROJECT_DIR/scripts/rein-check-plugin-drift.py"

[ -f "$DRIFT_PY" ] || { echo "FAIL: missing $DRIFT_PY" >&2; exit 1; }

TMP="$(mktemp -d -t rein-drift-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL_COUNT=0
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
ok()   { echo "  ok: $1"; }

# Helper — make a sandbox repo with both trees.
make_sandbox() {
  local sb="$1"
  mkdir -p "$sb/plugins/rein-core/hooks" \
           "$sb/plugins/rein-core/skills/foo" \
           "$sb/plugins/rein-core/agents" \
           "$sb/.claude/hooks" \
           "$sb/.claude/skills/foo" \
           "$sb/.claude/agents"
  # Baseline identical file in both trees.
  printf 'identical body\n' > "$sb/plugins/rein-core/hooks/baseline.sh"
  printf 'identical body\n' > "$sb/.claude/hooks/baseline.sh"
}

# A — live tree parity check only (boundary + validation skipped — those have
# their own dedicated test). Boundary check fails on the current dev tree because
# 7 shared rules still exist under `.claude/rules/` (Phase 3 작업 미수행),
# so we explicitly skip it here.
( cd "$PROJECT_DIR" && python3 "$DRIFT_PY" --quiet --skip-boundary --skip-validation \
                       >"$TMP/live.out" 2>&1 )
LIVE_RC=$?
if [ "$LIVE_RC" -eq 0 ]; then
  ok "A: live tree parity check (no boundary, no validation) exits 0"
else
  fail "A: live tree parity expected exit 0, got $LIVE_RC. Output:"
  cat "$TMP/live.out" >&2
fi

# B — synthetic hash-mismatch fixture (same path, different content).
SB_B="$TMP/b"
make_sandbox "$SB_B"
printf 'plugin variant\n'   > "$SB_B/plugins/rein-core/hooks/baseline.sh"
printf 'overlay variant\n'  > "$SB_B/.claude/hooks/baseline.sh"
python3 "$DRIFT_PY" --repo-root "$SB_B" --quiet --skip-boundary --skip-validation \
        >"$TMP/b.out" 2>&1
B_RC=$?
if [ "$B_RC" -eq 1 ] && grep -q "HASH-MISMATCH hooks/baseline.sh" "$TMP/b.out"; then
  ok "B: hash mismatch triggers HASH-MISMATCH drift line + exit 1"
else
  fail "B: expected exit 1 + 'HASH-MISMATCH hooks/baseline.sh' line, got rc=$B_RC, output:"
  cat "$TMP/b.out" >&2
fi

# C — synthetic OVERLAY-ONLY drift (file in .claude/ only).
SB_C="$TMP/c"
make_sandbox "$SB_C"
printf 'overlay only\n' > "$SB_C/.claude/hooks/orphan-from-overlay.sh"
python3 "$DRIFT_PY" --repo-root "$SB_C" --quiet --skip-boundary --skip-validation \
        >"$TMP/c.out" 2>&1
C_RC=$?
if [ "$C_RC" -eq 1 ] && grep -q "OVERLAY-ONLY hooks/orphan-from-overlay.sh" "$TMP/c.out"; then
  ok "C: overlay-only file triggers OVERLAY-ONLY drift line + exit 1"
else
  fail "C: expected exit 1 + 'OVERLAY-ONLY hooks/orphan-from-overlay.sh' line, got rc=$C_RC, output:"
  cat "$TMP/c.out" >&2
fi

# D — `.example` suffix on overlay side is silently ignored.
SB_D="$TMP/d"
make_sandbox "$SB_D"
printf '# stub\n' > "$SB_D/.claude/hooks/post-edit-lint.sh.example"
python3 "$DRIFT_PY" --repo-root "$SB_D" --quiet --skip-boundary --skip-validation \
        >"$TMP/d.out" 2>&1
D_RC=$?
if [ "$D_RC" -eq 0 ]; then
  ok "D: .example on overlay side is silently ignored (no drift)"
else
  fail "D: overlay .example should be ignored, got rc=$D_RC. Output:"
  cat "$TMP/d.out" >&2
fi

if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "test-plugin-drift-detection: FAIL ($FAIL_COUNT assertions failed)" >&2
  exit 1
fi
echo "test-plugin-drift-detection: OK (4/4 assertions)"
