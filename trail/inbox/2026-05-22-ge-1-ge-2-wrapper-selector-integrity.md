# GE-1 + GE-2 wrapper/selector 무결성 묶음

- 날짜: 2026-05-22
- 유형: fix (security hardening)
- 변경 파일:
  - `plugins/rein-core/hooks/lib/path-containment.sh` (신규 — 공용 containment validator)
  - `plugins/rein-core/hooks/lib/select-active-dod.sh` (GE-1 Tier 1 containment)
  - `plugins/rein-core/hooks/session-start-load-trail.sh` (GE-1 inline 4-check → helper 리팩토링)
  - `plugins/rein-core/scripts/rein-codex-review.sh` + `scripts/rein-codex-review.sh` (GE-2, 2-사본 byte-identical)
  - `tests/hooks/test-path-containment.sh` (신규 6건), `tests/hooks/test-select-active-dod.sh` (+2), `tests/skills/test-codex-review-stale-stamp.sh` (Test1 갱신 +3), `tests/skills/test-codex-review-wrapper.sh` (sandbox helper 복사)

## 요약

2026-04-26 wrapper-context-lifecycle hardening 이 의도적으로 deferred 한 (OQ-9/OQ-11/Non-functional) 잔존 risk 2건을 닫음.

- **GE-1** — selector(`select-active-dod.sh`) Tier 1 marker 가 `[ -f ]` 존재만 검사 → 오염된 `.active-dod` 가 프로젝트 외부 경로를 가리키면 blocking authority 획득. fix: 공용 `validate_repo_relative_path` (allowlist + `..` + realpath/commonpath) 추출 → selector 가 Tier 1 채택 전 검증(helper 부재 시 fail-closed=Tier 2 강등) + session-start cleanup 의 inline 4-check 를 같은 helper 로 교체(reason 보존, drift 제거).
- **GE-2** — `_resolve_diff_base` 가 fresh stamp 의 `diff_base:` SHA 를 무검증 채택 → forged/orphan/other-branch SHA 주입. fix: `git rev-parse --verify ^{commit}` + `git merge-base --is-ancestor HEAD` 둘 다 통과해야 채택, 실패 시 HEAD~1 fallback(OQ-3 fail-safe). stamp schema 불변.

## 검증

- TDD: 우회 시나리오(외부경로 marker / forged·orphan·other-branch SHA) failing test 선작성 → 구현.
- 테스트 GREEN: path-containment 6/6, select-active-dod 11/11, session-start-cleanup 17/17, stale-stamp 8/8, wrapper 26/26, spec-review-gate 27/27, pre-edit-dod-gate 14/14, pre-bash-test-commit-gate 14/14, state-fast-path 10/10.
- codex 코드리뷰 (high) PASS — containment 완전성(encoded/leading-./trailing-slash/symlink chain)·selector root(전 caller cd PROJECT_DIR)·GE-2 ancestor 로직·nounset/set-e 안전성·2-사본 parity 독립 확인, 결함 0.
- security 리뷰 (full, standard) PASS, 0 findings — adversarial 우회 시도(디렉토리 symlink escape, embedded newline, hostile git base 문자열) 전부 차단·injection 없음 확인. fail-closed 방향성 sound(deleting hook 관대 + consuming hook 엄격).

## 디버깅 기록 (재현)

- 초기 wrapper 테스트 26→-43/69 폭주: `select-active-dod.sh` 가 `${BASH_SOURCE[0]}` (nounset)를 참조 → wrapper 의 `set -euo pipefail` + `if ! . lib` 컨텍스트에서 "parameter not set" → exit 1 전파. fix: `${BASH_SOURCE[0]:-}` + 파일 존재 가드.
- 잔존 2건(Tier 1 marker false-reject): wrapper/stale-stamp sandbox 가 selector 만 복사하고 신규 sibling `path-containment.sh` 미복사 → fail-closed 가 valid marker 거부. fix: 두 sandbox 셋업에 helper 복사 추가(정당한 의존성 plumbing).

## 사전 실패 (무관, 본 작업 밖)

- `test-background-jobs-registered.sh` (hooks.json PreToolUse Bash matcher), `test-project-dir-resolution.sh` (2 FAIL/21), 통합 `test-fresh-design-spec-review-no-fallback.sh` (dangling marker) — 모두 baseline(GE stash)에서도 동일 실패. selector/wrapper 영역 밖.

## 라우팅 피드백

- agent: 메인 세션 직접(DoD 추천=feature-builder-fix, 컨텍스트 완비로 메인 채택). reproduction-first TDD 적합.
- skills: rein:codex-review — nounset 회귀를 테스트가 먼저 잡았고 codex 가 최종 확인. 효과적.
