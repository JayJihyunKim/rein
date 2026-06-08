# DoD — spec-writer 에이전트 구현

- 날짜: 2026-06-02
- plan ref: docs/plans/2026-06-02-spec-writer-agent-implementation.md
- spec ref: docs/specs/2026-06-02-spec-writer-agent.md (검토 통과)
- brainstorm ref: docs/brainstorms/2026-06-02-spec-writer-agent.md

## 목표

rein plugin 에 brainstorm → spec 단계를 자동화하는 `spec-writer` 에이전트를 추가한다. plan-writer 와 대칭(작성 + 자동 codex-review + 표식, self-fix 없음). 라우팅 2곳에 'spec 작성' 진입점 추가 + 회귀 테스트로 계약 잠금.

## 완료 기준 (acceptance)

1. `plugins/rein-core/agents/spec-writer.md` 신규 — SW-1~SW-4, SW-8 계약 본문 포함 (brainstorm 입력 / `docs/specs/` 산출 / `spec review for design:` prefix / plugin-root 표식 경로 / validator·self-fix 부재 / 평문 보고).
2. `routing-map.md` 에 'spec 작성' 행 추가 + ≤800B 회귀 통과 (`test-routing-map-emit.sh`).
3. `routing-procedure.md` baseline 표에 'spec 작성' 행 추가.
4. `tests/agents/test-spec-writer-auto-review-contract.sh` 신규 6 assertion PASS + `run-all.sh` 등재 (ALL SUITES PASSED).
5. `rein-check-plugin-drift.py` 정합성 통과 (신규 에이전트 + 수정 규칙 SSOT 일치).
6. 자동 리뷰 경로가 코드리뷰 게이트(`.codex-reviewed`) 미오염 (stamp 분리) — 본문 명시.
7. 통합 코드/보안 리뷰 1회 통과 후 커밋.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:parallel-execute   # plan 의 v2 실행 전략(웨이브) 기반 edit_only worker 병렬 dispatch
  - rein:codex-review       # 전체 변경분 통합 리뷰 (push/완료 전 1회)
mcps: []
security_tier: light        # markdown + bash 테스트, secret/auth/network 표면 없음
rationale: >
  신규 에이전트 추가(새 기능)이므로 feature-builder. plan 이 파일소유권 기준
  웨이브 병렬 전략(4개 edit_only disjoint + 1개 의존)을 이미 산출했으므로
  parallel-execute 로 첫 웨이브를 병렬 실행하고 부모가 웨이브 단위 검증·커밋.
  변경이 문서·테스트라 보안 표면이 낮아 light tier.
approved_by_user: true
```

## 변경 파일

- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/rules/routing-map.md
- plugins/rein-core/rules/routing-procedure.md
- tests/agents/test-spec-writer-auto-review-contract.sh
- tests/agents/run-all.sh
