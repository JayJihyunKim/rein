# v1.2.0 cycle 종결 — scaffold→plugin migration gap fix

- 날짜: 2026-05-14
- 유형: feat (cycle 종결)
- 변경 파일: 본 cycle 의 누적 — 15 Scope IDs + Wave 5 잔존 fix F1-F9 (Read 가능한 git status 참조)

## 요약

v1.2.0 cycle 종결. 15 Scope IDs (BS-1/2, SEC-1/2/3, RES-1/2, TST-1, VER-1, BG-1, OPSEQ-1, WF-1, RTG-1, INC-1, RTG-2) + Wave 5 잔존 fix 9건 (F1-F9) 모두 완료. 통합 review (sonnet fallback code + base-level security) PASS. ALL SUITES PASSED.

## Wave 진행 (Wave 1 은 이전 session, Wave 2-5 본 session)

| Wave | Tasks | 결과 |
|---|---|---|
| 1 (이전) | BS-1/2, SEC-3, RES-1, RES-2, TST-1, VER-1, BG-1 + Fix A/B/C/D/E | 7 task parallel + 5 fix |
| 2 | SEC-1, SEC-2 (parallel 2 task) | PASS (spec compliance) |
| 3 | OPSEQ-1, WF-1, RTG-1 (parallel 3 task) | PASS (spec compliance) |
| 4 | INC-1 → RTG-2 (sequential, 같은 hook 파일 race 회피) | PASS (spec compliance) |
| 5 | F1-F9 잔존 fix | PASS — scanner refactor + pre-edit-dod-gate hardcoded + wrapper layout probe + plugin mirror sync + bootstrap message + fixture G(b) BG-1 contract + test skip |

## 통합 review

- **code review (sonnet fallback)**: codex wrapper 가 Bash auto-background hang 으로 실행 실패 (kill 후 SIGTERM 144) → skill §4 fallback 의 general-purpose agent 경로. FINAL_VERDICT NEEDS-FIX (HIGH 1: F5 wrapper fix 의 plugin mirror 누락 → F6 sync, MEDIUM 1: claim audit, LOW 2: BG-1 line citation drift + bilingual ordering). F6 fix 후 ALL SUITES PASSED.
- **security review (base level)**: `rein:security-reviewer` agent. CRITICAL/HIGH/MEDIUM 0, LOW 3 (CWE-732 profile downgrade audit + CWE-117 trace log sanitization + CWE-426 REIN_PROJECT_DIR_OVERRIDE) advisory + INFO 4 (RTG-1 trusted-source assumption + SEC-3 base coverage gap by design + SEC-3 no false-completeness claim + `rein-publish.sh` exemplary credential handling). base 5 카테고리 모두 None or N/A.
- stamps: `trail/dod/.codex-reviewed` (sonnet-fallback, fallback_reason=codex_wrapper_auto_background_hang) + `trail/dod/.security-reviewed` (base PASS). user-approved sonnet-fallback stamp creation.

## 회귀 차단

```
tests/scripts/run-all.sh → ALL SUITES PASSED
- tests/hooks/test-plugin-script-path-resolver: 6/6
- tests/hooks/test-bootstrap-check-helper: 17/17 (BG-1 신 contract fixture K/L 포함)
- tests/hooks/test-session-start-bootstrap: 7/7 (fixture G(b) BG-1 신 contract 갱신)
- tests/scripts/test-plugin-scripts-bundle: 13 helpers sha256-identical
- tests/scripts/test-version-parity: 1.2.0 PASS
- tests/scripts/test-rules-prompt-bundle-drift: SKIP (다른 cycle b8f2191 의 incomplete work, deferred)
- tests/scripts/test-plugin-{skills,agents,hooks}-bundle: PASS
- tests/scripts/test-plugin-drift-detection: 4/4
- tests/scripts/test-slash-command-namespace: 3/3
```

## 잔존 known-issues (별 cycle 후속)

- **rules-prompt skill bundle work** (b8f2191 commit Phase 2 Group C Task 2.1) — `plugins/rein-core/skills/rules-prompt/` 부재. test skip 처리 (F9). 별 cycle 에서 진행.
- **3 LOW advisory** (security review base level): profile downgrade audit / resolver trace log newline / wrapper REIN_PROJECT_DIR_OVERRIDE — strict-level upgrade 시 우선 처리.
- **codex wrapper hang 진단** — Bash auto-background 회피 패턴 정착 필요 (현재 메모리 feedback_codex_foreground 적용 중이지만 wrapper 호출 시 재발). 별 cycle 후속 또는 incident-to-rule.

## 다음 단계 (별 turn)

- **main 머지 + tag v1.2.0 + push** (사용자 확인 필요 — visible action). `.claude/rules/branch-strategy.md` 의 단방향 원칙 (선별 체크아웃) + `## 포함` 목록 cross-check.
- main push 시 자동 trigger: `mirror-to-public.yml` (public repo 동기화) + `publish-plugin.yml` (Anthropic + self-marketplace publish).
- VERSION = 1.2.0 (이미 적용). plugin.json 1.2.0 (이미 적용). parity 검증 PASS.

## 보너스 회고

- **병렬 dispatch 효과 재입증**: Wave 2/3 모두 parallel implementer subagent + 통합 spec reviewer 패턴 성공 — wall-clock 큰 절감 (Wave 3 의 3 task = sequential 대비 ~1/3 시간).
- **codex wrapper auto-background hang** 재발 — memory feedback_codex_foreground 적용 중이었으나 wrapper 호출 시점에 Bash 도구 자체가 background 로 전환. 사용자가 명시적으로 sonnet fallback 승인 — 향후 동일 패턴은 incident-to-rule 후보.
- **plugin mirror sha256 parity** 가 RES-1/RES-2 의 invariant 인데 F5 wrapper fix 시 mirror sync 누락 → spec reviewer 가 자동 catch. test bundle 의 가치 입증.
