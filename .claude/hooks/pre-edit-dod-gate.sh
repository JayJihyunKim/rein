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
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"

# Plan A Phase 4 — shared libraries (GI-dod-gate-selector-shared-with-codex-review,
# GI-governance-stage-config). Missing either library is fail-closed: a
# silently degraded DoD gate is the drift we are trying to prevent.
if ! . "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null; then
  echo "BLOCKED: [DoD gate] select-active-dod library missing at $SCRIPT_DIR/lib/select-active-dod.sh" >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/governance-stage.sh" 2>/dev/null; then
  echo "BLOCKED: [DoD gate] governance-stage library missing at $SCRIPT_DIR/lib/governance-stage.sh" >&2
  exit 2
fi

BLOCKS_LOG="$PROJECT_DIR/trail/incidents/blocks.log"
BLOCKS_LOG_JSONL="$PROJECT_DIR/trail/incidents/blocks.jsonl"
DOD_DIR="$PROJECT_DIR/trail/dod"
INBOX_DIR="$PROJECT_DIR/trail/inbox"
SRC_EDIT_MARKER="$DOD_DIR/.session-has-src-edit"

# Plan A Phase 4 Task 4.3 (GI-dod-gate-cache-invalidation): session cache
# removed. The selector + validator are cheap enough to run on every hook
# invocation; any cache would re-introduce stale-pass drift. The legacy
# /tmp/.claude-dod-<key>-<mtime> variables are intentionally no longer
# declared.

# Markers produced by this gate (Plan A §4.2 table):
DOD_MISMATCH_MARKER="$DOD_DIR/.dod-coverage-mismatch"    # blocking
DOD_ADVISORY_MARKER="$DOD_DIR/.dod-coverage-advisory"    # non-blocking

# Validator invocation (Plan A Phase 3 + 4): wrapped in `timeout 30` by
# this hook per GI-validator-v2-timeout-fail-closed.
VALIDATOR_PATH="$PROJECT_DIR/scripts/rein-validate-coverage-matrix.py"
VALIDATOR_TIMEOUT_S=30

log_block() {
  local reason="$1"
  local target="$2"
  # Guard: PYTHON_RUNNER 가 아직 설정되지 않았거나 비어있으면 (resolver 실패 경로
  # 포함) raw python3 재호출을 피하고 조용히 skip. logging 은 best-effort 이며,
  # resolver 가 실패한 상황에서 같은 python3 stub 를 다시 부르면 stderr noise 가
  # 추가되어 사용자 진단 메시지 품질을 해친다.
  if [ -z "${PYTHON_RUNNER+x}" ] || [ "${#PYTHON_RUNNER[@]}" -eq 0 ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  "${PYTHON_RUNNER[@]}" - "pre-edit-dod-gate" "$reason" "$target" <<'PY' >> "$BLOCKS_LOG_JSONL" 2>/dev/null || true
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
# v0.10.1: python-runner.sh resolver 로 통합 (Windows Git Bash 9009 → exit 49 감지 포함).
# 주의: `if ! resolve_python` 은 bash `!` 가 $? 를 0/1 로 정규화하므로 resolver 의
# 세부 exit code (10/11/12) 가 사라진다. 직접 호출 후 $? 를 즉시 캡처한다.
resolve_python
rc=$?
if [ "$rc" -ne 0 ]; then
  case "$rc" in
    10) echo "BLOCKED: [DoD gate] Python 인터프리터 부재." >&2 ;;
    11) echo "BLOCKED: [DoD gate] WindowsApps Python stub 감지. 실제 Python 설치 필요." >&2 ;;
    12) echo "BLOCKED: [DoD gate] Python launch 실패 (9009 계열) — Windows Git Bash/MSYS 가능성 또는 REIN_PYTHON invalid override." >&2 ;;
    *)  echo "BLOCKED: [DoD gate] resolve_python 실패 (rc=$rc)." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '')
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "BLOCKED: [DoD gate] Edit/Write 입력 JSON 파싱 실패 (extract-hook-json.py exit $EXTRACT_RC)." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Path normalize — 그룹 6 P4 (2026-04-25). 묶음 A 의 PYTHON_RUNNER
# os.path.normpath 패턴 재사용 (.claude/hooks/post-edit-review-gate.sh).
# URL-encoded / `//` / `/./` 세그먼트 포함 경로 edge case 보호. 정규화 전/후
# 불일치 시 stderr NOTICE 만 (gate 동작 변경 없음). resolver 부재 fallback
# 은 원본 사용 (silent). 이후 case 매칭은 정규화된 FILE_PATH 사용.
FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
  'import os,sys; print(os.path.normpath(sys.argv[1]))' \
  "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
[ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"
if [ "$FILE_PATH_NORM" != "$FILE_PATH" ]; then
  echo "NOTICE: pre-edit-dod-gate normalized path: $FILE_PATH → $FILE_PATH_NORM" >&2
fi
FILE_PATH="$FILE_PATH_NORM"

# --- 경로 기반 면제 (runtime state + operational data + git infra only) ---
# M1 (2026-04-22 retro-review-sweep): 기존 blanket `*/.claude/*` exemption 제거.
# 배경: .claude/rules/*, .claude/skills/**, .claude/agents/*, .claude/workflows/*,
#   .claude/CLAUDE.md, .claude/orchestrator.md, AGENTS.md 는 branch-strategy.md
#   기준 main 포함 (사용자 repo 로 복사되는 source). DoD 없이 편집되면 안 됨.
# 면제 대상은 runtime state / 운영 데이터 / git 인프라 파일만.
case "$FILE_PATH" in
  # .gitignore 는 **어느 디렉토리에 있든** 항상 source (main-포함, tracking 정책
  # 변경 가능). Runtime-state 경로 (.claude/cache/) 에 있어도 예외 아님. 이
  # 최상단 match 는 아래 exit 0 들이 .gitignore 를 가로채지 못하도록 보호한다.
  # Codex Round 2 finding: 예전 순서에서는 .claude/cache/.gitignore 가
  # `*/.claude/cache/*` 에 먼저 잡혀 bypass 됐음.
  */.gitignore|.gitignore)
    :  # fall through to IS_SOURCE check below
    ;;
  # Runtime state — hook/validator 가 자동 기록. Edit/Write 로 올 일 거의 없지만 안전용.
  */.claude/cache/*|*/.claude/.rein-state/*)
    exit 0
    ;;
  # Trail 운영 데이터 — DoD 파일 자체가 여기 살고, inbox/daily/weekly/incidents/decisions 포함.
  */trail/*)
    exit 0
    ;;
  # Git 인프라 파일 — .gitkeep 만 면제 (디렉토리 placeholder).
  *.gitkeep)
    exit 0
    ;;
esac

# --- 소스 디렉토리 한정 gate ---
IS_SOURCE=false
case "$FILE_PATH" in
  # 일반 소스 경로 (사용자 프로젝트 코드). `*/hooks/*` 가 `.claude/hooks/*` 도 잡음.
  */src/*|*/app/*|*/services/*|*/apps/*|*/lib/*|*/components/*|*/hooks/*|*/store/*|*/types/*|*/models/*|*/schemas/*|*/repositories/*|*/routers/*|*/alembic/*|*/scripts/*|scripts/*)
    IS_SOURCE=true
    ;;
  # rein-internal source — branch-strategy.md 의 main 포함 경로.
  # 사용자 repo 로 복사되므로 편집 시 DoD 필수.
  */.claude/rules/*|*/.claude/skills/*|*/.claude/agents/*|*/.claude/workflows/*)
    IS_SOURCE=true
    ;;
  */.claude/CLAUDE.md|*/.claude/orchestrator.md|*/.claude/settings.json)
    IS_SOURCE=true
    ;;
  # AGENTS.md at any depth (repo root 또는 subdir 모두).
  */AGENTS.md|AGENTS.md)
    IS_SOURCE=true
    ;;
  # .gitignore — main 포함. tracking 정책 변경 가능.
  */.gitignore|.gitignore)
    IS_SOURCE=true
    ;;
esac

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# --- Governance stage (Plan A §6, GI-governance-stage-config) ---
# Fail-closed on malformed / unknown stage: "silent Stage 1 downgrade" is a
# bypass path. Stage 1 (default / file-absent) is advisory; Stage 2/3 is
# blocking. INVALID → block all Edits until config is fixed.
GOVERNANCE_STAGE=$(cd "$PROJECT_DIR" && read_governance_stage)
if [ "$GOVERNANCE_STAGE" = "INVALID" ]; then
  mkdir -p "$PROJECT_DIR/trail/incidents"
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "invalid_stage" \
    >> "$PROJECT_DIR/trail/incidents/governance-config-invalid.log" 2>/dev/null || true
  mkdir -p "$DOD_DIR"
  touch "$DOD_MISMATCH_MARKER"
  echo "BLOCKED: [DoD gate] corrupt .claude/.rein-state/governance.json." >&2
  echo "  fix or remove the file to re-initialize to Stage 1 (advisory)." >&2
  log_block "governance config invalid" "$FILE_PATH"
  exit 2
fi

# --- Incident Review Pending 검사 (cache 보다 앞. self-heal 포함) ---
# cache hit 로 우회되면 안 되는 gate. 항상 실시간 검증.
INCIDENT_STAMP="$DOD_DIR/.incident-review-pending"
INCIDENT_BYPASS="$DOD_DIR/.skip-incident-gate"

