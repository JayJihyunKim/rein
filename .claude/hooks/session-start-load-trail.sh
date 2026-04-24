#!/bin/bash
# Hook: SessionStart
# trail 프로젝트 상태를 세션 시작 시 에이전트 컨텍스트로 주입.
#
# 출력: stdout → Claude Code 가 additionalContext 로 흡수
# 실패해도 세션은 계속됨 (항상 exit 0)
#
# 환경변수:
#   REIN_NOW       — 기준 시각 (YYYY-MM-DD). 미설정 시 현재 시각. 테스트용
#   REIN_BUDGET_BYTES — 총 누적 바이트 상한 (기본 65536). 초과 시 이후 파일은 제목만

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

# sandbox/테스트용 override — 설정 시 이 값 사용, 아니면 기본 경로 계산
PROJECT_DIR="${REIN_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BUDGET_BYTES="${REIN_BUDGET_BYTES:-65536}"
USED_BYTES=0
TRUNCATED=false

# REIN_NOW 를 date 명령에 주입할 형식으로 정규화
now_week_offset() {
  # $1 = weeks ago (0,1,2,3)
  local i="$1"
  if [ -n "${REIN_NOW:-}" ]; then
    # 고정 시각 기준
    date -j -v-${i}w -f "%Y-%m-%d" "$REIN_NOW" +%G-W%V 2>/dev/null \
      || date -d "$REIN_NOW ${i} weeks ago" +%G-W%V 2>/dev/null
  else
    date -v-${i}w +%G-W%V 2>/dev/null \
      || date -d "${i} weeks ago" +%G-W%V 2>/dev/null
  fi
}

emit_file_block() {
  # $1 = 파일 경로 (프로젝트 루트 기준 상대 경로)
  local rel="$1"
  local abs="$PROJECT_DIR/$rel"
  [ -f "$abs" ] || return 0

  local sz
  sz=$(portable_stat_size "$abs")

  # 예산 초과 시 제목만 출력
  if [ "$((USED_BYTES + sz))" -gt "$BUDGET_BYTES" ]; then
    echo "### $rel (${sz}B, truncated — budget reached)"
    echo
    TRUNCATED=true
    return 0
  fi

  echo "### $rel"
  echo '```markdown'
  cat "$abs"
  echo '```'
  echo
  USED_BYTES=$((USED_BYTES + sz))
}

# 이전 세션 잔존 마커 초기화
rm -f "$PROJECT_DIR/trail/dod/.session-has-src-edit" 2>/dev/null
# .incident-decision-deferred 는 세션 스코프 — 새 세션에서 재질문 되도록 삭제
rm -f "$PROJECT_DIR/trail/dod/.incident-decision-deferred" 2>/dev/null

# active-dod-choice session flag sweep — select-active-dod.sh 의 "세션당 1회
# 로그" 세마포어가 세션 종료 시 누락되어 누적되는 현상 보완. 1시간 초과된
# flag 만 제거하므로 현재 진행 중인 다른 세션의 fresh flag 는 건드리지 않음.
# find -mmin +60 은 GNU/BSD/MSYS find 모두 지원. 실패해도 세션 로딩은 계속.
find "$PROJECT_DIR/.claude/cache" -maxdepth 1 -type f \
  -name 'active-dod-choice.session-*.flag' \
  -mmin +60 -delete 2>/dev/null || true

cd "$PROJECT_DIR" || exit 0

# Legacy-shipped pending 자동 healing (rein-heal-legacy-pending.py)
# git tag 에 이미 포함된 dev-only 문서 (dev commit ts <= tag ts) 의 .pending 을
# .reviewed (reviewer=retrospective-shipped-<tag>) 로 auto-stamp.
# **Freshness check**: pending marker 의 created= 가 tag 이전이어야 heal 됨 (fresh
# unreviewed pending 은 gate 유지).
# 실패 시: 전체 stderr 를 suppress 하지 않고 1 줄 warning 만 세션 로그에 기록 —
# python3 resolution 문제가 silent 하게 사라지지 않도록.
HEAL_SCRIPT="$PROJECT_DIR/scripts/rein-heal-legacy-pending.py"
if [ -f "$HEAL_SCRIPT" ]; then
  # python3 해석은 hook lib 의 portable 경로 사용 (PYTHON_RUNNER bash array 계약).
  # python-runner.sh 를 source 해 resolve_python() 으로 적절한 interpreter 선택.
  HEAL_LOG="$PROJECT_DIR/trail/incidents/rein-heal-session.log"
  if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
    # shellcheck source=./lib/python-runner.sh
    . "$SCRIPT_DIR/lib/python-runner.sh"
    if resolve_python 2>/dev/null; then
      HEAL_ERR=$("${PYTHON_RUNNER[@]}" "$HEAL_SCRIPT" --quiet 2>&1 >/dev/null); HEAL_RC=$?
    else
      HEAL_RC=127
      HEAL_ERR="resolve_python failed — no usable python interpreter"
    fi
  else
    # python-runner.sh 부재 시 fallback — 단일 토큰만 지원, multi-token runner 깨짐.
    HEAL_ERR=$(python3 "$HEAL_SCRIPT" --quiet 2>&1 >/dev/null); HEAL_RC=$?
  fi
  if [ ${HEAL_RC:-1} -ne 0 ]; then
    # 실패 경로 visible 로 남김 — gate 가 계속 block 하면 여기 로그 확인
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] rein-heal-legacy-pending FAILED rc=$HEAL_RC: $HEAL_ERR" \
      >> "$HEAL_LOG" 2>/dev/null || true
    # 세션 컨텍스트에도 짧은 경고 (agent 가 인지)
    echo "### ⚠️ rein-heal-legacy-pending 실패 (rc=$HEAL_RC) — $HEAL_LOG 참조"
    echo
  fi
