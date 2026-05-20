# DoD — UPS-1 회귀 fix (행동 강령 body marker 복원)

- 날짜: 2026-05-20
- 유형: fix (회귀)
- slug: ups-1-action-mandate-regression
- plan ref: (none — 단발성 회귀 fix, plan 불요)

## 배경

Phase 2c push 완료 후 (`origin/dev = d5d29d5`) 별 cycle 후보로 trail/index.md 가 명시한 UPS-1 잔존 회귀. v1.3.3 prep Phase 4 시점 short summary 도입 시 `## 행동 강령` 헤더 이전이 누락돼 3개 hook 테스트가 fail.

## 증상

```
$ bash tests/hooks/test-user-prompt-submit-rules.sh
FAIL: additionalContext missing '행동 강령' header

$ bash tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh
FAIL(A): missing answer-only-mode body marker '행동 강령'

$ bash tests/hooks/test-pre-tool-use-bash-rules.sh
AssertionError: missing 행동 강령
```

## 원인

`plugins/rein-core/rules/short/answer-only-summary.md` 와 `plugins/rein-core/rules/short/background-jobs-summary.md` 는 turn-brief 용 짧은 요약본인데, 본문이 `# Title` 다음 곧바로 평문 단락으로 시작. `## 행동 강령` 헤더가 없어 UserPromptSubmit / PreToolUse hook 이 emit 하는 additionalContext 에도 `행동 강령` 문자열이 포함되지 않음.

풀버전 (`plugins/rein-core/rules/answer-only-mode.md`, `rules/background-jobs.md`) 은 첫 `## ` 헤더가 `## 행동 강령` 으로 정상.

## 변경 범위

| 파일 | 변경 |
|---|---|
| `plugins/rein-core/rules/short/answer-only-summary.md` | `# Title` 다음 줄에 `## 행동 강령` 헤더 + 본문 1줄 삽입 |
| `plugins/rein-core/rules/short/background-jobs-summary.md` | 동일 패턴 |

## 검증 기준 (Definition of Done)

- [ ] `bash tests/hooks/test-user-prompt-submit-rules.sh` PASS
- [ ] `bash tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh` PASS (A/B/C 3 path 모두)
- [ ] `bash tests/hooks/test-pre-tool-use-bash-rules.sh` PASS (a/b/c 3 path 모두)
- [ ] `bash tests/rein-test.sh` 전체 회귀 없음 (Phase 2c claim 33/33 유지)
- [ ] `bash tests/hooks/test-action-mandate-existing-rules.sh` PASS — 첫 `## ` 헤더가 `## 행동 강령` 인지 + 본문 size ≤ 2048B 검증 (short md 도 검증 대상에 들어가는지 사전 확인 필요)

## 비범위

- 풀버전 rules/*.md 편집
- hook 본체 (`user-prompt-submit-rules.sh`, `pre-tool-use-bash-rules.sh`) 편집
- 별 cycle 후보 (b/c/d) 진행

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale: |
  - agent: 회귀 fix (DoD 키워드 "회귀"/"fix"), reproduction-first 전략 적합.
    이미 failing test 3개로 회귀 증상이 코드로 고정됨 (test-user-prompt-submit-rules /
    -bootstrap-advisory / test-pre-tool-use-bash-rules).
  - skills/codex-review: plugin source SSOT (rules/short/*.md) 편집은 사용자 ship 대상이므로 외부 모델 second opinion 필수.
  - mcps: 없음 — markdown 본문 2 줄 변경, 외부 시스템 조회 / 라이브러리 조사 불필요.
  - security_tier: light — markdown 평문 텍스트만, secret / 외부 input boundary / command exec 없음. AGENTS.md §6 light-tier 기준 부합.
approved_by_user: true
```

## 라우팅 승인 사유 (사용자 결재)

Auto Mode 활성 + 사용자 직접 명령 "갱신하고 (a) 진행해" 로 reasonable call 진행. 변경 범위가 markdown 2 파일·평문 텍스트·기존 failing test 로 회귀 영역 고정 → reasonable default 로 fix 전략 명확.
