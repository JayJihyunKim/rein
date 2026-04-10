# Codex 리뷰 강제 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** sub-agent 포함 모든 코드 수정에 codex 리뷰를 하드 강제하고, codex 실패 시에만 sonnet 폴백을 허용하는 이중 게이트 구현

**Architecture:** PostToolUse hook으로 코드 편집을 추적(.review-pending)하고, PreToolUse(Bash) hook으로 테스트/커밋 시 codex stamp 유효성을 검증하여 차단. codex 스킬에 폴백 체인과 메타데이터 stamp 기록 추가.

**Tech Stack:** Bash (hooks), Markdown (스킬/에이전트/워크플로우 정의), JSON (settings.json)

---

### Task 1: post-edit-review-gate.sh 생성

**Files:**
- Create: `.claude/hooks/post-edit-review-gate.sh`

- [ ] **Step 1: hook 스크립트 작성**

```bash
#!/bin/bash
# Hook: PostToolUse(Edit/Write/MultiEdit) - 소스 코드 편집 시 리뷰 대기 상태 추적
#
# 소스 코드 파일 편집 시 SOT/dod/.review-pending 생성
# SOT/, docs/, .md 파일은 제외 (규칙/문서 파일)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_PENDING="$PROJECT_DIR/SOT/dod/.review-pending"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tr = d.get('tool_result', {})
# Edit/Write는 file_path, MultiEdit는 첫 번째 파일
if 'file_path' in tr:
    print(tr['file_path'])
elif 'edits' in tr and len(tr['edits']) > 0:
    print(tr['edits'][0].get('file_path', ''))
else:
    ti = d.get('tool_input', {})
    print(ti.get('file_path', ''))
" 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# 제외 경로: SOT/, docs/, *.md 파일
case "$FILE_PATH" in
  */SOT/*|*/docs/*|*.md)
    exit 0
    ;;
esac

# 소스 코드 확장자 확인
SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|py|sh|yml|yaml|json|toml|css|scss|html)$'
if ! echo "$FILE_PATH" | grep -qE "$SOURCE_EXT_PATTERN"; then
  exit 0
fi

# .review-pending 생성 (이미 있으면 타임스탬프만 갱신)
mkdir -p "$(dirname "$REVIEW_PENDING")"
touch "$REVIEW_PENDING"

exit 0
```

- [ ] **Step 2: 실행 권한 부여**

Run: `chmod +x .claude/hooks/post-edit-review-gate.sh`

- [ ] **Step 3: 커밋**

```bash
git add .claude/hooks/post-edit-review-gate.sh
git commit -m "feat: post-edit-review-gate hook 생성 — 소스 코드 편집 시 .review-pending 추적"
```

---

### Task 2: pre-bash-guard.sh에 .review-pending 검증 추가

**Files:**
- Modify: `.claude/hooks/pre-bash-guard.sh:46-99` (check_review_stamp 함수)

- [ ] **Step 1: check_review_stamp 함수에 .review-pending 검증 로직 추가**

`check_review_stamp` 함수의 시작 부분(DoD 존재 검사 후, Codex stamp 검사 전)에 아래 로직을 삽입:

```bash
  # --- .review-pending 검증 (코드 편집 후 리뷰 필수) ---
  REVIEW_PENDING="$PROJECT_DIR/SOT/dod/.review-pending"
  if [ -f "$REVIEW_PENDING" ]; then
    if [ ! -f "$REVIEW_STAMP" ]; then
      echo "BLOCKED: 코드 변경 후 codex 리뷰가 실행되지 않았습니다." >&2
      echo "/codex 스킬로 코드 리뷰를 실행하세요." >&2
      log_block "코드 편집 후 리뷰 미실행 (${context})" "$COMMAND"
      return 1
    fi

    # .codex-reviewed가 .review-pending보다 최신인지 검증
    PENDING_TIME=$(stat -f %m "$REVIEW_PENDING" 2>/dev/null || stat -c %Y "$REVIEW_PENDING" 2>/dev/null || echo 0)
    REVIEW_TIME=$(stat -f %m "$REVIEW_STAMP" 2>/dev/null || stat -c %Y "$REVIEW_STAMP" 2>/dev/null || echo 0)
    if [ "$REVIEW_TIME" -lt "$PENDING_TIME" ]; then
      echo "BLOCKED: 리뷰 이후 코드가 다시 수정되었습니다. codex 리뷰를 재실행하세요." >&2
      log_block "리뷰 후 코드 재수정 (${context})" "$COMMAND"
      return 1
    fi
  fi
```

