# DoD: 영향받는 테스트 자동 선택 + 정밀 도구 자동 설치 + 리뷰 전 프로젝트 사전 검사

- 작성일: 2026-10-08
- plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
- 사용자 지시: "응 그렇게 진행해. 자동모드 켜고 설계하고 개발까지 완료해" (2026-10-08). 범위는 직전 대화에서 합의 — (1) 자동 대상 테스트 선택(프로젝트 스크립트 → 정밀 도구 → import 검색 → 전체 실행), (2) 정밀 도구 자동 설치(사용자 결정: "없으면 자동으로 설치를 하게하는게 좋겠다"), (3) 리뷰 전 프로젝트 사전 검사.
- spec 검토 종결(2026-10-08): codex 5회차 상한 도달(High 1·Medium 3 남음) → 작성자가 보수적 방식(사용자 정의 테스트 판별 설정이 있으면 full)과 단순 정정 3건 반영 후 **사용자 직접 승인**("고친 뒤 직접 승인"). 표식 `user-approved-skip-review`.
- plan 검토 종결(2026-10-08): codex plan 검토 5회차 상한 도달(High 2 남음 — 미차단 3지점, 런타임 경로 예외의 계약 우회) → 미차단 3지점에 성공 단언·중단 분기 추가, 런타임 경로 예외 제거(기존 계약 복귀 — 워커 구간 `trail/` 변화도 선언 밖이면 멈추고 보고, plan "알려진 운영 위험" 절) 반영 후 **사용자 직접 승인**("고친 뒤 직접 승인"). 표식 `user-approved-skip-review`.
- spec 재편집 승인(2026-10-09): 구현 코드 리뷰 1~3회차 High 반영으로 D23(트리 전체 검사·추출 실행, 셸 시작 환경 제거, TARGET 환경 변수, escape-aware 리터럴) 추가 — spec 검토 회차 상한(5/5) 상태라 사용자 직접 승인("직접 승인"). 표식 `user-approved-skip-review`.
- spec 갱신 위임(2026-10-10): 사용자 "이번 사이클 동안 위임" — 이 사이클에서 spec 을 이미 구현·리뷰된 동작에 맞추는 갱신은 작성자가 `user-approved-skip-review` 표식을 남길 수 있다(새 결정·범위 변경은 계속 사용자 확인). 첫 적용: §3.4 SKILL 초안 실행·환경 변수 줄, 줄 끝 공백.
- push·릴리스 승인(2026-10-08): 사용자 "자동모드 켜고 릴리즈까지 이어가" — plan 의 "완료 기록 뒤 별도 절차(push)" 의 승인 발화. 릴리스(버전 bump·main·태그)는 이 DoD 완료 뒤 별도 릴리스 기준서로.
- 근거: `docs/reports/[issues]_2026-10-07.md`. v2.3.0 이 델타 증거(대상 테스트만 실행)를 허용했지만 대상 테스트를 고르는 일은 에이전트의 눈대중이다 — 잘못 고르면 리뷰어가 "매핑 불명확" 으로 회차를 소모한다. 보고서의 Medium 4건 중 3건은 정적 패턴(fd 미닫힘·`ignore_errors=True`·출력 식별자)이라 외부 리뷰 전에 걸러질 수 있었다.

## 범위

IN
1. 신규 `plugins/rein-core/scripts/rein-affected-tests.py` — 바뀐 파일(기준 대비) → 돌릴 테스트 + 실행 명령 + 선택 방법 + 전체 실행 필요 여부·사유를 JSON/텍스트로 출력. 단계: 프로젝트 스크립트(`.rein/affected-tests.sh`) → 정밀 도구(jest `--findRelatedTests`, vitest `related`, pytest-testmon) → rein 내장 import 검색(2단계 추적) → 전체 실행. 전체 실행 복귀 조건은 v2.3.0 델타 증거 규칙과 같다.
2. 같은 스크립트의 정밀 도구 자동 설치 — 파이썬 프로젝트에서 testmon 이 없으면 감지한 패키지 관리자(poetry/uv/pip+requirements-dev)로 개발용 의존성 설치. 대상 패키지는 고정 목록(`pytest-testmon`)만. 저장소당 1회(결과 기록 `.rein/state/test-tools.json`, 원자적 쓰기·심볼릭 링크 거부), 실패 시 import 검색으로 내려감, `.rein/policy/test-selection.yaml` 의 `auto_install_test_tools: false` 로 끔 — 정책은 기존 `rein-policy-loader.py` 에 조회 모드를 추가해 읽는다(persona·meta-check 와 같은 패턴). 설치 위치는 프로젝트 환경(poetry/uv 의 프로젝트 venv, pip 은 활성 venv)뿐 — venv 없이 시스템 파이썬이면 설치하지 않는다. 버전 범위 고정(`pytest-testmon>=2,<3`), 사용자 지정 인덱스 인자 없음. 설치한 회차는 전체 실행 필요로 보고(의존성 변경 + testmon 기준 생성).
3. 리뷰 래퍼(`plugins/rein-core/scripts/rein-codex-review.sh` + 루트 사본) — 코드 리뷰 모드에서 codex 호출 전에 `.rein/review-precheck.sh` 가 있으면 실행, 실패하면 `[readiness-reject]` exit 4(회차·비용 미소모). 파일 없으면 동작 불변. 저장소 안의 일반 파일만(심볼릭 링크 거부), 시간 제한 있음.
4. `plugins/rein-core/skills/codex-review/SKILL.md` — 대상 테스트 선택 도구 사용법, 델타 증거에 선택 방법 칸, 사전 검사 훅 계약. 래퍼 봉투 sub-item 8 에 선택 방법 판정 한 줄.
5. 테스트 — 대상 선택·자동 설치(가짜 패키지 관리자)·정책 끄기·전체 실행 복귀, 사전 검사 훅(실패→exit 4·codex 미호출 / 통과 / 부재 / 심볼릭 링크 거부). 골든 재생성.
6. CHANGELOG Unreleased(user-facing).

