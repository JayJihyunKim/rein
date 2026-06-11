# DoD — stale orphan 테스트 2건 삭제

작업일: 2026-06-11
plan ref: 없음 (trivial cleanup — brainstorm/spec/plan 불요)

## 범위

CI 러너 화이트리스트에서 빠진 채 **의도된 아키텍처 변경**으로 stale 상태가 된 테스트 2개를 삭제한다.
두 테스트가 검증하던 행동은 현재 활성 러너의 다른 테스트들이 전부 커버하므로 **커버리지 손실 0**.
(codex 독립 검증 2026-06-11: 진단 4건 TRUE + "재작성은 중복이니 삭제 권고" 확인.)

- 대상 1: `tests/scripts/test-perf3-bash-rules-cold-path-skip.sh`
  - 옛 구조(hooks.json 에 bash-rules 가 26개 `if`-gated entry 로 등록)를 검증.
    `e414af8`(Cycle X2, Bash dispatcher 통합)으로 단일 `pre-bash-dispatcher.sh` 가 되며 무효.
  - 대체 커버리지: `tests/hooks/test-bootstrap-gate-hooks-json-order.sh`(단일 dispatcher 구조)
    + `tests/hooks/test-bash-dispatcher.sh`(분류기 기반 cold-path skip 동작, 실측 34/34 통과).
    둘 다 `tests/hooks/run-all.sh` 에 포함(활성).
- 대상 2: `tests/scripts/test-plugin-hooks-json-parity.sh`
  - `.claude/settings.json` 의 hooks 를 대조 기준(canonical)으로 사용.
    `251bfd8`(Option C Phase 3)에서 hooks 가 의도적으로 비워져 대조 기준 = 빈 집합 → 전제 무효.
  - 대체 커버리지: `tests/hooks/test-hooks-json-schema.sh`(모든 hook command 가 실존+실행가능 plugin 파일)
    + `scripts/rein-check-plugin-drift.py`(missing hook / exec bit / plugin-root marker / path 포함). 둘 다 활성.

두 파일 모두 `tests/scripts/run-all.sh` 화이트리스트에 부재(orphan) → CI 에서 미실행 상태였음.

## 변경 파일

- `tests/scripts/test-perf3-bash-rules-cold-path-skip.sh` (삭제)
- `tests/scripts/test-plugin-hooks-json-parity.sh` (삭제)

참조처: `trail/**` + `docs/plans|specs/**` 의 기록/언급뿐. 실행 러너 의존 없음(`run-all.sh` 부재 확인).
과거 trail/plan/spec 기록은 그 시점 사실의 역사 보존 — 소급 수정하지 않는다.

## 검증 기준

- [x] `bash tests/scripts/run-all.sh` 전체 그린 — ALL SUITES PASSED
- [x] `bash tests/hooks/run-all.sh` 전체 그린 (대체 커버리지 동작 확인) — ALL SUITES PASSED
- [x] 두 파일이 git tracking 에서 제거됨 (`git ls-files` 0건)
- [x] 실행(러너/빌드) 레이어의 dangling 참조 0건 (문서/기록 참조는 보존)

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills: []
mcps: []
rationale: stale 테스트 정리(cleanup) 유형. 단 2파일 삭제 + 러너 검증으로 trivial 하여
  메인 세션 직접 수행(서브에이전트 dispatch 불요). 신규 코드 추가 0 → codex-review/보안 리뷰 대상 없음.
approved_by_user: true
```

## 분류 (버전)

internal 변경(테스트 삭제, 외부 동작 불변) → **no version bump** (versioning Rule A).
