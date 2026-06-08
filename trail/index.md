# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: codex 역할별 모델 단일 출처(`plugins/rein-core/config/codex-models.sh`)+모델 fail-soft 구현 완료 — **dev 미커밋, commit 승인 대기**. codex 리뷰 PASS(dogfood gpt-5.3-codex-spark, 4R; R4 에서 fail-soft 자체 오탐을 dogfood 가 포착 → FINAL_VERDICT 가드+회귀 T7)+보안 PASS, 테스트 15/15 + run-all 등록. 상세 `trail/inbox/2026-06-08-codex-model-profile-routing.md`. **발견 별개 이슈 2**: (1) active-DoD 선택기가 `## 범위 연결` 없는 plan-less DoD 거부(문서↔구현 drift; 리뷰는 유효, stamp 라벨만 부정확) (2) governance-e2e stale(폐기 `.claude/hooks/` 참조, baseline 동일). cross-ref 2건(v1.1.0 잔존 drift / perf Track C) 추적 유지. 자동모드 OFF.
- **직전 완료 (릴리스)**: **v1.4.5 (2026-06-05)** dev `2c39b68`/main `70ef345`/tag `v1.4.5` push 성공. 묶음 3: ONBOARD-1(첫 세션 온보딩 안내+핵심 게이트 teach-forward) + git 사실 자동 스냅샷(index 신선도 — 훅이 `.rein/state/git-snapshot.md` 자동 기록·SessionStart 주입, 권위 규칙+Stop advisory, 신규 lib `git-snapshot.sh` env위생·fresh-write-or-clear·백틱무력화) + ROUTE-DOC-1(라우팅 두 표 정합). 각 기능 codex+보안 PASS. 릴리스 chore 는 self-review(codex wrapper diff_base 오작동 폴백). 선별 체크아웃 28파일(plugins12/tests10/scripts2/루트4) + stale 테스트 1 rm. publish success + mirror success. 별건: Track C(perf defer) + codex wrapper active-DoD/diff_base 오라벨(verdict 정상, 신선도 테마 잔갈래).
- **2026-05-28 회고 (v1.4.0 release 묶음)**: 오늘 5 cycle (communication-improve / worker contract + PLN1 enforce / AG-2 dogfood 4-worker / backlog 3-track cherry-pick / release prep) 의 dev 20 commits 통합. 사용자 결정으로 minor bump (Rule A advisory 따라). main 선별 체크아웃 = plugins/rein-core/** + tests/** + trail/** + 4 scripts/rein* + CHANGELOG (메인테이너 .claude/** + docs/** + 루트 임시 노트 제외). dev rotation 으로 archive 처리된 22 stale 파일 main 에서 동시 rm. 묶인 5 cycle 의 자세한 회고는 trail/inbox/2026-05-28-*.md.
- **이전 릴리스**: v1.4.4(`70fba39`/`v1.4.4` ROUTE-BIND-1 설계 라우팅 nudge, 2026-06-04), v1.4.3(`644422f` spec-writer+plan-path+perf, 2026-06-02), v1.4.2(`e76763d` parallel-execute, 2026-06-01), v1.4.1(`ee34fc3` 언어수정+게이트, 2026-05-29), v1.4.0(`a474ea4` 응답톤+worker, 2026-05-28), v1.0.0(2026-04-30 OSS launch). **현재 버전**: 1.4.5 main `70ef345`/tag `v1.4.5`.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
