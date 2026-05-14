# DoD — readme-style + versioning main 제외

- 날짜: 2026-04-27
- 묶음: branch-strategy.md 결정 정정 (사용자 보고 기반)

## 변경 대상 파일

- Modify: `.claude/rules/branch-strategy.md`
  - 포함 list 에서 `.claude/rules/readme-style.md` + `.claude/rules/versioning.md` 제거
  - 제외 list 에 두 파일 추가 (사유: rein-specific 회고 기반, 사용자 프로젝트에 그대로 적용 부적절)

## 사유

사용자 (wave) 가 v1.2.1 update 시 두 파일이 `Added` 로 들어왔는데 내용을 보면:
- `readme-style.md`: 2026-04-22 codex second-opinion 회고 기반. rein 자체의 README 재작성 cycle 산출물. "rein update" 등 rein-specific 표현
- `versioning.md`: 2026-04-19/20/21 3일간 11개 버전 릴리즈 회고 기반. Rule A/B/C 가 rein 의 release 운영 회고에 specific

사용자 입장에서 본인 프로젝트와 무관한 회고록을 받게 됨. branch-strategy.md 결정 자체의 결함.

## 완료 기준

- [x] DoD 작성
- [ ] branch-strategy.md 수정 (포함 → 제외)
- [ ] dev commit (단방향 원칙: dev 에서 먼저)
- [ ] main 머지 (별 cycle, 내일 — Rule B 준수)

## 라우팅 추천

```yaml
agent: docs-writer
skills: []
mcps: []
rationale:
  - 작업 성격: 단일 docs/rules 파일 1개 수정 (branch-strategy.md)
  - 변경 규모: 작음 (포함→제외 이동, ~10줄)
  - 검증: subagent-review.md 의 docs-only chore 예외 적용 가능
approved_by_user: true   # 사용자 명시 "A로 변경해" (2026-04-27)
```
