#!/bin/bash
# Hook: Stop - 정상 세션 종료 전 체크리스트 gate
#
# Exit code: 0=허용, 2=차단
# 비정상 종료(Ctrl+C, 터미널 닫기)에서는 실행되지 않음
# 정상 종료 시에만 inbox 기록 + index.md 갱신 여부를 검사

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
INDEX_FILE="$PROJECT_DIR/SOT/index.md"
TODAY=$(date +%Y-%m-%d)

MISSING=""

# --- inbox 작업 기록 확인 ---
# 오늘 날짜로 시작하는 파일이 있는지
INBOX_TODAY=false
if [ -d "$INBOX_DIR" ]; then
  for f in "$INBOX_DIR"/${TODAY}-*.md; do
    if [ -f "$f" ]; then
      INBOX_TODAY=true
      break
    fi
  done
fi

if [ "$INBOX_TODAY" = false ]; then
  MISSING="${MISSING}\n- SOT/inbox/${TODAY}-[작업명].md 가 없습니다. 작업 기록을 남겨주세요."
fi

# --- SOT/index.md 갱신 확인 ---
# 오늘 수정되었는지 (mtime 기준)
if [ -f "$INDEX_FILE" ]; then
  INDEX_DATE=$(date -r "$INDEX_FILE" +%Y-%m-%d 2>/dev/null || stat -c %y "$INDEX_FILE" 2>/dev/null | cut -d' ' -f1)
  if [ "$INDEX_DATE" != "$TODAY" ]; then
    MISSING="${MISSING}\n- SOT/index.md가 오늘 갱신되지 않았습니다."
  fi
fi

# --- 결과 판정 ---
if [ -n "$MISSING" ]; then
  echo "BLOCKED: 세션 종료 전 완료되지 않은 항목이 있습니다." >&2
  echo -e "$MISSING" >&2
  echo "" >&2
  echo "위 항목을 완료한 후 다시 종료하세요." >&2
  exit 2
fi

exit 0
