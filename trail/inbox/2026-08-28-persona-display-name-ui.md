# 2026-08-28 · persona 선택 UI 개선 + 표시 이름 현지화 — 구현 완료 (dev 로컬, push 미실행)

## 무엇

`/rein:persona` 선택 흐름을 최상위 3개 고정 메뉴(`페르소나 목록` / `내 페르소나 만들기` /
`페르소나 끄기`)로 재편하고, 내장 3프리셋에 **표시 이름**(`display_name` + 선택 `display_name_en`)을
도입해 목록·turn-brief·SessionStart 주입 세 경로에서 영어 파일명 slug 자동 노출을 없앴다.

- 표시 이름: boss-ace=마르코/Marco Santoro, jennie=제니/Jennie, choi-haengbae=최행배(영문 생략)
- 로더 active_line 이 slug 대신 표시 이름 사용, 표시 이름 없으면 영문 alias 도 안 붙이고
  "이름 없는 페르소나" fallback(전역 label dedup)
- `persona-summary` nudge 가 응답 언어에 맞춘 자칭을 지시(영어 대화 시 괄호 안 영문 표기 사용)
- 프리셋 본문 제목 `# Persona: <slug>` → `# Persona: <표시 이름>` (SessionStart 주입 slug 제거)
- 라벨: `새로 만들기`→`내 페르소나 만들기`, `끄기(중립)`→`페르소나 끄기`

사용자 요청(어제 v2.0 업데이트 후 페르소나 목록 UI 불편 + 자기 이름을 영어 파일명으로 부르는 문제)의
직접 해결.

## 산출물 (dev 로컬 커밋)

- 설계(brainstorm/spec/plan/DoD): `72e8b8f`
- 웨이브1(프리셋 boss-ace + 로더 2사본 + 스킬 + 회귀 테스트): `4ae5848`
- 웨이브2(jennie/choi-haengbae 표시 이름 + persona-summary 언어 적응 nudge): `e3c645b`
- byte 예산 상한 hotfix(내장 프리셋 개별 크기 1536→1600, display_name 필드 도입 반영): `7dfefa1`

## 리뷰 / 검증

- 설계 문서: spec codex 5회차 후 user-approved, plan codex 5회차 PASS
- 웨이브1 코드리뷰 codex PASS + 보안리뷰 PASS(로더 파싱 표면) — 두 v2 증거로 커밋 게이트 통과
- 웨이브2(표시 이름 값 + nudge 문구): 로직 변경 없어 커밋 게이트 통과(리뷰 비대상)
- 전체 테스트 GREEN: `tests/{scripts,hooks,skills}/run-all.sh` ALL PASSED + coverage validator exit 0 +
  byte 예산 11/0. 로더 두 사본 byte-identical 유지.
- 실전 확인: 이 세션 turn-brief 활성 줄이 "제니 (Jennie)"로 정상 표시됨(표시 이름 반영 실증)

## 후속 / 미결

- **push(원격 반영)는 오빠 승인 후 별도** — push 전 전체 diff 통합 리뷰 1회 권고
- 배포 버전 등급(minor 후보)은 배포 시 사용자 결정(spec §7 이월)
- 커스텀 프리셋 fallback 전역 dedup 계약은 커스텀 0개라 실전 미발동(계약·테스트로만 고정)
- codex-review 요청서가 "PASS"/정량 표현 + 자가검증 관문(typecheck/test 축 + diff_self_review)에
  여러 번 걸림 — code-review 모드 요청서 작성 관례로 익혀둘 것
