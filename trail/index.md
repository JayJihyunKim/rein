# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **다음 작업 = v1.5 (state.json canonical화 + `rein status`, 플랜 §7)** — split state 정규화, 넓은 인프라 작업. codex 재조정 순서: (1) ~~SR-1~~✅ → (2) ~~GE-1+GE-2~~✅ → **(3) v1.5** → (4) G8-3/job-stop/BC-INFO1/G3/A-LowPrio/SR-1.b. 상세 = `need-to-confirm.md`.
- **직전 완료 (dev)**: **GE-1+GE-2 완료 (2026-05-22, dev `9f2ff18` 다음, 미커밋→커밋 예정)** — wrapper/selector 무결성. GE-1: selector Tier 1 marker path containment(공용 `path-containment.sh` 추출 → selector + session-start 공유, helper 부재 fail-closed) / GE-2: `_resolve_diff_base` 가 fresh stamp diff_base 를 `rev-parse ^{commit}` + `merge-base --is-ancestor` 검증(forged/orphan/other-branch SHA → HEAD~1). 9파일, 테스트 全 GREEN, codex PASS + security PASS(0 findings, adversarial 검증). 디버깅: nounset `${BASH_SOURCE[0]:-}` + sandbox helper 복사. need-to-confirm GE-1/GE-2 → confirmed.md 이관.
- **이전 완료 (dev)**: **SR-1 완료 (2026-05-22, dev `9f2ff18`)** — spec-review gate stale `.reviewed` 우회 2겹 차단(post-edit `.reviewed` 제거 + pre-edit freshness). 27/27, codex R3 PASS, security PASS. 잔존 SR-1.b(low, post-edit hook 미발화 갭 — pre-existing). confirmed.md.
- **직전 완료 (릴리스)**: **v1.3.4 배포 완료 (2026-05-22) — 검증 6/6 PASS**. main `ad6b098`, tag `v1.3.4`, marketplace publish + public mirror(`f01b7c9`). 정리 후보: main 잔존 `.rein/policy/router/*.yaml`(public strip 되므로 무해 — 차후 머지서 git rm).
- **이전 완료**: 2026-05-22 **v1.3.4 구현** (B1/B2/B3/B6/B7+S+D). / 2026-05-22 X4.C.5 atomic state fast-path (영역 C close). / 2026-05-22 영역 D 기각. / 2026-05-20 **v1.3.3 릴리즈** (main `0f7e3ef`, tag `a4995c3`). / 2026-04-30 v1.0.0 OSS launch.
- **버전**: plugin.json = scripts/rein.sh VERSION = **1.3.4** (parity OK). main = origin/main = `ad6b098`, annotated tag `v1.3.4` → `ad6b098`. public mirror tag = `f01b7c9`(strip commit). v1.3.4 = patch (버그·위생·문서, 확정안 §0.5).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
