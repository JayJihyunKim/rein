# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **v1.3.4 릴리스 완료 (2026-05-22)**. dev 커밋 `d61aea8`(release 5파일: plugin.json+rein.sh 버전 동기화, CHANGELOG, README KR/EN) + trail 커밋. codex Round 1 NEEDS-FIX(버전 parity broken — rein.sh 미동기화) → 수정 → Round 2 PASS. v1.3.4 hook 테스트 PASS. main 선별 체크아웃 + tag `v1.3.4` + push + 배포 진행. 후속 후보: B2 verb allowlist 한계(rg/xxd 등), S3 state-paths mode 결정, need-to-confirm.md 미해결(G8-3 1순위·GE-1/2·SR-1).
- **이전 완료**: 2026-05-22 **v1.3.4 구현** (B1/B2/B3/B6/B7+S+D, dev, codex+security 통과). / 2026-05-22 X4.C.5 atomic state fast-path (영역 C close). / 2026-05-22 영역 D 기각. / 2026-05-20 **v1.3.3 릴리즈** (main `0f7e3ef`, tag `a4995c3`). / 2026-04-30 v1.0.0 OSS launch.
- **버전**: dev plugin.json = **1.3.4** = scripts/rein.sh VERSION (parity OK). v1.3.4 = patch (버그·위생·문서, 확정안 §0.5). main/tag 최종 sha 는 머지·태그 후 갱신.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
