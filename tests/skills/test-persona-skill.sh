#!/usr/bin/env bash
# tests/skills/test-persona-skill.sh
#
# persona 스킬 SKILL.md 정적 계약 검사.
# (spec docs/specs/2026-07-22-persona-user-selection.md §5,
#  plan docs/plans/2026-07-22-persona-user-selection.md Task 4.2)
# (g) 그룹: 변경 인사말 정적 계약
#  (spec docs/specs/2026-07-23-persona-change-greeting.md,
#   plan docs/plans/2026-07-23-persona-change-greeting.md Task 5.6)
#
# Scope 매핑:
#   (a) SKILL.md 존재 + frontmatter name:/description:
#   (b) 선택 흐름 필수 요소 (내장 2종 + 커스텀 경로 + 끄기 + AskUserQuestion + persona.yaml)
#   (c) 생성 흐름 7문항 키워드 + 표현 수위 3단계 라벨
#   (d) lint 참조 + 통과 시에만 저장 + CLAUDE_PLUGIN_ROOT 경로 해석
#   (e) 내장 충돌 사전 고지
#   (f) frontmatter summary: 자동 기록 언급
#   (g) 변경 인사말: prepend/중립 평문 + fallback 즉석 생성(summary seed, 프리셋 .md 새로 안 엶)
#       + greeting: 자동 생성·편집 + ≤60자 3경로 cap + 정확히 7문항·8번째 부재 + 불변층 종속

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="${REAL_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
SKILL_MD="$REAL_PROJECT_DIR/plugins/rein-core/skills/persona/SKILL.md"

TEST_COUNT=0
FAIL_COUNT=0

fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1" >&2; }

assert_file_exists() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ -f "$1" ]; then echo "  ok: $2"
  else fail "$2 (missing file: $1)"; fi
}

# assert_grep <pattern (ERE)> <label>
assert_grep() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qE -- "$1" "$SKILL_MD" 2>/dev/null; then echo "  ok: $2"
  else fail "$2 (pattern not found: $1)"; fi
}

# assert_grep_fixed <literal string> <label>
assert_grep_fixed() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qF -- "$1" "$SKILL_MD" 2>/dev/null; then echo "  ok: $2"
  else fail "$2 (literal not found: $1)"; fi
}

# assert_grep_absent <pattern (ERE)> <label>  — 패턴이 없어야 통과 (negative 정적 계약)
assert_grep_absent() {
  TEST_COUNT=$((TEST_COUNT + 1))
  if grep -qE -- "$1" "$SKILL_MD" 2>/dev/null; then fail "$2 (unexpected pattern found: $1)"
  else echo "  ok: $2"; fi
}

echo "== (a) 존재 + frontmatter =="
assert_file_exists "$SKILL_MD" "a1: SKILL.md 존재"
assert_grep '^name:[[:space:]]*persona[[:space:]]*$' "a2: frontmatter name: persona"
assert_grep '^description:[[:space:]]*[^[:space:]]' "a3: frontmatter description: 존재"

echo "== (b) 선택 흐름 필수 요소 =="
assert_grep_fixed 'boss-ace' "b1: 내장 boss-ace"
assert_grep_fixed 'jennie' "b2: 내장 jennie"
assert_grep_fixed '.rein/policy/persona' "b3: 커스텀 프리셋 경로"
assert_grep_fixed '끄기' "b4: 끄기(중립) 옵션"
assert_grep_fixed 'AskUserQuestion' "b5: AskUserQuestion 사용"
assert_grep_fixed 'persona.yaml' "b6: persona.yaml 기록"
assert_grep_fixed 'enabled: true' "b7: 프리셋 선택 기록 (enabled: true)"
assert_grep_fixed 'enabled: false' "b8: 끄기 기록 (enabled: false)"

echo "== (c) 생성 흐름 7문항 + 수위 3단계 =="
assert_grep_fixed '이름' "c1: Q1 이름"
assert_grep_fixed '호칭' "c2: Q2 호칭"
assert_grep_fixed '캐릭터 컨셉' "c3: Q3 캐릭터 컨셉"
assert_grep_fixed '표현 수위' "c4: Q4 표현 수위"
assert_grep_fixed '언어분기' "c5: Q5 언어분기"
assert_grep '차단[·./ ]?경고' "c6: Q6 차단·경고 말투"
assert_grep_fixed '예시 멘트' "c7: Q7 예시 멘트"
assert_grep_fixed '절제' "c8: 수위 라벨 절제"
assert_grep_fixed '보통' "c9: 수위 라벨 보통"
assert_grep_fixed '진하게' "c10: 수위 라벨 진하게"

echo "== (d) lint 게이트 =="
assert_grep_fixed 'rein-persona-lint.py' "d1: lint 스크립트 참조"
assert_grep '통과[^[:cntrl:]]*에만[^[:cntrl:]]*저장|통과 시에만' "d2: 통과 시에만 저장 취지"
assert_grep_fixed 'CLAUDE_PLUGIN_ROOT' "d3: CLAUDE_PLUGIN_ROOT 기반 lint 경로 해석"

echo "== (e) 내장 충돌 사전 고지 =="
assert_grep '내장[^[:cntrl:]]*(동일|같은)[^[:cntrl:]]*이름[^[:cntrl:]]*(불가|사용할 수 없)' "e1: 내장 충돌 사전 고지"

echo "== (f) frontmatter summary 자동 기록 =="
assert_grep 'summary:[^[:cntrl:]]*자동|자동[^[:cntrl:]]*summary:' "f1: summary: 자동 작성 언급"

