#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit)
# v1 존속 규율 게이트 묶음 — 활성 DoD 존재/거버넌스/사건 리뷰/스펙 리뷰/
# 라우팅 판정. 활성 "작업" 축(=이 편집을 커버하는 활성 task record 가
# 있는가) 판정은 이 훅에 없다 — 그 축은 sibling pre-edit-task-gate.sh 로
# 전량 이관됐다 (아래 "계승 매핑" 참조).
#
# Phase 7 웨이브 3 ③-b (edit-gate 교대): 이 파일은 (구)pre-edit-dod-
# gate.sh 를 대체한다. 그 파일은 삭제됐다. 계승 매핑:
#   - lib 소싱(portable/python-runner/project-dir/select-active-dod/
#     governance-stage/plugin-script-path), log_block(), shadow-capture
#     init, INPUT 캡처, python resolve, GMF-4 정책 토글, file_path+
#     tool_name 단일 추출 + 0x1F/LF 보안 하드닝, PERF-2 캐시 공급, 경로
#     정규화, source-path-classify 호출, emit_ext_source_notice() 정의,
#     incident-review-gate → spec-review-gate → routing-gate 순서 호출 —
#     전부 구 pre-edit-dod-gate.sh 에서 바이트 동일하게 이전 (아래 각
#     지점 주석 참조). dod-found(lib/dod-found.sh, rein_dod_found())는 이
#     계승 목록에 **없다** — Phase 7 웨이브 3 ③-b code review round 1
#     (Low)에서 소비자 0건(구 v1 최종 판정만 이 값을 읽었고, 그 판정은
#     pre-edit-task-gate.sh 로 이관되며 소멸했다)이 확인되어 이 훅에서
#     제거됐다. lib 자체와 그 함수는 pre-edit-coverage-gate.sh 가 자신의
#     select_active_dod 호출 직전 판정으로 여전히 사용하므로 소관만
#     coverage-gate 쪽으로 잔존한다 — 이 훅은 이제 그 값을 산출하지
#     않는다.
#   - 거버넌스 훼손 차단(구 L345-362, governance-stage INVALID 분기)은
#     lib/governance-invalid-gate.sh 로 추출해 이 훅이 소싱·호출한다
#     (다른 정밀 축들과 같은 verbatim-이전 스타일 — 동작 바이트 동일).
#   - 활성 "작업" 최종 판정(구 L424-439, lib/active-task-gate.sh 소싱·
#     rein_check_active_task 호출)은 이 훅에 **없다** — pre-edit-task-
#     gate.sh 로 전량 이관됐다 (그 훅의 헤더 참조).
#
# 이 훅 자신의 명칭 변경에 따른 표면 변화 (동작 판정에는 영향 없음,
# 라벨/토글 키만 변경):
#   - log_block() 이 rein-log-block.py 에 넘기는 훅 이름 라벨:
#     "pre-edit-dod-gate" → "pre-edit-discipline-gate"
#   - shadow_capture_init() 에 넘기는 훅 이름: 동일하게 변경
#   - GMF-4 정책 토글 키(.rein/policy/hooks.yaml): 새 훅 이름
#     "pre-edit-discipline-gate" 기준. 구 이름 "pre-edit-dod-gate" 는
#     scripts/rein-policy-loader.py 의 UMBRELLA_KEYS 에 우산(umbrella) 키로
#     매핑되어 있다 (Phase 7 wave 3 ③-b code review round 1 수리 — 기존
#     "pre-bash-guard" umbrella 선례와 동일한 패턴: pre-bash-guard.sh 가
#     pre-bash-safety-guard.sh + pre-bash-test-commit-gate.sh 로 분할됐을
#     때도 구 단일 키가 두 후속 훅 모두를 계속 끄도록 매핑했다). 기존에
#     `pre-edit-dod-gate: false` 를 설정해 둔 프로젝트는 이 교대 이후에도
#     그 사용자 의도("이 계열 게이트를 끄고 싶다")가 그대로 보존된다 —
#     개별 키(`pre-edit-discipline-gate` / `pre-edit-task-gate`) 의 명시
#     override 가 있으면 그게 우산 값보다 우선한다(정상적인 개별-키
#     우선 규칙). 이전 개정에서는 "이 교대가 사실상 새 훅을 도입하는
#     성격이라 명시 재설정을 요구하는 쪽이 안전하다"는 이유로 의도적
#     비-매핑을 택했으나, 그 판단은 기존 pre-bash-guard 선례와 일관성이
#     없었고(같은 저장소 안에서 "분할 시 구 키 승계" 정책이 훅마다
#     달라짐) 사용자가 명시적으로 끈 게이트가 이름만 바뀌었다고 아무
#     경고 없이 다시 켜지는 쪽이 실제로는 더 위험한 방향이라 umbrella
#     매핑 채택으로 교체됐다.
#
# (inbox 정리는 trail-rotate (구 inbox-compress).sh로 분리됨)
#
# Exit code: 0=허용, 2=차단

