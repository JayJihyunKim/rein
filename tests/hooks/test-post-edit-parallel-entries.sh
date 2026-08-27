#!/usr/bin/env bash
# HK-4 + X4.C.2 — hooks.json 의 PostToolUse(Edit|Write|MultiEdit) 가 9 sub-hook
# (8 HK-4 sub-hook + 1 X4.C.2 state-journal) 별개 entry + 마지막에 aggregator
# entry (총 10) 로 등록되어 있고, dispatcher 가 등록 해제 됐는지 검증.
#
# Scope ID: HK-4-post-edit-dispatcher-dependency-free-subhooks-split-into-parallel-hook-entries-conditional-on-spike-1-confirming-exit2-deny-merge

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/plugins/rein-core/hooks/hooks.json"

PASS=0
FAIL=0

# === JSON parse 가능 ===
if python3 -c "import json; json.load(open('$HOOKS_JSON'))" 2>/dev/null; then
  echo "PASS: hooks_json_parse"
  PASS=$((PASS+1))
else
  echo "FAIL: hooks_json_parse"
  FAIL=$((FAIL+1))
fi

# === Edit|Write|MultiEdit matcher 의 PostToolUse entry 정확히 11개 (10 sub-hook + aggregator) ===
# G3 cycle (2026-05-27) added post-edit-meta-check.sh as 10th sub-hook.
# feature-builder-refactor task step 1 (2026-08-14) added post-edit-src-
# touch-marker.sh (Marker A relocation — trail/dod/.session-has-src-edit
# producer, moved out of pre-edit-dod-gate.sh) as an 11th sub-hook, placed
# BEFORE the aggregator so the "aggregator is last" invariant below still
# holds (it does not emit an envelope, so its position relative to the
# aggregator's cache-merge role is otherwise unconstrained).
# Phase 7 웨이브 3 ③-d (2026-08-24): post-edit-review-gate.sh 삭제 —
# legacy trail/dod/.review-pending 표식의 유일한 생산자였고, 그 표식의
# write/read 경로가 이번 웨이브로 전면 제거됐다. sub-hook 수가 11 →10 으로
# 줄어 총 entry 수도 12 → 11 로 감소한다.
edit_entry_count=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
ents=[e for e in h['hooks']['PostToolUse'] if e.get('matcher')=='Edit|Write|MultiEdit']
print(len(ents))
")
if [ "$edit_entry_count" = "11" ]; then
  echo "PASS: posttoolse_edit_entry_count_11 (10 sub-hook + aggregator)"
  PASS=$((PASS+1))
else
  echo "FAIL: posttoolse_edit_entry_count_11 — actual=$edit_entry_count"
  FAIL=$((FAIL+1))
fi

# === dispatcher entry 등록 해제 ===
dispatcher_present=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
cmds=[h['hooks'][0]['command'] for entry in h['hooks']['PostToolUse'] for h in [entry] for h in [entry['hooks']]]
" 2>/dev/null; python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
flat=[hk['command'] for entry in h['hooks']['PostToolUse'] for hk in entry['hooks']]
print('yes' if any('post-edit-dispatcher' in c for c in flat) else 'no')
")
if [ "$dispatcher_present" = "no" ]; then
  echo "PASS: dispatcher_entry_등록_해제"
  PASS=$((PASS+1))
else
  echo "FAIL: dispatcher_entry_등록_해제 — actual=$dispatcher_present"
  FAIL=$((FAIL+1))
fi

# === 10 sub-hook 이름 모두 존재 (G3 cycle 추가 post-edit-meta-check 포함) ===
# Phase 7 웨이브 3 ③-d: post-edit-review-gate 는 삭제되어 이 목록에서
# 빠졌다(위 entry-count 주석 참조).
expected_subhooks=("post-edit-hygiene" "post-edit-index-sync-inbox" "post-edit-spec-review-gate" "post-edit-plan-coverage" "post-edit-dod-routing-check" "post-edit-design-plan-coverage-rule" "post-edit-routing-procedure-rule" "post-edit-meta-check" "post-edit-state-journal" "post-edit-src-touch-marker")
for sub in "${expected_subhooks[@]}"; do
  found=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
flat=[hk['command'] for entry in h['hooks']['PostToolUse'] for hk in entry['hooks']]
print('yes' if any('$sub.sh' in c for c in flat) else 'no')
")
  if [ "$found" = "yes" ]; then
    echo "PASS: subhook_등록_$sub"
    PASS=$((PASS+1))
  else
    echo "FAIL: subhook_등록_$sub"
    FAIL=$((FAIL+1))
  fi
done

# === post-edit-review-gate 부재 확인 (Phase 7 웨이브 3 ③-d, 무언 재도입 방지) ===
review_gate_absent=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
flat=[hk['command'] for entry in h['hooks']['PostToolUse'] for hk in entry['hooks']]
print('yes' if not any('post-edit-review-gate.sh' in c for c in flat) else 'no')
")
if [ "$review_gate_absent" = "yes" ]; then
  echo "PASS: subhook_부재_post-edit-review-gate"
  PASS=$((PASS+1))
else
  echo "FAIL: subhook_부재_post-edit-review-gate — hooks.json still registers the retired hook"
  FAIL=$((FAIL+1))
fi

# === aggregator 마지막 entry ===
last_edit_cmd=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
ents=[e for e in h['hooks']['PostToolUse'] if e.get('matcher')=='Edit|Write|MultiEdit']
print(ents[-1]['hooks'][0]['command'] if ents else '')
")
case "$last_edit_cmd" in
  *post-edit-aggregator.sh)
    echo "PASS: aggregator_마지막_entry"
    PASS=$((PASS+1))
    ;;
  *)
    echo "FAIL: aggregator_마지막_entry — actual=$last_edit_cmd"
    FAIL=$((FAIL+1))
    ;;
esac

echo
echo "HK-4 parallel-entries: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
