#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# DoD 파일 없으면 소스 편집 차단
# (inbox 정리는 trail-rotate (구 inbox-compress).sh로 분리됨)
#
# Exit code: 0=허용, 2=차단

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"
DOD_DIR="$PROJECT_DIR/trail/dod"
INBOX_DIR="$PROJECT_DIR/trail/inbox"
SRC_EDIT_MARKER="$DOD_DIR/.session-has-src-edit"
CACHE_KEY=$(echo "${PROJECT_DIR}" | md5 -q 2>/dev/null || echo "${PROJECT_DIR}" | md5sum 2>/dev/null | cut -c1-8)

# 캐시 키에 dod/inbox 디렉토리의 최신 mtime 을 혼입 (Codex 리뷰 완화책):
# inbox 파일이 생기는 순간 디렉토리 mtime 이 갱신되어 캐시가 즉시 무효화됨.
DIR_MTIME=$(
  {
    portable_mtime_epoch "$DOD_DIR"
    portable_mtime_epoch "$INBOX_DIR"
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

  # hook+reason 조합별로 카운트 (aggregate THRESHOLD 와 동일 기준).
  # 전체 hook 누적이 아닌 "동일 위반 패턴" 반복을 정확히 측정하기 위함.
  local count
  if command -v python3 >/dev/null 2>&1; then
    count=$(python3 -c "
import json, sys
target_hook = 'pre-edit-dod-gate'
target_reason = sys.argv[1]
n = 0
try:
    with open(sys.argv[2]) as f:
        for line in f:
            try:
                e = json.loads(line)
                if e.get('hook') == target_hook and e.get('reason') == target_reason:
                    n += 1
            except Exception:
                continue
except OSError:
    pass
print(n)
" "$reason" "$BLOCKS_LOG_JSONL" 2>/dev/null || echo 0)
  else
    count=0
  fi
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

# ============================================================
# DoD gate
# ============================================================
INPUT=$(cat)

# python3 필수 (JSON 파싱). 없으면 Edit/Write 차단 (fail-closed).
# 예전 `2>/dev/null` 방식은 python3 미설치 시 FILE_PATH="" → exit 0 으로 gate
# 전체가 무력화됐음 (codex v0.7.2 review Critical).
if ! command -v python3 >/dev/null 2>&1; then
  echo "BLOCKED: python3 가 PATH 에 없습니다 (DoD gate 필수 의존성)." >&2
  exit 2
fi

FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))")
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "BLOCKED: Edit/Write 입력 파싱 실패 (python3 exit $EXTRACT_RC)." >&2
  exit 2
fi

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

# --- Incident Review Pending 검사 (cache 보다 앞. self-heal 포함) ---
# cache hit 로 우회되면 안 되는 gate. 항상 실시간 검증.
INCIDENT_STAMP="$DOD_DIR/.incident-review-pending"
INCIDENT_BYPASS="$DOD_DIR/.skip-incident-gate"

if [ -f "$INCIDENT_STAMP" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    # python3 필수 의존성. fail-closed 로 gate 우회 방지.
    echo "BLOCKED: python3 미설치로 incident gate 검증 불가." >&2
    echo "python3 설치 후 재시도하거나, 확인 후 stamp 를 수동 제거: rm $INCIDENT_STAMP" >&2
    exit 2
  fi
  # exit code 를 분리 캡처하여 스크립트 실패 시 fail-closed 로 처리한다.
  # `|| echo 0` 방식은 실패 시에도 0 으로 보여 stamp 를 잘못 지우고 통과시켰음
  # (codex v0.7.2 review High).
  LIVE_COUNT=$(python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null)
  LIVE_RC=$?
  if [ "$LIVE_RC" -ne 0 ]; then
    echo "BLOCKED: incident count 검증 실패 (exit $LIVE_RC)." >&2
    log_block "incident count 검증 실패" "$FILE_PATH"
    exit 2
  fi
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
    echo "  4) python3 scripts/rein-mark-incident-processed.py <path> <processed|declined>" >&2
    echo "  5) (자동) 다음 source 편집 시 stamp 자가 해소" >&2
    echo "" >&2
    echo "긴급: echo 'reason=<사유>' > $INCIDENT_BYPASS" >&2
    log_block "incident review pending" "$FILE_PATH"
    exit 2
  fi
fi

# --- 캐시 확인 ---
if [ -f "$CACHE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(portable_mtime_epoch "$CACHE") ))
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

# BEGIN routing-gate
# DoD 의 '## 라우팅 추천' 섹션 + approved_by_user: true 검증.
# active DoD (= 신포맷 dod 파일 존재 AND 같은 slug inbox 파일 없음) 전체를 검사.
# 섹션 있으면서 approved_by_user 가 누락/false 인 경우 BLOCK. 섹션 아예 없는 경우도 BLOCK.
#
# 바이패스: trail/dod/.skip-routing-gate 마커 (reason 기록 후 1회 사용 → 자동 삭제)
ROUTING_BYPASS="$DOD_DIR/.skip-routing-gate"
ACTIVE_DODS_TMP=$(mktemp)
# (a) 신규 DoD 섹션 누락 차단: post-write-dod-routing-check.sh 가 DoD 작성 시
#     '## 라우팅 추천' 섹션 없으면 .routing-missing-<basename> 마커를 남긴다.
#     마커가 있으면 바로 BLOCK. legacy DoD 는 post-write 이전에 작성된 것이라 마커 없음.
shopt -s nullglob
MISSING_MARKERS=("$DOD_DIR"/.routing-missing-*)
shopt -u nullglob
if [ "${#MISSING_MARKERS[@]}" -gt 0 ]; then
  if [ -f "$ROUTING_BYPASS" ]; then
    REASON=$(grep '^reason=' "$ROUTING_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
    echo "WARNING: routing gate 1회성 바이패스 (missing section) — reason: $REASON" >&2
    log_block "routing missing section bypass" "$FILE_PATH"
    rm -f "$ROUTING_BYPASS"
  else
    echo "BLOCKED: 다음 DoD 에 '## 라우팅 추천' 섹션이 없습니다:" >&2
    for m in "${MISSING_MARKERS[@]}"; do
      echo "  - $(basename -- "$m" | sed 's/^\.routing-missing-//')" >&2
    done
    echo "  orchestrator.md '스마트 라우팅 절차' 를 따라 섹션을 추가하세요." >&2
    echo "  긴급 바이패스: echo 'reason=<사유>' > $ROUTING_BYPASS" >&2
    log_block "routing section missing" "$FILE_PATH"
    exit 2
  fi
fi

# (b) 섹션이 있는 active DoD 는 approved_by_user: true 강제.

if [ -d "$DOD_DIR" ]; then
  for dod_file in "$DOD_DIR"/dod-[0-9]*.md; do
    [ -f "$dod_file" ] || continue
    fname=$(basename "$dod_file")
    echo "$fname" | grep -q '^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-' || continue

    # opt-in: `## 라우팅 추천` 섹션이 없으면 enforcement 대상 외
    if ! grep -q '^## 라우팅 추천' "$dod_file" 2>/dev/null; then
      continue
    fi

    dod_slug=$(echo "$fname" | sed 's/^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | sed 's/\.md$//')

    is_active=true
    if [ -d "$INBOX_DIR" ]; then
      for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
        [ -f "$inbox_file" ] || continue
        inbox_slug_val=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
        if [ "$inbox_slug_val" = "$dod_slug" ]; then
          is_active=false
          break
        fi
      done
    fi

    if [ "$is_active" = true ]; then
      printf '%s\n' "$dod_file" >> "$ACTIVE_DODS_TMP"
    fi
  done
fi

ROUTING_VIOLATIONS=""
while IFS= read -r active_dod; do
  [ -z "$active_dod" ] && continue
  [ -f "$active_dod" ] || continue
  # `## 라우팅 추천` 섹션 범위만 추출 (다음 `^## ` 직전까지).
  # approved_by_user: true (선택적 inline # 주석 허용) 이 범위 내에 있어야 통과.
  # awk: 첫 `## 라우팅 추천` 섹션만 추출. 중복 섹션이 있어도 이어붙이지 않는다.
  SECTION=$(awk '
    /^## 라우팅 추천/ {if (!seen) {in_sec=1; seen=1}; next}
    in_sec && /^## / {in_sec=0}
    in_sec {print}
  ' "$active_dod" 2>/dev/null)
  # 이 루프에 들어온 시점에서 섹션 존재는 이미 확인됨.
  if ! printf '%s\n' "$SECTION" | grep -qE '^[[:space:]]*approved_by_user:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$'; then
    ROUTING_VIOLATIONS="$ROUTING_VIOLATIONS
  - $(basename "$active_dod"): 섹션 내 approved_by_user: true 없음 (pending/false)"
  fi
done < "$ACTIVE_DODS_TMP"
rm -f "$ACTIVE_DODS_TMP"

if [ -n "$ROUTING_VIOLATIONS" ]; then
  if [ -f "$ROUTING_BYPASS" ]; then
    REASON=$(grep '^reason=' "$ROUTING_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
    echo "WARNING: routing gate 1회성 바이패스 — reason: $REASON" >&2
    log_block "routing gate bypass" "$FILE_PATH"
    rm -f "$ROUTING_BYPASS"
  else
    printf "BLOCKED: active DoD 의 '## 라우팅 추천' 섹션 위반:%b\n" "$ROUTING_VIOLATIONS" >&2
    echo "  orchestrator.md '스마트 라우팅 절차' 를 따라 추천 조합 + approved_by_user: true 를 기록하세요." >&2
    echo "  긴급 바이패스: echo 'reason=<사유>' > $ROUTING_BYPASS" >&2
    log_block "routing section 위반" "$FILE_PATH"
    exit 2
  fi
fi

# skill/MCP 가이드 재생성 pending: 자동 생성 시도 → 실패 시 WARNING 만 (block 아님)
SKILL_REGEN_STAMP="$PROJECT_DIR/.claude/cache/.skill-mcp-regen-pending"
if [ -f "$SKILL_REGEN_STAMP" ]; then
  if [ -x "$PROJECT_DIR/scripts/rein-generate-skill-mcp-guide.py" ] || [ -f "$PROJECT_DIR/scripts/rein-generate-skill-mcp-guide.py" ]; then
    ( cd "$PROJECT_DIR" && python3 scripts/rein-generate-skill-mcp-guide.py >/dev/null 2>&1 ) || \
      echo "WARNING: skill-mcp-guide 자동 생성 실패 (stamp 유지)" >&2
  else
    echo "WARNING: skill/MCP 가이드 재생성 pending. .claude/cache/skill-mcp-guide.md 를 확인하세요." >&2
  fi
fi
# END routing-gate

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
