# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **방금 완료(미커밋, 미릴리스)** = 페르소나/규칙 주입 truncation 수정(`trail/inbox/2026-06-11-persona-injection-truncation-fix.md`, PT-1~PT-12). 세션시작 단일봉투 22.6KB 가 per-hook cap 초과로 잘려 페르소나+4규칙이 모델 미도달하던 버그. 요약화+페르소나 격리 hook+매턴 단일spawn(--turn-brief)+per-hook byte예산 테스트. codex spec 4R(HIGH 6건)+code 2R(env 주입 결함 발견·수정)+보안 PASS, 전체 스위트 green. **다음**: 이 변경 릴리스 판단(hook 동작 변경=minor) 또는 백로그. **활성 백로그 = 후속 2건**(`trail/inbox/2026-06-09-wrapper-cycle-followups.md`): ① broader staged-review 전면설계(codex-review wrapper envelope 슬롯 일관성). ② perf3·json-parity baseline 테스트 실패 2건(이번 작업 무관, hooks.json EXTRA/bash-rules hot-path 영역). 자동모드 ON.
- **직전 완료 (릴리스)**: **v1.5.0 (2026-06-09)** dev `c1c20e9`/main `a7752e7`/tag `v1.5.0` push + publish + mirror success (public: 페르소나 boss-ace 1633B + wrapper REVIEW_SUBJECT 도착 + 버전 1.5.0, trail/AGENTS.md/.rein 404 strip 검증). **페르소나 프리셋** 신규기능(boss-ace 기본 ON opt-out, 말투만/판단 냉정, brainstorm→spec→plan→Wave 병렬구현→codex+보안 PASS) + **codex-review wrapper 결함 6건**(config경로/exit-code fail-open/verdict tail-match/리뷰대상 모드 일관성 — drift sync 가 6 round self-review 로 노출, reproduction-first, codex R6 PASS+보안 PASS, 2사본 byte-identical, 45/45) + 버그 2건(active-DoD 마커신뢰+governance-e2e). **minor**(Rule A; 같은 날 v1.4.7 후 추가 배포는 사용자 결정 + 게이트 핫픽스 명분으로 Rule B override). 이전 **v1.4.7 (2026-06-09)** main `dbcfc8d` codex 리뷰 모델 gpt-5.5 통일.
- **2026-05-28 회고 (v1.4.0 release 묶음)**: 오늘 5 cycle (communication-improve / worker contract + PLN1 enforce / AG-2 dogfood 4-worker / backlog 3-track cherry-pick / release prep) 의 dev 20 commits 통합. 사용자 결정으로 minor bump (Rule A advisory 따라). main 선별 체크아웃 = plugins/rein-core/** + tests/** + trail/** + 4 scripts/rein* + CHANGELOG (메인테이너 .claude/** + docs/** + 루트 임시 노트 제외). dev rotation 으로 archive 처리된 22 stale 파일 main 에서 동시 rm. 묶인 5 cycle 의 자세한 회고는 trail/inbox/2026-05-28-*.md.
- **이전 릴리스**: v1.4.7(`dbcfc8d` codex 리뷰 모델 gpt-5.5 통일, 2026-06-09), v1.4.6(`521ab6a` codex 모델 단일 출처+fail-soft, 2026-06-08), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷, 2026-06-05), v1.4.3(`644422f` spec-writer+plan-path+perf, 2026-06-02), v1.4.2(`e76763d` parallel-execute, 2026-06-01), v1.0.0(2026-04-30 OSS launch). **현재 버전**: 1.5.0 main `a7752e7`/tag `v1.5.0`.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
