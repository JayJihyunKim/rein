#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# DoD 파일 없으면 소스 편집 차단
# (inbox 정리는 trail-rotate (구 inbox-compress).sh로 분리됨)
#
# Exit code: 0=허용, 2=차단

# --- Policy toggle moved below the python resolver (GMF-4) ---
# The policy-toggle block used to live HERE (top of file) and hard-coded
# `python3`. When python3 was absent (127) or a Windows stub (49), the
# `if ! python3 <loader>; then exit 0` form treated interpreter-absence as a
# user policy disable and silently turned the DoD gate OFF (fail-open). GMF-4
# (docs/specs/2026-06-12-gate-misfire-fixes.md §3.4) moves the policy check to
# AFTER resolve_python (which already fail-closes rc 10/11/12 → exit 2) and
# calls the loader via "${PYTHON_RUNNER[@]}", so a missing interpreter never
# disables the gate. See the policy block after the resolver below.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/portable.sh
. "$SCRIPT_DIR/lib/portable.sh"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# Plan A Phase 4 — shared libraries (GI-dod-gate-selector-shared-with-codex-review,
# GI-governance-stage-config). Missing either library is fail-closed: a
# silently degraded DoD gate is the drift we are trying to prevent.
if ! . "$SCRIPT_DIR/lib/select-active-dod.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/select-active-dod.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
if ! . "$SCRIPT_DIR/lib/governance-stage.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/governance-stage.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
# RES-1: plugin-aware helper script resolver. CLAUDE_PLUGIN_ROOT/scripts
# preferred, repo scripts/ as fallback.
if ! . "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/plugin-script-path.sh). Run 'rein update' to restore it." >&2
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
# RES-1: deferred resolution — validator path resolved lazily in the
# block that actually invokes it (only on Tier-1/2 candidates). Resolution
# failure becomes BLOCKED at that site so users without the helper get a
# clear message instead of a silent skip.
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
  # Auto mode: silence repeat-violation WARNING (the marker file presence
  # means the user is running a long autonomous cycle).
  local _auto_silent=0
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ]; then
    # shellcheck disable=SC1091
    . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh" 2>/dev/null || true
    if declare -F is_auto_mode >/dev/null 2>&1 && is_auto_mode; then
      _auto_silent=1
    fi
  fi
  if [ "$_auto_silent" = "0" ]; then
    if [ "$count" -ge 3 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-agent 실행을 권장합니다." >&2
    elif [ "$count" -ge 2 ]; then
      echo "WARNING: 동일 위반 (${reason}) ${count}회 누적. incidents-to-rule 실행을 권장합니다." >&2
    fi
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
    10) echo "[rein] The edit gate cannot run because Python is not installed. Install Python 3 to restore all edit checks." >&2 ;;
    11) echo "[rein] The edit gate cannot run because the Windows App Execution Alias Python stub was detected instead of a real Python installation. Install Python 3 from python.org or the Microsoft Store to proceed." >&2 ;;
    12) echo "[rein] The edit gate cannot run because Python failed to launch (exit 9009 family) — this is common in Windows Git Bash or MSYS, or when REIN_PYTHON points to an invalid interpreter. Check your Python installation or unset REIN_PYTHON." >&2 ;;
    *)  echo "[rein] The edit gate cannot run because the Python resolver failed (rc=$rc). Check your Python installation or run 'rein update'." >&2 ;;
  esac
  print_windows_diagnostics_if_applicable >&2
  log_block "python runtime unavailable" "unknown"
  exit 2
fi

