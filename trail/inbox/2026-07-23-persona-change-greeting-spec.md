# 페르소나 변경 시그니처 인사말 — 설계(brainstorm+spec) 완료, 구현 미착수

- 날짜: 2026-07-23
- 상태: **설계 승인(PASS+stamp)까지 완료. plan/구현은 미착수** (다음 세션 이월).
- 산출물:
  - brainstorm: `docs/brainstorms/2026-07-23-persona-change-greeting.md`
  - spec: `docs/specs/2026-07-23-persona-change-greeting.md` (R8, 18 Scope, spec-review 도장 생성됨 — reviewer codex, content_sha 기록)

## 기능 요지

페르소나를 스킬로 **바꿀 때만** 그 캐릭터의 **고정 시그니처 인사말 한 줄**을 상태 보고 앞에 내보낸다(스타크래프트 유닛 생성 대사 방식). 내장 프리셋은 curated 라인, 커스텀은 캐릭터 컨셉에서 **자동 생성**(7문항 계약 불변). 세션시작 훅·매턴 훅 불변, 새 훅/CI 없음. 릴리스 시 minor(구현 후).

## 설계 확정 사항

- 트리거 = 변경 시에만(codex-ask Q1). 세션시작 인사(Option B)·무반복 로테이션(Option D)·8번째 질문 추가는 배제.
- 인사말 저장 = 프리셋 frontmatter `greeting:` 필드. 스킬은 로더 `--persona-greeting <name>` 로만 취득(파일 직접 파싱 안 함). 인사말 없는 fallback 은 후보 수집 때 이미 확보한 summary 재사용.
- 무효 이름 → 빈 출력(boss-ace 다운그레이드 금지). 끄기 → 담백한 비캐릭터 한 줄.

## 리뷰 이력 (8라운드 — 전부 실질 이슈, 설계 아키텍처는 일관 유지)

- R1~R2: 무효 이름 다운그레이드·delimiter 누출·신뢰 경계 과잉 계약(High 3+3) → 반영.
- R3~R6: 세션시작 누출 봉합의 **런타임 경계 이동**(lint→loader `_custom_persona_valid()`), 하위호환 서술 정정, CRLF→bare-CR/유니코드 구분자까지 누출 클래스 확장.
- **핵심 수렴**: 줄바꿈 종류별 두더지잡기를 **일반 불변식 (P)∧¬(A)** 로 대체 — "느슨한 파서(splitlines/universal-newline)는 fence 로 보는데 hook awk 는 안 자르는 파일이면 전부 거부". padded/CRLF/bare-CR/유니코드 구분자 균일 차단. codex 실측 확인.
- 구현 함정 명문화: (A) 계산에 `str.splitlines()` 금지(후행 `\r` 제거로 무력화) — `\n` 리터럴 분할만.
- R7 통과(High 0), R8 = 잔여 Medium 2(문구 완전 동기화 + U+2028 회귀 픽스처) 반영 → **R8 PASS**.
- 리뷰 진행 사건: codex 3회 정지(워치독 exit 5 1회 포함) → 그 사이 대체 리뷰어(sonnet) 1회 사용. 이후 codex 정상 완주.

## 후속 (다음 세션)

- **plan 작성**(`rein:plan-writer`) → 커버리지 매트릭스 + 자동 리뷰 → 구현 → 코드/보안 리뷰 → 릴리스(minor).
- 구현 시 반드시 반영: (P)∧¬(A) 일반 불변식, `\n`-리터럴 분할(no splitlines), 로더 2벌 파리티, U+2028 회귀 픽스처 3경로.
