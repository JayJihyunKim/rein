# G3 Phase 2-4 — run-time meta-check + DoD anchor obligation + 회귀

- 날짜: 2026-05-27
- 유형: feature (run-time advisory + agent description + 회귀)
- plan ref: docs/plans/2026-05-27-g3-execution-mode-advisor.md (Phase 2 / Phase 3 / Phase 4 Task 4.1+4.3+4.4+4.5+4.6 — 4.2 는 별 DoD Phase 1 에서 완료)
- spec ref: docs/specs/2026-05-27-g3-execution-mode-advisor.md (Scope ID 8개: G3-MC-FASTPATH, G3-MC-NO-ACTIVE-DOD, G3-MC-POLICY, G3-MC-DOD-MISSING-HINT, G3-MC-DETECT, G3-MC-ADVISORY, G3-MC-INBOX, G3-DOD-TEMPLATE-CHANGED-FILES-SECTION)
- 선행 DoD: trail/dod/dod-2026-05-27-g3-phase1-route-time.md (G3-RM, Phase 1, working tree)

## 범위

본 DoD 는 G3 spec 의 9 Scope ID 중 Phase 1 제외 **8개** 를 구현 + 회귀. Phase 1 (G3-RM, route-time) 은 별 DoD 에서 완료.

## 변경 파일

### Phase 2 (run-time meta-check)
- `plugins/rein-core/scripts/rein-policy-loader.py` — `get_meta_check_policy()` 함수 + `--meta-check-policy` CLI flag 추가 (Task 2.1)
- `plugins/rein-core/docs/policy-meta-check.md` — schema doc 신규 (Task 2.2)
- `plugins/rein-core/hooks/post-edit-meta-check.sh` — sub-hook 신규 (Task 2.3)
- `plugins/rein-core/hooks/hooks.json` — PostToolUse Edit|Write|MultiEdit entry 추가 (Task 2.4)

### Phase 3 (DoD anchor obligation)
- `plugins/rein-core/agents/feature-builder.md` — `## 변경 파일` 의무 instruction (Task 3.1)
- `plugins/rein-core/agents/feature-builder-fix.md` — 동상 (Task 3.1)
- `plugins/rein-core/agents/feature-builder-refactor.md` — 동상 (Task 3.1)
- `plugins/rein-core/agents/plan-writer.md` — 동상 (Task 3.1)
- `plugins/rein-core/agents/researcher.md` — 동상 (Task 3.1)
- `plugins/rein-core/rules/operating-sequence.md` — Step 2 의무 섹션 명단에 `## 변경 파일` 추가 (Task 3.2)

### Phase 4 (회귀 + smoke)
- `tests/hooks/test-post-edit-meta-check.sh` — 13 fixture (Task 4.1)
- `tests/scripts/test-policy-loader-meta-check.sh` — 5 fixture (Task 4.3)
- `tests/agents/test-dod-changed-files-section.sh` — 6 assertion (Task 4.4)
- `tests/scripts/test-meta-check-inbox-aggregate.sh` — jq 회고 산식 검증 (Task 4.5)
- 기타: smoke (`bash tests/run-all.sh`), drift (`python3 scripts/rein-check-plugin-drift.py`), plugin validate (Task 4.6)

### Trail
- `trail/dod/dod-2026-05-27-g3-phase2-4-implementation.md` (본 DoD)
- `trail/inbox/2026-05-27-g3-phase2-4-implementation.md` (완료 시점)
- `trail/index.md` (세션 종료 직전 갱신)

## 검증 기준

1. **Phase 2 unit**: 신규 4 테스트 (4.1 / 4.3 / 4.5 / 4.4) 전부 PASS
2. **Phase 1 회귀 무영향**: `bash tests/hooks/test-routing-map-emit.sh` + `tests/hooks/test-session-start-rules.sh` PASS
3. **plugin drift 0**: `python3 scripts/rein-check-plugin-drift.py` exit 0
4. **plugin validate**: 새 hook + rule schema OK
5. **NFR**: post-edit-meta-check.sh advisory body ≤ 500B, answer-mode 0 dirty-diff git invocation
   - **NFR latency 미달 (follow-up tracked)**: spec §5 의 p95 ≤ **150ms** target 은 본 구현에서 **p95 ~210-230ms** 로 측정 (Python cold start ~25ms × 3-4 call/run 누적). 본 cycle 은 relaxed CI threshold (500ms) 통과로 종결, follow-up perf-tuning (Python process pooling 또는 hint parser shell rewrite 검토) 으로 별도 후속 spec 화. spec NFR 표 자체의 "150ms 는 비현실적 — Round 1 codex 지적" 노트도 이 latency 한계를 인지함.
6. **fail-open**: 모든 신규 hook/loader 분기가 PyYAML 부재 / yaml malformed / DoD 부재 / 권한 오류에서 silent skip (exit 0)
7. **legacy DoD 무영향**: Phase 1 routing-map.md 추가로 5 rule emit 되더라도, `## 변경 파일` 부재인 기존 DoD 들은 post-edit-meta-check.sh 가 G3-MC-DOD-MISSING-HINT silent skip
8. **commit gate**: `.codex-reviewed` + `.security-reviewed` stamp 양쪽 생성 (standard tier)

## 의도된 spec 편차 (본 cycle implementation 노트)

- **§3.2 dataflow step 4 — `select_active_dod` 대신 `.active-dod` 마커 직접 read**: spec author 가 helper 사용을 가정했으나 helper 는 `## 범위 연결` 필터 (design-coverage 게이트용) 라 meta-check 의 `## 변경 파일` anchor 와 의미가 다름. helper 본문 변경은 pre-edit-dod-gate / pre-bash-test-commit-gate 등 다른 caller 의 contract 도 흔들어 risk 가 너무 큼. inline marker read + GE-1 path-containment.sh share 패턴 채택. spec 본문 갱신은 follow-up.
- **§3.2 dataflow step 7 — `git ls-files --others --exclude-standard` 도 union**: spec literal 은 `git diff --name-only HEAD` 만이지만 user Write 신규 untracked 파일이 meta-check 의 핵심 UX path 이므로 untracked 도 D 에 포함하도록 확장. Round 1 codex Medium acknowledged.

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: standard
approved_by_user: true
rationale: |
  Phase 2 가 신규 attack surface 1개 추가 (stdin JSON parse + git diff invocation +
  yaml read + trail/inbox/ jsonl append). 모든 경로가 기존 hardened helper 재사용
  (post-edit-policy-gate.sh / state-machine.sh read_fast_path_state /
  select-active-dod.sh / hook-output-cache.sh / BC-INFO1 git env scrub). PyYAML 부재
  / yaml malformed / DoD 부재 / git 명령 실패 모든 분기 fail-open. python json.dumps
  로 inbox jsonl 안전 직렬화. Phase 3 는 정적 markdown 만. standard tier 로 정식
  security-reviewer 실행 (Auto Mode + 사용자 자율 진행 지시 = blanket approval).
  Phase 별 별 DoD 분리 안 함 — 9 Scope ID 가 spec 차원에서 묶여 있고 (post-edit hook
  의 G3-MC-DOD-MISSING-HINT 가 Phase 3 의 `## 변경 파일` 의무화에 의존) phase-level
  review/test cycle 통합이 합리적. plan 의 sequential 표기는 implementation 의존이
  아닌 acceptance 순서 (feedback_parallel_work_first 참고) — wave-based 병렬 진행 가능.