fi

echo "## trail 세션 시작 컨텍스트"
echo
echo "> 자동 로드: index.md + inbox 전량 + daily 전량 + weekly 최근 4주"
echo "> 예산: ${BUDGET_BYTES}B (초과 시 이후 파일은 제목만 표시)"
echo

# 0. B2 pending spec review 요약 (있을 때만)
SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"
if [ -d "$SPEC_REVIEWS_DIR" ]; then
  PENDING_COUNT=0
  PENDING_LIST=""
  for marker in "$SPEC_REVIEWS_DIR"/*.pending; do
    [ -f "$marker" ] || continue
    PATH_LINE=$(grep '^path=' "$marker" | cut -d= -f2- || true)
    PENDING_COUNT=$((PENDING_COUNT + 1))
    PENDING_LIST="${PENDING_LIST}  - ${PATH_LINE}"$'\n'
  done
  if [ "$PENDING_COUNT" -gt 0 ]; then
    echo "### ⚠️ 미해결 spec review: ${PENDING_COUNT}건"
    echo '```'
    printf '%s' "$PENDING_LIST"
    echo '```'
    echo "소스 편집 전 \`/codex-review\` 로 리뷰하거나 대체 경로로 해소 필요."
    echo
  fi
fi

# 미처리 incident 요약 + gate stamp 관리
INCIDENTS_DIR="$PROJECT_DIR/trail/incidents"
STAMP_FILE="$PROJECT_DIR/trail/dod/.incident-review-pending"

# 세션 스코프 stamp/카운터 무조건 초기화.
# python3 부재 또는 incidents 디렉토리 부재여도 이전 세션의 stamp 가 누수되지
# 않도록 조건문 밖으로 이동 (codex v0.7.2 review Medium).
rm -f "$PROJECT_DIR/trail/dod/.incident-decision-deferred"
rm -f "$PROJECT_DIR/trail/dod/.incident-stop-blocks"
rm -f "$PROJECT_DIR/trail/dod/.incident-stop-hashes"

if command -v python3 >/dev/null 2>&1 && [ -d "$INCIDENTS_DIR" ]; then
  # 비정상 종료 감지
  SNAPSHOT="$PROJECT_DIR/trail/incidents/.last-aggregate-state.json"
  if [ -f "$SNAPSHOT" ] && command -v python3 >/dev/null 2>&1; then
    ABNORMAL=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print('1' if not d.get('session_end', False) else '0')
except Exception:
    print('0')
" "$SNAPSHOT" 2>/dev/null)
    if [ "$ABNORMAL" = "1" ]; then
      echo "### ⚠️ 직전 세션 비정상 종료 감지"
      echo
      echo "마지막 aggregate 이후 Stop hook 이 정상 실행되지 않았습니다."
      echo "pending incident 가 있으면 이번 세션에서 처리됩니다."
      echo
    fi
  fi

  # 세션 시작 시 aggregate 한 번 실행 (비정상 종료로 stop-gate 를 놓친 세션의
  # blocks.jsonl 신규 라인을 반영). flock 으로 동시성 안전.
  python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    --project-dir "$PROJECT_DIR" >/dev/null 2>&1 || true

  # --- H3.2: session-start-line stamp (recovery aggregate 완료 후) ---
  # 순서 중요: ① recovery aggregate (위) → ② blocks.jsonl line count → ③ stamp 원자적 쓰기
  # stamp 값은 "이번 세션이 시작할 line 번호" = 현재 line_count + 1
  _write_session_start_line() {
    local BLOCKS_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"
    local STAMP="$PROJECT_DIR/trail/incidents/.session-start-line"
    mkdir -p "$(dirname "$STAMP")" 2>/dev/null || return 0
    local line_count=0
    if [ -f "$BLOCKS_JSONL" ]; then
      line_count=$(wc -l < "$BLOCKS_JSONL" | tr -d ' ')
    fi
    local next_line=$((line_count + 1))
    local tmp="${STAMP}.tmp.$$"
    echo "$next_line" > "$tmp" && mv "$tmp" "$STAMP"
  }
  _write_session_start_line

  PENDING=$(python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null || echo 0)

  if [ "$PENDING" -gt 0 ]; then
    echo "### 미처리 incident: ${PENDING}건"
    echo
    echo "**첫 source 편집 시도가 차단됩니다.** \`incidents-to-rule\` 스킬 호출 + AskUserQuestion 으로 처리하세요."
    echo
    mkdir -p "$(dirname "$STAMP_FILE")"
    touch "$STAMP_FILE"
  else
    rm -f "$STAMP_FILE"
  fi
fi

# 1. index.md
emit_file_block "trail/index.md"

# 2. inbox 전량
if [ -d "trail/inbox" ]; then
  for f in trail/inbox/*.md; do
    [ -f "$f" ] || continue
    emit_file_block "$f"
  done
fi

# 3. daily 전량
if [ -d "trail/daily" ]; then
  for f in trail/daily/*.md; do
    [ -f "$f" ] || continue
    emit_file_block "$f"
  done
fi

# 4. weekly: 최근 4주
if [ -d "trail/weekly" ]; then
  WEEKS=()
  for i in 0 1 2 3; do
    W=$(now_week_offset "$i")
    [ -n "$W" ] && WEEKS+=("$W")
  done
  for w in "${WEEKS[@]}"; do
    emit_file_block "trail/weekly/${w}.md"
  done
fi

if [ "$TRUNCATED" = true ]; then
  echo "> ⚠️ 예산 초과로 일부 파일이 제목만 표시됨. REIN_BUDGET_BYTES 로 상한 조정 가능."
fi

# Skill/MCP 인벤토리 스캔 + 가이드 출력 (D)
# BEGIN D skill-mcp
SKILL_GUIDE="$PROJECT_DIR/.claude/cache/skill-mcp-guide.md"
SKILL_REGEN_STAMP="$PROJECT_DIR/.claude/cache/.skill-mcp-regen-pending"
SKILL_GUIDE_MAX_BYTES=6144  # 6KB cap, B1 65536 의 약 10%

if command -v python3 >/dev/null 2>&1 && [ -f "$PROJECT_DIR/scripts/rein-scan-skill-mcp.py" ]; then
  # 스캐너 결과를 임시 파일에 저장 후 검증
  SCAN_TMP=$(mktemp)
  if python3 "$PROJECT_DIR/scripts/rein-scan-skill-mcp.py" \
       --project-dir "$PROJECT_DIR" --scan > "$SCAN_TMP" 2>/dev/null \
     && python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$SCAN_TMP" 2>/dev/null; then
    NEEDS_REGEN=$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print("yes" if d.get("needs_regen") else "no")' "$SCAN_TMP")
  else
    NEEDS_REGEN="unknown"
  fi
  rm -f "$SCAN_TMP"

  if [ -f "$SKILL_GUIDE" ]; then
    GUIDE_SIZE=$(portable_stat_size "$SKILL_GUIDE")
    echo "### Skill/MCP 활용 가이드"
    if [ "$GUIDE_SIZE" -gt "$SKILL_GUIDE_MAX_BYTES" ]; then
      head -c "$SKILL_GUIDE_MAX_BYTES" "$SKILL_GUIDE"
      echo
      echo "> ⚠️ 가이드가 ${GUIDE_SIZE}B (${SKILL_GUIDE_MAX_BYTES}B 초과) — truncated"
    else
      cat "$SKILL_GUIDE"
    fi
    echo
  fi

  case "$NEEDS_REGEN" in
    yes)
      mkdir -p "$(dirname "$SKILL_REGEN_STAMP")"
      touch "$SKILL_REGEN_STAMP"
      # 자동 재생성 시도 (실패 시 stamp 유지하여 gate hook 이 재시도)
      if [ -f "$PROJECT_DIR/scripts/rein-generate-skill-mcp-guide.py" ]; then
        if ( cd "$PROJECT_DIR" && python3 scripts/rein-generate-skill-mcp-guide.py >/dev/null 2>&1 ); then
          echo "### 🔄 skill/MCP 가이드 자동 재생성 완료"
          echo
          if [ -f "$SKILL_GUIDE" ]; then
            cat "$SKILL_GUIDE"
            echo
          fi
        else
          echo "### ⚠️ skill/MCP 가이드 자동 재생성 실패 (stamp 유지)"
          echo "수동 실행: python3 scripts/rein-generate-skill-mcp-guide.py"
          echo
        fi
      else
        echo "### 🔄 skill/MCP 인벤토리 변경 감지"
        echo "수동 재생성: python3 scripts/rein-generate-skill-mcp-guide.py"
        echo
      fi
      ;;
    no)
      rm -f "$SKILL_REGEN_STAMP"
      ;;
    unknown)
      echo "### ⚠️ skill/MCP 스캔 실패"
      echo "rein-scan-skill-mcp.py 출력이 손상됨. 수동 점검 필요."
      echo
      ;;
  esac
fi
# END D skill-mcp

exit 0
