# rein v1.3.4 구현 (B1/B2/B3/B6/B7 + S1/S2/S4 + D1/D2/D3)

- 날짜: 2026-05-22
- 유형: fix + feat + chore + docs
- 변경 파일:
  - `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` (B1: security-tier-skip Tier-1-only + S2 주석)
  - `plugins/rein-core/hooks/pre-bash-safety-guard.sh` (B2: P8 grep/awk/sed/jq/cut 확장, deny-by-default + S2 주석)
  - `plugins/rein-core/hooks/stop-session-gate.sh` (B3 resolver-cache GC, B6 POSIX 정수검사, B7 완료 DoD stale 제외 + S2 주석)
  - `plugins/rein-core/hooks/{pre-edit-dod-gate,post-edit-plan-coverage,post-edit-design-plan-coverage-rule,post-edit-routing-procedure-rule}.sh`, `lib/project-dir.sh` (S1/S2 주석 정리)
  - `tests/hooks/test-security-tier-gate.sh` (T1: Tier 2 fail-closed + Tier1 marker)
  - `tests/hooks/test-bash-guard-split-command-anchoring.sh` (T2: grep/awk/sed/jq/cut true-positive + quoted fail-closed, 28 cases)
  - `tests/hooks/test-stop-gate-v1-3-4.sh` (신규: B3 GC + B7 완료 DoD, 4 cases)
  - `tests/hooks/{test-session-start,test-session-start-tone}.sh` (S4: fixture mode plugin)
  - `README.md`, `README.ko.md` (D1: Claude Code vs Rein 비교 — KR/EN parity)
  - `docs/architecture.md`, `docs/policy-model.md` (D2/D3 신규)
- 요약: 확정안(rein-v1.4-improvement-plan.md §0.5) v1.3.4 스코프 전부 구현. codex 리뷰 Round 1 에서 **B2 quote-exemption fail-open (High)** 발견 → quote-boundary 철회, deny-by-default 원복 → Round 2 PASS. security review 차단급 0. 전체 테스트 PASS (security-tier 12, bash-guard-anchoring 28, stop-gate-v1-3-4 4, 인접 회귀 0). B4 폐기·B5 삭제·S3 분리(별도 cycle).
- 후속 후보: B2 verb allowlist 한계 (rg/xxd/od/strings 등 미포함 — 구조적, 후속 cycle), S3 state-paths mode 동작 결정.
- 미실행: commit 은 dev 누적 (push/main 머지는 별도 사용자 승인 — project_area_series_dev_only_until_complete).
