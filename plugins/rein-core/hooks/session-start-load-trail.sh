#!/bin/bash
# Hook: SessionStart
# trail 프로젝트 상태를 세션 시작 시 에이전트 컨텍스트로 주입 (lean mode).
#
# 출력: stdout → Claude Code 가 additionalContext 로 흡수
# 실패해도 세션은 계속됨 (항상 exit 0)
#
# Lean mode 정책 (2026-04-29~):
#   - inbox/daily/weekly/MEMORY 전량 주입은 **하지 않는다**. raw 회고/절차
#     텍스트가 stale anchoring 을 유발해 Claude 가 git 같은 권위 source 보다
#     trail 을 우선시하는 문제가 관찰됐다. 자세한 회고:
#     trail/dod/dod-2026-04-29-session-context-reduction.md
#   - 주입 대상은 trail/index.md (5~25줄), pending spec review 요약,
#     pending incident 카운트, freshness 경고 1줄. 그 외 trail 파일은
#     필요 시 명시 read 로 가져온다.
#   - hook 의 maintenance 책임은 그대로 유지: .active-dod cleanup, incident
#     session stamp, legacy pending heal.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
# GE-1: shared path-containment validator for the `.active-dod` cleanup below
# (was an inline 4-check; now one copy shared with select-active-dod.sh).
# shellcheck source=./lib/path-containment.sh
. "$SCRIPT_DIR/lib/path-containment.sh" 2>/dev/null || true

# resolve_project_dir() 가 REIN_PROJECT_DIR_OVERRIDE / REIN_PROJECT_DIR /
# git rev-parse / SCRIPT_DIR fallback / $PWD 순으로 결정.
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Plugin installs can be enabled before a repo has been bootstrapped for Rein.
# In that state, session-start-bootstrap.sh injects the user-facing prompt.
# This hook should not emit a partial trail context or create repo state.
# Skip unless BOTH markers exist — partial state (one missing) is still
# treated as uninitialized so the bootstrap prompt path stays authoritative.
if [ ! -f "$PROJECT_DIR/.rein/project.json" ] || [ ! -f "$PROJECT_DIR/trail/index.md" ]; then
  exit 0
fi

# RES-1: plugin-aware helper script resolver. Two helpers are consumed
# below (legacy-pending heal, incidents aggregate). Resolution is silent on
# absence; each call site guards on non-empty so a missing helper degrades
# to a no-op. SessionStart fails open — never block the session even if the
# resolver library itself is missing; pre-initialise the variables so
# `set -u` stays happy.
HEAL_SCRIPT=""
AGGREGATE_PY=""
if ! . "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null; then
  echo "session-start-load-trail: plugin-script-path library missing at $SCRIPT_DIR/lib/plugin-script-path.sh" >&2
else
  HEAL_SCRIPT=$(resolve_helper_script rein-heal-legacy-pending.py 2>/dev/null || true)
  AGGREGATE_PY=$(resolve_helper_script rein-aggregate-incidents.py 2>/dev/null || true)
fi

