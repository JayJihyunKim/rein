#!/usr/bin/env bash
# tests/rules/test-communication-principles.sh
# spec docs/specs/2026-10-07-review-delta-evidence-and-defaults.md §3.9.1 (2)
# Scope IDs covered: RDE-TONE-BODY, RDE-TONE-SUMMARY, RDE-OPS-PRINCIPLES, RDE-MODEL-RULE, RDE-MODEL-HINT
set -u
export LC_ALL=C   # GNU grep 3.7 + UTF-8 로케일의 한글 줄 매칭 결함 회피 (바이트 비교)

# 요약 문단 시작 문자열 — 설계 §3.5.3 / §3.6.2 (착수 전 차단 해소본) 와 같은 값.
OSS_MARK='Operating:'
OFS_MARK='Worker model:'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
R="$ROOT/plugins/rein-core/rules"
RT="$R/response-tone.md";       RTS="$R/short/response-tone-summary.md"
OS="$R/operating-sequence.md";  OSS="$R/short/operating-sequence-summary.md"
OF="$R/orchestrator-first.md";  OFS="$R/short/orchestrator-first-summary.md"
RP="$R/routing-procedure.md"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
has()   { if grep -qF -- "$2" "$1"; then _pass "$(basename "$1"): '$2'"; else _fail "$(basename "$1"): missing '$2'"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then _fail "$(basename "$1"): unexpected '$2'"; else _pass "$(basename "$1"): no '$2'"; fi; }
# 줄 전체가 $2 와 같은 첫 줄의 번호 (없으면 빈 값)
hdr()   { grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1; }
# $2 를 포함하는 첫 줄의 번호 (없으면 빈 값)
pos()   { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
lt()    { # $1 label, $2 $3 줄 번호 — 둘 다 있고 $2 < $3
  if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then _pass "$1"; else _fail "$1 (got '$2' < '$3')"; fi
}

echo "## test-communication-principles.sh"

echo "-- response-tone.md"
for h in '## 설명 원칙' '## 질문 원칙' '## Output Language'; do
  if [ -n "$(hdr "$RT" "$h")" ]; then _pass "header '$h'"; else _fail "header '$h' missing"; fi
done
if [ -z "$(hdr "$RT" '## 질문 형식')" ]; then _pass "구 헤더 '## 질문 형식' 부재"; else _fail "구 헤더 '## 질문 형식' 잔존"; fi
for s in '한 문장에 한 핵심' '처음 쓰는 용어는 풀이' '같은 개념은 같은 이름' '사실·추정·미검증 구분' \
         '구조는 도식으로' 'ASD-STE100' '결정할 것' '선택별 결과' '추천과 질문' '한 번에 결정 하나' \
         '기술 이름만으로 선택을 요구하지 않는다' '진행 보고' '작업 완료 보고' '변경 내용' '검증 결과와 미확인' \
         '방금 한 것 → 결과 → 다음 단계'; do
  has "$RT" "$s"
done
hasnt "$RT" '한국어로 답'
MANDATE=$(python3 - "$RT" <<'PY'
import re, sys
body = open(sys.argv[1], encoding="utf-8").read()
m = re.compile(r"^#\s+.+?\n+(## 행동 강령\b.*?)(?=\n## |\Z)", re.DOTALL | re.MULTILINE).search(body)
print(len(m.group(1).encode("utf-8")) if m else -1)
PY
)
if [ "$MANDATE" -ge 1 ] 2>/dev/null && [ "$MANDATE" -le 2048 ]; then _pass "행동 강령 ${MANDATE} B <= 2048 B"
else _fail "행동 강령 크기 ${MANDATE} B (1..2048 밖 또는 미검출)"; fi

echo "-- short/response-tone-summary.md"
if [ "$(head -1 "$RTS")" = "# Response Tone — per-turn quick rule" ]; then _pass "요약 첫 줄 헤더 불변"; else _fail "요약 첫 줄 헤더 변경"; fi
for s in 'Explaining:' 'Progress report:' 'Completion report' 'what changed / why / impact / verification result' \
         'context → decision → what each choice leads to → recommendation' 'One decision at a time' 'Output language:' \
         'never infer it from repo docs'; do
  has "$RTS" "$s"
done
RTS_SIZE=$(wc -c < "$RTS" | tr -d ' ')
if [ "$RTS_SIZE" -le 1800 ]; then _pass "요약 ${RTS_SIZE} B <= 1800 B"; else _fail "요약 ${RTS_SIZE} B > 1800 B"; fi

echo "-- operating-sequence.md + 요약"
lt "'## 행동 강령' < '## 작업 운영 원칙'" "$(hdr "$OS" '## 행동 강령')" "$(hdr "$OS" '## 작업 운영 원칙')"
lt "'## 차단 시 행동' < '## 작업 운영 원칙'" "$(hdr "$OS" '## 차단 시 행동')" "$(hdr "$OS" '## 작업 운영 원칙')"
lt "'## 작업 운영 원칙' < '## DoD 의무 섹션 (Step 2)'" "$(hdr "$OS" '## 작업 운영 원칙')" "$(hdr "$OS" '## DoD 의무 섹션 (Step 2)')"
for s in '시작·재개·전환 알림' '현재 위치' '남은 일' '사용자 확인 대상과 직접 판단 대상의 경계' \
         '합의된 결정은 다시 묻지 않는다' '결정 기록 위치'; do
  has "$OS" "$s"
done
lt "요약: '$OSS_MARK' 문단이 '> 전체 본문은' 앞" "$(pos "$OSS" "$OSS_MARK")" "$(pos "$OSS" '> 전체 본문은')"
# 요약 한 줄이 본문 네 원칙을 모두 담는다 (설계 §3.9.1 (2) — 같은 줄)
OSS_LINE=$(grep -F -- "$OSS_MARK" "$OSS" | head -1)
for s in 'phase change' 'security relaxation' 'only if premises change' 'log decisions in DoD/spec/inbox'; do
  case "$OSS_LINE" in
    *"$s"*) _pass "요약 '$OSS_MARK' 줄: '$s'" ;;
    *) _fail "요약 '$OSS_MARK' 줄: missing '$s'" ;;
  esac
