# v1.2.0 cycle Wave 1 완료 — 잔여 fix B/C/D/E + drift sync

- 날짜: 2026-05-14
- 유형: feat (cycle 진행 중, Wave 1 종결)
- 변경 파일:
  - `tests/scripts/test-version-parity.sh` (Fix C, Scope ID 정정)
  - `tests/scripts/run-all.sh` (Fix C, test-version-parity.sh 등록)
  - `tests/scripts/test-plugin-scripts-bundle.sh` (Fix E, count 10→8 + SOURCES 정리)
  - `tests/hooks/test-bootstrap-check-helper.sh` (Fix D, fixture A/D/E/F/G/H/I/J marker + 신 K/L)
  - `plugins/rein-core/hooks/lib/bootstrap-check.sh` (Fix D, bilingual guidance 정정)
  - `plugins/rein-core/hooks/post-edit-plan-coverage.sh` (Fix B, VALIDATOR resolver)
  - `plugins/rein-core/hooks/stop-session-gate.sh` (Fix B, AGGREGATE_PY + EMIT_PY resolver)
  - `plugins/rein-core/hooks/session-start-load-trail.sh` (Fix B, 4 helper resolver)
  - `plugins/rein-core/hooks/post-write-spec-review-gate.sh` (Fix B, 사용자 안내 메시지 정정)
  - `scripts/rein-policy-loader.py` (drift sync, v1.1.1 hotfix backport)

## 요약

직전 turn 의 Wave 1 partial 에서 남았던 fix 4건 + 발견된 source/mirror drift 1건을 모두 처리. Phase 1 (Contract repair) 의 9 Scope IDs 중 8개 완료 (잔여 SEC-1, SEC-2 는 Wave 2 의무).

## 처리 내역

### Fix C — VER-1 LOW 2 (small)
- `test-version-parity.sh` L20 Scope ID 주석을 spec 정식 ID 로 교체 (`VER-1-plugin-json-version-field-bumped-to-1-2-0-and-rein-publish-script-aborts-on-pre-publish-mismatch-between-plugin-json-and-rein-sh-version`)
- `run-all.sh` 에 `test-version-parity.sh` 호출 추가 (test-plugin-skills-bundle.sh 다음 위치)
- 검증: `bash tests/scripts/test-version-parity.sh` → `version-parity OK: 1.2.0`

### Fix E — RES-2 HIGH 1 (small)
- `test-plugin-scripts-bundle.sh` 의 `SOURCES`/`DESTS`/`EXECUTABLE_DESTS` 에서 폐기된 `.claude/hooks/lib/portable.sh` + `python-runner.sh` 2 엔트리 제거 (Option C Phase 3 cleanup 누락분 정리)
- count 10 → 8 변경 (assertion + header + final OK 메시지)
- composition history 주석에 2026-05-13 Option C Phase 3 변경 추가
- 검증: `bash tests/scripts/test-plugin-scripts-bundle.sh` → `OK (8 helpers mirrored sha256-identical)`

### Fix D — BG-1 HIGH 3 (medium)
- `bootstrap-check.sh` 의 bilingual guidance 정정 — `trail/ 디렉토리가 없습니다` → `trail/ 또는 .rein/project.json marker가 없습니다` (BG-1 신 contract 의 `trail/ AND .rein/project.json` 둘 다 부재 case 까지 포괄)
- `test-bootstrap-check-helper.sh` 에 helper 함수 `mk_bootstrap_marker` 추가 (DRY)
- 기존 fixture A/D/E/F/G/H/I/J 가 trail/ 만 만들던 것을 helper 호출로 통일 — trail/ + .rein/project.json 둘 다 생성 (BG-1 신 contract)
- 신 fixture K 추가 — trail/ only → exit 10 (BG-1 false positive 제거 회귀 방지)
- 신 fixture L 추가 — marker only → exit 10 (BG-1 symmetric)
- fixture B 의 메시지 검증에 `trail/` + `.rein/project.json` 두 substring 모두 grep 추가
- 검증: `bash tests/hooks/test-bootstrap-check-helper.sh` → `pass=17 fail=0 skip=0`