echo "== (g) 변경 인사말 정적 계약 (Task 5.6) =="

# (g1) 인사말/시그니처 prepend + 중립(off) 전환 시 평문 한 줄
assert_grep_fixed '인사말 prepend' "g1a: 시그니처 인사말 prepend 언급"
assert_grep_fixed '고정 평문 중립 한 줄' "g1b: 중립(off) 전환 시 고정 평문 한 줄"

# (g2) fallback 즉석 생성(확보된 summary seed) + 인사말 위해 프리셋 .md 새로 안 엶 (negative 계약)
assert_grep_fixed 'fallback degrade 체인' "g2a: fallback degrade 체인 언급"
assert_grep_fixed 'summary 텍스트를 seed 로' "g2b: fallback seed = 후보 수집서 확보한 summary"
assert_grep_fixed '즉석 생성' "g2c: 즉석 생성 언급"
assert_grep_fixed '새로 열지 않는다' "g2d: 인사말 위해 프리셋 .md 새로 안 엶 (negative)"

# (g3) 생성 흐름 greeting: 자동 생성 + 사용자 편집 가능
assert_grep 'greeting:.*자동 작성' "g3a: greeting: frontmatter 자동 작성"
assert_grep_fixed '수정·삭제할 수 있' "g3b: 생성된 greeting 사용자 수정·삭제 가능"

# (g4) ≤60자 상한 3경로 (내장 curated·커스텀 loader 출력 공통 cap + fallback 즉석) 모두 적용
#   line: 출력 예산 — 경로 무관 최종 시그니처 1줄 ≤60자 (내장 curated·커스텀 loader 출력을 함께 덮는 cap)
assert_grep_fixed '시그니처 인사말 1줄 (≤60자)' "g4a: 출력 예산 — 시그니처 1줄 ≤60자 (경로 무관 cap)"
#   fallback 즉석 생성 경로도 ≤60자
assert_grep_fixed '≤60자 시그니처 한 줄을 즉석 생성' "g4b: fallback 즉석 생성 ≤60자"
assert_grep_fixed 'tone-only + L4-clean + ≤60자' "g4c: 즉석 문구 불변식 ≤60자"

# (g5) 정확히 7문항 · 8번째 질문 부재 (기존 c1~c10 키워드 검사 위에 개수 파싱을 추가)
GEN_BLOCK="$(awk '/^## 생성 흐름/{f=1; next} /^### /{f=0} f' "$SKILL_MD")"
GEN_QCOUNT="$(printf '%s\n' "$GEN_BLOCK" | grep -cE '^[0-9]+\. \*\*')"
TEST_COUNT=$((TEST_COUNT + 1))
if [ "$GEN_QCOUNT" -eq 7 ]; then echo "  ok: g5a: 생성 흐름 질문 정확히 7개 (count=$GEN_QCOUNT)"
else fail "g5a: 생성 흐름 질문 개수 7 아님 (count=$GEN_QCOUNT)"; fi
assert_grep_absent '^8\. ' "g5b: 8번째 numbered 질문 부재"
assert_grep_fixed '8번째 질문을 만들지 않는다' "g5c: 8번째 질문 없음 불변식 명시"
assert_grep_fixed '7문항의 순서·개수는 불변' "g5d: 7문항 순서·개수 불변 명시"

# (g6) 불변층 종속 정적 계약 (## 경계)
assert_grep_fixed '불변층 종속' "g6a: 불변층 종속 항목 존재"
assert_grep_fixed 'tone-only 로 종속된다' "g6b: 인사말 tone-only 종속"
assert_grep_fixed '약화·대체·완곡화하지 않' "g6c: 판단·경고·차단 약화·대체·완곡화 안 함"
assert_grep_fixed '충돌 시 응답 규칙이 항상 이긴다' "g6d: 충돌 시 응답 규칙 우선"

# (g7) 대화 언어 적응 (저장 greeting 은 정본, 응답 언어로 등가 인사말) + 전환 보고 전체 메타 설명 금지 + 짧은 다절 허용 명확화
assert_grep_fixed '대화 언어 적응' "g7a: 대화 언어 적응 항목 존재"
assert_grep_fixed '그 언어로 등가의 시그니처 인사말' "g7b: 응답 언어가 정본과 다르면 그 언어로 인사말"
assert_grep_fixed '정본(canonical)' "g7c: 저장 greeting 은 정본"
assert_grep_fixed '언어 적응은 스킬 출력 시점의 책임' "g7d: 로더 불변·적응은 스킬 출력 시점 책임 (문장 보존)"
assert_grep_fixed '메타 서술을 붙이지 않는다' "g7e: 전환 시 메타 설명 금지"
assert_grep_fixed '전환 보고 어디에도' "g7f: 메타 금지가 전환 보고 전체 (상태 행 우회 차단)"
assert_grep_fixed '짧은 다절 인사말은 허용' "g7g: 짧은 다절 인사말 허용 명확화 (여러 문장 금지 완화)"
assert_grep_fixed '로더는 정본만 반환' "g7h: 로더 정본만 반환 절 보존 (언어 적응 책임 문장 삭제 차단)"
assert_grep_fixed '장황한 여러 문장 나열·이모지 스팸을 금지' "g7i: 장황 나열·이모지 스팸 금지 (허용 반전 차단)"
assert_grep_fixed '<전환 확인 1줄>' "g7j: 전환 확인 정확히 1줄 (최소 1줄 회귀 차단)"

echo ""
echo "persona-skill: $((TEST_COUNT - FAIL_COUNT))/$TEST_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
