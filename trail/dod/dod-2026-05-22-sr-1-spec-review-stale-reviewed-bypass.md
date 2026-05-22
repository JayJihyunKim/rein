# DoD — SR-1 spec-review gate stale `.reviewed` 우회 차단

- 날짜: 2026-05-22
- 유형: fix (security gate hardening — 리뷰 우회 경로 차단)
- plan ref: need-to-confirm.md §SR-1 (spec-review gate 가 stale `.reviewed` 를 신뢰)

## 목표 (Why)

리뷰 완료된 spec/plan 문서를 **다시 편집**하면 `post-edit-spec-review-gate.sh` 가 새 `${hash}.pending` 을 만들지만 기존 `${hash}.reviewed` 를 무효화하지 않는다. 그 결과 `.pending`(신규) + `.reviewed`(stale) 가 공존하고, `pre-edit-dod-gate.sh` 의 spec-review gate 는 `.reviewed` 의 **존재 여부만** 검사하므로 통과시킨다 → 미리뷰 변경분으로 소스 편집이 풀리는 리뷰 우회 경로. 이를 닫는다.

## 성공 기준 (Acceptance)

1. **(b) 편집 시 무효화** — `post-edit-spec-review-gate.sh` 가 canonical spec/plan 편집을 감지하면 같은 hash 의 기존 `.reviewed` 를 제거한다 (create/touch 두 분기 모두 적용). 편집 = 직전 리뷰 무효화.
2. **(a) gate freshness 백스톱** — `pre-edit-dod-gate.sh` spec-review gate 가 `.reviewed` 존재 시, `.pending` 의 `created=` 와 `.reviewed` 의 `reviewed=` 타임스탬프를 비교한다. `created` > `reviewed`(편집이 리뷰 이후) 또는 타임스탬프 누락/파손 → stale 로 간주하여 UNRESOLVED(차단). 둘 다 rein 이 쓰는 `date -u +%Y-%m-%dT%H:%M:%S` (UTC, offset 없음) 라 lexical 비교 = 시간 순서. legacy healer 의 trailing `Z` 는 strip 후 비교.
3. **회귀 테스트 (TDD, 실패 → 통과)**:
   - (b) post-edit 가 재편집 시 stale `.reviewed` 제거 + 새 `.pending` 생성
   - (a) `.pending.created` > `.reviewed.reviewed` 공존 시 gate 차단 (exit 2)
   - (a) `.reviewed` 가 `.pending` 보다 fresh(또는 동시각)면 통과 (false-positive 없음)
   - (a) 타임스탬프 누락 시 fail-closed (차단)
   - end-to-end: write spec → 실제 `rein-mark-spec-reviewed.sh` 리뷰 → 재편집(post-edit hook) → 소스 편집 시도 차단
4. **기존 테스트 무회귀** — `tests/hooks/test-spec-review-gate.sh` 전량 PASS (특히 `test_gate_allows_reviewed_spec`: 동시각 marker → 통과 유지).
5. codex 리뷰 PASS + `.codex-reviewed` stamp, security 리뷰 PASS + `.security-reviewed` stamp.

## 제외 (Out of scope)

- 다른 need-to-confirm 항목 (GE-1/GE-2/G8-3/G3/BC-INFO1/A-LowPrio). SR-1 단독.
- `rein-mark-spec-reviewed.sh` 변경 (PD-1 에서 이미 fail-closed 처리됨 — SR-1 범위 밖).
- legacy healer (`rein-heal-legacy-pending.py`) 변경 — `.pending` 을 항상 삭제하므로 공존을 만들지 않음(확인 완료). 불변.
- spec 파일 mtime 기반 비교 — git checkout/touch 로 fragile. content 타임스탬프(`created=`/`reviewed=`)만 사용.

## 리스크

- (R1) freshness 검사 false-positive 로 정상 편집 차단. → 비교는 `.pending` + `.reviewed` **공존 시에만** 실행 (정상 flow 는 리뷰 후 `.pending` 삭제됨). 동시각/older-pending 케이스 통과 테스트로 보장. healer 는 `.pending` 삭제하므로 공존 안 만듦(확인).
- (R2) locale collation 으로 lexical 비교 오작동. → ASCII ISO 8601 (`0-9`,`-`,`T`,`:`) 은 전 locale 동일 collate. 그래도 누락/파손 시 fail-closed.
- (R3) 본 세션의 live gate 자기 영향. → 메인테이너 dev 는 `/plugin install` 캐시에서 hook 실행 → working-tree 편집은 이번 세션 live 동작 불변. 또한 변경은 검사 강화(additive)라 gate 기능 자체는 보존.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix    # SR-1 = bugfix (리뷰 우회 경로). reproduction-first(failing test 먼저) 전략 적합
skills:
  - rein:codex-review              # commit gate 필수 (.codex-reviewed)
mcps: []
rationale: >
  spec-review gate 우회를 닫는 보안성 bugfix. reproduction-first TDD 로 우회 시나리오를
  failing test 로 고정 후 두 hook(post-edit-spec-review-gate / pre-edit-dod-gate)을 수정.
  본 세션이 이미 4개 관련 파일 + healer + 테스트 하네스를 전부 read 해 컨텍스트가
  완전하므로, subagent 재로딩 비용 회피를 위해 메인 세션에서 동일 reproduction-first
  전략으로 구현. security_tier=full — 리뷰 게이트 자체를 만지는 변경이라 light 면제 부적합.
security_tier: full                # 리뷰 우회 차단 = 보안 표면. full security review
approved_by_user: true             # 사용자 승인 (2026-05-22 "두 겹으로 막기" + "지금 세션에서 직접" 선택)
```

## Self-review 예정 항목 (AGENTS.md §6)

- (b) `.reviewed` 제거가 create/touch 두 분기 모두 커버하는가
- (a) freshness 비교가 공존 시에만 실행되어 정상 편집을 막지 않는가 (false-positive)
- 누락/파손 타임스탬프 fail-closed 가 정상인가
- 기존 `test-spec-review-gate.sh` 무회귀 + 신규 회귀 테스트가 우회 시나리오를 실제로 재현·차단하는가
- end-to-end 테스트가 실제 스크립트(post-edit hook + mark-spec-reviewed)를 사용하는가
