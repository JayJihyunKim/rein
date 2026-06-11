# DoD — codex-review envelope 모드 정합 (A) + active-DoD marker 청소 모순 수정 (C)

작업일: 2026-06-11
brainstorm ref: docs/brainstorms/2026-06-11-envelope-subject-consistency.md
plan ref: 없음 (bounded fix — brainstorm 에서 설계 결정 종결, spec/plan 체인 생략)

## 범위

### A. envelope confidence/모드 정합 (wrapper 2사본)

`scripts/rein-codex-review.sh` (+ `plugins/rein-core/scripts/rein-codex-review.sh` byte-identical):

- A1. envelope 컨텍스트 블록에 `review_subject:` 필드 명시 (working_tree / commit_range / spec)
- A2. `head_iso` subject-aware 화 — commit_range 에서만 실값, working_tree/spec 은 명시적 N/A (사유 포함)
- A3. spec 모드 `diff_base_iso` 를 일반 `(unavailable)` 대신 명시적 `(N/A: spec review has no commit diff)` 로
- A4. Tier 2 (추측) active DoD 일 때: DoD 유래 설계 context(plan_ref/design_ref/covers/scope_items)에
     advisory 표기 + Design Alignment 지시문의 blocking 언어를 Tier 1 한정으로 게이트.
     Claim Audit 도 Tier 2 컨텍스트를 확정 근거로 쓰지 않도록 한정 (codex 지적 risk).
- A5. evidence freshness 비교 지시문 — 커밋 ref 없는 모드(working_tree/spec)에서 비교 강제 대신 한정/완화

selector(`select-active-dod.sh`)와 차단 게이트 3종은 **무변경** (Option B 기각).

### C. session-start marker 청소 모순 수정 (근본 원인)

`plugins/rein-core/hooks/session-start-load-trail.sh`:

- C1. marker 청소 조건에서 "`## 범위 연결` 섹션 없으면 삭제" 제거 — selector Tier 1 의
     marker-trust 계약(2026-06-09: 섹션 불요)과 정합. containment/존재/archived 조건은 유지.

### D. 작업 중 발견 — fail-soft 가드 SIGPIPE 무력화 (본 사이클 리뷰 게이트 차단 결함)

`scripts/rein-codex-review.sh` (+ plugin 사본). 본 사이클 codex 리뷰 Round 1 이 PASS 였는데도
wrapper 가 종료 3(모델 거부 오인)을 낸 실측에서 발견:

- D1. `_detect_model_error` 의 완료신호 가드(`printf big | grep -q`)가 `pipefail` 아래서
     조기종료 SIGPIPE(141)로 무력화 — 대용량 출력 + 앞부분 verdict 양식 줄(envelope 인용)일 때
     가드가 통째로 skip 되어 본문 인용 에러패턴을 모델 거부로 오인 (재현: rc=141 실측).
     `_parse_verdict` Stage 2 의 동일 패턴 3건 포함, `-q` 제거 + `>/dev/null` 로 전 입력
     소비(조기종료 제거)하여 수정. v1.4.6 가드 도입 시점부터 잠복.
- D2. (Round 2 codex High) 모드 감지부 동일 클래스 — `printf $PROMPT_BODY | head -1 |
     grep -q` 가 대용량 spec 프롬프트에서 SIGPIPE 로 거짓 → spec 리뷰가 code-review 로
     오분류되어 코드 게이트 stamp 를 생성할 수 있던 규율 구멍 (재현 테스트로 stamp 오염
     실측). 첫 줄 추출을 파이프 없는 순수 bash 파라미터 확장으로 교체.

## 변경 파일

- `scripts/rein-codex-review.sh` (A1~A5)
- `plugins/rein-core/scripts/rein-codex-review.sh` (동일 — 2사본 byte-identical 유지)
- `plugins/rein-core/hooks/session-start-load-trail.sh` (C1)
- `tests/skills/test-codex-review-wrapper.sh` 또는 신규 테스트 (A 행동 고정)
- `tests/hooks/` 신규/기존 테스트 (C1 재현 테스트 — 섹션 없는 DoD marker 가 세션 시작에 살아남음)

## 검증 기준

- [x] (TDD) A4/C1 의 failing 재현 테스트 먼저 작성 — red 확인 후 구현 (A 7건 + C 2건 + D1 + D2 모두 red→green)
- [x] A: Tier 2 fixture 에서 envelope 에 advisory 표기 + blocking 설계 지시문 부재, Tier 1 fixture 에서 기존 blocking 유지
- [x] A: spec 모드 envelope 에 review_subject=spec + diff_base_iso 명시 N/A
- [x] A: commit_range 에서만 head_iso 실값
- [x] C: `## 범위 연결` 없는 DoD 를 가리키는 정상 marker 가 세션 시작 청소에서 보존됨 (containment 위반/대상 부재/archived 는 여전히 삭제 — 18/18)
- [x] wrapper 2사본 byte-identical (`cmp`)
- [x] `bash -n` 구문 통과 (wrapper 2사본 + session-start hook)
- [x] 전체 활성 스위트 green (`tests/scripts/run-all.sh`, `tests/hooks/run-all.sh`, `tests/skills/run-all.sh` — wrapper 54/54)
- [x] codex 코드 리뷰 통과 — 3 rounds (R1 PASS / R2 NEEDS-FIX High 1건=D2 / R3 PASS) + 보안 리뷰 PASS
- [x] spec-review 모드 기존 보증(G8-3) 회귀 없음 (해당 테스트 green + D2 로 보증 강화)

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
rationale: 모순/오탐 수정(fix 키워드) 지배 유형. reproduction-first 전략이 A4(Tier 2 승격 오탐)와
  C1(marker 오삭제)의 재현 테스트 선행 요구와 정확히 일치. 파일 수 적고 경계 명확하여
  메인 세션 직접 수행 + 구현 후 rein:codex-review 게이트.
approved_by_user: true
```

## 분류 (버전)

`/codex-review` 사용자 동작(리뷰 오탐 감소) + session-start hook 동작 변경 → **user-facing 버그 수정 = patch** (versioning Rule A). 단 Rule B(하루 1 bump)에 따라 오늘 v1.5.1 이 이미 나갔으므로 main 머지는 다음 근무일 이월 대상.