if [ -f "$INCIDENT_STAMP" ]; then
  # v0.10.1: resolver 는 이미 위에서 성공했으므로 PYTHON_RUNNER 가 populated 되어 있음.
  # exit code 를 분리 캡처하여 스크립트 실패 시 fail-closed 로 처리한다.
  # `|| echo 0` 방식은 실패 시에도 0 으로 보여 stamp 를 잘못 지우고 통과시켰음
  # (codex v0.7.2 review High).
  LIVE_COUNT=$("${PYTHON_RUNNER[@]}" "$PROJECT_DIR/scripts/rein-aggregate-incidents.py" \
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

# Plan A Phase 4 Task 4.3 (GI-dod-gate-cache-invalidation):
# The 5-min /tmp/.claude-dod-* session cache was removed here.
# Every DoD-gate invocation now runs the selector + validator from scratch.
# Benefit: "stale pass" class of drift is structurally impossible.
# Cost: one extra validator subprocess (~500ms) per Edit/Write. Well under
# the 30s timeout defined by GI-validator-v2-timeout-fail-closed.

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
  # Plan A Phase 4 Task 4.2 (GI-dod-gate-validator-call):
  # Run the active-DoD validator through the 30s timeout wrapper and
  # enforce the §4.2 tier/exit-code table. This block is a no-op
  # (exit 0) when no DoD candidate exists (tier=0), preserving the
  # original "DoD file exists → permit edit" behavior.
  SAD_LINE=$( cd "$PROJECT_DIR" && select_active_dod )
  SAD_TIER=$(printf '%s' "$SAD_LINE" | cut -f1)
  SAD_PATH=$(printf '%s' "$SAD_LINE" | cut -f2)
  SAD_REASON=$(printf '%s' "$SAD_LINE" | cut -f3)

  if [ "$SAD_TIER" = "0" ] || [ -z "$SAD_PATH" ]; then
    # No candidate DoD has '## 범위 연결' — silently pass through.
    # This is the common case for legacy DoDs; Stage 1 (advisory) does
    # not require 범위 연결. Emit no stderr to avoid polluting every
    # Edit/Write with a warning.
    touch "$SRC_EDIT_MARKER" 2>/dev/null
    exit 0
  fi

  # Validator call with 30s timeout.
  if ! command -v timeout >/dev/null 2>&1; then
    # macOS BSD doesn't ship GNU timeout by default; fall through to
    # no-wrap invocation but still honor the "block on validator fail"
    # contract. The validator is bounded by its own implementation.
    VEXIT=0
    ( cd "$PROJECT_DIR" && "${PYTHON_RUNNER[@]}" "$VALIDATOR_PATH" dod "$SAD_PATH" 2>&1 ) >/dev/null || VEXIT=$?
  else
    VEXIT=0
    ( cd "$PROJECT_DIR" && timeout "$VALIDATOR_TIMEOUT_S" "${PYTHON_RUNNER[@]}" "$VALIDATOR_PATH" dod "$SAD_PATH" 2>&1 ) >/dev/null || VEXIT=$?
  fi

  # Apply the §4.2 outcome table (tier × validator-result → marker + exit).
  case "$SAD_TIER:$VEXIT" in
    1:0)
      rm -f "$DOD_MISMATCH_MARKER" "$DOD_ADVISORY_MARKER"
      ;;
    1:124)
      mkdir -p "$PROJECT_DIR/trail/incidents"
      printf '%s\tdod\t%s\ttimeout\n' "$(date -u +%FT%TZ)" "$SAD_PATH" \
        >> "$PROJECT_DIR/trail/incidents/validator-timeout.log" 2>/dev/null || true
      touch "$DOD_MISMATCH_MARKER"
      echo "BLOCKED: [DoD gate] validator timeout on $SAD_PATH — fail-closed (Tier 1)." >&2
      log_block "validator timeout (tier 1)" "$SAD_PATH"
      exit 2
      ;;
    1:*)
      touch "$DOD_MISMATCH_MARKER"
      rm -f "$DOD_ADVISORY_MARKER"
      echo "BLOCKED: [DoD gate] DoD validator failed for $SAD_PATH (exit $VEXIT, Tier 1 marker)." >&2
      echo "  fix the DoD's '## 범위 연결' coverage list to reference 'implemented' IDs from the plan matrix." >&2
      log_block "dod covers mismatch (tier 1)" "$SAD_PATH"
      exit 2
      ;;
    2:0)
      rm -f "$DOD_ADVISORY_MARKER"
      ;;
    2:124)
      mkdir -p "$PROJECT_DIR/trail/incidents"
      printf '%s\tdod\t%s\ttimeout\n' "$(date -u +%FT%TZ)" "$SAD_PATH" \
        >> "$PROJECT_DIR/trail/incidents/validator-timeout.log" 2>/dev/null || true
      touch "$DOD_ADVISORY_MARKER"
      echo "WARNING: [DoD gate] validator timeout on $SAD_PATH — advisory only (Tier 2)." >&2
      ;;
    2:*)
      touch "$DOD_ADVISORY_MARKER"
      echo "WARNING: [DoD gate] DoD validator failed for $SAD_PATH (exit $VEXIT, Tier 2 advisory — non-blocking)." >&2
      ;;
  esac

  touch "$SRC_EDIT_MARKER" 2>/dev/null
  exit 0
else
  echo "BLOCKED: 미완료 DoD 파일이 없습니다." >&2
  echo "소스 코드를 편집하기 전에 먼저 trail/dod/dod-$(date +%Y-%m-%d)-<slug>.md 를 작성하세요." >&2
  log_block "미완료 DoD 없음" "$FILE_PATH"
  exit 2
fi
