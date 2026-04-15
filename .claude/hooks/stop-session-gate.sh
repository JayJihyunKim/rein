#!/bin/bash
# Hook: Stop - 정상 세션 종료 전 체크리스트 gate
#
# Exit code: 0=허용, 2=차단
# 비정상 종료(Ctrl+C, 터미널 닫기)에서는 실행되지 않음
# 정상 종료 시에만 inbox 기록 + index.md 갱신 여부를 검사

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
DOD_DIR="$PROJECT_DIR/SOT/dod"
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

# --- 14일 이상 미완료 DoD 경고 (차단하지 않음) ---
STALE_DAYS=14
NOW_EPOCH=$(date +%s)

if [ -d "$DOD_DIR" ]; then
  for f in "$DOD_DIR"/dod-[0-9]*.md; do
    [ -f "$f" ] || continue
    FILE_DATE=$(basename "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    [ -z "$FILE_DATE" ] && continue

    FILE_EPOCH=$(date -j -f "%Y-%m-%d" "$FILE_DATE" +%s 2>/dev/null \
               || date -d "$FILE_DATE" +%s 2>/dev/null)
    [ -z "$FILE_EPOCH" ] && continue

    AGE_DAYS=$(( (NOW_EPOCH - FILE_EPOCH) / 86400 ))
    if [ "$AGE_DAYS" -ge "$STALE_DAYS" ]; then
      echo "WARNING: 다음 DoD가 ${AGE_DAYS}일 이상 미완료 상태입니다:" >&2
      echo "  - $(basename "$f")" >&2
      echo "완료 기록을 남기거나 불필요하면 삭제하세요." >&2
    fi
  done
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
