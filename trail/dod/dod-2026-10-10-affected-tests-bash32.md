# DoD: 선택기 테스트의 bash 3.2(macOS) 호환 수정

- 작성일: 2026-10-10
- plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
- 계기: v2.4.0 태그 push 의 발행 워크플로 사전 테스트에서 macOS 잡의 script tests 가 실패(`tests/scripts/test-affected-tests.sh` 4건). 공식 미러·공개 태그·GitHub Release 는 정상 반영됨 — 실패한 것은 발행 산출물 기록 단계뿐.
- 원인(로컬 재현 — python:3.12-alpine + bash 3.2.57 컨테이너): (1) AT21b(c) — 테스트가 `mk_script "$(printf …)"` 로 만든 스크립트에서 bash 3.2 가 `{…}` 를 중괄호 확장해 JSON 출력이 깨짐 → 선택기는 "출력 형식 오류" 로 정상 하강(제품 결함 아님, 테스트 작성 결함). (2) AT17(e) — macOS `wc -l` 의 앞 공백 패딩('       0')을 '0' 과 문자열 비교.
- 등급(versioning Rule A): tests/** 만 변경 → no bump. CHANGELOG 미기재(Rule C).
- 사용자 승인: "자동모드 켜고 릴리즈까지 이어가" (2026-10-09) — 릴리스 검증 실패의 후속 수정으로 같은 지시 범위.

## 범위

IN
1. `tests/scripts/test-affected-tests.sh` — 스크립트 본문을 중괄호 확장 영향 없는 방식으로 생성(AT21b(c), 같은 패턴의 다른 케이스 포함), `wc -l` 결과 공백 제거(AT17(e), 같은 패턴 포함).
2. 검증: 로컬(bash 5.1) + 컨테이너(bash 3.2) 둘 다 실패 0. 코드 리뷰·보안 리뷰 → 커밋 → dev 병합·push.

OUT
- 제품 코드 변경, 버전 bump, main 반영(테스트 전용 — 다음 릴리스 때 함께, Rule B 오늘 main 병합 1회 사용).

## 변경 파일

tests/scripts/test-affected-tests.sh

## Definition of Done

- [x] 두 셸 버전에서 test-affected-tests 실패 0
- [x] 리뷰·보안 통과 → 커밋 → dev 병합·push
- [x] 완료 기록·index 갱신

## 검증 기준

- `bash tests/scripts/test-affected-tests.sh` 가 `FAIL: 0`
- bash 3.2 컨테이너에서 같은 테스트 `FAIL: 0`
- 기존 단언 삭제 없음(`git diff -U0` 에서 `- ` 줄은 교체된 생성·비교 줄뿐)

## 라우팅 추천

agent: rein:feature-builder-fix
orchestration: main-session-orchestrated
worker_strategy: 테스트 파일 1개 수정 — 워커 1개(sonnet, edit_only). 리뷰·커밋·병합은 부모
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: sonnet
effort_hint: medium
rationale:
  - 재현 완료(컨테이너), 원인 확정 — 테스트 작성 방식 수정
approved_by_user: true  # "자동모드 켜고 릴리즈까지 이어가" (2026-10-09)

## 범위 연결

plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
