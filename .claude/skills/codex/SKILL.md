---
name: codex
description: "Codex CLI (codex exec / codex exec resume) 를 두 모드로 제공한다. /codex review — 코드 리뷰 전용 (stamp 생성, severity escalation, Sonnet fallback, 동일 사이클 내 resume 허용). /codex ask — second opinion 전용 (stamp 없음, resume --last 금지 — 매번 새 세션으로 독립 관점 확보). 하위 커맨드 없이 /codex 만 호출하면 backward compat 로 /codex review 로 해석한다. Mode B 는 brainstorm 반박·spec sanity·refactor tradeoff 이중 검증에 사용."
---

# Codex Skill Guide

이 스킬은 Codex CLI 를 두 가지 모드로 노출한다. 모드는 호출 시 하위 커맨드로 선택한다.

| 모드 | 호출 | 목적 | stamp | resume --last | context |
|------|------|------|-------|---------------|---------|
| **Mode A** | `/codex review` | 코드 리뷰 (rein 리뷰 게이트) | **생성** | 같은 리뷰 사이클 내 재리뷰 허용 | 세션 유지 |
| **Mode B** | `/codex ask` | Second opinion (brainstorm 반박, spec sanity, refactor tradeoff) | **없음** | **금지** | 항상 새 세션 |

**하위 커맨드 없이 `/codex` 만 호출하면 Mode A 로 해석한다** (backward compat).

---

## Mode A: `/codex review` — 코드 리뷰

### 리뷰 실행 순서 (Codex 우선 + Sonnet 폴백)

1. **Codex 리뷰 실행** — 아래 "Running a Task" 절차에 따라 `codex exec` 로 실행
2. **성공 시** — stamp 생성 후 종료
3. **실패 시 (에러/타임아웃)** — sonnet 폴백 리뷰 실행 (`code-reviewer` 스킬 또는 `general-purpose` 에이전트, model: sonnet)
4. **폴백 성공 시** — stamp 에 `fallback_reason` 기록 후 종료
5. **폴백도 실패 시** — 작업 중단, 사용자에게 보고

**중요**: "codex 리뷰 결과가 부족해서" 등은 폴백 사유가 아님. 에러/타임아웃만 폴백 허용.

### 리뷰 에스컬레이션 규칙

| 리뷰 결과 | 수정 규모 | 다음 행동 |
|-----------|----------|----------|
| High 이슈 있음 | 무관 | 수정 후 **codex 재리뷰** |
| Medium만 있음 | > 3줄 | 수정 후 **codex 재리뷰** |
| Medium만 있음 | ≤ 3줄 | 수정 후 **sonnet 셀프리뷰** |
| Low만 있음 | 무관 | 수정 후 **sonnet 셀프리뷰** |
| 이슈 없음 | — | **통과** (stamp 생성) |
| 3회차에도 High | — | **사람에게 에스컬레이션** |

**sonnet 셀프리뷰**: 변경 diff 를 직접 확인하고, stamp 에 `reviewer: self-review` 기록.

### Stamp 생성 (Mode A 필수)

리뷰 완료 후 반드시 stamp 파일을 생성한다:

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
resolution: passed
remaining_issues: none
STAMP
```

Sonnet 폴백 시:

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: sonnet-fallback
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: codex_timeout
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
resolution: passed
remaining_issues: none
STAMP
```

Sonnet 셀프리뷰 시:

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: self-review
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
resolution: passed
remaining_issues: none
prior_reviewer: codex
prior_max_severity: [medium 또는 low]
STAMP
```

사람 에스컬레이션 시:

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: [변경 파일 수]
review_round: 3
resolution: escalated_to_human
remaining_issues: [잔존 이슈 요약]
STAMP
```

stamp 생성 후 `.review-pending` 이 있으면 삭제한다:

```bash
rm -f trail/dod/.review-pending
```

### Resume 정책 (Mode A)

같은 리뷰 사이클 내 재리뷰 (fix 후 재검토) 는 `codex exec resume --last` 허용. 세션 컨텍스트가 같은 변경분을 다루므로 자연스럽다.

---

## Mode B: `/codex ask` — Second Opinion

### 용도

- brainstorming 결론에 대한 sanity check ("Option B 기각이 진짜 맞나?")
- spec 의 설계 결정이 의심스러울 때 ("이 접근이 over-engineering 은 아닌가?")
- refactor tradeoff 이중 검증
- Claude 세션 컨텍스트에 오염되지 않은 **독립 관점** 이 필요한 모든 경우

### 원칙 (Mode A 와 다른 점)

- **stamp 생성 없음** — 리뷰 게이트 아님. `.codex-reviewed` 등 파일을 만들지 않는다.
- **`resume --last` 금지** — 이전 세션 컨텍스트가 독립 관점을 오염시키므로, 매 호출마다 **새 `codex exec` 세션** 을 띄운다.
- `--sandbox read-only` 기본. 파일 편집 권한 없음.
- 출력은 Claude 주 컨텍스트에 반영. Claude 는 사용자에게 summary + 필요 시 의사결정 질문.

