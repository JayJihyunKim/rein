# DoD — .claude/ 오버레이 잔재 정리 (plugin-first 정합)

- 날짜: 2026-06-01
- 유형: refactor (메인테이너 dev 오버레이 슬림화 + stale 참조 정리, 기능 변경 없음)
- plan ref: N/A (정비 작업 — 어떤 훅도 plan ref 강제 안 함). 근거: 2026-06-01 codex-ask second opinion (`.claude/` 오버레이 삭제/슬림 판단, gpt-5.5/medium, read-only)

## 목표 (Why)

Option C Phase 3(2026-05-13)에서 plugin-first 로 전환된 뒤, `.claude/` 오버레이의 일부 파일이 plugin SSOT(`plugins/rein-core/rules/operating-sequence.md`, `routing-procedure.md`, `routing-map.md`)와 **내용이 중복**되거나 **폐기된 경로(`.claude/agents/`, `.claude/hooks/`)를 참조**하는 stale 상태로 남았다. `.claude/CLAUDE.md`는 매 세션 자동 로드되며 `@.claude/orchestrator.md`를 import 해 11단계 시퀀스·라우팅을 **이중 로드** → 에이전트가 "어느 게 권위본인가" 혼란. 혼란의 실제 원인은 파일 존재가 아니라 **자동 로드/import 되는 중복 본문 + stale 내용**(codex 진단).

목표: 메인테이너 전용 규칙(branch/versioning/readme/legacy)의 세션 자동 로드는 보존하면서, 중복·stale 오버레이를 제거하고 거버넌스 표면(AGENTS.md, govcheck)의 끊긴 참조를 정리한다.

## 성공 기준 (Acceptance)

### 1. `.claude/CLAUDE.md` 슬림화 (slim, not delete)
- 11단계 강제 시퀀스 본문 + trail 운영 규칙 중복 서술 + `@.claude/orchestrator.md` import 제거.
- "운영 시퀀스/라우팅의 권위본은 plugin 규칙(operating-sequence / routing-procedure / routing-map)이며 본 파일은 메인테이너 전용 규칙만 추가 로드한다"는 취지 명시.
- 메인테이너 전용 규칙 import 보존: branch-strategy / readme-style / versioning (현행 3종 유지 — 동작 불변. legacy-shipped-pending 은 현재도 미import 였으므로 그대로 유지).

### 2. 중복·stale 오버레이 삭제 (git rm — git history 가 아카이브)
- `.claude/orchestrator.md` (라우팅 = plugin routing-procedure/map 가 SSOT, 폐기된 `.claude/agents/...draft` 참조 205줄).
- `.claude/workflows/*.md` 5종 (add-feature/fix-bug/build-from-scratch/research-task/design-to-plan — 핵심은 plugin agents/rules/skills + design-plan-coverage 로 이관됨).
- `.claude/registry/agents.yml` (폐기된 `.claude/agents/*` 가리킴, 런타임 reader 없음 — repo-audit 체크리스트 한 줄은 advisory).
- `.claude/plans/*.md` 2종 (hook-enforcement / -revisions — 과거 설계 로그, 자동 로드 안 됨, git history 보존).

### 3. 거버넌스 표면 끊긴 참조 정리 (main 포함 파일 — 내부 문서/툴링 수정)
- `AGENTS.md:81` — `.claude/workflows/design-to-plan.md` 참조 → plugin 의 design-plan-coverage 규칙 + writing-plans 스킬로 재지정.
- `AGENTS.md:232-235` — `.claude/agents/*.md` (이미 부재, dangling) → `plugins/rein-core/agents/*.md` 로 경로 수정.
- `scripts/rein-govcheck.py` — `ROOT_DOCS` (48줄) + docstring(11줄)에서 `.claude/orchestrator.md` 제거 (삭제 파일이므로). `if p.is_file()` 가드 덕에 런타임 미차단이나 죽은 config 제거.

### 4. 검증
- `python3 scripts/rein-govcheck.py` → exit 0 유지(baseline 0).
- 삭제 후 활성 거버넌스 표면(AGENTS.md, .claude/CLAUDE.md)에 끊긴 `.claude/orchestrator|workflows|registry|plans|agents` 참조 0건.
- codex 리뷰 PASS + 보안 리뷰 PASS (commit gate).

## 변경 파일

