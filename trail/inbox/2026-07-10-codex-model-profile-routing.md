# 2026-07-10 — Codex 모델 프로필 라우팅 (역할 기반 유연 적용)

## 무엇을

codex CLI 0.144.1 의 gpt-5.6 세대 대응. dev `de9ae01` (설계 체인 `8b9cb4c`).

- **게이트 모델**: gpt-5.5 → `gpt-5.6-sol` **고정** (effort 만 기존 결정론 산출 가변). 규모 기반 모델 라우팅은 codex-ask 독립 의견(gpt-5.6-sol 본인, 공식 docs 대조)에 따라 기각 — "심사위원 3명 = 판정 비일관".
- **/codex-ask 3계층**: fast(luna/low, 기계적) · default(terra/medium, 기본) · deep(sol/high, 고위험·설계 반박).
- **보강 4종**: config 부재 시 무모델 degrade 폐지 → 래퍼 내장 canonical(sol+high) 명시 폴백 / 위험 경로 floor(hooks·scripts/rein-*·security·config·workflows 산출 low→medium 단방향, 마커>floor, spec 모드 제외) / 게이트 도장 증빙 5필드(model·effort·effort_source·policy_version·codex_version) / `[EFFORT:ultra|max|xhigh]` 사유별 거부(자동 산출 어휘는 low|medium|high 유지).

## 절차 증거

brainstorm → spec(4R PASS) → plan(4R PASS, 14 Scope 커버) → parallel-execute 3웨이브(Wave1 4워커 병렬 → Wave2 래퍼 단독 → Wave3 미러) → 코드 리뷰 3R PASS → 보안 PASS. 신규 행위 테스트 90/90 + 회귀 54/29/15 + run-all 전체 GREEN. 첫 실전 도장에 증빙 5필드 실기록 확인(model: gpt-5.6-sol / policy_version: 1 / codex_version: codex-cli 0.144.1) — 도그푸드 성공.

리뷰 사이클 교훈: R1 지적 = DoD `## 범위 연결` 섹션 + `covers: [...]` **대괄호 형식** 필수(래퍼/validator 계약). R2 지적 = spec 헤딩은 정확히 `## Scope Items`(번호 붙이면 래퍼 추출 실패 — spec-writer 반복 이슈), Scope ID 토큰 자체에 방향성 필요. Wave2 워커가 구계약 고정 테스트(failsoft T4)와의 충돌을 blocked 로 정직 보고 → 부모가 T4 를 신계약으로 갱신(문서 3종 동기화 후 재리뷰).

## 비차단 후속 (보안 Low 3건 + 이월 2건)

- [Low] `[EFFORT:]` 마커가 프롬프트 내 첫 등장 기준이라 리뷰 대상 콘텐츠에 섞인 마커로 하향 가능(정직 에이전트 위협모델 안, 최저치도 low 리뷰 수행) — 선두 앵커 하드닝 후보.
- [Low] git 인용 파일명(비 ASCII)의 최상위 위험 경로가 floor 미탐 가능(상향 전용이라 게이트 약화 아님, 본 repo 실경로 전부 중첩형).
- [참고] CRLF codex 빌드 시 `codex_version` 값 끝 `\r` 잔존 가능 — `tr -d '\r'` 한 줄 소재.
- [이월] terra/luna 그림자 평가(게이트 모델 교체 검증), xhigh 마커 허용(timeout 실측 후 재승급 전용) — DoD OUT.

## 릴리스 판정 (versioning Rule A)

user-facing 신규 기능(게이트 모델 변경 + 도장 스키마 확장 + codex-ask 라우팅) → **minor** 후보. main 머지/publish 는 별도 승인 대기.
