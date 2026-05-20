# plugins/rein-core/hooks/lib/hook-output-cache.sh
#
# Phase 2c HK-5: sub-hook 의 PostToolUse envelope (stdout JSON) 을 cache 에
# 저장해 post-edit-aggregator 가 collect → merge → 단일 envelope 으로 emit
# 할 수 있게 한다.
#
# 왜 필요한가:
#   SPIKE-1 측정에서 같은 matcher 의 별개 entry 가 각자 stdout envelope 을
#   출력하면 Claude Code 는 entry 별 system-reminder 로 분리 surface. 즉
#   aggregator 가 다른 entry 의 stdout 을 직접 capture 할 수 없다. file-system
#   매개 cache 가 유일한 통합 경로.
#
# 캐시 계약:
#   - 키: tool_use_id (hook-resolver-cache.sh 의 resolver_cache_sanitize_id
#         재사용 — Anthropic Tool Use ID, `^toolu_[A-Za-z0-9_-]+$`)
#   - 위치: ${CLAUDE_PROJECT_DIR}/.rein/cache/hook-output/${tool_use_id}/${sub_hook_name}.json
#   - 각 sub-hook 이 자신의 PostToolUse envelope 을 write,
#     post-edit-aggregator 가 collect 후 cleanup
#
# 보안:
#   - sub_hook_name 도 sanitize (영문/숫자/하이픈/언더스코어만 — path traversal
#     방어). post-edit-* basename 만 들어오므로 whitelist 검증으로 충분.

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./hook-resolver-cache.sh
. "$SCRIPT_LIB_DIR/hook-resolver-cache.sh"

# ---------------------------------------------------------------
# output_cache_dir <tool_use_id>
#   stdout: ${CLAUDE_PROJECT_DIR}/.rein/cache/hook-output/<sanitized-id>
#   exit 1: invalid id
# ---------------------------------------------------------------
output_cache_dir() {
  local raw_id="${1:-}"
  local clean_id
  clean_id=$(resolver_cache_sanitize_id "$raw_id" 2>/dev/null) || return 1
  local base="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  printf '%s' "${base}/.rein/cache/hook-output/${clean_id}"
}

# ---------------------------------------------------------------
# output_cache_sanitize_hook_name <name>
#   허용: 영문/숫자/하이픈/언더스코어 — basename 만 (디렉토리 구분자 차단)
#   exit 1: invalid
# ---------------------------------------------------------------
output_cache_sanitize_hook_name() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  if printf '%s' "$name" | grep -qE '^[A-Za-z0-9_-]+$'; then
    printf '%s' "$name"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------
# output_cache_write <tool_use_id> <hook_name> <content>
#   exit 0: write 성공 (final file 존재)
#   exit 1: write 실패 (invalid id/name 또는 fs error — caller 가 stdout
#           fallback 결정)
#
# atomic write (mktemp + mv).
# ---------------------------------------------------------------
output_cache_write() {
  local raw_id="${1:-}"
  local raw_name="${2:-}"
  local data="${3:-}"
  local dir clean_name tmp
  dir=$(output_cache_dir "$raw_id" 2>/dev/null) || return 1
  clean_name=$(output_cache_sanitize_hook_name "$raw_name" 2>/dev/null) || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "${dir}/.${clean_name}.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$data" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv "$tmp" "${dir}/${clean_name}.json" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ---------------------------------------------------------------
# output_cache_collect <tool_use_id>
#   stdout: 각 sub-hook 의 envelope 내용을 NUL-delimited 로 stream 출력
#           (envelope 자체에 newline 이 있을 수 있어 line 기반 못 씀)
#   exit 0: 항상 (빈 dir 도 정상)
# ---------------------------------------------------------------
output_cache_collect() {
  local raw_id="${1:-}"
  local dir
  dir=$(output_cache_dir "$raw_id" 2>/dev/null) || return 0
  [ -d "$dir" ] || return 0
  local f
  # find -print0 + sort -z + NUL-read loop — CLAUDE_PROJECT_DIR 에 공백 포함 시
  # `ls | sort` 의 word-splitting 으로 path 가 망가지는 회귀 (codex R1 High)
  # 방어. LC_ALL=C 로 locale-independent 결정론적 ordering 보장.
  while IFS= read -r -d '' f; do
    [ -r "$f" ] || continue
    cat "$f" 2>/dev/null
    printf '\0'
  done < <(find "$dir" -maxdepth 1 -name '*.json' -print0 2>/dev/null | LC_ALL=C sort -z)
  return 0
}

# ---------------------------------------------------------------
# output_cache_cleanup <tool_use_id>
#   exit 0: 삭제 성공 또는 부재 (idempotent)
# ---------------------------------------------------------------
output_cache_cleanup() {
  local raw_id="${1:-}"
  local dir
  dir=$(output_cache_dir "$raw_id" 2>/dev/null) || return 0
  rm -rf "$dir" 2>/dev/null
  return 0
}