emit_file_block() {
  # $1 = 파일 경로 (프로젝트 루트 기준 상대 경로)
  # Lean mode: 예산 추적 없이 그대로 emit. 호출 대상은 index.md 1개.
  local rel="$1"
  local abs="$PROJECT_DIR/$rel"
  [ -f "$abs" ] || return 0

  echo "### $rel"
  echo '```markdown'
  cat "$abs"
  echo '```'
  echo
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

# ---- 묶음 C Phase 3: `.active-dod` cleanup ----------------------------
# 4 categories trigger removal (각각 incident log 기록):
#   (a) path security violation (containment / traversal / metachars / empty)
#   (b) target file missing
#   (c) target lacks `## 범위 연결`
#   (d) target archived (matching inbox or daily completion record — exact match)
# Path validation 은 file -f / grep / glob 검사 보다 **선행** (Task 3.4).
# `path=` 첫 줄만 채택 (Task 3.5 first-line contract; head -1).
# POSIX-portable shell glob + case (find -regex GNU/BSD 비대칭 회피).
ACTIVE_MARKER="$PROJECT_DIR/trail/dod/.active-dod"
if [ -f "$ACTIVE_MARKER" ]; then
  TARGET_PATH=$(grep '^path=' "$ACTIVE_MARKER" 2>/dev/null | head -1 | sed 's/^path=//')
  REMOVE_REASON=""
  # GE-1: containment via shared helper (was an inline empty/metachar/../commonpath
  # block). Reason strings are preserved by the helper (empty path / metachars /
  # .. segment / outside PROJECT_DIR), so existing incident-log assertions hold.
  # declare -F guard: a missing helper degrades to empty-path-only here; the
  # selector re-validates at consumption time (GE-1 backstop).
  if declare -F validate_repo_relative_path >/dev/null 2>&1; then
    REMOVE_REASON=$(validate_repo_relative_path "$PROJECT_DIR" "$TARGET_PATH") || true
  elif [ -z "$TARGET_PATH" ]; then
    REMOVE_REASON="empty path"
  fi
  if [ -n "$REMOVE_REASON" ]; then
    :  # containment failed — REMOVE_REASON holds the reason
  elif [ ! -f "$PROJECT_DIR/$TARGET_PATH" ]; then
    REMOVE_REASON="target file missing"
  elif ! grep -qE '^## 범위 연결' "$PROJECT_DIR/$TARGET_PATH" 2>/dev/null; then
    REMOVE_REASON="target lacks ## 범위 연결"
  else
    # Archived check: same slug in inbox or daily — EXACT match only.
    SLUG=$(basename "$TARGET_PATH" .md | sed -E 's/^dod-[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
    if [ -n "$SLUG" ]; then
      # Inbox: exact filename `<YYYY>-<MM>-<DD>-<SLUG>.md` (case re-validates).
      for f in "$PROJECT_DIR/trail/inbox/"*-"${SLUG}".md; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"${SLUG}".md)
            REMOVE_REASON="archived: matching inbox completion record"
            break
            ;;
        esac
      done
      # Daily: heading line `^# <slug>` with trailing whitespace only (no substring).
      # awk literal compare 로 SLUG metachar injection (예: 합법 slug `foo.bar` 가
      # daily `# fooXbar` 와 ERE false-match) 차단. inbox case 글로브는 `.` literal
      # 이라 안전; daily 만 grep -E → awk 로 비대칭 해소.
      if [ -z "$REMOVE_REASON" ]; then
        for daily_file in "$PROJECT_DIR/trail/daily/"*.md; do
          [ -e "$daily_file" ] || continue
          if awk -v slug="$SLUG" '
            BEGIN { found=0 }
            /^#[[:space:]]/ {
              line = $0
              sub(/^#[[:space:]]+/, "", line)
              sub(/[[:space:]]+$/, "", line)
              if (line == slug) { found=1; exit }
            }
            END { exit (found ? 0 : 1) }
          ' "$daily_file" 2>/dev/null; then
            REMOVE_REASON="archived: matching daily completion heading"
            break
          fi
        done
      fi
    fi
  fi
  if [ -n "$REMOVE_REASON" ]; then
    rm -f "$ACTIVE_MARKER" 2>/dev/null
    mkdir -p "$PROJECT_DIR/trail/incidents" 2>/dev/null
    printf '%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" "$REMOVE_REASON" "$TARGET_PATH" \
      >> "$PROJECT_DIR/trail/incidents/active-dod-cleanup.log" 2>/dev/null || true
  fi
fi
# ---- end 묶음 C Phase 3 ------------------------------------------------

cd "$PROJECT_DIR" || exit 0

# Legacy-shipped pending 자동 healing (rein-heal-legacy-pending.py)
# git tag 에 이미 포함된 dev-only 문서 (dev commit ts <= tag ts) 의 .pending 을
# .reviewed (reviewer=retrospective-shipped-<tag>) 로 auto-stamp.
# **Freshness check**: pending marker 의 created= 가 tag 이전이어야 heal 됨 (fresh
# unreviewed pending 은 gate 유지).
# 실패 시: 전체 stderr 를 suppress 하지 않고 1 줄 warning 만 세션 로그에 기록 —
# python3 resolution 문제가 silent 하게 사라지지 않도록.
if [ -n "$HEAL_SCRIPT" ] && [ -f "$HEAL_SCRIPT" ]; then
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
    echo "### 세션 준비 작업 일부가 완료되지 않았습니다"
    echo
    echo "이전 리뷰 마커를 자동으로 정리하는 단계에서 문제가 생겼습니다. 대부분의 작업에는 영향이 없지만,"
    echo "편집 중 spec review gate 가 예상치 못하게 차단한다면 \`$HEAL_LOG\` 를 확인해 주세요."
    echo
  fi
fi

echo "## trail 세션 시작 컨텍스트"
echo
echo "> 세션 상태 요약만 주입합니다 (비권위 캐시 — index.md 및 미해결 항목)."
echo "> release/branch/tag/publish 관련 주장은 답변 전 \`git status\` / \`git log\` / \`git tag\` / \`git ls-remote\` 로 재검증해 주세요."
echo "> 단순 조회·의견 요청은 작업 기록·라우팅·리뷰 절차 없이 바로 답변합니다 (\${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md)."
echo "> inbox·daily·weekly 파일은 자동으로 주입되지 않습니다 — 필요하면 직접 Read 로 가져오세요."
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
    echo "소스를 편집하기 전에 \`/codex-review\` 를 실행하거나 다른 방법으로 리뷰를 먼저 완료해 주세요."
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
      echo "### 직전 세션 종료가 확인되지 않았습니다"
      echo
      echo "지난 세션이 예상치 못하게 종료됐을 수 있습니다."
      echo "미처리 incident 가 있다면 이번 세션 시작 시 자동으로 집계됩니다."
      echo
    fi
  fi

  # session_end 도장 reset — 이번 세션의 stop hook 이 다시 도장 찍어야 의미 유지.
  # ABNORMAL 판정/메시지 출력 직후, recovery aggregate 호출 직전에 위치해야 함
  # (그 사이에 다른 reader 가 직전 세션의 stale true 를 읽지 않도록).
  # PERF-1: combine set-session-end + aggregate + count-pending into ONE Python
  # subprocess spawn (was 3 separate spawns). Guaranteed internal order:
  #   set-session-end false → aggregate → count-pending (inside cmd_combined).
  # JSON output is parsed with a small python3 -c helper (no jq dependency).
  if [ -n "$AGGREGATE_PY" ]; then
    _COMBINED_JSON=$(python3 "$AGGREGATE_PY" \
      --project-dir "$PROJECT_DIR" \
      --set-session-end false \
      --run-aggregate \
      --count-pending \
      --output-json 2>/dev/null) || _COMBINED_JSON=""
  else
    _COMBINED_JSON=""
  fi

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

  # Parse pending_count from the combined JSON result (python3 inline — no jq).
  if [ -n "$_COMBINED_JSON" ]; then
    PENDING=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(int(d.get('pending_count', 0)))
except Exception:
    print(0)
" "$_COMBINED_JSON" 2>/dev/null || echo 0)
  else
    # Fallback: AGGREGATE_PY absent or combined call failed — degrade gracefully.
    PENDING=0
  fi

  if [ "$PENDING" -gt 0 ]; then
    echo "### 미처리 incident: ${PENDING}건"
    echo
    echo "편집을 시작하기 전에 미처리 incident 를 처리해 주세요 — \`incidents-to-rule\` 스킬을 호출하고 사용자에게 처리 방법을 확인하세요."
    echo
    mkdir -p "$(dirname "$STAMP_FILE")"
    touch "$STAMP_FILE"
  else
    rm -f "$STAMP_FILE"
  fi
fi

# index.md — lean mode 의 유일한 파일 주입 대상
emit_file_block "trail/index.md"

exit 0