- `.claude/CLAUDE.md` (슬림화)
- `.claude/rules/branch-strategy.md` (제외 표 orchestrator/workflows/registry 행 갱신 + 머지 예제 `.claude/hooks/` → plugin — codex round 1·3 반영. CLAUDE.md import 하는 활성 surface)
- `.claude/rules/versioning.md` (internal hook helper 예시 경로 `.claude/hooks/lib/**` → `plugins/rein-core/hooks/lib/**`)
- `.claude/rules/legacy-shipped-pending.md` (관련 파일 절 healer + 2 hook 경로 → plugin)
- `AGENTS.md` (에이전트 표 경로 + design-to-plan 참조 + code-reviewer skill 참조 → plugin/skill name. main 포함)
- `scripts/rein-govcheck.py` (ROOT_DOCS + docstring orchestrator 제거 + HOOK_GLOB → plugin 훅 스캔 + plugin 상대경로 dual-path 해석. main 포함)
- `plugins/rein-core/rules/design-plan-coverage.md` (`.claude/hooks/post-edit-plan-coverage.sh` → bare hook name. **사용자 ship plugin 규칙** — codex round 3 High 반영, 사용자 범위확장 승인)
- `plugins/rein-core/rules/answer-only-mode.md` (`.claude/skills/...` → `${CLAUDE_PLUGIN_ROOT}/skills/...`. **사용자 ship plugin 규칙**)
- 삭제: `.claude/orchestrator.md`, `.claude/workflows/{add-feature,fix-bug,build-from-scratch,research-task,design-to-plan}.md`, `.claude/registry/agents.yml`, `.claude/plans/{hook-enforcement,hook-enforcement-revisions}.md`

## 제외 (Out of scope)

- ~~`scripts/rein-govcheck.py` 의 `HOOK_GLOB` 미변경~~ → **범위 포함으로 전환** (사용자 승인 2026-06-01 "전부 이번에 정리"). HOOK_GLOB 을 plugin 훅(`plugins/rein-core/hooks/*.sh`)으로 재지정하고, false-fail 우려는 `validate_ref` 에 repo-root → `plugins/rein-core/` dual-path 해석을 추가해 해소. govcheck 가 이제 plugin 훅 30개를 실제로 스캔(top-level 8 훅이 script 참조) + exit 0.
- 루트 임시 노트(`need-to-confirm.md` 등)의 본 정비 언급 줄 갱신 — 별 작업(앞 codex-ask 에서 별도 다룸).
- trail/CHANGELOG 등 과거 기록의 `.claude/orchestrator|agents` 언급 — 히스토리이므로 불변.
- main 병합 — 진행 중인 병렬 실행 시리즈와 함께 별도 판정(본 정비는 내부 doc/tooling = no bump).

## 리스크

- (R1) CLAUDE.md 슬림화로 메인테이너 규칙 자동 로드가 끊길 위험 → mitigation: branch/readme/versioning import 3줄을 명시 보존(현행 동작과 동일). 슬림 후에도 세션 시작 시 3규칙 로드 확인.
- (R2) orchestrator/workflows 삭제로 govcheck/AGENTS 참조 dangling → mitigation: 본 DoD 3번에서 동시 정리. 삭제 후 govcheck exit 0 + grep 0건 검증.
- (R3) `.claude/CLAUDE.md`·govcheck·AGENTS 는 source 로 분류되어 DoD 게이트 대상 → 본 DoD 가 충족. 삭제는 `git rm`(Edit/Write 아님)이나 정합 위해 동일 DoD 범위.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor   # 기능 변경 없는 구조 개선(오버레이 슬림 + 참조 정리) — refactor 전담
skills:
  - rein:codex-review                  # commit gate 필수 (Mode A — stamp)
mcps: []
rationale: >
  DoD 키워드 = refactor / 오버레이 정리 / stale 참조 → feature-builder-refactor 매치.
  본 세션이 이미 codex-ask 로 대상·리스크·참조처를 전수 검증 완료(govcheck if-guard,
  HOOK_GLOB false-fail, AGENTS dangling, 삭제 4종 main 미포함)했으므로 메인 세션 인라인
  실행이 효율적 — 단일 coherent 정비(슬림 1 + 삭제 4 + 참조수정 2). codex-review 는
  commit 게이트라 필수. security_tier=light — 마크다운/문서 + govcheck config 1줄 제거,
  실행 경로·권한·입력 경계 변화 없음.
security_tier: light
approved_by_user: true   # 사용자 "오토모드 키고 바로 정리 들어가" (2026-06-01) 로 승인
```
