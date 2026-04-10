#!/bin/bash
# Hook: PostToolUse(Edit/Write/MultiEdit) - 소스 코드 편집 시 리뷰 대기 상태 추적
#
# 소스 코드 파일 편집 시 SOT/dod/.review-pending 생성
# SOT/, docs/, .md 파일은 제외 (규칙/문서 파일)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_PENDING="$PROJECT_DIR/SOT/dod/.review-pending"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tr = d.get('tool_result', {})
# Edit/Write는 file_path, MultiEdit는 첫 번째 파일
if 'file_path' in tr:
    print(tr['file_path'])
elif 'edits' in tr and len(tr['edits']) > 0:
    print(tr['edits'][0].get('file_path', ''))
else:
    ti = d.get('tool_input', {})
    print(ti.get('file_path', ''))
" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# 제외 경로: SOT/, docs/, *.md 파일
case "$FILE_PATH" in
  */SOT/*|*/docs/*|*.md)
    exit 0
    ;;
esac

# 소스 코드 확장자 확인
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|py|sh|yml|yaml|json|toml|css|scss|html)$'
if ! echo "$FILE_PATH" | grep -qE "$SOURCE_EXT_PATTERN"; then
  exit 0
fi

# .review-pending 생성 (이미 있으면 타임스탬프만 갱신)
mkdir -p "$(dirname "$REVIEW_PENDING")"
touch "$REVIEW_PENDING"

exit 0
