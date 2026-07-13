# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **직전 완료 (2026-07-13)**: ① **trail 부산물 위생** — meta-check jsonl 텔레메트리 retire(소비자 0건, env opt-in trace 로 테스트 oracle 유지), 런타임 커서 3종 untrack, jsonl 20개·legacy 로그 삭제. patch. 상세: `trail/inbox/2026-07-13-trail-byproduct-hygiene.md`. ② **index 줄수 작성시점 게이트** — 편집 결과 5~25줄 위반 즉시 차단(신규 훅 `pre-edit-index-lines.sh`, 15픽스처), 종료 게이트는 이중방어 유지. codex 5R PASS(상대경로·MultiEdit 실계약 결함 리뷰가 적발)+보안 PASS. minor 편승. 상세: `trail/inbox/2026-07-13-index-line-limit-at-write.md`. ③ 개선 백로그 5+2건 codex 이중검증 확정: `trail/inbox/2026-07-13-pipeline-improvement-backlog.md`. AGENTS.md 규칙 1건 승격(inbox 기록은 소스 편집 종료 후). ④ **리뷰 증거 기계화 구현 완료** — 래퍼 사전검사(정량/PASS 주장에 [EVIDENCE] 블록 없으면 codex 호출 전 exit 4 거부, envelope 슬롯 2종+Claim Audit 교차확인), brainstorm→spec 5R→plan 7R→병렬구현→통합리뷰 8R PASS+보안 PASS(Low 1 이월). 스위트 142건+회귀 4종 GREEN, 도그푸딩 실동작 2회(증거 요구·블록 상한 거부). minor 편승. 상세: `trail/inbox/2026-07-13-review-evidence-manifest-impl.md`.
- **이전 완료 (릴리스)**: **v1.6.0 (2026-07-10)** dev `fb0e2c1`/main `b815f85`/tag `v1.6.0` push + publish + mirror success (public: plugin.json 1.6.0 도착, trail/AGENTS.md/.rein/docs-specs 404 strip, public tag clean `dc76c4c`, GitHub Release Latest 게시). **codex 모델 프로필 라우팅** — codex 0.144.1 gpt-5.6 세대 대응: 게이트 `gpt-5.6-sol` 고정+effort 가변, /codex-ask 3계층(luna/terra/sol), canonical fallback(무모델 degrade 폐지), 위험경로 floor(low→medium), 도장 증빙 5필드, ultra/max/xhigh 거부. 규모기반 모델 라우팅은 codex-ask 독립의견으로 기각. spec 4R/plan 4R/코드 3R+릴리스면 2R PASS+보안 PASS(2회), 테스트 90/90+회귀 GREEN. **minor** (게이트 모델 변경+ask 라우팅 신설, Rule A). 도장에 증빙 실기록·`effort_source: marker` 오버라이드 경로 실전 검증. 후속(Low 3+이월 2: terra 그림자 평가, xhigh 실측): `trail/inbox/2026-07-10-codex-model-profile-routing.md`. 릴리스 교훈: DoD `## 범위 연결`+`covers: [...]` 대괄호, spec 헤딩 `## Scope Items` 정확 일치, 보안면제는 단일-clause commit 만.
- **이전 완료 (2026-07-03)**: GitHub Releases 백필 v1.1.0~v1.5.8 31개 + 묵은 DoD 21건 아카이브. 상세: `trail/inbox/2026-07-03-github-releases-backfill.md`.
- **이전 릴리스**: **v1.5.8 (2026-06-26)** dev `e39eda8`/main `7ffbbe3`/tag `v1.5.8` (public tag clean `48e2da6`) — codex 리뷰 effort 결정론적 산출(변경 규모 기반 low|medium|high, 마커 우선, 측정 실패 high). patch. 비차단 후속: Info 2건(numstat 숫자 가드, spec wc 경로 봉쇄), 보안표식 content_sha 미적용.
- **종결 (2026-07-10 실측)**: 보안-surface 면제 미발동 진단 — **회귀 아님, 명령 형태 문제 확정**. v1.6.0 릴리스에서 단일-clause `git commit`(버전+문서 5파일, trail-only 각각)은 면제 정상 발동, `git add && git commit && ...` 다중-clause 만 `SECURITY_REVIEW_STALE` 차단. staged-set 분류 가설 기각. 교훈=릴리스 커밋은 add/commit 분리 + 단독 clause (기존 메모와 v1.5.6 스펙 명세대로 동작).
- **이전 릴리스**: v1.5.7(`059ed70` helper 호출 `${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/` 정정, 06-18), v1.5.6(`0777835` 문서·운영기록·버전문자열-only 커밋 보안 재검토 자동 면제 — 단일-clause 전경 `git commit` 만, 06-17), v1.5.5(`fd61010` 마커 감사 백로그 M1~M4 봉합, 06-16), v1.5.4(`f6f6b6c` 자동모드 안내 정정, 06-15), v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소, 06-11), v1.5.1(`e470def` 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋, 06-09), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
