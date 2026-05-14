#!/bin/bash
# Test: session-start-load-trail.sh 가 recovery 후 .session-start-line 을 올바르게 기록
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/.rein" "$TMP/trail/incidents" "$TMP/trail/inbox" "$TMP/trail/daily" "$TMP/trail/weekly" "$TMP/trail/dod"
ln -s "$PROJECT_DIR/scripts" "$TMP/scripts"
ln -s "$PROJECT_DIR/.claude" "$TMP/.claude"
printf '{"version":1}\n' > "$TMP/.rein/project.json"
touch "$TMP/trail/index.md"
cat > "$TMP/trail/incidents/blocks.jsonl" <<'EOF'
{"ts":"2026-04-19T09:00:00Z","source":"s","reason":"r","target":"t"}
{"ts":"2026-04-19T09:05:00Z","source":"s","reason":"r","target":"t"}
EOF

REIN_PROJECT_DIR="$TMP" bash "$PROJECT_DIR/.claude/hooks/session-start-load-trail.sh" > /dev/null 2>&1 || true

STAMP="$TMP/trail/incidents/.session-start-line"
[ -f "$STAMP" ] || { echo "FAIL: stamp file missing at $STAMP"; exit 1; }

LINE_COUNT=$(wc -l < "$TMP/trail/incidents/blocks.jsonl" | tr -d ' ')
EXPECTED=$((LINE_COUNT + 1))
STAMP_VAL=$(cat "$STAMP" | tr -d ' \n')
[ "$STAMP_VAL" = "$EXPECTED" ] || {
  echo "FAIL: stamp expected $EXPECTED (line_count=$LINE_COUNT + 1), got $STAMP_VAL"
  exit 1
}

echo "OK: stamp=$STAMP_VAL (next line for current session)"
