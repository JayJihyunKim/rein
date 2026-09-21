# DoD: 메인 세션 지휘 기본화 구현 3/4 — 워커 2단계 (세션 시작 배선 + 이 저장소에서 기능 켜기)

- 작성일: 2026-09-21 (작업 시작일)
- 사용자 지시: "푸시하고 바로 구현 들어가" (2026-09-21)
- 이 작업 기록은 계획의 네 커밋 단위 중 **세 번째만** 가리킨다. 앞 두 단위는 dev `57837de`, `7033d2c` 로 커밋됨.

## 범위 연결

plan ref: docs/plans/2026-09-21-orchestrator-first-default.md
work unit: Phase 2 / Task 2.1
covers: [OFD-INJECT-1, OFD-GUARD-1]

## 범위

IN — 계획 Task 2.1 (`inject-wiring`, 단독 워커)

- `plugins/rein-core/hooks/session-start-rules.sh`: 저장소 opt-in 플래그가 켜졌을 때만 지휘 규칙 요약을 작업 순서 규칙과 라우팅 표 사이에 주입. 플래그 읽기 실패·로더 부재·"true" 이외의 모든 답은 꺼짐(fail-closed). 기존 규칙 6종 for 줄 리터럴은 그대로 두고 루프 본문을 함수로 뽑는다. 헤더 주석의 규칙 수·크기 서술 갱신.
- 신규 `tests/hooks/test-orchestrator-first-emit.sh`: 꺼짐(파일 없음 / 깨진 파일) → 마커 없음, 켜짐 → 마커가 제자리 + 요약 파일 1,000B 이하 + 훅이 내보내는 JSON 한 줄이 1만 자 미만.
- `tests/hooks/run-all.sh`: 새 테스트 두 개(`test-policy-rules-enabled-flag.sh`, `test-orchestrator-first-emit.sh`) 등록.
- `.rein/policy/rules.yaml`: 이 저장소에서 기능 켜기 (`orchestrator-first: {enabled: true}`).
- `.claude/agents/` 가 생기지 않았는지 확인.

OUT

- 8월 잠긴 설계 문서 주석(4/4 — 이 커밋 뒤 메인 세션이 직접)
- `tests/scripts/test-ups1-short-rule-injection.sh` 의 기존 실패(페르소나 요약 상한) — 무변경, for 줄 리터럴만 grep 으로 확인
- 배포본 기본값 전환, 새 절차·검사·훅, 설계 §8 의 분리된 후속 항목

## Definition of Done

- [x] 워커 완료 반환, 변경 경로가 선언한 쓰기 범위 4개 파일의 부분집합 (시작 시점 기준선 대비)
- [x] 계획 Task 2.1 의 확인 명령 + close-out 의 웨이브 2 확인(이 저장소에서 실제로 켜졌는지, 1만 자 미만) 통과
- [x] 스테이징 → 코드 리뷰 + 보안 리뷰 통과 → 커밋 1개

## 검증 기준

- `bash tests/hooks/test-orchestrator-first-emit.sh` → 통과 (꺼짐 두 경우 마커 없음, 켜짐 마커 제자리 + JSON 줄 < 10,000자)
- `bash tests/hooks/test-policy-rules-override.sh`, `bash tests/hooks/test-session-start-rules.sh`, `bash tests/hooks/test-routing-map-emit.sh` → 회귀 없음
- `grep -c "for RULE in code-style security testing operating-sequence routing-map response-tone" plugins/rein-core/hooks/session-start-rules.sh` → 1
- 이 저장소에서 훅 실행 → 출력 길이 < 10000 이고 지휘 규칙 마커 포함 (계획 close-out 의 명령)
- `git status --porcelain -- .claude/agents | wc -l` → 0, `bash tests/scripts/test-plugin-agents-bundle.sh` → 통과
- `bash -n plugins/rein-core/hooks/session-start-rules.sh`

## 라우팅 추천

agent: rein:feature-builder-worker
skills:
  - rein:parallel-execute
  - rein:codex-review
mcps: []
security_tier: standard      # 세션 시작 훅의 조건 분기 — 새 기본 동작을 켜는 스위치의 호출부
complexity: low
model_hint: opus
effort_hint: medium
rationale:
  - 계획의 실행 전략 2단계 = 편집 전용 단독 워커
  - 실행 중인 훅 소스를 고치고 fail-closed 분기를 넣는 안전 민감 변경 → 워커 모델은 세션 모델 그대로 (지휘자 판단)
  - 웨이브 끝 리뷰는 codex-review, 보안 리뷰는 rein:security-reviewer — 부모 소유, 스테이징 후 호출
approved_by_user: true  # 사용자 지시 "푸시하고 바로 구현 들어가" (2026-09-21) — 계획이 정한 실행 방식 그대로

## 변경 파일

- plugins/rein-core/hooks/session-start-rules.sh
- tests/hooks/test-orchestrator-first-emit.sh
- tests/hooks/run-all.sh
- .rein/policy/rules.yaml
- trail/inbox/2026-09-21-orchestrator-first-wave2.md
- trail/index.md
- trail/incidents/blocks.jsonl
