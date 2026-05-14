# Wrapper: fresh spec review 에서 stale active DoD fallback

- 발견 날짜: 2026-04-24
- 발견 경로: `docs/specs/2026-04-24-claim-audit-hardening-design.md` 에 대해 `bash scripts/rein-codex-review.sh --non-interactive` (spec-review mode) 실행
- 관찰된 증상:
  - 새로 작성된 design 문서는 아직 연동 plan/DoD 가 없음
  - wrapper 의 `build_envelope()` 가 active DoD 를 Tier 2 (최신 mtime) fallback 으로 선택 → **별건 작업 (brainstorming-sanity-gate, c71bc39) 의 DoD** 를 context 로 주입
  - `diff_base=HEAD` 로 설정됨 (실제 변경은 worktree 의 fresh spec 이므로 HEAD..HEAD = 비어있음)
  - `plan_ref=MULTIPLE_FAIL_CLOSED` — plan 이 resolve 안 됨
- 결과:
  - codex 가 "MISSING all active DoD covers" 를 보고 (stale DoD 의 covers 를 평가)
  - "claim-vs-diff drift" High 지적 — 실제로는 wrapper 가 worktree 가 아닌 HEAD 를 리뷰 대상으로 잡음
  - codex verdict 말미에 "wrapper assembled the wrong review base" 로 시인

## 영향

- fresh design 에 대한 spec-review 가 **구조적으로 false NEEDS-FIX** 를 내보낸다 — 실질 결함 판정 섞임
- 현재 경로는 advisory (spec-review 는 stamp 를 건드리지 않음) 이므로 block 은 없음
- 그러나 "codex 가 지적한 결함 중 어디까지가 실제 설계 결함인지" 를 매번 사람이 분리해야 함 → 리뷰 신호-노이즈비 악화

## 고려할 수 있는 방향 (본 incident 는 기록만. 별건 brainstorm/spec 필요)

- (A) wrapper 가 spec-review 모드에서 **design 경로 수신 시 active DoD fallback 을 비활성화** → context 에서 active_dod 부분을 `(N/A for fresh spec review)` 로 표기
- (B) spec-review 모드에서 `diff_base` 를 "N/A" 로 강제, changed_files 는 design 문서 자체만 포함
- (C) 새 spec-review 전용 envelope 구성 (code-review envelope 와 분리)

## 연관

- 원인 파일: `scripts/rein-codex-review.sh` (build_envelope 의 active DoD selection + diff_base 로직)
- 선행: `GI-codex-review-envelope-context-missing` (context 부재 시 High process gap 표기 규칙) — 본 케이스는 regular gap 이 아니라 **wrong context 가 주입됨** 이라 해당 규칙이 못 잡음
- 관련 회고: codex-review SKILL.md §2 "Mode 별 stamp 규칙" 에는 stamp 규칙만 있고 context 조립 차이는 없음