# --- Policy toggle (plugin mode only) — GMF-4 resolver-after form ---
# .rein/policy/hooks.yaml can disable a hook via `<hook-name>: false`
# or `{ <hook-name>: { enabled: false } }`.
# Plugin mode: ${CLAUDE_PLUGIN_ROOT} is set, loader is invoked.
# Non-plugin runtime: env unset, check is skipped (preserves pre-policy behavior).
#
# GMF-4 contract: resolve_python above already fail-closed (exit 2) on rc
# 10/11/12 (interpreter absent / Windows stub / launch failure), so reaching
# here means PYTHON_RUNNER is a real interpreter. We call the loader through it
# and distinguish:
#   rc == 1        → loader ran cleanly + reported "disabled" → exit 0 (OFF)
#   rc == 0        → enabled → fall through to the gate body (active)
#   rc ∉ {0,1}     → loader crash / OS fault → fail-closed (gate active)
# Interpreter-absence can no longer reach this block, so it never disables
# the gate.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-edit-dod-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '')
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "[rein] The edit gate cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $EXTRACT_RC). This is an installation issue — run 'rein update' to repair." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# PERF-2: PostToolUse 분할 sub-hook 들이 같은 tool_use_id 키로 resolver 결과를
# 재사용할 수 있도록 cache 에 dump. cache miss 는 sub-hook 자체 fallback 으로 처리.
#
# Cache leak 가능성 (advisory, 2026-05-20 Phase 2b): 본 write 가 모든 gate check
# 통과 전에 발생 — DoD 부재 / routing 미승인 등으로 본 gate 가 exit 2 차단할 경우
# PostToolUse 가 fire 되지 않아 aggregator cleanup 이 발생하지 않으며 cache 가
# stale 로 남을 수 있음. 별 cycle 의 GC 후속 (SessionEnd hook 또는 cron) 으로
# 24h+ stale entry 정리 검토. 본 cycle 에선 leak 가능성만 명시.
if [ -f "$SCRIPT_DIR/lib/hook-resolver-cache.sh" ]; then
  # shellcheck source=./lib/hook-resolver-cache.sh
  . "$SCRIPT_DIR/lib/hook-resolver-cache.sh"
  _perf2_tool_use_id=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_use_id --default '' 2>/dev/null)
  if [ -n "$_perf2_tool_use_id" ]; then
    _perf2_payload=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" -c 'import sys,json
try:
    data = json.loads(sys.stdin.read())
    if not isinstance(data, dict):
        sys.exit(0)
    out = {"file_path": (data.get("tool_input") or {}).get("file_path", "")}
    # MultiEdit 의 경우 file_paths 도 같이 dump
    edits = (data.get("tool_input") or {}).get("edits") or []
    if isinstance(edits, list):
        paths = []
        for e in edits:
            if isinstance(e, dict) and e.get("file_path"):
                paths.append(e["file_path"])
        if paths:
            out["file_paths"] = paths
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
except Exception:
    pass' 2>/dev/null)
    if [ -n "$_perf2_payload" ]; then
      resolver_cache_write "$_perf2_tool_use_id" "$_perf2_payload" || true
    fi
  fi
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
# 배경: 사용자 repo 의 .claude/rules/*, .claude/skills/**, .claude/agents/*,
#   .claude/workflows/*, AGENTS.md 는 plugin 이 제공하는 운영 surface — DoD 없이
#   편집되면 안 됨. (rein-dev 메인테이너 환경 hint: .claude/CLAUDE.md /
#   .claude/orchestrator.md 도 동일 카테고리이나 일반 사용자 repo 에는 없음.)
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

# --- 소스 판정 gate (GMF-3: 디렉토리 화이트리스트 + 소스 확장자 화이트리스트) ---
# spec/plan §3.3. 판정 순서(우선순위)는 tightening-only 를 보장하도록 고정:
#   (1) generated/vendored 제외 — source-dir *앞* (산출물/벤더링은 source-dir
#       안에 있어도 비소스. 예: vendor/foo/lib/x.go, src/generated/api.ts)
#   (2) 기존 디렉토리(source-dir) 화이트리스트 — 변경 없음 (불완화)
#   (3) doc/data/lock 확장자 제외 — source-dir *뒤* (source-dir 내부 파일은
#       이미 (2)에서 IS_SOURCE=true 확정되어 이 단계에 도달하지 않음 → 기존
#       차단 불완화. 루트 config.json 등 source-dir 밖만 통과)
#   (4) 소스 확장자 화이트리스트 (additive) — 디렉토리로 안 잡힌 소스 파일
# NONSOURCE_DECIDED=true 는 (1) generated/vendored 가 후속 판정을 덮어쓰지 못하게
# 막는 결정 플래그. EXT_SOURCE_HIT=true 는 (4) 확장자로 새로 소스가 됐음을 표시
# (디렉토리 매칭과 구분 — 안내 메시지 trigger).
IS_SOURCE=false
NONSOURCE_DECIDED=false
EXT_SOURCE_HIT=false

