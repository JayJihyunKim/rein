# DoD — need-to-confirm FU-1~4 묶음 처리

- 날짜: 2026-05-18
- 유형: fix + docs + chore

## 목표

`need-to-confirm.md` 의 2026-05-18 후속작업 후보 FU-1~4 를 한 묶음으로 처리한다.
본 세션에서 4건 모두 문제 claim 을 검증 완료 — plugin 사용자 관점 gap 3건
(FU-1/2/3) + hook 명령 분류기 버그 1건 (FU-4). FU-4 는 감사 결과 test/commit
분류기 외 `.env`-read·destructive-git 분류기에도 동일 결함이 있어 사용자 결정으로
pre-bash-guard 명령 분류기 5개 전체 + post-edit-hygiene 까지 범위 확장.

## 완료 기준

### FU-1 — incidents-to-rule AGENTS.md 부재 분기 추가
- `plugins/rein-core/skills/incidents-to-rule/SKILL.md` 의 Step 4 (사람 결정 수집)
  에 "승격(processed) 결정 시 프로젝트 루트 `AGENTS.md` 가 부재하면 최소 starter
  템플릿으로 생성한 뒤 규칙을 추가한다" 분기를 추가.
- starter 템플릿은 제목 + 규칙 섹션 헤더 수준의 최소 골격 (과한 본문 금지).

### FU-2 — 마켓플레이스 클론 루트 AGENTS.md public strip
- `.github/workflows/mirror-to-public.yml` 의 public push 직전 strip 목록에
  `AGENTS.md` 추가 (`trail/`·`.rein/` 와 동일 처리 — rein-dev main 에는 유지).
- `.claude/rules/branch-strategy.md` 에서 AGENTS.md 의 분류를 갱신 (main 포함 +
  public mirror strip 으로 — `trail/`·`.rein/project.json` 의 🔶 특수 처리 패턴과
  동일) + 사유 1줄.

### FU-3 — rein-mark-spec-reviewed.sh PROJECT_DIR 해소 수정
- `plugins/rein-core/scripts/rein-mark-spec-reviewed.sh` + `scripts/rein-mark-spec-reviewed.sh`
  두 사본의 `PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"` 를 reader gate
  (`post-write-spec-review-gate.sh`·`pre-edit-dod-gate.sh`) 와 동일한
  `resolve_project_dir` 헬퍼 사용으로 교체 → stamp writer/reader 경로 일치.
- 헬퍼 lib 소싱 불가 시 conservative fallback 유지 (스크립트가 깨지지 않게).

### FU-4 — pre-bash-guard 명령 분류기 앵커링 (대안 A, 확장 범위)
- 공유 clause-앵커 명령 매칭 헬퍼 도입 (clause 시작 위치 + 선행 env 할당 허용).
- `pre-bash-guard.sh` 명령 분류기를 헬퍼 기반으로 전환:
  test/commit (라인 358·392·399·413), `.env`-read [P8] (453), destructive-git
  [P11] (483). [P1] pipe-shell (154) 은 이미 앵커됨 — 헬퍼 통합은 선택.
- `post-edit-hygiene.sh:36` 의 `*test_*` 를 경계 있는 패턴으로 교체 (`latest_*`
  류 오분류 차단).
- TDD: 회귀 테스트 작성 — false-positive 미차단 (`grep "pytest"`,
  `npm pkg set scripts.test=vitest`, `cat .env.example`, `echo "git reset --hard"`)
  + true-positive 차단 (`pytest tests/`, `cd x && git commit`, 실제 `.env` read,
  `git reset --hard`).

### 공통 완료 기준
- `tests/hooks/**` 전체 회귀 PASS (FU-4 회귀 테스트 포함)
- codex review + security review 통과 (전체 changeset 1회 통합 리뷰)

## 범위·버전 메모

> `## 범위 연결` 섹션은 의도적으로 두지 않는다 — 이 DoD 는 plan 의 work unit 을
> 구현하는 게 아니라 bug-fix/gap 묶음이라 coverage matrix 대상이 아니다
> (coverage 규칙 §3.2: `## 범위 연결` 은 plan 연동 DoD 전용 opt-in 섹션).

plan: 없음 (N/A) — 요구사항 소스 = `need-to-confirm.md` FU-1~4 + 본 세션
검증·감사 결과. 별도 design/plan 문서 없음 (설계는 대화로 수렴 완료).
work unit: 4 FU 독립 — 파일 집합 disjoint (FU-1 SKILL.md / FU-2 mirror.yml +
branch-strategy.md / FU-3 mark-spec-reviewed.sh ×2 / FU-4 pre-bash-guard.sh +
post-edit-hygiene.sh + tests). versioning.md Rule A: FU-3/FU-4 = user-facing
hook 동작 수정 (patch), FU-1/FU-2 = internal — 최상위 등급 patch 후보.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
mcps:
  - serena  # opportunistic — 작업 중 코드 내비게이션이 추가로 필요할 때만 사용
rationale: >
  FU-1~3 은 소규모 doc/script/workflow 편집 (파일 집합 disjoint, 설계 확정).
  FU-4 는 hook 정규식 변경 — 회귀 위험이 커 TDD 필수: false-positive 미차단 +
  true-positive 차단 케이스를 실패 테스트로 먼저 고정한 뒤 공유 앵커 헬퍼를
  구현한다. feature-builder 가 4 FU 를 순차 수행 (FU-4 는 test-driven-development
  적용). 4 FU 가 disjoint 라 병렬 디스패치도 가능하나, FU-4 hook 정규식의 정밀
  제어를 위해 in-session 직접 구현 + codex/security review 는 전체 changeset
  1회 통합. context7 은 제외 (FU-1~4 에 외부 라이브러리 문서 fetch 불필요).
  serena 는 routing 에 포함하되 opportunistic — 작업 중 심볼/참조 내비게이션이
  추가로 필요할 때만 호출.
approved_by_user: true  # 2026-05-18 사용자 승인 — feature-builder + TDD(FU-4), context7 제외, serena opportunistic
```
