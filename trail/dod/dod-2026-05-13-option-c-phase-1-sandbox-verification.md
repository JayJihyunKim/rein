# DoD — Option C Phase 1: Sandbox dogfood verification

- 날짜: 2026-05-13
- 유형: implementation (Phase 1 — verification cycle)
- brainstorm ref: `docs/brainstorms/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- spec ref: `docs/specs/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`

## 작업 기준

### 목표

plan Phase 1 의 3 tasks 실행 (covers: S10):
- Task 1.1 sandbox 디렉토리 setup
- Task 1.2 `claude --plugin-dir` 로 plugin 단독 실행 + trace 캡처
- Task 1.3 evidence 파일 작성

성공 시 Phase 2 (drift checker 통합) 진입 가능. 실패 시 (trace 캡처 불가, plugin install 오류 등) 사용자와 협의 후 fallback 결정.

### Scope (명시)

- 포함:
  - `/tmp/rein-dogfood-sandbox/` 임시 디렉토리 setup (`git init` + minimal `.gitignore`)
  - `claude --plugin-dir /Users/jihyunkim/dreamline/rein-dev/plugins/rein-core` 호출 (사용자 명령 또는 Bash)
  - SessionStart / UserPromptSubmit / PreToolUse hook trace 캡처 — hook envelope 의 `additionalContext` 가 출력되는지 + 각 hook trigger count
  - 7 shared rule (`code-style`, `security`, `testing`, `answer-only-mode`, `subagent-review`, `background-jobs`, `design-plan-coverage`) 의 prompt byte count 측정
  - evidence 파일 작성: `trail/decisions/2026-05-13-option-c-sandbox-verification.md`
    - hook trigger count 표 (hook 명 / event / trigger count = 1)
    - 7 shared rule prompt byte count 표 (rule 명 / hook 명 / byte > 0)
- 제외:
  - 본 repo 의 plugin install / overlay 변경 (Phase 3 의 일)
  - drift checker / branch-strategy / workflow 의 코드 편집 (Phase 2, 5 의 일)

### 성공 기준

- [ ] sandbox 디렉토리 생성 + `.git/` 존재
- [ ] `claude --plugin-dir` 호출이 정상 종료 (또는 fallback 방식 결정)
- [ ] hook trace 또는 hook 별 발견 evidence 캡처 (출력 형식은 Claude CLI 가 결정)
- [ ] evidence 파일 작성 — 두 표 (trigger count + prompt byte count) 포함
- [ ] codex review PASS
- [ ] **failure 시**: 사용자에게 fallback (manual instrumentation / hook 에 stderr 로깅 추가 / Phase 1 skip 등) 결정 요청

### Risk / Open

- `claude --plugin-dir` 의 정확한 sub-command 시그니처는 trail/weekly 의 이전 언급만 있음. 작동 안 하면 fallback 필요
- Claude CLI 가 hook envelope 의 `additionalContext` 를 직접 expose 안 할 수 있음 — 그 경우 hook 본문에 임시 stderr log 추가 후 trace
- 본 메인테이너 Claude 세션 안에서 sub-Claude 실행 시 conflict 가능 (별 세션 권장)

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review
mcps: []
rationale: |
  Phase 1 은 임시 디렉토리 setup + 외부 명령 (`claude --plugin-dir`) 실행 + evidence file 작성. 메인 세션 직접 진행 (subagent dispatch 불필요).
  코드 편집은 evidence 파일 작성만 — 단순 markdown. 단 외부 명령의 trace 캡처는 불확실성 있어 사용자 협의 필요할 수 있음.
approved_by_user: true
```

## 범위 연결

plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
work unit: Phase 1 (Tasks 1.1 + 1.2 + 1.3)
covers: [S10]
