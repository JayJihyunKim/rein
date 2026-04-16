#!/bin/bash
# Hook: PostToolUse(Edit/Write/MultiEdit) - 소스 코드 편집 시 리뷰 대기 상태 추적
#
# 소스 코드 파일 편집 시 trail/dod/.review-pending 생성
# trail/, docs/, .md 파일은 제외 (규칙/문서 파일)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"

INPUT=$(cat)

# 모든 편집 파일 경로 추출 (MultiEdit는 여러 파일 가능)
FILE_PATHS=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tr = d.get('tool_result', {})
ti = d.get('tool_input', {})
paths = []
# Edit/Write: tool_input.file_path
if 'file_path' in ti:
    paths.append(ti['file_path'])
# MultiEdit: tool_input.edits 또는 tool_result.edits
for src in (ti, tr):
    edits = src.get('edits', [])
    for e in edits:
        fp = e.get('file_path', '')
        if fp and fp not in paths:
            paths.append(fp)
# tool_result.file_path (fallback)
if not paths and 'file_path' in tr:
    paths.append(tr['file_path'])
print('\n'.join(paths))
" 2>/dev/null)

if [ -z "$FILE_PATHS" ]; then
  exit 0
fi

SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|py|sh|yml|yaml|json|toml|css|scss|html|sql|go|rs|java|kt|rb)$'
FOUND_SOURCE=false

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue

  # 제외 경로: trail/, docs/, *.md 파일 (루트 상대경로도 매치)
  case "$FILE_PATH" in
    trail/*|*/trail/*|docs/*|*/docs/*|*.md)
      continue
      ;;
  esac

  # 소스 코드 확장자 확인
  if echo "$FILE_PATH" | grep -qE "$SOURCE_EXT_PATTERN"; then
    FOUND_SOURCE=true
    break
  fi

  # Dockerfile (확장자 없음) 처리
  BASENAME=$(basename "$FILE_PATH")
  if [ "$BASENAME" = "Dockerfile" ] || echo "$BASENAME" | grep -qE "^Dockerfile\."; then
    FOUND_SOURCE=true
    break
  fi
done <<< "$FILE_PATHS"

if [ "$FOUND_SOURCE" = false ]; then
  exit 0
fi

# .review-pending 생성 (이미 있으면 타임스탬프만 갱신)
mkdir -p "$(dirname "$REVIEW_PENDING")"
touch "$REVIEW_PENDING"

exit 0
