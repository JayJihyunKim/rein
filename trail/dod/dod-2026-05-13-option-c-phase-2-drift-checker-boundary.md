# DoD — Option C Phase 2: drift checker 의미 전환 + validator 통합

- 날짜: 2026-05-13
- 유형: implementation (Phase 2)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`

## 작업 기준

### 목표

plan Phase 2 의 5 task 실행 (covers: S1, S2, S3):
- Task 2.1 (S1) — boundary mode 도입: `.claude/rules/<shared>.md` 존재 시 exit 1
- Task 2.2 (S2) — `rein-validate-plugin-rules.py` 의 6 check 흡수
- Task 2.3 (S3) — dead `skills/rules-prompt/*` allowlist 제거
- Task 2.4 — 호출자 영향 검증 (`rein-publish.sh`, `plugin-drift-check.yml`, tests)
- Task 2.5 — 새 unit test `tests/scripts/test-rein-check-plugin-drift-boundary.sh`

### Scope (명시)

- 포함:
  - `scripts/rein-check-plugin-drift.py` 갱신 (boundary check + 6 validator check 흡수 + dead allowlist 제거)
  - `plugins/rein-core/scripts/rein-check-plugin-drift.py` 동일 갱신 (dual-write — Option C 본 작업이 메인테이너 환경 only 변경)
  - `scripts/rein-validate-plugin-rules.py` wrapper 화 (D3 결정 — backward compat, `exec` 또는 `argparse` 분기)
  - 새 unit test (`tests/scripts/test-rein-check-plugin-drift-boundary.sh`)
  - 기존 test 가 통합 후 PASS 확인 (`tests/hooks/test-rein-validate-plugin-rules*.sh`, `tests/scripts/test-plugin-drift-detection.sh`)
  - codex review (Mode A) + security review
- 제외:
  - `.claude/rules/` 또는 `.claude/CLAUDE.md` 의 실제 편집 (Phase 3 작업)
  - dogfood install (Phase 3 작업)
  - `tests/**` 의 plugin tarball ship (D5 의 ❌ 제외 그대로)
  - branch-strategy.md 갱신 (Phase 5 작업)

### 성공 기준 (S1, S2, S3 의 deterministic 검증)

- [ ] **S1**: 새 unit test 가 임시 `.claude/rules/code-style.md` 생성 → `rein-check-plugin-drift.py` exit 1 + stderr 에 위반 path
- [ ] **S2**: 기존 `tests/hooks/test-rein-validate-plugin-rules.sh` + `-hardening.sh` 가 통합 후 도구에서 동등 pass/fail (6 fixture)
- [ ] **S3**: `grep -E '(skills/rules-prompt|skills-rules-prompt)' scripts/rein-check-plugin-drift.py | wc -l == 0`
- [ ] codex review PASS (Mode A code review)
- [ ] security review (light — Python 코드, boundary check 의 path traversal 등 검토)
- [ ] 호출자 작동 확인: `bash scripts/rein-publish.sh --check-only` (있다면) PASS, `tests/scripts/test-plugin-drift-detection.sh` PASS

### Risk / Open

- 통합 도구의 행동이 변경되면 `rein-publish.sh` publish gate 가 unexpected 실패 가능. 호출자 매핑 정확 + backward compat
- boundary check 가 dev overlay (현재 7 shared rule 가 그대로 존재) 에서 매번 fail — Phase 3 작업이 완료될 때까지 dev 환경에서 publish 시도 시 차단. mitigation:
  - 옵션 A: boundary check 가 우선 advisory (exit 0 + stderr 경고) → Phase 3 완료 후 enforcing
  - 옵션 B: 본 cycle 의 boundary check 가 enforcing 이지만 publish gate 호출 경로에서만 — dev 일반 사용 영향 없음
  - 옵션 C: `.claude/rules/` 의 shared 7 파일을 본 cycle 에서 함께 제거 (Phase 3 의 Task 3.6 흡수)
  - plan 의 의도 = boundary check 가 enforcing. 본 cycle 에서 dev overlay 의 shared 7 파일 정리는 안 함 → Phase 3 까지 일시 mismatch 허용
  - 결정: 옵션 A (advisory) + Phase 3 후 enforcing 으로 승급 표시. 또는 도구에 `--enforce-boundary` flag 도입

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale: |
  Python 스크립트 통합 + 새 test. 메인 세션 직접 작성 (구조 변경이라 author 권한 분리 — subagent dispatch 보다 메인 세션이 명확).
  codex-review (Mode A code review) 가 검증 gate.
approved_by_user: true
```

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 2 (Tasks 2.1 + 2.2 + 2.3 + 2.4 + 2.5)
covers: [S1, S2, S3]
