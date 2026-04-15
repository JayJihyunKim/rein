#!/bin/bash
# Hook: Stop - 정상 세션 종료 전 체크리스트 gate
#
# Exit code: 0=허용, 2=차단
# 비정상 종료(Ctrl+C, 터미널 닫기)에서는 실행되지 않음
# 정상 종료 시에만 inbox 기록 + index.md 갱신 여부를 검사
#
# v0.4.3 변경점:
# - REIN_BYPASS_STOP_GATE=1 env var 탈출구 추가 (최상단 우선권)
# - git 활동 (오늘 커밋 또는 변경사항) 을 "작업 증거" 로 인정해
#   inbox 파일이 없어도 실제 작업이 있으면 WARNING + 통과
# - 차단 메시지에 구체적 해결 방법 3 가지 명시
#
# 이 변경은 v0.4.1 의 post-edit-index-sync-inbox.sh 훅이 가진
# precondition 실패 (사용자가 SOT/index.md 를 편집하지 않으면 훅이
# 발동하지 않음) 를 근본적으로 우회하기 위한 것이다. stop-session-gate
# 자체가 git 활동을 감지하므로 PostToolUse 훅 발동 여부와 무관하게
# 데드락이 해소된다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INBOX_DIR="$PROJECT_DIR/SOT/inbox"
DOD_DIR="$PROJECT_DIR/SOT/dod"
INDEX_FILE="$PROJECT_DIR/SOT/index.md"
TODAY=$(date +%Y-%m-%d)

# ---- 방어층 3: 비상 탈출 env var (with audit trail) ----
# 극단 상황 (git 활동도 없고 inbox 도 못 만드는 경우) 에 세션을 강제로
# 끝낼 escape hatch. 악용 방지를 위해 항상 WARNING 출력 + incidents 로그.
if [ "${REIN_BYPASS_STOP_GATE:-0}" = "1" ]; then
  echo "WARNING: REIN_BYPASS_STOP_GATE=1 — stop gate bypassed." >&2
  echo "  이 탈출구는 1회성 비상용입니다. 다음 세션에서 SOT/inbox/${TODAY}-*.md 에 작업 기록을 보충하세요." >&2
  # Audit trail: bypass 사용 이력을 blocks.log 에 기록해 repo-audit 등에서
  # 추후 탐지 가능하도록 한다. 실패해도 조용히 통과 (exit 0 유지).
  BLOCKS_LOG="$PROJECT_DIR/SOT/incidents/blocks.log"
  mkdir -p "$(dirname "$BLOCKS_LOG")" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%S)|stop-session-gate|BYPASS_ENV|REIN_BYPASS_STOP_GATE=1" \
    >> "$BLOCKS_LOG" 2>/dev/null || true
  exit 0
fi

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

# ---- 방어층 1: git 활동 감지 ----
# inbox 파일이 없더라도 오늘 git 활동 (커밋 또는 tracked 변경사항) 이
# 있으면 "실제 작업" 의 증거로 인정한다. git 명령은 훅 프로세스에서
# 직접 실행되므로 PreToolUse 기반의 3rd-party 차단 훅 (예: fact-force)
# 의 영향을 받지 않는다.
#
# 중요: 순수 untracked 파일만 있는 상태는 "work" 로 인정하지 않는다.
# .DS_Store, 에디터 swap 파일, 빌드 부산물 같은 noise 가 gate 를
# 우회시키는 것을 막기 위함. tracked 파일의 수정 또는 staging 만 신호
# 로 취급. (security-reviewer M1)
HAS_GIT_ACTIVITY=false
GIT_ACTIVITY_REASON=""
GIT_PROBE_FAILED=false
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # 오늘 커밋 확인 (로컬 시간 기준)
  if git -C "$PROJECT_DIR" log --since="${TODAY}T00:00:00" --oneline 2>/dev/null | head -1 | grep -q .; then
    HAS_GIT_ACTIVITY=true
    GIT_ACTIVITY_REASON="오늘 커밋 존재"
  fi
  # tracked 파일의 modified 변경 (worktree)
  if [ "$HAS_GIT_ACTIVITY" = false ]; then
    if git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null | head -1 | grep -q .; then
      HAS_GIT_ACTIVITY=true
      GIT_ACTIVITY_REASON="tracked 파일 변경사항 존재"
    fi
  fi
  # staged 변경 (index)
  if [ "$HAS_GIT_ACTIVITY" = false ]; then
    if git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null | head -1 | grep -q .; then
      HAS_GIT_ACTIVITY=true
      GIT_ACTIVITY_REASON="staged 변경 존재"
    fi
  fi
else
  # git 저장소가 아니거나 probe 실패 — warning 으로만 남기고 block 로직
  # 그대로 진행. 실제 deadlock 재현 환경에서는 거의 언제나 git repo 이므로
  # 이 경로는 드문 edge case.
  GIT_PROBE_FAILED=true
fi

if [ "$INBOX_TODAY" = false ]; then
  if [ "$HAS_GIT_ACTIVITY" = true ]; then
    # git 활동이 실제 작업의 증거 — inbox 요구사항을 완화 (WARNING 출력)
    echo "WARNING: SOT/inbox/${TODAY}-*.md 가 없지만 git 활동이 감지되어 통과합니다." >&2
    echo "  근거: ${GIT_ACTIVITY_REASON}" >&2
    echo "  다음 세션에서 SOT/inbox/${TODAY}-<작업명>.md 에 보충 기록 권장." >&2
  else
    MISSING="${MISSING}\n- SOT/inbox/${TODAY}-[작업명].md 가 없습니다. 작업 기록을 남겨주세요."
    if [ "$GIT_PROBE_FAILED" = true ]; then
      echo "NOTE: git 저장소 감지 실패 — git 활동 기반 완화가 적용되지 않았습니다." >&2
    fi
  fi
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
  echo "빠른 해결책 (상황에 맞게 선택):" >&2
  echo "  1) SOT/index.md 를 편집 — post-edit-index-sync-inbox 훅이 설치돼 있으면" >&2
  echo "     오늘자 inbox 가 자동 생성됩니다 (v0.4.1+)" >&2
  echo "  2) 터미널에서 직접:" >&2
  echo "     echo '# session note' > SOT/inbox/${TODAY}-session.md" >&2
  echo "  3) 비상 탈출 (감사 로그 남김): 다음 호출 앞에 REIN_BYPASS_STOP_GATE=1 을" >&2
  echo "     설정하면 bypass 됩니다 (SOT/incidents/blocks.log 에 기록)" >&2
  echo "  4) 실제로 작업했다면 git 활동 (커밋 / staged / modified tracked file) 이" >&2
  echo "     감지되면 이 gate 는 자동으로 통과합니다 — 작업을 커밋하거나 staging 하세요" >&2
  exit 2
fi

exit 0
