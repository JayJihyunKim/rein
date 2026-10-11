# DoD: 선택기 보안 Low 3건 보강

- 작성일: 2026-10-10
- plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
- 계기: 2026-10-08 선택기 사이클 보안 리뷰(standard PASS)의 Low 3건 후속. index "다음 세션 시작점" 첫 항목.
- 등급(versioning Rule A): 사용자 동작 보강(차단 범위·종료 코드 불변) → patch 후보. 이번 사이클은 dev 반영까지 — 릴리스는 별도.
- 사용자 승인: "작업 이어서 해" (2026-10-10) — index 다음 시작점 첫 항목 진행.

## 범위

IN
1. `plugins/rein-core/scripts/rein-affected-tests.py`
   - pip(venv) 설치 argv 에 `-I` 추가 — 작업 트리의 `pip.py` 등 섀도잉 차단(probe 와 일치).
   - 프로젝트 스크립트 환경에서 `SHELLOPTS`·`BASHOPTS` 제거 — 리뷰 래퍼 사전 검사 환경과 일치.
   - 텍스트 출력 각 줄의 제어 문자(줄바꿈·CR·탭 포함 C0/C1) 치환 — 경로·사유에 섞인 줄바꿈으로 가짜 줄(예: 델타 증거 칸) 주입 차단.
2. `tests/scripts/test-affected-tests.sh` — 세 동작의 회귀 테스트(AT30 argv 기대값 갱신 포함).

OUT
- 래퍼 codex `--sandbox`, commit id 40-hex, `rein job` 개선(별도 사이클). 버전 bump·main 반영.

## 변경 파일

plugins/rein-core/scripts/rein-affected-tests.py
tests/scripts/test-affected-tests.sh

## Definition of Done

- [x] 세 동작의 실패 테스트 먼저 작성 → 수정 후 통과
- [x] 코드 리뷰·보안 리뷰 통과 → 커밋 → dev 병합·push
- [x] 완료 기록·index 갱신

## 검증 기준

- `bash tests/scripts/test-affected-tests.sh` 가 `FAIL: 0`
- AT30 argv 가 `-I -m pip install …`
- SHELLOPTS 로 xtrace 를 켜도 스크립트 stderr 에 추적 출력 없음 / 줄바꿈 든 파일명이 텍스트 출력에서 한 줄로 유지

## 라우팅 추천

agent: rein:feature-builder-fix
orchestration: main-session-orchestrated
worker_strategy: 3줄 수정 + 테스트 — 강등(부모 직접). 리뷰·커밋·병합은 부모
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: sonnet
effort_hint: medium
rationale:
  - 보안 리뷰 Low 지적 그대로 — 원인·수정 위치 확정
approved_by_user: true  # "작업 이어서 해" (2026-10-10)

## 범위 연결

plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