OUT
- 릴리스(버전 bump·main·태그) — 별도 지시.
- `rein job` 중복 거부·진행률 보고 — 이번 범위 아님(대화에서 제외).
- testmon 외 패키지 자동 설치, JS 도구 설치.
- 사전 검사 항목 자체(프로젝트 몫) — rein 은 연결만.

## Definition of Done

- [ ] 설계(brainstorm → spec → plan) 작성·검토 통과
- [ ] IN 1~6 구현 + 신규 테스트 red→green
- [ ] 다섯 러너 실패 집합이 기준선과 동일
- [ ] 웨이브마다 코드 리뷰 + 보안 리뷰 통과 → 커밋 → dev 로컬 병합 + 병합 뒤 회귀 비교 + 완료 기록·index (push 승인 요청과 push 는 완료 기록 뒤 별도 절차 — 이 DoD 완료 판정 밖)
- [ ] 완료 기록 + index 갱신

## 검증 기준

- `python3 plugins/rein-core/scripts/rein-affected-tests.py --help` exit 0
- 신규 테스트 `tests/scripts/test-affected-tests.sh`·`tests/skills/test-review-precheck-hook.sh` 통과, base 에서 실패
- `bash tests/skills/test-review-doc-mode-slots.sh` DM8 골든 일치, `cmp scripts/rein-codex-review.sh plugins/rein-core/scripts/rein-codex-review.sh`
- 다섯 러너(`tests/{hooks,rules,agents,skills,scripts}/run-all.sh`) 실패 집합 기준선 동일, `python3 scripts/rein-check-plugin-drift.py` exit 0
- 세션 시작 훅 출력 10000자 미만(`tests/hooks/test-orchestrator-first-emit.sh`) — 요약 파일은 건드리지 않는다

## 라우팅 추천

agent: rein:feature-builder
orchestration: main-session-orchestrated
worker_strategy: parallel-execute 웨이브 3개·워커 8개 — 웨이브 1 edit_only 6개 병렬(선택기·선택기 테스트·정책 로더·래퍼 사전 검사·사전 검사 테스트·SKILL+CHANGELOG), 웨이브 2 edit_only 1개(동기화 검사 갱신·skills 러너), 웨이브 3 mutating 1개(골든 재생성). 부모는 검증·테스트·리뷰·보안 발급·커밋·병합만
skills:
  - rein:codex-review
mcps: []
security_tier: deep      # 패키지 설치 명령 실행 + 프로젝트 스크립트 실행 = 코드 실행·공급망 경계
complexity: high
model_hint: sonnet
effort_hint: high
rationale:
  - 새 실행 경로 2개(설치 명령, 프로젝트 스크립트) → 보안 검토 깊게
  - 파일 소유권이 분리되는 3묶음 → 병렬 위임
approved_by_user: true  # "응 그렇게 진행해. 자동모드 켜고 설계하고 개발까지 완료해" (2026-10-08)

## 범위 연결

plan ref: docs/plans/2026-10-08-affected-tests-and-precheck.md
work unit: Phase 0 · Phase 1 · Phase 2 · 부모 웨이브 close-out · Phase 3 · Phase 4
covers: [ATP-SEL-CLI, ATP-SEL-ORDER, ATP-SEL-SCRIPT, ATP-SEL-DYNAMIC, ATP-SEL-DISCOVERY, ATP-SEL-TOOLS, ATP-SEL-IMPORT, ATP-SEL-SHARED, ATP-SEL-FULL, ATP-SEL-BUDGET, ATP-INSTALL, ATP-INSTALL-GUARD, ATP-STATE, ATP-POLICY, ATP-PRECHECK, ATP-PRECHECK-TRUST, ATP-PRECHECK-TIMEOUT, ATP-PRECHECK-NOOP, ATP-SKILL, ATP-ENVELOPE, ATP-SYNC, ATP-GOLDEN, ATP-TESTS, ATP-CHANGELOG, ATP-UNCHANGED]

## 변경 파일

- plugins/rein-core/scripts/rein-affected-tests.py
- plugins/rein-core/scripts/rein-policy-loader.py
- scripts/rein-policy-loader.py
- tests/skills/test-codex-review-delta-evidence.sh
- tests/scripts/test-policy-loader-test-selection.sh
- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- plugins/rein-core/skills/codex-review/SKILL.md
- CHANGELOG.md
- tests/scripts/test-affected-tests.sh
- tests/scripts/run-all.sh
- tests/skills/test-review-precheck-hook.sh
- tests/skills/run-all.sh
- tests/fixtures/envelope-code-review.golden
- docs/brainstorms/2026-10-08-affected-tests-and-precheck.md
- docs/specs/2026-10-08-affected-tests-and-precheck.md
- docs/plans/2026-10-08-affected-tests-and-precheck.md
- trail/inbox/2026-10-08-affected-tests-and-precheck.md
- trail/index.md
