#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit)
# trail/dod/dod-*.md 작성 시 '## 라우팅 추천' 섹션 존재 검사.
# 누락 시 `.routing-missing-<basename>` 마커 생성 → pre-edit-dod-gate.sh 가 차단.
# 섹션이 있으면 해당 마커 제거 (자가 치유).
#
# 이 hook 은 DoD 가 작성된 후에만 동작하므로 legacy DoD 는 자연스럽게 grandfather 된다.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOD_DIR="$PROJECT_DIR/trail/dod"

INPUT=$(cat)

# python3 부재: routing-gate 의 신뢰성을 지키기 위해 fail-closed.
# 보수적 마커를 생성해 다음 pre-edit 에서 소스 편집이 막히도록 한다.
# (inspection 불가 → '미검증' 상태로 처리)
if ! command -v python3 >/dev/null 2>&1; then
  mkdir -p "$DOD_DIR"
  touch "$DOD_DIR/.routing-missing-unknown-python3-absent"
  echo "WARNING: python3 부재 — routing check skipped. 다음 소스 편집은 차단됩니다." >&2
  echo "  복구: python3 설치 후 DoD 를 재저장하면 자가 치유." >&2
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)
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

exit 0
