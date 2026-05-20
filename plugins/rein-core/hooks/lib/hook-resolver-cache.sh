# plugins/rein-core/hooks/lib/hook-resolver-cache.sh
#
# PERF-2: PreToolUse 의 Python resolver 결과를 PostToolUse 분할 sub-hook 들이
# 재사용할 수 있도록 tool_use_id 키로 file-system cache 공유.
#
# 캐시 계약:
#   - 키: tool_use_id (Anthropic Tool Use ID, `^toolu_[A-Za-z0-9_-]+$`)
#   - 위치: ${CLAUDE_PROJECT_DIR}/.rein/cache/hook-resolver/${tool_use_id}.json
#   - PreToolUse (pre-edit-dod-gate) 가 write, PostToolUse sub-hook 들이 read,
#     post-edit-aggregator (HK-5) 가 cleanup
#
# 보안:
#   - tool_use_id 가 사용자 영역 입력에서 유래 → 그대로 파일명에 쓰면 path
#     traversal 위험 (`../etc/passwd` 같은 페이로드)
#   - resolver_cache_sanitize_id 가 whitelist 검증, invalid 시 즉시 fail
#   - cache miss 는 정상 흐름 — sub-hook 은 자체 resolver 로 fallback
#
# 호출 패턴 (writer, pre-edit-dod-gate):
#   . "$SCRIPT_DIR/lib/hook-resolver-cache.sh"
#   resolver_cache_write "$tool_use_id" "$resolver_json" || true
#
# 호출 패턴 (reader, post-edit-* sub-hook):
#   . "$SCRIPT_DIR/lib/hook-resolver-cache.sh"
#   if resolver_data=$(resolver_cache_read "$tool_use_id" 2>/dev/null); then
#     # cache hit — resolver_data 사용
#   else
#     # cache miss — 자체 resolver fallback
#   fi
#
# 호출 패턴 (cleanup, post-edit-aggregator):
#   . "$SCRIPT_DIR/lib/hook-resolver-cache.sh"
#   resolver_cache_cleanup "$tool_use_id" || true

# ---------------------------------------------------------------
# resolver_cache_dir
#   project 단위 cache directory 절대경로. mkdir 시도 후 echo.
#   CLAUDE_PROJECT_DIR 부재 시 pwd fallback.
# ---------------------------------------------------------------
resolver_cache_dir() {
  local base="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  printf '%s' "${base}/.rein/cache/hook-resolver"
}

# ---------------------------------------------------------------
# resolver_cache_sanitize_id <id>
#   stdout: sanitized id (Anthropic Tool Use ID 형식)
#   exit 0: 통과, exit 1: invalid (caller 가 cache 미사용 결정)
#
# 허용 패턴: `^toolu_[A-Za-z0-9_-]+$` — 빈 문자열 / `.` / `/` / `..` 등은 reject.
# ---------------------------------------------------------------
resolver_cache_sanitize_id() {
  local id="${1:-}"
  case "$id" in
    toolu_*)
      ;;
    *)
      return 1
      ;;
  esac
  if printf '%s' "$id" | grep -qE '^toolu_[A-Za-z0-9_-]+$'; then
    printf '%s' "$id"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------
# resolver_cache_write <tool_use_id> <data>
#   exit 0: write 성공 (또는 invalid id 로 silent skip — caller fail-soft)
#
# pre-edit-dod-gate 가 호출. resolver 결과 JSON 을 file 에 dump.
# atomic write 위해 mktemp + mv 사용.
# ---------------------------------------------------------------
resolver_cache_write() {
  local raw_id="${1:-}"
  local data="${2:-}"
  local clean_id
  clean_id=$(resolver_cache_sanitize_id "$raw_id" 2>/dev/null) || return 0
  local dir
  dir=$(resolver_cache_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  local tmp
  tmp=$(mktemp "${dir}/.${clean_id}.XXXXXX" 2>/dev/null) || return 0
  printf '%s' "$data" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv "$tmp" "${dir}/${clean_id}.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------
# resolver_cache_read <tool_use_id>
#   stdout: cache 내용
#   exit 0: hit, exit 1: miss 또는 invalid id (caller 가 fallback)
# ---------------------------------------------------------------
resolver_cache_read() {
  local raw_id="${1:-}"
  local clean_id
  clean_id=$(resolver_cache_sanitize_id "$raw_id" 2>/dev/null) || return 1
  local dir
  dir=$(resolver_cache_dir)
  local path="${dir}/${clean_id}.json"
  [ -r "$path" ] || return 1
  cat "$path" 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------
# resolver_cache_cleanup <tool_use_id>
#   exit 0: 삭제 성공 또는 부재 (idempotent)
#
# post-edit-aggregator 가 호출. 동일 cache key 의 output dir 도 함께 정리.
# ---------------------------------------------------------------
resolver_cache_cleanup() {
  local raw_id="${1:-}"
  local clean_id
  clean_id=$(resolver_cache_sanitize_id "$raw_id" 2>/dev/null) || return 0
  local dir
  dir=$(resolver_cache_dir)
  rm -f "${dir}/${clean_id}.json" 2>/dev/null
  # 동반: hook-output dir 의 동일 tool_use_id sub-dir
  local out_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}/.rein/cache/hook-output/${clean_id}"
  rm -rf "$out_dir" 2>/dev/null
  return 0
}
