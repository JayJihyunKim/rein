# DoD — cc-feature-adoption Phase 2: SPIKE-1 (병렬 hook exit/deny 병합 + PostToolUse tool_use_id 측정)

- 작업 시작일: 2026-05-20
- 유형: research (no bump — production 코드 변경 없음, 측정 spike + report)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2 (Task 2.1)
covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

## 배경

cc-feature-adoption plan 의 HK-4 (post-edit-dispatcher 를 의존성 없는 sub-hook 으로 분할해 병렬 hook entry 로 등록) 와 PERF-2 (pre-edit-dod-gate + dispatcher 가 PostToolUse 의 `tool_use_id` 키로 Python resolver 결과를 공유) 는 둘 다 Claude Code 의 **미문서 동작** 에 의존한다:

1. **HK-4 전제**: 동일 matcher 의 hook entry 가 여러 개일 때, **하나가 `exit 2` 또는 `permissionDecision: "deny"` 를 반환하면 전체 도구 호출이 차단**되는가? (= OR-propagation 등가) 아니면 다른 entry 의 결과가 마지막 entry 의 결정으로 덮어쓰여지는가?
2. **PERF-2 전제**: PostToolUse 입력 JSON 에 `tool_use_id` 필드가 실제로 제공되는가? PreToolUse 와 PostToolUse 가 동일한 `tool_use_id` 를 공유해 둘 사이 cache key 로 쓸 수 있는가?

두 전제가 실측으로 확인되어야 Phase 2b (HK-4·PERF-2·HK-5 implemented 전환) 진입 가능. 본 SPIKE-1 은 production 코드 변경 없이 임시 probe hook 로 두 가설을 검증한다.

## 완료 기준

### 측정 hook 작성 (production 격리)

- [ ] `tests/hooks/spike-parallel-exit-probe.sh` — 동일 matcher 의 2 entry 중 하나가 exit 2 + deny JSON 을 반환하고 다른 entry 는 exit 0 + allow JSON 을 반환하도록 작성. 각 entry 가 stdin (input JSON) 의 hash + 자신의 exit code/decision 을 `tests/fixtures/spike/parallel-exit-<entry>.jsonl` 에 append 하도록 → 사후에 어느 결정이 propagation 됐는지 분석 가능
- [ ] `tests/hooks/spike-tool-use-id-probe.sh` — PostToolUse(Edit|Write|MultiEdit) 와 PreToolUse(Edit|Write|MultiEdit) 양쪽에서 호출됐을 때 stdin JSON 의 keys + `tool_use_id` (혹은 등가) 값 + tool name + timestamp 를 `tests/fixtures/spike/tool-use-id-<phase>.jsonl` 에 dump
- [ ] 두 probe 모두 PROJECT_DIR 밖 stdin·환경 변수에 의존하지 않고 항상 exit 0 로 종료해 측정 자체가 사용자 작업을 차단하지 않게 fail-soft (parallel-exit probe 의 "exit 2 의도 entry" 만 exit 2)
- [ ] probe 가 외부 secret 노출·임의 파일 쓰기·privileged path 접근 없는지 코드리뷰 (security_tier:light 정당화)

### hooks.json 임시 등록

- [ ] `plugins/rein-core/hooks/hooks.json` 의 PostToolUse(Edit|Write|MultiEdit) 블록에 `spike-tool-use-id-probe.sh` entry 1개 임시 추가 — 기존 `post-edit-dispatcher.sh` 와 **동일 entry 의 hooks[]** 가 아니라 **별개 entry** 로 등록해 parallel entry 동작 동시 관측
- [ ] PreToolUse(Edit|Write|MultiEdit) 블록에도 `spike-tool-use-id-probe.sh` entry 1개 임시 추가 — pre/post 양쪽 dump 비교 위함
- [ ] PostToolUse(Edit|Write|MultiEdit) 블록에 `spike-parallel-exit-probe.sh` entry 2개 (`PROBE_ROLE=allow`, `PROBE_ROLE=deny` 환경 변수 또는 wrapper 분할) — exit2/deny propagation 관찰
- [ ] 임시 entry 는 **PostToolUse 만 사용** (PreToolUse 의 parallel-exit 추가는 사용자 차단 위험 — 본 spike 는 PostToolUse 만)

