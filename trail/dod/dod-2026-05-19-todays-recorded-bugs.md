# DoD — 2026-05-19 기록 버그 3건 해결 (PD-1 · PD-2 · GUARD-1)

- 날짜: 2026-05-19
- 유형: fix

## 목표

`need-to-confirm.md` 에 2026-05-19 자로 기록된 버그 3건을 해결한다. 3건 모두
Phase 1 root-cause 조사 (코드 직접 read + 비파괴 트레이스 재현) 로 근본 원인이
확정됨.

## 배경 — 확정된 근본 원인

- **PD-1** — `plugins/rein-core/hooks/lib/project-dir.sh` 의 `resolve_project_dir`
  step 4 가 `SCRIPT_DIR/../..` 로 항상 2단계 위를 가정한다 (hook 레이아웃
  `<repo>/.claude/hooks/` 전용). `scripts/*.sh` 는 1단계 깊이라 `../..` 가 repo
  부모를 가리킨다. step 5 는 `trail/` 가드 실패 후에도 그 잘못된 값을 무조건
  출력 → `rein-mark-spec-reviewed.sh` 가 repo 밖에 stamp 를 쓰고 `exit 0` 으로
  실패를 은폐. (`bash -x` 트레이스로 step 4→5 경로 확정.)
- **PD-2** — `rein-codex-review.sh:55` 의 inline resolution
  `${CLAUDE_PROJECT_DIR:-$PWD}` 가 해소한 PROJECT_DIR 이 실제 repo 루트인지
  sanity check 없이 `cd`(67) + stamp 생성(807). 정상 경로엔 영향 없는 hardening.
- **GUARD-1** — `pre-bash-guard.sh:419-424` 가 `pytest` 등 *테스트 실행 자체* 를
  리뷰 stamp 없으면 차단 → TDD red-green 루프 구조적 불가. 게이트 대상은
  *커밋/완료 선언* 이어야 함.

## 완료 기준

### PD-1
- `resolve_project_dir` 가 caller 스크립트 깊이에 무관하게 rein 프로젝트 루트를
  반환한다 — 고정 `../..` 대신 `SCRIPT_DIR` 부터 `trail/` 보유 조상까지 walk-up.
- `trail/` 미발견 시 fallback 은 cwd-git 이 아니라 `git -C "$SCRIPT_DIR"` 기준
  (script 물리 위치가 속한 repo) → 잘못된 부모 값을 emit 하지 않는다.
- `rein-mark-spec-reviewed.sh` 가 PROJECT_DIR 해소 후 `trail/` 부재 시 loud fail
  (non-zero exit) — `exit 0` 실패 은폐 제거.
- 재현 테스트: 1단계 깊이 스크립트가 `trail/` 보유 fixture repo 내부에 있을 때
  `resolve_project_dir` 가 부모가 아닌 repo 루트를 반환.

### PD-2
- `rein-codex-review.sh` 가 PROJECT_DIR 확정 직후 `git -C "$PROJECT_DIR" rev-parse
  --show-toplevel` 일치 + `trail/` 존재를 검증, 불일치 시 명확한 오류로 fail
  (조용히 진행 금지).
- 정상 경로 (`CLAUDE_PROJECT_DIR` 주입) 동작 불변 — 회귀 테스트로 확인.
- 재현 테스트: 잘못된 PROJECT_DIR (repo 아님 / `trail/` 부재) 에서 loud fail.

### GUARD-1
- `pre-bash-guard.sh` 에서 테스트 실행 (`pytest` 등) 의 리뷰 stamp 게이트
  (line 419-424) 제거. `git commit` 게이트 (427-431) 는 유지.
- coverage-matrix 게이트 (`.coverage-mismatch` 류) 는 그대로 — GUARD-1 범위 외.
- 11-step 문서 동기화: 테스트 실행이 더 이상 stamp 를 요구하지 않음을 반영
  (`.claude/CLAUDE.md` step 8 + plugin rules 의 Operating Sequence 본문).
- 재현 테스트: DoD 존재 + stamp 부재 시 `pytest` 는 통과(차단 안 됨),
  `git commit` 은 여전히 차단.

### 공통
- 각 버그마다 재현 테스트 선작성 (TDD red → green). rein testing rule
  "버그 수정은 재현 테스트 필수" 준수.
- `scripts/` 루트 사본과 `plugins/rein-core/scripts/` SSOT 사본 동기화 유지
  (`rein-mark-spec-reviewed.sh`, `rein-codex-review.sh` — 현재 byte-identical).
- 기존 회귀 테스트 무회귀 (`test-pre-bash-guard*.sh`,
  `test-codex-review-wrapper.sh`, project-dir 관련 테스트).
- codex review + security review 통과 후 stamp 생성.
- 해결된 PD-1/PD-2/GUARD-1 항목을 `need-to-confirm.md` → `confirmed.md` 이관.
- stale spec-review `.pending` 마커 (`e740bea312dabe02`, `fac428f9d2bde994` —
  `.reviewed` 가 이미 존재) 정리.

## 작업 범위 (버그 수정 — 별도 coverage plan 없음)

> 버그 수정 작업이라 design/plan coverage matrix 가 없다. 아래는 서술적
> 추적용이며 coverage validator 의 `## 범위 연결` 대상이 아니다 (validator
> contract §3.2: `## 범위 연결` 섹션 부재 시 skip).

source: need-to-confirm.md — PD-1 / PD-2 / GUARD-1
work unit: PD-1 (project-dir resolution) · PD-2 (codex-review wrapper sanity) · GUARD-1 (test-gate 재범위화)

## 비범위 (이번 작업 제외)

- G8-3 / GE-1 / GE-2 / G3 / BC-INFO1 / A-LowPrio — 2026-05-13 검증분, 오늘 기록 아님.
- PD-1+PD-2 의 "PROJECT_DIR resolution 단일 helper 통합" (need-to-confirm.md 의
  "더 근본적" 옵션) — 범위·위험 큼. 이번엔 per-script sanity check 로 한정.
- `scripts/rein.sh` VERSION bump — main 머지 시점 결정 (Rule B). dev 작업은 미변경.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - superpowers:systematic-debugging
mcps: []
rationale: >
  bash hook + bash 스크립트 + 라이브러리 함수의 버그 수정 — feature-builder 가
  버그 수정 전담. 3건 모두 재현 테스트 선작성이 필수라 test-driven-development,
  근본 원인 추적·최소 수정 규율에 systematic-debugging. 외부 API/문서 조회가
  없어 MCP 불요. 3건은 disjoint 파일이나 codex/security 리뷰·SSOT 동기화가
  공유 단계라 1개 에이전트 순차 처리 (사용자 확인).
approved_by_user: true  # 2026-05-19 사용자 승인 — feature-builder 1개 순차, GUARD-1 은 "테스트 실행 게이트 제거 + 커밋 게이트 유지" 방향
```