이 코드를 `check_review_stamp()` 함수 내부에서 `[ "$DOD_EXISTS" = false ] && return 0` 직후, `# --- Codex 리뷰 stamp 검사 ---` 직전에 삽입.

- [ ] **Step 2: 동작 확인**

Run: `bash -n .claude/hooks/pre-bash-guard.sh`
Expected: 문법 에러 없이 종료 (exit 0)

- [ ] **Step 3: 커밋**

```bash
git add .claude/hooks/pre-bash-guard.sh
git commit -m "feat: pre-bash-guard에 .review-pending 시간 비교 검증 추가"
```

---

### Task 3: settings.json에 post-edit-review-gate hook 등록

**Files:**
- Modify: `.claude/settings.json:83-93` (PostToolUse 섹션)

- [ ] **Step 1: PostToolUse에 post-edit-review-gate.sh 추가**

현재 PostToolUse 섹션:
```json
"PostToolUse": [
  {
    "matcher": "Edit|Write|MultiEdit",
    "hooks": [
      {
        "type": "command",
        "command": ".claude/hooks/post-edit-lint.sh"
      }
    ]
  }
]
```

변경 후:
```json
"PostToolUse": [
  {
    "matcher": "Edit|Write|MultiEdit",
    "hooks": [
      {
        "type": "command",
        "command": ".claude/hooks/post-edit-lint.sh"
      },
      {
        "type": "command",
        "command": ".claude/hooks/post-edit-review-gate.sh"
      }
    ]
  }
]
```

- [ ] **Step 2: JSON 유효성 확인**

Run: `python3 -c "import json; json.load(open('.claude/settings.json'))"`
Expected: 에러 없이 종료

- [ ] **Step 3: 커밋**

```bash
git add .claude/settings.json
git commit -m "feat: settings.json에 post-edit-review-gate hook 등록"
```

---

### Task 4: codex 스킬에 폴백 로직 + stamp 메타데이터 추가

**Files:**
- Modify: `.claude/skills/codex/SKILL.md`

- [ ] **Step 1: SKILL.md 전체 교체**

```markdown
---
name: codex
description: Use when the user asks to run Codex CLI (codex exec, codex resume) or references OpenAI Codex for code analysis, refactoring, or automated editing
---

# Codex Skill Guide

## 리뷰 실행 순서 (Codex 우선 + Sonnet 폴백)

코드 리뷰 시 반드시 아래 순서를 따른다:

1. **Codex 리뷰 실행** — 아래 "Running a Task" 절차에 따라 codex exec로 리뷰 실행
2. **성공 시** — stamp 생성 후 종료
3. **실패 시 (에러/타임아웃)** — sonnet 폴백 리뷰 실행 (code-reviewer agent, model: sonnet)
4. **폴백 성공 시** — stamp에 fallback_reason 기록 후 종료
5. **폴백도 실패 시** — 작업 중단, 사용자에게 보고

**중요**: "codex 리뷰 결과가 부족해서" 등은 폴백 사유가 아님. 에러/타임아웃만 폴백 허용.

## Stamp 생성

리뷰 완료 후 반드시 stamp 파일을 생성한다:

```bash
cat > SOT/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: [변경 파일 수]
STAMP
```

Sonnet 폴백 시:
```bash
cat > SOT/dod/.codex-reviewed << STAMP
reviewer: sonnet-fallback
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: codex_timeout
files_reviewed: [변경 파일 수]
STAMP
```

stamp 생성 후 .review-pending이 있으면 삭제한다:
```bash
rm -f SOT/dod/.review-pending
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
```

- [ ] **Step 2: 커밋**

```bash
git add .claude/skills/codex/SKILL.md
git commit -m "feat: codex 스킬에 sonnet 폴백 체인 + stamp 메타데이터 추가"
```

---

### Task 5: AGENTS.md에 코드 리뷰 필수 규칙 추가

**Files:**
- Modify: `AGENTS.md` (§5 완료 기준 직후에 삽입)

- [ ] **Step 1: §5 DoD 항목 아래에 리뷰 규칙 섹션 추가**

`## 6. Self-review 기준` 직전에 아래를 삽입:

