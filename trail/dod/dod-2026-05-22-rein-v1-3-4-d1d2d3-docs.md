# DoD — D1+D2+D3 포지셔닝 문서화

- 날짜: 2026-05-22
- 유형: docs
- plan ref: rein-v1.4-improvement-plan.md §5.1 D1/D2/D3 (확정안 §0.5)
- design ref: 확정안 §0 포지셔닝 ("policy-governed engineering agent")

## 목표 (Why)

코드 변경 없이 포지셔닝을 강화. "Claude Code workflows vs Rein" 비교 + 아키텍처/정책 모델 개념 문서로 신규 유입자가 Rein 의 차별점을 60초 안에 이해.

## 성공 기준 (Acceptance)

1. **D1**: `README.md` + `README.ko.md` 양쪽에 "How Rein differs from Claude Code workflows" 비교 섹션 추가 (KR/EN parity — readme-style.md §5).
2. **D2**: `docs/architecture.md` 신설 — hook lifecycle diagram (SessionStart→...→Stop).
3. **D3**: `docs/policy-model.md` 신설 — governance layer 개념 ("every failure becomes a rule").
4. readme-style.md 자가검증: 오프너 mechanism 언어 회피, 기존 포지션과 충돌 없음.

## 제외 (Out of scope)

- 코드/hook 변경 일체.
- README 의 다른 섹션 재작성 (비교 섹션 추가만).
- 선언형 정책 엔진(v1.6) 의 실제 YAML 스펙 — 개념만 D3 에 언급.

## 리스크

- (R1) KR/EN parity drift. → 양쪽 동시 추가 + 동일 구조.
- (R2) 신규 docs(architecture/policy-model)의 main include 여부 미결 → merge 시점 branch-strategy 결정 (본 cycle dev 누적).

## 라우팅 추천

```yaml
agent: rein:docs-writer
skills:
  - rein:codex-review
mcps: []
rationale: >
  순수 문서화 → docs-writer 적합. 코드 변경 0 이라 MCP 불요. security_tier light
  (문서만, 보안 경계 무관). codex-review 는 commit gate 필수.
security_tier: light
approved_by_user: true   # 사용자 위임 (2026-05-22) — 확정안 §0.5 스코프
```

## Self-review 예정 항목 (AGENTS.md §6)

- KR/EN parity 유지되는가
- mechanism 언어 과다 아닌가 (readme-style §1)
- 신규 docs main include 결정을 merge 체크리스트에 남겼는가
