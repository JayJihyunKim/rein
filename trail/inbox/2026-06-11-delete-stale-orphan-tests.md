# stale orphan 테스트 2건 삭제

작업일: 2026-06-11
DoD: dod-2026-06-11-delete-stale-orphan-tests.md
상태: 완료 (커밋 미실행 — 사용자 승인 대기)

## 무엇을

CI 러너 화이트리스트에서 빠진 채(orphan) 의도된 아키텍처 변경으로 stale 된 테스트 2개 삭제:

- `tests/scripts/test-perf3-bash-rules-cold-path-skip.sh`
  옛 구조(hooks.json 에 bash-rules 26개 `if`-gated entry) 검증 → `e414af8`(Cycle X2 dispatcher 통합)으로 무효.
- `tests/scripts/test-plugin-hooks-json-parity.sh`
  `.claude/settings.json` hooks 를 대조 기준으로 사용 → `251bfd8`(Option C Phase 3)에서 hooks 가 비워져 전제 무효.

## 검증

- codex 독립 검증(gpt-5.5, high): 진단 4건 모두 TRUE + **둘 다 삭제 권고** (재작성/재목적화는 기존 활성 테스트와 중복).
- 대체 커버리지(전부 활성 러너 포함):
  - dispatcher 단일 구조 → `tests/hooks/test-bootstrap-gate-hooks-json-order.sh`
  - 분류기 기반 cold-path skip 동작 → `tests/hooks/test-bash-dispatcher.sh` (실측 34/34)
  - plugin hook 실존+실행가능 정합 → `tests/hooks/test-hooks-json-schema.sh` + `scripts/rein-check-plugin-drift.py`
- `tests/scripts/run-all.sh` + `tests/hooks/run-all.sh` 둘 다 ALL SUITES PASSED → 커버리지 손실 0.

## 분류

internal (테스트 삭제, 외부 동작 불변) → **no version bump** (versioning Rule A).

## 후속

- 활성 백로그 남은 1건: **broader staged-review 전면설계** (codex-review wrapper 의 envelope 슬롯 일관성, brainstorm 부터). medium.
- 커밋/main 머지는 사용자 승인 시. `tests/**` 는 main 포함 대상 → 다음 릴리스 선별 체크아웃 때 두 파일 삭제도 함께 반영해야 함(선별 체크아웃은 "추가"만 처리, "제거"는 수동 `git rm`).
