#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# DoD 파일 없으면 소스 편집 차단
# (inbox 정리는 inbox-compress.sh로 분리됨)
#
# Exit code: 0=허용, 2=차단

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"
DOD_DIR="$PROJECT_DIR/trail/dod"
INBOX_DIR="$PROJECT_DIR/trail/inbox"
SRC_EDIT_MARKER="$DOD_DIR/.session-has-src-edit"
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
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  python3 - "pre-edit-dod-gate" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL"
import json, sys
from datetime import datetime, timezone
print(json.dumps({
  "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
  "hook": sys.argv[1],
  "reason": sys.argv[2],
  "target": sys.argv[3],
}, ensure_ascii=False))
PY

  local count
  count=$(grep -c '"pre-edit-dod-gate"' "$BLOCKS_LOG_JSONL" 2>/dev/null || echo 0)
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
  */.claude/*|*/trail/*|*.gitkeep|*.gitignore)
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
    touch "$SRC_EDIT_MARKER" 2>/dev/null
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

# --- Spec review gate ---
SKIP_SPEC_GATE="$PROJECT_DIR/trail/dod/.skip-spec-gate"
SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"

if [ ! -f "$SKIP_SPEC_GATE" ] && [ -d "$SPEC_REVIEWS_DIR" ]; then
  UNRESOLVED_SPECS=false
  for pending_marker in "$SPEC_REVIEWS_DIR"/*.pending; do
    [ -f "$pending_marker" ] || continue

    spec_path=$(grep -E '^path=' "$pending_marker" 2>/dev/null | head -1 | sed 's/^path=//')
    [ -z "$spec_path" ] && continue

    # spec 파일이 아직 존재하는지 확인
    if [ ! -f "$spec_path" ]; then
      continue
    fi

    # 리뷰 완료 마커가 있는지 확인 (hash.reviewed)
    hash_val=$(basename "$pending_marker" .pending)
    reviewed_marker="$SPEC_REVIEWS_DIR/${hash_val}.reviewed"
    if [ ! -f "$reviewed_marker" ]; then
      UNRESOLVED_SPECS=true
      break
    fi
  done

  if [ "$UNRESOLVED_SPECS" = true ]; then
    echo "BLOCKED: 미리뷰 사양 문서가 있습니다." >&2
    echo "리뷰 완료 후: bash scripts/rein-mark-spec-reviewed.sh \"$spec_path\" codex" >&2
    log_block "미리뷰 사양 문서" "$FILE_PATH"
    exit 2
  fi
fi

# --- 신규: Incident Review Pending 검사 (self-heal 포함) ---
INCIDENT_STAMP="$DOD_DIR/.incident-review-pending"
INCIDENT_BYPASS="$DOD_DIR/.skip-incident-gate"

if [ -f "$INCIDENT_STAMP" ]; then
  # Self-heal: 실시간 pending 재검증
  if command -v python3 >/dev/null 2>&1; then
    LIVE_COUNT=$(python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
      --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null || echo 0)
    if [ "$LIVE_COUNT" -eq 0 ]; then
      rm -f "$INCIDENT_STAMP"  # 자가 치유 — 통과
    elif [ -f "$INCIDENT_BYPASS" ]; then
      REASON=$(grep '^reason=' "$INCIDENT_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
      echo "WARNING: incident gate 1회성 바이패스 — reason: $REASON" >&2
      log_block "incident gate bypass" "$FILE_PATH"
      rm -f "$INCIDENT_BYPASS"
    else
      echo "BLOCKED: 미처리 incident ${LIVE_COUNT}건. 먼저 처리하세요." >&2
      echo "  1) /incidents-to-rule 스킬 호출" >&2
      echo "  2) AskUserQuestion 으로 승격/거부 결정" >&2
      echo "  3) 승인된 rule 을 AGENTS.md 에 추가" >&2
      echo "  4) 각 incident frontmatter status 갱신 (processed/declined)" >&2
      echo "  5) (자동) 다음 source 편집 시 stamp 자가 해소" >&2
      echo "" >&2
      echo "긴급: echo 'reason=<사유>' > $INCIDENT_BYPASS" >&2
      log_block "incident review pending" "$FILE_PATH"
      exit 2
    fi
  fi
fi

# BEGIN D skill-mcp
# (1) DoD 의 '활용 skill/MCP' 섹션 검증 — 가장 최근 mtime 의 active DoD 1건만 검사 (경고만)
if [ -d "$DOD_DIR" ]; then
  # 가장 최근 mtime 의 active dod (인박스 매칭이 아직 없는 것) 1개 선택
  LATEST_ACTIVE_DOD=$(ls -t "$DOD_DIR"/dod-[0-9]*.md 2>/dev/null | head -1)
  if [ -n "$LATEST_ACTIVE_DOD" ] && [ -f "$LATEST_ACTIVE_DOD" ]; then
    if ! grep -q '^## 활용 skill/MCP' "$LATEST_ACTIVE_DOD" 2>/dev/null; then
      echo "WARNING: $(basename "$LATEST_ACTIVE_DOD") 에 '## 활용 skill/MCP' 섹션이 없습니다." >&2
      echo "  .claude/cache/skill-mcp-guide.md 를 참조해 활용할 도구를 명시하세요." >&2
    fi
  fi
fi

# (2) skill/MCP 가이드 재생성 pending 경고 (강제 아님, 반복 알림)
SKILL_REGEN_STAMP="$PROJECT_DIR/.claude/cache/.skill-mcp-regen-pending"
if [ -f "$SKILL_REGEN_STAMP" ]; then
  echo "WARNING: skill/MCP 가이드 재생성 pending. 첫 turn 이 끝나기 전에 LLM 으로 재생성하세요." >&2
  echo "  대상 파일: .claude/cache/skill-mcp-guide.md" >&2
fi
# END D skill-mcp

if [ "$DOD_FOUND" = true ]; then
  touch "$CACHE"
  touch "$SRC_EDIT_MARKER" 2>/dev/null
  exit 0
else
  echo "BLOCKED: 미완료 DoD 파일이 없습니다." >&2
  echo "소스 코드를 편집하기 전에 먼저 trail/dod/dod-$(date +%Y-%m-%d)-<slug>.md 를 작성하세요." >&2
  log_block "미완료 DoD 없음" "$FILE_PATH"
  exit 2
fi