# Security (High, Phase 7 wave 3 ③-b code review round 2 — 재현 완료):
# 이 훅에 들어오는 그대로의 프로세스 환경을 무조건 신뢰하지 않는다.
# REIN_GATE_PEEK_MODE 는 pre-edit-coverage-gate.sh 의 `_rein_precheck_would_
# block` 서브셸이 그 서브셸 수명 동안만 `export` 하는 내부 계약 값이다 —
# lib/incident-review-gate.sh / lib/spec-review-gate.sh / lib/routing-
# gate.sh 안의 모든 1회성 바이패스 소비(rm -f)가 이 값이 "1"이면 생략되도록
# 가드되어 있다("peek 는 판정만 하고 절대 변이하지 않는다"는 계약). 이 훅은
# 그 세 lib 를 ENFORCING 으로(=peek 가 아니라) 호출하는 쪽이라 이 변수를
# 스스로 export 하지 않지만, 오염된 세션 환경 / 다른 도구의 잘못된 export /
# 문자 그대로의 외부 주입 등 어떤 경로로든 이 변수가 "1"인 채로 상속되면,
# 이 진짜(enforcing) 호출이 조용히 "peek 모드"로 격하되어 사용자가 심어 둔
# 1회성 바이패스 표식(.skip-routing-gate 등)이 소비되지 않고 디스크에 남는다
# — 한 번 쓰고 버려야 할 우회가 무한 재사용 가능한 상태로 굳는 회귀
# (재현 완료). 판정 lib 를 source 하기 전에 무조건 unset 해 이 훅의 판정이
# 상속된 환경값과 무관하게 항상 "진짜 집행"으로만 동작하게 한다 — peek
# 권한은 오직 coverage-gate 자신의 서브셸 export 로만 부여될 수 있고, 그
# 서브셸 밖으로는 절대 흘러나오면 안 된다는 내부 계약을 여기서 강제한다.
unset REIN_GATE_PEEK_MODE

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
# silently degraded gate is the drift we are trying to prevent.
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

# Plan A Phase 4 Task 4.3 (GI-dod-gate-cache-invalidation): session cache
# removed. The selector + validator are cheap enough to run on every hook
# invocation; any cache would re-introduce stale-pass drift. The legacy
# /tmp/.claude-dod-<key>-<mtime> variables are intentionally no longer
# declared.

