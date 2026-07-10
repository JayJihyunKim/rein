# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **직전 완료 (2026-07-10)**: **codex 모델 프로필 라우팅** (dev `de9ae01`, 설계 `8b9cb4c`, 미release) — codex 0.144.1 gpt-5.6 세대 대응: 게이트 `gpt-5.6-sol` 고정+effort 가변, /codex-ask 3계층(luna/terra/sol), canonical fallback(무모델 degrade 폐지), 위험경로 floor(low→medium), 도장 증빙 5필드, ultra/max/xhigh 거부. 규모기반 모델 라우팅은 codex-ask 독립의견으로 기각. spec 4R/plan 4R/코드 3R PASS+보안 PASS, 테스트 90/90+회귀 GREEN. **minor 후보 — main 머지/publish 별도 승인 대기**. 후속(Low 3+이월 2): `trail/inbox/2026-07-10-codex-model-profile-routing.md`.
- **이전 완료 (2026-07-03)**: GitHub Releases 백필 v1.1.0~v1.5.8 31개 + 묵은 DoD 21건 아카이브. 상세: `trail/inbox/2026-07-03-github-releases-backfill.md`.
- **직전 완료 (릴리스)**: **v1.5.8 (2026-06-26)** dev `e39eda8`/main `7ffbbe3`/tag `v1.5.8` push + publish + mirror success (public: plugin.json 1.5.8 도착, trail/.rein/AGENTS.md 404 strip, public tag clean commit `48e2da6`). **codex 리뷰 effort 결정론적 산출** — 래퍼가 마커 부재 시 변경 규모(코드 diff numstat / 문서 길이)로 low|medium|high 산출, 마커 우선(오버라이드 보존), 측정 실패 시 high(fail-closed). 항상-high 결함(실측 자동리뷰 61% high, high 중앙값=low의 2.9배 — `docs/reports/2026-06-26-codex-effort-measurement.md`) 해소. 근본원인=`[EFFORT:]` 생산 코드 0건 + 이중 high 폴백. brainstorm/spec(4R PASS)/plan/DoD 체인, 행위 테스트 29 + 회귀 GREEN, codex+보안 PASS. **patch**(게이트 오작동 수정=user-facing, Rule A). 비차단 후속: Info 2건(numstat 산술 숫자 가드, spec wc 경로 봉쇄 일관화), 보안표식 content_sha 미적용(touch 기반).
- **남은 진입점 후보**: **보안-surface 면제 미발동 근본원인 진단**. 증상: 문서/버전라인-only + trail 도장 staged 릴리즈 커밋이 깨끗한 메시지로도 `SECURITY_REVIEW_STALE` 차단 — v1.5.6 면제 미발동(2회). 점검: `pre-bash-test-commit-gate.sh` 의 `_sx_compute_security_surface_skip` staged-set 분류, spec `docs/specs/2026-06-16-commit-gate-security-surface-exempt.md`. 가설: README/CHANGELOG 또는 도장 staged 시 분류 실패. v1.5.6 회귀 가능성.
- **이전 릴리스**: **v1.5.7 (2026-06-18)** `059ed70`/tag `v1.5.7` (public tag clean `7e1ad7a`) — ship 문서 5개의 helper 스크립트 호출을 `${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/` 로 정정(플러그인 우선+repo 폴백). patch.
- **이전 릴리스**: **v1.5.6 (2026-06-17)** `0777835`/tag `v1.5.6` (public tag clean `d59c5134`) — 문서·운영기록·버전문자열-only 커밋은 보안 재검토 자동 면제(단일-clause 전경 `git commit` 만, 그 외 fail-closed). v1.5.5 M2 릴리스 마찰 근본 해결.
- **이전 릴리스 (직전)**: **v1.5.5 (2026-06-16)** dev `fd61010`/main `ff05a3d`/tag `v1.5.5` (public tag clean `60e7a1e`). 마커 감사 백로그(M1~M4) 봉합 — M2 보안표식 신선도/cycle/verdict + M3 코드표식 dual-read 등.
- **이전 릴리스**: v1.5.4(`f6f6b6c` 자동모드 안내 정정 + 메타체크 거짓경고 제거, 06-15), v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소 + marker 오삭제 근본원인, 06-11), v1.5.1(`e470def` 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋, 06-09), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
