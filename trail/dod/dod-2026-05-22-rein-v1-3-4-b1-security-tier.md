# DoD — B1 security-tier-skip Tier-1-only 정렬

- 날짜: 2026-05-22
- 유형: fix (security/correctness)
- plan ref: rein-v1.4-improvement-plan.md §5.2 B1 (확정안 §0.5)
- design ref: codex 검증 (2026-05-22) — security skip Tier 1+2 vs coverage self-heal Tier 1 불일치

## 목표 (Why)

`pre-bash-test-commit-gate.sh` 의 security stamp skip 경로(P6)는 `select_active_dod` 결과 Tier 1 **또는** Tier 2 를 모두 수용한다(line 178). 그러나 같은 파일의 coverage marker self-heal 은 Tier 1 만 신뢰한다(line 334). Tier 2 는 `select-active-dod.sh` 정의상 **advisory fallback (non-blocking authority)** 이므로, "security stamp 없이 commit 허용" 같은 **blocking 결정**의 근거로 쓰면 안 된다. `.active-dod` marker 부재 + 최신 mtime DoD 가 우연히 `security_tier: light` 인 경우 Tier 2 로 false-skip 되어 보안 리뷰를 우회할 수 있다.

## 성공 기준 (Acceptance)

1. line 178 의 조건을 `[ "$_sad_tier" = "1" ] && [ -n "$_sad_path" ]` 으로 좁힌다 (Tier 2 제거). 주석(line 176-177)도 "Tier 1 only" 로 갱신.
2. **회귀 테스트 T1**: `.active-dod` marker 부재 + 최신 DoD 가 `security_tier: light` + `approved_by_user: true` 인 상태(Tier 2 fallback)에서 `git commit` 시 **여전히 `.security-reviewed` stamp 를 요구**(차단)하는지 검증.
3. 기존 정상 경로 보존: Tier 1 (`.active-dod` 가 light DoD 를 가리킴) + `approved_by_user: true` 이면 stamp 없이 skip 허용 — 기존 동작 유지 (회귀 없음).
4. `.codex-reviewed` (P5) 는 tier 와 무관하게 항상 요구 — 불변.

## 제외 (Out of scope)

- coverage self-heal 로직(line 334) 변경 — 이미 Tier 1 only, 손대지 않음.
- `select_active_dod` 자체의 tier 판정 로직 변경.
- `security_tier: light` 의미/파싱 변경.

## 리스크

- (R1) Tier 2 를 정당하게 쓰던 경로가 있으면 over-block. → codex 검증 결과 "Tier 2 light skip 은 정당한 blocking 면제 아님" (advisory authority). T1 으로 의도된 차단임을 고정.
- (R2) 테스트 fixture 가 Tier 2 상태를 정확히 재현 못하면 검증 무효. → marker 부재 + 단일 light DoD mtime 으로 Tier 2 강제, select_active_dod 출력으로 tier=2 사전 확인.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix          # 버그 수정 — reproduction-first (failing test 먼저)
skills:
  - rein:codex-review                    # commit gate 필수 (.codex-reviewed)
mcps:
  - serena                               # select_active_dod 호출처/tier 사용처 추적
rationale: >
  security gate 의 tier 일관성 결함 수정. reproduction-first 로 Tier 2 false-skip 을
  failing test(T1) 로 먼저 고정한 뒤 조건을 좁힌다. select_active_dod 사용처 정확
  추적이 핵심이라 serena symbol 분석 유효. 보안 경계(commit gate) 변경이므로
  security_tier 는 standard — 전체 security review 필수.
security_tier: standard  # 보안 게이트 동작 변경 — 전체 security review 필수
approved_by_user: true   # 사용자 위임 (2026-05-22 "나 없이 혼자서 진행해봐") — 확정안 §0.5 스코프
```

## Self-review 예정 항목 (AGENTS.md §6)

- Tier 2 제거가 정상 Tier 1 경로를 깨지 않는가
- `.codex-reviewed` always-required 불변 확인
- T1 이 Tier 2 상태를 실제로 재현하는가 (tier=2 사전 확인)
- shellcheck clean, 매직넘버 없음
