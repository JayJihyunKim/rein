# v1.1.3 release — Option C plugin SSOT + dogfood model shipped

- 날짜: 2026-05-14
- 유형: release (patch — Rule A)
- DoD: trail/dod/dod-2026-05-14-v1-1-3-release-option-c-shipped.md
- main commit: `d8727c8`
- tag: `v1.1.3` (annotated, sha `cf25b681`)
- mirror-to-public + publish-plugin workflow: 자동 trigger (main push 직후)

## 요약

Option C Phase 1~5 + plugin cache rebuild 검증 산출물을 patch release 로 ship. 사용자가 `/plugin marketplace update + install` 시 받는 변화 3건:
- SessionStart 시 inject 되는 design-plan-coverage rule body 풍부화 (Phase 4 Round 1)
- banner 의 `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md` path 정확화 (Phase 4 Task 4.4)
- plugin tarball 사이즈 감소 (Phase 4 Task 4.1)

## 본 cycle 의 incident — bootstrap-gate false positive

메인테이너 release cycle 의 main checkout 단계에서 plugin 의 bootstrap-gate hook 이 "trail/ 부재 → onboarding 미완료" 로 잘못 인식. 본질적으로:
- main 에 trail/ 부재 = 정상 (branch-strategy `trail/** 제외`)
- 그러나 hook 은 working tree 의 trail/ 부재만 보고 사용자 onboarding 시나리오로 처리
- → main checkout 시 disk 의 dev 시점 trail/ 가 사라져 hook 발화

본 cycle 에서는 `git stash` + manual 우회 (`!` prefix 직접 실행) 로 해소. 향후 cycle 후보로 등록 — bootstrap-gate 가 "메인테이너 dev repo 에서 main branch 작업" 시나리오를 구분하도록 개선.

## 라우팅 피드백

feature-builder + codex-review (medium effort). codex Round 1 PASS. release prep 변경 (VERSION + CHANGELOG + README) 은 단순했지만 main 머지 단계에서 bootstrap-gate incident 가 진행을 막아 사용자 직접 실행 (`!stash pop`) 필요했음.

## 변경 파일 (main commit)

```
21 files changed, 1328 insertions(+), 526 deletions(-)
- .github/workflows/{govcheck,plugin-drift-check,publish-plugin,tests}.yml (new)
- CHANGELOG.md (v1.1.3 entry)
- README.md / README.ko.md (latest release line)
- plugins/rein-core/hooks/session-start-load-trail.sh
- plugins/rein-core/rules/design-plan-coverage.md
- plugins/rein-core/scripts/* (drift checker + codex-review + validate-coverage-matrix)
- plugins/rein-core/skills/{code-reviewer,codex-ask,codex-review}/SKILL.md
- scripts/rein.sh (VERSION 1.1.3)
- scripts/rein-* (drift checker / validate / runtime-init / codex-review)
```
