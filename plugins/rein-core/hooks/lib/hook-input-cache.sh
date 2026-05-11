# .claude/hooks/lib/hook-input-cache.sh
#
# 캐시된 hook input + file path 를 공유하기 위한 helper.
#
# post-edit-dispatcher.sh 가 stdin JSON 을 한 번만 읽고 path 를 1회만 추출한 뒤,
# 아래 환경변수를 통해 각 sub-hook 에 전달한다. sub-hook 들은 캐시가 있으면
# 자체 JSON 파싱을 건너뛰고, 없으면 기존 stdin 파싱 경로로 fallback 한다 (직접
# 호출 / 테스트 호환).
#
# 캐시 계약:
#   REIN_HOOK_INPUT_CACHE=1            — 캐시 활성 플래그
#   REIN_HOOK_INPUT_FILE               — 원본 JSON 이 저장된 temp 파일 경로.
#                                        env var 에 raw JSON 을 넣지 않아 ARG_MAX
#                                        한계를 회피한다. dispatcher 가 temp 파일
#                                        생성에 실패하면 CACHE_OK=0 으로 사용되어
#                                        sub-hook 들이 직접 stdin 을 읽는다.
#   REIN_HOOK_FILE_PATHS               — 중복 제거된 file_path 목록 (LF 구분)
#   REIN_HOOK_FILE_PATH                — 첫 path (Edit/Write 단일 파일 경로 호환)
#
# Sub-hook 사용 패턴:
#   . "$SCRIPT_DIR/lib/hook-input-cache.sh"
#   hook_input_load           # INPUT, FILE_PATHS, FILE_PATH 가 자동 채워짐
#   # 이후 기존 로직 그대로 사용
#
# 캐시가 없으면 hook_input_load 는 stdin 을 직접 읽어 INPUT 만 채우고
# FILE_PATHS/FILE_PATH 는 빈 상태로 둔다. 호출자는 기존 파서 (extract-hook-json
# + awk) 로 채우면 된다.

# ---------------------------------------------------------------
# hook_input_load
#   INPUT, FILE_PATHS, FILE_PATH 변수를 채운다.
#   캐시 활성 시: 환경변수에서 복원.
#   캐시 없음:    stdin 을 INPUT 으로 흡수만 함.
# ---------------------------------------------------------------
hook_input_load() {
  if [ "${REIN_HOOK_INPUT_CACHE:-0}" = "1" ]; then
    # INPUT 은 temp 파일에서 읽는다 (env var 에 raw JSON 을 넣지 않는다).
    if [ -n "${REIN_HOOK_INPUT_FILE:-}" ] && [ -r "${REIN_HOOK_INPUT_FILE}" ]; then
      INPUT=$(cat "${REIN_HOOK_INPUT_FILE}" 2>/dev/null || true)
    else
      INPUT=""
    fi
    FILE_PATHS="${REIN_HOOK_FILE_PATHS:-}"
    FILE_PATH="${REIN_HOOK_FILE_PATH:-}"
    return 0
  fi
  INPUT=$(cat 2>/dev/null || true)
  FILE_PATHS=""
  FILE_PATH=""
  return 0
}

# ---------------------------------------------------------------
# hook_input_export FILE_PATHS FILE_PATH
#   dispatcher 가 sub-hook 호출 전에 캐시 플래그 + 파일 경로만 export.
#   FILE_PATHS 는 LF 구분 문자열 (단일 또는 다중).
#   raw JSON 은 별도로 REIN_HOOK_INPUT_FILE 로 dispatcher 가 export 한다.
# ---------------------------------------------------------------
hook_input_export() {
  export REIN_HOOK_INPUT_CACHE=1
  export REIN_HOOK_FILE_PATHS="${1:-}"
  export REIN_HOOK_FILE_PATH="${2:-}"
}

# ---------------------------------------------------------------
# hook_input_clear
#   dispatcher 가 모든 sub-hook 호출 종료 후 캐시 해제.
#   동일 프로세스에서 다음 PostToolUse 가 재호출돼도 stale cache 가
#   영향을 주지 않도록 한다.
# ---------------------------------------------------------------
hook_input_clear() {
  unset REIN_HOOK_INPUT_CACHE
  unset REIN_HOOK_INPUT_FILE
  unset REIN_HOOK_FILE_PATHS
  unset REIN_HOOK_FILE_PATH
}
