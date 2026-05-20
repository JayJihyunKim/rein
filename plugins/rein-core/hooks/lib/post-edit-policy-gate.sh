# plugins/rein-core/hooks/lib/post-edit-policy-gate.sh
#
# HK-4 분할 후 dispatcher 가 처리하던 `rein-policy-loader.py` enabled 평가를
# 각 sub-hook 자체에서 호출하기 위한 helper.
#
# 호출 패턴 (sub-hook head 에서):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib/post-edit-policy-gate.sh"
#   post_edit_policy_gate "post-edit-hygiene"  # hook_name = filename without .sh
#
# 의미:
#   - loader 부재 → return 0 (fail-open, enabled)
#   - python3 부재 → return 0 (fail-open)
#   - loader 가 enabled 반환 → return 0 (계속 진행)
#   - loader 가 disabled 반환 → `exit 0` (sub-hook main body skip)

post_edit_policy_gate() {
  local hook_name="${1:-}"
  if [ -z "$hook_name" ]; then
    return 0
  fi
  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || [ ! -f "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" ]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  if python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-policy-loader.py" "$hook_name" >/dev/null 2>&1; then
    return 0
  fi
  exit 0
}
