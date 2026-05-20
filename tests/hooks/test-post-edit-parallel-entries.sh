#!/usr/bin/env bash
# HK-4 — hooks.json 의 PostToolUse(Edit|Write|MultiEdit) 가 8 sub-hook 별개 entry
# + 마지막에 aggregator entry (총 9) 로 등록되어 있고, dispatcher 가 등록 해제
# 됐는지 검증.
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

# === Edit|Write|MultiEdit matcher 의 PostToolUse entry 정확히 9개 (8 sub-hook + aggregator) ===
edit_entry_count=$(python3 -c "
import json
h=json.load(open('$HOOKS_JSON'))
ents=[e for e in h['hooks']['PostToolUse'] if e.get('matcher')=='Edit|Write|MultiEdit']
print(len(ents))
")
if [ "$edit_entry_count" = "9" ]; then
  echo "PASS: posttoolse_edit_entry_count_9 (8 sub-hook + aggregator)"
  PASS=$((PASS+1))
else
  echo "FAIL: posttoolse_edit_entry_count_9 — actual=$edit_entry_count"
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

# === 8 sub-hook 이름 모두 존재 ===
expected_subhooks=("post-edit-hygiene" "post-edit-review-gate" "post-edit-index-sync-inbox" "post-edit-spec-review-gate" "post-edit-plan-coverage" "post-edit-dod-routing-check" "post-edit-design-plan-coverage-rule" "post-edit-routing-procedure-rule")
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
