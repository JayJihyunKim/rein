---
paths:
  - "tests/**"
  - "**/*.test.ts"
  - "**/*.spec.ts"
  - "**/*.test.py"
  - "test_*.py"
---

# Testing Rules

## 테스트 작성 원칙
1. **테스트는 명세서**: 이름만 읽어도 무엇을 검증하는지 알 수 있어야 한다
2. **독립성**: 각 테스트는 다른 테스트에 의존하지 않는다
3. **결정론적**: 실행할 때마다 동일한 결과

## 테스트 이름 규칙
```
// 패턴: [무엇을]_[어떤 조건에서]_[기대 결과]
test("getUserById_존재하는ID_유저반환")
test("createUser_중복이메일_에러발생")
```

## 테스트 구조 (AAA)
```
// Arrange — 준비
// Act     — 실행
// Assert  — 검증
```

## 커버리지 기준
- 신규 기능: 핵심 로직 80% 이상
- 버그 수정: 재현 테스트 반드시 포함
- 엣지 케이스: null/undefined, 빈 값, 최대/최소값

## 금지 패턴
- 구현 코드를 그대로 복사한 테스트 금지
- `sleep`/`setTimeout` 타이밍 의존 테스트 금지
- 외부 API 직접 호출 단위 테스트 금지 → Mock 사용

## 테스트 카테고리

rein 관점에서 테스트는 3 카테고리로 구분한다. **이 분류는 선택적** — `kind: behavioral-contract` 태그가 design Scope Items 에 붙은 ID 가 있을 때만 behavioral-contract test 가 의무화된다. 기존 테스트는 재분류 없이 그대로 작동한다.

| 카테고리 | 목적 | 예시 |
|----------|------|------|
| unit | 단일 함수/모듈의 로직 | test_pair_momentum_returns_ratio |
| integration | 2+ 모듈 협력 | test_bear_detect_feeds_rotation_signal |
| behavioral-contract | design 이 명시한 contrast 를 scenario 실행 결과로 검증 | test_caution_nav_drawdown_less_than_attack_in_s1_2020_03 |

**behavioral-contract 정의**:

- Historical/scenario path **전체 실행** (end-to-end) — 모듈 단독 테스트가 아니다
- Design 이 명시한 **방향 + 임계값** assertion (예: `A < B`, `A` 가 drawdown 완화). `A != B` 같은 contrast-only 는 부적격
- Scope ID 에 `kind: behavioral-contract` 태그 trigger — 태그 없으면 선택적 분류

### behavioral-contract assertion 템플릿

```python
# Bad 1 (drift 숨김 — contrast 없음, 다른 mode 와 동일 값):
def test_caution_mode_nav(self):
    nav = run_simulation(mode=CAUTION, ...)
    assert nav == 101_000_000   # ← ATTACK 과 완전 동일

# Bad 2 (방향 없음 — 잘못된 방향 drift 도 통과):
def test_caution_nav_differs_from_attack(self):
    nav_attack = run_simulation(mode=ATTACK, scenario="S1_2020_03")
    nav_caution = run_simulation(mode=CAUTION, scenario="S1_2020_03")
    assert nav_caution != nav_attack   # ← !=는 부등호지만 방향 정보 없음

# Good (design-anchored, measurable):
def test_caution_nav_drawdown_less_than_attack_in_s1_2020_03(self):
    result_attack = run_simulation(mode=ATTACK, scenario="S1_2020_03")
    result_caution = run_simulation(mode=CAUTION, scenario="S1_2020_03")
    # design 의도: CAUTION 은 bear window 에서 drawdown 완화
    assert drawdown(result_caution.nav) < drawdown(result_attack.nav)
    # 임계값까지 명시하면 최적 (design 이 수치화한 경우):
    assert drawdown(result_attack.nav) - drawdown(result_caution.nav) >= 0.02
```

**4 요점**:

1. **Scenario 명시** (`S1_2020_03`)
2. **Direction 명시** (부등호, `<` 또는 `>` — contrast-only `!=` 금지)
3. **Design term 으로 assertion** (drawdown, not raw nav)
4. **가능하면 임계값** (0.02 — design 이 수치화한 경우)

## Claim audit 원칙

commit 메시지 / PR title / DoD / plan 의 구체 claim (숫자, mode 개수, 기능 이름) 에 대한 claim audit 은 **PR review 단계의 `/codex-review` envelope Claim Audit 섹션에서 검증**. local commit hook 으로 만들지 않는다 — format 체크가 의미 체크를 대체하면 false sense of security 가 생긴다.
