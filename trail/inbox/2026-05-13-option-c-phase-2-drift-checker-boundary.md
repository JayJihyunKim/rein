# Option C Phase 2 — drift checker 의미 전환 + validator 흡수

- 날짜: 2026-05-13
- 유형: implementation (Phase 2, covers: S1 + S2 + S3)
- 변경 파일:
  - `scripts/rein-check-plugin-drift.py` (재작성 — boundary + parity + validation 통합)
  - `plugins/rein-core/scripts/rein-check-plugin-drift.py` (overlay 와 byte-identical sync)
  - `scripts/rein-validate-plugin-rules.py` (wrapper 화 — `main(["--skip-parity", "--skip-boundary"])`)
  - `.github/workflows/plugin-drift-check.yml` (transitional `--skip-boundary` + 새 unit test step)
  - `tests/scripts/test-rein-check-plugin-drift-boundary.sh` (NEW — 7 assertions S1/S2/S3)
  - `tests/hooks/test-rein-validate-plugin-rules.sh` (갱신 — drift_checker module + 인자 기반 호출)
  - `tests/hooks/test-rein-validate-plugin-rules-hardening.sh` (갱신 — 6 scenarios PASS)
  - `tests/scripts/test-plugin-drift-detection.sh` (갱신 — 4 assertions, PLUGIN-ONLY 옛 test 제거)
  - `trail/dod/dod-2026-05-13-option-c-phase-2-drift-checker-boundary.md` (NEW)
- 요약:
  Plan Phase 2 의 5 task 실행. drift checker 가 단일 통합 도구로 (1) shared rule boundary check (2) sha256 parity check (3) plugin rules validation (이전 validator 5 check 흡수) 수행. dead `skills/rules-prompt/*` allowlist 제거. PLUGIN-ONLY 처리를 default OK 로 전환 (Option C 의도 — plugin SSOT 가 SSOT). path containment 추가 (hooks.json target traversal 방지).
  CLI 옵션: `--skip-parity` / `--skip-boundary` / `--skip-validation` 으로 layer 별 선택 가능.
  `rein-validate-plugin-rules.py` wrapper 유지 (backward compat — publish gate / CI workflow / test 호출).
  CI workflow (`plugin-drift-check.yml`) 가 Phase 3 까지 transitional `--skip-boundary` 사용 — Phase 3 후 flag 제거 표시.
  codex review Round 1 NEEDS-FIX (2 issues: workflow 영향 미검증 + path containment 부재) → Round 2 PASS (2 fix RESOLVED).
  security review: No concerns (subprocess argv + env allowlist + path containment + JSON graceful + dual-write byte-equal).
  Tests: 7 (new boundary) + 6 (validate-plugin-rules synthetic) + 6 (hardening) + 4 (plugin-drift-detection) = **23 assertion 전체 PASS**.
  **다음 진입점**: Phase 3 — overlay 정리 + dogfood install (sub-step 4a~4g 안전 순서).
- 라우팅 피드백: agent=feature-builder (메인 직접) + codex-review (Round 1+2 sequential) + security-reviewer (subagent dispatch). 학습:
  - 통합 도구의 check 함수 시그니처 `(repo_root, errors)` 가 monkeypatch 패턴보다 깔끔 + 인자 기반 호출로 직접 unit test 용이
  - Option C transition 단계의 workflow 는 explicit transitional flag 로 명시 — Phase 3 후 제거 marker 동봉
  - security-reviewer agent 가 stamp 를 자동 갱신할 때 manual touch policy 위반 가능성 — agent 호출 후 stamp cycle/scope 명시 검증 필요 (`subagent-review.md` warning)
