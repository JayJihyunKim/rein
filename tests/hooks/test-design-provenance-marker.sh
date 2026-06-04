#!/usr/bin/env bash
# tests/hooks/test-design-provenance-marker.sh
#
# Unit test for the provenance claim helper
# `plugins/rein-core/scripts/rein-mark-design-provenance.sh` (ROUTE-BIND-1, SC-1).
# Phase 1 의 비-커밋 smoke check 를 정식 회귀 테스트로 완성한다.
#
# Verifies:
#   (a) claim 생성 — helper 호출 시 .rein/cache/.design-provenance/<hash>.touched 생성
#   (b) schema 4 필드 — path / agent / session / created 모두 존재
#   (c) path= 정확 대조 — 절대경로가 `path=<ABS>` 로 정확히 한 줄 기록 (grep -qxF)
#   (d) 멱등 재기록 — 재호출 시 마커가 갱신되고 여전히 단일 claim (presence+consume)
#   (e) 인자 누락 → exit 1 (usage 가드)
#
# 격리: REIN_PROJECT_DIR_OVERRIDE 샌드박스로 PROJECT_DIR 를 고정 → 메인테이너
# repo 의 실제 .rein/cache/ 오염 방지 (호스트 훅 regression 테스트와 동일 패턴).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HELPER="$PROJECT_DIR/plugins/rein-core/scripts/rein-mark-design-provenance.sh"

[ -f "$HELPER" ] || { echo "FAIL: $HELPER missing" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/trail"
export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

# 호스트 훅·helper 와 byte-identical hash 규약 재구성.
abs_of() { python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$1"; }
hash_of() { printf '%s' "$(abs_of "$1")" | shasum | cut -c1-16; }
marker_of() { echo "$SANDBOX/.rein/cache/.design-provenance/$(hash_of "$1").touched"; }

# (a) claim 생성
P="docs/specs/2026-01-01-a.md"
bash "$HELPER" "$P" spec-writer sess
M="$(marker_of "$P")"
[ -f "$M" ] || { echo "FAIL (a): claim marker not created at $M" >&2; exit 1; }
echo "  ok: (a) helper creates claim marker"

# (b) schema 4 필드 — path / agent / session / created
for field in path agent session created; do
  grep -qE "^${field}=" "$M" || { echo "FAIL (b): missing '${field}=' field" >&2; cat "$M" >&2; exit 1; }
done
# 정확히 4줄인지 (schema drift 방지).
LINES="$(grep -c . "$M")"
[ "$LINES" -eq 4 ] || { echo "FAIL (b): expected 4 schema lines, got $LINES" >&2; cat "$M" >&2; exit 1; }
echo "  ok: (b) schema has path/agent/session/created (4 fields)"

# (c) path= 정확 대조 — 호스트 훅이 grep -qxF 로 매칭하는 그 줄.
ABS="$(abs_of "$P")"
grep -qxF -- "path=$ABS" "$M" || { echo "FAIL (c): 'path=$ABS' not an exact line in marker" >&2; cat "$M" >&2; exit 1; }
# agent / session 값도 인자대로 기록됐는지.
grep -qxF -- "agent=spec-writer" "$M" || { echo "FAIL (c): agent field mismatch" >&2; cat "$M" >&2; exit 1; }
grep -qxF -- "session=sess" "$M" || { echo "FAIL (c): session field mismatch" >&2; cat "$M" >&2; exit 1; }
echo "  ok: (c) path= exact-line match + agent/session values"

# (d) 멱등 재기록 — 같은 경로로 다른 agent 인자로 재호출 시 마커가 갱신되고 여전히 단일.
bash "$HELPER" "$P" plan-writer sess2
[ -f "$M" ] || { echo "FAIL (d): marker disappeared after re-claim" >&2; exit 1; }
grep -qxF -- "agent=plan-writer" "$M" || { echo "FAIL (d): re-claim did not overwrite agent field" >&2; cat "$M" >&2; exit 1; }
grep -qxF -- "session=sess2" "$M" || { echo "FAIL (d): re-claim did not overwrite session field" >&2; cat "$M" >&2; exit 1; }
grep -qxF -- "path=$ABS" "$M" || { echo "FAIL (d): path= lost on re-claim" >&2; cat "$M" >&2; exit 1; }
LINES2="$(grep -c . "$M")"
[ "$LINES2" -eq 4 ] || { echo "FAIL (d): re-claim left non-4-line marker (got $LINES2)" >&2; cat "$M" >&2; exit 1; }
# 마커 디렉토리에 claim 이 1개뿐 (같은 경로는 같은 hash → 같은 파일).
COUNT="$(find "$SANDBOX/.rein/cache/.design-provenance" -type f | wc -l | tr -d ' ')"
[ "$COUNT" -eq 1 ] || { echo "FAIL (d): expected single claim file, found $COUNT" >&2; exit 1; }
echo "  ok: (d) idempotent re-claim (single marker, fields overwritten)"

# (e) 인자 누락 → exit 1 (usage 가드)
set +e
bash "$HELPER" >/dev/null 2>&1; RC_NOARG=$?
bash "$HELPER" "docs/specs/x.md" >/dev/null 2>&1; RC_ONEARG=$?
set -e
[ "$RC_NOARG" -eq 1 ] || { echo "FAIL (e): missing args should exit 1, got $RC_NOARG" >&2; exit 1; }
[ "$RC_ONEARG" -eq 1 ] || { echo "FAIL (e): missing agent should exit 1, got $RC_ONEARG" >&2; exit 1; }
echo "  ok: (e) missing required args → exit 1"

echo "test-design-provenance-marker: OK"
