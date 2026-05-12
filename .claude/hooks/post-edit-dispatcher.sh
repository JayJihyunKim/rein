#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit) — dispatcher
#
# 기존 7개 post-hook 을 단일 entry 로 묶어 다음 비용을 1회만 지불한다:
#   1) stdin JSON 흡수
#   2) Python resolver 부트스트랩
#   3) extract-hook-json.py 호출 (file_path 추출)
#   4) 정책 loader (.rein/policy/hooks.yaml) 1회 평가
#
# 결과는 다음 환경변수 / 파일로 sub-hook 에 전달된다:
#   REIN_HOOK_INPUT_CACHE=1                — 캐시 활성 플래그
#   REIN_HOOK_INPUT_FILE=<temp>            — 원본 JSON (env 가 아니라 파일 — 거대 payload 안전)
#   REIN_HOOK_FILE_PATH, REIN_HOOK_FILE_PATHS — 추출된 경로
#
# 출력 정책 (Task 2.6 aggregator refactor):
#   - sub-hook 들이 emit 한 JSON envelope 의 additionalContext 만 추출 → 단일
#     PostToolUse envelope 로 합쳐 dispatcher stdout 에 1회 출력. separator
#     는 `\n\n---\n\n` (마지막 entry 뒤에는 separator 없음).
#   - sub-hook stderr 는 dispatcher stderr 로 그대로 통과 (capture/silence 금지).
#   - sub-hook 이 invalid JSON 을 stdout 으로 출력하면 stderr 에 진단을 남기고
#     해당 sub-hook 의 기여분은 drop (다른 sub-hook envelope 은 정상 처리).
#
# Exit 정책 (단순 numeric max 사용 금지):
#   - 어떤 sub-hook 이라도 exit 2 면 dispatcher exit 2 (hard block 의미 보존).
#   - 그 외 nonzero (127 등) 는 stderr 진단만 남기고 dispatcher exit 0.
#   - resolver 실패 또는 extractor 실패 시 캐시를 export 하지 않아 sub-hook 들이
#     각자 fallback 경로를 타고 본래의 fail-closed/marker 동작을 유지.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
# shellcheck source=./lib/aggregator.sh
. "$SCRIPT_DIR/lib/aggregator.sh"

INPUT=$(cat 2>/dev/null || true)

# stdin 을 temp file 로 보관 — env var 대신 파일 핸들을 sub-hook 에 넘긴다.
# Write/MultiEdit payload 가 ARG_MAX 를 넘어 sub-hook exec 가 실패하는 회귀를
# 방어한다.
INPUT_FILE="$(mktemp -t rein-hook-input.XXXXXX 2>/dev/null || true)"
if [ -n "$INPUT_FILE" ]; then
  printf '%s' "$INPUT" > "$INPUT_FILE" 2>/dev/null || INPUT_FILE=""
fi
cleanup() {
  [ -n "${INPUT_FILE:-}" ] && rm -f "$INPUT_FILE" 2>/dev/null
  hook_input_clear
}
trap cleanup EXIT INT TERM

# Python resolver — silent fail (post-hook 계약).
resolve_python 2>/dev/null
PY_RC=$?

FILE_PATHS=""
FILE_PATH=""
CACHE_OK=0
EXTRACT_OK=1

