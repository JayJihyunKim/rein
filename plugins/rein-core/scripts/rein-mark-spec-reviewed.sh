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
# spec-review gate (post-edit-spec-review-gate.sh / pre-edit-dod-gate.sh) 와
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
# PD-1 (2026-05-19): loud fail when PROJECT_DIR did not resolve to a real rein
# project root. Previously a mis-resolved PROJECT_DIR (e.g. the repo's parent)
# would still get a stamp written under it + exit 0, silently hiding the
# failure — the spec-review gate then never sees the stamp and keeps blocking.
if [ ! -d "$PROJECT_DIR/trail" ]; then
  echo "ERROR: [mark-spec-reviewed] resolved PROJECT_DIR has no trail/ directory: $PROJECT_DIR" >&2
  echo "ERROR: [mark-spec-reviewed] this is not a rein project root — refusing to write a stamp the review gate cannot see." >&2
  echo "ERROR: [mark-spec-reviewed] set REIN_PROJECT_DIR_OVERRIDE or run from the project root." >&2
  exit 1
fi

SPEC_REVIEWS_DIR="$PROJECT_DIR/trail/dod/.spec-reviews"

# 절대경로 정규화
ABS_SPEC=$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$SPEC_PATH" 2>/dev/null)
[ -z "$ABS_SPEC" ] && { echo "ERROR: invalid spec path: $SPEC_PATH" >&2; exit 1; }

# 해시 계산 (post-edit-spec-review-gate.sh와 동일)
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

# .reviewed 생성 — temp file + atomic rename. PD-1 (codex review 2026-05-19):
# 직접 `> "$REVIEWED_MARKER"` 는 기존 marker 가 있고 write 가 실패하면 (디렉토리/
# 파일 read-only 등) set -e 부재로 그대로 진행했고, 뒤이은 `[ -f ]` 검사는 stale
# marker 때문에 통과해 "OK" + exit 0 으로 실패를 은폐했다. temp 에 먼저 쓰고
# write 명령의 종료 상태를 직접 검사한 뒤 atomic rename 한다. 디렉토리가 쓰기
# 가능한 한 (= temp 생성 성공) 모든 실패 경로는 fail-closed — 기존 stale
# `.reviewed` 도 함께 제거해, 실패 후 "리뷰됨" 으로 오인될 marker 를 남기지
# 않는다 (gate 는 .reviewed 존재만 본다).
REVIEWED_TMP="$(mktemp "${SPEC_REVIEWS_DIR}/.${HASH}.reviewed.XXXXXX" 2>/dev/null)" || {
  echo "ERROR: [mark-spec-reviewed] cannot create a temp file in $SPEC_REVIEWS_DIR — directory not writable?" >&2
  exit 1
}
if ! {
  echo "path=$ABS_SPEC"
  echo "reviewer=$REVIEWER"
  echo "reviewed=$(date -u +%Y-%m-%dT%H:%M:%S)"
} > "$REVIEWED_TMP"; then
  echo "ERROR: [mark-spec-reviewed] failed to write the .reviewed marker (temp write failed)" >&2
  rm -f "$REVIEWED_TMP" "$REVIEWED_MARKER"
  exit 1
fi
if [ ! -s "$REVIEWED_TMP" ]; then
  echo "ERROR: [mark-spec-reviewed] the .reviewed marker came out empty — refusing to install it" >&2
  rm -f "$REVIEWED_TMP" "$REVIEWED_MARKER"
  exit 1
fi
if ! mv -f "$REVIEWED_TMP" "$REVIEWED_MARKER"; then
  echo "ERROR: [mark-spec-reviewed] failed to install the .reviewed marker at $REVIEWED_MARKER" >&2
  rm -f "$REVIEWED_TMP" "$REVIEWED_MARKER"
  exit 1
fi

# .pending 삭제 — .reviewed 가 확실히 자리잡은 뒤에만 (write 실패 시 pending 보존).
[ -f "$PENDING_MARKER" ] && rm -f "$PENDING_MARKER"

echo "OK: spec reviewed — $ABS_SPEC (reviewer: $REVIEWER)" >&2
exit 0
