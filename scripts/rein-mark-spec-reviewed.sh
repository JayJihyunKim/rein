#!/bin/bash
# scripts/rein-mark-spec-reviewed.sh
# Mark a specification document as reviewed
# Usage: bash scripts/rein-mark-spec-reviewed.sh <spec_path> <reviewer>

set -u

SPEC_PATH="${1:-}"
REVIEWER="${2:-}"

if [ -z "$SPEC_PATH" ] || [ -z "$REVIEWER" ]; then
  echo "Usage: bash scripts/rein-mark-spec-reviewed.sh <spec_path> <reviewer>" >&2
  exit 1
fi

# PROJECT_DIR 은 trail/dod/.spec-reviews/ 를 소유한 rein 프로젝트 루트여야 하며,
# spec-review gate (post-write-spec-review-gate.sh / pre-edit-dod-gate.sh) 와
# 반드시 동일하게 해소되어야 한다 — gate 는 resolve_project_dir 를 쓴다.
# 예전 `$0/..` 는 이 스크립트가 프로젝트 로컬 scripts/ 에 있다고 가정했으나,
# plugin 설치 시 `$0/..` 는 plugin 캐시 디렉토리라 .reviewed stamp 가 gate 가
# 읽지 않는 곳에 생성됐다 (writer/reader 경로 불일치 버그).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for _pd_lib in \
  "$SCRIPT_DIR/../hooks/lib/project-dir.sh" \
  "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/project-dir.sh" \
  "$SCRIPT_DIR/../plugins/rein-core/hooks/lib/project-dir.sh"; do
  if [ -n "$_pd_lib" ] && [ -f "$_pd_lib" ]; then
    # shellcheck source=/dev/null
    . "$_pd_lib"
    break
  fi
done
if declare -F resolve_project_dir >/dev/null 2>&1; then
  PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
else
  # Conservative fallback — lib 미발견. resolve_project_dir 의 env-override +
  # git-root-from-cwd 순서를 그대로 모사해, 정상(plugin) 모드에서 gate 와 동일
  # 결과를 낸다.
  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    PROJECT_DIR="$REIN_PROJECT_DIR_OVERRIDE"
  elif [ -n "${REIN_PROJECT_DIR:-}" ]; then
    PROJECT_DIR="$REIN_PROJECT_DIR"
  else
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || PROJECT_DIR=""
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"
  fi
fi
SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"

# 절대경로 정규화
ABS_SPEC=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$SPEC_PATH" 2>/dev/null)
[ -z "$ABS_SPEC" ] && { echo "ERROR: invalid spec path: $SPEC_PATH" >&2; exit 1; }

# 해시 계산 (post-write-spec-review-gate.sh와 동일)
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

mkdir -p "$SPEC_REVIEWS_DIR"
HASH=$(compute_hash "$ABS_SPEC")
PENDING_MARKER="$SPEC_REVIEWS_DIR/${HASH}.pending"
REVIEWED_MARKER="$SPEC_REVIEWS_DIR/${HASH}.reviewed"

# .pending 삭제
[ -f "$PENDING_MARKER" ] && rm -f "$PENDING_MARKER"

# .reviewed 생성
{
  echo "path=$ABS_SPEC"
  echo "reviewer=$REVIEWER"
  echo "reviewed=$(date -u +%Y-%m-%dT%H:%M:%S)"
} > "$REVIEWED_MARKER"

echo "OK: spec reviewed — $ABS_SPEC (reviewer: $REVIEWER)" >&2
exit 0
