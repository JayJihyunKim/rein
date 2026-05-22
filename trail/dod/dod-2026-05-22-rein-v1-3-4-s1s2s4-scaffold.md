# DoD — S1+S2+S4 scaffold 잔재 정리

- 날짜: 2026-05-22
- 유형: chore (cleanup) + test (fixture)
- plan ref: rein-v1.4-improvement-plan.md §5.3 S1/S2/S4 (확정안 §0.5)
- design ref: codex 검증 (2026-05-22) — S3 제외(별도 cycle), S5 보존

## 목표 (Why)

v1.0.0 OSS launch 때 scaffold mode 실행 경로는 제거됐으나 주석·fixture 잔재가 남아 가독성/유지보수 혼선을 유발. 실행 경로 불변, 주석·fixture만 정리.

## 성공 기준 (Acceptance)

1. **S1**: `lib/project-dir.sh:21` 의 "Scaffold install" 용어 제거 — walk-up 동작 설명을 plugin-agnostic 으로 (CI 등 CLAUDE_PLUGIN_ROOT 미설정 케이스). **로직 불변** (S5: walk-up 실행 코드 유지).
2. **S2**: 아래 hook 의 "scaffold mode" 주석을 "plugin mode 요구, 그 외 skip" 표현으로 교체. 동작 불변:
   - `pre-bash-safety-guard.sh`, `pre-bash-test-commit-gate.sh`, `pre-edit-dod-gate.sh`, `post-edit-plan-coverage.sh`, `post-edit-design-plan-coverage-rule.sh`, `post-edit-routing-procedure-rule.sh`, `stop-session-gate.sh`
3. **S4**: `tests/hooks/test-session-start.sh`, `test-session-start-tone.sh` fixture 의 `"mode":"scaffold"` → `"mode":"plugin"`.
4. **검증**: 변경 hook 전부 `bash -n` 통과 + session-start 테스트 전체 PASS + `tests/scripts/test-rein-init-unknown.sh` PASS (S5 계약 보존).

## 제외 (Out of scope)

- **S3** (`rein-state-paths.py` mode 필드) — dead code 아님, 별도 cycle (확정안 §0.5).
- **S5** (`test-rein-init-unknown.sh`) — `--mode=scaffold` unknown 계약 검증 테스트, **보존**.
- `json-deny-emitter.sh` 의 "scaffolding" — 문자열 length 용어, scaffold-mode 와 무관.
- `test-plugin-hooks-json-parity.sh` 의 scaffold 언급 — fixture 아닌 설명 주석, 본 cycle 제외.
- 실행 코드 로직 변경 일체.

## 리스크

- (R1) S4 fixture mode 변경이 session-start 동작을 바꿈. → codex 확인: 로드 hook 은 `.rein/project.json` 존재만 검사, mode 값 미사용. session-start 테스트 전체로 방어.
- (R2) 주석 교체가 실수로 코드 라인 변경. → bash -n + diff 검토.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:codex-review
mcps: []
rationale: >
  주석·fixture 정리(동작 불변) → refactor-researcher 적합. 실행 경로 변경 없어
  MCP 불요. security_tier light — 외부 입력/보안 경계 변화 0, 주석·테스트 fixture
  뿐. codex-review 는 commit gate 필수.
security_tier: light    # 주석/fixture only — 동작·보안 경계 변화 0. 사용자 위임 (2026-05-22)
approved_by_user: true  # 사용자 위임 (2026-05-22) — 확정안 §0.5 스코프
```

## Self-review 예정 항목 (AGENTS.md §6)

- 주석만 바뀌고 코드 라인 불변인가 (diff 검토)
- session-start 테스트 PASS, test-rein-init-unknown PASS (S5)
- S3 미포함 확인
