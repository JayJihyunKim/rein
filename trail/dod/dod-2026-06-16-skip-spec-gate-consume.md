# DoD — 스펙 리뷰 우회 마커(.skip-spec-gate) 1회 소비로 전환

- 날짜: 2026-06-16
- 유형: fix
- Scope ID: M1-skip-spec-gate-consume
- 출처: 마커 감사 후속 백로그 (`trail/inbox/2026-06-15-marker-audit-findings.md` §M1)

## 문제 (Symptom)

스펙 리뷰 게이트를 **1회** 건너뛰려고 만든 우회 마커 `trail/dod/.skip-spec-gate` 가
사용(편집 허용) 후 소비(삭제)되지 않아, 손으로 지울 때까지 설계→리뷰 강제가 계속 꺼진 상태로
남는다. 즉 "1회 면제"로 광고된 마커가 실제로는 **영구 면제 스위치**.

## Root cause

`pre-edit-dod-gate.sh:493` 에서 `SKIP_SPEC_GATE` 를 정의하고 `:496` `if [ ! -f "$SKIP_SPEC_GATE" ] && [ -d "$SPEC_REVIEWS_DIR" ]` 로
마커가 있으면 스펙 게이트 블록 전체를 건너뛰지만, 파일 내 `SKIP_SPEC_GATE` 참조는 정의·사용
2곳뿐 — **`rm -f` 가 없다.** 대조로 동일 성격의 1회 우회 `.skip-stop-gate` 는
`stop-session-gate.sh:372-373` 에서 매칭 즉시 `rm -f` 로 소비된다. 스펙 게이트만 소비 누락.
(추가 관찰: `.skip-spec-gate` 를 만들라고 안내하는 사용자 메시지는 없음 — 비공식 escape hatch.)

## 범위

- `pre-edit-dod-gate.sh` 의 스펙 게이트 진입부를 다음 의미로 변경:
  - `.spec-reviews` 디렉토리가 있고 + `.skip-spec-gate` 마커가 있으면 → **이번 편집 1회만** 게이트를
    건너뛰되, 건너뛰기 전에 마커를 `rm -f` 로 소비하고 audit 로그 1줄을 남긴다.
  - **소비(rm) 실패 = fail-closed**: 마커가 실제로 사라졌음을 확인(`[ ! -f ]`)하지 못하면 우회를
    적용하지 않고 게이트를 정상 실행한다 (영구 우회 버그 재발 방지).
  - `.spec-reviews` 디렉토리가 없으면(게이트 비활성) 마커를 소비하지 않는다 (no-op 편집에 1회권 낭비 방지).
  - 마커 없을 때의 기존 게이트 동작은 완전 불변.
- audit 로그: `trail/incidents/auto-mode-bypass.log` 에 `<ISO8601>\tskip-spec-gate consumed (one-shot spec-review bypass)` 1줄 append.
  로깅은 fail-soft(실패해도 hook 중단 금지). 기존 bypass 감사 원장을 재사용하되 reason 문구로 auto-mode 와 구분.

### 명시적 비범위 (감사 백로그 M2/M3/M4 와 분리)

- 코드/보안 리뷰 도장의 freshness·content 바인딩(M2/M3), 스펙 리뷰 표식 생성기 fail-open(M4) 은 **이 DoD 범위 아님.**

## 변경 파일

- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` — 스펙 게이트 진입부 1회 소비 + fail-closed (M1 본체)
- `tests/hooks/test-spec-review-gate.sh` — 소비 후 재차단 + fail-closed 재현 테스트 추가

## 검증 기준

- [ ] failing test 먼저: `.skip-spec-gate` + 미리뷰 스펙(pending, no reviewed) 상태에서
      ① 첫 편집은 허용(exit 0) + 마커 삭제됨 ② **두 번째 편집은 차단(exit 2)** — 현행 코드(소비 없음)에서
      ②가 "여전히 허용"으로 실패함을 먼저 확인
- [ ] 소비 로직 적용 후 위 ①②가 모두 GREEN
- [ ] fail-closed 케이스: 마커가 제거 불가(예: 마커를 디렉토리로 만들어 `rm -f` 실패 유도)일 때
      편집이 차단됨(exit 2) GREEN
- [ ] 기존 `test_gate_respects_bypass_file`(마커 있으면 1회 허용) 여전히 GREEN
- [ ] `bash tests/hooks/test-spec-review-gate.sh` 전체 GREEN
- [ ] `bash tests/hooks/test-state-fast-path-skip.sh` GREEN (`.skip-spec-gate` 사용 케이스 회귀 없음 — 라인 358)
- [ ] `bash -n plugins/rein-core/hooks/pre-edit-dod-gate.sh` 구문 통과
- [ ] codex review + security review 통과

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  reproduction-first 버그수정. 단일 hook(pre-edit-dod-gate.sh) 의 스펙 게이트 진입부 + 그 test 만 touch.
  실패 테스트로 "소비 후 재차단" 을 먼저 고정한 뒤 1회 소비 + fail-closed 를 구현. codex/security review 는
  상위 흐름이 처리하므로 skill/mcp 불필요.
approved_by_user: true
```
