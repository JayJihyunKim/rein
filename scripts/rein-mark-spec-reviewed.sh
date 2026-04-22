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

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