### Fix B — RES-1 medium-large (4 hook resolver sourcing)
- `post-edit-plan-coverage.sh` — VALIDATOR 변수를 `resolve_helper_script rein-validate-coverage-matrix.py` 로 lazy resolve (`[ -f "$VALIDATOR" ]` graceful skip 유지)
- `stop-session-gate.sh` — 상단에 AGGREGATE_PY 정의 + 4 호출 변환 (trap, advisory_check, 메인 aggregate, count-pending). EMIT_PY 도 같은 줄에서 resolver 로 변환.
- `session-start-load-trail.sh` — HEAL_SCRIPT, AGGREGATE_PY, SCAN_SKILL_MCP, GEN_SKILL_MCP 4개 변수를 상단에서 resolve, 7 호출 변환. SessionStart 는 fail-open (resolver lib source 실패 시 빈 변수로 graceful degrade). 사용자 안내 메시지의 hardcoded path 도 helper short name + 위치 hint 로 정리.
- `post-write-spec-review-gate.sh` — 사용자 안내 메시지의 hardcoded `bash scripts/...` 만 정정 (소스 호출은 부재)
- 검증: `bash tests/hooks/test-plugin-script-path-resolver.sh` → `6 passed, 0 failed`. 4 hook 모두 `bash -n` syntax OK. 잔존 hardcoded `scripts/rein-` paths 0 (CLAUDE_PLUGIN_ROOT-only 정책 loader 제외).

### 보너스 — rein-policy-loader.py source/mirror drift
- 발견: `plugins/rein-core/scripts/rein-policy-loader.py` (8119B, v1.1.1 hotfix, 2026-05-12) 가 `scripts/rein-policy-loader.py` (6751B, 2026-05-11) 보다 newer
- 원인: v1.1.1 bootstrap-gate hotfix 시 plugin source 만 패치, repo `scripts/` 본체로 backport 누락
- 사용자 승인 후 `cp plugins/rein-core/scripts/rein-policy-loader.py scripts/rein-policy-loader.py` 로 sync
- UMBRELLA_KEYS 추가 코드 + bootstrap-gate umbrella 토글이 source 로 backport 됨
- 검증: 두 파일 sha256 동일 (`ffc866d5...`), bundle test PASS

## 회귀 차단 status

| Test | Result |
|---|---|
| `tests/hooks/test-plugin-script-path-resolver.sh` | 6/6 PASS |
| `tests/hooks/test-bootstrap-check-helper.sh` | 17/17 PASS (2 신 case 포함) |
| `tests/scripts/test-plugin-scripts-bundle.sh` | OK (8 mirrors) |
| `tests/scripts/test-version-parity.sh` | OK 1.2.0 |
| 4 hook `bash -n` syntax | 모두 OK |

## 다음 세션 진입점

**Wave 2 (sequential, 2 task)** — SEC-1 (bootstrap profile-only) → SEC-2 (security-reviewer priority list resolve). SEC-3 (Task 1.5) 의 standard.md 가 이미 ship 되어 의존성 OK. 이어서 Wave 3 (parallel 3 task: OPSEQ-1, WF-1, RTG-1) → Wave 4 (sequential 2 task: INC-1 → RTG-2) → 통합 review (codex + security) → main 머지 + tag v1.2.0 + push.

**DoD checklist 갱신**: Phase 1 의 BS-1/2, SEC-3, RES-1 (Wave 1 + Fix A + Fix B), RES-2, TST-1, VER-1 (Wave 1 + Fix C), BG-1 (Wave 1 + Fix D) 모두 완료 ✓. 잔여 Phase 1 = SEC-1, SEC-2 (Wave 2 의무).

## 보너스 회고

- `incident decline` 결정으로 첫 source 편집 차단 해제 (Wave 1 partial 이 만든 self-generated 부산물 2건)
- `stale spec review pending` 1건 (`docs/specs/foo.md`) 정리 — heal 로직이 file 부재로 skip 한 legacy marker
- inbox 의 16 지점 예상 → 실측 14+ 지점. 메시지 안내까지 합치면 16 근접

## 참고

- branch=dev 유지
- 본 turn 의 변경 중 `tests/scripts/test-plugin-scripts-bundle.sh` 의 `plugins/rein-core/scripts/` mirror 가 단일 정직 SSOT 이라는 점 + RES-2 의 `rein-mark-spec-reviewed.sh`, `rein-codex-review.sh`, `rein-validate-coverage-matrix.py` 3 helper 가 모두 SOURCES 에 포함되어 있어 RES-2 의 presence assertion 도 충족
