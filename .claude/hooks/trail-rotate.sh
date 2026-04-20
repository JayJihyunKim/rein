#!/bin/bash
# Hook: PreToolUse(Read|Edit|Write|MultiEdit)
# trail 회전 엔진: inbox → daily → weekly + 레거시 DoD 아카이빙
# (하루 1회, 마커 기반 idempotent)
#
# 2026-04 이전 이름: inbox-compress.sh (alias 로 유예 중)
# 항상 exit 0 — 차단하지 않음

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

INBOX_DIR="$PROJECT_DIR/trail/inbox"
DAILY_DIR="$PROJECT_DIR/trail/daily"
WEEKLY_DIR="$PROJECT_DIR/trail/weekly"
DOD_DIR="$PROJECT_DIR/trail/dod"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)
COMPRESS_MARKER="/tmp/.claude-inbox-compressed-${CACHE_KEY}"

TODAY=$(date +%Y-%m-%d)

# ============================================================
# 레거시 DoD 스윕 (마커 검사 이전에 실행 — 업데이트 당일 즉시 청소)
# ============================================================
sweep_legacy_dod() {
  [ -d "$DOD_DIR" ] || return 0

  local LEGACY_ARCHIVE="$DOD_DIR/LEGACY_ARCHIVE.md"
  local LEGACY_COUNT=0

  for f in "$DOD_DIR"/dod-*.md; do
    [ -f "$f" ] || continue
    local fname
    fname=$(basename "$f")

    # 신 포맷(dod-YYYY-MM-DD-*)이면 건너뜀
    [[ "$fname" =~ ^dod-[0-9]{4}-[0-9]{2}-[0-9]{2}- ]] && continue

    # 아카이브 헤더 보장
    if [ ! -f "$LEGACY_ARCHIVE" ]; then
      {
        echo "# Legacy DoD Archive"
        echo ""
        echo "> 날짜 규칙 도입 이전의 DoD 파일을 자동 수집한 아카이브."
        echo ""
      } > "$LEGACY_ARCHIVE" || continue
    fi

    local FILE_MTIME
    FILE_MTIME=$(portable_mtime_date "$f")

    # 원자성: tmp 에 섹션 작성 후 append 성공 시에만 원본 rm
    local TMP_SECTION
    TMP_SECTION=$(mktemp)
    {
      echo "---"
      echo "## $fname (mtime: $FILE_MTIME)"
      cat "$f"
      echo ""
    } > "$TMP_SECTION" || { rm -f "$TMP_SECTION"; continue; }

    if cat "$TMP_SECTION" >> "$LEGACY_ARCHIVE"; then
      rm -f "$TMP_SECTION"
      rm -f "$f"
      LEGACY_COUNT=$((LEGACY_COUNT + 1))
    else
      rm -f "$TMP_SECTION"
    fi
  done

  if [ "$LEGACY_COUNT" -gt 0 ]; then
    echo "NOTICE: ${LEGACY_COUNT}개의 레거시 DoD 파일을 ${LEGACY_ARCHIVE}로 아카이빙했습니다." >&2
  fi
}

sweep_legacy_dod

# 마커가 오늘이면 skip (하루 1회만 실행)
if [ -f "$COMPRESS_MARKER" ] && [ "$(cat "$COMPRESS_MARKER" 2>/dev/null)" = "$TODAY" ]; then
  exit 0
fi

# --- 통합 회전: inbox(driver) + 매칭 dod → daily ---
if [ -d "$INBOX_DIR" ]; then
  for inbox_file in "$INBOX_DIR"/*.md; do
    [ -f "$inbox_file" ] || continue
    fname=$(basename "$inbox_file")

    # YYYY-MM-DD-<slug>.md 형식만 처리
    if ! [[ "$fname" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-(.+)\.md$ ]]; then
      continue
    fi
    inbox_date="${BASH_REMATCH[1]}"
    slug="${BASH_REMATCH[2]}"

    # 오늘 파일은 다음 날에 처리
    [ "$inbox_date" = "$TODAY" ] && continue

    target_daily="$DAILY_DIR/${inbox_date}.md"
    mkdir -p "$DAILY_DIR"

    # 멱등 체크: 이미 병합된 소스면 inbox 만 제거하고 continue
    if [ -f "$target_daily" ] && grep -qF "<!-- source: ${fname} -->" "$target_daily"; then
      rm -f "$inbox_file"
      continue
    fi

    # daily 헤더 보장
    if [ ! -f "$target_daily" ]; then
      {
        echo "# Daily Summary: $inbox_date"
        echo ""
      } > "$target_daily" || continue
    fi

    # 매칭 dod 파일 탐색 (dod/ 내 slug 는 고유)
    dod_match=""
    for d in "$DOD_DIR"/dod-[0-9]*-"$slug".md; do
      [ -f "$d" ] || continue
      d_fname=$(basename "$d")
      d_slug=$(echo "$d_fname" | sed -E 's/^dod-[0-9]{4}-[0-9]{2}-[0-9]{2}-//' | sed 's/\.md$//')
      if [ "$d_slug" = "$slug" ]; then
        dod_match="$d"
        break
      fi
    done

    # 섹션을 tmp 에 완전히 구성한 뒤 한 번에 append
    TMP_SECTION=$(mktemp)
    {
      echo "---"
      echo "<!-- source: ${fname} -->"
      echo "## ${slug}"
      echo ""
      if [ -n "$dod_match" ]; then
        echo "### DoD"
        sed '1{/^# /d;}' "$dod_match"
        echo ""
      fi
      echo "### 완료 기록"
      sed '1{/^# /d;}' "$inbox_file"
      echo ""
    } > "$TMP_SECTION" || { rm -f "$TMP_SECTION"; continue; }

    if cat "$TMP_SECTION" >> "$target_daily"; then
      rm -f "$TMP_SECTION"
      rm -f "$inbox_file"
      [ -n "$dod_match" ] && rm -f "$dod_match"
    else
      rm -f "$TMP_SECTION"
    fi
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
