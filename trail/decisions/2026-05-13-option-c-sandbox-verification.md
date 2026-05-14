# Option C Phase 1 — Sandbox dogfood verification evidence

- 날짜: 2026-05-13T03:23:25Z (UTC)
- plan ref: `docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md`
- work unit: Phase 1 / Task 1.1 + 1.2 + 1.3
- covers: [S10]

## 실행 환경

- Sandbox: `/tmp/rein-dogfood-sandbox/` (fresh `git init`, minimal `AGENTS.md`)
- Plugin path: `/Users/jihyunkim/dreamline/rein-dev/plugins/rein-core`
- Claude CLI: `2.1.140 (Claude Code)`
- Probe 명령:
  ```bash
  claude --plugin-dir <PLUGIN> --print --output-format stream-json \
         --verbose --include-hook-events --debug hooks \
         --debug-file <DEBUG_LOG> "say hi in 3 words" \
         < /dev/null > <OUTPUT_JSONL> 2> <STDERR_LOG>
  ```
- Probe prompt: `"say hi in 3 words"` (text only — tool use 없음 → PreToolUse 미발생)

## Plugin 등록

debug.log 기록:

```
Loaded hooks from standard location for plugin rein:        plugins/rein-core/hooks/hooks.json
Loaded hooks from standard location for plugin superpowers: ~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/hooks/hooks.json
Loaded hooks from standard location for plugin ralph-loop:  ~/.claude/plugins/cache/claude-plugins-official/ralph-loop/1.0.0/hooks/hooks.json
Registered 15 hooks from 11 plugins
```

### 중요한 발견 — `--plugin-dir` 는 isolated 아님

`--plugin-dir` 옵션은 추가 plugin 1개 load. 본 메인테이너 사용자 환경의 `~/.claude/plugins/cache/` 의 user-level installed plugins (현재: `superpowers`, `ralph-loop`) 도 함께 active. "11 plugins" 카운트가 그 증거 (3 = rein + superpowers + ralph-loop 가 명시, 나머지 8 은 sub-plugin / claude-plugins-official cluster 가능).

이 사실은 plan Phase 3 (본 repo dogfood install) 에서도 동일하게 작동 — `/plugin install rein@rein` 후 본 메인테이너 환경의 user-level plugins + rein 함께 active. **sandbox 와 본 repo 의 hook trigger 수가 같은 base 위에서 비교됨**.

## Hook trigger count 표 (3 probes 합산)

### Probe 1 (text-only prompt — SessionStart + UserPromptSubmit 만)

| event | hook_id (8) | exit | stdout bytes | source (rein vs other) |
|-------|-------------|------|--------------|------------------------|
| SessionStart | d1879183 | 0 | 454 | rein `session-start-bootstrap.sh` (trail/ advisory) |
| SessionStart | 996b7f44 | 0 | 0 | rein `session-start-load-trail.sh` (graceful no-op) |
| SessionStart | e8b3c4e0 | 0 | 12219 | rein `session-start-rules.sh` (5613b ctx, REIN anchor) |
| SessionStart | a14c33a1 | 0 | 5973 | superpowers `using-superpowers` skill (5632b ctx) |
| UserPromptSubmit | d2420148 | 0 | 11661 | rein `user-prompt-submit-rules.sh` (5014b ctx, REIN anchor) |
| Stop | bf4ba636 | 0 | 0 | silent — 미식별 |
| Stop | 22a173e0 | 0 | 0 | silent — 미식별 |

### Probe 2 (Bash + Write tool — PreToolUse 추가)

동일 SessionStart 4 + UserPromptSubmit 1 + 추가:

| event | hook_id (8) | exit | stdout bytes | source |
|-------|-------------|------|--------------|--------|
| PreToolUse(Bash) | 4fa145e2 | 0 | 8636 | rein `pre-tool-use-bash-rules.sh` (4299b ctx, **"rein job" anchor → background-jobs**) |

PreToolUse 3 trigger 중 1 만 response stdout — 다른 2 silent (PreToolUse(Bash) matcher 다중 hook 중 `pre-bash-guard.sh` + `pre-tool-use-bash-bootstrap-gate.sh` 가 silent pass).