### 측정 실행 (3회 trigger)

- [ ] 단순 Edit/Write 1회 (예: `need-to-confirm.md` 1줄 추가) → probe 3종 모두 record
- [ ] 추가 Edit 2회 더 반복 → 결과 일관성 확인 (random 변동 없는지)
- [ ] 결과 jsonl 3 종 (parallel-exit-allow, parallel-exit-deny, tool-use-id-pre/post) 누적 후 정리

### Report 작성

- [ ] `docs/reports/2026-05-19-cc-feature-spike.md` 신축
  - 측정 설계 + probe 코드 인용
  - 측정 결과 raw dump 요약 (jsonl excerpt)
  - **HK-4 go/no-go 판정**: 병렬 exit2 결과가 도구 호출 전체에 propagation 되면 go (OR-propagation 등가, dispatcher 분할 안전), 마지막 entry 결정만 반영되면 no-go (Phase 2b deferred 유지)
  - **PERF-2 go/no-go 판정**: PostToolUse 가 `tool_use_id` (또는 등가 unique id) 를 제공 + PreToolUse 와 매칭 가능하면 go (subprocess cache 가능), 부재 또는 mismatch 면 no-go
  - 한계: 본 측정은 macOS Darwin 25.4 / Claude Code 현 release 1개 환경 — Phase 2b 진입 전 Linux/CI 환경에서도 재측정 권장

### hooks.json 원상복구

- [ ] 측정 완료 후 probe 3종 entry 를 `plugins/rein-core/hooks/hooks.json` 에서 제거 — `git diff hooks.json` 가 비어 있어야 함 (production 오염 방지)
- [ ] `tests/hooks/spike-*.sh` 는 **남긴다** — Phase 2b 진입 / 회귀 재현용
- [ ] `tests/fixtures/spike/*.jsonl` 은 **gitignore** — 환경별 raw dump 이므로 repo 추적 부적합 (별도 `tests/fixtures/spike/.gitignore` 또는 root `.gitignore` 추가)

### 검증

- [ ] codex review PASS (light tier — production 코드 미변경, probe + report 만)
- [ ] security review PASS (light tier — probe 의 secret/path-traversal 없음)
- [ ] 회귀 테스트 (`bash tests/scripts/run-all.sh`) 통과
- [ ] commit (no bump): `chore(spike): Task 2.1 — 병렬 hook exit/deny + tool_use_id 측정 (SPIKE-1)`
- [ ] dev push (main 머지 없음 — no bump 작업)

## 비범위

- HK-4 dispatcher 실제 분할 (Phase 2b 작업)
- PERF-2 resolver cache 구현 (Phase 2b 작업)
- HK-5 PostToolBatch aggregator (HK-4 land 후)
- v1.3.3 main 머지 + tag (별 cycle — 사용자 결정 대기)
- 다른 Phase (3·4) 작업

## 위험

- **R1**: probe 의 `spike-parallel-exit-probe.sh` 가 deny 를 실제로 발사해 도구 호출이 차단됨 → 사용자 작업 차단. **Mitigation**: PostToolUse 만 등록 (PostToolUse 차단은 도구 실행 이후 단계라 즉시 작업 진행에 영향 작음). 본 DoD 의 측정 단계는 **probe 등록 직후 1개 Edit 으로 trigger 한 뒤 hooks.json 즉시 원상복구** 까지를 한 cycle 로 묶어 진행 — 측정 fixture 가 누적되면 hooks.json 을 다시 revert 한 채로 분석.
- **R2**: probe stdin 입력 JSON schema 가 Claude Code 버전에 따라 다를 수 있음 → tool_use_id 필드 이름 mismatch. **Mitigation**: probe 가 stdin 전체 JSON keys 와 raw payload 를 dump 하므로 사후에 다른 필드명도 식별 가능 (예: `toolUseId`, `id`, `event_id`).
- **R3**: parallel-exit probe 가 deny 를 발사할 때, **post-edit-dispatcher.sh 가 이미 실행 완료된 후** propagation 이 발생하면 OR-propagation 검증 의미가 약함 (dispatcher 가 이미 작업 완료). **Mitigation**: probe 가 PostToolUse 의 첫 entry 가 아니라 별개 entry 로 매칭되므로 entry 순서가 아닌 entry 간 병합 의미를 측정. report 에 entry 순서 의존성 caveat 명시.
- **R4**: tool_use_id 가 PostToolUse 에 제공되더라도 PreToolUse 와 동일하지 않을 수 있음 (각 단계가 별 id) → PERF-2 cache key 전제 위배. **Mitigation**: tool-use-id probe 가 pre/post 양쪽에서 id 를 dump 해 매칭 확인.

