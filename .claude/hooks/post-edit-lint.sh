#!/bin/bash
# Hook: PostToolUse(Edit) - 파일 수정 후 lint/format 자동 실행
#
# settings.json 설정:
# "hooks": { "PostToolUse": [{ "matcher": "Edit|Write",
#   "hooks": [{"type": "command", "command": ".claude/hooks/post-edit-lint.sh"}] }] }

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

EXT="${FILE_PATH##*.}"

case "$EXT" in
  ts|tsx|js|jsx)
    command -v npx > /dev/null 2>&1 && npx eslint "$FILE_PATH" --fix --quiet 2>/dev/null
    ;;
  py)
    if command -v ruff > /dev/null 2>&1; then
      ruff check "$FILE_PATH" --fix --quiet 2>/dev/null
      ruff format "$FILE_PATH" --quiet 2>/dev/null
    fi
    ;;
esac

exit 0
