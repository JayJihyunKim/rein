# Cycle X4.C.3 — 완료 (4 policy hook fast-path skip + state_is_valid)

- 날짜: 2026-05-21
- 유형: feat
- DoD: `trail/dod/dod-2026-05-21-cycle-x4-c-3-hook-fast-path-skip.md`
- design ref: `docs/specs/2026-05-21-area-c-state-machine.md` §8.4
- plan ref: `docs/plans/2026-05-20-integrated-roadmap.md` §4.3 (영역 C)

## 요약

영역 C 의 fast-path skip cycle. 4 policy hook 에 `effective_mode` 기반 fast-path skip
분기를 추가하고, state-machine.sh 에 corrupt-state 를 걸러내는 `state_is_valid`
predicate 를 도입했다. 핵심 안전 불변식: state 가 **불확실하면 항상 legacy** (게이트
유지 / envelope 발행) — skip 은 state 가 design §2 contract 를 완전히 만족할 때만.

## 변경 파일

수정:
- `plugins/rein-core/hooks/lib/state-machine.sh` — `state_is_valid` predicate 신규
  (design §2 schema-v1 contract 전수 검증: schema_version==1 + mode∈{answer,explore,
  source_edit,commit} 정확 enum + updated_at:str + dirty_files:list + last_drain_seq:int
  + optional command_class_cache:dict/risk_score:int) / `read_effective_mode` 의
  pipe+heredoc → argv fix / `acquire_state_lock` 에 `REIN_STATE_LOCK_TIMEOUT_MS` test-seam
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` — fast-path: state_is_valid + read 성공
  + mode=source_edit + dirty_files hit 일 때만 validator subprocess skip (보수적)
- `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` — fast-path:
  state_is_valid + read 성공 + mode=answer 일 때만 envelope skip
- `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` — 동일 패턴
- `plugins/rein-core/hooks/post-edit-spec-review-gate.sh` — 같은 path .pending marker
  존재 시 mtime touch dedup (`grep -qxF` 고정 문자열, security Info-1)
- `scripts/rein-check-plugin-drift.py` — check_conditional_event_hook 의 hook subprocess
  를 tempfile.TemporaryDirectory 로 CLAUDE_PROJECT_DIR 격리 (ambient state.json 누출 방지)
- `tests/hooks/run-all.sh` — 신규 test 등록
- `tests/hooks/test-post-edit-design-plan-coverage-rule.sh` — REIN_PROJECT_DIR_OVERRIDE 격리

신규:
- `tests/hooks/test-state-fast-path-skip.sh` — 10 adversarial test (T1~T10)

## 리뷰 (codex 7 rounds + self-review + security)

codex Mode A 7라운드 — 각 라운드가 "answer" sentinel 이 error-fallback 으로 새는
서로 다른 경로를 발견·수정 (단일 부류):
- R1 state 파일 부재 / R2 malformed JSON·unknown schema / R3 lock 획득 실패 /
  R4 schema-v1 + 필드 타입 except / R5 비-enum/whitespace mode word-split /
  R6 required 필드 누락 → 모두 `state_is_valid` design §2 전수 검증 + capture 의
  exit-status 신뢰로 종결. R2.5 test/checker 의 live state.json 누출 → project-dir 격리.
- R7: 코드 결함 0 확인. 잔여는 test 대칭성 갭(routing 1/7) → T10 을 두 hook 전 매트릭스로
  확장 (14 assertions) 후 escalation §3 (Low/test-level) 에 따라 user-approved self-review
  stamp 로 종결.
- security review (standard tier): Critical/High/Medium/Low/Info = 0/0/0/0/0.
  injection/traversal·게이트 우회·test-seam·tempdir·fail-soft·Info-1 6초점 probe 검증.

## 검증

- `bash tests/hooks/test-state-fast-path-skip.sh` 10/10
- `bash tests/hooks/test-state-machine.sh` 6/6 (V1)
- `bash tests/hooks/test-state-machine-integration.sh` 9/9 (V2)
- `bash tests/hooks/run-all.sh` ALL SUITES PASSED
- `bash tests/rein-test.sh` 15/15 (CLI 표면 회귀 0)
- `python3 scripts/rein-check-plugin-drift.py` rc=0

## 잔여 / 후속

- codex 비차단 advisory: state_is_valid/read_effective_mode 2-call TOCTOU — single-lock/
  single-writer 모델 하 실질적 누출 아님 (codex 명시). 필요 시 X4.C.4 에서 atomic 결합 검토.
- security Info-2 (비차단): profile.yaml `security_level: base` 인데 standard 로 리뷰됨.
  repo 정상 posture 가 standard 면 profile 갱신 검토.
- 다음 권장 cycle: X4.C.4 (SPIKE 측정 + 영역 C 종결).