## 라우팅 추천

```yaml
agent: rein:researcher
skills:
  - rein:codex-review        # Step 5 필수 게이트 (probe 코드 + report)
mcps: []
security_tier: light          # production 차단 로직 미변경, secret/auth 무관, probe 는 stdin JSON dump 전용
complexity: low               # probe 2 파일 + report 1 파일 + hooks.json temp toggle
model_hint: sonnet            # 측정·검증 작업, 아키텍처 결정 없음
effort_hint: small            # 측정·dump·분석 — 실측 시간이 대부분
rationale:
  - 작업 성격: spike (production 미변경, 측정 + report). feature-builder 가 아닌 researcher 가 적합 — Claude Code 미문서 동작에 대한 실증·조사
  - 파일 패턴: tests/hooks/spike-*.sh (신축 2), docs/reports/2026-05-19-cc-feature-spike.md (신축 1), plugins/rein-core/hooks/hooks.json (임시 toggle — commit 시 원상복구), tests/fixtures/spike/.gitignore (신축)
  - security_tier light 정당화: probe 가 stdin JSON 만 dump (write to tests/fixtures/spike/, 외부 네트워크·secret 접근 없음). pre-bash-guard, pre-edit-dod-gate 차단 로직 미변경
  - codex-review 단일 스킬: spike report 의 go/no-go 판정 근거가 측정 결과와 일치하는지 검증 + probe 코드의 fail-soft 패턴 확인
  - writing-plans 미포함 이유: 본 작업은 plan 갱신이 아니라 plan 의 Task 2.1 실행. Phase 2b 진입 시 (go 판정 후) 별도 cycle 에서 writing-plans 사용
  - changelog-writer 미포함 이유: no bump 작업 — CHANGELOG 변경 없음
approved_by_user: true   # 2026-05-20 사용자 승인 — 원안 (rein:researcher + codex-review + security_tier:light)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject)
- [x] cc-feature-adoption plan Phase 2 / Task 2.1 본문 확인
- [x] dev 브랜치 확인 (HEAD = ab41077, origin/dev sync)
- [x] main HEAD = 7795193 (v1.3.2), v1.3.3 tag 아직 부재 — 본 작업은 main 영향 0
- [x] hooks.json PostToolUse 블록 구조 확인 (Edit|Write|MultiEdit entry 1개 + Agent entry 1개)
- [x] spec-review pending 2건 (e740bea / fac428f9) 은 paired .reviewed 도 존재 — gate 통과 (SR-1 staleness 는 별 cycle)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. probe 2종 작성 (`tests/hooks/spike-*.sh`) — fail-soft + jsonl dump
2. `tests/fixtures/spike/.gitignore` 신축 (`*` ignore)
3. `hooks.json` 에 probe 3 entry 임시 등록 (PostToolUse Edit|Write|MultiEdit 블록)
4. Edit trigger 3회 (예: `need-to-confirm.md` 줄 추가 → revert)
5. jsonl raw dump 분석 → HK-4 / PERF-2 go-no-go 판단
6. `docs/reports/2026-05-19-cc-feature-spike.md` 신축 (측정 설계 + 결과 + 판정)
7. `hooks.json` 원상복구 (probe entry 제거) — `git diff hooks.json` empty 확인
8. codex-review (light tier) → security-review (light tier — stamp 없이 commit 허용)
9. commit (no bump) + dev push
10. trail/inbox + trail/index 갱신 (index 의 "다음 진입점" 을 SPIKE-1 결과에 따라 갱신 — go 면 Phase 2b 진입, no-go 면 Phase 3 진입)
