#!/bin/bash
# Hook: PostToolUse(Write|Edit|MultiEdit)
# plan 파일 편집 시 coverage matrix validator 실행.
# 실패 시 trail/dod/.coverage-mismatch 마커 생성. pre-bash-guard 가 이후 차단.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOD_DIR="$PROJECT_DIR/trail/dod"
MARKER="$DOD_DIR/.coverage-mismatch"
VALIDATOR="$PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"

[ -f "$VALIDATOR" ] || exit 0  # validator 없으면 no-op

INPUT=$(cat)

FILE_PATHS=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ti = d.get("tool_input", {}) or {}
tr = d.get("tool_result", {}) or {}
paths = []
if "file_path" in ti and ti["file_path"]:
    paths.append(ti["file_path"])
for src in (ti, tr):
    for e in (src.get("edits") or []):
        fp = e.get("file_path", "")
        if fp and fp not in paths:
            paths.append(fp)
if not paths and tr.get("file_path"):
    paths.append(tr["file_path"])
print("\n".join(paths))
' 2>/dev/null
)

[ -z "$FILE_PATHS" ] && exit 0

mkdir -p "$DOD_DIR"

is_plan_path() {
  # Mirror canonical matcher from post-write-spec-review-gate.sh but restrict to plans.
  local abs="$1"
  local rel
  case "$abs" in
    "$PROJECT_DIR"/*) rel="${abs#$PROJECT_DIR/}" ;;
    *) return 1 ;;
  esac
  [[ "$rel" =~ ^(docs(/[^/]+)*/plans/.+\.md|plans/.+\.md)$ ]]
}

# Helpers for managing the marker as a deduped line-list of failed plan paths.
marker_has_plan() {
  local plan="$1"
  [ -f "$MARKER" ] || return 1
  grep -qxF "$plan" "$MARKER"
}

marker_add_plan() {
  local plan="$1"
  mkdir -p "$(dirname "$MARKER")"
  if marker_has_plan "$plan"; then return 0; fi
  echo "$plan" >> "$MARKER"
}

marker_remove_plan() {
  local plan="$1"
  [ -f "$MARKER" ] || return 0
  local tmp
  tmp=$(mktemp)
  grep -vxF "$plan" "$MARKER" > "$tmp" || true
  if [ -s "$tmp" ]; then
    mv "$tmp" "$MARKER"
  else
    rm -f "$MARKER" "$tmp"
  fi
}

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  ABS=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null)
  [ -z "$ABS" ] && continue
  is_plan_path "$ABS" || continue
  [ -f "$ABS" ] || continue  # 편집된 파일이 실제로 존재해야 검증 가능

  # Run validator once, capture stderr + exit code.
  TMP_ERR=$(mktemp)
  python3 "$VALIDATOR" "$ABS" 2> "$TMP_ERR"
  VEXIT=$?
  if [ -s "$TMP_ERR" ]; then
    cat "$TMP_ERR" >&2
  fi
  rm -f "$TMP_ERR"

  if [ "$VEXIT" -ne 0 ]; then
    marker_add_plan "$ABS"
    echo "NOTICE: coverage matrix validation failed for $ABS — marker updated ($MARKER)" >&2
    echo "  Fix the plan and re-edit to clear this entry, or remove marker manually with explicit approval." >&2
  else
    # Success path: remove this specific plan from the failure list.
    if marker_has_plan "$ABS"; then
      marker_remove_plan "$ABS"
      if [ -f "$MARKER" ]; then
        echo "NOTICE: $ABS now valid — removed from marker (other failed plans remain)" >&2
      else
        echo "NOTICE: coverage matrix now valid for all tracked plans — marker cleared" >&2
      fi
    fi
  fi
done <<< "$FILE_PATHS"

exit 0
