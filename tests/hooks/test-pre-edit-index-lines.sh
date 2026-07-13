#!/usr/bin/env bash
# tests/hooks/test-pre-edit-index-lines.sh
#
# Behavioral test for plugins/rein-core/hooks/pre-edit-index-lines.sh.
#
# The hook simulates the RESULT line count of a Write/Edit/MultiEdit against
# trail/index.md and blocks (exit 2) when the result violates the 5~25 line
# rule — write-time enforcement of the rule the stop-session gate re-checks
# at session end (defense in depth; the stop gate stays).
#
# Fixtures:
#   1. WRITE-26-BLOCKED        — Write with 26-line content → exit 2 + stderr guidance
#   2. WRITE-25-OK             — boundary 25 lines → exit 0
#   3. WRITE-5-OK              — boundary 5 lines → exit 0
#   4. WRITE-4-BLOCKED         — 4 lines → exit 2
#   5. EDIT-GROW-BLOCKED       — Edit growing 25 → 26 → exit 2
#   6. EDIT-SHRINK-OK          — Edit shrinking 26 → 24 → exit 0 (escape from violation)
#   7. OTHER-FILE-UNTOUCHED    — 30-line Write to another file → exit 0
#   8. MALFORMED-JSON-FAILOPEN — broken stdin → exit 0 (stop gate backstops)
#   9. MULTIEDIT-GROW-BLOCKED  — MultiEdit net growth past 25 → exit 2
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$REPO_ROOT/plugins/rein-core/hooks/pre-edit-index-lines.sh"
PLUGIN_ROOT="$REPO_ROOT/plugins/rein-core"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }

FAILED=0

assert_exit() {
  local name="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    echo "OK [$name]"
  else
    echo "FAIL [$name]: expected exit $expected got $got" >&2
    FAILED=$((FAILED+1))
  fi
}

make_lines() {  # make_lines N → N numbered lines on stdout
  local n="$1" i=1
  while [ "$i" -le "$n" ]; do echo "line $i"; i=$((i+1)); done
}

json_escape() {  # stdin → JSON string (with quotes)
  python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'
}

run_hook() {  # run_hook <proj> <json> [stderr_file]
  local proj="$1" payload="$2" errf="${3:-/dev/null}"
  local rc=0
  printf '%s' "$payload" | REIN_PROJECT_DIR_OVERRIDE="$proj" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$HOOK" >/dev/null 2>"$errf" || rc=$?
  echo "$rc"
}

make_project() {
  local proj="$1" idx_lines="${2:-10}"
  mkdir -p "$proj/trail"
  make_lines "$idx_lines" > "$proj/trail/index.md"
}

# ---------- 1. WRITE-26-BLOCKED ---------------------------------------------
P=$(mktemp -d "/tmp/idx-t1-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 26 | json_escape)
ERR=$(mktemp)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}" "$ERR")
assert_exit "WRITE-26-BLOCKED" "2" "$RC"
if grep -q "26" "$ERR" && grep -q "25" "$ERR"; then
  echo "OK [WRITE-26-BLOCKED-stderr-mentions-counts]"
else
  echo "FAIL [WRITE-26-BLOCKED-stderr-mentions-counts]: $(cat "$ERR")" >&2
  FAILED=$((FAILED+1))
fi
rm -rf "$P" "$ERR"

# ---------- 2. WRITE-25-OK ---------------------------------------------------
P=$(mktemp -d "/tmp/idx-t2-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 25 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}")
assert_exit "WRITE-25-OK" "0" "$RC"
rm -rf "$P"

# ---------- 3. WRITE-5-OK ----------------------------------------------------
P=$(mktemp -d "/tmp/idx-t3-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 5 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}")
assert_exit "WRITE-5-OK" "0" "$RC"
rm -rf "$P"

