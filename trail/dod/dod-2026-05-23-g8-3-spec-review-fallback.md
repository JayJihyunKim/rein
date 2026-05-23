# DoD — G8-3: 신규 spec-review 의 무관 active-DoD Tier-2 fallback 차단

- 날짜: 2026-05-23
- 유형: fix
- Scope ID: G8-3-spec-review-disable-unrelated-tier2-fallback

## 문제 (Symptom)

새 design/plan 문서의 첫 `/codex-review` (fresh spec review) 에서 wrapper 가 **무관한 active DoD**
를 Tier-2 fallback 으로 envelope 에 주입한다. Design Alignment slot 이 그 무관 DoD 의 Scope ID
들을 MISSING 으로 보고 → 구조적 **false NEEDS-FIX**. 5회+ 재발.

## Root cause

spec-review 분기가 무조건 `select_active_dod` 를 호출하는데, 이 함수는 spec-review 인식이 없어
latest-mtime DoD 를 Tier-2 advisory 로 반환한다. 신규 design/plan 시점엔 존재하는 유일한 DoD 가
무관한 in-flight 작업의 것이라, 그게 `active_dod_tier: 2` / `active_dod_path: <unrelated>` 로 주입됨.

## 수정 범위 (DoD 항목)

- [ ] failing test 먼저: `tests/skills/test-codex-review-wrapper.sh` 에 fresh spec review 가 무관
      active DoD 를 Tier-2 로 채택하지 않음 assertion → 현재 코드 실패 확인
- [ ] spec-review 분기에서 active-DoD Tier-2 fallback 비활성화 (`(N/A for fresh spec review)` 표기)
- [ ] `diff_base` = `N/A`, `changed_files` = 리뷰 대상 문서 자체만
- [ ] 두 사본 (`scripts/rein-codex-review.sh` + `plugins/rein-core/scripts/rein-codex-review.sh`)
      **byte-identical** (`diff -q` 통과)
- [ ] code-review (non-spec) 분기 동작 불변 — negative-side guard test 로 Tier-2 fallback 유지 검증
- [ ] `bash tests/skills/test-codex-review-wrapper.sh` GREEN (기존 26 + 신규 2 = 28)

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  Reproduction-first 버그 수정. spec-review 분기 한정 변경, code-review 분기 불변.
  rein-codex-review.sh 2사본 + wrapper test 만 touch. codex/security review 와 integration 은
  orchestrator 가 처리하므로 skill/mcp 불필요.
approved_by_user: true
```
