# Integrated roadmap — cc-feature + performance 통합 master plan 작성

- 날짜: 2026-05-20
- 유형: docs (master plan 통합)
- 변경 파일 (4):
  - `docs/plans/2026-05-20-integrated-roadmap.md` (신규, ~260 줄)
  - `trail/dod/dod-2026-05-20-integrated-roadmap.md` (신규)
  - `trail/inbox/2026-05-20-integrated-roadmap.md` (본 파일)
  - `trail/index.md` (진입점 갱신)

## 요약

어제 plan (`docs/plans/2026-05-19-cc-feature-adoption.md`, 16 Scope ID) 과 오늘 untracked 로 작성된 성능 노트 (`rein-performance-plan.md`, 6 Phase) 두 source 가 부분만 중복하고 나머지는 분기한 상태를 단일 master plan 으로 통합. 진행 완료는 간략 (§3, 1 단락), 잔존 작업은 자세히 (§4, 5 영역 A~E).

## 통합 결과

| performance-plan Phase | cc-feature 매핑 | 본 plan 영역 분류 |
|---|---|---|
| Phase 1 rule injection off | UPS-1 부분 | §3.2 완료 |
| Phase 2 short rule + Bash if | UPS-1 + PERF-3 | §3.2 완료 |
| Phase 3 Bash dispatcher 통합 | — | §4.1 영역 A 잔존 |
| Phase 4 post-edit 다이어트 | HK-4 분할만 | §4.2 영역 B 잔존 |
| Phase 5 State machine | — | §4.3 영역 C 잔존 |
| Phase 6 Release gate 분리 | — | §4.4 영역 D 잔존 |

추가로 본 plan §4.5 영역 E (scaffold 청소: tests/rein-test.sh + bootstrap drift + dispatcher body 제거) 신설.

## 우선순위 (§5)

cycle 묶음 X1~X5 — X1 (scaffold 청소 영역 E.1+E.2) 부터 시작 권장.

## 검증

- `rein-validate-coverage-matrix.py` 결과: legacy plan WARN, exit 0, `.coverage-mismatch` 마커 미생성 — 본 plan §1 의 "matrix 의도적 생략" 결정과 부합.
- DoD 에 `## 범위 연결` 섹션 추가 (covers: 빈 배열, meta-cycle 표기) — invalid-active-dod marker 회피.

## 리뷰

- codex Round 1 NEEDS-FIX (3 issue):
  - **High 1**: inbox + index 미작성 — Round 2 에서 작성 (이 inbox + index 갱신)
  - **High 2**: DoD `## 범위 연결` 섹션 누락 → invalid-active-dod marker — Round 2 에서 보강 (covers:[] meta-cycle)
  - **Medium 1**: §3.1 Phase 3 main 반영 부정확 → Round 2 에서 "v1.3.2 main 묶음" 으로 1차 정정
- codex Round 2 NEEDS-FIX (2 issue, Round 1 정정의 정확성 미흡 발견):
  - **High 1 (재발)**: review base scope — working tree 파일이 diff_base..HEAD 안 들어가 codex 가 4 파일 fix 검증 불가. → Round 3 에서 **working tree 본문 read 기반 review** 로 codex 가 직접 4 파일 본문 검증. commit 은 review PASS 후 진행 (정상 순서).
  - **High 2**: Round 1 Medium 의 정정이 부정확 — Phase 3 (DEC-1/PLN-1/AG-2) 가 main 에 ship 됐다는 evidence 가 부재. → Round 3 에서 §3.1 전면 정정 (git evidence 기반 — main 의 AGENTS.md/writing-plans SKILL/feature-builder agent 에서 SubagentStop/execution_strategy/worktree-isolation 키워드 부재 확인). 정정 결과: **Phase 1 의 7 Scope 만 main, Phase 2/2b/2c/3/4 의 9 Scope 는 dev only** (Phase 4 PERF-3 는 부분).
- codex Round 3 NEEDS-FIX (1 High + optional): 본 inbox 의 Round 2/3 audit text 가 stale (이전 "commit 후 재리뷰" 표현 잔존). Round 4 에서 정정 — Round 3 의 정확한 process 명시: "Round 3 = working tree 본문 review → PASS 후 commit/stamp/push". §3.1 PERF-3 path optional 정확화 (`plugins/rein-core/hooks.json` → `plugins/rein-core/hooks/hooks.json`).
- Round 4 정정: 본 inbox 본문 + plan §3.1 PERF-3 path. Round 4 codex 호출 → PASS → stamp 갱신 → commit + push.
- security tier=light: docs only, secret/외부 input/exec 없음.

## 후속 의무 (§6 working agreement)

본 plan 의 §4 잔존 영역 (A~E) 가 모두 종결되거나 후속 통합 plan 으로 명시적 승계될 때까지:
- 매 session SessionStart 후 첫 작업 시작 전 본 plan §4 read
- 별 cycle 진입 시 DoD 본문에 본 plan 의 영역 # 와 cycle 묶음 (X1~X5) 명시
- 본 plan 영역 진행도 갱신은 같은 cycle 안에서 동기화

## 라우팅 회고

- 추천: docs-writer agent (or 직접 Write) + codex-review skill + light security tier — DoD 라우팅 추천 대로 직접 Write 채택, plan 통합은 두 source 의 manual merge 라 agent dispatch overhead 불필요
- approved_by_user: true (사용자 명시 "스스로 판단해서 진행")
