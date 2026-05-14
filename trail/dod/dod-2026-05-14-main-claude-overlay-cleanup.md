# DoD — main `.claude/` overlay cleanup + branch-strategy.md 보완

- 날짜: 2026-05-14
- 유형: refactor (internal cleanup, no version bump)
- plan ref: (없음 — single-cycle cleanup)

## 배경

`.claude/rules/branch-strategy.md` 의 `❌ 제외 (Option C 후)` 표 (64~77 줄) 는 2026-05-13 Phase 3/5 갱신에서 `.claude/CLAUDE.md`, `.claude/orchestrator.md`, `.claude/hooks/**`, `.claude/skills/**`, `.claude/agents/**`, `.claude/rules/*.md`, `.claude/workflows/*.md`, `.claude/cache/**`, `.claude/.rein-state/**`, `.claude/settings.json` 을 main 제외 대상으로 명시했다. 그러나 v1.1.3 release 머지 (`d8727c8`) 시 main 트리에서 이 overlay 를 `git rm` 하는 cleanup step 이 누락되어, 현재 main 과 public mirror (`9c5ff76`) 양쪽에 overlay 가 잔존한다.

추가로 `.claude/registry/`, `.claude/security/`, `.claude/settings.local.json.example` 은 branch-strategy.md ❌ 표에 명시되지 않은 그레이 영역. **codex review (2026-05-14) 발견**: `.claude/security/**` 는 plugin SSOT 가 아직 흡수하지 못함 (`plugins/rein-core/rules/security.md`, `security-reviewer.md` 가 `.claude/security/profile.yaml` + `rules/{level}.md` 를 require, bootstrap 도 미생성). 따라서 `.claude/security/**` 제거는 본 cycle scope 에서 **제외** — 별도 cycle 에서 migration 후 처리. 본 cycle 은 `.claude/registry/**` + `.claude/settings.local.json.example` 2 항목만 추가 + 기존 Phase 3 명시된 항목 cleanup.

## 완료 기준

1. `.claude/rules/branch-strategy.md` 갱신
   - ❌ 제외 표에 `.claude/registry/**`, `.claude/settings.local.json.example` 2 항목 추가
   - `.claude/security/**` 는 표에 추가하지 않고, 표 아래 인용문으로 "plugin SSOT migration 대기" 명시
   - 머지 전 체크리스트 (151~160 줄) 에 "❌ 제외 표에 새로 추가된 경로가 main 트리에 잔존하는지 확인" 한 줄 추가
2. main 트리에서 다음 경로를 `git rm` 으로 제거 + cleanup commit:
   - `.claude/CLAUDE.md`
   - `.claude/orchestrator.md`
   - `.claude/hooks/`
   - `.claude/skills/`
   - `.claude/agents/`
   - `.claude/rules/`
   - `.claude/workflows/`
   - `.claude/cache/`
   - `.claude/registry/`
   - `.claude/settings.json`
   - `.claude/settings.local.json.example`
   - **제외**: `.claude/security/**` (plugin SSOT migration 후 별도 cycle)
3. dev 측 branch-strategy.md 변경분은 dev → main 단방향 원칙에 따라 dev 에 먼저 commit + push, main 으로 옮기지 않음 (이 파일 자체가 ❌ 제외)
4. main push → mirror-to-public + publish-plugin workflow 자동 trigger 정상 동작 확인

## 변경 파일

- `.claude/rules/branch-strategy.md` (dev only)
- main: `.claude/**` 부분 삭제 (위 11 경로 — `.claude/security/**` 는 본 cycle scope 제외)
- `trail/dod/dod-2026-05-14-main-claude-overlay-cleanup.md` (본 DoD, dev only)
- `trail/inbox/2026-05-14-main-claude-overlay-cleanup.md` (작업 완료 후)

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale:
  - 작업 성격: internal cleanup (rule 한 줄 추가 + main `git rm` cleanup). user-facing 변화 없음 → Rule A 기준 no version bump
  - 파일 패턴: `.claude/rules/branch-strategy.md` (dev) + main `.claude/**` 전체 삭제
  - codex-review: rule 보완이 일관되고 머지 절차 누락 케이스를 정확히 차단하는지 검증
  - security-reviewer skip 후보: 코드 변경 없음 (rule 문서 + git rm 만). 그러나 답변 일관성 위해 절차상 포함 검토
approved_by_user: true  # security-reviewer skip 명시 승인 (2026-05-14)
```

## 위험 / 주의

- 단방향 원칙 위반 위험: main 으로 체크아웃 후 `git rm` 만 수행 (편집 없음). 이 case 는 branch-strategy.md §단방향 원칙의 "유일한 예외" 인 "main-only cleanup" 에 해당
- public mirror 자동 trigger: main push → `mirror-to-public.yml` 이 self-strip 후 public rein 으로 force push. 결과적으로 public rein 의 `.claude/` overlay 도 삭제됨
- plugin tarball 영향 없음: `.claude-plugin/marketplace.json` 의 source = `./plugins/rein-core` 이므로 plugin install 사용자가 받는 파일은 무관
