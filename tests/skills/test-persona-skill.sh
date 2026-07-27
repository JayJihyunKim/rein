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
#   (h) 선택창 '새로 만들기' 고정 입구 + 선택지 상한(4) 초과 2단 제시 + 도달 가능성 불변식
#       + 인계 시 persona.yaml 미기록·인사말 미수행

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

echo "== (h) 선택창 '새로 만들기' 입구 + 선택지 상한 초과 처리 (dod-2026-07-27) =="

# (h1) 새로 만들기 / 끄기는 실존 프리셋 수와 무관한 고정 옵션
assert_grep_fixed '항상 포함하는 고정 옵션 2개' "h1a: 고정 옵션 2개(새로 만들기·끄기) 명시"
assert_grep '새로 만들기[^[:cntrl:]]*생성 흐름' "h1b: '새로 만들기' 가 생성 흐름 입구"

# (h2) AskUserQuestion 선택지 상한 + 초과 시 2단 제시 + 갈래 내 이어보기
assert_grep_fixed '선택지 상한 4개' "h2a: 선택지 상한 4개 명시"
assert_grep_fixed '2단 제시' "h2b: 상한 초과 시 2단 제시"
assert_grep_fixed '갈래 선택' "h2c: 1단 = 갈래 선택"
assert_grep_fixed '다음 목록 보기' "h2d: 갈래 내 4개 초과 시 이어보기"

# (h3) 도달 가능성 불변식 — 상한 때문에 실존 후보가 조용히 누락되면 안 됨 (negative 계약)
assert_grep_fixed '도달 가능성 불변식' "h3a: 도달 가능성 불변식 항목 존재"
assert_grep_fixed '조용히 빠지는 프리셋이 있어서는 안 된다' "h3b: 후보 누락 금지 문장 보존"

# (h4) 인계 시 상태 미변경 — persona.yaml 미기록 + 전환 인사말 미수행
assert_grep '새로 만들기 선택 시[^[:cntrl:]]*쓰지 않고' "h4a: 새로 만들기 선택 시 persona.yaml 미기록"
assert_grep_fixed '새로 만들기로 인계된 경우 이 단계를 수행하지 않는다' "h4b: 인계 시 인사말 단계 미수행"

# (h5) 적용 질문 '예' 는 기록 + 인사말을 모두 수행 (인사말이 영구히 누락되지 않음)
assert_grep '선택 흐름 [0-9]단계\(인사말 prepend \+ 결과 보고\)를 동일하게 수행' "h5a: 적용 '예' 시 기록 + 인사말 수행"

echo "== (i) 전환 즉시 본문 반영 + 인사말 후보 선택 (dod-2026-07-27) =="

# (i1) 전환 직후 로더가 해석한 경로에서 신규 본문을 읽어 그 턴부터 적용
assert_grep_fixed '새 말투 본문을 지금 세션에 반영' "i1a: 전환 즉시 본문 반영 단계 존재"
assert_grep_fixed '--persona-file' "i1b: 본문 경로는 로더 --persona-file 로 해석"
assert_grep_fixed '이번 턴부터' "i1c: 반영 시점 = 이번 턴부터"

# (i2) 요약 1줄로 캐릭터를 추측하지 않는다 (실사용 결함 재발 차단 — 이름 오독/직전 호칭 잔존)
assert_grep_fixed '요약 1줄로 캐릭터를 추측하지 않는다' "i2a: 요약 추측 금지 (negative)"
assert_grep_fixed '이름·호칭은 반드시 본문에서 읽는다' "i2b: 이름·호칭 출처는 본문"

# (i3) 해석 실패 시 추측 금지 + 중립 / (i4) 끄기 시 직전 말투 즉시 폐기
assert_grep_fixed '캐릭터를 추측하지 말고 중립으로' "i3a: 경로 해석 실패 시 추측 금지·중립"
assert_grep_fixed '직전 프리셋 본문의 말투를 즉시 버리고' "i4a: 끄기 시 직전 말투 즉시 폐기"

# (i5) 본문을 읽더라도 인사말 출처는 여전히 로더 (인사말 신뢰 경계 보존)
assert_grep_fixed '본문을 읽었다고 해서 인사말을 본문에서 만들지 않는다' "i5a: 인사말 출처는 여전히 로더 (경계 보존)"

# (i6) 생성 흐름 — 인사말 후보 제시 + 직접 작성 (7문항 불변 유지)
assert_grep_fixed '후보 2~3개를 제시해 사용자가 고르거나 직접 작성' "i6a: 인사말 후보 제시 + 직접 작성"
assert_grep_fixed '직접 쓸게요' "i6b: '직접 쓸게요' 경로 존재"
assert_grep_fixed '초안 확인 단계의 일부이지 질문 세트의 일부가 아니다' "i6c: 확인 단계 소속 — 질문 세트 아님"

