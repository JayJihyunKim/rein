# v1.3.8 release prep — CHANGELOG 통합 entry + main 머지

- 날짜: 2026-05-27
- 유형: release prep (docs + version tagging)
- plan ref: 없음 (단발 release cycle)
- 선행 commit: dev `2b4ece9` (backlog cleanup)

## 범위

dev 에 누적된 v1.3.8 작업 (plugin install hotfix `cb4d997` + G3 `021bbf9` + TONE-1 `413169d` + 자동모드 `080455e` + backlog cleanup `2b4ece9`) 을 main 으로 머지 + tag `v1.3.8`. CHANGELOG 의 v1.3.8 entry 가 hotfix-only 라 오늘 추가 user-facing 변경 (G3 routing-map / meta-check / `## 변경 파일` 의무 / TONE-1 response-tone / 자동모드 marker+스킬+silent) 을 통합 entry 로 확장.

## 변경 파일

### dev step (release prep)

- `CHANGELOG.md` (modify — v1.3.8 entry 확장: hotfix + G3 + TONE-1 + 자동모드 통합)
- `trail/dod/dod-2026-05-27-v1-3-8-changelog-release-prep.md` (본 DoD)
- `trail/dod/.active-dod` / `.codex-reviewed` (light tier)
- `trail/inbox/2026-05-27-v1-3-8-release.md` (완료 시점)
- `trail/index.md` (다음 진입점 갱신 — release 후 상태)

### main step (선별 체크아웃, branch-strategy.md §포함 목록)

- `plugins/rein-core/**` (전체 변경 파일)
- `scripts/rein.sh` (VERSION=1.3.8 이미)
- `tests/**` (5 신규 + 회귀 갱신)
- `trail/**` (DoD/inbox/index/stamps)
- `CHANGELOG.md` (위 확장 entry)
- `.rein/project.json` (단일 파일, 변경 없으면 skip)
- `AGENTS.md` (변경 없으면 skip)

### main step (제외)

- `.claude/**` (Option C Phase 3 폐기, dev-only)
- `docs/specs / docs/plans / docs/brainstorms / docs/reports` (메인테이너 dev-only)
- `need-to-confirm.md`, `confirmed.md` (메인테이너 임시 노트)

## 검증 기준

1. **사용자 명시 버전**: 1.3.8 (사용자 turn 2026-05-27)
2. **plugin.json + scripts/rein.sh parity**: 둘 다 `1.3.8` (확인 완료)
3. **versioning Rule A advisory**: 오늘 변경이 user-facing 신규 기능 다수라 minor bump (v1.4.0) 가 advisory checklist 권고이지만, 사용자가 v1.3.8 (patch) 로 명시 결정 — Rule A 는 advisory hard gate 아님, 사용자 결정 우선
4. **versioning Rule B (같은 날 복수 bump 금지)**: 위반 없음 (직전 release v1.3.7 = 2026-05-24, 오늘 = 2026-05-27, 3일 간격)
5. **CHANGELOG Rule C (user-facing only)**: 통합 entry 가 user-facing 항목만 포함 (G3 routing-map / meta-check advisory / `## 변경 파일` 의무 / TONE-1 응답 톤 / 자동모드 marker+스킬+silent — 모두 사용자 관찰 가능)
6. **tag 존재**: `git tag -l v1.3.8` 부재 확인 (신규 tag)
7. **main 머지 후**: `claude plugin validate plugins/rein-core` PASS / public mirror strip 검증 (`mirror-to-public.yml` 이 자동 실행)
8. **branch-strategy 단방향**: main 에서 직접 편집 안 함, `git checkout dev -- <file>` 만

## 라우팅 추천

agent: rein:docs-writer
skills:
  - rein:codex-review
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  release prep — CHANGELOG markdown 편집 + git tag + push. 코드/hook 영향 0
  (오늘 dev 작업의 코드 변경은 이미 prior cycle 들에서 리뷰/테스트 완료).
  security_tier: light 적정.

  사용자 명시 "메인 머지부터 진행. 버전 1.3.8" = implicit routing approval.
  branch-strategy.md 절차 준수 (선별 체크아웃, 단방향, CLAUDE.md @import 제거).