# DOD_MISMATCH_MARKER (Plan A §4.2 table) — this gate still touches it
# directly for ONE remaining case: a corrupt governance.json (see
# lib/governance-invalid-gate.sh, sourced below). The .dod-coverage-mismatch /
# .dod-coverage-advisory pair's OTHER producer (the coverage-validator
# tier/exit-code table) lives in pre-edit-coverage-gate.sh — governance-stage
# handling itself is explicitly out of scope for that hook (it belongs to the
# "옛 3단계 강도 설정" that move deferred), so this one touch site stays here.
# There is no DOD_ADVISORY_MARKER declaration left in this file — the
# advisory marker is produced only by pre-edit-coverage-gate.sh.
DOD_MISMATCH_MARKER="$DOD_DIR/.dod-coverage-mismatch"    # blocking

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
  # v1 safety release ① — 기록·마스킹·카운트는 lib/rein-log-block.py SSOT
  # (bash-guard-infra.sh 의 log_block 과 공유). 이 게이트의 target 은 파일
  # 경로/짧은 리터럴이므로 path 모드 (마스킹 적용, 해시 축약 없음). helper
  # 부재 시 로깅만 생략 — 차단 판정에는 영향 없음.
  local _lb_helper="$SCRIPT_DIR/lib/rein-log-block.py"
  if [ ! -f "$_lb_helper" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$BLOCKS_LOG_JSONL")"
  # hook+reason 조합별 카운트 (aggregate THRESHOLD 와 동일 기준). source=test
  # 레코드는 카운트에서 제외 — 테스트 하니스 이벤트가 반복 경고를 오염시키지
  # 않도록 (legacy 무필드 레코드는 live 취급).
  local count
  count=$("${PYTHON_RUNNER[@]}" "$_lb_helper" \
    "pre-edit-discipline-gate" "$reason" "$target" \
    "$BLOCKS_LOG_JSONL" "$PROJECT_DIR/.rein/logs/blocks-raw.jsonl" \
    path "${REIN_TEST_MODE:-0}" 2>/dev/null || echo 0)
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
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
# Discipline gate
# ============================================================
. "$SCRIPT_DIR/lib/shadow-capture.sh" 2>/dev/null && shadow_capture_init "pre-edit-discipline-gate"  # plan Task 2.8 — shadow capture (fire-and-forget)

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
  "${PYTHON_RUNNER[@]}" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "pre-edit-discipline-gate"
  _pol_rc=$?
  if [ "$_pol_rc" -eq 1 ]; then
    exit 0  # loader ran cleanly + disabled by user policy
  fi
  # rc 0 = enabled (continue); rc ∉ {0,1} = loader call failure → fail-closed.
fi

# file_path + tool_name 단일 프로세스 추출 (PERF, 2026-08-18 수리). TOOL_NAME
# 은 이 훅 자신은 소비하지 않는다 — 그 축(활성 작업)이 sibling pre-edit-
# task-gate.sh 로 전량 이관됐기 때문이다. 그럼에도 이 훅은 file_path 단독
# 추출로 되돌리지 않고 원래의 2-필드 추출 호출을 바이트 동일하게 유지한다:
# 아래 0x1F 구분자 개수 검사 + 파라미터 확장 분할은 정확히 "구분자 1개인
# 2-필드 추출"이라는 형태에 맞춰 검증된 보안 하드닝이고(2026-08-19 보안
# 검토 실증 2건, 아래 각 검사 지점 주석 참조), 1-필드 추출로 축소하려면 그
# 하드닝 자체를 다시 유도해야 한다 — 위험 대비 이득이 없는 변경이라 하지
# 않는다. 구분자는 파일 경로/도구명에 나타날 일이 없는 ASCII Unit
# Separator(0x1F)를 쓴다 — 기본 구분자(줄바꿈)는 `read` 한 번으로 여러
# "줄"을 나눠 담을 수 없어(줄바꿈 자체가 read 의 레코드 종결자이므로) 이
# 용도에 맞지 않는다. 값 부재·형식 이상 시의 방향은 기존과 동일하다 —
# --default '' 는 두 필드 모두에 적용되므로 missing field 로 인한 exit 21
# 은 여전히 발생하지 않는다(원래 FILE_PATH 단독 추출과 동일한 실패 방향).
EXTRACT_SEP=$'\x1f'
EXTRACT_OUT=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --field tool_name --default '' --separator "$EXTRACT_SEP")
EXTRACT_RC=$?

if [ "$EXTRACT_RC" -ne 0 ]; then
  echo "[rein] The edit gate cannot read the tool input because the hook JSON could not be parsed (extract-hook-json.py exited $EXTRACT_RC). This is an installation issue — run 'rein update' to repair." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

