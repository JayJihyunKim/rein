---
name: codex
description: Use when the user asks to run Codex CLI (codex exec, codex resume) or references OpenAI Codex for code analysis, refactoring, or automated editing
---

# Codex Skill Guide

## 리뷰 실행 순서 (Codex 우선 + Sonnet 폴백)

코드 리뷰 시 반드시 아래 순서를 따른다:

1. **Codex 리뷰 실행** — 아래 "Running a Task" 절차에 따라 codex exec로 리뷰 실행
2. **성공 시** — stamp 생성 후 종료
3. **실패 시 (에러/타임아웃)** — sonnet 폴백 리뷰 실행 (reviewer agent, model: sonnet)
4. **폴백 성공 시** — stamp에 fallback_reason 기록 후 종료
5. **폴백도 실패 시** — 작업 중단, 사용자에게 보고

**중요**: "codex 리뷰 결과가 부족해서" 등은 폴백 사유가 아님. 에러/타임아웃만 폴백 허용.

## 리뷰 에스컬레이션 규칙

리뷰 결과에 따라 다음 행동을 결정한다:

| 리뷰 결과 | 수정 규모 | 다음 행동 |
|-----------|----------|----------|
| High 이슈 있음 | 무관 | 수정 후 **codex 재리뷰** |
| Medium만 있음 | > 3줄 | 수정 후 **codex 재리뷰** |
| Medium만 있음 | ≤ 3줄 | 수정 후 **sonnet 셀프리뷰** |
| Low만 있음 | 무관 | 수정 후 **sonnet 셀프리뷰** |
| 이슈 없음 | — | **통과** (stamp 생성) |
| 3회차에도 High | — | **사람에게 에스컬레이션** |

**sonnet 셀프리뷰**: 변경 diff를 직접 확인하고, stamp에 `reviewer: self-review` 기록.

## Stamp 생성

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

stamp 생성 후 .review-pending이 있으면 삭제한다:
```bash
rm -f trail/dod/.review-pending
```

## Running a Task
1. Ask the user (via `AskUserQuestion`) which model to run: `gpt-5.4` (default, config.toml 기본값) or `gpt-5.3-codex`.
2. Ask the user (via `AskUserQuestion`) which reasoning effort to use: `low`, `medium`, or `high`.
3. Select the sandbox mode required for the task; default to `--sandbox read-only` unless edits or network access are necessary.
4. Assemble the command with the appropriate options:
   - `-m, --model <MODEL>`
   - `--config model_reasoning_effort="<low|medium|high>"`
   - `--sandbox <read-only|workspace-write|danger-full-access>`
   - `--full-auto`
   - `-C, --cd <DIR>`
   - `--skip-git-repo-check`
5. When continuing a previous session, use `codex exec resume --last` via stdin. **IMPORTANT**: When resuming, you CANNOT specify model, reasoning effort, or other flags—the session retains all settings from the original run. Resume syntax: `echo "your prompt here" | codex exec resume --last`
6. Run the command, capture stdout/stderr, and summarize the outcome for the user.

### Quick Reference
| Use case | Sandbox mode | Key flags |
| --- | --- | --- |
| Read-only review or analysis | `read-only` | `--sandbox read-only` |
| Apply local edits | `workspace-write` | `--sandbox workspace-write --full-auto` |
| Permit network or broad access | `danger-full-access` | `--sandbox danger-full-access --full-auto` |
| Resume recent session | Inherited from original | `echo "prompt" \| codex exec resume --last` (no flags allowed) |
| Run from another directory | Match task needs | `-C <DIR>` plus other flags |

## Following Up
- After every `codex` command, immediately use `AskUserQuestion` to confirm next steps, collect clarifications, or decide whether to resume with `codex exec resume --last`.
- When resuming, pipe the new prompt via stdin: `echo "new prompt" | codex exec resume --last`. The resumed session automatically uses the same model, reasoning effort, and sandbox mode from the original session.
- Restate the chosen model, reasoning effort, and sandbox mode when proposing follow-up actions.

## Error Handling
- Stop and report failures whenever `codex --version` or a `codex exec` command exits non-zero; request direction before retrying.
- Before you use high-impact flags (`--full-auto`, `--sandbox danger-full-access`, `--skip-git-repo-check`) ask the user for permission using AskUserQuestion unless it was already given.
- When output includes warnings or partial results, summarize them and ask how to adjust using `AskUserQuestion`.
- **Codex 실패 시**: 에러 메시지를 기록하고 sonnet 폴백 리뷰를 실행한다. 폴백 결과를 stamp에 기록한다.
