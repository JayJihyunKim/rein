#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit)
# trail/dod/dod-*.md 작성 시 '## 라우팅 추천' 섹션 존재 검사.
# 누락 시 `.routing-missing-<basename>` 마커 생성 → pre-edit-dod-gate.sh 가 차단.
# 섹션이 있으면 해당 마커 제거 (자가 치유).
#
# 이 hook 은 DoD 가 작성된 후에만 동작하므로 legacy DoD 는 자연스럽게 grandfather 된다.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"

# REIN_PROJECT_DIR_OVERRIDE: test sandbox 가 hook 을 격리 환경에서 호출할 때 사용.
# 기본은 script 위치 기반 (실제 운영 동작 보존).
PROJECT_DIR="${REIN_PROJECT_DIR_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DOD_DIR="$PROJECT_DIR/trail/dod"

INPUT=$(cat)

# Python resolver (soft fail-closed for post-hook):
# resolver 실패 시에도 routing-gate 의 신뢰성을 지키기 위해 보수적 marker 를
# 생성한다. 다음 pre-edit-dod-gate 가 이 marker 를 감지해 routing-missing
# BLOCK 을 걸면서 Python 진단을 함께 노출한다. post-hook 자체는 exit 0
# (silent) — 사용자의 현재 write 를 되돌리지 않는다.
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  mkdir -p "$DOD_DIR" 2>/dev/null
  : > "$DOD_DIR/.routing-missing-unknown-python-runtime" 2>/dev/null
  exit 0
fi
# resolver 성공 경로에 도달하면 이전 write 시 남긴 python-runtime fallback marker 를 자동 해소.
rm -f "$DOD_DIR/.routing-missing-unknown-python-runtime" 2>/dev/null || true

FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

case "$FILE_PATH" in
  */trail/dod/dod-[0-9]*.md)
    ;;
  *)
    exit 0
    ;;
esac

[ -f "$FILE_PATH" ] || exit 0

FNAME=$(basename "$FILE_PATH")
# basename 화이트리스트: dod-YYYY-MM-DD-<kebab-slug>.md 만 허용 (F2/F4 방어).
# 통과하지 못하면 무시 (신뢰하지 않는 입력).
case "$FNAME" in
  dod-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md) ;;
  *) exit 0 ;;
esac
if [[ ! "$FNAME" =~ ^dod-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9._-]*\.md$ ]]; then
  exit 0
fi
MARKER="$DOD_DIR/.routing-missing-${FNAME%.md}"

if grep -q '^## 라우팅 추천' "$FILE_PATH" 2>/dev/null; then
  rm -f "$MARKER"
else
  mkdir -p "$DOD_DIR"
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  echo "WARNING: $FNAME 에 '## 라우팅 추천' 섹션이 없습니다. 다음 소스 편집이 차단됩니다." >&2
  echo "  orchestrator.md 의 '스마트 라우팅 절차' 를 따라 섹션을 추가하세요." >&2
fi

# Auto-write `.active-dod` when routing approval is final.
# Mirror pre-edit-dod-gate.sh L407-416 contract:
#   - extract `## 라우팅 추천` section only (first occurrence; awk in_sec)
#   - match `^[[:space:]]*approved_by_user:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$`
#     (inline `#` comment allowed; section-outer key rejected)
# Atomic via mktemp + mv. Idempotent — same target path overwrites without diff.
SECTION=$(awk '
  /^## 라우팅 추천/ {if (!seen) {in_sec=1; seen=1}; next}
  in_sec && /^## / {in_sec=0}
  in_sec {print}
' "$FILE_PATH" 2>/dev/null)
if printf '%s\n' "$SECTION" | grep -qE '^[[:space:]]*approved_by_user:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$'; then
  REPO_REL_PATH="${FILE_PATH#$PROJECT_DIR/}"
  ACTIVE_MARKER="$DOD_DIR/.active-dod"
  TMP_MARKER=$(mktemp "$DOD_DIR/.active-dod.tmp.XXXXXX") || exit 0
  printf 'path=%s\n' "$REPO_REL_PATH" > "$TMP_MARKER"
  mv "$TMP_MARKER" "$ACTIVE_MARKER" 2>/dev/null || rm -f "$TMP_MARKER"
fi

exit 0
