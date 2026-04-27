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
# precondition 실패 (사용자가 trail/index.md 를 편집하지 않으면 훅이
# 발동하지 않음) 를 근본적으로 우회하기 위한 것이다. stop-session-gate
# 자체가 git 활동을 감지하므로 PostToolUse 훅 발동 여부와 무관하게
# 데드락이 해소된다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${REIN_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"

INBOX_DIR="$PROJECT_DIR/trail/inbox"
DOD_DIR="$PROJECT_DIR/trail/dod"
INDEX_FILE="$PROJECT_DIR/trail/index.md"
SRC_EDIT_MARKER="$DOD_DIR/.session-has-src-edit"
TODAY=$(date +%Y-%m-%d)

# --- H3.3: incident_advisory_check (non-blocking, stderr only) ---
# 현재 세션 동안 쌓인 blocks.jsonl 엔트리를 per-pattern 집계해
# 자기진화 파이프라인 (2회→rule, 3회→agent) 트리거를 권장한다.
# 주의: stdout 에 쓰지 않는다 (stop-session-gate 가 stdout 에 block JSON 출력).
incident_advisory_check() {
  local STAMP="$PROJECT_DIR/trail/incidents/.session-start-line"
  local since_line=1
  if [ -f "$STAMP" ]; then
    since_line=$(cat "$STAMP" 2>/dev/null | tr -d ' \n')
    [ -z "$since_line" ] && since_line=1
  fi

  local summary_json
  summary_json=$(python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    advisory-summary --since-line "$since_line" 2>/dev/null || echo "[]")

  if [ -z "$summary_json" ] || [ "$summary_json" = "[]" ]; then
    return 0
  fi

  SUMMARY="$summary_json" python3 - <<'PY' >&2
import json, os
data = json.loads(os.environ.get("SUMMARY", "[]"))
for item in data:
    c = item.get("count", 0)
    label = item.get("pattern_label", "unknown")
    if c >= 3:
        print(f"[advisory] 같은 incident 패턴 '{label}' 이 {c}회 반복됨. 'incidents-to-agent' 스킬 실행을 권장합니다.")
    elif c >= 2:
        print(f"[advisory] 같은 incident 패턴 '{label}' 이 {c}회 반복됨. 'incidents-to-rule' 스킬 실행을 권장합니다.")
PY

  local DRAFTS="$PROJECT_DIR/trail/incidents"
  if ls "$DRAFTS"/*.draft.md 2>/dev/null | head -1 >/dev/null; then
    echo "[advisory] pending incident draft 존재: $DRAFTS/*.draft.md" >&2
  fi
  if ls "$DRAFTS"/auto-*.md 2>/dev/null | head -1 >/dev/null; then
    echo "[advisory] pending incident auto-* 존재: $DRAFTS/auto-*.md" >&2
  fi
}

# ---- 방어층 3: 비상 탈출 env var (with audit trail) ----
# 극단 상황 (git 활동도 없고 inbox 도 못 만드는 경우) 에 세션을 강제로
# 끝낼 escape hatch. 악용 방지를 위해 항상 WARNING 출력 + incidents 로그.
if [ "${REIN_BYPASS_STOP_GATE:-0}" = "1" ]; then
  echo "WARNING: REIN_BYPASS_STOP_GATE=1 — stop gate bypassed." >&2
  echo "  이 탈출구는 1회성 비상용입니다. 다음 세션에서 trail/inbox/${TODAY}-*.md 에 작업 기록을 보충하세요." >&2
  # Audit trail: bypass 사용 이력을 blocks.log 에 기록해 repo-audit 등에서
  # 추후 탐지 가능하도록 한다. 실패해도 조용히 통과 (exit 0 유지).
  BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
  mkdir -p "$(dirname "$BLOCKS_LOG")" 2>/dev/null || true
  echo "$(date -u +%Y-%m-%dT%H:%M:%S)|stop-session-gate|BYPASS_ENV|REIN_BYPASS_STOP_GATE=1" \
    >> "$BLOCKS_LOG" 2>/dev/null || true
  exit 0
fi

# ---- QA 세션 감지: 소스 편집이 없었으면 inbox/index 요구 면제 ----
# incident advisory 는 소스 편집 여부와 무관하게 항상 실행
incident_advisory_check
if [ ! -f "$SRC_EDIT_MARKER" ]; then
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
    echo "WARNING: trail/inbox/${TODAY}-*.md 가 없지만 git 활동이 감지되어 통과합니다." >&2
    echo "  근거: ${GIT_ACTIVITY_REASON}" >&2
    echo "  다음 세션에서 trail/inbox/${TODAY}-<작업명>.md 에 보충 기록 권장." >&2
  else
    MISSING="${MISSING}\n- trail/inbox/${TODAY}-[작업명].md 가 없습니다. 작업 기록을 남겨주세요."
    if [ "$GIT_PROBE_FAILED" = true ]; then
      echo "NOTE: git 저장소 감지 실패 — git 활동 기반 완화가 적용되지 않았습니다." >&2
    fi
  fi
fi

# --- trail/index.md 갱신 확인 ---
# 오늘 수정되었는지 (mtime 기준) + 줄 수 규칙 (5~25줄, AGENTS.md §9)
if [ -f "$INDEX_FILE" ]; then
  INDEX_DATE=$(date -r "$INDEX_FILE" +%Y-%m-%d 2>/dev/null || stat -c %y "$INDEX_FILE" 2>/dev/null | cut -d' ' -f1)
  if [ "$INDEX_DATE" != "$TODAY" ]; then
    MISSING="${MISSING}\n- trail/index.md가 오늘 갱신되지 않았습니다."
  fi

  # 줄 수 규칙 강제 (5~25줄). trail/index.md 상단 안내 주석 + AGENTS.md §9
  # 가 같은 범위를 명시한다. 위반 시 차단 메시지에 현재 줄 수 표시
  # (need-to-confirm.md 그룹 5 — 2026-04-25).
  INDEX_LINES=$(wc -l < "$INDEX_FILE" 2>/dev/null | tr -d ' ' || echo 0)
  if [ -n "$INDEX_LINES" ] && { [ "$INDEX_LINES" -lt 5 ] || [ "$INDEX_LINES" -gt 25 ]; }; then
    MISSING="${MISSING}\n- trail/index.md가 ${INDEX_LINES}줄입니다. 5~25줄 범위로 유지하세요."
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

    FILE_EPOCH=$(portable_date_ymd_to_epoch "$FILE_DATE")
    [ -z "$FILE_EPOCH" ] && continue

    AGE_DAYS=$(( (NOW_EPOCH - FILE_EPOCH) / 86400 ))
    if [ "$AGE_DAYS" -ge "$STALE_DAYS" ]; then
      echo "WARNING: 다음 DoD가 ${AGE_DAYS}일 이상 미완료 상태입니다:" >&2
      echo "  - $(basename "$f")" >&2
      echo "완료 기록을 남기거나 불필요하면 삭제하세요." >&2
    fi
  done
fi

# --- Incidents 집계 (Python) ---
# aggregate 의 stdout/stderr 는 모두 stderr 로 redirect 한다.
# Stop hook 의 stdout 은 block JSON payload 전용이어야 하므로 aggregate 의
# NOTICE/WARNING 이 혼입되면 JSON 파싱이 깨질 위험 (codex v0.7.2 Medium).
if command -v python3 >/dev/null 2>&1; then
  python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    --project-dir "$PROJECT_DIR" 1>&2 || true
fi

# --- Incident gate (Stage 1 + Stage 2 강화) ---
INCIDENT_STAMP_DEFERRED="$PROJECT_DIR/trail/dod/.incident-decision-deferred"
INCIDENT_STAMP_BYPASS="$PROJECT_DIR/trail/dod/.skip-stop-gate"
BLOCK_COUNTER_FILE="$PROJECT_DIR/trail/dod/.incident-stop-blocks"
HASHES_FILE="$PROJECT_DIR/trail/dod/.incident-stop-hashes"
EMIT_PY="$PROJECT_DIR/scripts/rein-stop-emit-block.py"
INCIDENTS_DIR="$PROJECT_DIR/trail/incidents"

if command -v python3 >/dev/null 2>&1; then
  # Second invocation: read-only count query.
  # (aggregate side effect already ran above; count_pending reflects updated state.)
  PENDING_COUNT=$(python3 "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
    --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null || echo 0)
else
  PENDING_COUNT=0
fi

if [ "$PENDING_COUNT" -eq 0 ]; then
  # pending 이 0 이면 counter/hashes 파일은 더 이상 의미 없음. 정리하지 않으면
  # 같은 세션 내 새 pending 발생 시 이전 카운터가 남아 3회 가드가 조기 발동할
  # 수 있음 (codex v0.7.2 Medium).
  rm -f "$BLOCK_COUNTER_FILE" "$HASHES_FILE" 2>/dev/null || true
fi

if [ "$PENDING_COUNT" -gt 0 ]; then
  if [ -f "$INCIDENT_STAMP_DEFERRED" ]; then
    :
  elif [ -f "$INCIDENT_STAMP_BYPASS" ]; then
    rm -f "$INCIDENT_STAMP_BYPASS"
  else
    CURRENT_HASHES=$(
      for f in "$INCIDENTS_DIR"/auto-*.md; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "auto-stop-gate-loop.md" ] && continue
        grep '^status:' "$f" | grep -q pending || continue
        grep '^pattern_hash:' "$f" | sed 's/.*: *//' | tr -d '"'
      done | sort
    )
    PREV_HASHES=$(cat "$HASHES_FILE" 2>/dev/null || echo "")
    if [ "$CURRENT_HASHES" != "$PREV_HASHES" ]; then
      echo 0 > "$BLOCK_COUNTER_FILE"
    fi
    echo "$CURRENT_HASHES" > "$HASHES_FILE"

    COUNT=$(head -1 "$BLOCK_COUNTER_FILE" 2>/dev/null || echo 0)
    # 비정수 방어
    [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$BLOCK_COUNTER_FILE"

    if [ "$COUNT" -gt 3 ]; then
      META="$INCIDENTS_DIR/auto-stop-gate-loop.md"
      if [ ! -f "$META" ]; then
        cat > "$META" <<METAEOF
---
status: "pending"
pattern_hash: "stop-gate-loop"
hook: "stop-session-gate"
reason: "3회 초과 block (루프 감지 전용)"
first_seen: "$(date -u +%Y-%m-%dT%H:%M:%S)"
last_seen_at: "$(date -u +%Y-%m-%dT%H:%M:%S)"
---

# Incident: stop-session-gate 3회 초과 block

Stop hook 이 pending 을 3회 초과 block 했음. 스킬 체인 호출이 실패하는 것으로 추정.

## 예시

(자동 수집 없음 — 수동 확인)

## 분석 메모

(incidents-to-rule 스킬이 분석 결과를 여기에 기록)

## 승격 이력

(사용자 결정 기록)
METAEOF
      fi
      echo "BLOCKED (3회 초과): 결정 스킬 호출이 반복 실패. 강제 통과: touch trail/dod/.skip-stop-gate" >&2
      if [ -x "$EMIT_PY" ]; then
        python3 "$EMIT_PY" "$PENDING_COUNT"
      else
        echo '{"decision":"block","reason":"pending incidents — emit helper missing"}'
      fi
      # Claude Code Stop hook: block via JSON decision field, not exit code.
      exit 0
    fi

    if [ -x "$EMIT_PY" ]; then
      python3 "$EMIT_PY" "$PENDING_COUNT"
    else
      echo '{"decision":"block","reason":"pending incidents present, but emit helper missing"}'
    fi
    # Claude Code Stop hook: block via JSON decision field, not exit code.
    exit 0
  fi
fi

# --- 결과 판정 ---
if [ -n "$MISSING" ]; then
  echo "BLOCKED: 세션 종료 전 완료되지 않은 항목이 있습니다." >&2
  echo -e "$MISSING" >&2
  echo "" >&2
  echo "빠른 해결책 (상황에 맞게 선택):" >&2
  echo "  1) trail/index.md 를 편집 — post-edit-index-sync-inbox 훅이 설치돼 있으면" >&2
  echo "     오늘자 inbox 가 자동 생성됩니다 (v0.4.1+)" >&2
  echo "  2) 터미널에서 직접:" >&2
  echo "     echo '# session note' > trail/inbox/${TODAY}-session.md" >&2
  echo "  3) 비상 탈출 (감사 로그 남김): 다음 호출 앞에 REIN_BYPASS_STOP_GATE=1 을" >&2
  echo "     설정하면 bypass 됩니다 (trail/incidents/blocks.log 에 기록)" >&2
  echo "  4) 실제로 작업했다면 git 활동 (커밋 / staged / modified tracked file) 이" >&2
  echo "     감지되면 이 gate 는 자동으로 통과합니다 — 작업을 커밋하거나 staging 하세요" >&2
  exit 2
fi

# snapshot session_end=true 기록 (Task 10)
SNAPSHOT="$PROJECT_DIR/trail/incidents/.last-aggregate-state.json"
if [ -f "$SNAPSHOT" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, sys
try:
    p = sys.argv[1]
    d = json.load(open(p))
    d['session_end'] = True
    with open(p, 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
except Exception:
    pass
" "$SNAPSHOT" 2>/dev/null || true
fi

# Cleanup: 현재 세션의 active-dod-choice flag 제거 (select-active-dod.sh 가
# 생성한 "세션당 1회 로그" 세마포어). key 해석은 select-active-dod.sh 와
# 동일: ${REIN_SESSION_ID:-${PPID:-$$}}. BYPASS / early-exit / gate-block 경로로
# 빠진 flag 는 다음 SessionStart 의 1h sweep 이 정리함. 실패해도 exit 0 유지.
_rein_dod_flag_key="${REIN_SESSION_ID:-${PPID:-$$}}"
rm -f "$PROJECT_DIR/.claude/cache/active-dod-choice.session-${_rein_dod_flag_key}.flag" 2>/dev/null || true

exit 0
