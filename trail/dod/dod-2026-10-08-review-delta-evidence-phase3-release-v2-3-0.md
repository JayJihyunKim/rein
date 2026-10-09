# DoD: 리뷰 델타 증거·원칙·기본 모델 사이클 Phase 3 — 코드 리뷰·보안 리뷰·커밋 + v2.3.0 릴리스

- 작성일: 2026-10-08
- plan ref: docs/plans/2026-10-07-review-delta-evidence-and-defaults.md
- 사용자 지시: "릴리즈해" (2026-10-08). 직전 기준서(`dod-2026-10-07-review-delta-evidence-and-defaults.md`)가 구현·테스트에서 닫혔고, 그 기준서와 plan Phase 3 이 "리뷰·보안·커밋은 사용자 별도 승인 후 후속 기준서" 로 정한 그 후속 기준서다. 릴리스까지 한 번에 묶는다.
- 등급 근거(versioning Rule A): 사용자 프로젝트의 리뷰 요청서 작성법·검토자 판정 지시문·에이전트 실행 모델·응답/작업 규칙이 바뀌는 user-facing 신규 동작 → **minor, v2.3.0**. breaking 아님(CLI·exit code·훅 차단 범위 불변 — 래퍼 로직 0줄 변경). Rule B: 2026-10-08 첫 main 머지. Rule C: 테스트·메인테이너 규칙·설계 문서는 CHANGELOG 제외.
- 상태 확인(2026-10-08): 원격 Actions 는 여전히 결제 문제로 모든 런이 수 초 내 실패 → v2.2.0 과 같은 **로컬 검증·로컬 미러·로컬 발행 자체 검사** 절차.

## 범위

IN
1. 코드 리뷰 — `/codex-review` 1회(두 웨이브 델타 전체 + 아래 2 의 릴리스 변경, 하나의 트리). 요청서는 자가검증 두 축 계약 + `diff_self_review:`.
2. 릴리스 변경(같은 커밋): `scripts/rein.sh` `VERSION="2.2.0"`→`"2.3.0"`, `plugins/rein-core/.claude-plugin/plugin.json` `"version"`→`2.3.0`, `CHANGELOG.md` `## Unreleased` → `## v2.3.0 — 2026-10-08 (…)`, `README.md`·`README.ko.md` 릴리스 히스토리(최신 = v2.3.0, 이전 = v2.2.0, 두 언어 병렬).
3. 보안 리뷰 — 지휘 경로: 부모가 subject 캡처 → `rein:security-reviewer` 워커 디스패치 → 확인 → 발급(`agents/orchestrator.md` 발급 절차).
4. 커밋 — feature 브랜치에 구현+릴리스 변경 1커밋(`feat:`), 계획 산출물·trail 회전·완료 기록은 별도 `docs:`/`chore(trail):` 커밋(같은 리뷰 트리 안). dev 로 `--no-ff` 병합, `origin dev` push.
5. main 선별 반영 — 격리 worktree, `branch-strategy.md` 포함 목록만 `git checkout dev -- <paths>`; `.claude/**` 제외; `bash -n` 훅·스크립트; 커밋 `chore: v2.3.0 — …`; 태그 `v2.3.0`; `origin main` + 태그 push(Actions 실패는 무시).
6. 로컬 미러 — `mirror-to-public.yml` strip 단계를 main 임시 클론에서 재현(미러·tests·publish 워크플로, AGENTS.md, blocks 로그, `.rein/`, `trail/` 제거) → public main force-push → strip 커밋을 `refs/tags/v2.3.0` 으로 push → `git ls-remote` 사후 검증.
7. 로컬 발행 자체 검사 — main 클론에서 `REIN_PUBLISH_SELF_HOSTED_ONLY=1 bash scripts/rein-publish.sh 2.3.0`(tarball·manifest 생성 + drift·version parity). 저장소에 커밋하지 않음.
8. GitHub Release — 공개 태그 확인 후 `gh release create v2.3.0 --repo JayJihyunKim/rein --title … --notes-file …`(gh 2.4.0 — `--verify-tag`·`--latest` 없음). 본문 = CHANGELOG user-facing 항목.
9. 완료 기록(`trail/inbox/2026-10-08-review-delta-evidence-phase3-release-v2-3-0.md`) + `trail/index.md` 직전 릴리스 갱신.

OUT
- 구현 내용 변경 — 리뷰 지적 수정 외에는 없음. 지적 수정은 이 기준서 아래에서(같은 31개 경로 안, 밖이면 사용자 확인).
- 원격 CI 실행·Actions 결제 복구 — 사용자 계정.
- 두 번째 사이클(프로젝트 정의 사전검사 훅, `rein job` 중복 거부·진행률).

## Definition of Done

- [x] 코드 리뷰 통과 기록 + 보안 검토 통과 기록(두 v2 증거) → feature 커밋 → dev 병합·push
- [x] main `chore: v2.3.0` 커밋 + 태그 push, 공개 저장소 main·태그 = strip 커밋, GitHub Release Latest
- [x] 완료 기록·index 갱신

## 검증 기준

- `git log --oneline -1 origin/dev` 가 병합 커밋, `git tag -l v2.3.0` 존재, `git ls-remote --tags origin v2.3.0` 1건
- `git ls-remote --tags https://github.com/JayJihyunKim/rein.git v2.3.0` 1건 + 공개 main 이 strip 커밋(`git ls-remote https://github.com/JayJihyunKim/rein.git HEAD`)
- 공개 strip 트리에 `trail/`·`.rein/`·`AGENTS.md`·`.github/workflows/{mirror-to-public,tests,publish-plugin}.yml` 부재
- `gh release list --repo JayJihyunKim/rein --limit 2` 에 v2.3.0
- main 트리: `grep '^VERSION="2.3.0"' scripts/rein.sh`, `plugin.json` 2.3.0, `README.md`·`README.ko.md` 최신 v2.3.0, `rg '[ㄱ-힝]' README.md` 0건(코드 블록 제외)
- main 트리 `bash -n` 훅·스크립트 전부 통과, `python3 scripts/rein-check-plugin-drift.py` exit 0, 다섯 러너 실패 집합이 dev 와 동일

## 라우팅 추천

agent: rein:feature-builder
orchestration: main-session-orchestrated
worker_strategy: 보안 검토만 `rein:security-reviewer` 워커(부모 발급). 나머지(리뷰 요청·커밋·병합·main 반영·미러·발행·Release)는 부모가 직접 — 전부 금지목록(커밋·스테이징·발급·trail) 항목이라 워커에 못 맡김
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 코드 변경 없음, 절차 실행 — 리뷰·발급·커밋은 부모 소유
approved_by_user: true  # "릴리즈해" (2026-10-08)

## 범위 연결

plan ref: docs/plans/2026-10-07-review-delta-evidence-and-defaults.md
work unit: Phase 3 (별도 승인 후): 리뷰 · 보안 리뷰 · 커밋 + 릴리스
covers: [RDE-WRAP-NOLOGIC, RDE-UNCHANGED, RDE-TESTS]

## 변경 파일

- scripts/rein.sh
- plugins/rein-core/.claude-plugin/plugin.json
- CHANGELOG.md
- README.md
- README.ko.md
- trail/inbox/2026-10-08-review-delta-evidence-phase3-release-v2-3-0.md
- trail/index.md