if [ "$PY_RC" -eq 0 ] && [ -n "$INPUT" ]; then
  # 단일 파일 경로 (Edit/Write) — strip-newlines 로 안전 추출. pipefail 로 실패 감지.
  FILE_PATH=$(
    set -o pipefail
    printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
      "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_input.file_path --strip-newlines --default '' 2>/dev/null
  ) || EXTRACT_OK=0

  # 다중 경로 (MultiEdit + tool_result) — 순서 보존 + dedup.
  if [ "$EXTRACT_OK" -eq 1 ]; then
    FILE_PATHS=$(
      set -o pipefail
      printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
        "$SCRIPT_DIR/lib/extract-hook-json.py" \
        --field tool_input.file_path \
        --array-of tool_input.edits --subfield file_path \
        --array-of tool_result.edits --subfield file_path \
        --default '' 2>/dev/null | awk 'NF && !seen[$0]++'
    ) || EXTRACT_OK=0

    # FILE_PATHS 가 비어 있으면 tool_result.file_path 로 fallback (Codex A4 계약).
    if [ "$EXTRACT_OK" -eq 1 ] && [ -z "$FILE_PATHS" ]; then
      FILE_PATHS=$(
        set -o pipefail
        printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
          "$SCRIPT_DIR/lib/extract-hook-json.py" \
          --field tool_result.file_path --default '' 2>/dev/null \
          | awk 'NF && !seen[$0]++'
      ) || EXTRACT_OK=0
    fi
  fi

  if [ "$EXTRACT_OK" -eq 1 ]; then
    CACHE_OK=1
  fi
fi

# 정책 loader: enabled 여부를 dispatcher 가 1회 결정해 sub-hook 호출 자체를 skip.
# plugin mode (CLAUDE_PLUGIN_ROOT) 일 때만 loader 가 active — scaffold 모드는
# 기존 behavior (정책 무시) 유지.
LOADER=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
  LOADER="${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py"
fi
policy_enabled() {
  local hook_name="$1"
  [ -n "$LOADER" ] || return 0  # loader 없으면 enabled
  if [ "$PY_RC" -ne 0 ]; then
    return 0  # python 없으면 fail-open (enabled)
  fi
  "${PYTHON_RUNNER[@]}" "$LOADER" "$hook_name" >/dev/null 2>&1
}

# Sub-hook 캐시 export. INPUT_FILE 가 없으면 (mktemp 실패) 캐시 미활성화 →
# sub-hook 들이 stdin 으로 직접 파싱.
if [ "$CACHE_OK" -eq 1 ] && [ -n "$INPUT_FILE" ]; then
  export REIN_HOOK_INPUT_FILE="$INPUT_FILE"
  hook_input_export "$FILE_PATHS" "$FILE_PATH"
fi

# Sub-hook 실행 — 순서는 기존 settings.json 등록 순서를 그대로 따름.
# 각 sub-hook 이름은 정책 loader 가 인식하는 키와 동일하다.
#
# Aggregator 정책 (Task 2.6):
#   - 각 sub-hook 의 stdout 을 capture → aggregator 가 envelope concat
#   - stderr 는 capture 하지 않음 → dispatcher stderr 로 그대로 통과
#   - exit 2 가 하나라도 있으면 dispatcher exit 2 (OR-based 누적, max 아님)
aggregator_init
for sub in \
  post-edit-hygiene.sh \
  post-edit-review-gate.sh \
  post-edit-index-sync-inbox.sh \
  post-write-spec-review-gate.sh \
  post-edit-plan-coverage.sh \
  post-write-dod-routing-check.sh \
  post-write-design-plan-coverage-rule.sh
do
  SUB_PATH="$SCRIPT_DIR/$sub"
  [ -x "$SUB_PATH" ] || continue
  HOOK_KEY="${sub%.sh}"  # e.g. post-edit-hygiene
  if ! policy_enabled "$HOOK_KEY"; then
    continue  # 정책으로 비활성화된 hook 은 호출 자체를 skip
  fi
  # sub-hook 이 stdin 을 다시 읽으려 할 때 대비해 INPUT 을 흘려준다. 캐시가
  # 활성 상태면 sub-hook 은 stdin 을 읽지 않으므로 SIGPIPE 발생 가능 — printf
  # stderr 만 silence 한다 (sub-hook 결과는 정상 capture).
  #
  # stderr 는 redirect 하지 않음 (>&2 path 그대로 통과). stdout 만 capture.
  sub_stdout=$(printf '%s' "$INPUT" 2>/dev/null | "$SUB_PATH")
  rc=$?
  aggregator_add "$sub_stdout" "$rc"
done

aggregator_emit
exit "$(aggregator_exit_code)"
