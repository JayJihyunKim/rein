#!/bin/bash
# plugins/rein-core/scripts/rein-mark-design-provenance.sh
# 전용 에이전트(spec-writer/plan-writer)가 spec/plan 파일을 작성하기 *직전*
# 호출. 대상 경로에 대한 provenance claim 을 .rein/cache/.design-provenance/
# <hash(ABS)>.touched 로 (재)기록한다. presence+consume 모델 (SC-3): 호스트
# 훅이 매칭 시 이 claim 을 소비(삭제)한다. timestamp 비교 없음.
# Usage: rein-mark-design-provenance.sh <target_path> <spec-writer|plan-writer> [session]
set -u
TARGET="${1:-}"; AGENT="${2:-}"; SESSION="${3:-unknown}"
[ -n "$TARGET" ] && [ -n "$AGENT" ] || { echo "Usage: rein-mark-design-provenance.sh <target_path> <agent> [session]" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for _pd_lib in \
  "$SCRIPT_DIR/../hooks/lib/project-dir.sh" \
  "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/project-dir.sh" \
  "$SCRIPT_DIR/../plugins/rein-core/hooks/lib/project-dir.sh"; do
  if [ -n "$_pd_lib" ] && [ -f "$_pd_lib" ]; then . "$_pd_lib"; break; fi
done
if declare -F resolve_project_dir >/dev/null 2>&1; then
  PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
else
  PROJECT_DIR="${REIN_PROJECT_DIR_OVERRIDE:-${REIN_PROJECT_DIR:-$PWD}}"
fi

# 절대경로 정규화 — 호스트 훅(post-edit-spec-review-gate.sh:116)과 동일.
ABS=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$TARGET" 2>/dev/null)
[ -n "$ABS" ] || { echo "ERROR: [mark-design-provenance] invalid path: $TARGET" >&2; exit 1; }

# 해시 계산 (post-edit-spec-review-gate.sh:81-93 와 byte-identical).
compute_hash() {
  local input="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum | cut -c1-16
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha1sum | cut -c1-16
  else
    # fallback: path 끝 12자 + length 접미
    local tail="${input: -12}"
    local len="${#input}"
    printf '%s%d' "$(echo "$tail" | tr -cd 'a-zA-Z0-9')" "$len" | cut -c1-16
  fi
}
HASH=$(compute_hash "$ABS")
PROV_DIR="$PROJECT_DIR/.rein/cache/.design-provenance"
MARKER="$PROV_DIR/${HASH}.touched"

# claim 디렉토리 사전 생성 (spec §4 Implementation caution).
mkdir -p "$PROV_DIR" 2>/dev/null || true

# 멱등 재기록 — 매 authored write 직전 호출되므로 매번 덮어쓴다 (SC-2/§4.3).
{
  echo "path=$ABS"
  echo "agent=$AGENT"
  echo "session=$SESSION"
  echo "created=$(date -u +%Y-%m-%dT%H:%M:%S)"
} > "$MARKER" 2>/dev/null || true   # 비차단: claim 실패해도 에이전트 진행을 막지 않음

exit 0
