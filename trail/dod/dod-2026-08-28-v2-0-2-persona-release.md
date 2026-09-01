---
approved_by_user: true
plan ref: 없음 (릴리스 배포 — 설계 사이클 불요, 기능은 dod-2026-08-28-persona-selection-ui.md 에서 완료·리뷰됨)
---

# DoD: v2.0.2 배포 — 페르소나 선택 UI 개선 + 표시 이름 현지화 사용자 릴리스

이미 dev 에서 완료·리뷰된 페르소나 선택 UI 개선 작업(`dod-2026-08-28-persona-selection-ui.md`,
spec 5R user-approved + plan 5R PASS + 웨이브별 코드/보안 리뷰 PASS + 전체 테스트 GREEN)을
사용자에게 배포한다. 버전 2.0.1 → 2.0.2 (patch).

## 범위

- 버전 표면 2곳(`plugins/rein-core/.claude-plugin/plugin.json` + `scripts/rein.sh`)을
  2.0.1 → 2.0.2 로 승격 (parity).
- CHANGELOG + README(en/ko)에 v2.0.2 사용자 대면 항목 추가 (최신 릴리스 요약 갱신).
- 이미 dev 에 있는 페르소나 소스·테스트를 main 에 선별 체크아웃 후 tag v2.0.2 + 공개 미러 + 마켓 발행.

Rule B 예외 명시: 2026-08-28 이미 v2.0.0/v2.0.1 배포. 오늘 세 번째 배포는 사용자 명시 결정
("지금 2.0.2로 패치올려", 2026-08-28)에 따른 것. hotfix 아님(UX 개선) — 사용자 권한으로
Rule B advisory 를 우회한 배포임을 정직하게 기록.

포함하지 않음 (의도적 축소):
- 신규 기능/코드 변경 없음 — 페르소나 기능은 이미 완료·리뷰됨. 본 DoD 는 버전 승격 + 배포만.
- 설계 문서(`docs/specs`·`docs/plans`)는 main 제외 대상 — 선별 체크아웃 세트에서 제외.

## 변경 파일

- `plugins/rein-core/.claude-plugin/plugin.json` (버전 2.0.1→2.0.2)
- `scripts/rein.sh` (VERSION 2.0.1→2.0.2)
- `CHANGELOG.md` (v2.0.2 항목 추가)
- `README.md` + `README.ko.md` (최신 릴리스 요약 v2.0.1→v2.0.2 로 갱신, v2.0.1 을 이전으로 내림)
- (main 선별 체크아웃 대상, 운영 기록 4 — branch-strategy trail 포함 규정) `trail/index.md`,
  `trail/dod/dod-2026-08-28-v2-0-2-persona-release.md` (본 문서),
  `trail/dod/dod-2026-08-28-persona-selection-ui.md`,
  `trail/inbox/2026-08-28-persona-display-name-ui.md`
- (main 선별 체크아웃 대상, dev 기존 커밋) 페르소나 소스 7 + 테스트 6:
  `plugins/rein-core/rules/persona/{boss-ace,jennie,choi-haengbae}.md`,
  `plugins/rein-core/rules/short/persona-summary.md`,
  `plugins/rein-core/scripts/rein-policy-loader.py`, `scripts/rein-policy-loader.py`,
  `plugins/rein-core/skills/persona/SKILL.md`,
  `tests/scripts/{test-persona-lint,test-persona-preset-greeting,test-policy-loader-turn-brief}.sh`,
  `tests/hooks/{test-session-start-persona-inject,test-session-start-byte-budget}.sh`,
  `tests/skills/test-persona-skill.sh`

## 검증 기준

- [ ] 두 버전 표면이 2.0.2 로 일치 (parity — plugin.json + rein.sh).
- [ ] 페르소나 테스트 스위트 전량 GREEN (`tests/{scripts,hooks,skills}/run-all.sh` 관련분).
- [ ] main 트리 preflight 시뮬레이션 통과 (dev-green ≠ main-green 방지 — 태그 직전 main worktree 배터리).
- [ ] main 선별 체크아웃 후 `git status --short` 에 예상 외 파일 0.
- [ ] tag v2.0.2 생성 + 공개 미러 strip 검증(`docs/specs`·`docs/plans`·`trail`·`.rein`·`AGENTS.md` 미노출) + 마켓 발행 success.

## 라우팅 추천

approved_by_user: true

- 릴리스 배포 (신규 설계·구현 없음, 버전 bump + 선별 머지). 버전 bump 소스 편집분에
  `rein:codex-review`(VER-1 게이트) + `rein:security-reviewer`(버전 문자열 변경이라 표면 최소).