```markdown
## 5-1. 코드 리뷰 필수 규칙 (sub-agent 포함)

- 소스 코드(.ts, .py, .sh, .json 등)를 수정한 **모든 에이전트(sub-agent 포함)**는 작업 완료 전 반드시 codex 리뷰를 실행한다
- codex 리뷰: `/codex` 스킬 호출 → `SOT/dod/.codex-reviewed` stamp 생성
- codex 실패(에러/타임아웃) 시에만 sonnet 폴백 허용 — 그 외 사유로 sonnet 리뷰 대체 금지
- sonnet 폴백 시 stamp에 `fallback_reason` 기록 필수
- 리뷰 없이 결과를 반환하거나 테스트/커밋 시도 시 hook이 차단함 (exit 2)
- 리뷰 후 추가 코드 수정 시 `.review-pending` 재생성 → 재리뷰 필수
```

- [ ] **Step 2: 커밋**

```bash
git add AGENTS.md
git commit -m "docs: AGENTS.md에 코드 리뷰 필수 규칙 추가 (sub-agent 포함)"
```

---

### Task 6: feature-builder.md, service-builder.md 완료 기준 추가

**Files:**
- Modify: `.claude/agents/feature-builder.md:37-46` (완료 기준)
- Modify: `.claude/agents/service-builder.md:35-43` (완료 기준)

- [ ] **Step 1: feature-builder.md 완료 기준 수정**

현재:
```
## 완료 기준
```
[ ] DoD 항목 전체 충족
[ ] 기존 테스트 100% 통과
[ ] 신규 기능에 테스트 추가됨
[ ] lint/format 통과
[ ] Self-review 완료
[ ] 빠뜨린 규칙 → SOT/incidents/ 초안 작성
```
```

변경:
```
## 완료 기준
```
[ ] DoD 항목 전체 충족
[ ] codex 리뷰 실행 완료 (.codex-reviewed stamp 존재)
[ ] 리뷰 후 추가 수정 시 재리뷰 완료
[ ] 기존 테스트 100% 통과
[ ] 신규 기능에 테스트 추가됨
[ ] lint/format 통과
[ ] Self-review 완료
[ ] 빠뜨린 규칙 → SOT/incidents/ 초안 작성
```
```

- [ ] **Step 2: service-builder.md 완료 기준 수정**

현재:
```
## 완료 기준
```
[ ] build-from-scratch workflow DoD 전체 충족
[ ] 서비스가 실제 실행됨
[ ] 기본 테스트 통과
[ ] 하위 AGENTS.md 작성됨
[ ] SOT/decisions/DEC-NNN.md 기술 결정 기록됨
[ ] SOT/index.md 갱신됨
```
```

변경:
```
## 완료 기준
```
[ ] build-from-scratch workflow DoD 전체 충족
[ ] codex 리뷰 실행 완료 (.codex-reviewed stamp 존재)
[ ] 리뷰 후 추가 수정 시 재리뷰 완료
[ ] 서비스가 실제 실행됨
[ ] 기본 테스트 통과
[ ] 하위 AGENTS.md 작성됨
[ ] SOT/decisions/DEC-NNN.md 기술 결정 기록됨
[ ] SOT/index.md 갱신됨
```
```

- [ ] **Step 3: 커밋**

