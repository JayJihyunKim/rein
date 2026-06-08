# DoD — 라우팅 정의 정합성 + 고아 라우터 동작 정리 (ROUTE-DOC-1)

- 날짜: 2026-06-05
- plan ref: docs/plans/2026-06-04-routing-def-consistency-implementation.md
- spec ref: docs/specs/2026-06-04-routing-def-consistency.md (검토 통과)
- brainstorm ref: docs/brainstorms/2026-06-04-routing-def-consistency.md

## 목표

plugin-first 전환 후 고아가 된 라우터 학습/검증 동작을 `rein-route-record.py` 에서 제거하고(감사 로그만 유지), routing-map ↔ routing-procedure 두 조합표를 SSOT-projection 관계로 명시·정렬하며, stale 테스트를 정리하고 drift-guard 회귀 테스트를 추가한다. Option A(정직한 축소) 범위 — 자동 학습 재구현·디스크 검증 plugin 경로 수정은 비범위.

## 완료 기준 (acceptance)

1. `rein-route-record.py` 에서 `learn` 명령·관련 상수·헬퍼 전체 제거 — `learn` subcommand 거부(argparse invalid choice). (RD-1)
2. ID 검증·디스크 스캔(`.claude/agents|skills`) 제거 + `feedback` 의 `invalid_ids` schema 제거 — 전달값 직기록. (RD-2, RD-3)
3. 잔존 schema/format 검증(outcome enum + 대상 yaml 존재) 유지 확인. (RD-4)
4. docstring·미사용 import·stale 주석 정합. (RD-5)
5. `scripts/` ↔ `plugins/rein-core/scripts/` 두 사본 byte-identical (`test-plugin-scripts-bundle.sh` PASS). (RD-6)
6. `routing-map.md` projection 명시 1줄 + §5 라벨 subset 정렬 + ≤900B. (RD-7)
7. `routing-procedure.md` §5-A 유형 우선순위·지배 판정 1줄씩 + namespaced canonical 1줄. (RD-8, RD-9)
8. stale `test-route-record-validation.sh` 제거 + run-all 등록 해제. (RD-10)
9. `test-routing-map-projection.sh` drift-guard 신규(map ⊆ procedure §5 + 바이트 상한) + run-all 등록 + drift 주입 시 FAIL 확인. (RD-11)
10. 인접 route-record 회귀 테스트 무변경 PASS + 전체 suite `ALL SUITES PASSED`. (RD-12)
11. 통합 코드/보안 리뷰 1회 통과 후 커밋.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:parallel-execute   # plan 의 v2 실행 전략(3 웨이브) 기반 worker dispatch
  - rein:codex-review       # 전체 변경분 통합 리뷰 (완료 전 1회)
mcps: []
security_tier: light        # 로컬 감사로그 writer(Python) + markdown 규칙 + bash 테스트, secret/auth/network 표면 없음
rationale: >
  기능 변경 없이 고아 코드를 제거하고 문서 정합성을 맞추는 refactor 가 지배 유형
  (완료 기준이 "동작 축소 + 문서 정렬 + 테스트 가드"를 가리킴). plan 이 파일소유권
  기준 3 웨이브(Wave1 script mutating 단독 → Wave2 두 규칙 edit_only 병렬 → Wave3
  테스트 mutating 단독)를 산출했으므로 parallel-execute 로 Wave2 를 병렬 실행하고
  부모가 웨이브 단위 검증·커밋. Python 은 로컬 yaml append 만 다뤄 보안 표면이 낮아
  light tier.
approved_by_user: true
```

## 변경 파일

- scripts/rein-route-record.py
- plugins/rein-core/scripts/rein-route-record.py
- plugins/rein-core/rules/routing-map.md
- plugins/rein-core/rules/routing-procedure.md
- tests/scripts/test-route-record-validation.sh (삭제)
- tests/scripts/test-routing-map-projection.sh (신규)
- tests/scripts/run-all.sh
- .rein/policy/router/overrides.yaml (dev 운영 데이터 헤더 주석 — main 비포함)
