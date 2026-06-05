#!/usr/bin/env bash
# test-routing-map-projection.sh — RD-11 (ROUTE-DOC-1)
# routing-map.md 가 routing-procedure.md §5 의 충실한 projection 임을 가드:
#   (a) map 작업유형 라벨 ⊆ procedure §5 작업유형 라벨 (map-only 0건)
#   (b) routing-map.md 바이트 ≤ 상한 (800B 토큰 예산 회귀 방지)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAP="$ROOT/plugins/rein-core/rules/routing-map.md"
PROC="$ROOT/plugins/rein-core/rules/routing-procedure.md"
MAX_BYTES=900

[ -f "$MAP" ]  || { echo "FAIL: routing-map.md 부재"; exit 1; }
[ -f "$PROC" ] || { echo "FAIL: routing-procedure.md 부재"; exit 1; }

# (b) byte 상한
bytes=$(wc -c < "$MAP")
if [ "$bytes" -gt "$MAX_BYTES" ]; then
  echo "FAIL[bytes]: routing-map.md ${bytes}B > 상한 ${MAX_BYTES}B (800B 토큰 예산 회귀)"
  exit 1
fi

# 표 1열(작업 유형) 추출 helper. $2=헤더 식별 정규식(첫 데이터 표를 고름).
# table 헤더행을 만나면 캡처 시작 → 비-파이프 줄에서 종료. separator(---) / 헤더셀 제외.
extract_types() {
  awk -v hdr="$2" '
    $0 ~ /^\|/ && $0 ~ hdr { intbl=1; next }
    intbl && $0 !~ /^\|/ { intbl=0 }
    intbl {
      cell=$2
      gsub(/^[ \t`]+/, "", cell); gsub(/[ \t`]+$/, "", cell)
      if (cell == "" || cell == "작업 유형") next
      if (cell ~ /^[-: ]+$/) next
      print cell
    }
  ' FS='|' "$1"
}

# (a) 작업유형 라벨 subset — map ⊆ procedure §5
map_types=$(extract_types "$MAP" "추천 agent")
proc_types=$(extract_types "$PROC" "에이전트.*스킬")

# (a-0) 추출 성공 가드 — 표 헤더 rename / 구조 변경으로 파서가 0건을 뽑으면
# subset 검사가 공허하게 참(false PASS)이 된다. 양쪽 모두 non-empty + map 은
# 알려진 최소 행수를 단언해 vacuous-pass 를 차단한다.
MAP_MIN_ROWS=8   # 현행 projection 행수 (floor). 의도적 축소 시 이 값을 같이 갱신.
map_count=$(printf '%s\n' "$map_types" | grep -c . || true)
proc_count=$(printf '%s\n' "$proc_types" | grep -c . || true)
if [ "$proc_count" -lt 1 ]; then
  echo "FAIL[parse]: procedure §5 작업유형 추출 0건 — routing-procedure.md 표 헤더/구조 변경 또는 파서 깨짐"
  exit 1
fi
if [ "$map_count" -lt "$MAP_MIN_ROWS" ]; then
  echo "FAIL[parse]: map 작업유형 추출 ${map_count}건 < 최소 ${MAP_MIN_ROWS}건 — routing-map.md 표 헤더/구조 변경 또는 파서 깨짐"
  exit 1
fi

missing=""
while IFS= read -r t; do
  [ -z "$t" ] && continue
  if ! printf '%s\n' "$proc_types" | grep -qxF "$t"; then
    missing="${missing}${t}\n"
  fi
done <<< "$map_types"

if [ -n "$missing" ]; then
  echo "FAIL[subset]: map-only 작업유형 (procedure §5 에 부재):"
  printf '%b' "$missing"
  exit 1
fi

echo "PASS: tests/scripts/test-routing-map-projection.sh (map ${map_count}행 ⊆ procedure §5 ${proc_count}행 + ${bytes}B ≤ ${MAX_BYTES}B)"
