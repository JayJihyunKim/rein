# G3 Phase 2-4 — run-time meta-check + DoD anchor obligation + 회귀

- 날짜: 2026-05-27
- 유형: feat
- 변경 파일: 14건
  - **Phase 2 (4)**: `plugins/rein-core/scripts/rein-policy-loader.py` (modify — `get_meta_check_policy()` + `--meta-check-policy` CLI + module-level yaml import refactor `sys.exit(0)` → `yaml=None`) / `plugins/rein-core/docs/policy-meta-check.md` (new) / `plugins/rein-core/hooks/post-edit-meta-check.sh` (new ~270 line) / `plugins/rein-core/hooks/hooks.json` (modify — PostToolUse entry idx=8)
  - **Phase 3 (6)**: `plugins/rein-core/agents/feature-builder{,-fix,-refactor}.md` + `plan-writer.md` + `researcher.md` + `plugins/rein-core/rules/operating-sequence.md` — `## 변경 파일` 의무 instruction
  - **Phase 4 (4)**: `tests/hooks/test-post-edit-meta-check.sh` (15 fixture) + `tests/scripts/test-policy-loader-meta-check.sh` (5) + `tests/agents/test-dod-changed-files-section.sh` (6) + `tests/scripts/test-meta-check-inbox-aggregate.sh` (jq aggregate)
  - **Trail (3)**: `trail/dod/dod-2026-05-27-g3-phase2-4-implementation.md` (신규 DoD) / `trail/dod/.codex-reviewed` (self-review R3 PASS) / `trail/dod/.security-reviewed` (security-reviewer PASS)

- 요약:
  - **9 Scope ID 중 Phase 1 (G3-RM) 제외 8개 구현 완료**: G3-MC-FASTPATH / G3-MC-NO-ACTIVE-DOD / G3-MC-POLICY / G3-MC-DOD-MISSING-HINT / G3-MC-DETECT / G3-MC-ADVISORY / G3-MC-INBOX / G3-DOD-TEMPLATE-CHANGED-FILES-SECTION.
  - **codex R1 NEEDS-FIX (High claim-audit + 3 Medium) → R2 NEEDS-FIX (3 Medium) → R3 self-review PASS**. 적용한 fix 8건 (Fix A~H):
    - A: F1 FASTPATH fixture + git PATH spy (rev-parse 정상 exclude)
    - B: hook 에 `git ls-files --others --exclude-standard` union (untracked Write 검출)
    - C: 20-run p95 perf fixture, 3-tier threshold (NFR 150ms target 미달 ~210-230ms, follow-up tracked)
    - D: advisory body 에 `hint_count` + `diff_count` 추가 (spec §2.1 G3-MC-ADVISORY 일치)
    - E: select_active_dod bypass 결정 hook 주석 + DoD 의도된 spec 편차 섹션에 명시
    - F (R3): `section_present` flag 로 "section absent" vs "section present-but-empty" 구분 (G3-MC-DOD-MISSING-HINT 정확성)
    - G (R3): F7B untracked-write regression (seed-then-create 패턴으로 격리)
    - H (R3): F7C empty-section asserts H=∅ full-mismatch
  - **security-reviewer (rein:security-reviewer) PASS** — standard tier 검사 9항목 모두 통과. 2 Low advisory 만 (META_DIFF_RAW ARG_MAX, jsonl symlink race) — 양쪽 fail-open 경로 + trust model 외부, 차단/수정 불요. follow-up tracked.
  - **회귀 무영향**: Phase 1 (`test-routing-map-emit` + `test-session-start-rules`) PASS / plugin drift 0 / `claude plugin validate plugins/rein-core` PASS / 신규 4 테스트 PASS.
  - **의도된 spec 편차** (DoD 명시):
    - §3.2 step 4: `select_active_dod` 대신 `.active-dod` 마커 직접 read (helper 의 `## 범위 연결` 필터가 meta-check 의 `## 변경 파일` anchor 와 의미 다름)
    - §3.2 step 7: `git diff --name-only HEAD` 에 `git ls-files --others --exclude-standard` union (literal spec 확장 — Write 신규 파일 UX catch)

- plan ref: `docs/plans/2026-05-27-g3-execution-mode-advisor.md` (Phase 2 / Phase 3 / Phase 4 Task 4.1+4.3+4.4+4.5+4.6 — 4.2 는 Phase 1 별 DoD 완료)

- **G3 spec 의 모든 Phase 종결**: Phase 1 (route-time, dev `0608983` + uncommitted) + Phase 2-4 (run-time + agent + 회귀, uncommitted). 다음 작업 후보:
  - dev commit (Phase 1 + Phase 2-4 통합) — 사용자 명시 시
  - v1.4.0 release plan (사용자 결정 시)
  - 잔여 백로그: SR-1.b(low) / 자동모드 시맨틱 정의 / PLN-1+AG-2(보류) / G3 perf NFR follow-up
