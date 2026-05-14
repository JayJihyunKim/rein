# DoD — Option C Phase 4: plugin docs/rules mirror cleanup

- 날짜: 2026-05-13
- 유형: refactor (Phase 4, target-release: none — main 머지 보류, dev only. Task 6.2 다음 release 묶음)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 4 / Task 4.1 ~ 4.4
covers: [S8]

## 목적

`plugins/rein-core/docs/rules/` 의 4 mirror 파일을 제거. `.claude/rules/` (dev-only 4 파일) + `plugins/rein-core/rules/` (shared 7 파일) 가 단일 SSOT. plugin 안에 중복 mirror 가 없어 drift 가능성 0.

추가로 Phase 3 codex review Round 1 이 짚은 stale string reference (카테고리 B/D) 모두 정리.

## 변경 작업

### Task 4.1 — plugin docs/rules 4 파일 + dir 제거 (S8)

```bash
rm plugins/rein-core/docs/rules/{legacy-shipped-pending,background-jobs,design-plan-coverage,subagent-review}.md
rmdir plugins/rein-core/docs/rules
```

검증:
- `test ! -d plugins/rein-core/docs/rules` 통과
- `plugins/rein-core/docs/` 에 `overflow-handoff.md` 만 남음

### Task 4.2 — `tests/hooks/test-legacy-pending-heal-registered.sh` 갱신 (S8)

`plugins/rein-core/docs/rules/legacy-shipped-pending.md` mirror 존재 + sha256 동일성 검증 부분 제거. healer 동작 검증만 유지.

검증: `bash tests/hooks/test-legacy-pending-heal-registered.sh` PASS

### Task 4.3 — drift checker 의 docs/rules parity 검사 제거 (S8)

`scripts/rein-check-plugin-drift.py` (+ plugin mirror) 에서 plugin docs/rules parity 검사 잔존 시 제거. Phase 2 에서 흡수되었으면 변경 없음. test fixture 갱신.

검증:
- `python3 scripts/rein-check-plugin-drift.py` OK
- `bash tests/scripts/test-rein-check-plugin-drift-boundary.sh` pass=8 fail=0

### Task 4.4 — 기타 reference 정리 (Phase 3 의 카테고리 B/D 후속)

`plugins/rein-core/docs/rules/` reference + Phase 3 의 plugin SSOT mirror 안 `.claude/rules/<name>.md` string reference 모두 정리:

```bash
grep -rn 'plugins/rein-core/docs/rules' . --include='*.md' --include='*.sh' --include='*.py' --include='*.yml'
grep -rn '\.claude/rules/\(code-style\|security\|testing\|design-plan-coverage\|subagent-review\|answer-only-mode\|background-jobs\)\.md' plugins scripts --include='*.md' --include='*.sh' --include='*.py'
```

대상 (codex Round 1 발견):
- `plugins/rein-core/skills/{codex-ask,codex-review,code-reviewer}/SKILL.md` — `.claude/rules/<name>.md` 참조
- `plugins/rein-core/scripts/{rein-check-plugin-drift.py, rein-codex-review.sh, rein-validate-coverage-matrix.py}` — `.claude/rules/design-plan-coverage.md` string
- `scripts/{rein-check-plugin-drift.py, rein-codex-review.sh, rein-runtime-init.py, rein-validate-coverage-matrix.py}` — 같은 string
- `plugins/rein-core/hooks/session-start-load-trail.sh` — header text 의 stale path

각 reference 를 plugin source path 로 redirect 또는 의미 명확화 (예: `.claude/rules/...` 가 사용자 repo 의 user-applied rule 이면 그대로, 메인테이너 dev 도구의 input 이면 plugin source 로).

검증: 위 grep 결과 0 매치 또는 의미상 정당화된 reference 만 잔존.

## 검증 게이트 (모두 통과해야 Phase 4 완료)

- [ ] Task 4.1: `plugins/rein-core/docs/rules/` 디렉토리 부재
- [ ] Task 4.1: `plugins/rein-core/docs/` 에 `overflow-handoff.md` 만 잔존
- [ ] Task 4.2: `test-legacy-pending-heal-registered.sh` PASS
- [ ] Task 4.3: drift checker OK + drift-boundary test pass=8 fail=0
- [ ] Task 4.4: stale reference 0 매치 (또는 의미상 정당화)
- [ ] codex review PASS
- [ ] security review No concerns

## Rollback

문제 시: `git restore plugins/rein-core/docs/rules/ scripts/ plugins/rein-core/skills/ tests/hooks/test-legacy-pending-heal-registered.sh`. 본 Phase 4 의 변경 크기는 작아 rollback 간단.

## Release

본 cycle main 머지 = none (Rule A, plan §Phase 6). 다음 user-facing release cycle 에 Phase 3 변경분과 묶음. 사용자 결정 시 commit 후 origin/dev push.

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review        # 변경분 review (small scope, low effort 적합)
mcps: []
rationale: |
  Phase 4 는 plugin docs/rules mirror 4 파일 제거 + test 갱신 + grep 기반
  reference cleanup. 변경 규모 작음 (Phase 3 보다 10배 이상 작음). schema 검증이나
  외부 docs 조회 불필요 (Phase 3 의 context7 학습 완료). codex-review 가 변경 review
  + stamp 생성.
approved_by_user: true
```

## Self-review (Phase 4 종료 시 작성)

- [ ] 모든 Task 검증 게이트 통과
- [ ] codex-review PASS + security-reviewer No concerns
- [ ] trail/index.md 갱신
- [ ] inbox 기록
- [ ] commit + push
