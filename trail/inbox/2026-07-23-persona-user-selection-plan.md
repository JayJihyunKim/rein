# 2026-07-23 — persona user-selection plan 작성 (plan-writer)

Plan complete: docs/plans/2026-07-22-persona-user-selection.md
- Scope IDs: 18 implemented / 0 deferred (spec docs/specs/2026-07-22-persona-user-selection.md)
- Validator: `python3 scripts/rein-validate-coverage-matrix.py plan <plan>` exit 0 (scope-id-version v2)
- Schedule: 4 waves (w1: t1,t3,t4,t7,t9,t10,t11 / w2: t2,t8 / w3: t5,t6 / w4: t12 mutating)
- trail/dod/.coverage-mismatch: 없음
- spec review Low advisory 2건 흡수: (1) v1.5.0 default-ON assert 교체(Task 1.1/2.1/6.2), (2) CLAUDE_PLUGIN_ROOT 미설정 loader 거동 D1 로 확정+테스트(Task 1.1 step 6)

Spec review (plan): NEEDS-FIX
- 1차 시도: codex wrapper 실행이 auto-background 전환 후 hang (CPU 0/네트워크 0) → kill
- 2차 시도: wrapper 소유 watchdog timeout — exit 5 + `ERROR: [codex-review][review-timeout]` anchored 진단행 (300s cap + 2×30s 무성장, effort=high). 계약상 재시도 없이 즉시 대체 리뷰.
- Fallback: general-purpose agent (sonnet), spec-review prefix 보존, 표식 무접촉
- Verdict: NEEDS-FIX — Medium 1 (Task 1.2 가 get_persona() 내 `_validate_persona_name` 호출부 raw-passthrough 교체를 명시하지 않음 — Step 7/Task 3.1 의 전제와 불일치, docstring 도 stale), Low 1 (Task 1.1 RED 목록에 명시 `enabled: false` 케이스 n8 누락)

Stamp: 생성 안 됨 (.spec-reviews pending 유지)
Next (수동 개입 경로):
  (1) author 가 위 2건 plan 반영 (Task 1.2 sub-step 추가 + Task 1.1 n8 추가)
  (2) validator 재실행
  (3) 재리뷰 (codex 복구 시 /codex-review, 불가 시 fallback reviewer) → PASS 시 `rein-mark-spec-reviewed.sh <plan> <reviewer>-sonnet-fallback` 형태로 표식
