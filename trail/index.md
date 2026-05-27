# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.3.8 release main 머지 + tag + push 진행 중** (사용자 명시 patch bump). origin/dev force-with-lease 정리 완료 (Hermes 4 commits → hermes-experimental-2026-05-26 branch 보존). main push 후 mirror-to-public + publish-plugin GH Actions 자동 실행. 남은 백로그 3건 모두 보류/low: PLN-1+AG-2 / SR-1.b / G3 perf NFR follow-up.
- **2026-05-27 회고 (release prep + confirmed 이관, dev `2b4ece9`)**: CHANGELOG v1.3.8 entry hotfix-only → 통합 (routing-map / meta-check / `## 변경 파일` 의무 / response-tone / 자동모드). plugin.json+rein.sh `1.3.8` parity OK. need-to-confirm TONE-1+자동모드 strike + 상세 awk 제거 → confirmed 이관.
- **2026-05-27 회고 (자동모드 `080455e` + TONE-1 `413169d`)**: 자동모드 = marker + helper + 토글 스킬 2 + 5 hook silent (block 포함 + audit log, codex usage limit → sonnet-fallback PASS). TONE-1 = response-tone.md(983B) + UserPromptSubmit TONE_BODY 합류 (codex R1 NEEDS-FIX → R2 self-review PASS).
- **2026-05-27 회고 (G3 ship, dev `021bbf9`)**: 9 Scope ID 전부 — routing-map + post-edit-meta-check (~270 line) + 5 agent + 회귀 5 테스트(15+5+6+1). codex R3 PASS (Fix A~H), security PASS, 의도된 spec 편차 2건. design phase = brainstorm+spec+plan stamps 2 PASS.
- **직전 완료 (릴리스)**: **v1.3.7 (2026-05-24)** dev `b4261b2`/main `a50fb33`/tag/public `5f9791f`(strip). BC-INFO1 git-env trust-boundary 클래스 완전 종결 + A-LowPrio. siblings/2/3 worktree 격리 agent teams 병렬, codex PASS + security 0. publish + mirror GH Actions success.
- **직전 완료 (릴리스)**: **v1.3.6 (2026-05-23)** dev `8cca729`/main `698f38a`/tag/public `f76cf05`(strip). 실제 버그 3건 patch: G8-3 + job-stop + BC-INFO1. codex R1 NEEDS-FIX→R2 PASS, security 0. v1.5~1.7 로드맵=보류(felt value 약함).
- **이전 완료 (릴리스)**: **v1.3.5 (2026-05-22)** main `f7b3209`/public `11a849e`(strip) — SR-1+GE-1+GE-2 patch. **v1.3.4** main `ad6b098`/public `f01b7c9`. **v1.3.3** 2026-05-20. **v1.0.0** 2026-04-30 OSS launch.
- **현재 버전**: 1.3.7 (parity OK). main `a50fb33`/tag `v1.3.7`/public `5f9791f`(strip).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
