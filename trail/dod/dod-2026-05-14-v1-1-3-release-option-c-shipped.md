# DoD — v1.1.3 release: Option C plugin SSOT + dogfood model shipped

- 날짜: 2026-05-14
- 유형: release (patch — Phase 4 plugin rule body 변화 = minimal user-facing, Rule A patch)
- plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md (Phase 6 — release 보류 결정을 본 DoD 가 override: 사용자 결정으로 즉시 release)

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 6 / release (Rule A 보류 → 사용자 결정으로 즉시 release)
covers: [S1, S2, S3, S4, S5, S6, S7, S8, S9, S10]

## 목적

Option C Phase 1~5 의 변경분 (`c1cb693..16c0184`, 11 commits) 을 v1.1.3 patch release 로 사용자에게 ship. 본 cycle 의 핵심 산출물:

- **plugin SSOT 단독 source** — `.claude/{hooks,skills,agents}/` overlay 폐기, plugin source 가 사용자 ship 단일 SSOT
- **drift checker 통합 도구** — boundary + parity + validation 3 layer 단일 도구 (`scripts/rein-check-plugin-drift.py`)
- **plugin rule body 정확성 회복** — `design-plan-coverage.md` 의 mandate section + enrichment sync (user-facing inject content)
- **branch-strategy + workflow surface 갱신** — 9 workflow 분류 명시, mirror-to-public strip 패턴과 일관

## user-facing 영향 (versioning.md Rule A 판정)

| 변경 | user-facing? | 정당화 |
|---|---|---|
| plugin SessionStart inject 시 `design-plan-coverage.md` 본문 풍부해짐 | ✅ 약간 — SessionStart 시 사용자가 받는 rule body content 변화 | patch bump 정당화 |
| plugin tarball 사이즈 감소 (docs/rules 4 mirror 폐기) | ✅ 약간 — install size + cache footprint 감소 | positive delta |
| `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md` banner path 정확화 | ✅ minor — installed plugin 환경에서 메시지 정확 | patch |
| 메인테이너 dev overlay 폐기 (`.claude/hooks/` 등) | ❌ 사용자 환경에는 overlay 자체 부재 | internal |
| drift checker 도구 통합 | ❌ 메인테이너 도구 | internal |

→ **Rule A patch bump 정당화** (user-facing 영향 약함 + breaking 없음).

## 변경 작업

### Task 1 — VERSION bump (dev 에서 먼저)

`scripts/rein.sh` 의 `VERSION="1.1.2"` → `VERSION="1.1.3"`.

### Task 2 — CHANGELOG.md 새 v1.1.3 entry

플랫 (`## v1.1.3 — 2026-05-14 (Option C plugin SSOT + dogfood model shipped)`) 본문:
- user-facing 변화 위주 (`feedback_release_readme_version_entry.md` 권고)
- internal cleanup 은 짧게 언급
- v1.1.2 entry 위에 추가

### Task 3 — README.md / README.ko.md 버전 히스토리 1~2줄 + CHANGELOG 링크

`feedback_release_readme_version_entry.md` 의 patterns 따름:
- 간략 1~2줄 entry
- 상세는 CHANGELOG.md 의 `#v113-...` anchor 로 링크

### Task 4 — dev commit ("chore(release): v1.1.3 prep") + push

VERSION + CHANGELOG + README 변경 묶음 단일 commit.

### Task 5 — main 머지 (선별 체크아웃, `feedback_branch_strategy_order.md` 준수)

```
git checkout main
git checkout dev -- <branch-strategy.md ✅ 포함 list>
```

main 머지 대상 (Option C Phase 5 의 branch-strategy.md ✅ 포함 표 따름):
- `plugins/rein-core/**`
- `.claude-plugin/marketplace.json`
- `AGENTS.md`, `README.md`, `README.ko.md`, `main_img.png`, `CHANGELOG.md`
- `docs/{changelog-archive,troubleshooting,agents-md-examples.md}/**`
- `scripts/rein*.{sh,py}`
- `.gitignore`, `.github/workflows/*.yml` (mirror 가 strip 대상 처리)

❌ 제외: `.claude/{CLAUDE.md,rules/,settings*.json,orchestrator.md,workflows/,cache/,.rein-state/}`, `tests/**`, `docs/{specs,plans,brainstorms,reports}/**`, `trail/**`, `need-to-confirm.md` 등

### Task 6 — main commit + tag v1.1.3

```
git commit -m "feat(release): v1.1.3 — Option C plugin SSOT + dogfood model"
git tag v1.1.3
```

### Task 7 — main + tag push

```
git push origin main
git push origin v1.1.3
```

mirror-to-public + publish-plugin workflow 가 자동 trigger.

### Task 8 — dev sync (post-release 기록)

dev 에 commit: `docs(trail): v1.1.3 release 종결 — main <sha> + tag v1.1.3 반영` + trail/index.md 갱신.

## 검증 게이트

- [ ] Task 1: `grep '^VERSION=' scripts/rein.sh` = `VERSION="1.1.3"`
- [ ] Task 2: CHANGELOG.md 의 `## v1.1.3 — 2026-05-14` entry 존재
- [ ] Task 3: README.md + README.ko.md 의 v1.1.3 entry 1~2줄 + CHANGELOG 링크
- [ ] Task 4: dev commit 후 origin/dev push (ahead 0)
- [ ] Task 5: main 의 working tree 가 dev 의 main-mergeable subset 과 일치 (memory `feedback_plugin_validate_before_main.md` — `claude plugin validate` 권고)
- [ ] Task 6: main HEAD = 새 commit, `git tag -l v1.1.3` = exists
- [ ] Task 7: `git ls-remote --tags origin v1.1.3` 매치
- [ ] Task 8: dev/origin/dev ahead 0, trail/index.md "이전 완료" 에 v1.1.3 추가
- [ ] codex-review PASS (release commit 전체 변경분)
- [ ] security-review No concerns

## Rollback

문제 시:
- main push 전: `git checkout dev` + main working tree reset
- main push 후 tag 전: `git push --delete origin main` 위험 (force push to main 금지) — 새 commit 으로 revert
- tag push 후: `git tag -d v1.1.3` (로컬) + `git push --delete origin v1.1.3` (사용자 명시 승인 필요)

## Release

본 cycle main 머지 = v1.1.3. tag v1.1.3 생성. mirror-to-public + publish-plugin workflow trigger.

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review        # release 변경분 (VERSION/CHANGELOG/README) 리뷰
  - changelog-writer    # CHANGELOG entry 작성 권고 (선택)
mcps: []
rationale: |
  release cycle 의 변경은 작음 (VERSION + CHANGELOG + README 3 파일 변경 + main 머지
  + tag). codex-review medium effort 가 적합. changelog-writer skill 은 git log
  기반 자동 CHANGELOG 작성에 사용 (선택, manual 작성도 가능).
approved_by_user: true
```

## Self-review (release cycle 종료 시 작성)

- [ ] 모든 Task 검증 게이트 통과
- [ ] codex-review PASS + security-reviewer No concerns
- [ ] main HEAD = v1.1.3 tag commit + origin push 완료
- [ ] mirror-to-public + publish-plugin workflow trigger 확인
- [ ] dev sync + trail 갱신