### 실행 순서

1. 사용자 의도 확인 — 무엇에 대한 second opinion 인지, 어떤 관점을 원하는지
2. AskUserQuestion 으로 모델(`gpt-5.4` / `gpt-5.3-codex`) 과 reasoning effort 선택
3. `codex exec -m <model> --config model_reasoning_effort="<effort>" --sandbox read-only --full-auto -C <workdir>` 로 **새 세션** 실행 (resume 금지)
4. 출력을 사용자에게 요약 보고
5. 필요 시 추가 질의는 **또 다른 새 세션** 으로 시작 (resume 사용 안 함)

### 호출 예시

- `/codex ask` "이 spec 의 X 결정이 실제로 맞는지 독립 관점으로 반박해줘"
- `/codex ask` "brainstorm 에서 기각된 option B 가 진짜 기각돼야 하는지 재검토해줘"
- `/codex ask` "이 refactor 가 over-engineering 인지 판단해줘"

### Stamp 금지

Mode B 는 리뷰 게이트가 아니다. `trail/dod/.codex-reviewed` 같은 stamp 파일을 **절대 만들지 않는다**. 실수로 Mode B 결과로 stamp 를 생성하면 리뷰 없이 테스트/커밋이 통과되어 게이트가 무력화된다.

---

## 하위 호환 (backward compat)

- `/codex` (하위 커맨드 없음) → Mode A 로 해석
- `/codex review` → Mode A (명시적)
- `/codex ask` → Mode B
- 기존 문서/AGENTS.md 의 `/codex` 언급은 점진적으로 `/codex review` 또는 `/codex ask` 로 명시화

---

## Running a Task (공통)

1. Ask the user (via `AskUserQuestion`) which model to run: `gpt-5.4` (default, config.toml 기본값) or `gpt-5.3-codex`.
2. Ask the user (via `AskUserQuestion`) which reasoning effort to use: `low`, `medium`, or `high`.
3. Select the sandbox mode required for the task; default to `--sandbox read-only` unless edits or network access are necessary. **Mode B 는 항상 read-only**.
4. Assemble the command with the appropriate options:
   - `-m, --model <MODEL>`
   - `--config model_reasoning_effort="<low|medium|high>"`
   - `--sandbox <read-only|workspace-write|danger-full-access>`
   - `--full-auto`
   - `-C, --cd <DIR>`
   - `--skip-git-repo-check`
5. **Resume 규칙 (Mode 에 따라 다름)**:
   - Mode A (`/codex review`): 같은 리뷰 사이클 내 재리뷰는 `echo "new prompt" | codex exec resume --last` 허용
   - Mode B (`/codex ask`): **resume 금지**. 매번 새 `codex exec` 세션
6. Run the command, capture stdout/stderr, and summarize the outcome for the user.

### Quick Reference

| Use case | Sandbox mode | Mode | Key flags |
| --- | --- | --- | --- |
| 코드 리뷰 (초회) | `read-only` | A | `--sandbox read-only` |
| 코드 리뷰 (fix 후 재리뷰) | inherited | A | `echo "..." \| codex exec resume --last` |
| Second opinion | `read-only` | B | `--sandbox read-only`, **resume 금지** |
| 로컬 편집 (드문 경우) | `workspace-write` | A | `--sandbox workspace-write --full-auto` |
| 다른 디렉토리에서 실행 | task needs | A/B | `-C <DIR>` 추가 |

---

## Following Up

- After every `codex` command, immediately use `AskUserQuestion` to confirm next steps, collect clarifications, or decide whether to resume (Mode A 만) or start a new session (Mode B).
- When resuming (Mode A 에만 해당), pipe the new prompt via stdin: `echo "new prompt" | codex exec resume --last`. The resumed session automatically uses the same model, reasoning effort, and sandbox mode from the original session.
- Restate the chosen model, reasoning effort, and sandbox mode when proposing follow-up actions.

## Error Handling

- Stop and report failures whenever `codex --version` or a `codex exec` command exits non-zero; request direction before retrying.
- Before you use high-impact flags (`--full-auto`, `--sandbox danger-full-access`, `--skip-git-repo-check`) ask the user for permission using AskUserQuestion unless it was already given.
- When output includes warnings or partial results, summarize them and ask how to adjust using `AskUserQuestion`.
- **Codex 실패 시 (Mode A)**: 에러 메시지를 기록하고 sonnet 폴백 리뷰를 실행한다. 폴백 결과를 stamp 에 기록한다.
- **Codex 실패 시 (Mode B)**: 폴백 없음. 사용자에게 보고하고 재시도 여부를 물어본다 (Mode B 는 리뷰 게이트 아니므로 실패해도 작업 차단 없음).