echo "== (j) 로더 호출 경로 해석 규약 (dod-2026-07-27) =="

# (j1) 규약 블록 + plugin 루트를 스킬 자기 위치에서 유도
assert_grep_fixed '로더·lint 호출 규약' "j1a: 호출 규약 블록 존재"
assert_grep_fixed '이 스킬 파일이 놓인 디렉토리의 상위 2단계' "j1b: plugin 루트를 스킬 자기 위치에서 유도"

# (j2) CLAUDE_PLUGIN_ROOT 를 명시 전달 — 환경변수 존재를 기대하지 않는다
assert_grep_fixed 'CLAUDE_PLUGIN_ROOT="$PR"' "j2a: 로더 호출 시 CLAUDE_PLUGIN_ROOT 명시 전달"
assert_grep_fixed '변수가 있기를 기대하는 형태로 호출하지 않는다' "j2b: 환경변수 의존 호출 금지"

# (j3) 빈 출력의 의미 — '비활성' 으로 오해 금지 (실사용 결함의 직접 원인)
assert_grep_fixed '빈 출력' "j3a: 빈 출력 실패 양상 명시"
assert_grep_fixed '"비활성" 으로 오해' "j3b: 빈 출력을 비활성으로 오해 금지"

# (j4) 두 호출 지점(본문 경로·인사말) 모두 규약을 따른다 — 규약 적용이 한쪽만 남는 회귀 차단
TEST_COUNT=$((TEST_COUNT + 1))
PR_CALLS="$(grep -cF 'CLAUDE_PLUGIN_ROOT="$PR" python3' "$SKILL_MD" 2>/dev/null || true)"
[ -n "$PR_CALLS" ] || PR_CALLS=0
if [ "$PR_CALLS" -ge 2 ]; then echo "  ok: j4a: 규약 형태 호출 ${PR_CALLS}건 (본문 경로 + 인사말)"
else fail "j4a: 규약 형태 호출이 2건 미만 (count=$PR_CALLS)"; fi
assert_grep_absent '\$\{CLAUDE_PLUGIN_ROOT:-[^}]*\}/scripts/rein-policy-loader\.py' "j4b: 환경변수 기대형 로더 호출 잔존 없음"

echo "== (k) 호출 규약 실패 모드 방어 (dod-2026-07-27 round 2) =="

# (k1) 셸 상태 비유지 — 매 호출마다 PR 재정의 (미정의 시 빈 문자열 전개로 조용히 실패)
assert_grep_fixed '셸 상태는 명령 호출 사이에 유지되지 않는다' "k1a: 셸 상태 비유지 명시"
assert_grep_fixed '같은 명령 안에서 `PR=` 을 다시 정의한 상태' "k1b: 매 호출 PR 재정의 전제"
TEST_COUNT=$((TEST_COUNT + 1))
PR_DEFS="$(grep -cF 'PR="<이 스킬의 base directory>/../.."' "$SKILL_MD" 2>/dev/null || true)"
[ -n "$PR_DEFS" ] || PR_DEFS=0
# 규약 블록 + 본문 경로 + 인사말 + lint = 4건 (실행 가능한 예시마다 PR 정의 동반)
if [ "$PR_DEFS" -ge 4 ]; then echo "  ok: k1c: 실행 예시마다 PR 정의 동반 (${PR_DEFS}건)"
else fail "k1c: PR 정의 동반 예시가 4건 미만 (count=$PR_DEFS)"; fi

# (k2/k3) 빈 출력 = 호출 결함 우선 의심 — 내장 프리셋은 즉석 생성 금지
assert_grep_fixed '정확히 1회 재시도' "k2a: 빈 출력 시 1회 재시도"
assert_grep_fixed '즉석 생성으로 바로 넘어가지 않는다' "k3a: 빈 출력 즉시 창작 금지"
assert_grep_fixed '내장 프리셋인데 재시도에도 비면 그것은 "인사말 없음" 이 아니라 호출 결함' "k3b: 내장 빈 출력 = 호출 결함 판정"
assert_grep_fixed '즉석 생성 금지' "k3c: 내장 경로 즉석 생성 금지"

# (k4) 갈래 내 항목 1개일 때 선택지 최소 2개 충족
assert_grep_fixed '선택지는 최소 2개' "k4a: 선택지 최소 2개 제약 명시"
assert_grep_fixed '뒤로 가기' "k4b: 단일 항목 갈래의 2번째 선택지"

echo ""
echo "persona-skill: $((TEST_COUNT - FAIL_COUNT))/$TEST_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
