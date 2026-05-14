#!/bin/bash
# Test: stop-session-gate.sh 의 incident_advisory_check helper
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

mkdir -p "$TMP/trail/incidents" "$TMP/trail/inbox" "$TMP/trail/dod"
ln -s "$PROJECT_DIR/scripts" "$TMP/scripts"
ln -s "$PROJECT_DIR/.claude" "$TMP/.claude"
touch "$TMP/trail/index.md"

echo "1" > "$TMP/trail/incidents/.session-start-line"

cat > "$TMP/trail/incidents/blocks.jsonl" <<'EOF'
{"ts":"2026-04-19T12:00:00Z","source":"s","reason":"dod-missing","target":"a"}
{"ts":"2026-04-19T12:05:00Z","source":"s","reason":"dod-missing","target":"b"}
{"ts":"2026-04-19T12:10:00Z","source":"s","reason":"dod-missing","target":"c"}
EOF

TODAY=$(date +%Y-%m-%d)
echo "# test" > "$TMP/trail/inbox/${TODAY}-test.md"
echo "# idx" > "$TMP/trail/index.md"

OUTPUT=$(REIN_PROJECT_DIR="$TMP" bash "$PROJECT_DIR/.claude/hooks/stop-session-gate.sh" 2>&1 1>/dev/null || true)

echo "$OUTPUT" | grep -q "incidents-to-agent" || {
  echo "FAIL: expected 'incidents-to-agent' in stderr"
  echo "actual: $OUTPUT"
  exit 1
}
echo "OK: advisory message present"
