#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit)
# 언어중립 hygiene: 하드코딩 시크릿 스캔 + console.log/print 경고
#
# Exit code: 항상 0 (사후 피드백, 차단하지 않음)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"

INPUT=$(cat)

# Python resolver (soft fail, silent — hygiene 은 단순 console.log/시크릿 grep 만
# 수행하는 사후 피드백이므로 resolver 실패 시 조용히 skip). marker 를 생성하지
# 않는다 — 다음 편집을 BLOCK 할 이유가 없다.
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit 0
fi

FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '' 2>/dev/null)

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# test 디렉토리는 제외
case "$FILE_PATH" in
  */test/*|*/tests/*|*/__tests__/*|*test_*|*.test.*|*.spec.*)
    exit 0
    ;;
esac

# 하드코딩 시크릿 스캔 (언어 무관)
if grep -qEi "(api[_-]?key|secret|password|token|credential)\s*[:=]\s*[\"'][^\"']{8,}[\"']" "$FILE_PATH" 2>/dev/null; then
  echo "WARNING: 하드코딩된 시크릿 패턴이 감지되었습니다: $FILE_PATH" >&2
  echo "환경변수 또는 secret manager 를 사용하세요." >&2
fi

# console.log / print 운영 코드 감지
EXT="${FILE_PATH##*.}"
case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs)
    if grep -qE "console\.(log|debug|info)\(" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: console.log/debug/info 가 감지되었습니다: $FILE_PATH" >&2
      echo "운영 코드에서는 logger 를 사용하세요." >&2
    fi
    ;;
  py)
    if grep -qE "^\s*print\(" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: print() 가 감지되었습니다: $FILE_PATH" >&2
      echo "운영 코드에서는 logging 모듈을 사용하세요." >&2
    fi
    ;;
esac

exit 0
