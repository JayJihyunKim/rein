# G3 Phase 1 — route-time layer (routing-map rule + emit list)

- 날짜: 2026-05-27
- 유형: feature (route-time advisory)
- plan ref: docs/plans/2026-05-27-g3-execution-mode-advisor.md (Phase 1 / Task 1.1 + 1.2 + 회귀 4.2)
- spec ref: docs/specs/2026-05-27-g3-execution-mode-advisor.md (Scope ID G3-RM)
- 선행 commit: dev `1da7c9e` (G3 cycle completion docs)

## 범위

본 DoD 는 plan 의 **Phase 1 + Phase 4 Task 4.2** 만 실행. SessionStart 첫 turn 에 `routing-map.md` 본문이 additionalContext 로 emit 되도록 한다. Phase 2~4 (run-time meta-check, DoD anchor obligation, 잔여 회귀) 는 본 DoD 범위 외 — 별 DoD 에서 sequential 진행.

## 변경 파일

- `plugins/rein-core/rules/routing-map.md` (신규, ≤ 800B uncompressed)
- `plugins/rein-core/hooks/session-start-rules.sh` (line 41 for-loop 리스트에 `routing-map` 1단어 append)
- `tests/hooks/test-routing-map-emit.sh` (신규)
- `trail/dod/dod-2026-05-27-g3-phase1-route-time.md` (본 DoD)
- `trail/inbox/2026-05-27-g3-phase1-route-time.md` (완료 시점 신규)
- `trail/index.md` (세션 종료 직전 갱신)

## 검증 기준

1. `routing-map.md` 본문 ≤ 800B (`wc -c` 직접 확인)
2. `session-start-rules.sh:41` for-loop 가 `code-style security testing operating-sequence routing-map` 순서로 5 rule emit
3. `bash tests/hooks/test-routing-map-emit.sh` PASS — assertion 3개:
   - additionalContext 안에 `routing-map.md` substring (`> 상세: plugins/rein-core/rules/routing-procedure.md`) 검출
   - emit 순서: `code-style` 본문이 `routing-map` 본문보다 앞
   - routing-map.md 단독 byte count ≤ 800B
4. 기존 `bash tests/hooks/test-session-start-rules.sh` 회귀 PASS (4 rule → 5 rule 확장 후에도 happy-path + graceful-degrade 무영향)
5. `python3 scripts/rein-check-plugin-drift.py` drift 0 (또는 routing-map.md 신규 외 의도된 drift 만)
6. commit message: `feat(rules): ...` + `feat(hooks): ...` + `test(hooks): ...` 형식. scope 에 점/숫자 prefix 없음

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  plugin SSOT 안의 신규 rule md (정적 markdown) + bash for-loop 의 1단어 추가 + 신규 bash 테스트.
  외부 입력 / 비밀정보 / 명령 주입 / 경로 traversal 표면 모두 부재. 변경 surface 전부
  plugin source tree (CLAUDE_PLUGIN_ROOT) 내부. security review light tier 적정 (P9 / SEC-2 와
  일관). Phase 1 sequential 진행 (Phase 2~4 별 DoD).