```bash
git add .claude/agents/feature-builder.md .claude/agents/service-builder.md
git commit -m "docs: feature-builder, service-builder 완료 기준에 codex 리뷰 추가"
```

---

### Task 7: add-feature.md 워크플로우 리뷰 단계 강화

**Files:**
- Modify: `.claude/workflows/add-feature.md:39-44` (Step 5)

- [ ] **Step 1: Step 5를 codex 우선 + sonnet 폴백으로 교체**

현재:
```markdown
### Step 5: Codex 코드 리뷰
```
[ ] /codex 스킬로 변경된 파일에 대해 리뷰 실행
[ ] 리뷰 결과의 수정사항 반영
[ ] 수정 후 테스트 재실행
```
```

변경:
```markdown
### Step 5: Codex 코드 리뷰 (필수 — codex 우선, sonnet 폴백)
```
[ ] /codex 스킬로 변경된 파일에 대해 리뷰 실행
[ ] codex 실패(에러/타임아웃) 시에만 sonnet 폴백 리뷰 실행
[ ] 리뷰 결과의 수정사항 반영
[ ] 수정사항 반영 후 .review-pending 재생성 시 재리뷰 실행
[ ] stamp(SOT/dod/.codex-reviewed)에 reviewer, fallback_reason 기록 확인
[ ] .review-pending 삭제 확인
```
```

- [ ] **Step 2: 커밋**

```bash
git add .claude/workflows/add-feature.md
git commit -m "docs: add-feature 워크플로우에 codex 우선 + sonnet 폴백 절차 명시"
```

---

### Task 8: 통합 테스트

**Files:**
- 변경 없음 (검증만)

- [ ] **Step 1: hook 문법 검증**

Run: `bash -n .claude/hooks/post-edit-review-gate.sh && bash -n .claude/hooks/pre-bash-guard.sh && echo "OK"`
Expected: `OK`

- [ ] **Step 2: settings.json 유효성 검증**

Run: `python3 -c "import json; json.load(open('.claude/settings.json')); print('OK')"`
Expected: `OK`

- [ ] **Step 3: .review-pending 생성 시뮬레이션**

Run: `touch SOT/dod/.review-pending && ls -la SOT/dod/.review-pending`
Expected: 파일 존재 확인

- [ ] **Step 4: .review-pending 있고 .codex-reviewed 없을 때 차단 테스트**

Run: `rm -f SOT/dod/.codex-reviewed && echo '{"tool_input":{"command":"pytest"}}' | bash .claude/hooks/pre-bash-guard.sh 2>&1; echo "exit: $?"`
Expected: `BLOCKED: 코드 변경 후 codex 리뷰가 실행되지 않았습니다.` + `exit: 2`

- [ ] **Step 5: .codex-reviewed가 .review-pending보다 최신일 때 통과 테스트**

Run:
```bash
touch SOT/dod/.review-pending && sleep 1 && touch SOT/dod/dod-test.md && cat > SOT/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: 1
STAMP
echo '{"tool_input":{"command":"pytest"}}' | bash .claude/hooks/pre-bash-guard.sh 2>&1; echo "exit: $?"
```
Expected: exit 0 (통과)

- [ ] **Step 6: .review-pending이 .codex-reviewed보다 최신일 때 차단 테스트**

Run:
```bash
cat > SOT/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
fallback_reason: none
files_reviewed: 1
STAMP
sleep 1 && touch SOT/dod/.review-pending
echo '{"tool_input":{"command":"pytest"}}' | bash .claude/hooks/pre-bash-guard.sh 2>&1; echo "exit: $?"
```
Expected: `BLOCKED: 리뷰 이후 코드가 다시 수정되었습니다.` + `exit: 2`

- [ ] **Step 7: 테스트 정리**

Run: `rm -f SOT/dod/.review-pending SOT/dod/.codex-reviewed SOT/dod/dod-test.md`

- [ ] **Step 8: 커밋**

```bash
git add -A && git commit -m "chore: codex 리뷰 강제 구현 완료 — 통합 테스트 통과"
```