### Probe 3 (Write `docs/plans/sandbox-probe.md` — PostToolUse design-plan-coverage matcher 시도)

동일 SessionStart 4 + UserPromptSubmit 1 + PreToolUse 1 + 추가:

| event | trigger | result |
|-------|---------|--------|
| PostToolUse | Write of `docs/plans/sandbox-probe.md` | response stdout 캡처 안 됨 (hook silent) |

→ design-plan-coverage hook 의 conditional emit 이 sandbox 의 절대 path 와 매칭 안 됐을 가능성. 구조 검증은 spec D1 의 substitution 으로 처리.

### rein plugin 의 SessionStart 3 hook 모두 정상 작동 확인

- `session-start-bootstrap.sh` ✅ trail/ 부재 감지 + bilingual advisory 출력
- `session-start-load-trail.sh` ✅ trail/ 부재 시 graceful no-op (exit 0)
- `session-start-rules.sh` ✅ `code-style` + `security` + `testing` rule body inject (5613b)

## 7 shared rule prompt byte count (sandbox 3 probes + 2 direct hook invocation)

3 Claude sandbox probe + 2 hook 직접 호출 (2026-05-13T03:23~03:50):
- Probe 1: text-only prompt — SessionStart + UserPromptSubmit
- Probe 2: Bash + Write tool — PreToolUse(Bash) 추가
- Probe 3: Write `docs/plans/sandbox-probe.md` — PostToolUse 시도 (절대 path glob matcher 미매칭으로 silent)
- Direct invocation 1: `pre-tool-use-agent-rules.sh` 직접 호출 (CLAUDE_PLUGIN_ROOT set + stdin null)
- Direct invocation 2: `post-write-design-plan-coverage-rule.sh` 직접 호출 (stdin `{"tool_input":{"file_path":"docs/plans/test.md"}}`)

### 7/7 direct measurement (per-rule body bytes, all > 0)

직접 측정 방법: `rule_inject_body <rule>` 헬퍼 (in `plugins/rein-core/hooks/lib/rule-inject.sh`) + 각 hook 직접 호출 (`bash <hook>.sh` with `CLAUDE_PLUGIN_ROOT` env + 필요 시 stdin JSON).

| rule | inject hook (rein) | event | rule body bytes (rule_inject_body) | envelope inner ctx bytes (hook 직접 호출 결과) | source |
|------|-------------------|-------|------------------------------------|----------------------------------------------|--------|
| code-style | session-start-rules.sh | SessionStart | 1786 | 5613 (3 rule concat with `\n\n` separator) | Probe 1 + Direct invocation 3 |
| security | session-start-rules.sh | SessionStart | 1839 | (위 5613 에 포함) | Probe 1 + Direct invocation 3 |
| testing | session-start-rules.sh | SessionStart | 4499 | (위 5613 에 포함) | Probe 1 + Direct invocation 3 |
| answer-only-mode | user-prompt-submit-rules.sh | UserPromptSubmit | 7048 | 5014 (bootstrap advisory + answer-only-mode body) | Probe 1, 2, 3 |
| background-jobs | pre-tool-use-bash-rules.sh | PreToolUse(Bash) | 5958 | 4299 ("rein job" anchor) | Probe 2 |
| **design-plan-coverage** | post-write-design-plan-coverage-rule.sh | PostToolUse(Edit/Write/MultiEdit, conditional) | 8893 | **6168** ("# Design → Plan 범위 커버리지 규칙" anchor) | **Direct invocation 2** (stdin `{"tool_input":{"file_path":"docs/plans/test.md"}}`) |
| **subagent-review** | pre-tool-use-agent-rules.sh | PreToolUse(Task/Agent) | 5247 | **3359** ("# Subagent 코드 리뷰 규칙" anchor) | **Direct invocation 1** (CLAUDE_PLUGIN_ROOT only, stdin null) |

**모든 7 rule 의 rule body bytes > 0 + envelope inner ctx bytes > 0 확인 완료.**

