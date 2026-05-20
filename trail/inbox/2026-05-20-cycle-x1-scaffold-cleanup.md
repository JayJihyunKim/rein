# Cycle X1 — scaffold 잔존 청소 (E.1 + E.2)

- 날짜: 2026-05-20
- 유형: refactor
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.5 영역 E.1 + E.2, §5.1 cycle X1
- DoD: trail/dod/dod-2026-05-20-cycle-x1-scaffold-cleanup.md
- 변경 파일:
  - tests/rein-test.sh (재작성, -215/+98 줄)
  - docs/plans/2026-05-20-integrated-roadmap.md (§3.3 / §4.5 / §5 갱신)
  - trail/dod/dod-2026-05-20-cycle-x1-scaffold-cleanup.md (신규)

## 요약

**E.1 (tests/rein-test.sh 갱신)**: v1.0.0 에서 폐기된 `rein new` 명령 + scaffold 시대의 `rein merge`/`update` 산출물 assertion 제거. 현 `scripts/rein.sh` 의 dispatch 표면만 검증으로 재작성 — `--help`/`--version`/plugin redirect (update, merge)/unknown command exit 1 (rein new 회귀 trap 포함)/job subcmd 분기 (no-arg, unknown, list smoke)/no-arg invocation. 15/15 PASS. bootstrap 산출물 검증은 `tests/hooks/` + `tests/integration/` suite 가 담당.

**E.2 (bootstrap drift 점검)**: 두 본 (`scripts/rein-bootstrap-project.py` 33-line, `plugins/rein-core/scripts/rein-bootstrap-project.py` 580+ line) 비교 + sandbox 호출 검증. **drift 아님 — 의도된 layered SSOT**: root 는 `runpy.run_path()` wrapper, plugin 이 실제 SSOT. `.claude/rules/branch-strategy.md` RES-1 plugin-aware resolver 정책 (`CLAUDE_PLUGIN_ROOT/scripts` 우선, repo `scripts/` fallback) 과 일치. sandbox 호출 시 산출물 (`.rein/project.json`, `.claude/security/profile.yaml`, `.rein/policy/{hooks,rules}.yaml`, `trail/` 7 subdir + `trail/index.md`) 정상 생성. 단일화 불필요.

## 리뷰

- codex Round 1 NEEDS-FIX: DoD `## 범위 연결` 섹션 누락 → fix (covers: [] empty array, plan 의 matrix 부재와 일관성)
- codex Round 2 PASS: stamp `trail/dod/.codex-reviewed` (reviewer=codex, diff_base=b2ccf7f, verdict=PASS)
- security: tier=light + approved_by_user=true → stamp 생략 (operating-sequence step 6 예외). self-review: secret/외부 input boundary/신규 command exec 도입 없음

## 테스트

- `bash tests/rein-test.sh` → 15/15 PASS
- `bash tests/hooks/run-all.sh` → ALL SUITES PASSED (회귀 0)

## 버전 영향

VERSION bump 없음 (internal scaffold 청소 — `.claude/rules/versioning.md` Rule A no-bump 카테고리). dev VERSION = 1.3.3 유지.

## 다음

Cycle X2 = 영역 A (Bash dispatcher 통합). plan §4.1 + §5.1 X2 권장.
