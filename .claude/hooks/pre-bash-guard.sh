#!/bin/bash
# Hook: PreToolUse(Bash) - 위험 명령어 패턴 감지 및 차단
#
# Exit code: 0=허용, 2=차단
# 주의: exit 1은 non-blocking error (통과됨). 차단은 반드시 exit 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"

BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"

log_block() {
  local reason="$1"
  local target="$2"
  # Guard: resolver 실패 경로에서 raw python3 재호출을 피함 (stderr noise 방지).
  # PYTHON_RUNNER 가 아직 set 되지 않았거나 비어있으면 logging 을 skip.
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  "${PYTHON_RUNNER[@]}" - "pre-bash-guard" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL" 2>/dev/null || true
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
  count=$("${PYTHON_RUNNER[@]}" -c "
import json, sys
target_hook = 'pre-bash-guard'
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
  if [ "$count" -ge 3 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
  elif [ "$count" -ge 2 ]; then
    echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
  fi
}

INPUT=$(cat)

# python3 필수 (JSON 파싱). 없으면 Bash gate 전체가 무력화되므로 fail-closed.
# 예전 `2>/dev/null` 방식은 python3 미설치 시 COMMAND="" → exit 0 으로 위험
# 명령어 차단 로직 전체가 비활성화됐음 (codex v0.7.2 review High).
# v0.10.1: Windows Git Bash/MSYS 의 `python3 exit 49` (= 9009 mod 256, App
# Execution Alias stub) 를 실제 JSON 파싱 실패와 구분하기 위해 strict
# resolver 기반으로 교체. exit code 10/11/12 로 원인 분기 + Windows 전용
# 진단 메시지. 파싱은 lib/extract-hook-json.py 로 위임 (inline python3 -c 제거).
# NOTE: bash `!` prefix resets $? to 0 after evaluation. To preserve the
# resolver's specific exit code (10/11/12) for diagnostic routing, capture
# $? immediately after the call BEFORE the conditional, not inside `if !`.
resolve_python
RESOLVER_RC=$?
if [ "$RESOLVER_RC" -ne 0 ]; then
  case "$RESOLVER_RC" in
    10) echo "BLOCKED: [Bash guard] Python 인터프리터 부재." >&2 ;;
    11) echo "BLOCKED: [Bash guard] WindowsApps Python stub 감지. 실제 Python 설치 필요." >&2 ;;
    12) echo "BLOCKED: [Bash guard] Python launch 실패 (9009 계열) — Windows Git Bash/MSYS 가능성 또는 REIN_PYTHON invalid override." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

COMMAND=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.command --default '')
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "BLOCKED: [Bash guard] Bash 입력 JSON 파싱 실패 (extract-hook-json.py exit $EXTRACT_RC)." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- 즉시 차단: 파이프로 쉘 스크립트 실행 ---
# 정규식은 파이프 뒤 bash/sh 토큰 다음에 공백 또는 라인 끝이 오는 경우만 매치한다.
# 단어 경계를 요구하지 않으면 'grep "x\|shadcn"' 같이 alternation 인자에
# sh- / bash- 로 시작하는 substring 이 있을 때 false-positive 로 차단됐다.
if echo "$COMMAND" | grep -qE '\| *(bash|sh)( |$)'; then
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
      echo "/codex-review 스킬로 코드 리뷰를 실행하세요." >&2
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      return 1
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(portable_mtime_epoch "$REVIEW_PENDING")
    REVIEW_TIME=$(portable_mtime_epoch "$REVIEW_STAMP")
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
    echo "${context} 전에 /codex-review 스킬로 코드 리뷰를 실행하세요." >&2
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

# --- Coverage matrix gate (pytest/commit 차단, 리뷰 stamp 검사보다 선행) ---
# Plan A Phase 5 (GI-dod-mismatch-marker-consumer): BLOCK_MARKERS is an array
# so the guard consumes both the legacy plan-level marker and the new DoD-level
# marker. Advisory (non-blocking) markers like .dod-coverage-advisory must NOT
# be listed here — they are informational only and do not gate commits/tests.
# Iteration order determines which marker's message surfaces first when more
# than one is present; we keep legacy first for message stability.
BLOCK_MARKERS=(
  "$PROJECT_DIR/trail/dod/.coverage-mismatch"
  "$PROJECT_DIR/trail/dod/.dod-coverage-mismatch"
)
if echo "$COMMAND" | grep -qE "(pytest|jest|vitest|mocha|npm run test|npm test|yarn test|pnpm test|python -m pytest|npx jest|npx vitest|git commit|bash tests/)"; then
  for marker in "${BLOCK_MARKERS[@]}"; do
    if [ -f "$marker" ]; then
      echo "BLOCKED: coverage matrix 검증 실패 마커 존재 ($marker)." >&2
      echo "  plan/DoD 을 수정해 validator 를 통과시키거나, 예외 승인 후 마커를 직접 삭제하세요." >&2
      log_block "coverage-mismatch" "$COMMAND"
      exit 2
    fi
  done
fi

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
  # v0.10.1: python3 존재 여부는 파일 상단의 resolve_python() 이 이미 gate 했다.
  # 중복 `command -v python3` 체크 제거. PYTHON_RUNNER 배열은 이 시점에 set 되어
  # 있으며 strict-resolver 통과한 인터프리터이다. 배열 확장 `"${PYTHON_RUNNER[@]}"`
  # 로 token 경계를 보존해야 안전하다 (REIN_PYTHON 주입 방어).
  COMMIT_MSG=$("${PYTHON_RUNNER[@]}" "$EXTRACT_SCRIPT" "$COMMAND" 2>/dev/null)
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
