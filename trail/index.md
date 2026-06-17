# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.5.6 릴리스 진행 중** (dev 완료, main 머지+태그+public mirror 검증 남음). 다음 = main 선별 체크아웃 → tag v1.5.6 → push(publish+mirror) → public strip/parity 검증 → index 최종 갱신. 남은 후보: A1/E2 문서 한 줄 정정, CI 자동테스트 0건(workflow_dispatch만), routing 블록 reason echo sanitize, **audit 로그 churn**(면제 커밋마다 `security-surface-exempt.log` 1줄 append→tree dirty; gitignore 검토). 위협모델 밖 보류: 도장 원자성·blocks.jsonl 락(D1/D2).
- **직전 완료 (dev)**: **commit-gate 보안-surface 면제 (2026-06-16~17)** dev `d0b9a3e`(feat)+`fac2000`(릴리스 버전범프). 문서(`*.md`/`docs`/`trail`)·버전문자열-only(`rein.sh` VERSION 라인/`plugin.json` top-level version semantic JSON) 커밋이면 보안 재검토(P6+M2) 자동 면제 → M2 릴리스 마찰 근본 해결. 명령형태 = **단일-clause 종착 규칙**(전경 단독 `git commit <allowlist>` 만; multi-clause/wrapper/cd/env/글로벌옵션/쉘평가/서브셸/백그라운드 `&` → 전부 fail-closed). 명시 허용목록 외 전부 보안 관련=fail-closed. brainstorm→spec→plan(codex PASS)→구현→통합 codex 4R(R2 비-git clause skip·R3 백그라운드 봉합)+보안 PASS. 테스트 104+15 GREEN. ✅ **dogfood 실증**: v1.5.6 버전범프 커밋(`fac2000`)이 단독 `git commit` 으로 면제 발동(audit `staged_files=5 docs=3 version=2`) — 보안 재검토 없이 통과. ⚠️ **정정**: 활성 게이트는 캐시(1.5.4)가 아니라 **워킹트리 훅**이다(M2·면제 라이브). 앞서 실커밋이 면제 안 된 건 `cd …; git commit`(다중 clause)을 써서였지 캐시 때문이 아님 — [[reference_plugin_directory_marketplace_lifecycle]].
- **직전 릴리스**: **v1.5.5 (2026-06-16)** dev `fd61010`/main `ff05a3d`/tag `v1.5.5` (public tag clean `60e7a1e`, strip 검증). 마커 감사 백로그(M1~M4) 봉합 — M2 보안표식 신선도/cycle/verdict + M3 코드표식 dual-read 등. (M2 dogfood 주장은 워킹트리 훅 기준으로 정상 — 위 정정 참조.)
- **이전 릴리스 (직전)**: **v1.5.4 (2026-06-15)** main `f6f6b6c`/tag `v1.5.4` — 자동모드 안내 정정 + 메타체크 방치-untracked 거짓경고 제거.
- **이전 릴리스**: v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소 + marker 오삭제 근본원인, 06-11), v1.5.1(`e470def` 페르소나/규칙 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋 + wrapper 결함 6건, 06-09), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
