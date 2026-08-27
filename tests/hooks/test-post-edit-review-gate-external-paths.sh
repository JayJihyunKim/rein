#!/usr/bin/env bash
# test-post-edit-review-gate-external-paths.sh
#
# Phase 7 웨이브 3 ③-d (2026-08-24) 처분: **정당 소멸**. 원래 이 스위트는
# post-edit-review-gate.sh(legacy trail/dod/.review-pending 표식의 유일한
# 생산자)의 external-path 예외(mktemp -d 임시 파일이 PROJECT_DIR 밖이면
# 게이트를 더럽히지 않는다) 4개 시나리오를 고정했다 — incident bash-guard-
# 2fbe7edae5a10b1f 의 회귀 방지.
#
# 이 웨이브에서 legacy 리뷰 표식 3종(.codex-reviewed/.review-pending/
# .security-reviewed)의 write/read 경로가 전면 제거되면서, 이 표식의
# 유일한 생산자였던 post-edit-review-gate.sh 자체가 삭제됐다(hooks.json
# 등록도 함께 해제 — tests/hooks/test-hooks-routing-contract.sh 의
# EXPECTED_ROUTING 표에서 이 항목이 빠졌음을 그 스위트가 직접 고정한다).
# 검증 대상이던 "external path 예외 로직" 자체가 코드에서 사라졌으므로
# 원 4개 시나리오는 재현 불가능하다 — 후계는 존재하지 않는다(이 웨이브가
# 표식 메커니즘 자체를 폐기하기로 한 스펙 결정이지, 우연한 누락이
# 아니다).
#
# 이 파일은 "정당 소멸" 처분을 부재 검증(hook 파일 자체가 다시는
# 나타나지 않는다)으로 전환해 유지한다 — 실수로 이 훅이 재도입되면
# (예: git revert, 브랜치 병합 실수) 즉시 이 테스트가 잡는다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-review-gate.sh"
HOOKS_JSON="$PROJECT_DIR/plugins/rein-core/hooks/hooks.json"

FAIL=0
note_fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

if [ -e "$HOOK" ]; then
  note_fail "post-edit-review-gate.sh unexpectedly exists at $HOOK — the legacy .review-pending write path was retired in Phase 7 wave 3 ③-d and must not be reintroduced"
else
  echo "  ok: post-edit-review-gate.sh remains absent (Phase 7 wave 3 ③-d)"
fi

if [ -f "$HOOKS_JSON" ]; then
  if grep -q "post-edit-review-gate.sh" "$HOOKS_JSON"; then
    note_fail "hooks.json still references post-edit-review-gate.sh — registration should have been removed alongside the hook file"
  else
    echo "  ok: hooks.json does not reference post-edit-review-gate.sh"
  fi
else
  note_fail "hooks.json not found at $HOOKS_JSON"
fi

# 존속 확인: legacy 표식이 사라진 자리를 대신하는 새 판정 경로
# (post-agent-review-trigger.sh 의 v2 digest 조회)는 별도 스위트
# (tests/hooks/test-post-agent-review-trigger.sh)가 전담한다 — 여기서는
# 중복 검증하지 않는다.

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-post-edit-review-gate-external-paths: OK (absence-lock, 2/2 assertions)"
  exit 0
else
  echo "test-post-edit-review-gate-external-paths: $FAIL assertion(s) FAILED"
  exit 1
fi
