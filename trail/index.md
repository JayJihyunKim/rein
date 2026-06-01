# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **병렬 실행 재설계 — Phase 1~4 전부 완료, 다음=main 병합(버전 bump 판정)** (2026-05-30~06-01). 기존 PLN-1/AG-2 병렬 워커 폐기 → plan `depends_on` 웨이브 + 같은 트리 + 부모 통합 + Rein 스킬(`parallel-execute`) 재설계 종결. dev 커밋: Phase 1 `20f3bb9`·`9ec1b90`·`d40234b` / Phase 2 `17c8898`(스킬, 6093byte) / Phase 3 `91349f1`(plan-writer v2 + PLN-1 게이트 제거 + 워크트리 기계 폐기, 병렬 3워커) / Phase 4 `<this>`(스케줄러+델타 동작 테스트 + agents 러너 신설). 각 Phase codex+security 리뷰 PASS(Phase 2 security medium·Phase 4 codex high 둘 다 해소·재리뷰 PASS). **미푸시·미병합**. 미진행:
  - **main 병합**: 이번 시리즈(Phase 1~4) + 5/31 게이트우회 가드레일(`b3986ef`+`bdf6433`) 누적. 새 user-exposed 스킬(parallel-execute) 추가 → **minor bump 후보**(시리즈 종결 후 일괄 판정). 게이트우회 가드레일은 patch 급.
  - **구조적 관찰(미조치)**: CI(tests.yml)가 agents/skills/rules 러너 미invoke — 신규 스케줄러/델타 테스트는 scripts 러너라 CI 도달하나, parallel-execute 스킬 테스트·plan-writer v2 테스트는 로컬 전용. CI 확장 별 결정.
  - 문서: `docs/{brainstorms,specs,plans}/2026-05-30-plan-driven-wave-parallel-execution.md`. 그 외 active 후보: G3-perf-NFR / public repo strip spot-check.
  - **06-01 추가 (오버레이 정리, 미커밋)**: codex-ask 판단 → `.claude/` dev 오버레이가 plugin SSOT와 중복·stale 참조로 세션 혼란. CLAUDE.md 슬림 + orchestrator/workflows/registry/plans 9파일 삭제 + 전 표면 폐기경로 참조 정리(AGENTS.md·govcheck·plugin 규칙 2건 포함, govcheck는 plugin 훅 스캔으로 재지정). codex R4 PASS + 보안 light PASS. 대부분 dev 전용(릴리스 영향 0), AGENTS/govcheck/plugin규칙만 main-bound(patch급). DoD `dod-2026-06-01-claude-overlay-cleanup`.
- **2026-05-28 회고 (v1.4.0 release 묶음)**: 오늘 5 cycle (communication-improve / worker contract + PLN1 enforce / AG-2 dogfood 4-worker / backlog 3-track cherry-pick / release prep) 의 dev 20 commits 통합. 사용자 결정으로 minor bump (Rule A advisory 따라). main 선별 체크아웃 = plugins/rein-core/** + tests/** + trail/** + 4 scripts/rein* + CHANGELOG (메인테이너 .claude/** + docs/** + 루트 임시 노트 제외). dev rotation 으로 archive 처리된 22 stale 파일 main 에서 동시 rm. 묶인 5 cycle 의 자세한 회고는 trail/inbox/2026-05-28-*.md.
- **직전 완료 (릴리스)**: **v1.4.1 (2026-05-29)** dev `bfecf81`/main `ee34fc3`/tag `v1.4.1` push 성공. 언어 수정 + SR-1.b 게이트 정확도(mtime→content_sha) + spec-gate tests/ 예외 + P10/wrapper 가드 — dev 누적 4 patch 번들. 통합 codex+security PASS(22파일, 차단0). publish + mirror GH Actions 진행 중.
- **이전 릴리스**: v1.4.0(`a474ea4`/`v1.4.0` 응답톤+worker+spec-review backstop, 2026-05-28), v1.3.8(`c273add` plugin install hotfix+G3+TONE-1, 2026-05-27), v1.3.7(`5f9791f` BC-INFO1 클래스 종결, 2026-05-24), v1.3.6(`f76cf05` G8-3+job-stop), v1.3.5(`11a849e` SR-1+GE-1+GE-2), v1.0.0(2026-04-30 OSS launch). **현재 버전**: 1.4.1 main `ee34fc3`/tag `v1.4.1`.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
