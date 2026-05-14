# DoD — Option C Phase 5: branch-strategy + workflow surface 갱신

- 날짜: 2026-05-13
- 유형: docs + workflow audit (Phase 5, target-release: none — Rule A)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 5 / Task 5.1 ~ 5.8
covers: [S9]

## 목적

`branch-strategy.md` 의 main 머지 표 + 영향 workflow 5 개를 Option C 후 layout 으로 일관화. plugin SSOT (`plugins/rein-core/**`) 중심으로 main 머지 대상 정리.

## 변경 / 검증 작업

### Task 5.1 — branch-strategy.md 새 표 (S9, 실제 편집)

`.claude/rules/branch-strategy.md` 의 ✅ 포함 / ❌ 제외 표를 spec D5 형식으로 재작성:

**✅ 포함**:
- `plugins/rein-core/**` (hooks/skills/agents/rules/scripts — docs/rules/ 는 부재)
- `.claude-plugin/marketplace.json`
- `README.md` / `README.ko.md` / `CHANGELOG.md`
- `scripts/rein-publish.sh` + 기타 rein-* helper
- `docs/troubleshooting/**`, `docs/agents-md-examples.md`, `docs/changelog-archive/**`

**❌ 제외**:
- `.claude/CLAUDE.md`
- `.claude/rules/{branch-strategy,readme-style,versioning,legacy-shipped-pending}.md`
- `.claude/settings.json`
- `.claude/hooks/**`, `.claude/skills/**`, `.claude/agents/**` (Option C 후 부재)
- `tests/**`, `.github/workflows/{tests,govcheck}.yml`
- `docs/specs/**`, `docs/plans/**`, `docs/brainstorms/**`, `docs/reports/**`
- `trail/**`

### Task 5.2-5.8 — 영향 workflow / script 검증 (audit-only, 갱신 plan 작성)

| Task | 대상 | 검증 |
|---|---|---|
| 5.2 | `.github/workflows/mirror-to-public.yml` strip 패턴 | Option C 제외 항목과 일관성 |
| 5.3 | `.github/workflows/govcheck.yml` + `scripts/rein-govcheck.py` | overlay 부재 시 graceful skip |
| 5.4 | `.github/workflows/tests.yml` | test suite 가 plugin path 만 reference |
| 5.5 | `.github/workflows/publish-plugin.yml` | `rein-publish.sh` 가 통합 도구 호출 |
| 5.6 | `.github/workflows/plugin-drift-check.yml` | drift checker boundary mode 정상 |
| 5.7 | `.claude-plugin/marketplace.json` | `source: ./plugins/rein-core` 유효 |
| 5.8 | `scripts/rein-publish.sh:94-102` | Phase 2 통합 후 정상 호출 |

## 검증 게이트

- [ ] Task 5.1: branch-strategy.md 의 새 표가 spec D5 와 일치 (plugin SSOT 명시 + dev-only 4 파일 + docs/rules 부재)
- [ ] Task 5.2: mirror-to-public.yml strip 패턴이 새 제외 목록과 일관
- [ ] Task 5.3: govcheck overlay 부재 시 graceful (또는 skip 권고)
- [ ] Task 5.4: tests.yml 의 fixture 가 plugin path reference
- [ ] Task 5.5: publish-plugin.yml 정상 trigger
- [ ] Task 5.6: plugin-drift-check.yml 정상 exit
- [ ] Task 5.7: marketplace.json 의 source path 유효
- [ ] Task 5.8: rein-publish.sh:94-102 가 통합 도구 정상 호출
- [ ] codex review PASS
- [ ] security review (audit-only 라 No concerns 기대)

## Rollback

문제 시 `git restore .claude/rules/branch-strategy.md`. Task 5.2-5.8 은 audit-only 라 변경 없음.

## Release

본 cycle main 머지 = none (Rule A — Task 6.2 다음 release 묶음). dev push 만.

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale: |
  Phase 5 의 핵심은 docs (branch-strategy.md) 갱신 + workflow audit. 작은 변경
  + 검증 위주. codex-review medium effort.
approved_by_user: true
```
