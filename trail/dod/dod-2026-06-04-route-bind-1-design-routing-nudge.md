# DoD — 설계 단계 라우팅 nudge (ROUTE-BIND-1)

- 날짜: 2026-06-04
- 작업 유형: 신규 기능 (provenance claim + 호스트 훅 soft nudge — 설계 단계 라우팅 강제력 부재 보완)
- plan ref: docs/plans/2026-06-04-design-phase-routing-nudge-implementation.md

## 요약

spec/plan 파일이 전용 에이전트(spec-writer/plan-writer)의 provenance claim 없이 인라인으로 써지면, 기존 PostToolUse 호스트 훅(`post-edit-design-plan-coverage-rule.sh`)이 차단 없이 soft nudge(stderr advisory, exit 0)를 emit 한다. 정상 경로(에이전트가 authored write 직전 claim 기록)에서는 claim 을 매칭→소비해 nudge 무발화. presence+consume 모델(timestamp 비교 없음 — 동일초 FN 제거). 매 편집 hot-path 부하 0(비-design 경로는 nudge 코드 미도달).

## 범위 (IN)

- SC-1: provenance 표식 schema·위치·hash 키 확정 (helper `rein-mark-design-provenance.sh` 신규)
- SC-2: 에이전트 claim 작성 단계 (spec-writer·plan-writer authored write 직전)
- SC-3: claim lifecycle presence + consume (freshness 제거)
- SC-4: 호스트 훅 nudge inline (기존 design-plan-coverage 훅, 신규 hooks.json entry 없음)
- SC-5: nudge 발화 채널(stderr)·문구 (response-tone, 내부용어 비노출)
- SC-6: operating-sequence 설계 체인 1줄
- SC-7: 정당 수동 작성 문서화 (opt-out 비범위)
- SC-8: 성능 검증 NFR-1~4 (hot-path 0 증가)
- SC-9: dogfood 실증 (helper-level 시뮬레이션 + 라이브 에이전트-경로)
- SC-10: 회귀 테스트 (paths·consume·동일파일 반복편집)

## 범위 (OUT)

- 하드 게이트 (Option C 기각 — 인라인 작성 차단 안 함, advisory only)
- "항상 nudge" (Option B 기각 — provenance 로 정상 경로 식별)
- brainstorm provenance (스킬이라 전용 에이전트 없음)
- routing-procedure.md post-inject 시점 재설계
- 온보딩/프라이머 (ONBOARD-1 몫)
- path-policy 변형 경로(루트 specs/*.md·중첩 docs/**/specs|plans) 정렬 (SC-8 deferred, 후속 cycle)
- opt-out 메커니즘(.rein/policy suppress) (SC-7 deferred, 후속 cycle)

## 변경 파일

- plugins/rein-core/scripts/rein-mark-design-provenance.sh (신규)
- plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh
- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/agents/plan-writer.md
- plugins/rein-core/rules/operating-sequence.md
- tests/hooks/test-post-edit-design-plan-coverage-rule.sh
- tests/hooks/test-design-provenance-marker.sh (신규)
- tests/hooks/run-all.sh (신규 helper 테스트 등록)
- (검증) tests/hooks/test-hook-hotpath-perf.sh
- hooks.json: 변경 없음 (NFR-4)

## 완료 기준 (검증)

1. SC-1: helper `bash -n` PASS + exec bit 100755 + smoke check (claim 생성·path= 정확 대조)
2. SC-2/SC-3/SC-4/SC-5: 호스트 훅 nudge inline — claim 부재→nudge / claim 존재→무발화+소비. 함수 정의+호출 같은 커밋(미정의 함수 호출 방지). exit 2 절대 안 냄
3. SC-6: operating-sequence 설계 체인 1줄 + 6규칙 inject 토큰 예산 회귀 없음
4. SC-7: 정당 수동 작성 주석 + nudge 괄호절 면책
5. SC-8: NFR-1(비-design 경로 nudge 미도달) / NFR-2(hot-path latency 증가 0) / NFR-3(design 편집 추가분 측정·기록) / NFR-4(hooks.json diff 0)
6. SC-9: dogfood — helper-level claim/consume 시뮬레이션 + 라이브 에이전트 경로 trail 기록
7. SC-10: 회귀 (a)~(g) + (c') 동일파일 반복편집 전부 green. 신규 helper 테스트 run-all.sh 등록 확인
8. `bash tests/hooks/run-all.sh` 전체 PASS
9. codex 코드리뷰 통과 + security 리뷰 통과

## 범위 연결

plan ref: docs/plans/2026-06-04-design-phase-routing-nudge-implementation.md
work unit: Implementation 전체 — Phase 1~5 / 모든 Task
covers: [SC-1, SC-2, SC-3, SC-4, SC-5, SC-6, SC-7, SC-8, SC-9, SC-10]

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:parallel-execute
  - rein:codex-review
mcps: []
security_tier: standard
rationale:
  - 작업 유형 = 신규 기능 (provenance claim 메커니즘 + 호스트 훅 nudge inline + helper 신규). add-feature 키워드 → feature-builder.
  - plan 실행 전략(`## 실행 전략`)의 웨이브를 parallel-execute 로 의존 위상정렬 실행 — step1 host-hook(mutating 단독) → step2 helper+operating-sequence(edit_only 동시) → step3 tests(mutating) → step4 agents(edit_only). 부모가 웨이브 단위 검증·커밋.
  - security_tier standard: advisory-only·비차단·gitignored 캐시 write 이나, 매 편집 hot-path 훅(post-edit-design-plan-coverage-rule.sh)을 건드리고 신규 helper 가 파일시스템 write·python spawn 을 하므로 보수적 standard. 사용자 확인.
  - codex 통합 코드리뷰 (codex Mode A). 설계 체인은 이미 codex PASS (spec R3 / plan R3).
approved_by_user: true
