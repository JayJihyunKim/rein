# DOD-GATE-FP-TESTS — spec 검토 게이트의 tests/ 경로 false-positive 차단 수정

- 날짜: 2026-05-29
- 유형: fix
- plan ref: N/A (단일 hook 버그 수정, 별도 plan 불요)

## 배경 / 문제

`plugins/rein-core/hooks/pre-edit-dod-gate.sh` 의 spec 검토 게이트(line 398-532)는
검토되지 않은 사양 문서(`.pending` without fresh `.reviewed`)가 **하나라도** 있으면
`UNRESOLVED_SPECS=true` 로 판정하고, 편집 대상(`FILE_PATH`) 경로를 전혀 거르지 않은 채
`exit 2` 로 **모든 편집을 전역 차단**한다 (line 525-531).

이 때문에 사양 검토 대기 중에는 테스트 파일(`tests/**`) 편집까지 막힌다.
- 2026-05-28 incident `351623296a9bc1d8` — 5회 누적, declined 처리됨.
- 차단 사례 (blocks.jsonl): `tests/scripts/test-rein-publish-dual-channel.sh`(2회),
  `tests/scripts/test-rein-publish-tarball.sh`, `tests/hooks/test-pre-edit-dod-gate-pln1-enforce.sh`.

테스트 파일 편집은 rein 의 reproduction-first / TDD red-green 전략의 핵심 행위이며,
GUARD-1 ("테스트 실행 자체는 게이트 대상이 아니다") 정신과 일관되게 **사양 검토 게이트의
대상이 되어서는 안 된다**. 테스트만 편집 가능하게 풀어도 실제 소스(`plugins/`, `scripts/`)는
여전히 차단되므로 게이트 우회 위험은 없다.

## 목표

spec 검토 게이트가 편집 대상 경로(`FILE_PATH`)가 `tests/` 하위일 때는 차단을 skip 하도록 보정.
비-tests 소스 편집(`plugins/`, `scripts/`, 루트 config 등)은 기존 차단 동작을 그대로 유지.

## 완료 기준 (DoD)

1. `FILE_PATH` 가 프로젝트 루트의 `tests/` 하위일 때, 검토 안 된 사양이 있어도 spec 게이트가 통과한다.
2. `FILE_PATH` 가 비-tests 소스일 때는 검토 안 된 사양이 있으면 기존대로 `exit 2` 차단 (회귀 없음).
3. 위 두 경우를 검증하는 회귀 테스트를 추가하고 러너에 등록한다 (reproduction-first: 먼저 RED 확인).
4. `bash -n` 구문 검증 통과.

## 비목표

- spec 게이트의 전역 차단 구조 자체를 재설계하지 않는다 (tests/ 예외만 추가).
- 다른 게이트(routing-gate, incident-gate)는 손대지 않는다.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
rationale: >
  단일 hook 버그 수정. DoD 키워드에 fix/버그 포함 → feature-builder-fix 의
  reproduction-first 전략 적합 (failing test 먼저 작성 후 path filter 보정).
  구현 후 codex-review 로 게이트 우회 회귀 없음 검증.
approved_by_user: true
```
