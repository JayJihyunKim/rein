#!/bin/bash
# Hook: PostToolUse(Write|Edit|MultiEdit)
# canonical 설계 문서 작성 시 pending review 마커 생성

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOD_DIR="$PROJECT_DIR/trail/dod"
SPEC_REVIEWS_DIR="$DOD_DIR/.spec-reviews"

INPUT=$(cat)

# MultiEdit + Edit/Write 모두 지원: 모든 편집 파일 경로 추출
# 기존 post-edit-review-gate.sh 와 동일 패턴
FILE_PATHS=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
tr = d.get("tool_result", {}) or {}
ti = d.get("tool_input", {}) or {}
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
' 2>&1
)
PY_EXIT=$?

# python 에러가 섞였으면 FILE_PATHS 에서 걸러 stderr 로 분리
if [ "$PY_EXIT" -ne 0 ]; then
  echo "WARNING: post-write-spec-review-gate JSON 파싱 실패 — marker 미생성" >&2
  echo "$FILE_PATHS" >&2
  exit 0  # 세션은 차단하지 않음. 사용자가 stderr 를 통해 인지
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
  ABS=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null)
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
