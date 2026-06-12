# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **게이트 false-negative 4건 수리 — dev 커밋 완료, 미push·미릴리스** (`8449114`, 2026-06-12). 정직한 에이전트인데 게이트가 조용히 미발동하던 구멍: ①커밋탐지 약한 매칭(`git -C commit`/더블스페이스), ②머지 면제 메시지 오매칭, ③소스 판정 디렉토리한정(Go/루트 누락), ④정책 체크 python3 fail-open. 신설 공유 lib(`git-subcommand-model.sh`)로 canonical 탐지 SSOT화, 3겹 fail-closed. brainstorm→spec→plan→Wave병렬구현(GMF-1‖GMF-3→GMF-2→GMF-4)→codex+보안 PASS. **다음 결정: push + 버전bump(patch=v1.5.3 후보) + main 머지 — 사용자 승인 대기**. 후속 검토 후보: ⓐ 보안 리뷰어 도장이 `touch`만 해 내용 stale 잔존(이번에 수동 정정) — 게이트-freshness 클래스, ⓑ skills 러너 CI 미등록 + CI 자동 테스트 0건(workflow_dispatch만), ⓒ 적대적 우회 하드닝(정책 kill-switch 보호·도장 content_sha)은 위협모델 밖으로 보류(사용자 결정).
- **직전 완료 (릴리스)**: **v1.5.2 (2026-06-11)** dev `032f96d`/main `c8dba3b`/tag `v1.5.2` push + publish + mirror success (public: plugin.json 1.5.2 + C1 hook·D2 wrapper 수정 도착, trail/AGENTS.md/.rein 404 strip 검증, public tag `ab99125`=clean commit). 리뷰 오탐 감소(Tier 2 추측 컨텍스트 advisory 정직화 A1~A5) + marker 오삭제 근본원인 C1 + SIGPIPE fail-open 2건(D1 fail-soft 가드 / D2 모드감지 — 코드게이트 오염 가능성) 봉합 + stale orphan 테스트 2건 삭제. TDD red 선행 11건, wrapper 54/54, 세 스위트 green, codex 3R(R2 가 D2 적발)+보안 PASS. **patch** — 같은날 v1.5.1 후 추가 배포는 게이트 무결성 hotfix 명분 + 사용자 결정 (Rule B override, hotfix for v1.5.1).
- **이전 릴리스**: v1.5.1(`e470def` 페르소나/규칙 주입 truncation 수정 — per-hook cap 초과로 페르소나 미도달, 2026-06-11), v1.5.0(`a7752e7` 페르소나 프리셋 신규 + wrapper 결함 6건, 2026-06-09), v1.4.7(`dbcfc8d` codex 모델 gpt-5.5 통일, 2026-06-09), v1.4.6(`521ab6a` 모델 단일 출처+fail-soft, 2026-06-08), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷, 2026-06-05), v1.0.0(2026-04-30 OSS launch). 2026-05-28 v1.4.0 묶음 회고는 trail/inbox/2026-05-28-*.md.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
