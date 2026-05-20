# Phase 4 cc-feature-adoption — UPS-1 short rule injection + PERF-3 cold-path skip (v1.3.3 prep)

- 날짜: 2026-05-20
- 유형: feat
- DoD: trail/dod/dod-2026-05-20-cc-feature-adoption-phase4-short-rule-and-if-field.md
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 4)
- spec ref: docs/specs/2026-05-19-cc-feature-adoption.md (UPS-1, PERF-3, §제외 #3 재제출)

## 요약

cc-feature-adoption Phase 4 신설 (Scope ID 2개). spec §제외 항목 #3 (UserPromptSubmit 재주입) 의 재설계 방향 ("본문 대신 요약 주입") 을 UPS-1 으로 재제출 + HK-2 (v1.3.2 shipped) 와 분리된 advisory hook cold-path skip PERF-3 신설. codex Mode B (`/codex-ask` gpt-5.5 high) 가 PERF-3 의 ID 이름을 좁히는 권고 + UPS-1 의 SessionStart anchor 표현 사실 정정 권고를 짚어줘 spec/plan/DoD 본문에 반영.

## 변경 파일

- 신축: `plugins/rein-core/rules/short/{answer-only-summary,background-jobs-summary}.md`
- 신축: `tests/scripts/{test-ups1-short-rule-injection,test-perf3-bash-rules-cold-path-skip}.sh`
- 신축: `trail/dod/dod-2026-05-20-cc-feature-adoption-phase4-short-rule-and-if-field.md`
- 편집: `plugins/rein-core/hooks/{user-prompt-submit-rules,pre-tool-use-bash-rules}.sh` (1 line each)
- 편집: `plugins/rein-core/hooks/hooks.json` (PreToolUse Bash 26 hot-path entry 추가)
- 편집: `docs/{specs,plans}/2026-05-19-cc-feature-adoption.md` (Scope ID 2 + Phase 4 섹션 + 릴리즈 표 v1.3.3 row + §제외 #3 재제출)
- 편집: `scripts/rein.sh` VERSION 1.3.2 → 1.3.3
- 편집: `plugins/rein-core/.claude-plugin/plugin.json` version 1.3.2 → 1.3.3
- 편집: `CHANGELOG.md` v1.3.3 entry 추가
- 편집: `README.md` / `README.ko.md` latest release 줄 갱신

## 측정 (Phase 0 vs Phase 4)

- byte (1회 inject): 7049 B → 546 B (92.3% ↓), 5959 B → 515 B (91.4% ↓)
- 1시간 누적 컨텍스트: ~332 KB → ~38 KB (89% ↓)
- hook wall-clock: pre-tool-use-bash-rules.sh ~0.06s 변경 없음. cold path 에서 spawn 안 됨 → 외부 측정 시 차이 conceptual

## 검증

- `tests/scripts/test-ups1-short-rule-injection.sh`: 11/11 PASS
- `tests/scripts/test-perf3-bash-rules-cold-path-skip.sh`: 33/33 PASS
- `tests/scripts/run-all.sh`: ALL SUITES PASSED (19 PASS, 0 FAIL)
- codex-review: **Round 1 NEEDS-FIX → Round 2 PASS** (fix: spec/plan 의 ≤400B → ≤600B 정정 3건 + hooks.json 13 → 26 entry bare+args 분리)
- security-review (light tier): **PASS** (CRITICAL/HIGH/MEDIUM 0, LOW advisory 1 — `make help` 류 false-positive, 보안 위험 아님)

## 묶음 release (사용자 결정)

오늘 (2026-05-20) 작업을 한번에 v1.3.3 patch tag 로 묶음:
- 오전 incident cleanup 3건 declined + 파일 삭제 (internal)
- Phase 4 short rule injection + cold-path skip (user-facing rule body 축소 + advisory hook spawn 감소)

versioning.md Rule A patch bump 정당화 — user-facing outcome 변화 없음, body 단축 + hook config tweak.

## 다음 단계

1. **main 선별 체크아웃 + annotated tag v1.3.3 + push** — mirror-to-public + publish-plugin workflow 자동 trigger. dev 단방향 원칙 준수 (`feedback_branch_strategy_order.md`)
2. **trail/index.md "다음 세션 진입점" 갱신** — v1.3.3 shipped 반영
3. **다음 cycle 진입** — 사용자 결정. 후보:
   - cc-feature-adoption Phase 2 SPIKE-1 (병렬 hook + tool_use_id 측정, no bump) — 원래 다음 예정 작업
   - HK-2 의 bare command 미커버 fix (codex Round 1 짚음, 본 Phase 4 범위 밖)
   - rein-performance-plan Phase 3~6 (별 cycle)
   - improve_plan §제외 항목 #7/#14/#16 재설계 (별 cycle)

## codex Mode B 권고 메모리 저장

`feedback_design_doc_exclusion_check_before_dod.md` — DoD 작성 전 spec §제외 항목 + 17→Scope ID 매핑 표 먼저 확인. 본 cycle 에서 codex Mode B 가 잡지 않았으면 PERF-3 가 HK-2 중복으로 잘못 신설됐을 것.
