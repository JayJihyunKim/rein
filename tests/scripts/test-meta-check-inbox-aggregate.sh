#!/usr/bin/env bash
# tests/scripts/test-meta-check-inbox-aggregate.sh — G3 Phase 4 Task 4.5
#
# Verifies that the inbox jsonl produced by post-edit-meta-check.sh can be
# aggregated with a `jq` 1-liner to compute the "auto-converged ratio"
# claimed in spec §3.4 (G3-MC-INBOX). This guarantees the operational
# claim (회고 산식) is executable, independent of the hook implementation.
#
# Fixture: 10-line jsonl with mismatch_count 0/0/1/0/2/0/0/3/0/0
#   → mismatch=0 count: 7
#   → total: 10
#   → auto-converged ratio: 70%
#
# Scope ID: G3-MC-INBOX
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq missing — inbox aggregate test requires jq" >&2
  exit 0
fi

WORK=$(mktemp -d "/tmp/meta-check-inbox-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FX="$WORK/2026-05-27-meta-check.jsonl"
cat > "$FX" <<'JSONL'
{"ts":"2026-05-27T00:00:00Z","dod_slug":"a","diff_files_count":1,"mismatch_count":0,"hint_files_count":1,"sample_missing_files":[]}
{"ts":"2026-05-27T00:01:00Z","dod_slug":"a","diff_files_count":2,"mismatch_count":0,"hint_files_count":2,"sample_missing_files":[]}
{"ts":"2026-05-27T00:02:00Z","dod_slug":"a","diff_files_count":3,"mismatch_count":1,"hint_files_count":2,"sample_missing_files":["x.py"]}
{"ts":"2026-05-27T00:03:00Z","dod_slug":"a","diff_files_count":1,"mismatch_count":0,"hint_files_count":1,"sample_missing_files":[]}
{"ts":"2026-05-27T00:04:00Z","dod_slug":"a","diff_files_count":4,"mismatch_count":2,"hint_files_count":2,"sample_missing_files":["y.py","z.py"]}
{"ts":"2026-05-27T00:05:00Z","dod_slug":"a","diff_files_count":1,"mismatch_count":0,"hint_files_count":1,"sample_missing_files":[]}
{"ts":"2026-05-27T00:06:00Z","dod_slug":"a","diff_files_count":2,"mismatch_count":0,"hint_files_count":2,"sample_missing_files":[]}
{"ts":"2026-05-27T00:07:00Z","dod_slug":"a","diff_files_count":5,"mismatch_count":3,"hint_files_count":2,"sample_missing_files":["a","b","c"]}
{"ts":"2026-05-27T00:08:00Z","dod_slug":"a","diff_files_count":1,"mismatch_count":0,"hint_files_count":1,"sample_missing_files":[]}
{"ts":"2026-05-27T00:09:00Z","dod_slug":"a","diff_files_count":1,"mismatch_count":0,"hint_files_count":1,"sample_missing_files":[]}
JSONL

TOTAL=$(jq -s 'length' < "$FX")
ZEROS=$(jq -s '[.[] | select(.mismatch_count==0)] | length' < "$FX")

if [ "$TOTAL" != "10" ]; then
  echo "FAIL: fixture total expected 10, got $TOTAL" >&2
  exit 1
fi

if [ "$ZEROS" != "7" ]; then
  echo "FAIL: mismatch=0 count expected 7, got $ZEROS" >&2
  exit 1
fi

RATIO=$(( ZEROS * 100 / TOTAL ))
if [ "$RATIO" != "70" ]; then
  echo "FAIL: auto-converged ratio expected 70%, got $RATIO%" >&2
  exit 1
fi

echo "test-meta-check-inbox-aggregate: OK (total=10, zeros=7, ratio=70%)"
