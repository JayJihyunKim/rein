# DoD — 신규 설치 첫 세션 온보딩 (ONBOARD-1)

- 날짜: 2026-06-05
- plan ref: docs/plans/2026-06-05-onboarding-first-session-primer.md
- design ref: docs/specs/2026-06-05-onboarding-first-session-primer.md (검토 통과)
- brainstorm ref: docs/brainstorms/2026-06-05-onboarding-first-session-primer.md

## 목표

신규 설치 첫 세션에서 rein 핵심 흐름(작업 기준서 → 사용자 승인 → 리뷰 완료 표시)을 막히기 전에 두 채널(사용자 stdout + 에이전트 additionalContext)로 1회 안내하고, 핵심 3 게이트 차단 메시지를 "이유 + 다음 2단계" teach-forward 로 보강해 게이트당 왕복을 줄인다. Option A(첫 세션 프라이머) + Option C(핵심 게이트 teach-forward)만, 핵심 범위.

## 완료 기준 (acceptance)

1. 마커 helper `hooks/lib/onboarded-check.sh` 신규(`rein_is_onboarded`/`rein_mark_onboarded`, `rein_primer_body`) + `.gitignore` 에 `/.rein/.onboarded` 추가. (SCOPE-MARKER)
2. 첫 세션(마커 부재) → 두 채널 프라이머 1회 emit: bootstrap stdout(읽기만) + rules additionalContext prepend. 단일 writer = rules. (SCOPE-EMIT-CHANNELS/SINGLE-WRITER/FIRST-SESSION-DETECT)
3. rc=0 기존 사용자 backfill: 마커 부재면 1회 emit 후 무발화. (SCOPE-BACKFILL)
4. 프라이머 = 1문단 + 3 흐름 + "막히는 건 정상", 내부용어 비노출. (SCOPE-PRIMER-COPY)
5. 핵심 3 게이트(DoD 부재/라우팅 승인/미리뷰 설계) 차단 메시지에 "이유 + 다음 2단계" + 라우팅 승인 메시지에 형식 힌트(regex 정합). 차단 조건·exit 2 불변. (SCOPE-GATE-*/HINT-COPY)
6. 회귀 테스트 신규 2파일 + run-all 등록: 첫/둘째 세션·두 채널·SessionStart 순서 단언·backfill·게이트 next-step·형식 힌트 regex 정합. (SCOPE-TEST-*)
7. hot-path 0 (프라이머 SessionStart 1회 + 차단 시만). (SCOPE-PERF)
8. 통합 코드 리뷰 + 보안 리뷰 1회 통과 후 커밋.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:parallel-execute   # plan 의 v2 실행 전략(primer-bundle/teach-forward/tests) 기반
  - rein:codex-review       # 전체 변경분 통합 리뷰 (완료 전 1회)
mcps: []
security_tier: standard     # 거버넌스 훅(session-start, pre-edit-dod-gate) + 마커 파일 write 신규 로직 — fail-safe 로 보안 리뷰 1회
rationale: >
  첫 세션 온보딩 프라이머(신규 기능) 추가이므로 feature-builder. plan 이 파일소유권
  기준 3 task(primer-bundle mutating / teach-forward edit_only / tests 의존)를
  산출했으나 primer-bundle 이 mutating 이라 실제 스케줄은 순차. parallel-execute 로
  실행 전략을 태우고 부모가 웨이브 단위 검증·테스트·커밋. secret/auth/network 표면은
  없으나 세션 거버넌스 훅을 만지므로 standard tier 로 보안 리뷰 1회(spec NFR 의 light
  보다 보수적 — gate-touching 변경).
approved_by_user: true
```

## 변경 파일

- plugins/rein-core/hooks/lib/onboarded-check.sh (신규)
- plugins/rein-core/hooks/session-start-bootstrap.sh
- plugins/rein-core/hooks/session-start-rules.sh
- plugins/rein-core/hooks/pre-edit-dod-gate.sh
- .gitignore
- tests/hooks/test-onboarding-primer.sh (신규)
- tests/hooks/test-teach-forward-gates.sh (신규)
- tests/hooks/run-all.sh