done

echo "-- orchestrator-first.md + 요약"
for s in '**기본 모델 배정**' '세션 모델 그대로' 'CLAUDE_CODE_SUBAGENT_MODEL' 'model_hint' '`model` 인자' \
         '1. 원하는 워커 모델을' '2. 대체 모델도 불가' '3. 병렬·다중 워커 dispatch'; do
  has "$OF" "$s"
done
lt "'## 5.' < '**기본 모델 배정**'" "$(pos "$OF" '## 5. 워커 모델 판단과 강등 순서')" "$(pos "$OF" '**기본 모델 배정**')"
lt "'**기본 모델 배정**' < 강등 문단" "$(pos "$OF" '**기본 모델 배정**')" "$(pos "$OF" '원하는 모델을 쓸 수 없거나')"
has "$OFS" "$OFS_MARK"
# 요약이 본문 §5 의 경계 셋을 모두 담는다 (설계 §3.9.1 (2))
for s in 'model_hint' 'build workers only' 'orchestrator keeps session model' 'forced subagent-model env var wins'; do
  has "$OFS" "$s"
done

echo "-- routing-procedure.md"
has   "$RP" '규칙이 소비하는 힌트'
has   "$RP" '이 전달을 검증하는 코드는 없다'
has   "$RP" '지휘 규칙이 dispatch 시 소비하는 힌트'
hasnt "$RP" '`model_hint` 와 `effort_hint` 는 정보성 힌트'
hasnt "$RP" '`model_hint` 등 기존 정보성 필드'
hasnt "$RP" '`model_hint` 와 동일 선상'

echo "-- light 면제 정정 (5파일, 설계 §3.6.4)"
AGD="$ROOT/plugins/rein-core/agents"
has   "$RP" 'light 면제는 폐기됨'
hasnt "$RP" '`security_tier: light` 효과'
has   "$OS" '`light` 여도 이 증거는 필수'
hasnt "$OS" '이 증거 없이 commit 허용'
for b in feature-builder feature-builder-fix feature-builder-refactor; do
  has   "$AGD/$b.md" 'light 여도 면제 없음'
  hasnt "$AGD/$b.md" 'security_tier:light 면 면제'
done

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
