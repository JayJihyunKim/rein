# 페르소나 변경 시그니처 인사말 — 구현 플랜 작성 완료 (구현 미착수)

- 날짜: 2026-07-23
- 상태: **plan 작성 + 커버리지 검증 + 설계 재검토 PASS + 도장 생성까지 완료. 구현은 미착수** (다음 세션 이월).
- 선행: 같은 날 spec R8 PASS + 도장(`docs/specs/2026-07-23-persona-change-greeting.md`, 상세 `trail/inbox/2026-07-23-persona-change-greeting-spec.md`).
- 산출물: `docs/plans/2026-07-23-persona-change-greeting.md`

## 플랜 개요

spec §5 의 18개 Scope ID 를 커버리지 매트릭스 + 각 work-unit `covers:` 로 100% 매핑(구현 18/18, deferred 0, mismatch 마커 없음). 결정적 2웨이브 병렬 스케줄:

- **Wave 1 (병렬 edit_only, pairwise-disjoint):** 프리셋 인사말 필드 편집 · 로더 2벌(플러그인+루트 파리티) · 스킬 문서 · lint 강화
- **Wave 2 (병렬 edit_only, 1차 의존):** 로더 테스트 · lint 테스트 · 스킬 테스트 · 세션시작 회귀 테스트 · 프리셋 인사말 테스트

부모(메인 세션)가 웨이브 단위로 검증·테스트·커밋. 릴리스 등급 **minor(기록만, 이 사이클은 릴리스 안 함)**.

## 리뷰 이력 (2라운드 — 자동 설계 검토)

- **R1 NEEDS-FIX** (4건, 전부 minor·구조적 커버리지는 통과): ①lint fence-read fail-open 위험(핸들 미종료 + raw 실패 시 조용한 skip) ②`greeting-stays-tone-only-...` 회귀 축이 문서 task 에만 있고 테스트 task 에 없음 ③유효 custom(greeting 보유) positive 시나리오 부재 ④turn-brief 회귀가 literal 토큰만 검사(값 누출 못 잡음).
- **author(플랜 작성 주체)가 4건 보완, reviewer(codex)는 findings 만** — 권한 경계 유지, 자율 self-fix 루프 없음:
  1. lint fence-read → `with open(..., "rb")` 명시 종료 + raw 재읽기 실패 시 **fail-closed violation 추가**(조용한 skip 제거).
  2. tone-only 회귀 축 추가 — 매트릭스 위치 `Task 3.5 + Task 5.6`, 테스트 task 에 SKILL.md tone-only/불약화 문구 정적 assertion.
  3. 유효 custom positive 시나리오(저장된 인사말 값 그대로 출력) 추가.
  4. turn-brief 를 고유 sentinel **값** 부재 검사로 강화.
- **R2 PASS** — 4건 전부 해소, Design 18/18 MATCH, Test 11/11 MATCH, Code 5/5. PARTIAL/CONTRADICTS/MISSING 0. 두 fence 관련 Scope ID 계약은 slug(`whitespace-padded`)로 좁히지 않고 (P)∧¬(A) 전 terminator(padded/CRLF/bare-CR/U+2028·U+2029) 유지를 진리표로 재확인.
- 도장은 plan 바이트 content_sha 앵커로 생성. 코드리뷰 게이트 무접촉(spec/plan 도장과 코드 도장 분리 유지).

## 구현 시 반드시 반영 (spec 8라운드 봉합 — 놓치면 재발)

- 거부 판정 **일반 불변식 (P)∧¬(A)**: (P) 느슨한 파서(splitlines/universal-newline)가 선두 라인을 fence 로 인식 ∧ (A) awk 관점 선두 `\n`-레코드가 byte-exact `---` 아님 → 거부.
- **(A) 계산에 `str.splitlines()` 금지** — `\n` 리터럴 분할만(후행 `\r`·유니코드 구분자 제거로 검사 무력화됨). 기존 형제 파서가 splitlines 관례라 답습 위험.
- 로더 2벌 byte-identical 파리티. `--persona-greeting` 은 downgrade 경로 재사용 금지(무효 이름 → 빈 출력, boss-ace 대체 인사말 아님).
- 세션시작 훅·매턴 훅 소스 불변. 새 훅/새 CI 잡 없음.
- U+2028/U+2029 회귀 픽스처를 로더·lint·세션시작 3경로 모두에 추가.

## 다음 (다음 세션)

- **구현** — `parallel-execute` 스킬(또는 `subagent-driven-development`)로 2웨이브 dispatch → 부모가 웨이브 단위 검증/테스트/커밋 → 통합 코드리뷰 + 보안리뷰 → 릴리스(minor).
