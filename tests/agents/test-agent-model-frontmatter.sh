#!/usr/bin/env bash
# tests/agents/test-agent-model-frontmatter.sh
# spec docs/specs/2026-10-07-review-delta-evidence-and-defaults.md §3.9.1 (1)
# Scope IDs covered: RDE-MODEL-FM (T1~T4), RDE-MODEL-RULE (T5)
# bash 3.2 호환(연관 배열 없음) — macOS CI 대비.
set -u
export LC_ALL=C   # GNU grep 3.7 + UTF-8 로케일의 한글 줄 매칭 결함 회피 (바이트 비교)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AG="$ROOT/plugins/rein-core/agents"
OF="$ROOT/plugins/rein-core/rules/orchestrator-first.md"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

want_of() {
  case "$1" in
    spec-writer|plan-writer|researcher|security-reviewer|orchestrator) echo opus ;;
    feature-builder|feature-builder-fix|feature-builder-refactor|feature-builder-worker|docs-writer) echo sonnet ;;
    *) echo "" ;;
  esac
}
# frontmatter = 1번째 줄 '---' 다음부터 다음 '---' 앞까지
fm() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$1"; }

echo "## test-agent-model-frontmatter.sh"

echo "-- T1~T3: 에이전트별 frontmatter"
for f in "$AG"/*.md; do
  n=$(basename "$f" .md)
  cnt=$(fm "$f" | grep -c '^model:')
  if [ "$cnt" = "1" ]; then _pass "T1 $n: model: 1줄"; else _fail "T1 $n: frontmatter model: 줄 수 $cnt (기대 1)"; fi
  val=$(fm "$f" | sed -n 's/^model:[[:space:]]*//p' | head -1)
  want=$(want_of "$n")
  if [ -z "$want" ]; then
    case "$val" in
      opus|sonnet) _pass "T2 $n: 매핑 밖 에이전트, 값 $val 은 허용 집합" ;;
      *) _fail "T2 $n: model '$val' 이 {opus, sonnet} 밖" ;;
    esac
  elif [ "$val" = "$want" ]; then _pass "T2 $n: model=$val"
  else _fail "T2 $n: model='$val' (기대 $want)"; fi
  order=$(fm "$f" | sed -n '1,3p' | cut -d: -f1 | tr '\n' ' ')
  if [ "$order" = "name description model " ]; then _pass "T3 $n: name/description/model 순서"
  else _fail "T3 $n: frontmatter 앞 3줄 키 순서 '$order' (기대 'name description model ')"; fi
done

echo "-- T4: DoD 검증 기준 (model: 줄 총 10)"
total=$(grep -n '^model:' "$AG"/*.md | wc -l | tr -d ' ')
if [ "$total" = "10" ]; then _pass "T4 ^model: 줄 10"; else _fail "T4 ^model: 줄 $total (기대 10)"; fi

echo "-- T5: orchestrator-first.md §5 배정 목록과 교차 일치"
opus_line=$(grep -E '^- `opus` — ' "$OF")
sonnet_line=$(grep -E '^- `sonnet` — ' "$OF")
[ "$(printf '%s\n' "$opus_line" | grep -c .)" = "1" ] && _pass "T5 opus 배정 줄 1개" || _fail "T5 opus 배정 줄 수 != 1"
[ "$(printf '%s\n' "$sonnet_line" | grep -c .)" = "1" ] && _pass "T5 sonnet 배정 줄 1개" || _fail "T5 sonnet 배정 줄 수 != 1"
for n in spec-writer plan-writer researcher security-reviewer orchestrator \
         feature-builder feature-builder-fix feature-builder-refactor feature-builder-worker docs-writer; do
  want=$(want_of "$n")
  val=$(fm "$AG/$n.md" 2>/dev/null | sed -n 's/^model:[[:space:]]*//p' | head -1)
  if [ "$want" = "opus" ]; then mine="$opus_line"; other="$sonnet_line"; else mine="$sonnet_line"; other="$opus_line"; fi
  if printf '%s' "$mine" | grep -qF "\`$n\`" && ! printf '%s' "$other" | grep -qF "\`$n\`" && [ "$val" = "$want" ]; then
    _pass "T5 $n: 규칙 배정($want) = frontmatter($val)"
  else
    _fail "T5 $n: 규칙 배정 줄($want) 또는 frontmatter($val) 불일치"
  fi
done

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