# (1) generated/vendored 제외 — source-dir 판정보다 앞. 매칭 시 비소스 확정.
case "$FILE_PATH" in
  */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.next/*|*/generated/*|*/__generated__/*|*/__pycache__/*)
    NONSOURCE_DECIDED=true ;;
  *.min.js|*.generated.*|*_pb2.py|*.pb.go)
    NONSOURCE_DECIDED=true ;;
esac

# (2) 기존 디렉토리 화이트리스트 — generated/vendored 가 아닐 때만 평가 (불완화).
if [ "$NONSOURCE_DECIDED" != true ]; then
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
    # rein-dev 메인테이너 환경에서만 존재하는 paths. 일반 사용자 repo 에는
    # 이들 파일이 없으므로 자연 무동작 (case 가 매치되지 않음). hint 보존 목적.
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
fi

# (3) doc/data/lock 확장자 제외 — source-dir *뒤*. 디렉토리로 안 잡힌(=source-dir
#     밖) 파일이 문서/데이터/락이면 비소스로 통과. source-dir 내부 파일은 (2)에서
#     이미 IS_SOURCE=true 라 여기 안 옴 → src/schema.json 등 기존 차단 불완화.
if [ "$IS_SOURCE" != true ] && [ "$NONSOURCE_DECIDED" != true ]; then
  case "$FILE_PATH" in
    *.md|*.txt|*.rst|*.adoc) NONSOURCE_DECIDED=true ;;
    *.json|*.yaml|*.yml|*.toml|*.ini|*.csv|*.xml|*.env) NONSOURCE_DECIDED=true ;;
    *.lock|*.sum) NONSOURCE_DECIDED=true ;;  # Cargo.lock / poetry.lock / go.sum / *-lock.yaml(=*.yaml)
  esac
fi

# (4) 소스 확장자 화이트리스트 (additive) — 위 어느 단계로도 결정 안 된 파일.
#     §3.3.b 확정 목록. 목록 누락은 보수적 실패(통과 = 게이트 약하게) — 안전 방향.
if [ "$IS_SOURCE" != true ] && [ "$NONSOURCE_DECIDED" != true ]; then
  case "$FILE_PATH" in
    *.go|*.rs|*.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.java|*.kt|*.kts|*.scala|*.c|*.h|*.cpp|*.cc|*.cxx|*.hpp|*.hh|*.rb|*.php|*.sh|*.bash|*.swift|*.m|*.mm|*.cs|*.ex|*.exs|*.erl|*.hs|*.clj|*.cljs|*.lua|*.dart|*.pl|*.pm|*.r|*.R|*.jl|*.zig|*.ml|*.mli|*.fs|*.fsx|*.groovy)
      IS_SOURCE=true; EXT_SOURCE_HIT=true ;;
    Dockerfile|*/Dockerfile|Makefile|*/Makefile|*.mk)
      IS_SOURCE=true; EXT_SOURCE_HIT=true ;;
  esac
