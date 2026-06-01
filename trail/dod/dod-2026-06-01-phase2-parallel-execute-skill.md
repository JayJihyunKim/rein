# DoD — Phase 2: parallel-execute 스킬 신설 (웨이브 스케줄러 + 워커 계약 + 부모 통합)

- 날짜: 2026-06-01
- 유형: feat (병렬 실행 재설계 Phase 2 — 같은-트리 웨이브 병렬 실행 스킬)
- plan ref: docs/plans/2026-05-30-plan-driven-wave-parallel-execution.md §Phase 2 (Task 2.1/2.2/2.3)

## 목표 (Why)

Phase 1 에서 v2 스키마(`tasks[]` + `depends_on` + `mode` + `scope`)와 검증기(위상정렬·사이클·동시쌍 disjoint fail-closed + `schedule` emitter)를 확정했다. Phase 2 는 그 위에 **실제 실행 계층**을 올린다 — 활성 plan 의 `## 실행 전략` 을 읽어 의존 위상정렬로 웨이브를 유도하고, 각 웨이브의 독립 `edit_only` 태스크를 **같은 작업 트리에서** 서브에이전트로 병렬 실행, `mutating`·의존 태스크는 순차 실행하며, 부모(메인 세션)가 웨이브 단위로 검증·테스트·커밋하는 흐름을 Rein 자체 스킬(`parallel-execute`)로 제공한다.

격리는 강제된 sandbox 가 아니라 **(1) 워커 프롬프트의 best-effort 규율 + (2) 부모의 사후 델타 검증** 두 겹이다. 안전성의 1차 보증은 write-set 분리(검증기가 동시쌍 disjoint 보장), 2차는 부모의 baseline-delta 검증이다.

## 성공 기준 (Acceptance)

### Task 2.1 — 스킬 골격 + 웨이브 유도 + 결정적 스케줄러
covers: EXEC-SKILL-WAVE-DETERMINISTIC-SCHEDULER-MUTATING-SOLO

1. **실패 테스트 먼저 (TDD RED)** — `tests/skills/test-parallel-execute-skill.sh` 신설: 파일 존재, frontmatter `name: parallel-execute` + `description:`, 본문 키워드 grep("위상정렬"/"ready"/"mutating"/"단독"/"병렬 dispatch"), 본문 ≤ 6144 byte(`wc -c`). RED 확인.
2. `plugins/rein-core/skills/parallel-execute/SKILL.md` 신설 — frontmatter + `## 목적` + `## 사용 시점` + `## Preflight`(활성 plan `## 실행 전략` 파싱, 검증기가 이미 fail-closed 검증함을 전제, 섹션 부재 → 순차 안내) + `## 웨이브 유도 + 결정적 스케줄러` + `## 호스트 능력 fallback`.
3. **canonical 순서 SSOT** — 스케줄러 섹션은 `python3 scripts/rein-validate-coverage-matrix.py schedule <plan>`(Phase 1 emitter, 출력 `step <n>: <id>...`)를 결정적 웨이브 순서의 SSOT 로 소비하도록 명시. helper 미가용 시 같은 규칙(ready→mutating-solo-then-edit_only) 복제.
4. GREEN — `bash tests/skills/test-parallel-execute-skill.sh` 통과(Task 2.1 키워드 한정).

### Task 2.2 — 워커 dispatch 계약 (edit_only + mutating) + 구조화 결과 스키마
covers: EXEC-SKILL-WORKER-EDIT-ONLY-CONTRACT-RESULT-SCHEMA, EXEC-SKILL-WAVE-DETERMINISTIC-SCHEDULER-MUTATING-SOLO

