#!/bin/bash
# Hook: PostToolUse(Write|Edit|MultiEdit)
# canonical 설계 문서 작성 시 pending review 마커 생성

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOD_DIR="$PROJECT_DIR/trail/dod"
SPEC_REVIEWS_DIR="$DOD_DIR/.spec-reviews"

# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"

# Post-hook: Python 미해결 시 조용히 skip (세션 차단 금지).
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit 0
fi

INPUT=$(cat)

# MultiEdit + Edit/Write 모두 지원: 모든 편집 파일 경로 추출.
# 수집 순서(원본 보존): tool_input.file_path → tool_input.edits[*].file_path
#                   → tool_result.edits[*].file_path → tool_result.file_path(fallback only).
# 빈 값/중복은 awk 단계에서 제거 (원본의 `if fp and fp not in paths` 의미 유지).
# 서브쉘에서 pipefail 을 켜서 helper 실패를 정확히 캡처한다.
FILE_PATHS=$(
  set -o pipefail
  printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
    --field tool_input.file_path \
    --array-of tool_input.edits --subfield file_path \
    --array-of tool_result.edits --subfield file_path \
    --default '' 2>/dev/null \
    | awk 'NF && !seen[$0]++'
)
PY_EXIT=$?

# helper 가 실패했으면 세션은 차단하지 않되 사용자가 stderr 로 인지 가능하게 한다.
if [ "$PY_EXIT" -ne 0 ]; then
  echo "WARNING: post-write-spec-review-gate JSON 파싱 실패 — marker 미생성" >&2
  exit 0
fi

# fallback: tool_result.file_path 는 1~3 에서 경로를 찾지 못했을 때만 사용 (Codex final review A4).
if [ -z "$FILE_PATHS" ]; then
  FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
    --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
fi

[ -z "$FILE_PATHS" ] && exit 0

# 해시 계산
compute_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum | cut -c1-16
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha1sum | cut -c1-16
  else
    # fallback: path 끝 12자 + length 접미
    local tail="${input: -12}"
    local len="${#input}"
    printf '%s%d' "$(echo "$tail" | tr -cd 'a-zA-Z0-9')" "$len" | cut -c1-16
  fi
}

# 절대경로 정규화 + canonical 매칭
is_canonical_spec() {
  local abs="$1"
  local rel
  case "$abs" in
    "$PROJECT_DIR"/*) rel="${abs#$PROJECT_DIR/}" ;;
    *) return 1 ;;  # repo 외부는 canonical 아님
  esac
  [[ "$rel" =~ ^(docs(/[^/]+)*/(specs|plans)/.+\.md|specs/.+\.md|plans/.+\.md)$ ]]
}

# 각 파일에 대해 마커 생성 (while 루프가 subshell을 생성하므로 미리 mkdir)
mkdir -p "$SPEC_REVIEWS_DIR"

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue

  # 절대경로 정규화
  ABS=$("${PYTHON_RUNNER[@]}" -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null)
  [ -z "$ABS" ] && continue

  # canonical 매칭
  is_canonical_spec "$ABS" || continue

  HASH=$(compute_hash "$ABS")
  MARKER="$SPEC_REVIEWS_DIR/${HASH}.pending"

  {
    echo "path=$ABS"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
  } > "$MARKER"

  echo "NOTICE: spec review pending — $ABS" >&2
  echo "  리뷰 후: bash scripts/rein-mark-spec-reviewed.sh \"$ABS\" codex" >&2
done <<< "$FILE_PATHS"

exit 0
