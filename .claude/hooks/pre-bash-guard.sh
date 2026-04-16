#!/bin/bash
# Hook: PreToolUse(Bash) - 위험 명령어 패턴 감지 및 차단
#
# Exit code: 0=허용, 2=차단
# 주의: exit 1은 non-blocking error (통과됨). 차단은 반드시 exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

log_block() {
  local reason="$1"
  local target="$2"
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  python3 - "pre-bash-guard" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL"
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
  count=$(grep -c '"pre-bash-guard"' "$BLOCKS_LOG_JSONL" 2>/dev/null || echo 0)
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

# Portable mtime extractor: returns epoch seconds.
# macOS uses BSD stat (-f %m), Linux/WSL/Git Bash/Cygwin use GNU stat (-c %Y).
_mtime() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
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

# --- Codex 리뷰 + 보안 리뷰 stamp 공통 검사 함수 ---
check_review_stamp() {
  local context="$1"  # "test" 또는 "commit"
  REVIEW_STAMP="$PROJECT_DIR/trail/dod/.codex-reviewed"
  SECURITY_STAMP="$PROJECT_DIR/trail/dod/.security-reviewed"
  DOD_DIR="$PROJECT_DIR/trail/dod"

  # DoD 파일이 없으면 (작업 중이 아니면) 검사 스킵
  DOD_EXISTS=false
  if [ -d "$DOD_DIR" ]; then
    for f in "$DOD_DIR"/dod-*.md; do
      [ -f "$f" ] || continue
      DOD_EXISTS=true
      break
    done
  fi
  [ "$DOD_EXISTS" = false ] && return 0

  # --- .review-pending 검증 (코드 편집 후 리뷰 필수) ---
  REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"
  if [ -f "$REVIEW_PENDING" ]; then
    if [ ! -f "$REVIEW_STAMP" ]; then
      echo "BLOCKED: 코드 변경 후 codex 리뷰가 실행되지 않았습니다." >&2
      echo "/codex 스킬로 코드 리뷰를 실행하세요." >&2
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      return 1
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(_mtime "$REVIEW_PENDING")
    REVIEW_TIME=$(_mtime "$REVIEW_STAMP")
    if [ "$REVIEW_TIME" -lt "$PENDING_TIME" ]; then
      echo "BLOCKED: 리뷰 이후 코드가 다시 수정되었습니다. codex 리뷰를 재실행하세요." >&2
      log_block "리뷰 후 코드 재수정 (${context})" "$COMMAND"
      return 1
    fi
  fi

  # --- escalated_to_human 감지 시 경고 (차단하지 않음) ---
  if grep -q "resolution: escalated_to_human" "$REVIEW_STAMP" 2>/dev/null; then
    echo "WARNING: 코드 리뷰가 사람 에스컬레이션 상태입니다. 수동 확인 후 진행하세요." >&2
  fi

  # --- Codex 리뷰 stamp 검사 ---
  # 시간 기반 TTL 은 제거 — .review-pending 비교가 "코드 변경 후 재리뷰" 를 정확히 담당한다
  if [ ! -f "$REVIEW_STAMP" ]; then
    echo "BLOCKED: Codex 코드 리뷰가 실행되지 않았습니다." >&2
    echo "${context} 전에 /codex 스킬로 코드 리뷰를 실행하세요." >&2
    echo "리뷰 완료 후 trail/dod/.codex-reviewed 파일이 생성되어야 합니다." >&2
    log_block "Codex 리뷰 미실행 (${context})" "$COMMAND"
    return 1
  fi

  # --- 보안 리뷰 stamp 검사 ---
  if [ ! -f "$SECURITY_STAMP" ]; then
    echo "BLOCKED: 보안 리뷰가 실행되지 않았습니다." >&2
    echo "Codex 리뷰 후 security-reviewer 에이전트를 실행하세요." >&2
    echo "리뷰 완료 후 trail/dod/.security-reviewed 파일이 생성되어야 합니다." >&2
    log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
    return 1
  fi


  return 0
}

# --- Codex 리뷰 stamp 검사 (테스트 실행 시) ---
if echo "$COMMAND" | grep -qE "(pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest)"; then
  if ! check_review_stamp "테스트 실행"; then
    exit 2
  fi
fi

# --- Codex 리뷰 stamp 검사 (git commit 시) ---
if echo "$COMMAND" | grep -qE "git commit"; then
  if ! check_review_stamp "커밋"; then
    exit 2
  fi
fi

# 커밋 메시지 포맷 검증 (python3 helper 기반, 복합 명령 + heredoc + scope 지원)
# - 복합 명령에서 첫 "commit" 토큰 이후 구간만 분석 (다음 구분자 &&, ||, ;, | 전까지)
#   → 복합 명령의 tag 쪽 -m 을 오인하지 않음
# - heredoc 본문의 첫 줄을 multiline regex 로 정확히 추출
#   → $(cat <<'EOF' ... EOF) 형태 메시지도 올바로 검사됨
# - conventional commits scope 표기법 허용: type(scope)?: description
# 추출 로직 자체는 .claude/hooks/lib/extract-commit-msg.py 에 분리 (bash 의
# $(cmd <<HEREDOC) + `|| true` 파서 한계를 피하기 위함).
if echo "$COMMAND" | grep -qE "git commit"; then
  EXTRACT_SCRIPT="$SCRIPT_DIR/lib/extract-commit-msg.py"
  # Helper 누락은 fail-open 으로 두지 않는다. heredoc 우회와 같은 silent
  # bypass 를 막기 위해, helper 가 없거나 python3 가 동작하지 않으면 BLOCK.
  if [ ! -f "$EXTRACT_SCRIPT" ]; then
    echo "BLOCKED: 커밋 메시지 검증 helper 가 없습니다." >&2
    echo "  expected: $EXTRACT_SCRIPT" >&2
    echo "  rein 설치/업데이트가 누락된 상태입니다 — rein update 를 실행하세요." >&2
    log_block "commit msg helper 누락" "$EXTRACT_SCRIPT"
    exit 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "BLOCKED: python3 가 PATH 에 없습니다 (커밋 메시지 검증 필수 의존성)." >&2
    log_block "python3 누락 (commit msg)" "$COMMAND"
    exit 2
  fi
  COMMIT_MSG=$(python3 "$EXTRACT_SCRIPT" "$COMMAND" 2>/dev/null)
  EXTRACT_RC=$?
  if [ "$EXTRACT_RC" -ne 0 ]; then
    echo "BLOCKED: 커밋 메시지 추출이 실패했습니다 (helper exit=$EXTRACT_RC)." >&2
    log_block "commit msg helper 실패" "$EXTRACT_SCRIPT"
    exit 2
  fi

  if [ -n "$COMMIT_MSG" ]; then
    FIRST_LINE=$(printf '%s' "$COMMIT_MSG" | head -1 | sed 's/^[[:space:]]*//')
    if [ -n "$FIRST_LINE" ]; then
      if ! echo "$FIRST_LINE" | grep -qE "^(feat|fix|docs|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?: .+"; then
        # Co-Authored-By 라인은 면제
        if ! echo "$FIRST_LINE" | grep -qE "^Co-Authored-By:"; then
          echo "BLOCKED: 커밋 메시지 형식이 올바르지 않습니다." >&2
          echo "형식: <type>(<scope>)?: <설명>" >&2
          echo "  type: feat|fix|docs|refactor|test|chore" >&2
          echo "  scope: 영문/숫자/언더스코어/하이픈 (선택)" >&2
          log_block "커밋 메시지 포맷 위반" "$FIRST_LINE"
          exit 2
        fi
      fi
    fi
  fi
fi

# --- .env 파일 읽기 차단 (cat, python 등으로 우회 방지) ---
if echo "$COMMAND" | grep -qE "(cat|head|tail|less|more|python[23]?|node)\s+.*\.env"; then
  echo "BLOCKED: .env 파일을 Bash로 읽는 것은 허용되지 않습니다." >&2
  log_block ".env Bash 읽기 시도" "$COMMAND"
  exit 2
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
if echo "$COMMAND" | grep -qiE "git (reset --hard|push --force|push.*-f( |$)|checkout -- |restore )"; then
  echo "CONFIRM: 파괴적 git 명령어가 감지되었습니다." >&2
  exit 2
fi

exit 0
