---
name: code-reviewer
description: /codex 장애 시 fallback 리뷰어. 변경된 코드에 대해 AGENTS.md rules + 체크리스트 기반으로 리뷰하고 stamp 생성.
triggers:
  - /codex 호출 타임아웃
  - /codex 호출 에러(exit non-zero)
  - superpowers:code-reviewer 미설치 + codex 자체 불가 환경
---

# code-reviewer (rein-native fallback)

## 실행 조건

이 스킬은 `/codex` 리뷰 게이트를 대체하지 않는다. AGENTS.md §5-1 / `.claude/skills/codex/SKILL.md` 의 규정은 "codex 실패 시에만 fallback" 이며, 본 스킬은 그 fallback 경로의 rein-native 구현이다. 사용자의 임의 요청만으로는 호출하지 않는다.

1. **codex_timeout** — `/codex` 호출이 타임아웃
2. **codex_error** — `/codex` 가 exit non-zero 로 실패
3. **no_superpowers_plugin** — `superpowers:code-reviewer` 플러그인이 없고 `/codex` 경로도 사용 불가

아래 "Stamp 생성" 섹션의 `fallback_reason` 필드에는 위 slug (codex_timeout / codex_error / no_superpowers_plugin) 중 하나를 그대로 기입한다.

## 리뷰 체크리스트

리뷰 시작 전 아래 규칙 파일을 먼저 로드하여 각 그룹의 기준을 확인한다.

### 1. 보안 (`.claude/rules/security.md` 기준)

- [ ] 하드코딩된 credential (API 키, 비밀번호, 토큰) 없음
- [ ] 모든 외부 입력(사용자 입력, 환경 인수, 파일 경로)에 검증 로직 존재
- [ ] SQL / 쉘 / HTML 주입 공격 방어 처리 확인
- [ ] `.env` 파일 또는 `secrets/` 디렉토리 직접 접근·커밋 없음

### 2. 코드 스타일 (`.claude/rules/code-style.md` 기준)

- [ ] 네이밍: 함수 동사형 camelCase, 상수 UPPER_SNAKE_CASE, Boolean `is/has/can/should` 접두사
- [ ] 함수 길이 50줄 이내 (초과 시 분리 권고)
- [ ] 파라미터 3개 이하 (초과 시 객체 묶음 권고)
- [ ] 중첩 depth 3단계 이하 (early return 또는 함수 분리)
- [ ] `any` 타입(TypeScript) / `console.log`·`print` 운영 코드 방치 없음

### 3. 테스트 (`.claude/rules/testing.md` 기준)

- [ ] 변경 범위에 해당하는 테스트가 추가 또는 수정됨
- [ ] 경계 조건(null/undefined, 빈 값, 최대/최소값) 커버
- [ ] 외부 API 직접 호출 단위 테스트 없음 (Mock 사용 확인)
- [ ] 모킹 과다 여부 — 실제 동작보다 mock 구조 검증에 편중되지 않음

### 4. Rein 고유

- [ ] `trail/dod/dod-YYYY-MM-DD-<slug>.md` 파일이 이 작업 전 생성되어 있음
- [ ] DoD 또는 plan work unit 에 `covers: [...]` 메타데이터가 존재하고 매트릭스 ID 와 일치
- [ ] 작업 완료 후 `trail/inbox/YYYY-MM-DD-작업명.md` 기록 대상임을 확인

## 출력 형식

리뷰 결과를 아래 마크다운 템플릿으로 출력한다:

~~~markdown
## 코드 리뷰 결과 (rein-native, round N)

**리뷰 대상**: [파일 목록]
**라운드**: N

### High (즉시 수정 필요)

- [파일:줄번호] 이슈 설명 — 권고 조치

### Medium (수정 권고)

- [파일:줄번호] 이슈 설명 — 권고 조치

### Low (선택 개선)

- [파일:줄번호] 이슈 설명

### 통과 항목

- 보안: 하드코딩 credential 없음
- 스타일: 네이밍 규칙 준수
- 테스트: 변경 범위 커버됨
- Rein 고유: DoD 파일 존재 확인

**결론** (아래 중 하나):
- 통과 — 이슈 없음, 본 스킬 stamp 생성
- 재리뷰 (self-review) — Low 만 또는 Medium ≤3줄, 수정 후 sonnet self-review stamp
- 재리뷰 (same reviewer) — Medium >3줄 또는 High 1건 이상, 수정 후 본 스킬 재실행
- 에스컬레이션 — 3라운드 후에도 High 잔존, escalated_to_human stamp
~~~

## 리뷰 에스컬레이션 흐름

AGENTS.md §5-1 / `.claude/skills/codex/SKILL.md` 의 표와 일치한다.

| 라운드 결과 | 규모 | 다음 행동 |
|-----------|------|----------|
| 이슈 없음 | — | **통과** (본 스킬 stamp) |
| Low 만 | — | 수정 후 **sonnet self-review stamp** |
| Medium 만 | ≤3줄 | 수정 후 **sonnet self-review stamp** |
| Medium 만 | >3줄 | 수정 후 본 스킬 재실행 (round N+1) |
| High 1건 이상 | — | 수정 후 본 스킬 재실행 (round N+1) |
| 3라운드 이후 High 잔존 | — | **에스컬레이션** (resolution: escalated_to_human) |

## Stamp 생성

이슈가 없을 때만 본 스킬 이름으로 stamp 를 생성한다. `<REASON>` 은 "실행 조건" 섹션의 slug (codex_timeout / codex_error / no_superpowers_plugin) 중 하나로 교체한다. Low / Medium(≤3줄) 잔존 시에는 수정 후 self-review stamp 로 전환 (아래 블록 참조).

~~~bash
REASON=codex_timeout     # 실제 호출 사유로 교체
N_FILES=$(git diff --name-only | wc -l | tr -d ' ')
ROUND=1                  # 재리뷰 시 증가
cat > trail/dod/.codex-reviewed <<STAMP
reviewer: code-reviewer-rein
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: $REASON
files_reviewed: $N_FILES
review_round: $ROUND
resolution: passed
remaining_issues: none
STAMP
~~~

stamp 생성 후 `.review-pending` 이 존재하면 삭제한다:

~~~bash
rm -f trail/dod/.review-pending
~~~

Medium ≤3줄 / Low-only 경로에서는 round 증가 없이 self-review stamp 를 쓴다 — `reviewer: self-review` 로 바꾸고, `fallback_reason` 은 직전 본 스킬 실행 사유를 그대로 이어받는다:

~~~bash
cat > trail/dod/.codex-reviewed <<STAMP
reviewer: self-review
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: $REASON
files_reviewed: $N_FILES
review_round: $ROUND
resolution: passed
remaining_issues: none
prior_reviewer: code-reviewer-rein
prior_max_severity: low    # 또는 medium (≤3줄)
STAMP
~~~

## 에스컬레이션 (3라운드 이후에도 High 잔존 시)

3라운드 리뷰 후에도 High 가 남아 있으면 작업을 중단하고 사람에게 에스컬레이션한다:

~~~bash
cat > trail/dod/.codex-reviewed <<STAMP
reviewer: code-reviewer-rein
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: $REASON
files_reviewed: $N_FILES
review_round: 3
resolution: escalated_to_human
remaining_issues: [잔존 High 이슈 요약]
STAMP
~~~

에스컬레이션 후 작업자는 잔존 이슈를 검토하여 직접 수정하거나 추가 지시를 내린다.