# ---------- 4. WRITE-4-BLOCKED -----------------------------------------------
P=$(mktemp -d "/tmp/idx-t4-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 4 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}")
assert_exit "WRITE-4-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 5. EDIT-GROW-BLOCKED ---------------------------------------------
# index = 25 lines; Edit replaces "line 25" with two lines → 26.
P=$(mktemp -d "/tmp/idx-t5-XXXXXX"); make_project "$P" 25
PAYLOAD=$(python3 - "$P" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
  "tool_name": "Edit",
  "tool_input": {
    "file_path": f"{proj}/trail/index.md",
    "old_string": "line 25",
    "new_string": "line 25\nline 26",
  },
}))
PY
)
RC=$(run_hook "$P" "$PAYLOAD")
assert_exit "EDIT-GROW-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 6. EDIT-SHRINK-OK ------------------------------------------------
# index = 26 lines (already violating); Edit removing 2 lines → 24 must pass.
P=$(mktemp -d "/tmp/idx-t6-XXXXXX"); make_project "$P" 26
PAYLOAD=$(python3 - "$P" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
  "tool_name": "Edit",
  "tool_input": {
    "file_path": f"{proj}/trail/index.md",
    "old_string": "line 24\nline 25\nline 26",
    "new_string": "line 24",
  },
}))
PY
)
RC=$(run_hook "$P" "$PAYLOAD")
assert_exit "EDIT-SHRINK-OK" "0" "$RC"
rm -rf "$P"

# ---------- 7. OTHER-FILE-UNTOUCHED ------------------------------------------
P=$(mktemp -d "/tmp/idx-t7-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 30 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/inbox/note.md\",\"content\":$CONTENT}}")
assert_exit "OTHER-FILE-UNTOUCHED" "0" "$RC"
rm -rf "$P"

# ---------- 8. MALFORMED-JSON-FAILOPEN ----------------------------------------
P=$(mktemp -d "/tmp/idx-t8-XXXXXX"); make_project "$P"
RC=$(run_hook "$P" '{not json — but mentions trail/index.md')
assert_exit "MALFORMED-JSON-FAILOPEN" "0" "$RC"
rm -rf "$P"

# ---------- 9. MULTIEDIT-TOPLEVEL-FALLBACK-BLOCKED ------------------------------
# per-edit file_path 가 없는 변형 스키마 — top-level file_path fallback 경로.
P=$(mktemp -d "/tmp/idx-t9-XXXXXX"); make_project "$P" 24
PAYLOAD=$(python3 - "$P" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
  "tool_name": "MultiEdit",
  "tool_input": {
    "file_path": f"{proj}/trail/index.md",
    "edits": [
      {"old_string": "line 24", "new_string": "line 24\nline 25"},
      {"old_string": "line 25", "new_string": "line 25\nline 26"},
    ],
  },
}))
PY
)
RC=$(run_hook "$P" "$PAYLOAD")
assert_exit "MULTIEDIT-TOPLEVEL-FALLBACK-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 9b. MULTIEDIT-REAL-SCHEMA-BLOCKED ------------------------------------
# 실계약: tool_input.edits[*].file_path (per-edit 경로, top-level 없음) —
# post-edit-review-gate.sh 수집 순서와 동일 (codex R2 High 회귀).
P=$(mktemp -d "/tmp/idx-t9b-XXXXXX"); make_project "$P" 24
PAYLOAD=$(python3 - "$P" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
  "tool_name": "MultiEdit",
  "tool_input": {
    "edits": [
      {"file_path": f"{proj}/trail/index.md", "old_string": "line 24", "new_string": "line 24\nline 25"},
      {"file_path": f"{proj}/trail/index.md", "old_string": "line 25", "new_string": "line 25\nline 26"},
    ],
  },
}))
PY
)
RC=$(run_hook "$P" "$PAYLOAD")
assert_exit "MULTIEDIT-REAL-SCHEMA-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 9c. MULTIEDIT-MIXED-FILES-BLOCKED ------------------------------------
# 여러 파일 혼합 MultiEdit: 타 파일 edit(old_string 이 index 에 없음)는 제외되고
# index 대상 edit 만 적용돼야 한다 — 잘못 포함되면 SKIP(fail-open)으로 새서 실패.
P=$(mktemp -d "/tmp/idx-t9c-XXXXXX"); make_project "$P" 24
PAYLOAD=$(python3 - "$P" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
  "tool_name": "MultiEdit",
  "tool_input": {
    "edits": [
      {"file_path": f"{proj}/trail/other.md", "old_string": "zzz-not-in-index", "new_string": "y"},
      {"file_path": f"{proj}/trail/index.md", "old_string": "line 24", "new_string": "line 24\nline 25\nline 26"},
    ],
  },
}))
PY
)
RC=$(run_hook "$P" "$PAYLOAD")
assert_exit "MULTIEDIT-MIXED-FILES-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 10. WC-ALIGNMENT (trailing newline 없는 26조각 = wc -l 25 = 통과) ----
# 줄 수 산식은 stop-session-gate 의 `wc -l`(개행 문자 수)과 동일해야 한다 —
# 편집 게이트와 종료 게이트가 다르게 세면 잔존 왕복이 생긴다.
P=$(mktemp -d "/tmp/idx-t10-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 26 | printf '%s' "$(cat)" | json_escape)   # 마지막 개행 제거
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}")
assert_exit "WC-ALIGNMENT-26-segments-no-trailing-nl-OK" "0" "$RC"
rm -rf "$P"