5. **실패 단언 추가 (RED)** — 공통 결과 스키마 키("task_id"/"status"/"changed_files"/"blocked_reason"/"recommendation") + edit_only("커밋 금지"/"stamp 금지") + mutating("변경성 명령 허용"/"단독 웨이브"/"예상 부작용 경로") grep 추가. RED 확인.
6. SKILL.md `## 워커 dispatch 계약` — 공통 결과 스키마(두 변형 동일, 최종 메시지 반환 기반, 워크트리 마커/결과 파일 없음): `task_id`(필수)/`status: completed|blocked`(필수)/`changed_files`(필수, advisory)/`blocked_reason`(blocked 시)/`recommendation: parent_fallback|split|scope_expand`(blocked 시)/`summary`. 부모는 `status=blocked` 또는 결과 누락(timeout/truncation)을 미완 처리 → 의존 후속 다음 웨이브 진입 불가.
7. **edit_only 변형** — 선언 `scope` 파일만 편집(best-effort). 금지: 커밋·스테이징·리뷰/보안 stamp·trail·전체 포매터·변경성 테스트/코드젠. 같은 웨이브 여러 edit_only 한 메시지 병렬 dispatch.
8. **mutating 변형** — 자기 자신만의 단독 웨이브. edit_only 금지목록 중 변경성 명령만 허용(코드젠·변경성 테스트·설치). 커밋·스테이징·stamp·trail 은 여전히 부모 소유 금지. 동일 결과 스키마 반환. 검증 기준 `scope` = 선언 + 예상 부작용 경로.
9. 본문 ≤ 6144 byte 재확인. 초과 시 schema 상세를 `exec-strategy-schema.md` 로 위임. GREEN.

### Task 2.3 — 부모 통합 (클린 시작 + 델타 검증 + 웨이브당 1커밋)
covers: EXEC-SKILL-PARENT-CLEAN-START-DELTA-VALIDATION-WAVE-COMMIT

10. **실패 단언 추가 (RED)** — "클린"/"porcelain"/"델타"/"부분집합"/"reject"/"웨이브당 1커밋" + `git status --porcelain` + `git ls-files --others --exclude-standard` grep 추가. RED 확인.
11. SKILL.md `## 부모 통합 (barrier)` — 각 웨이브 클린 트리 시작(직전 웨이브 커밋 보장, 첫 웨이브는 세션 현재 커밋 상태). 웨이브 경계 dirty → 중단·보고. 웨이브 완료 후 시작 이후 델타 산출(`git status --porcelain=v1 -z -uall --ignored=no` 또는 `git diff --name-only HEAD` + `git ls-files --others --exclude-standard`) → repo-relative literal 파일 경로 정규화. 델타 ⊆ 웨이브 `scope`(mutating 은 +부작용) 합집합 검증. 위반 → reject + 보고(커밋 안 함). 통과 → 웨이브 단위 1회 포맷/린트/테스트/리뷰 → 그 델타만 1커밋 → 다음(다시 클린 시작).
12. **(보안 L1 이월, 필수)** — 부모가 `scope` 경로를 델타 검증에 소비할 때 `..` 정규화(path traversal 차단) + 프로젝트 루트 containment 검증(루트 밖 경로는 reject). 이를 부모 통합 섹션에 명시.
13. 사용자 보고 방식 섹션(내부 식별자 평문 번역) 추가. 본문 ≤ 6144 byte 최종 확인. GREEN.

### 공통

14. 회귀 무영향 — 기존 skills 테스트 스위트(`tests/skills/run-all.sh`) 무회귀 + 신규 테스트를 run-all 에 등록.
15. codex 리뷰 PASS + 리뷰 stamp, security 리뷰 PASS + security stamp (commit gate).

## 변경 파일

- `plugins/rein-core/skills/parallel-execute/SKILL.md` (신설)
- `tests/skills/test-parallel-execute-skill.sh` (신설)
- `tests/skills/run-all.sh` (신규 테스트 등록)

## 제외 (Out of scope)

