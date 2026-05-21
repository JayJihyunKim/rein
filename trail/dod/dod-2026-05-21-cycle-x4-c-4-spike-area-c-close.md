# DoD — Cycle X4.C.4 (SPIKE 측정 + 영역 C 종결 결정)

- 날짜: 2026-05-21
- 유형: research (latency 측정) + docs (SPIKE report + plan/design 갱신) + 조건부 fix (FAIL 시 rollback)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md §8.5 (X4.C.4 sub-step) + §9 Q-1
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C, 마지막 cycle)
- cycle: X4.C.4 — 영역 C 종결 cycle

## 범위 (Scope)

포함:

1. **SPIKE 측정** (design memo §8.5 산출물 1) — fast-path skip 의 latency 개선을 정직하게 실측:
   - `tests/hooks/bench-state-fast-path.sh` (신규) — production 격리 microbenchmark.
   - 측정 대상 (per-hook, before=legacy / after=fast-path):
     - (M1) pre-edit-dod-gate: fast-path probe (state_is_valid + read_effective_mode + dirty match) 비용 vs validator subprocess 비용
     - (M2) post-edit-design-plan-coverage-rule / routing-procedure-rule: state-read probe 비용 (common case 인 source_edit 에서는 skip 안 함 → 순추가 비용인지 검증)
     - (M3) post-edit-spec-review-gate: marker dedup (mtime touch) vs body rewrite 비용
   - N회 반복 + median/min/max 기록. flock 부재(mkdir mutex) 환경 caveat 명시.
   - macOS Darwin (Apple Silicon M5 Pro) 단일 OS — Linux/CI 재측정 권고 caveat 명시 (이전 SPIKE-1 패턴 차용).

2. **Q-1 답변** (design memo §8.5 산출물 2 + §9 Q-1) — `.plan-coverage-dirty` (영역 B layer) 와 `state.json.dirty_files` (영역 C layer) 통합 검토:
   - 두 layer 의 의미/소비자/중복도 분석 (`.plan-coverage-dirty` 는 중복 누적, `dirty_files` 는 path dedup — 관측됨)
   - 통합 / 독립 유지 결정 + 근거를 design memo §9 Q-1 에 기록

3. **영역 C 종결 결정** (design memo §8.5 산출물 3):
   - PASS (개선 측정됨) → 영역 C 종결 mark (master plan §4.3 + §5 + §1 + design memo §8.5)
   - FAIL (개선 미측정 / 회귀) → rollback 또는 §2.3 schema_version disable. **rollback 은 hook 코드 변경 동반 → 사용자 확인 후 진행** (master plan §7 영역 우선순위 변경에 준함)
   - PARTIAL (일부 hook 만 win) → 정직하게 hook 별 결론 기록 + 순손실 hook 의 후속 처리 권고

4. **검토 항목 (b)** — codex 비차단 advisory `state_is_valid`/`read_effective_mode` 2-call TOCTOU:
   - single-writer 모델 하 실질 누출 여부 재확인 + SPIKE 결과와 결합 (2-call 이 latency 기여 시 atomic 결합이 latency+correctness 동시 개선인지)
   - 결론을 design memo 또는 report 에 기록 (코드 변경 시 standard tier)

5. **검토 항목 (c)** — security Info-2: `.claude/security/profile.yaml` `base`→`standard` posture:
   - rein-dev 자체 attack surface (hook path resolution, command classification) 기준으로 base/standard 판정
   - 결정 + 근거 기록. 적용 시 `last_upgraded` + `upgrade_history` 갱신

제외 (별 cycle):

- X3.B.3: post-edit-review-gate dirty source path 본문 append (선택 보강, 영역 B)
- 영역 D: release gate 분리 + v1.3.3 main 머지
- dev → main propagation (영역 series 종결 후, 사용자 승인)

## 작업 기준

