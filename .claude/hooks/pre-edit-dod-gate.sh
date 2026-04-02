#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit) - DoD 파일 없으면 소스 편집 차단
#
# Exit code: 0=허용, 2=차단
# SOT/dod/dod-*.md 파일이 최근 4시간 내 존재해야 소스 편집 허용

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/SOT/incidents/blocks.log"
DOD_DIR="$PROJECT_DIR/SOT/dod"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)
CACHE="/tmp/.claude-dod-${CACHE_KEY}"
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

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# --- 경로 기반 면제 ---
# .claude/, SOT/ 하위 파일은 무조건 통과
case "$FILE_PATH" in
  */.claude/*|*/SOT/*|*.gitkeep|*.gitignore)
    exit 0
    ;;
esac

# --- 소스 디렉토리 한정 gate ---
# 아래 경로 내 파일만 DoD 검사. 그 외는 통과
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
# SOT/dod/dod-*.md 파일이 최근 4시간(14400초) 내 수정된 것이 있는지
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
  # 캐시 갱신
  touch "$CACHE"
  exit 0
else
  echo "BLOCKED: DoD 파일이 없습니다." >&2
  echo "소스 코드를 편집하기 전에 먼저 SOT/dod/dod-[작업명].md를 작성하세요." >&2
  log_block "DoD 파일 미존재" "$FILE_PATH"
  exit 2
fi
