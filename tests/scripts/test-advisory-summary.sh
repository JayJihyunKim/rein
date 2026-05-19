#!/bin/bash
# Test: rein-aggregate-incidents.py advisory-summary 서브커맨드
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES=$(mktemp -d)
trap "rm -rf $FIXTURES" EXIT

# fixture blocks.jsonl 생성
cat > "$FIXTURES/blocks.jsonl" <<'EOF'
{"ts":"2026-04-19T10:00:00Z","source":"pre-bash-safety-guard","reason":"dod-missing","target":"src/foo.py"}
{"ts":"2026-04-19T10:05:00Z","source":"pre-bash-safety-guard","reason":"dod-missing","target":"src/bar.py"}
{"ts":"2026-04-19T10:10:00Z","source":"pre-edit-dod-gate","reason":"coverage-mismatch","target":"plan.md"}
EOF

# Test 1: 기본 실행
OUT=$(REIN_BLOCKS_JSONL="$FIXTURES/blocks.jsonl" python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" advisory-summary)
echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, list), 'not a list'; print('test1: OK')"

# Test 2: --since-line 1 이면 3줄 모두 포함 → 2개 패턴
OUT=$(REIN_BLOCKS_JSONL="$FIXTURES/blocks.jsonl" python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" advisory-summary --since-line 1)
COUNT=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")
[ "$COUNT" = "2" ] || { echo "test2 FAIL: expected 2 patterns, got $COUNT"; exit 1; }
echo "test2: OK"

# Test 3: dod-missing 은 count 2
OUT=$(REIN_BLOCKS_JSONL="$FIXTURES/blocks.jsonl" python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" advisory-summary --since-line 1)
DOD_COUNT=$(echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for item in d:
    if item['pattern_label'] == 'dod-missing':
        print(item['count'])
        break
")
[ "$DOD_COUNT" = "2" ] || { echo "test3 FAIL: dod-missing count expected 2, got $DOD_COUNT"; exit 1; }
echo "test3: OK"

# Test 4: --since-line 3 이면 1줄(3번째)만 → 1개 패턴
OUT=$(REIN_BLOCKS_JSONL="$FIXTURES/blocks.jsonl" python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" advisory-summary --since-line 3)
COUNT=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))")
[ "$COUNT" = "1" ] || { echo "test4 FAIL: expected 1 pattern, got $COUNT"; exit 1; }
echo "test4: OK"

echo "ALL OK"
