#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit) - lint + 시크릿 스캔 + console.log 감지
#
# Exit code: 항상 0 (사후 피드백 목적, 차단하지 않음)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

EXT="${FILE_PATH##*.}"

# --- lint/format 실행 ---
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

# --- test 디렉토리 밖 파일만 추가 검사 ---
case "$FILE_PATH" in
  */test/*|*/tests/*|*/__tests__/*|*test_*|*.test.*|*.spec.*)
    exit 0
    ;;
esac

# --- 하드코딩 시크릿 스캔 ---
if grep -qEi "(api[_-]?key|secret|password|token|credential)\s*[:=]\s*[\"'][^\"']{8,}" "$FILE_PATH" 2>/dev/null; then
  echo "WARNING: 하드코딩된 시크릿 패턴이 감지되었습니다: $FILE_PATH" >&2
  echo "환경변수를 사용하세요." >&2
fi

# --- console.log 감지 (JS/TS 파일만) ---
case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs)
    if grep -qE "console\.(log|debug|info)\(" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: console.log가 감지되었습니다: $FILE_PATH" >&2
      echo "운영 코드에서는 logger를 사용하세요." >&2
    fi
    ;;
esac

exit 0
