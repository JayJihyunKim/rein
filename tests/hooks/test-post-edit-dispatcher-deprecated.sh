#!/usr/bin/env bash
# HK-4 — post-edit-dispatcher.sh 가 deprecation 상태 (early exit 0 + warning).
# hooks.json 에서 등록 해제됐으므로 호출되어도 runtime 영향 없음.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/plugins/rein-core/hooks/post-edit-dispatcher.sh"

PASS=0
FAIL=0

# === 파일 존재 (rollback 용 보존) ===
if [ -f "$DISPATCHER" ]; then
  echo "PASS: dispatcher_파일_보존"
  PASS=$((PASS+1))
else
  echo "FAIL: dispatcher_파일_보존"
  FAIL=$((FAIL+1))
fi

# === deprecation marker (head 5 line 이내) ===
if head -10 "$DISPATCHER" | grep -q "DEPRECATED"; then
  echo "PASS: dispatcher_deprecation_marker"
  PASS=$((PASS+1))
else
  echo "FAIL: dispatcher_deprecation_marker"
  FAIL=$((FAIL+1))
fi

# === 호출 시 exit 0 + stderr warning ===
output=$(printf '' | bash "$DISPATCHER" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "PASS: dispatcher_호출시_exit_0"
  PASS=$((PASS+1))
else
  echo "FAIL: dispatcher_호출시_exit_0 — rc=$rc"
  FAIL=$((FAIL+1))
fi

if printf '%s' "$output" | grep -q "DEPRECATED"; then
  echo "PASS: dispatcher_호출시_stderr_warning"
  PASS=$((PASS+1))
else
  echo "FAIL: dispatcher_호출시_stderr_warning"
  FAIL=$((FAIL+1))
fi

echo
echo "HK-4 dispatcher deprecation: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