- Phase 3 (plan-writer v2 / PLN-1 게이트 제거 / 워크트리 기계 폐기) — 별 Task. 본 Phase 는 스킬 신설만.
- Phase 4 회귀 스위트 통합 (validator+스케줄러+부모 end-to-end) — Phase 4.
- 검증기/스케줄러 emitter 자체 변경 — Phase 1 에서 확정. 본 Phase 는 그 출력을 **소비**만.
- `feature-builder-worker` 에이전트 재작성 — Phase 3 Task 3.3. 본 Phase 의 워커 dispatch 는 인라인 프롬프트 또는 Task 3.3 후 재작성된 에이전트 지정(둘 다 계약 키워드 동일)으로 기술.
- 워크트리 격리 / mutating 병렬 / glob scope / cross-plan / 워커별 독립 커밋·stamp / 자동 롤백 (spec Non-goals 전부).

## 리스크

- (R1) 스킬 본문 6 KB NFR 초과 — 3 계약(스케줄러·워커·부모)을 한 파일에 채우면 예산 압박. mitigation: schema 상세는 `exec-strategy-schema.md` 참조 위임, 본문은 절차·키워드 중심 압축. 매 Task 끝에 `wc -c` 확인.
- (R2) 스킬은 마크다운 지시문이라 런타임 강제 불가 — 격리는 best-effort. mitigation: 안전성 1차는 검증기의 동시쌍 disjoint(Phase 1 기계 보증), 2차는 부모 델타 검증(기계가독 git porcelain). 스킬은 이 두 겹을 명문화.
- (R3) 델타 검증 경로 정규화 누락 시 path traversal — `..` 또는 루트 밖 scope 가 검증을 우회. mitigation: Acceptance 12 (L1 이월) 로 `..` normalize + containment 명시.
- (R4) 테스트가 키워드 grep 위주라 실제 동작 미검증 — 스킬은 지시문이라 단위 실행 불가. mitigation: grep 단언은 계약 presence 보증, 실제 동작 검증은 Phase 4 end-to-end + validator/스케줄러 단위(Phase 1)가 담당. 본 Phase 테스트는 구조·계약 presence 로 한정(정직).

## 라우팅 추천

```yaml
agent: rein:feature-builder        # Phase 2 = 신규 스킬 파일 + 테스트 신설 (add-feature). 버그·리팩토링 아님
skills:
  - rein:codex-review              # commit gate 필수 (리뷰 stamp)
mcps: []
rationale: >
  parallel-execute 스킬 신설은 신규 기능 추가(SKILL.md + 테스트 파일 생성)이므로
  feature-builder 가 적합. TDD red-green (각 Task 실패 테스트 먼저 → GREEN). 산출물이
  마크다운 지시문 + bash grep 테스트라 외부 의존 없음(MCP 불필요). Phase 1 의 schedule
  emitter 출력을 소비하는 계약을 정확히 기술하는 것이 핵심. security_tier=normal —
  스킬이 git delta·scope 경로를 다루므로 path traversal(L1 이월)을 acceptance 에 포함.
security_tier: normal
approved_by_user: true             # 사용자 "이대로 진행" — feature-builder + TDD + codex/security 리뷰 승인 (2026-06-01)
```

## Self-review 예정 항목 (AGENTS.md §6)

- 스케줄러 섹션이 Phase 1 `schedule` emitter 출력(`step <n>: <id>...`)을 SSOT 로 정확히 소비하는가 (규칙 재정의 아닌 위임)
- mutating 단독 웨이브 / edit_only 병렬 dispatch 의 결정성이 spec 과 일치하는가 (plan 순서 가장 앞선 mutating 1개)
- 공통 결과 스키마 6 키가 spec EXEC-SKILL-WORKER 행과 정확히 일치하는가
- 부모 델타 검증이 기계가독 git porcelain + repo-relative literal 정규화 + `..`/containment(L1)를 모두 명문화하는가
- 본문 ≤ 6144 byte NFR 충족 (각 Task 후 측정)
- 신규 테스트가 RED→GREEN 증명 + run-all 등록 + 기존 skills 스위트 무회귀
- 사용자 보고 섹션이 내부 식별자를 평문 번역하는가
