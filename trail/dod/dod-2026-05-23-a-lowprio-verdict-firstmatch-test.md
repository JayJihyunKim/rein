# DoD — A-LowPrio: multi-line FINAL_VERDICT first-match 회귀 테스트

- 날짜: 2026-05-23
- 유형: fix (test)
- Scope ID: A-LowPrio-verdict-firstmatch-test

## 문제 (Symptom)

`rein-codex-review.sh` 의 verdict 파서가 `head -1` first-match contract 사용. 다중
`FINAL_VERDICT:` 라인이 있을 때 first-match-wins 가 정상 동작하는지 단위 테스트 부재.
(로직은 이미 올바름 — 회귀 방지 테스트만 추가, 코드 변경 없음)

## 수정 범위 (DoD 항목)

- [ ] `tests/skills/test-codex-review-wrapper.sh` 에 테스트 1건 추가:
      `FAKE_CODEX_VERDICT` 에 `FINAL_VERDICT: PASS` + `FINAL_VERDICT: REJECT` 두 라인 주입 →
      wrapper 가 first match(PASS)를 채택해 exit 0 (PASS) 인지 검증
- [ ] 기존 wrapper 테스트 전부 통과 (28건 + 신규 1 = 29)
- [ ] 코드(파서) 변경 없음 — 테스트만 추가

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  테스트 1건 추가(internal, no logic change). 회귀 방지 가치. integration/review 는 orchestrator.
approved_by_user: true
```