1. **정직한 측정** (superpowers:verification-before-completion) — 측정 명령 실제 실행 + raw 출력 기록. fast-path 가 순손실인 hook 이 있으면 숨기지 않고 PARTIAL/FAIL 로 기록. contrast-only 가 아닌 방향+수치 명시.
2. production 격리 — benchmark 는 `tests/` 에만, `tests/fixtures/` 하위에 sandbox state. `.rein/state.json` 실데이터 비파괴 (REIN_PROJECT_DIR_OVERRIDE 사용).
3. 측정 caveat 명시 — 단일 OS / mkdir-mutex (flock 부재) / 단일 release / cold vs warm python.
4. rollback 동반 시 (FAIL) — 사용자 확인 + hook 코드 변경은 standard tier security review.
5. 전 hook test suite 회귀 0 (측정이 hook/lib 본문을 바꾸지 않으면 자명, 바꾸면 재검증).
6. codex Mode A code-review PASS — `.codex-reviewed` stamp (신규 benchmark 스크립트 + 갱신 문서 대상)
7. security-reviewer 판정 — `.security-reviewed` stamp (또는 light tier 면 stamp 면제)
8. inbox + index 갱신 + dev commit (single commit). **push 없음** (영역 series dev-only — memory: project_area_series_dev_only_until_complete)

## 검증 시나리오

- (V1) `bash tests/hooks/bench-state-fast-path.sh` — M1/M2/M3 median latency 표 출력 (실제 실행)
- (V2) `bash tests/hooks/run-all.sh` — ALL SUITES PASSED (회귀 0, 본 cycle 이 hook 본문 미변경이면)
- (V3) `bash tests/hooks/test-state-fast-path-skip.sh` — X4.C.3 4 case 유지 PASS
- (V4) SPIKE report (`docs/reports/2026-05-21-area-c-state-machine-spike.md`) 가 M1~M3 + Q-1 + (b) + (c) + 종결 판정 포함
- (V5) master plan §4.3/§5/§1 + design memo §8.5/§9 가 종결 결정과 동기화 (working agreement §6.3)

## 라우팅 추천

```yaml
agent: direct
skills:
  - superpowers:verification-before-completion
  - rein:codex-review
mcps: []
rationale: |
  SPIKE 측정 + 영역 C 종결 결정 cycle. feature/fix/refactor 가 아닌
  measurement + analysis + decision + docs 성격이라 builder agent 미적합 —
  방법론 통제와 종결 판정이 consequential 하므로 main thread 직접 실행.
  measurement 의 정직성이 핵심이라 verification-before-completion 으로 raw
  출력 실증. 신규 benchmark 스크립트 + 갱신 문서 (+ 조건부 rollback 코드) 는
  codex Mode A 리뷰. Q-1/(b)/(c) 분석은 상호 의존 (2-call 패턴이 latency
  기여하면 (b) atomic 결합이 (M2) 개선이기도 함) → 순차 main-thread 분석.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "X4.C.4 를 스스로 판단해서 진행, 가장 좋은 판단 신뢰" 명시 (오토모드).
  기본은 docs-only (report + plan + design 갱신) 이나, FAIL 시 rollback /
  검토항목 (b) atomic 결합 / (c) security posture 변경이 hook·security 코드를
  건드릴 수 있어 standard tier 로 둔다. rollback 같은 비가역 변경은 별도 사용자
  확인 후 진행.
```

## self-review

- [ ] M1~M3 측정이 실제 실행된 raw 출력 기반인가 (추정/가정 아님)
- [ ] fast-path 가 순손실인 hook 을 정직하게 기록했는가 (PARTIAL/FAIL 은닉 금지)
- [ ] 측정이 `.rein/state.json` 실데이터를 파괴하지 않았는가 (override sandbox)
- [ ] Q-1 결정에 두 layer 의 소비자/중복 의미가 명시됐는가
- [ ] (b) TOCTOU 가 single-writer 모델에서 실질 누출 없음 + SPIKE 와의 연결을 기록했는가
- [ ] (c) base/standard 판정 근거가 rein-dev attack surface 기준인가
- [ ] 종결 결정이 master plan §7 amendment policy 준수 (PASS=상태반영 자유 / rollback=사용자 확인)
- [ ] cycle commit message 가 `chore(spike):` 또는 `docs(plans):` 형식 + scope 점(.) 없음 (memory: feedback_commit_scope_format)
- [ ] push 없음 (dev-only — 영역 series 종결 후 사용자 승인)
