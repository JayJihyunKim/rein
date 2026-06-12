# Plan complete — gate misfire fixes (GMF-1..GMF-4)

Plan complete: docs/plans/2026-06-12-gate-misfire-fixes.md
Spec review: PASS (codex-gpt-5.5-high-automated, 5 rounds)
Stamp created: trail/dod/.spec-reviews/4f3f088a8ab1e417.reviewed
Code-review gate (.codex-reviewed): untouched (spec-review subflow — gate separation preserved)

## Coverage
- GMF-1 / GMF-2 / GMF-3 / GMF-4 all implemented (matrix exit 0, no .coverage-mismatch)

## Tasks (11 total)
- Phase 1 (GMF-1): Task 1.1–1.6 (red, new lib, gate-internal, classifier, dispatcher, fail-closed regression)
- Phase 2 (GMF-2): Task 2.1–2.2
- Phase 3 (GMF-3): Task 3.1–3.4
- Phase 4 (GMF-4): Task 4.1–4.3

## Execution strategy (waves)
- step 1: gmf1-canonical-commit || gmf3-dod-source (disjoint scope, parallel edit_only)
- step 2: gmf2-merge-exemption (dep gmf1)
- step 3: gmf4-policy-failclosed (dep gmf2, gmf3)
- all edit_only; parent commits per wave

## Review trajectory (5 rounds, author-fixed each)
- R1 NEEDS-FIX: SSOT-by-mirror weak + classifier/dispatcher mention false-positive risk + stale comment
  → introduced new shared lib lib/git-subcommand-model.sh (true SSOT) + git_clause_invokes clause-start matcher
- R2 NEEDS-FIX: Phase 2 stale GIT_MERGE_ERE redefinition + HIGH shared-lib source-failure fail-open
  → GMF-2 consume-only + 3-layer fail-closed (classifier/dispatcher over-trigger, test-commit-gate hard-fail exit 2) + Task 1.6 regression
- R3 NEEDS-FIX: residual bash-guard-infra refs + dispatcher snippet missing fi + rationale wording
  → corrected refs to test-commit-gate, added fi + elif-chain note, reworded empty-ERE rationale
- R4 NEEDS-FIX: one comment "유일 소비자" contradicting 3-consumer model
  → reworded to "유일 hard-fail 소비자"
- R5 PASS: all GMF-1..GMF-4 MATCH

## Empirically verified during planning (grounding, not implementation)
- 27/27 canonical ERE contract cases (commit/merge true-pos + overmatch=0 incl. mention + allowlist-outside)
- fail-closed: model absent → gate exit 2; classifier over-trigger on commit token; no false trigger on benign cmd

## Spec normalization (author, structural)
- docs/specs/2026-06-12-gate-misfire-fixes.md heading "## 4. Scope Items" → "## Scope Items"
  (validator strictly matches "## Scope Items"; numbered heading blocked extraction). No semantic change.

## Next (자동 경로)
- subagent-driven-development / parallel-execute 로 plan 실행 (Wave 1 병렬 → Wave 2 → Wave 3)

## 미해결 결정사항
- 없음 (모든 codex findings 가 author-fixable 였음 — 사용자 결정 필요 항목 0건)
