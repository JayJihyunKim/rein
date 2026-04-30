#!/bin/bash
# Hook: PreToolUse(Read|Edit|Write|MultiEdit)
# trail 회전 엔진: inbox → daily → weekly + 레거시 DoD 아카이빙
# (하루 1회, 마커 기반 idempotent)
#
# 2026-04 이전 이름: inbox-compress.sh (alias 로 유예 중)
# 항상 exit 0 — 차단하지 않음

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

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

# --- orphan 완료 DoD 보정 스윕 ---
# 정상 경로에서는 inbox driver 가 DoD 를 daily 로 병합한 직후 원본을 삭제한다.
# 과거 데이터나 slug 변경으로 inbox 원본이 먼저 사라진 경우에는 완료 기록만
# daily/weekly 에 남고 DoD 가 계속 active 후보로 떠서, 완료 증거가 명확한
# 과거 DoD 만 별도 아카이브한다.
completed_dod_has_archive_evidence() {
  local dod_fname="$1"
  local slug="$2"
  local archive_file

  for archive_file in "$DAILY_DIR"/*.md "$WEEKLY_DIR"/*.md; do
    [ -f "$archive_file" ] || continue
    awk -v slug="$slug" -v dod_fname="$dod_fname" '
      index($0, dod_fname) > 0 { found=1; exit }

      $0 == "## " slug { found=1; exit }

      /^<!--[[:space:]]source:[[:space:]]/ {
        line = $0
        sub(/^<!--[[:space:]]source:[[:space:]]/, "", line)
        sub(/[[:space:]]*-->$/, "", line)
        if (line ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-.*[.]md$/) {
          source_slug = line
          sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-/, "", source_slug)
          sub(/[.]md$/, "", source_slug)
          if (source_slug == slug) { found=1; exit }
        }
      }

      END { exit(found ? 0 : 1) }
    ' "$archive_file" 2>/dev/null && return 0
  done

  return 1
}

dod_has_matching_inbox() {
  local slug="$1"
  local inbox_file inbox_slug

  [ -d "$INBOX_DIR" ] || return 1
  for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
    [ -f "$inbox_file" ] || continue
    inbox_slug=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    [ "$inbox_slug" = "$slug" ] && return 0
  done

  return 1
}

sweep_orphan_completed_dod() {
  [ -d "$DOD_DIR" ] || return 0

  local COMPLETED_ARCHIVE="$DOD_DIR/COMPLETED_ARCHIVE.md"
  local COMPLETED_COUNT=0

  for f in "$DOD_DIR"/dod-[0-9]*.md; do
    [ -f "$f" ] || continue

    local fname file_date slug
    fname=$(basename "$f")
    file_date=$(echo "$fname" | grep -oE '^[^0-9]*[0-9]{4}-[0-9]{2}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    [ -n "$file_date" ] || continue

    # 오늘/미래 DoD 는 아직 작업 중일 수 있으므로 보정 스윕 대상에서 제외.
    [ "$file_date" \< "$TODAY" ] || continue

    slug=$(echo "$fname" | sed -E 's/^dod-[0-9]{4}-[0-9]{2}-[0-9]{2}-//' | sed 's/\.md$//')
    [ -n "$slug" ] || continue

    # 정상 회전 대상은 inbox driver 가 DoD 를 daily 에 병합하도록 둔다.
    dod_has_matching_inbox "$slug" && continue

    completed_dod_has_archive_evidence "$fname" "$slug" || continue

    if [ ! -f "$COMPLETED_ARCHIVE" ]; then
      {
        echo "# Completed DoD Archive"
        echo ""
        echo "> inbox driver 를 잃었지만 daily/weekly 에 완료 증거가 있는 DoD 를 자동 수집한 아카이브."
        echo ""
      } > "$COMPLETED_ARCHIVE" || continue
    fi

    local FILE_MTIME TMP_SECTION
    FILE_MTIME=$(portable_mtime_date "$f")
    TMP_SECTION=$(mktemp)
    {
      echo "---"
      echo "## $fname (mtime: $FILE_MTIME, archived: $TODAY)"
      cat "$f"
      echo ""
    } > "$TMP_SECTION" || { rm -f "$TMP_SECTION"; continue; }

    if cat "$TMP_SECTION" >> "$COMPLETED_ARCHIVE"; then
      rm -f "$TMP_SECTION"
      rm -f "$f"
      COMPLETED_COUNT=$((COMPLETED_COUNT + 1))
    else
      rm -f "$TMP_SECTION"
    fi
  done

  if [ "$COMPLETED_COUNT" -gt 0 ]; then
    echo "NOTICE: ${COMPLETED_COUNT}개의 완료 DoD 파일을 ${COMPLETED_ARCHIVE}로 아카이빙했습니다." >&2
  fi
}

sweep_orphan_completed_dod

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
