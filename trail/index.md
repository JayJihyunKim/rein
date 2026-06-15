# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **dev 에 미릴리스 수정 1건 대기** (2026-06-15) — 외부 제보 검증발: ① 자동모드 스킬 문서 정정(자동모드는 incident 블록만 silent, inbox/index 작업증거 종료차단은 자동모드여도 발동을 명시) ② 메타체크 방치-untracked false-positive 수정(세션시작 mtime-window 필터 + fail-open, 재현 fixture F14/F15/F16). 두 리뷰 PASS·테스트 GREEN·미커밋. 릴리스(patch=hook 동작변경 user-facing) 별도 승인 대기. 상세 trail/inbox/2026-06-15-automode-doc-fix-metacheck-untracked.md. 후속 후보: ⓑ **CI 자동 테스트 0건**(전 워크플로 workflow_dispatch) + 러너 미등록, ⓒ 적대적 우회 하드닝은 위협모델 밖 **보류**. (ⓐ 보안도장 내용 stale 은 이번 security-reviewer 가 content-rich 도장으로 실증 — files/threat/evidence 기록됨)
- **직전 완료 (릴리스)**: **v1.5.3 (2026-06-12)** dev `f373569`/main `079c616`/tag `v1.5.3` push + publish + mirror success (public: plugin.json 1.5.3 + 신설 lib `git-subcommand-model.sh` 도착, trail/AGENTS.md/.rein 404 strip 검증, public tag `0dc9c11`=clean commit). 게이트 false-negative 4건 봉합: 커밋탐지 약한매칭(`git -C`/더블스페이스/글로벌옵션) canonical SSOT화 + 머지 면제 메시지 오매칭 제거 + 소스 판정 확장자 추가(Go/루트) + 정책 체크 python3 fail-open→fail-closed. brainstorm→spec(codex 4R)→plan(codex 5R)→Wave병렬구현(GMF-1‖GMF-3→GMF-2→GMF-4, TDD red 선행)→통합 codex+보안 PASS, 5스위트 199 green. **patch** (hook 동작변경=user-facing 버그수정, Rule A). 위협모델: 정직한 에이전트 규율까지.
- **이전 릴리스 (직전)**: **v1.5.2 (2026-06-11)** main `c8dba3b`/tag `v1.5.2` — 리뷰 오탐 감소 + marker 오삭제 근본원인 + SIGPIPE fail-open 2건 봉합.
- **이전 릴리스**: v1.5.1(`e470def` 페르소나/규칙 주입 truncation 수정 — per-hook cap 초과로 페르소나 미도달, 2026-06-11), v1.5.0(`a7752e7` 페르소나 프리셋 신규 + wrapper 결함 6건, 2026-06-09), v1.4.7(`dbcfc8d` codex 모델 gpt-5.5 통일, 2026-06-09), v1.4.6(`521ab6a` 모델 단일 출처+fail-soft, 2026-06-08), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷, 2026-06-05), v1.0.0(2026-04-30 OSS launch). 2026-05-28 v1.4.0 묶음 회고는 trail/inbox/2026-05-28-*.md.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
