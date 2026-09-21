# DoD: 메인 세션 지휘 기본화 구현 2/4 — 워커 병렬 1단계 (플래그 읽기 · 규칙 쌍 · 교차 참조 · 지휘자 에이전트 재정의)

- 작성일: 2026-09-21 (작업 시작일)
- 사용자 지시: "푸시하고 바로 구현 들어가" (2026-09-21)
- 이 작업 기록은 계획의 네 커밋 단위 중 **두 번째만** 가리킨다. 선행 단위는 dev `57837de` 로 커밋됨.

## 범위 연결

plan ref: docs/plans/2026-09-21-orchestrator-first-default.md
work unit: Phase 1 (Task 1.1 ~ 1.4)
covers: [OFD-FLAG-1, OFD-RULE-1, OFD-SCOPE-1, OFD-WORKER-1, OFD-OBS-1, OFD-ROUTE-1, OFD-OPSEQ-1, OFD-DOD-1, OFD-AGENT-1, OFD-TEST-1, OFD-TEST-2]

## 범위

IN — 계획 Phase 1 의 네 태스크를 같은 작업 트리에서 워커 4개로 동시에 실행하고, 메인 세션이 끝에서 한 번에 점검·테스트·리뷰·커밋한다.

- Task 1.1 `flag-loader`: 저장소별 opt-in 플래그 읽기 함수 + CLI 모드, 미러 동기화, 신규 테스트 (fail-closed 3경우)
- Task 1.2 `rule-pair`: 지휘 규칙 전체 본문 + 세션 시작 주입용 요약(1,000B 이하) 신설
- Task 1.3 `cross-refs`: 라우팅 표 각주 + 상한 900→1100(두 테스트 동시), 작업 시퀀스 표 Step 4 셀, 라우팅 절차 §6 의 신규 필드 2개 + 경계표
- Task 1.4 `asset-redefine`: 지휘자 에이전트 정의 두 지점(frontmatter description · depth-rule 서문)만, 강등 테스트 docstring 만

OUT

- 세션 시작 훅 배선·이 저장소에서 기능 켜기(3/4), 8월 잠긴 설계 문서 주석(4/4)
- `plugins/rein-core/rein/orchestration/` 5개 모듈, 지휘자 에이전트 정의의 다른 anchor, 작업 시퀀스 요약 파일, `test_prompt_contract.py` — 무변경
- 설계 §8 의 분리된 후속 항목, 새 절차·검사·훅

## 계획 대비 이탈 (부모가 웨이브 끝 점검에서 추가)

- `tests/agents/test-plan-path-consistency.sh`: 라우팅 표 크기 상한이 설계·계획이 적은 두 테스트 말고 이 테스트에도 800B 로 걸려 있었다(CI 목록에 포함). 각주 추가로 939B 가 되어 실패 → 설계 §3.4 가 이미 정한 상한 1100B 를 이 세 번째 곳에도 같은 값으로 맞췄다(새 임계값 아님, 세 곳 lockstep 주석 추가). 워커 쓰기 범위 밖이라 워커 점검 통과 뒤 부모가 직접 편집. 계획 문서는 고치지 않는다(검토 통과 표식 유지) — 이 기록과 완료 기록에 남긴다.
- 워커 산출물 문구 다듬기 2곳(부모): `routing-procedure.md` 경계표의 "결정 3·4" 참조(배포되지 않는 설계 문서의 번호)를 기존 정보성 필드와의 비교로 교체, 강등 테스트 docstring 의 "spec §3.8" 을 설계 문서 경로로 명시.

## Definition of Done

- [x] 워커 4개 전부 완료 반환, 변경 경로가 선언한 쓰기 범위 12개 파일의 부분집합 (시작 시점 기준선 대비)
- [x] 계획 Task 1.1~1.4 의 확인 명령 전부 통과
- [x] 계획 close-out 의 웨이브 1 테스트 목록 회귀 없음
- [x] 코드 리뷰 + 보안 리뷰 통과 → 커밋 1개

## 검증 기준

- `bash tests/hooks/test-policy-rules-enabled-flag.sh`, `bash tests/hooks/test-policy-rules-override.sh`, `bash tests/scripts/test-plugin-scripts-bundle.sh`, `bash tests/scripts/test-routing-map-projection.sh`, `bash tests/hooks/test-routing-map-emit.sh`, `bash tests/scripts/test-feature-builder-variants.sh` → 전부 통과
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/rein-check-plugin-drift.py` → exit 0
- `python3 -m pytest -p no:cacheprovider plugins/rein-core/tests/orchestration/test_prompt_contract.py -q` → 30 passed, `… test_dispatch_degradation.py -q` → 35 passed
- `cmp plugins/rein-core/scripts/rein-policy-loader.py scripts/rein-policy-loader.py` → 동일
- `git diff --stat HEAD -- plugins/rein-core/rein/orchestration plugins/rein-core/rules/short/operating-sequence-summary.md plugins/rein-core/tests/orchestration/test_prompt_contract.py` → 출력 없음

## 라우팅 추천

agent: rein:feature-builder-worker
skills:
  - rein:parallel-execute
  - rein:codex-review
mcps: []
security_tier: standard      # 정책 로더(파이썬)·테스트·규칙 문서 — 신규 인터페이스(CLI 모드) 추가
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 계획의 실행 전략이 편집 전용 태스크 4개를 1단계 동시 실행으로 선언 → 병렬 실행 스킬 + 편집 전용 워커
  - 규칙 본문을 쓰는 `rule-pair` 는 계약 문안 판단이 필요해 세션 모델 그대로, 나머지 셋은 범위가 명확해 가벼운 모델 (지휘자 판단)
  - 웨이브 끝 리뷰는 codex-review, 보안 리뷰는 rein:security-reviewer — 부모 소유
approved_by_user: true  # 사용자 지시 "푸시하고 바로 구현 들어가" (2026-09-21) — 계획이 정한 실행 방식 그대로

## 변경 파일

- plugins/rein-core/scripts/rein-policy-loader.py
- scripts/rein-policy-loader.py
- tests/hooks/test-policy-rules-enabled-flag.sh
- plugins/rein-core/rules/orchestrator-first.md
- plugins/rein-core/rules/short/orchestrator-first-summary.md
- plugins/rein-core/rules/routing-map.md
- plugins/rein-core/rules/operating-sequence.md
- plugins/rein-core/rules/routing-procedure.md
- tests/scripts/test-routing-map-projection.sh
- tests/hooks/test-routing-map-emit.sh
- plugins/rein-core/agents/orchestrator.md
- plugins/rein-core/tests/orchestration/test_dispatch_degradation.py
- tests/agents/test-plan-path-consistency.sh
- trail/inbox/2026-09-21-orchestrator-first-wave1.md
- trail/index.md
