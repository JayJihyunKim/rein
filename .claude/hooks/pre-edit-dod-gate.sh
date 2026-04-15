#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# DoD 파일 없으면 소스 편집 차단
# (inbox 정리는 inbox-compress.sh로 분리됨)
#
# Exit code: 0=허용, 2=차단

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/SOT/incidents/blocks.log"
DOD_DIR="$PROJECT_DIR/SOT/dod"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)

# Portable mtime extractor: returns epoch seconds.
# macOS uses BSD stat (-f %m), Linux/WSL/Git Bash/Cygwin use GNU stat (-c %Y).
_mtime() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

# 캐시 키에 dod/inbox 디렉토리의 최신 mtime 을 혼입 (Codex 리뷰 완화책):
# inbox 파일이 생기는 순간 디렉토리 mtime 이 갱신되어 캐시가 즉시 무효화됨.
DIR_MTIME=$(
  {
    _mtime "$DOD_DIR"
    _mtime "$INBOX_DIR"
  } | sort -nr | head -1
)
CACHE="/tmp/.claude-dod-${CACHE_KEY}-${DIR_MTIME:-0}"
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
# DoD gate
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
  */src/*|*/app/*|*/services/*|*/apps/*|*/lib/*|*/components/*|*/hooks/*|*/store/*|*/types/*|*/models/*|*/schemas/*|*/repositories/*|*/routers/*|*/alembic/*|*/scripts/*|scripts/*)
    IS_SOURCE=true
    ;;
esac

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# --- 캐시 확인 ---
if [ -f "$CACHE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(_mtime "$CACHE") ))
  if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
    exit 0
  fi
fi

# --- Pending DoD 판정 (inbox-매칭 기반) ---
# pending = 신 포맷 dod 파일 존재 AND 같은 slug 의 inbox 파일 없음
DOD_FOUND=false
if [ -d "$DOD_DIR" ]; then
  for dod_file in "$DOD_DIR"/dod-*.md; do
    [ -f "$dod_file" ] || continue
    fname=$(basename "$dod_file")

    # 신 포맷만 처리 (레거시는 별도 스윕)
    echo "$fname" | grep -q '^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-' || continue

    slug=$(echo "$fname" | sed 's/^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | sed 's/\.md$//')

    # inbox/ 에 slug 완전 일치하는 파일이 있는지
    matched=false
    if [ -d "$INBOX_DIR" ]; then
      for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
        [ -f "$inbox_file" ] || continue
        inbox_slug_val=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
        if [ "$inbox_slug_val" = "$slug" ]; then
          matched=true
          break
        fi
      done
    fi

    if [ "$matched" = false ]; then
      DOD_FOUND=true
      break
    fi
  done
fi

if [ "$DOD_FOUND" = true ]; then
  touch "$CACHE"
  exit 0
else
  echo "BLOCKED: 미완료 DoD 파일이 없습니다." >&2
  echo "소스 코드를 편집하기 전에 먼저 SOT/dod/dod-$(date +%Y-%m-%d)-<slug>.md 를 작성하세요." >&2
  log_block "미완료 DoD 없음" "$FILE_PATH"
  exit 2
fi