# ---------- 11. RELATIVE-PATH-BLOCKED (상대경로도 PROJECT_DIR 기준 매칭) --------
# codex review 2026-07-13 Medium: 상대 file_path 를 CWD 기준으로 해석하면
# 대상 파일인데도 SKIP. PROJECT_DIR 기준 해석을 회귀 고정.
P=$(mktemp -d "/tmp/idx-t11-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 26 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"trail/index.md\",\"content\":$CONTENT}}")
assert_exit "RELATIVE-PATH-BLOCKED" "2" "$RC"
rm -rf "$P"

# ---------- 12. RELATIVE-OTHER-FILE-UNTOUCHED -----------------------------------
P=$(mktemp -d "/tmp/idx-t12-XXXXXX"); make_project "$P"
CONTENT=$(make_lines 30 | json_escape)
RC=$(run_hook "$P" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"trail/inbox/note-index.md\",\"content\":$CONTENT}}")
assert_exit "RELATIVE-OTHER-FILE-UNTOUCHED" "0" "$RC"
rm -rf "$P"

# ---------- 13. PYTHON-UNAVAILABLE-FAILOPEN -------------------------------------
# PATH 에 python 계열이 아예 없으면 resolver 가 실패 → 이 게이트는 fail-open
# (종료 게이트 backstop). 26줄 Write 도 통과해야 한다. 훅이 쓰는 외부 바이너리
# (cat/cut/dirname)만 담은 제한 PATH 로 재현.
P=$(mktemp -d "/tmp/idx-t13-XXXXXX"); make_project "$P"
NOPY_BIN=$(mktemp -d "/tmp/idx-nopy-XXXXXX")
for b in bash sh cat cut dirname; do
  src=$(command -v "$b") && ln -s "$src" "$NOPY_BIN/$b"
done
CONTENT=$(make_lines 26 | json_escape)
RC=0
printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$P/trail/index.md\",\"content\":$CONTENT}}" \
  | env PATH="$NOPY_BIN" REIN_PROJECT_DIR_OVERRIDE="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$HOOK" >/dev/null 2>&1 || RC=$?
assert_exit "PYTHON-UNAVAILABLE-FAILOPEN" "0" "$RC"
rm -rf "$P" "$NOPY_BIN"

# ---------- Result -------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
  echo "test-pre-edit-index-lines: FAIL ($FAILED assertion(s))" >&2
  exit 1
fi
echo "test-pre-edit-index-lines: OK (15 fixtures)"