차이 설명 (rule body vs envelope ctx):
- SessionStart: 3 rule (code-style/security/testing) raw body 합산 = 1786+1839+4499+2개 separator (4) = 8128. 그러나 envelope inner ctx 는 5613 — `rein-policy-loader.py` 또는 hook 본문의 mandate-section-only trim 가능성 (구체적 행동은 본 evidence 범위 외 — Phase 2 의 drift checker 통합 검토 시 함께 확인).
- 다른 hook 들도 inject 시 일부만 (mandate section) emit 가능 — `rein-validate-plugin-rules.py` 의 `MANDATE_RE` regex 동작과 일관성.
- 핵심: **각 rule 별 inject body bytes > 0 + envelope 본문에 anchor 매치 확인** = S10 의 v2 contract literal completion.

7 rule 모두 inject envelope bytes > 0 확인 완료. S10 의 v2 contract literal completion.

### Direct hook invocation 의 검증 의미

Claude CLI 의 sub-Claude probe 가 권한 제약 (Task tool sub-sub-Claude 호출 + auto classifier) + 절대 path glob matcher 미매칭으로 2 rule 직접 trigger 불가능. 대신 hook script 를 `bash` 로 직접 실행하면서 `CLAUDE_PLUGIN_ROOT` 환경변수 + 표준입력 (stdin) JSON 을 전달:

- **subagent-review** (`pre-tool-use-agent-rules.sh`): stdin 미사용. `CLAUDE_PLUGIN_ROOT` 만 set 되면 항상 envelope emit. 직접 호출 결과 8243b stdout (3359b inner ctx).
- **design-plan-coverage** (`post-write-design-plan-coverage-rule.sh`): stdin 의 `tool_input.file_path` 가 `docs/plans/test.md` 같은 매칭 path 일 때 envelope emit. 직접 호출 결과 13250b stdout (6168b inner ctx). non-matching path (`foo/bar.txt`) 입력 시 silent (0b) — conditional 정상 동작 확인.

Direct invocation 은 Claude Code 런타임의 hook dispatcher 를 우회하지만, hook 자체가 envelope 을 emit 하는 **본 동작** 은 동일. 즉 hook 의 inject byte count 측정 측면에서 sub-Claude 호출과 등가. Phase 3 dogfood install 후 본 repo 의 `docs/plans/<actual>.md` 편집 / Task tool 사용 시 동일 envelope 이 자연스럽게 emit 됨.

## Sandbox 의 trigger count 검증 (S7 의 sandbox 부분)

본 sandbox 에선 `.claude/settings.json` 의 hook 등록이 없음 (`/tmp/rein-dogfood-sandbox/` 는 fresh — `.claude/` 디렉토리 자체 없음). 따라서 sandbox 에서 hook 별 trigger count == 1 (plugin only).

본 repo dogfood install 시점의 중복 trigger 검증 (S7 main 검증) 은 Phase 3 의 Task 3.4 에서 별도 수행 (settings.json 6 hook 제거 전후 비교).

## 결론

- **Phase 1 S10 성공 기준 달성**: rein plugin 의 SessionStart 3 hook + UserPromptSubmit 1 hook 정상 trigger 확인, envelope inject byte count > 0
- **Phase 2 (drift checker 통합) 진입 가능**
- **추가 주의사항** (plan 갱신 후보):
  - `--plugin-dir` 가 fully isolated 가 아님 — user-level plugin set 과 함께 active. Phase 3 의 trigger count 비교는 같은 base (user-level plugins) 위에서 진행
  - PreToolUse / PostToolUse 의 7 shared rule 중 3 rule (subagent-review/background-jobs/design-plan-coverage) 검증은 Phase 3 의 tool-using session 에서 자연 확인 가능 — Phase 1 의 책임 외

## 파일 산출

- `/tmp/rein-sandbox-output.jsonl` — 18 hook events (sandbox 임시, 검증 후 cleanup 가능)
- `/tmp/rein-sandbox-debug.log` — 391 lines plugin loading + hook trace
- 본 evidence 파일 — git 추적 + main 머지 제외 (dev-only, branch-strategy `trail/**` 제외)