fi

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# GMF-3 안내 메시지 헬퍼 (파일경로당 1회). 디렉토리가 아닌 *소스 확장자* 로 새로
# IS_SOURCE=true 가 되어 DoD 미충족으로 차단되는 경우에만, "이 파일이 이제 DoD 를
# 요구하는 이유"(= 디렉토리 화이트리스트가 아니라 소스 확장자로 판정됨 + 정책
# 토글로 끌 수 있음) 를 stderr 로 안내한다. 억제 단위 = 정규화된 파일 경로
# (per-path marker `trail/dod/.ext-source-notice-<sha>`). 디렉토리 매칭
# (EXT_SOURCE_HIT=false) 차단은 기존 동작이므로 안내 없음. 통과(exit 0) 경로에서는
# 호출하지 않는다(plan §3.4 — marker 생성은 차단 시점에만).
# best-effort: PYTHON_RUNNER 실패/hash 실패 시 안내만 skip(차단 결정과 독립).
emit_ext_source_notice() {
  [ "$EXT_SOURCE_HIT" = true ] || return 0
  local _ext_sha _ext_marker _ext_token
  _ext_sha=$("${PYTHON_RUNNER[@]}" -c '
import hashlib, sys
print(hashlib.sha1(sys.argv[1].encode("utf-8")).hexdigest()[:12])
' "$FILE_PATH" 2>/dev/null)
  [ -n "$_ext_sha" ] || return 0
  _ext_marker="$DOD_DIR/.ext-source-notice-$_ext_sha"
  [ -f "$_ext_marker" ] && return 0
  _ext_token="${FILE_PATH##*.}"
  echo "[rein] 이 파일은 소스 확장자(.$_ext_token)로 판정되어 DoD 를 요구합니다 (디렉토리 화이트리스트가 아닌 확장자 기준). 정책 토글로 끌 수 있습니다." >&2
  mkdir -p "$DOD_DIR" 2>/dev/null
  touch "$_ext_marker" 2>/dev/null
}

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
  # governance.json path is mode-aware. Surface the actually-resolved path so
  # the user fixes the right file in plugin / legacy installs.
  GOVERNANCE_CONFIG_PATH=$(cd "$PROJECT_DIR" && resolve_governance_config_path)
  echo "[rein] The edit gate cannot run because the governance config file ($GOVERNANCE_CONFIG_PATH) is corrupt. Fix or remove the file to re-initialize to Stage 1 (advisory mode)." >&2
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
  # RES-1: helper script 경로는 plugin-aware resolver 로 해석한다. resolver
  # 실패 시 stamp 검증 자체가 불가능하므로 fail-closed (VALIDATOR_PATH 패턴과
  # 동일). plugin install 환경에서 ${CLAUDE_PLUGIN_ROOT}/scripts/ 우선, 메인테이너
  # repo fallback 으로 ${PROJECT_DIR}/scripts/ 가 사용된다.
  AGGREGATE_PY=$(resolve_helper_script rein-aggregate-incidents.py) || {
    echo "[rein] The incident count check cannot run because the aggregate helper (rein-aggregate-incidents.py) could not be found. Run 'rein update' to restore it." >&2
    log_block "aggregate helper missing" "$FILE_PATH"
    exit 2
  }
  LIVE_COUNT=$("${PYTHON_RUNNER[@]}" "$AGGREGATE_PY" \
    --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null)
  LIVE_RC=$?
  if [ "$LIVE_RC" -ne 0 ]; then
    echo "[rein] The incident count check failed (exit $LIVE_RC). Check that Python is working correctly and run 'rein update' if the problem persists." >&2
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
  elif [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ] && \
       { . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh" 2>/dev/null || true; } && \
       declare -F is_auto_mode >/dev/null 2>&1 && is_auto_mode; then
    # Auto mode: silence the pending-incident block + skip stderr noise.
    # The user opted in via the marker file; block bypass is audit-logged.
    if declare -F auto_mode_log_bypass >/dev/null 2>&1; then
      auto_mode_log_bypass "pre-edit-dod-gate: skip pending-incident block (LIVE_COUNT=$LIVE_COUNT)"
    fi
  else
    echo "[rein] There are $LIVE_COUNT unresolved incidents that need a decision before source files can be edited. To proceed:" >&2
    echo "  1) Run /incidents-to-rule to review and resolve them." >&2
    echo "  2) Ask the user to approve or decline each incident." >&2
    echo "  3) Add any approved rule to AGENTS.md." >&2
    echo "  4) Mark each incident as processed: python3 <scripts-dir>/rein-mark-incident-processed.py <path> <processed|declined>" >&2
    echo "     (scripts-dir = \${CLAUDE_PLUGIN_ROOT}/scripts/ on plugin install, \${PROJECT_DIR}/scripts/ on maintainer repo)" >&2
    echo "  5) The check clears itself automatically on the next source edit once all incidents are resolved." >&2
    echo "" >&2
    echo "  Emergency bypass: echo 'reason=<reason>' > $INCIDENT_BYPASS" >&2
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
  # Strict ISO 8601 shape shared by SR-1 (.pending vs .reviewed compare) and
  # SR-1.b (orphan .reviewed vs spec mtime compare). Both rein writers use
  # `date -u +%Y-%m-%dT%H:%M:%S` (UTC, no offset); the legacy healer's
  # trailing `Z` is stripped before matching.
  spec_iso_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'
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

    # SR-1: existence alone is not enough — a spec re-edited after its review
    # re-creates .pending whose created= is newer than .reviewed's reviewed=,
    # while the old .reviewed lingers (review-bypass). Compare the two rein-
    # written timestamps. Strict ISO 8601 shape — a missing OR garbled
    # timestamp (e.g. `created=0000`, which would sort below a valid reviewed=
    # and slip past a bare lexical compare) cannot prove freshness →
    # fail-closed. After shape validation both are fixed-width, so a
    # digit-only numeric compare is locale-independent (avoids bash `[[ > ]]`
    # collation). Backstops the post-edit gate's .reviewed removal and
    # catches a stale state already on disk.
    pending_created=$(grep -E '^created=' "$pending_marker" 2>/dev/null | head -1 | sed -e 's/^created=//' -e 's/Z$//')
    reviewed_at=$(grep -E '^reviewed=' "$reviewed_marker" 2>/dev/null | head -1 | sed -e 's/^reviewed=//' -e 's/Z$//')
    if ! [[ "$pending_created" =~ $spec_iso_re ]] || ! [[ "$reviewed_at" =~ $spec_iso_re ]]; then
      UNRESOLVED_SPECS=true   # missing/garbled timestamp → fail-closed
      break
    fi
    if [ "${pending_created//[!0-9]/}" -gt "${reviewed_at//[!0-9]/}" ]; then
      UNRESOLVED_SPECS=true   # spec edited after review → stale review
      break
    fi
  done

  # SR-1.b: orphan .reviewed backstop. SR-1's freshness check only fires
  # when a .pending sibling exists. If the post-edit hook fails to fire
  # (hooks disabled, external IDE write, `git checkout` restoring the spec,
  # MultiEdit JSON parse failure → exit 0) the new .pending is never
  # created. The old .reviewed lingers as an orphan and the loop above
  # never runs for that hash → source edits proceed with unreviewed spec
  # changes. Pre-existing trust boundary (.pending-keyed), not a new gap
  # from SR-1. Mitigation: iterate orphan .reviewed markers (no matching
  # .pending) and decide staleness by CONTENT (see the tiered logic below).
  # The original mtime compare (R1 risk, "accepted" in an earlier revision)
  # produced real false-positives — checkout/cherry-pick/rotation bump mtime
  # without changing content — so it was replaced (SR-1.b-MTIME-FP).
  if [ "$UNRESOLVED_SPECS" = false ]; then
    # SR-1.b-MTIME-FP fix (codex Mode B "tightened A", 2026-05-29): the orphan
    # backstop previously compared the spec's filesystem mtime against
    # reviewed=, but git checkout / cherry-pick / rotation bump mtime WITHOUT
    # changing content → false "stale" → unrelated source edits chain-blocked
    # (2026-05-29 incident: 25 dev-only docs). Decide staleness by CONTENT
    # (content_sha anchor), with a git committer-time fallback restricted to
    # retrospective/healer markers (whose origin is knowable), and the legacy
    # mtime path only for non-retro / non-git markers.
    #
    # 2026-05-31 follow-up: also recognise the `retrospective-cherry-pick-mtime-fp*`
    # provenance class. Those markers were deliberately re-stamped on 2026-05-29
    # to absorb exactly this mtime FP, but were previously unrecognised and fell
    # to the mtime path — so the FP they were meant to fix still fired. Routing
    # them through the committer-time tier clears the mtime FP SOUNDLY: plain
    # checkout / branch-switch / rotation bump only the filesystem mtime, NOT
    # committer-time, so a spec committed before review reads as fresh; while a
    # genuine post-review commit (or a spec cherry-picked/integrated after
    # review) has committer-time > reviewed and is still blocked (no
    # false-negative). committer-time — not author-time — is the sound signal:
    # author-time would wrongly allow a pre-review-authored commit that was only
    # integrated into this branch AFTER review (its content was never reviewed).
    #
    # git work-tree detection, computed once. Sanitized per BC-INFO1 class so a
    # poisoned GIT_DIR/GIT_WORK_TREE cannot redirect discovery to a decoy repo.
    SR1B_GIT_WORKTREE=false
    if [ "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
            git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
      SR1B_GIT_WORKTREE=true
    fi
    for reviewed_marker in "$SPEC_REVIEWS_DIR"/*.reviewed; do
      [ -f "$reviewed_marker" ] || continue

      hash_val=$(basename "$reviewed_marker" .reviewed)
      # Skip if a matching .pending exists — that path is handled by the
      # SR-1 branch above and we must not double-count or apply the orphan
      # semantics (which would override SR-1's content-timestamp logic).
      if [ -f "$SPEC_REVIEWS_DIR/${hash_val}.pending" ]; then
        continue
      fi

      spec_path=$(grep -E '^path=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^path=//')
      [ -z "$spec_path" ] && continue

      # Deleted spec → skip (matches existing test_gate_ignores_deleted_spec).
      [ -f "$spec_path" ] || continue

      reviewed_at=$(grep -E '^reviewed=' "$reviewed_marker" 2>/dev/null | head -1 | sed -e 's/^reviewed=//' -e 's/Z$//')
      if ! [[ "$reviewed_at" =~ $spec_iso_re ]]; then
        UNRESOLVED_SPECS=true    # missing/garbled timestamp → fail-closed
        break
      fi

      content_sha_stored=$(grep -E '^content_sha=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^content_sha=//')

      if [ -n "$content_sha_stored" ]; then
        # TIER 1 — content hash anchor (strict, FP-free + FN-safe). Byte hash of
        # the spec NOW vs the hash recorded at review. Immune to mtime / checkout
        # / cherry-pick / rotation; catches any committed OR uncommitted edit.
        spec_sha_now=$("${PYTHON_RUNNER[@]}" -c '
import hashlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        print(hashlib.sha256(f.read()).hexdigest())
except Exception:
    sys.exit(1)
' "$spec_path" 2>/dev/null) || {
          UNRESOLVED_SPECS=true   # unreadable spec → fail-closed
          break
        }
        if [ "$spec_sha_now" != "$content_sha_stored" ]; then
          UNRESOLVED_SPECS=true   # content changed since review → stale
          break
        fi
        continue                  # content unchanged → not stale
      fi

      # No content anchor (legacy marker). reviewed_epoch is needed by both
      # remaining tiers. fromisoformat parses naive ISO 8601 (no offset);
      # anchor to UTC since the writer uses `date -u`.
      reviewed_epoch=$("${PYTHON_RUNNER[@]}" -c '
import sys
from datetime import datetime, timezone
try:
    dt = datetime.fromisoformat(sys.argv[1]).replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    sys.exit(1)
' "$reviewed_at" 2>/dev/null) || {
        UNRESOLVED_SPECS=true   # malformed reviewed= despite regex pass → fail-closed
        break
      }

      # Provenance gate for the git fallback: deliberate retrospective / healer
      # markers have a knowable origin, so a git author-time heuristic is
      # acceptable for them — but NOT for arbitrary contentless markers, whose
      # reviewed content is unknowable (codex Mode B: do not broadly bless).
      # Recognised provenance classes (each a deliberate, auditable namespace —
      # a normal review writes reviewer=codex/sonnet/… which never matches):
      #   - retrospective-shipped*              release-shipped / healer specs
      #   - retrospective-cherry-pick-mtime-fp* legacy markers re-stamped to
      #                                         absorb a checkout/cherry-pick
      #                                         mtime false-positive
      #   - mechanism=rein-heal-legacy-pending  legacy-pending healer
      reviewer_val=$(grep -E '^reviewer=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^reviewer=//')
      mechanism_val=$(grep -E '^mechanism=' "$reviewed_marker" 2>/dev/null | head -1 | sed 's/^mechanism=//')
      is_retro=false
      case "$reviewer_val" in
        retrospective-shipped*|retrospective-cherry-pick-mtime-fp*) is_retro=true ;;
      esac
      [ "$mechanism_val" = "rein-heal-legacy-pending" ] && is_retro=true

      if [ "$is_retro" = true ] && [ "$SR1B_GIT_WORKTREE" = true ]; then
        # TIER 2 — constrained git committer-time fallback (retrospective only).
        # SOUND (no false-negative): a clean work-tree means the current content
        # IS the last commit touching the spec; committer-time ≤ reviewed means
        # that commit was integrated into THIS branch's history before review,
        # so its content was present at review time. Any post-review content
        # change is either a new commit (committer-time = now > reviewed → block)
        # or uncommitted (dirty → blocked just above). Plain checkout / branch
        # switch / rotation bump only the filesystem mtime, NOT committer-time,
        # so this tier clears the mtime false-positive without under-blocking.
        # A spec genuinely cherry-picked/integrated AFTER review has
        # committer-time = the integration moment > reviewed and is
        # conservatively blocked (we cannot prove the integrated content was the
        # reviewed content) — intended. NB: committer-time, not author-time —
        # author-time would wrongly allow a pre-review-authored commit that was
        # only integrated after review.
        rel_spec="${spec_path#"$PROJECT_DIR"/}"
        # Confirm the path is tracked (git log history alone is not proof).
        if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
             git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$rel_spec" >/dev/null 2>&1; then
          UNRESOLVED_SPECS=true   # untracked retro spec → cannot verify → fail-closed
          break
        fi
        # Uncommitted working-tree change → cannot prove freshness → stale.
        if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
             git -C "$PROJECT_DIR" diff --quiet HEAD -- "$rel_spec" >/dev/null 2>&1; then
          UNRESOLVED_SPECS=true   # dirty → stale
          break
        fi
        spec_commit_epoch=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
          git -C "$PROJECT_DIR" log -1 --format=%ct -- "$rel_spec" 2>/dev/null)
        if ! [[ "$spec_commit_epoch" =~ ^[0-9]+$ ]]; then
          UNRESOLVED_SPECS=true   # no commit history → fail-closed
          break
        fi
        if [ "$spec_commit_epoch" -gt "$reviewed_epoch" ]; then
          UNRESOLVED_SPECS=true   # committed/integrated after review → cannot prove → stale
          break
        fi
        continue                  # integrated before review, clean → content present at review
      fi

      # TIER 3 — mtime fallback (non-retrospective marker, or non-git project).
      # Preserves the pre-fix behavior where there is no checkout/cherry-pick FP
      # source; such markers migrate to TIER 1 on their next review. Python
      # getmtime avoids GNU vs BSD `stat` divergence; any failure is fail-closed.
      spec_mtime_epoch=$("${PYTHON_RUNNER[@]}" -c '
import os, sys
try:
    print(int(os.path.getmtime(sys.argv[1])))
except Exception:
    sys.exit(1)
' "$spec_path" 2>/dev/null) || {
        UNRESOLVED_SPECS=true   # unreadable mtime → fail-closed
        break
      }
      if [ "$spec_mtime_epoch" -gt "$reviewed_epoch" ]; then
        UNRESOLVED_SPECS=true   # spec touched after review (legacy heuristic) → stale
        break
      fi
    done
  fi

  # DOD-GATE-FP-TESTS (2026-05-29, incident 351623296a9bc1d8): the spec gate
  # blocks GLOBALLY on any unreviewed spec without consulting FILE_PATH. That
  # also blocked test files (tests/**), breaking reproduction-first / TDD
  # red-green — editing a failing test is the FIRST step of a fix, and the
  # test cannot touch real source, so it is no review-bypass. Exempt edits
  # whose target resolves under PROJECT_DIR/tests/. The containment check is
  # done in Python (normpath + commonpath) so an absolute OR repo-relative
  # FILE_PATH is handled, and a mere `tests` substring elsewhere (e.g.
  # src/tests-helper.ts) is NOT exempted. PYTHON_RUNNER is populated above;
  # a failure here falls through to the original block (fail-closed).
  if [ "$UNRESOLVED_SPECS" = true ]; then
    if "${PYTHON_RUNNER[@]}" -c '
import os, sys
project = os.path.realpath(sys.argv[1])
tests_root = os.path.join(project, "tests")
target = os.path.realpath(os.path.join(project, sys.argv[2]))
try:
    inside = os.path.commonpath([tests_root, target]) == tests_root
except ValueError:
    inside = False
sys.exit(0 if inside else 1)
' "$PROJECT_DIR" "$FILE_PATH" 2>/dev/null; then
      echo "NOTICE: pre-edit-dod-gate spec gate skip — test file ($FILE_PATH) under tests/ is exempt from the unreviewed-spec block (reproduction-first / TDD)." >&2
      UNRESOLVED_SPECS=false
    fi
  fi

  if [ "$UNRESOLVED_SPECS" = true ]; then
    echo "[rein] There is a design document that has not been reviewed yet. To proceed:" >&2
    echo "  1) Review the design document (/codex-review, or the spec-writer auto-review path)." >&2
    echo "  2) On PASS, mark it reviewed:" >&2
    echo "     bash <scripts-dir>/rein-mark-spec-reviewed.sh \"$spec_path\" codex" >&2
    echo "     (scripts-dir = \${CLAUDE_PLUGIN_ROOT}/scripts/ on plugin install, \${PROJECT_DIR}/scripts/ on maintainer repo)" >&2
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
# (a) 신규 DoD 섹션 누락 차단: post-edit-dod-routing-check.sh 가 DoD 작성 시
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
    echo "[rein] The following task records are missing the '## 라우팅 추천' routing section:" >&2
    for m in "${MISSING_MARKERS[@]}"; do
      echo "  - $(basename -- "$m" | sed 's/^\.routing-missing-//')" >&2
    done
    echo "  Add a '## 라우팅 추천' section to the task record with fields: agent / skills / mcps / rationale / approved_by_user." >&2
    echo "  The PostToolUse hook will inject the routing procedure body after the task record is saved." >&2
    echo "  Emergency bypass: echo 'reason=<reason>' > $ROUTING_BYPASS" >&2
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
    printf "[rein] The following active task records have a routing section without user approval:%b\n" "$ROUTING_VIOLATIONS" >&2
    echo "  To proceed:" >&2
    echo "  1) Confirm the routing plan with the user." >&2
    echo "  2) Add the approval line to the '## 라우팅 추천' section, then retry the edit." >&2
    echo "  Approval line format: a standalone YAML line inside the '## 라우팅 추천' section," >&2
    echo "    'approved_by_user: true' (no quotes). Leading spaces and a trailing inline '#' comment are OK." >&2
    echo "    Not recognized: bullet (- approved_by_user: true), bold (**approved_by_user: true**), or quoted (approved_by_user: \"true\")." >&2
    echo "  Emergency bypass: echo 'reason=<reason>' > $ROUTING_BYPASS" >&2
    log_block "routing section 위반" "$FILE_PATH"
    exit 2
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

  # X4.C.3 fast-path skip — design memo §8.4 / §3.4. effective_mode ==
  # source_edit + FILE_PATH 가 state.json.dirty_files 에 이미 등재되어 있으면
  # validator subprocess (~500ms) 를 skip 하고 직전 marker 상태를 그대로 유지.
  # 보수적 skip — design memo §6.2 R-7 risk mitigation (false-positive 잘못 skip
  # 위험 인지). state.json 부재 (greenfield) / malformed JSON / unknown
  # schema_version / state-machine.sh 부재 / lock 실패 → legacy validator path.
  # state_is_valid 로 게이트해, corrupt/unknown-schema state 의 default mode 가
  # fast-path 분기를 trigger 하지 않도록 한다 (design memo §2.3 legacy fallback).
  if [ -f "$SCRIPT_DIR/lib/state-machine.sh" ]; then
    if . "$SCRIPT_DIR/lib/state-machine.sh" 2>/dev/null; then
      # X4.C.5: read_fast_path_state folds validate + effective-mode + the
      # dirty_files match into one python call under one lock (was state_is_valid
      # + read_effective_mode + read_state + a separate match = 5 python + 1
      # lock). Non-zero return = lock/python/parse failure → fall through to the
      # legacy validator path (codex Round 3 HIGH preserved). The leading "valid"
      # field is "1" only for a well-typed schema-v1 doc, so a corrupt/unknown-
      # schema state never trips the skip (codex Round 2/4 HIGH preserved). The
      # dirty match is against the on-disk dirty_files snapshot — same target as
      # the prior read_state-based match.
      if _fp_line=$(read_fast_path_state "$FILE_PATH" 2>/dev/null) \
          && IFS=$'\t' read -r _fp_valid _fp_mode _fp_match <<<"$_fp_line" \
          && [ "$_fp_valid" = "1" ] && [ "$_fp_mode" = "source_edit" ] \
          && [ "$_fp_match" = "1" ]; then
        echo "NOTICE: pre-edit-dod-gate state.fast-path skip — file=$FILE_PATH (mode=source_edit, dirty_files hit, validator subprocess skipped)" >&2
        touch "$SRC_EDIT_MARKER" 2>/dev/null
        exit 0
      fi
    fi
  fi

  # RES-1: lazy-resolve VALIDATOR_PATH via plugin-aware helper. The
  # resolver picks ${CLAUDE_PLUGIN_ROOT}/scripts/<name> first, then
  # ${PROJECT_DIR}/scripts/<name> as fallback. Without this, fresh
  # plugin installs (no repo scripts/) would always fail Tier 1 on a
  # missing validator, which would block legitimate edits.
  if [ -z "${VALIDATOR_PATH:-}" ]; then
    VALIDATOR_PATH=$(resolve_helper_script rein-validate-coverage-matrix.py) || {
      mkdir -p "$DOD_DIR" 2>/dev/null
      touch "$DOD_MISMATCH_MARKER" 2>/dev/null
      echo "[rein] The coverage validator (rein-validate-coverage-matrix.py) could not be found. Run 'rein update' to restore it." >&2
      log_block "validator helper missing" "$SAD_PATH"
      exit 2
    }
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
      echo "[rein] The coverage validator timed out while checking $SAD_PATH — the edit is blocked until the validator can complete. Check if the plan file is valid." >&2
      log_block "validator timeout (tier 1)" "$SAD_PATH"
      exit 2
      ;;
    1:*)
      touch "$DOD_MISMATCH_MARKER"
      rm -f "$DOD_ADVISORY_MARKER"
      echo "[rein] The coverage check failed for the active task record ($SAD_PATH, exit $VEXIT). Update the '## 범위 연결' section to reference the IDs that are actually marked 'implemented' in the plan." >&2
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
  # GMF-3: 확장자-소스로 새로 차단되는 경우 "DoD 요구 이유" 안내(파일경로당 1회).
  emit_ext_source_notice
  echo "[rein] Source files cannot be edited yet because there is no active task record. To proceed:" >&2
  echo "  1) Create trail/dod/dod-$(date +%Y-%m-%d)-<slug>.md describing what this task changes." >&2
  echo "  2) Add a '## 라우팅 추천' section with a user-approval line (the routing gate will require it next)." >&2
  log_block "미완료 DoD 없음" "$FILE_PATH"
  exit 2
fi