# Security (High, 2026-08-19 보안 검토 실증): "0x1F(ASCII Unit Separator)
# 는 파일 경로에 나타나지 않는다" 는 가정을 검증으로 대체한다. POSIX
# 파일명은 NUL 과 '/' 만 금지하므로 0x1F 는 file_path 값 안에 합법적으로
# 존재할 수 있다. 이 2-field 추출(--field tool_input.file_path --field
# tool_name)은 정확히 구분자 1개(두 값 사이의 join)를 기대한다.
# file_path 값 자체에 0x1F 가 섞여 있으면 아래 `IFS=$EXTRACT_SEP read`
# 가 그 지점에서도 분리된다 — bash read 매뉴얼: 변수 수보다 word 가
# 많으면 남는 word 와 "그 사이 구분자"까지 통째로 마지막 변수에 흡수됨.
# 그 결과 FILE_PATH 가 확장자 앞에서 절단되고, 절단된 경로가 소스
# 확장자 화이트리스트에 안 맞아 비소스로 오분류되어 exit 0 으로 무음
# 통과한다 — 이 훅 전체 체인(사건 검토/스펙 리뷰/라우팅 게이트)이
# 스킵되는 결과. 구분자 개수를 세어 정확히 1이 아니면 기존 파싱 실패
# (EXTRACT_RC!=0)와 동일하게 fail-closed 처리한다.
EXTRACT_SEP_STRIPPED="${EXTRACT_OUT//$EXTRACT_SEP/}"
EXTRACT_SEP_COUNT=$(( ${#EXTRACT_OUT} - ${#EXTRACT_SEP_STRIPPED} ))
if [ "$EXTRACT_SEP_COUNT" -ne 1 ]; then
  echo "[rein] The edit gate cannot run because the tool input produced a malformed field extraction (found $EXTRACT_SEP_COUNT embedded separator(s), expected exactly 1 — a file path or tool name likely contains the internal separator character). This is a parsing safety check, not an installation issue; the edit is blocked to avoid mis-splitting the path." >&2
  log_block "json parse failure" "unknown"
  exit 2
fi

# Security (High, 2026-08-19 보안 델타 재검증 실증): 위 개수 검사로 0x1F
# 절단은 막았으나, bash `read` 는 IFS 설정과 무관하게 첫 개행(LF)에서
# 레코드를 끊는다 — file_path 에 리터럴 LF 를 심으면 구분자(0x1F)는
# 정확히 1개라 개수 검사를 통과하지만 `read` 가 LF 앞에서 FILE_PATH 를
# 절단해 동일한 무음 우회를 만든다. LF 를 하나 더 차단하는 열거 대신
# `read` 를 버리고, 이미 "구분자 정확히 1개" 로 검증된 EXTRACT_OUT 을
# 파라미터 확장으로 위치 분할한다 — 파라미터 확장은 LF 를 종결자가
# 아닌 일반 바이트로 취급하므로 delimiter 절단 클래스(LF·기타 종결
# 후보)가 통째로 사라진다. EXTRACT_OUT 은 $(...) 로 캡처돼 후행 개행이
# 이미 제거된 상태이며, 구분자가 정확히 1개이므로 %% 와 # 가 두 필드를
# 모호성 없이 나눈다. 경로 안의 LF 는 절단 없이 보존돼 실제 확장자로
# 정상 분류된다(우회 아님 — 소스면 게이트가 그대로 집행).
FILE_PATH="${EXTRACT_OUT%%"$EXTRACT_SEP"*}"
TOOL_NAME="${EXTRACT_OUT#*"$EXTRACT_SEP"}"

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
# os.path.normpath 패턴 재사용 (post-edit-src-touch-marker.sh 와 동일).
# URL-encoded / `//` / `/./` 세그먼트 포함 경로 edge case 보호. 정규화 전/후
# 불일치 시 stderr NOTICE 만 (gate 동작 변경 없음). resolver 부재 fallback
# 은 원본 사용 (silent). 이후 case 매칭은 정규화된 FILE_PATH 사용.
FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
  'import os,sys; print(os.path.normpath(sys.argv[1]))' \
  "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
[ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"
if [ "$FILE_PATH_NORM" != "$FILE_PATH" ]; then
  echo "NOTICE: pre-edit-discipline-gate normalized path: $FILE_PATH → $FILE_PATH_NORM" >&2
fi
FILE_PATH="$FILE_PATH_NORM"

# --- 경로 기반 면제 + 소스 판정 (GMF-3: 디렉토리/확장자 화이트리스트) ---
# M1 (2026-04-22 retro-review-sweep): 기존 blanket `*/.claude/*` exemption 제거.
# 배경: 사용자 repo 의 .claude/rules/*, .claude/skills/**, .claude/agents/*,
#   .claude/workflows/*, AGENTS.md 는 plugin 이 제공하는 운영 surface — DoD 없이
#   편집되면 안 됨. (rein-dev 메인테이너 환경 hint: .claude/CLAUDE.md /
#   .claude/orchestrator.md 도 동일 카테고리이나 일반 사용자 repo 에는 없음.)
# 면제 대상은 runtime state / 운영 데이터 / git 인프라 파일만.
#
# 분류 로직 자체는 lib/source-path-classify.sh 로 이동했다 (동작 불변 리팩토링
# — feature-builder-refactor, "고아가 되는 공유 표식" 재배치 작업의 일부). 이유:
# post-edit-src-touch-marker.sh / pre-edit-coverage-gate.sh 두 신규 훅이 이
# 게이트와 독립적으로 실행되면서도 "이 경로가 소스인가" 판정에서 절대 갈라지면
# 안 되므로, 판정 로직을 이 훅의 프로세스 수명에 묶어두지 않고 공유 함수로 뽑았다.
# 아래 호출은 원래 인라인 case 문과 동일한 순서(면제 → (1)~(4)단계)로 동일한
# 케이스 패턴을 그대로 실행한다 — 판정 결과는 바뀌지 않는다.
if ! . "$SCRIPT_DIR/lib/source-path-classify.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/source-path-classify.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_classify_source_path "$FILE_PATH"
[ "$REIN_SRC_CLASS" = "exempt" ] && exit 0

if [ "$IS_SOURCE" = false ]; then
  exit 0
fi

# GMF-3 안내 메시지 헬퍼 (파일경로당 1회) — lib/ext-source-notice.sh 로 이전
# (Phase 7 웨이브 3 ③-b: sibling pre-edit-task-gate.sh 도 자신의 v2-DENY
# relay 경로에서 동일 안내를 내보내야 해서 공유 lib 화했다 — 그 lib 의
# 헤더 "왜 공유 lib 인가" 절 참조). 이 훅은 활성-작업 축을 더 이상 갖고
# 있지 않으므로(그 축의 v1 "no active task record" 분기가 emit_ext_
# source_notice 를 부르던 유일한 호출부였다) 실제로는 호출하지 않지만,
# 향후 이 훅에서 새 차단 지점이 생기면 바로 재사용할 수 있도록 소싱은
# 유지한다.
if ! . "$SCRIPT_DIR/lib/ext-source-notice.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/ext-source-notice.sh). Run 'rein update' to restore it." >&2
  exit 2
fi

# --- Governance stage (Plan A §6, GI-governance-stage-config) ---
# Fail-closed on malformed / unknown stage: "silent Stage 1 downgrade" is a
# bypass path. Stage 1 (default / file-absent) is advisory; Stage 2/3 is
# blocking. INVALID → block all Edits until config is fixed.
#
# Extracted to lib/governance-invalid-gate.sh (Phase 7 웨이브 3 ③-b —
# pre-edit-dod-gate.sh 삭제에 맞춰 다른 정밀 축들과 같은 lib 스타일로
# 정리). Behavior-preserving move: the function body sourced below is
# byte-for-byte identical to the block that used to be inline here.
if ! . "$SCRIPT_DIR/lib/governance-invalid-gate.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/governance-invalid-gate.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_check_governance_invalid

# --- Incident Review Pending 검사 (cache 보다 앞. self-heal 포함) ---
# Extracted to lib/incident-review-gate.sh (dod-gate fix cycle, 2026-08-14
# — 당시 사유였던 coverage-gate 의 read-only peek 는 Phase 7 웨이브 3
# ③-b round 6 에서 pre-edit-dispatcher.sh 의 순차 실행 보장으로 제거됨:
# coverage-gate 가 실행된다는 것 자체가 이 게이트를 이미 통과했다는
# 증명이라 재유도가 불필요하다. lib 분리 자체는 판정 경계 정리로 계속
# 유효 — 그 lib 헤더의 HISTORY 절 참조). Behavior-preserving move:
# identical checks, just relocated.
if ! . "$SCRIPT_DIR/lib/incident-review-gate.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/incident-review-gate.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_check_incident_review_gate

# Plan A Phase 4 Task 4.3 (GI-dod-gate-cache-invalidation):
# The 5-min /tmp/.claude-dod-* session cache was removed here.
# Every DoD-gate invocation now runs the selector + validator from scratch.
# Benefit: "stale pass" class of drift is structurally impossible.
# Cost: one extra validator subprocess (~500ms) per Edit/Write. Well under
# the 30s timeout defined by GI-validator-v2-timeout-fail-closed.

# NOTE (Phase 7 wave 3 ③-b code review round 1, Low — dead-code removal):
# this hook used to also source lib/dod-found.sh and call `rein_dod_found`
# here (producing the $DOD_FOUND global). That call had ZERO consumers in
# this file: the only reader of $DOD_FOUND was lib/active-task-gate.sh's
# rein_check_active_task() entry point, and this hook never calls that
# entry point (the active-task axis moved entirely to pre-edit-task-gate.sh,
# which reuses only active-task-gate.sh's two sub-functions — see that
# hook's own header). Measured: zero references to $DOD_FOUND anywhere else
# in this file. The dead call was removed rather than kept "just in case" —
# lib/dod-found.sh and its rein_dod_found() function are UNCHANGED and still
# actively used by pre-edit-coverage-gate.sh (which computes its own
# $DOD_FOUND before calling select_active_dod — see that hook's own call
# site), so no capability was lost, only a no-op call in this file.

# --- Spec review gate ---
# Extracted to lib/spec-review-gate.sh (feature-builder-refactor task step 2
# — "code review" transition boundary). Behavior-preserving move: the
# function body sourced below is byte-for-byte identical to the block that
# used to be inline here. See that file's header for the extraction
# rationale and the caller contract.
if ! . "$SCRIPT_DIR/lib/spec-review-gate.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/spec-review-gate.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_check_spec_review_gate

# --- Routing gate ---
# Extracted to lib/routing-gate.sh (dod-gate fix cycle, 2026-08-14 —
# coverage-gate precondition-awareness). pre-edit-coverage-gate.sh needs to
# independently re-derive "is this precondition currently blocking" without
# hand-copying the missing-section-glob / M4 spec-gen-fail / approved_by_user
# decision tree into a second location (see that lib's header for the full
# rationale and the read-only peeking contract). Behavior-preserving move:
# the function body sourced below is byte-for-byte identical to the block
# that used to be inline here (including its own "BEGIN/END routing-gate"
# grouping).
if ! . "$SCRIPT_DIR/lib/routing-gate.sh" 2>/dev/null; then
  echo "[rein] The edit gate cannot run because a required library is missing (lib/routing-gate.sh). Run 'rein update' to restore it." >&2
  exit 2
fi
rein_check_routing_gate

# 활성 "작업" 축(=이 편집을 커버하는 활성 task record 가 있는가)은 여기
# 없다 — pre-edit-task-gate.sh 가 그 판정을 전담한다. 현행 실행 모델
# (Phase 7 웨이브 3 ③-b round 6~): 이 훅은 pre-edit-dispatcher.sh 의
# 첫 번째 자식으로 실행되며, 디스패처가 discipline → task → coverage 를
# **순차** 실행하고 첫 차단에서 중단한다 — 이 훅이 exit 0 하면 디스패처가
# 다음 자식(task-gate)을 실행하므로, 이 훅의 통과가 곧 편집 허용은
# 아니다 (후행 자식이 차단할 수 있다). 같은 이벤트에 병렬 등록된 훅들의
# 순서 비보장 문제(hooks-guide: "the order is non-deterministic")는 이
# 디스패처 단일 등록으로 해소됐다 — hooks.json 에는 디스패처 1건만
# 등록되고 세 게이트는 그 자식으로만 실행된다 (디스패처 헤더가 계약 정본).
exit 0
