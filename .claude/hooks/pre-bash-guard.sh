#!/bin/bash
# Hook: PreToolUse(Bash) - 위험 명령어 패턴 감지 및 차단
#
# Exit code: 0=허용, 2=차단
# 주의: exit 1은 non-blocking error (통과됨). 차단은 반드시 exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/SOT/incidents/blocks.log"

log_block() {
  local reason="$1"
  local target="$2"
  mkdir -p "$(dirname "$BLOCKS_LOG")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%S)|pre-bash-guard|$reason|$target" >> "$BLOCKS_LOG"

  local count
  count=$(grep -c "pre-bash-guard|$reason" "$BLOCKS_LOG" 2>/dev/null || echo 0)
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('command', ''))" 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- 즉시 차단: 파이프로 쉘 스크립트 실행 ---
if echo "$COMMAND" | grep -qE "\| *(bash|sh)"; then
  echo "BLOCKED: 파이프로 쉘 스크립트 실행은 허용되지 않습니다." >&2
  log_block "파이프 쉘 실행" "$COMMAND"
  exit 2
fi

# --- 커밋 메시지 포맷 검증 ---
# merge/rebase commit은 면제
if echo "$COMMAND" | grep -qE "git (merge|rebase|am)"; then
  exit 0
fi

# --- Codex 리뷰 stamp 검사 (git commit 시) ---
if echo "$COMMAND" | grep -qE "git commit"; then
  REVIEW_STAMP="$PROJECT_DIR/SOT/dod/.codex-reviewed"
  if [ ! -f "$REVIEW_STAMP" ]; then
    echo "BLOCKED: Codex 코드 리뷰가 실행되지 않았습니다." >&2
    echo "커밋 전에 /codex 스킬로 코드 리뷰를 실행하세요." >&2
    echo "리뷰 완료 후 SOT/dod/.codex-reviewed 파일이 생성되어야 합니다." >&2
    log_block "Codex 리뷰 미실행" "$COMMAND"
    exit 2
  else
    # stamp가 1시간(3600초) 이내인지 확인 (오래된 stamp 방지)
    STAMP_AGE=$(( $(date +%s) - $(stat -f %m "$REVIEW_STAMP" 2>/dev/null || stat -c %Y "$REVIEW_STAMP" 2>/dev/null || echo 0) ))
    if [ "$STAMP_AGE" -gt 3600 ]; then
      echo "BLOCKED: Codex 리뷰 stamp가 1시간 이상 경과했습니다. 다시 리뷰를 실행하세요." >&2
      log_block "Codex 리뷰 stamp 만료" "$COMMAND"
      exit 2
    fi
    # 커밋 성공 후 stamp 삭제 (1회성)는 post hook에서 처리하거나 다음 DoD 작성 시 초기화
  fi
fi

# git commit 감지 → 메시지 포맷 검증
if echo "$COMMAND" | grep -qE "git commit"; then
  # HEREDOC 커밋 (cat <<'EOF' ... EOF) 에서 첫 줄 추출
  COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*<<['\"]\\{0,1\\}EOF['\"]\\{0,1\\}//p" | head -1 | sed 's/^[[:space:]]*//')

  # -m "..." 또는 --message "..." 에서 추출
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG=$(echo "$COMMAND" | grep -oE '(-m|--message)[[:space:]]+"[^"]*"' | head -1 | sed 's/^[^"]*"//;s/"$//')
  fi
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG=$(echo "$COMMAND" | grep -oE "(-m|--message)[[:space:]]+'[^']*'" | head -1 | sed "s/^[^']*'//;s/'$//")
  fi

  if [ -n "$COMMIT_MSG" ]; then
    # 첫 줄만 검사
    FIRST_LINE=$(echo "$COMMIT_MSG" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$FIRST_LINE" ]; then
      if ! echo "$FIRST_LINE" | grep -qE "^(feat|fix|docs|refactor|test|chore): .+"; then
        # Co-Authored-By 라인은 면제
        if ! echo "$FIRST_LINE" | grep -qE "^Co-Authored-By:"; then
          echo "BLOCKED: 커밋 메시지 형식이 올바르지 않습니다." >&2
          echo "형식: [type]: [설명]  (type: feat|fix|docs|refactor|test|chore)" >&2
          log_block "커밋 메시지 포맷 위반" "$FIRST_LINE"
          exit 2
        fi
      fi
    fi
  fi
fi

# --- .env 파일 커밋 방지 ---
if echo "$COMMAND" | grep -qE "git add"; then
  if echo "$COMMAND" | grep -qE "git add (-A|\.(\s|$|\|)|\.env)"; then
    if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
      echo "BLOCKED: .env 파일이 존재합니다. git add로 스테이징할 수 없습니다." >&2
      echo "파일을 지정하여 개별 add하세요." >&2
      log_block ".env 스테이징 시도" "$COMMAND"
      exit 2
    fi
  fi
fi

# git commit -am
if echo "$COMMAND" | grep -qE "git commit.*-[a-z]*a[a-z]*m"; then
  if [ -f "$PROJECT_DIR/.env" ] || ls "$PROJECT_DIR"/.env.* 1>/dev/null 2>&1; then
    echo "BLOCKED: .env 파일이 존재합니다. git commit -am은 허용되지 않습니다." >&2
    log_block ".env 포함 commit -am" "$COMMAND"
    exit 2
  fi
fi

# --- 확인 요청: 파괴적 git 명령어 ---
if echo "$COMMAND" | grep -qiE "git (reset --hard|push --force|push.*-f )"; then
  echo "CONFIRM: 파괴적 git 명령어가 감지되었습니다." >&2
  exit 2
fi

exit 0
