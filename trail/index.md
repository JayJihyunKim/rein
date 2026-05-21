# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **통합 master plan 활성 — `docs/plans/2026-05-20-integrated-roadmap.md` 우선 read**. **다음 권장 cycle = 영역 D (release gate 분리 + v1.3.3 main 머지)** — 본 plan 마지막 영역. ✅ X1 + ✅ v1.3.3 + ✅ X2 + ✅ X3.E.3 + ✅ X3.B.0/B.1+B.2/B.5 + ✅ X4.C.0/C.1/C.2 + ✅ X4.C.3 (4 hook fast-path) + ✅ **X4.C.4 (SPIKE + Q-1 + (b) + (c), 2026-05-21)**. **X4.C.4 결과 PARTIAL — 영역 C 일시 close**: M2 answer-skip 32ms 절약, M1 +59~77ms / M2 source_edit +66~68ms common-case net regression, M3 neutral. Q-1 → 두 dirty layer 분리 유지. (b) TOCTOU → 단일 writer 모델 하 실질 누출 0 + atomic 결합 후속 후보 (M1 net -1~+21ms = break-even/약 회귀). (c) security profile → base→standard upgrade 적용. report: `docs/reports/2026-05-21-area-c-state-machine-spike.md`. 잔존: 영역 D (다음), X4.C.5 atomic 결합 (선택, 영역 D 와 병렬 가능), X3.B.3 (선택). main = origin/main = **`0f7e3ef`** (v1.3.3, 불변).
- **이전 완료**: 2026-05-20 **v1.3.3 릴리즈** (main `0f7e3ef`, annotated tag, public mirror + 마켓플레이스 publish workflow 트리거됨 — Phase 4 short rule injection ~92% / cold-path skip). / 2026-05-19 v1.3.2. / 2026-05-18 v1.3.1. / 2026-05-15 v1.3.0. / 2026-04-30 v1.0.0 OSS launch.
- **버전**: dev VERSION = **1.3.3** (X2 미bump — internal hook 인프라 refactor, user-facing CLI 표면 변화 없음). main = origin/main = **1.3.3** (annotated tag `v1.3.3` → `0f7e3ef`, 불변). 다음 bump 후보: X3/X4/X5 누적 후 평가 — X2 의 hooks.json structure 변화는 plugin internal 이라 minor 미해당 가능성.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
