#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# 1. inbox 자동 정리 (어제 이전 파일 → daily로 병합)
# 2. DoD 파일 없으면 소스 편집 차단
#
# Exit code: 0=허용, 2=차단

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/SOT/incidents/blocks.log"
DOD_DIR="$PROJECT_DIR/SOT/dod"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
DAILY_DIR="$PROJECT_DIR/SOT/daily"
WEEKLY_DIR="$PROJECT_DIR/SOT/weekly"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)
CACHE="/tmp/.claude-dod-${CACHE_KEY}"
COMPRESS_MARKER="/tmp/.claude-inbox-compressed-${CACHE_KEY}"
CACHE_TTL=300  # 5분

log_block() {
  local reason="$1"
  local target="$2"
  mkdir -p "$(dirname "$BLOCKS_LOG")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%S)|pre-edit-dod-gate|$reason|$target" >> "$BLOCKS_LOG"

  local count
  count=$(grep -c "pre-edit-dod-gate" "$BLOCKS_LOG" 2>/dev/null || echo 0)
  if [ "$count" -ge 3 ]; then
    echo "WARNING: DoD 미작성 위반 ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: DoD 미작성 위반 ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

# ============================================================
# Part 1: inbox → daily 자동 정리 (세션당 1회)
# ============================================================
# 마커 파일이 오늘 생성되지 않았으면 정리 실행
TODAY=$(date +%Y-%m-%d)

if [ ! -f "$COMPRESS_MARKER" ] || [ "$(cat "$COMPRESS_MARKER" 2>/dev/null)" != "$TODAY" ]; then

  # --- inbox → daily (어제 이전 파일 병합) ---
  if [ -d "$INBOX_DIR" ]; then
    # 날짜별로 파일 수집 (파일명이 YYYY-MM-DD-로 시작하는 것)
    declare -A DATE_FILES 2>/dev/null
    USE_ASSOC=$?

    if [ "$USE_ASSOC" -eq 0 ]; then
      # bash 4+ (associative array 사용)
      for f in "$INBOX_DIR"/*.md; do
        [ -f "$f" ] || continue
        FNAME=$(basename "$f")
        FILE_DATE=$(echo "$FNAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
        [ -z "$FILE_DATE" ] && continue
        [ "$FILE_DATE" = "$TODAY" ] && continue  # 오늘 파일은 건너뜀
        DATE_FILES["$FILE_DATE"]+="$f "
      done

      for DATE in "${!DATE_FILES[@]}"; do
        DAILY_FILE="$DAILY_DIR/${DATE}.md"
        mkdir -p "$DAILY_DIR"
        echo "# Daily Summary: $DATE" > "$DAILY_FILE"
        echo "" >> "$DAILY_FILE"
        for f in ${DATE_FILES[$DATE]}; do
          echo "---" >> "$DAILY_FILE"
          cat "$f" >> "$DAILY_FILE"
          echo "" >> "$DAILY_FILE"
          rm "$f"
        done
      done
    else
      # bash 3 (macOS 기본) - associative array 없음, 단순 처리
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
  fi

  # --- daily → weekly (지난주 이전 파일 병합) ---
  if [ -d "$DAILY_DIR" ]; then
    # 7일 전 날짜 계산
    WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null)

    if [ -n "$WEEK_AGO" ]; then
      WEEK_NUM=$(date +%Y-W%V)
      WEEKLY_FILE="$WEEKLY_DIR/${WEEK_NUM}.md"
      WEEKLY_MERGED=false

      for f in "$DAILY_DIR"/*.md; do
        [ -f "$f" ] || continue
        FNAME=$(basename "$f" .md)
        # 파일명이 날짜 형식인지 확인
        echo "$FNAME" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue
        # 7일 전보다 오래된 파일만
        [ "$FNAME" \< "$WEEK_AGO" ] || continue

        mkdir -p "$WEEKLY_DIR"
        if [ "$WEEKLY_MERGED" = false ]; then
          if [ ! -f "$WEEKLY_FILE" ]; then
            echo "# Weekly Summary: $WEEK_NUM" > "$WEEKLY_FILE"
            echo "" >> "$WEEKLY_FILE"
          fi
          WEEKLY_MERGED=true
        fi
        echo "---" >> "$WEEKLY_FILE"
        echo "## $FNAME" >> "$WEEKLY_FILE"
        cat "$f" >> "$WEEKLY_FILE"
        echo "" >> "$WEEKLY_FILE"
        rm "$f"
      done
    fi
  fi

  # 마커 갱신 (오늘 날짜 기록)
  echo "$TODAY" > "$COMPRESS_MARKER"
fi

# ============================================================
# Part 2: DoD gate (기존 로직)
# ============================================================
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# --- 경로 기반 면제 ---
case "$FILE_PATH" in
  */.claude/*|*/SOT/*|*.gitkeep|*.gitignore)
    exit 0
    ;;
esac

# --- 소스 디렉토리 한정 gate ---
IS_SOURCE=false
case "$FILE_PATH" in
  */src/*|*/app/*|*/services/*|*/apps/*|*/lib/*|*/components/*|*/hooks/*|*/store/*|*/types/*|*/models/*|*/schemas/*|*/repositories/*|*/routers/*|*/alembic/*)
    IS_SOURCE=true
    ;;
esac

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# --- 캐시 확인 ---
if [ -f "$CACHE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
    exit 0
  fi
fi

# --- DoD 파일 존재 확인 ---
DOD_FOUND=false
if [ -d "$DOD_DIR" ]; then
  for f in "$DOD_DIR"/dod-*.md; do
    [ -f "$f" ] || continue
    FILE_AGE=$(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if [ "$FILE_AGE" -lt 14400 ]; then
      DOD_FOUND=true
      break
    fi
  done
fi

if [ "$DOD_FOUND" = true ]; then
  touch "$CACHE"
  exit 0
else
  echo "BLOCKED: DoD 파일이 없습니다." >&2
  echo "소스 코드를 편집하기 전에 먼저 SOT/dod/dod-[작업명].md를 작성하세요." >&2
  log_block "DoD 파일 미존재" "$FILE_PATH"
  exit 2
fi
