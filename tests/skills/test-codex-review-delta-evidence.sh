#!/usr/bin/env bash
# tests/skills/test-codex-review-delta-evidence.sh
# spec docs/specs/2026-10-07-review-delta-evidence-and-defaults.md §3.9.1 (3)
# Scope IDs covered: RDE-SKILL-AXIS, RDE-SKILL-DELTA, RDE-SKILL-COMPOSE, RDE-WRAP-COMPOSE, RDE-WRAP-DELTA, RDE-SEC-FLOOR
set -u
export LC_ALL=C   # GNU grep 3.7 + UTF-8 로케일의 한글 줄 매칭 결함 회피 (바이트 비교)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ROOT/plugins/rein-core/skills/codex-review/SKILL.md"
WP="$ROOT/plugins/rein-core/scripts/rein-codex-review.sh"
WR="$ROOT/scripts/rein-codex-review.sh"
SR="$ROOT/plugins/rein-core/agents/security-reviewer.md"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
has() { if grep -qF -- "$2" "$1"; then _pass "$(basename "$1"): '$2'"; else _fail "$(basename "$1"): missing '$2'"; fi; }
pos() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
lt()  { if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then _pass "$1"; else _fail "$1 (got '$2' < '$3')"; fi; }

echo "## test-codex-review-delta-evidence.sh"

echo "-- SKILL.md: 자가검증 두 축 계약"
X=$(pos "$S" '### 자가검증 증거 — 두 축 계약')
lt "'### 요청서 작성 규약' < 두 축 소절" "$(pos "$S" '### 요청서 작성 규약')" "$X"
lt "두 축 소절 < '### 후속 회차 요청서 양식'" "$X" "$(pos "$S" '### 후속 회차 요청서 양식')"
for s in '[axis:typecheck]' 'diff_self_review:' 'verification_commands: none' 'tests-intentionally-red' 'expected_failure:'; do
  has "$S" "$s"
done
N=$(grep -c 'axis:test' "$S")
if [ "$N" -ge 2 ]; then _pass "SKILL.md: 'axis:test' ${N}줄 (>= 2)"; else _fail "SKILL.md: 'axis:test' ${N}줄 (< 2)"; fi

echo "-- SKILL.md: 델타 증거"
for s in '**델타 증거 — 후속 회차의 테스트 증거**' 'git stash create' 'git rev-parse HEAD' 'git diff --name-status' \
         'git cat-file -e' 'delta_evidence:' 'full_run_tree:' 'untracked_scope:' 'untracked_at_full_run:' \
         '<경로> <sha256> <줄 수>' 'added|modified|deleted' '추적 전환 규칙' 'delta_lines:' 'delta_source_files:' \
         'targeted_tests:' 'external_inputs: unchanged' '`exit_code: 0` 이어야 한다' \
         '**전체 테스트 재실행으로 돌아가는 조건**' 'conftest.py' 'tests/fixtures/**' '**전체 스위트 실행 횟수**'; do
  has "$S" "$s"
done
lt "델타 블록 < '**전체 검토로 복귀하는 조건**'" "$(pos "$S" '**델타 증거 — 후속 회차의 테스트 증거**')" "$(pos "$S" '**전체 검토로 복귀하는 조건**')"

echo "-- SKILL.md: 수치 구성 + §4.1 링크"
has "$S" '<합계> = <항목1 값>(<출처>)'
L=$(awk '/^### 4\.1 /{f=1; next} /^### 4\.2 /{f=0} f' "$S" | grep -cF '두 축 계약')
if [ "$L" -ge 1 ]; then _pass "§4.1 ~ §4.2 사이 '두 축 계약' 링크 줄"; else _fail "§4.1 ~ §4.2 사이 '두 축 계약' 링크 줄 없음"; fi

echo "-- 래퍼 두 사본: Claim Audit sub-item 6 (c) · sub-item 8"
for W in "$WP" "$WR"; do
  tag="${W#$ROOT/}"
  BLK=$(awk '/^4\. Claim Audit /,/^응답 출력 형식/' "$W")
  for s in '8. Delta evidence' '대상 테스트 매핑 불명확 — 전체 실행 후 재요청' '델타 증거 불완전 — 전체 실행 후 재요청' \
           'external_inputs' 'git cat-file -e <full_run_tree>' 'untracked_at_full_run' 'untracked_scope' \
           '<경로> <sha256> <줄 수>' 'added(지금 줄 수)' 'modified(스냅샷·지금 중 큰 줄 수)' 'deleted(스냅샷 줄 수)' \
           '추적 전환 규칙' '합계 재계산' 'numstat 합 + ?? 줄 수 = delta_lines' \
           '--name-status 소스 + ?? 소스 = delta_source_files' 'git ls-files' '(c) 구성 단서'; do
    if printf '%s\n' "$BLK" | grep -qF -- "$s"; then _pass "$tag Claim Audit: '$s'"; else _fail "$tag Claim Audit: missing '$s'"; fi
  done
  # sub-item 8 은 조건 블록 밖(함수 최상위)에서 항상 방출된다.
  N8=$(grep -n '^   8\. Delta evidence$' "$W" | head -1 | cut -d: -f1)
  if [ -z "$N8" ]; then
    _fail "$tag: '   8. Delta evidence' 줄 없음"
  else
    CL=$(head -n "$N8" "$W" | grep -n "cat <<'SLOTS'" | tail -1 | cut -d: -f1)
    CAT_LINE=$(sed -n "${CL}p" "$W")
    PREV=$(head -n $((CL - 1)) "$W" | grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$' | tail -1)
    if [ "$CAT_LINE" = "  cat <<'SLOTS'" ]; then _pass "$tag: sub-item 8 heredoc 이 2칸 들여쓰기(함수 최상위)"
    else _fail "$tag: sub-item 8 heredoc 시작 줄 '$CAT_LINE' (기대 2칸 cat <<'SLOTS')"; fi
    if [ "$PREV" = "  fi" ]; then _pass "$tag: sub-item 8 heredoc 직전 코드 줄 = '  fi' (sub-item 7 블록 종료)"
    else _fail "$tag: sub-item 8 heredoc 직전 코드 줄 '$PREV' (기대 '  fi')"; fi
  fi
done
if cmp -s "$WP" "$WR"; then _pass "래퍼 두 사본 바이트 동일"; else _fail "래퍼 두 사본이 다름"; fi

echo "-- 숫자·공식 동기화 (SKILL.md · 래퍼 두 사본)"
for s in '5개 초과' '200줄 초과' 'added(지금 줄 수)' 'modified(스냅샷·지금 중 큰 줄 수)' 'deleted(스냅샷 줄 수)' \
         'numstat 합 + ?? 줄 수 = delta_lines' '--name-status 소스 + ?? 소스 = delta_source_files' \
         '델타 증거 불완전 — 전체 실행 후 재요청'; do
  for F in "$S" "$WP" "$WR"; do has "$F" "$s"; done
done

echo "-- security-reviewer.md: 등급 하한 + 처리 순서"
for s in '등급 하한 — 재현 가능한 데이터 무결성 결함' 'TOCTOU' '원자성 결여' '최소 Medium' \
         '코드 검토 요청 전에 반영' '후속 작업으로 넘기지 않는다' '데이터 무결성 결함의 등급 하한은 §4'; do
  has "$SR" "$s"
done

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
