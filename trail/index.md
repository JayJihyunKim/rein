# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.4.7 이후 dev 누적 → 내일 main 배포**(오늘 v1.4.7 배포 + Rule B 로 오늘 추가 배포 불가). 누적 3묶음: ① 버그 2건(`87e6eee` active-DoD 마커신뢰 + `4d6385e` governance-e2e 부활) ② **페르소나 프리셋 신규기능**(`302b138`, 설계체인 `de55889`) — 기본 `boss-ace`(호칭 '보스'+과잉충성 톤, 판단·경고 냉정), 기본 ON opt-out, 세션1회주입+매턴 nudge off, path주입 방어. brainstorm→spec→plan→구현(Wave 병렬)→codex+보안 PASS ③ **codex-review wrapper 결함 6건**(`baec1d1`) — config경로/exit-code fail-open/verdict tail-match/리뷰대상 모드 일관성(changed_files·claim_sources·라벨·지시문). drift sync 가 6 round self-review 로 누적 결함 6건 노출, 전부 reproduction-first+codex PASS(R6)+보안 PASS, 2사본 byte-identical, 테스트 45/45. Rule A 복합 → **minor 1회**. **후속**(`trail/inbox/2026-06-09-wrapper-cycle-followups.md`): broader staged-review 전면설계(brainstorm) + perf3·json-parity baseline 실패(무관, 별도 수정). 자동모드 OFF.
- **직전 완료 (릴리스)**: **v1.4.7 (2026-06-09)** dev `3de74bd`/main `dbcfc8d`/tag `v1.4.7` push + publish + mirror success (public: CODE_MODEL=gpt-5.5 도착, trail/AGENTS.md/.rein strip 검증). codex `CODE_MODEL` gpt-5.3-codex-spark→gpt-5.5 로 코드·문서(설계/플랜) 리뷰 모델 통일(역할 변수 2개 유지, 미래 재분리 여지) + spec-writer/plan-writer 옛 라벨 gpt-5.4 정합(어제 단일 출처 작업 변경파일 누락 드리프트). 강도 질문은 현행 유지(사용자 결정). codex 코드리뷰 PASS(gpt-5.5 첫 dogfood)+보안 PASS+release self-review, 테스트 15/15 + run-all 33/33. 이전 **v1.4.6 (2026-06-08)** main `521ab6a` codex 모델 단일 출처+fail-soft.
- **2026-05-28 회고 (v1.4.0 release 묶음)**: 오늘 5 cycle (communication-improve / worker contract + PLN1 enforce / AG-2 dogfood 4-worker / backlog 3-track cherry-pick / release prep) 의 dev 20 commits 통합. 사용자 결정으로 minor bump (Rule A advisory 따라). main 선별 체크아웃 = plugins/rein-core/** + tests/** + trail/** + 4 scripts/rein* + CHANGELOG (메인테이너 .claude/** + docs/** + 루트 임시 노트 제외). dev rotation 으로 archive 처리된 22 stale 파일 main 에서 동시 rm. 묶인 5 cycle 의 자세한 회고는 trail/inbox/2026-05-28-*.md.
- **이전 릴리스**: v1.4.6(`521ab6a` codex 모델 단일 출처+fail-soft, 2026-06-08), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷, 2026-06-05), v1.4.4(`70fba39` ROUTE-BIND-1, 2026-06-04), v1.4.3(`644422f` spec-writer+plan-path+perf, 2026-06-02), v1.4.2(`e76763d` parallel-execute, 2026-06-01), v1.0.0(2026-04-30 OSS launch). **현재 버전**: 1.4.7 main `dbcfc8d`/tag `v1.4.7`.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
