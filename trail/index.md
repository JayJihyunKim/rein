# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **v1.6.3 릴리스 대상 (dev 커밋, 미push·미릴리스)**: 페르소나 사용자 선택+커스텀(`909f8c5`~`99dae03`)·변경 시그니처 인사말(`9e886c3`~`7a8bebc`)·인사말 다듬기(대화 언어 적응·전환 메타금지·jennie 문구, `88ba9b6`) + codex 리뷰 시간상한 워치독(`068b14f`~`2c7a875`). 각 사이클 codex/보안 리뷰 통과(codex 워치독 정지 다수→sonnet 대체 또는 자체리뷰 종결). 기계판정 minor→**사용자 결정 patch(1.6.3)**. 후속 Low: 닫는 fence 느슨·로더 greeting L4필터·Scope ID 신설(위협모델·형식). 상세: `trail/` 의 persona-* / review-time-cap 사이클 기록.
- **직전 완료 (릴리스)**: **v1.6.2 (2026-07-22)** dev `f29792e`/main `a7062b0`/tag `v1.6.2` push+publish+mirror success (public plugin.json 1.6.2 도착, 내부 기록 404 strip, public tag clean `35350db`, GitHub Release Latest 게시). **리뷰 사이클 효율화** — A 무상태 자가검증 관문(변경=diff∪untracked∪취득실패 fail-closed 시 codex spawn 이전 로컬검증 증거 강제: 두 축 [axis] exit0 블록+diff_self_review, none 폴백, TDD red escape, 미충족 exit 4)+C envelope 출력축소(REIN_REVIEW_VERBOSE=1 복원, FINAL_VERDICT 계약 불변). 신규 스위트 2개(69+19 단언)+하네스 파급 정리, 전 스위트 GREEN+미러 parity. 리뷰: codex R1 NEEDS-FIX(untracked 우회 High 등) 반영→R2 codex 30분+ 행→대체 리뷰 통과(codex_timeout 정직 기재)+보안 PASS, 릴리스면 codex 1R 지적 1건 정정+릴리스 사이클 보안 재검토 PASS. 등급: 기계판정 minor, **사용자 결정 patch(1.6.2)**. 후속(Low): untracked envelope 노출 이관, 안전 초기화 env 상속 위생, 리뷰 시간상한. 상세: `trail/inbox/2026-07-22-release-v162.md` + `2026-07-21-review-cycle-efficiency-impl.md`.
- **직전 완료 (릴리스)**: **v1.6.1 (2026-07-13)** dev `b23c34d`/main `c5f5c88`/tag `v1.6.1` push+publish+mirror success (public plugin.json 1.6.1 도착, 내부 기록 404 strip, public tag clean `2bd5369`, GitHub Release Latest 게시). **묶음 3건** — ①리뷰 증거 기계화(요청서 정량/PASS 주장에 [EVIDENCE] 블록 요구, 없으면 codex 호출 전 exit 4. spec 5R/plan 7R/통합 8R PASS+보안 PASS, 스위트 142+회귀 GREEN, 도그푸딩 실동작 2회) ②index 줄수 편집시점 게이트(codex 5R+보안 PASS) ③trail 부산물 위생(jsonl 21파일 제거+커서 untrack). 등급: 기계판정 minor, **사용자 결정 patch(1.6.1)** — CHANGELOG 병기. 릴리스 중 사건: main 전환이 옛 커서 복원→이력 재집계 incident 18건(전부 되감기 부산물로 종결, 커서 untrack ship 으로 클래스 소멸). 후속(Low): stderr 발췌 제어문자 소독, 대형 diff 리뷰 시간상한. 상세: `trail/inbox/2026-07-13-review-evidence-manifest-impl.md` 외 3건.
- **이전 완료 (릴리스)**: **v1.6.0 (2026-07-10)** main `b815f85`/tag `v1.6.0` (public clean `dc76c4c`). **codex 모델 프로필 라우팅** — 게이트 `gpt-5.6-sol` 고정+effort 가변, /codex-ask 3계층(luna/terra/sol), canonical fallback, 위험경로 floor, 도장 증빙 5필드. **minor**. 후속 Low 3+이월 2: `trail/inbox/2026-07-10-codex-model-profile-routing.md`. 교훈: spec 헤딩 `## Scope Items` 정확 일치, 보안면제는 단일-clause commit 만.
- **이전 완료**: v1.5.8 릴리스(2026-06-26, effort 결정론적 산출, patch — 후속 Info 2건+content_sha 미적용) / GitHub Releases 백필 31개+DoD 21건 아카이브(2026-07-03, `trail/inbox/2026-07-03-github-releases-backfill.md`).
- **이전 릴리스**: v1.5.7(`059ed70` helper 호출 `${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/` 정정, 06-18), v1.5.6(`0777835` 문서·운영기록·버전문자열-only 커밋 보안 재검토 자동 면제 — 단일-clause 전경 `git commit` 만, 06-17), v1.5.5(`fd61010` 마커 감사 백로그 M1~M4 봉합, 06-16), v1.5.4(`f6f6b6c` 자동모드 안내 정정, 06-15), v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소, 06-11), v1.5.1(`e470def` 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋, 06-09), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
