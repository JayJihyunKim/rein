#!/bin/bash
# Hook: PostToolUse(Write|Edit|MultiEdit)
# plan 파일 편집 시 dirty path 를 trail/dod/.plan-coverage-dirty 에 append.
# 실제 validator 실행은 pre-bash-test-commit-gate.sh 의 flush 가 commit/test
# 시점에 수행 (Area B X3.B.1, design ref:
# docs/specs/2026-05-20-area-b-post-edit-deferral.md §5.1 + §7 Scope ID 1).
#
# Edit-time cost = path 분류 + append 1줄. validator subprocess 호출 0.
# PIPE_BUF (대부분 512 bytes) 초과 한 줄은 legacy immediate validator fallback
# 으로 silent corruption 방지 (§5.1.r3).

set -u

# --- Policy toggle (plugin mode only) ---
# .rein/policy/hooks.yaml can disable a hook via `<hook-name>: false`
# or `{ <hook-name>: { enabled: false } }`.
# Plugin mode: ${CLAUDE_PLUGIN_ROOT} is set, loader is invoked.
# Non-plugin runtime: env unset, check is skipped (preserves pre-policy behavior).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  if ! python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "post-edit-plan-coverage"; then
    exit 0  # disabled by user policy
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
DOD_DIR="$PROJECT_DIR/trail/dod"
DIRTY_LIST="$DOD_DIR/.plan-coverage-dirty"
MARKER="$DOD_DIR/.coverage-mismatch"

# X3.B.1: validator 직접 호출은 commit gate flush 로 이동. 본 hook 은 dirty
# path 만 append. 단 PIPE_BUF 초과 한 줄은 fallback 으로 validator 호출.
#
# RES-1: resolve VALIDATOR via the plugin-aware helper (PIPE_BUF fallback 용
# 으로만 사용). validator 부재 시 hook 은 여전히 append 만 수행 — fallback
# 만 no-op 으로 degrade. Source-fail 은 여전히 fatal (path-policy lib pattern).
if ! . "$SCRIPT_DIR/lib/plugin-script-path.sh" 2>/dev/null; then
  echo "BLOCKED: [post-edit-plan-coverage] plugin-script-path library missing at $SCRIPT_DIR/lib/plugin-script-path.sh" >&2
  exit 2
fi
VALIDATOR=$(resolve_helper_script rein-validate-coverage-matrix.py 2>/dev/null || true)

# Append-line atomicity 한도. POSIX 는 PIPE_BUF (대부분 512 bytes) 이하의
# write 만 concurrent append 시 atomic 을 보장. 초과 한 줄은 partial-line
# corruption 위험 → legacy immediate validator fallback 으로 우회.
PIPE_BUF_LIMIT=512

# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
# shellcheck source=./lib/post-edit-policy-gate.sh
. "$SCRIPT_DIR/lib/post-edit-policy-gate.sh"
post_edit_policy_gate "post-edit-plan-coverage"

# Plan A §2 (GI-path-policy-lib): path classification lives in a shared
# library. If the library is missing, fail-closed rather than silently
# degrading — a missing library means the hook would apply no classifier
# and validate *every* Write, or worse, skip every Write.
if ! . "$SCRIPT_DIR/lib/path-policy.sh" 2>/dev/null; then
  echo "BLOCKED: [post-edit-plan-coverage] path-policy library missing at $SCRIPT_DIR/lib/path-policy.sh" >&2
  exit 2
fi

hook_input_load   # 캐시 활성 시 INPUT/FILE_PATHS 채워짐.

if [ "${REIN_HOOK_INPUT_CACHE:-0}" != "1" ]; then
  # Post-hook: Python 미해결 시 조용히 skip (세션 차단 금지).
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 0
  fi

  # Claude Code hook payload 의 여러 필드에서 편집 대상 경로를 수집한다.
  # 수집 순서(원본 보존): tool_input.file_path → tool_input.edits[*].file_path
  #                   → tool_result.edits[*].file_path → tool_result.file_path(fallback only).
  # 빈 값/중복은 awk 단계에서 제거 (원본의 `if fp and fp not in paths` 의미 유지).
  FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
    --field tool_input.file_path \
    --array-of tool_input.edits --subfield file_path \
    --array-of tool_result.edits --subfield file_path \
    --default '' 2>/dev/null \
    | awk 'NF && !seen[$0]++'
  )

  # fallback: tool_result.file_path 는 1~3 에서 경로를 찾지 못했을 때만 사용 (Codex final review A4).
  if [ -z "$FILE_PATHS" ]; then
    FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
  fi
fi

[ -z "$FILE_PATHS" ] && exit 0

# validator 호출에 python runner 가 필요. 캐시 경로에서 resolve 보장.
if [ -z "${PYTHON_RUNNER[0]:-}" ]; then
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 0
  fi
fi

mkdir -p "$DOD_DIR"

