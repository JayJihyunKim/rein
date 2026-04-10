#!/bin/bash
# Hook: PreToolUse(Read|Edit|Write|MultiEdit)
# inbox → daily → weekly 자동 정리 (하루 1회)
#
# 항상 exit 0 (차단하지 않음, 정리만 수행)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
DAILY_DIR="$PROJECT_DIR/SOT/daily"
WEEKLY_DIR="$PROJECT_DIR/SOT/weekly"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)
COMPRESS_MARKER="/tmp/.claude-inbox-compressed-${CACHE_KEY}"

TODAY=$(date +%Y-%m-%d)

# 마커가 오늘이면 skip (하루 1회만 실행)
if [ -f "$COMPRESS_MARKER" ] && [ "$(cat "$COMPRESS_MARKER" 2>/dev/null)" = "$TODAY" ]; then
  exit 0
fi

# --- inbox → daily (어제 이전 파일 병합) ---
if [ -d "$INBOX_DIR" ]; then
  for f in "$INBOX_DIR"/*.md; do
    [ -f "$f" ] || continue
    FNAME=$(basename "$f")
    FILE_DATE=$(echo "$FNAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ -z "$FILE_DATE" ] && continue
    [ "$FILE_DATE" = "$TODAY" ] && continue

    DAILY_FILE="$DAILY_DIR/${FILE_DATE}.md"
    mkdir -p "$DAILY_DIR"
    if [ ! -f "$DAILY_FILE" ]; then
      echo "# Daily Summary: $FILE_DATE" > "$DAILY_FILE"
      echo "" >> "$DAILY_FILE"
    fi
    echo "---" >> "$DAILY_FILE"
    cat "$f" >> "$DAILY_FILE"
    echo "" >> "$DAILY_FILE"
    rm "$f"
  done
fi

# --- daily → weekly (7일 이전 파일 병합) ---
if [ -d "$DAILY_DIR" ]; then
  WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null)

  if [ -n "$WEEK_AGO" ]; then
    for f in "$DAILY_DIR"/*.md; do
      [ -f "$f" ] || continue
      FNAME=$(basename "$f" .md)
      echo "$FNAME" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue
      [ "$FNAME" \< "$WEEK_AGO" ] || continue

      # weekly 파일명을 daily 파일의 날짜 기반으로 생성 (현재 날짜 기준 아님)
      FILE_WEEK_NUM=$(date -j -f "%Y-%m-%d" "$FNAME" +%G-W%V 2>/dev/null \
        || date -d "$FNAME" +%G-W%V 2>/dev/null \
        || echo "unknown-week")
      WEEKLY_FILE="$WEEKLY_DIR/${FILE_WEEK_NUM}.md"

      mkdir -p "$WEEKLY_DIR"
      if [ ! -f "$WEEKLY_FILE" ]; then
        echo "# Weekly Summary: $FILE_WEEK_NUM" > "$WEEKLY_FILE"
        echo "" >> "$WEEKLY_FILE"
      fi
      echo "---" >> "$WEEKLY_FILE"
      echo "## $FNAME" >> "$WEEKLY_FILE"
      cat "$f" >> "$WEEKLY_FILE"
      echo "" >> "$WEEKLY_FILE"
      rm "$f"
    done
  fi
fi

# 마커 갱신
echo "$TODAY" > "$COMPRESS_MARKER"

exit 0
