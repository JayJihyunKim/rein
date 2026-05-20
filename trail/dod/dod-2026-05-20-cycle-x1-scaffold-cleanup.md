# DoD — Cycle X1: scaffold 잔존 청소 (E.1 + E.2)

- 날짜: 2026-05-20
- 유형: refactor (scaffold 청소 — 기능 변경 없음, 정합 회복)
- slug: cycle-x1-scaffold-cleanup
- plan ref: `docs/plans/2026-05-20-integrated-roadmap.md` §4.5 영역 E.1 + E.2, §5.1 cycle X1

## 범위 연결

plan ref: docs/plans/2026-05-20-integrated-roadmap.md
work unit: §4.5 영역 E.1 + E.2 (cycle X1 묶음)
covers: []

> 본 plan 은 operational roadmap 성격 — `## Design 범위 커버리지 매트릭스` 섹션 의도적 생략 (legacy advisory, plan §1 첫 줄 참조). 따라서 `covers:` 는 빈 배열로 정직히 기재. 본 cycle 의 작업 범위 (영역 # = E.1 + E.2, cycle 묶음 = X1) 는 위 work unit 라인이 명시.

## 배경

통합 master plan §4.5 의 잔존 영역 E (scaffold 청소) 중 우선순위 1~2 (E.1 + E.2) 를 한 cycle 로 묶어 처리. plan §5 의 권장 시작 cycle 과 일치. 묶음 이유: 두 작업 모두 scope 작고 독립 (선행 가능), test runner 회복으로 후속 영역 A/B/C/D 의 회귀 안전망 확보.

## 작업 1 — E.1: `tests/rein-test.sh` runner 갱신

### 현 상태 진단

- 현재 test 는 6 시나리오: `--help`, `--version`, `new` 명령, `new` 충돌, `merge`, `merge` non-git fail, `update` alias
- `scripts/rein.sh` 의 현 CLI 표면 (line 633~674) 검증:
  - `--version` / `--help` — 작동
  - `merge|update` → `claude plugin update rein` redirect 메시지 후 `exit 0` (plugin-first 전환의 의도된 동작)
  - `job <subcmd>` — 작동
  - `new` — **완전 제거됨** (case 분기 부재 → `*)` 의 `unknown command` 로 exit 1)
- 결과: test 의 line 124~165 (`new` 검증) 즉시 실패, line 168~212 (`merge`/`update`) 는 redirect 메시지에 대한 stale 가정 → 모든 file/dir assertion 실패

### 변경 방향

현 CLI 표면만 검증으로 재작성. 의도: rein.sh 자체의 dispatch + version 보고 + plugin-redirect 동작을 회귀 안전망으로 유지하되, scaffold 시대의 `new`/`merge` 가정 제거.

| 보존 | 제거 | 신규 |
|---|---|---|
| `--help` (Usage 포함) | `new test-project` 시나리오 + 산출물 assertion | `update`/`merge` 가 plugin redirect 메시지 emit + exit 0 검증 |
| `--version` (rein 포함) | `new` 충돌 (exit code 1) | `job` subcmd 누락 시 exit 1 검증 (rein CLI 표면 회귀 안전망) |
| | `merge` git-init 후 산출물 assertion (`.claude/CLAUDE.md` 등) | unknown command exit 1 검증 |
| | `update` alias 산출물 assertion | |

bootstrap 산출물 검증 (`.claude/` overlay, security layer 등) 은 별도 `tests/hooks/` suite + `tests/integration/` suite 가 이미 담당 → 본 runner 에서 중복 제거.

## 작업 2 — E.2: bootstrap drift 점검

### 현 상태 진단

```bash
$ wc -l scripts/rein-bootstrap-project.py plugins/rein-core/scripts/rein-bootstrap-project.py
  33  scripts/rein-bootstrap-project.py        # wrapper
 580+ plugins/rein-core/scripts/rein-bootstrap-project.py  # SSOT
```

- root `scripts/rein-bootstrap-project.py` (33 lines): pure compatibility entry point. `runpy.run_path()` 로 plugin 본체를 호출하는 wrapper.
- plugin `plugins/rein-core/scripts/rein-bootstrap-project.py` (580+ lines): 실제 bootstrap 본체. `.rein/`, `trail/`, `.claude/security/profile.yaml` 등 생성.

### 결론

drift 아님. **의도된 wrapper 패턴**. `.claude/rules/branch-strategy.md` RES-1 의 plugin-aware resolver 정책 (`CLAUDE_PLUGIN_ROOT/scripts` 우선, repo `scripts/` fallback) 과 일치. root wrapper 는 repo-local hook + governance scan 이 documented `scripts/` 경로로 helper 를 resolve 할 수 있도록 유지하는 fallback.

### 변경 방향

코드 변경 없음. 단 wrapper 의 docstring 이 분류를 명시하므로 plan §4.5 의 "bootstrap drift 두 본 differ" 표현은 부정확 — drift 가 아니라 **layered SSOT (wrapper + body)**. 본 cycle 의 산출물:

1. wrapper 실제 동작 검증 (sandbox 에서 root wrapper 호출 → plugin body 산출물 동일성 확인)
2. plan §4.5 의 E.2 표현을 "drift 점검 → layered SSOT 정합 검증 완료" 로 갱신
3. `docs/plans/2026-05-20-integrated-roadmap.md` §3.3 / §5 에 E.2 완료 반영

## 변경 범위

| 파일 | 변경 종류 |
|---|---|
| `tests/rein-test.sh` | 본문 재작성 (대부분 줄 교체) |
| `docs/plans/2026-05-20-integrated-roadmap.md` | §3.3 / §4.5 / §5 갱신 (E.1/E.2 완료 반영) |
| `trail/inbox/2026-05-20-cycle-x1-scaffold-cleanup.md` | 신규 |
| `trail/index.md` | 다음 진입점 + 잔존 영역 표 갱신 (X2 = 영역 A 다음) |

## 비범위

- hook 본체 / plugin source 편집 없음 (test runner + plan/trail 문서만 변경)
- 영역 E.3 (post-edit-dispatcher body 완전 제거) — 영역 B 와 묶음 권고, 본 cycle 제외
- 영역 A~D 진입 — 별 cycle (X2~X5)
- VERSION bump 없음 (internal scaffold 청소 — Rule A 의 no bump 카테고리)

## 검증 기준 (Definition of Done)

- [ ] `tests/rein-test.sh` 갱신 후 단독 실행 시 모든 assertion PASS
- [ ] 전체 hook test suite (`tests/hooks/`) 회귀 0
- [ ] root wrapper (`scripts/rein-bootstrap-project.py`) sandbox 호출 → plugin body 와 동일 산출물 (`.rein/project.json` + `trail/` 구조) 확인
- [ ] `docs/plans/2026-05-20-integrated-roadmap.md` 의 §3.3 / §4.5 / §5 가 E.1/E.2 완료 반영
- [ ] `.codex-reviewed` + `.security-reviewed` stamp 생성
- [ ] `trail/inbox/` + `trail/index.md` 갱신

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale: |
  - agent: 기능 변경 없는 test runner + 문서 갱신 + drift 진단. researcher-first refactor 성격 (기존 코드 구조 파악 후 의도 보존하며 갱신).
  - skills/codex-review: test 본체는 plugin SSOT 아니지만 회귀 안전망 신뢰도를 위해 second opinion 유지. drift 결론도 외부 관점 검증.
  - mcps: 없음 — 외부 조회 불필요.
  - security_tier: light — bash test 스크립트 + 문서 갱신만, secret / 외부 input boundary / 신규 command exec 도입 없음. wrapper 의 runpy 사용은 기존 코드 (변경 없음).
approved_by_user: true
```

## 라우팅 승인 사유

Auto Mode 활성 + 사용자 직접 명령 "진행하자. 이번 사이클은 commit 까지 스스로 판단하고 진행해" 로 reasonable call 진행. E.1/E.2 는 plan §5 권장 시작 cycle 과 정확히 일치, scope 명확 (test runner 재작성 + drift 진단 + 문서 sync) → 별 brainstorm/spec 분리 불필요.