# Plan A §2 consumer: is_plan_path from the shared library expects a
# repo-relative path (GI-path-policy-input-contract). This wrapper handles
# the "absolute path → repo-relative" normalization that was previously
# inlined here.
_is_plan_abs() {
  local abs="$1"
  local rel
  case "$abs" in
    "$PROJECT_DIR"/*) rel="${abs#$PROJECT_DIR/}" ;;
    *) return 1 ;;
  esac
  is_plan_path "$rel"
}

# X3.B.1: dirty append (validator 호출은 commit gate flush 가 담당).
#
# Concurrency model (codex Round 1 HIGH fix): we share `.plan-coverage-dirty`
# with the commit-gate flush. Naively appending by pathname leaves an
# open-before-rename window — if flush executes `mv .plan-coverage-dirty
# .plan-coverage-dirty.processing` between our open() and write(), our write
# lands in the already-renamed inode and is removed when flush completes.
# Mitigation: a portable mkdir-based mutex (`.plan-coverage-dirty.lock`)
# guards both append AND the flush's mv (commit gate side). mkdir is atomic
# on POSIX filesystems and works without flock(1) (which is missing on stock
# macOS). On lock-acquisition failure, fall back to the legacy synchronous
# validator path — that path was the entire pre-deferral behavior, so it is
# always-safe (no data loss, just slower).
LOCK_DIR_PATH="$DOD_DIR/.plan-coverage-dirty.lock"
LOCK_TIMEOUT_MS=2000          # 2s total wait budget for append
LOCK_POLL_DELAY=0.05          # 50ms poll cadence

# Try to acquire the lock with bounded retry. Returns 0 on success, 1 on
# timeout. Caller MUST `release_dirty_lock` on success.
acquire_dirty_lock() {
  mkdir -p "$DOD_DIR"
  local waited_ms=0
  while ! mkdir "$LOCK_DIR_PATH" 2>/dev/null; do
    if [ "$waited_ms" -ge "$LOCK_TIMEOUT_MS" ]; then
      return 1
    fi
    sleep "$LOCK_POLL_DELAY"
    waited_ms=$((waited_ms + 50))
  done
  return 0
}

release_dirty_lock() {
  rmdir "$LOCK_DIR_PATH" 2>/dev/null || true
}

# Synchronous fallback — invoke validator immediately and write to the legacy
# .coverage-mismatch marker (pre-deferral behavior). Always-safe.
fallback_immediate_validator() {
  local abs="$1"
  if [ -z "${VALIDATOR}" ] || [ ! -f "$VALIDATOR" ]; then
    # Validator unavailable — record fact to stderr so the failure is not
    # silent (codex Round 1 Medium fix: PIPE_BUF + missing-validator must
    # not silently lose coverage state).
    echo "NOTICE: coverage matrix validator unavailable; cannot track dirty plan: $abs" >&2
    return 0
  fi
  mkdir -p "$DOD_DIR"
  TMP_ERR=$(mktemp)
  "${PYTHON_RUNNER[@]}" "$VALIDATOR" "$abs" 2> "$TMP_ERR"
  local vexit=$?
  if [ -s "$TMP_ERR" ]; then
    cat "$TMP_ERR" >&2
  fi
  rm -f "$TMP_ERR"
  if [ "$vexit" -ne 0 ]; then
    if ! { [ -f "$MARKER" ] && grep -qxF "$abs" "$MARKER"; }; then
      echo "$abs" >> "$MARKER"
    fi
    echo "NOTICE: coverage matrix validation failed for $abs (immediate fallback path) — marker updated" >&2
  fi
}

# Append 는 O_APPEND single-line atomic 인 동시에 lock 으로 mv 와 직렬화 된다.
# 같은 path 가 여러 번 append 되어도 flush 시점에 unique path set 으로 처리
# (design memo §7 ID 2 의 set-등가 contract).
append_dirty_path() {
  local abs="$1"
  # +1 for trailing newline. printf path | wc -c 는 byte count.
  local bytes=$(($(printf '%s' "$abs" | wc -c) + 1))
  if [ "$bytes" -gt "$PIPE_BUF_LIMIT" ]; then
    # PIPE_BUF fallback (design memo §5.1.r3): atomic append cannot be
    # relied upon — even with lock, the single-write atomicity at the
    # kernel level is bounded. Use the synchronous validator path so
    # commit gate still has authoritative state. fallback_immediate_validator
    # itself is vocal on missing validator (no silent skip).
    fallback_immediate_validator "$abs"
    return 0
  fi

  # Acquire the cross-hook mutex. If the lock is contended beyond the
  # timeout, degrade to the immediate validator path — that path predates
  # deferral and is always-safe.
  if ! acquire_dirty_lock; then
    echo "NOTICE: $LOCK_DIR_PATH contended >${LOCK_TIMEOUT_MS}ms; using immediate validator fallback for $abs" >&2
    fallback_immediate_validator "$abs"
    return 0
  fi
  # Lock held — append safely. Lock also serializes us with the commit-gate
  # flush, so flush's mv cannot race our open()→write() window.
  printf '%s\n' "$abs" >> "$DIRTY_LIST"
  release_dirty_lock
}

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  ABS=$("${PYTHON_RUNNER[@]}" -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null)
  [ -z "$ABS" ] && continue
  _is_plan_abs "$ABS" || continue
  [ -f "$ABS" ] || continue  # 편집된 파일이 실제로 존재해야 검증 가능

  append_dirty_path "$ABS"
done <<< "$FILE_PATHS"

exit 0
