---
name: codex-review
description: "Codex CLI 코드 리뷰 모드. stamp 생성, severity escalation, Sonnet fallback, 동일 사이클 resume --last 허용. rein 의 리뷰 게이트(`trail/dod/.codex-reviewed`) 를 생성하는 유일한 스킬."
---

# Codex Review Skill (Mode A)

## 1. 목적

코드 리뷰 전용 — rein 의 리뷰 게이트 생성 스킬. `/codex-review` 슬래시 명령으로 호출한다.

이 스킬은 **리뷰 gate** 다. 실행 결과로 `trail/dod/.codex-reviewed` stamp 를 생성하며, 이 stamp 가 있어야만 `pre-bash-guard.sh` 가 `git commit` / `pytest` 를 허용한다.

Second opinion (brainstorm 반박, spec sanity, refactor tradeoff 이중 검증) 이 필요하면 `/codex-review` 가 아니라 `/codex-ask` 를 사용한다 — stamp 를 생성하지 않는 별도 스킬.

---

## 2. Running a review

`/codex-review` 는 `scripts/rein-codex-review.sh` wrapper 를 호출한다.
Wrapper 가 context assembly, envelope 4 slots, codex exec, stamp 생성을 담당한다.

### Usage

- Interactive (code review): `bash scripts/rein-codex-review.sh`
- Automated (agent, code review): `bash scripts/rein-codex-review.sh --non-interactive`
- Spec review (plan review): stdin 맨 앞에 `[NON_INTERACTIVE] spec review for plan: <path>` marker. wrapper 가 spec-review mode 로 분기.
- Spec review (design review): stdin 맨 앞에 `[NON_INTERACTIVE] spec review for design: <path>` marker.

### Mode 별 stamp 규칙 (CRITICAL)

- **Code review mode**: PASS 시 `trail/dod/.codex-reviewed` 생성 (기존 pre-bash-guard gate 통과용). `.review-pending` 이 있으면 제거. stamp 에 `diff_base: <sha>` 라인 포함 (GI-codex-review-diff-base).
- **Spec review mode (plan 또는 design)**: `.codex-reviewed` **절대 생성 안 함**. `.review-pending` 도 건드리지 않음. verdict 만 stdout 으로 방출. caller 가 `bash scripts/rein-mark-spec-reviewed.sh <path> <reviewer>` 를 별도로 호출해 `trail/dod/.spec-reviews/*.reviewed` 를 생성할 책임.
- Rationale: `.codex-reviewed` 는 code commit/test gate. spec review 가 이를 찍으면 코드 변경 없이도 gate 통과 → rein 규율 붕괴.

### Legacy interactive model selection

아래는 wrapper 가 없던 시기의 manual invocation 절차로, 현재는 wrapper 가 담당한다. 참고용으로 남긴다.

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
5. Run the command, capture stdout/stderr, and summarize the outcome for the user.
6. After every `codex` command, immediately use `AskUserQuestion` to confirm next steps, collect clarifications, or decide whether to resume the same review cycle (§7).

### Quick Reference

| Use case                               | Sandbox mode      | Key flags                                |
| -------------------------------------- | ----------------- | ---------------------------------------- |
| 코드 리뷰 (초회)                       | `read-only`       | `--sandbox read-only`                    |
| 코드 리뷰 (fix 후 재리뷰, 같은 사이클) | inherited         | `echo "..." \| codex exec resume --last` |
| 로컬 편집 (드문 경우)                  | `workspace-write` | `--sandbox workspace-write --full-auto`  |
| 다른 디렉토리에서 실행                 | task needs        | `-C <DIR>` 추가                          |

### 실행 모드 — Bash 도구로 호출 시 foreground 전용

`.claude/rules/background-jobs.md` 예외 절에 따라, 어떤 경로로 codex 를 호출하든 Bash 도구에서는 foreground 실행이 강제된다. Bash 도구의 auto-background 전환이 stdin 을 unix socket 으로 붙이면 codex sandbox/auth 초기화가 hang 한다 (증상: 네트워크 연결 0개, CPU 0, `~/.codex/sessions/` 미갱신).

**공통 규칙** (wrapper / direct 모두):

- Bash 도구 호출 시 `run_in_background: false` 필수
- timeout 상한: `low ≤120s`, `medium ≤180s`, `high ≤300s`. 600s harness limit 넘어가면 prompt 쪼개기

**Wrapper 경로** — `bash scripts/rein-codex-review.sh [--non-interactive]`:

- wrapper 가 stdin 을 `printf '%s' "$prompt" | bash wrapper.sh` 형태로 명시 소비하므로 stdin 격리는 자연 충족
- 출력은 wrapper 가 stamp 생성 + stdout 요약을 동기 반환. `| tail -N` 추가 pipe 는 불필요
- stamp (`trail/dod/.codex-reviewed`) 생성은 **foreground 동기 실행** 가정 위에서 동작. background 전환 시 stamp 가 비정상 상태로 남을 수 있음 — `.review-pending` 은 남고 `.codex-reviewed` 는 미생성되는 staleness 가능

**Direct codex exec 경로** (§2 "Legacy interactive model selection" 의 수동 조립):

- stdin `< /dev/null` 로 명시 close
- 출력은 `> <file> 2>&1` 로 직접 파일에 쓰고 `Read` 로 읽기. `| tail -N` 금지 (EOF 까지 버퍼링)
- codex 실행 후 stamp 생성은 수동. wrapper 가 자동화하는 `diff_base` / `review_round` 필드를 caller 가 직접 채워야 함

Hang 감지 + 복구: §8 Error Handling 참고.

---

## 3. Escalation 규칙

리뷰 결과 severity + 수정 규모에 따라 다음 단계를 결정한다:

| 리뷰 결과      | 수정 규모 | 다음 행동                                                          |
| -------------- | --------- | ------------------------------------------------------------------ |
| High 이슈 있음 | 무관      | 수정 후 **codex 재리뷰** (Round 증가)                              |
| Medium만 있음  | > 3줄     | 수정 후 **codex 재리뷰** (Round 증가)                              |
| Medium만 있음  | ≤ 3줄     | 수정 후 **sonnet 셀프리뷰**                                        |
| Low만 있음     | 무관      | 수정 후 **sonnet 셀프리뷰**                                        |
| 이슈 없음      | —         | **통과** — stamp 생성 (§5)                                         |
| 3회차에도 High | —         | **사람에게 에스컬레이션** — stamp `resolution: escalated_to_human` |

**sonnet 셀프리뷰**: 변경 diff 를 직접 확인하고, stamp 에 `reviewer: self-review` 기록.

Round 관리: stamp 의 `review_round` 필드에 현재 회차를 기록한다. 같은 사이클 내 재리뷰는 Round 를 증가시키며 `codex exec resume --last` 로 이전 세션 컨텍스트를 유지한다 (§7).

---

## 4. Sonnet Fallback

Codex 실패 (에러/타임아웃) 시 Sonnet 기반 대체 리뷰 경로:

1. **Codex 리뷰 실행** — §2 절차로 `codex exec`
2. **성공 시** — §5 stamp 생성 후 종료
3. **실패 시 (에러/타임아웃)** — sonnet 폴백 리뷰 실행
   - `code-reviewer` 스킬 호출, 또는
   - `general-purpose` 에이전트 (model: sonnet) 로 이관
4. **폴백 성공 시** — stamp 에 `reviewer: sonnet-fallback` + `fallback_reason: codex_timeout` (또는 해당 에러 코드) 기록 후 종료
5. **폴백도 실패 시** — 작업 중단, 사용자에게 보고

**중요**: "codex 리뷰 결과가 부족해서" 등은 폴백 사유가 아니다. 에러/타임아웃 같은 **실행 실패** 만 폴백을 허용한다.

---

## 5. Stamp 생성 (필수)

리뷰 완료 후 반드시 `trail/dod/.codex-reviewed` 를 생성한다. stamp 없으면 `pre-bash-guard.sh` 가 테스트/커밋을 차단한다.

**Plan A Phase 6 이후**: `scripts/rein-codex-review.sh` wrapper 가 code-review mode PASS 시 자동 생성한다. 아래 필드 규격은 wrapper 가 emit 하는 포맷의 canonical 정의이며, Sonnet 셀프리뷰 / 수동 경로에서는 여전히 caller 가 같은 필드로 stamp 를 생성한다.

### 5.1 Stamp 필드

- `reviewer` — `codex` | `sonnet-fallback` | `self-review`
- `timestamp` — ISO 8601 UTC (`$(date -u +%Y-%m-%dT%H:%M:%S)`)
- `cycle` — 해당 작업 사이클 식별자 (DoD slug 또는 PR 번호)
- `scope` — 변경 범위 요약 (파일 수 또는 모듈명)
- `files_reviewed` — 리뷰 대상 파일 수
- `review_round` — 같은 사이클 내 N번째 리뷰
- `fallback_reason` — `none` | `codex_timeout` | `codex_error_<code>`
- `resolution` — `passed` | `needs-fix-round-N` | `escalated_to_human`
- `remaining_issues` — `none` 또는 잔존 이슈 요약

### 5.2 정상 통과 (codex)

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
cycle: [DoD slug]
scope: [변경 범위 요약]
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
fallback_reason: none
resolution: passed
remaining_issues: none
STAMP
```

### 5.3 Sonnet Fallback

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: sonnet-fallback
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
cycle: [DoD slug]
scope: [변경 범위 요약]
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
fallback_reason: codex_timeout
resolution: passed
remaining_issues: none
STAMP
```

### 5.4 Sonnet 셀프리뷰 (Low/경미한 Medium)

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: self-review
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
cycle: [DoD slug]
scope: [변경 범위 요약]
files_reviewed: [변경 파일 수]
review_round: [N번째 리뷰]
fallback_reason: none
resolution: passed
remaining_issues: none
prior_reviewer: codex
prior_max_severity: [medium 또는 low]
STAMP
```

### 5.5 사람 에스컬레이션

```bash
cat > trail/dod/.codex-reviewed << STAMP
reviewer: codex
timestamp: $(date -u +%Y-%m-%dT%H:%M:%S)
cycle: [DoD slug]
scope: [변경 범위 요약]
files_reviewed: [변경 파일 수]
review_round: 3
fallback_reason: none
resolution: escalated_to_human
remaining_issues: [잔존 이슈 요약]
STAMP
```

### 5.6 후처리

stamp 생성 후 `.review-pending` 이 남아 있으면 제거한다:

```bash
rm -f trail/dod/.review-pending
```

---

## 6. Non-interactive mode

자동 호출 (예: plan-writer agent 가 spec review 트리거) 시 사용. Prompt 에 marker 가 있으면 사용자 질문(AskUserQuestion) 을 skip 하고 default 로 codex exec 실행.

### 6.1 Invocation contract

prompt 본문 어디든 다음 marker 가 있으면 non-interactive mode 활성:

- `[NON_INTERACTIVE]` — AskUserQuestion 호출 skip
- `[MODEL:<name>]` — model override (default `gpt-5.4`)
  - 허용 값: `gpt-5.4`, `gpt-5.3-codex`
- `[EFFORT:<level>]` — reasoning effort override (default `high`)
  - 허용 값: `low`, `medium`, `high`
- `[SANDBOX:<mode>]` — sandbox override (default `read-only`)
  - 허용 값: `read-only`, `workspace-write`
  - **금지**: `danger-full-access` 는 자동 호출에서 거부 (사용자 명시 confirmation 필요)

### 6.2 Marker 처리 절차

1. prompt 에서 marker 패턴 (`\[NON_INTERACTIVE\]`, `\[MODEL:[^\]]+\]` 등) 추출
2. 추출 후 prompt 본문에서 marker 제거 (codex exec 로 전달 안 함)
3. 추출된 값 또는 default 로 codex exec 명령 조립
4. 실행 후 결과 캡처

**구현 상태** (v1.1.2~):

- `[EFFORT:<level>]` — ✅ wrapper (`scripts/rein-codex-review.sh`) 에 구현됨. 유효 값은 `low|medium|high`. 유효하지 않은 값은 stderr warning + `~/.codex/config.toml` default fallback. marker 는 codex 로 전달되는 prompt 에서 제거.
- `[NON_INTERACTIVE]` — ✅ wrapper 의 `--non-interactive` CLI 플래그로 처리. marker 자체는 prompt 에 보존 (spec-review 모드 감지에 사용).
- `[MODEL:<name>]`, `[SANDBOX:<mode>]` — ⏳ wrapper 미구현 (legacy interactive flow 전용). prompt 에 포함 시 wrapper 는 무시하고 `~/.codex/config.toml` default 를 사용.

### 6.3 Claude 자동 effort 선택 기준

비-interactive caller (Claude 본체) 가 `/codex-review` 를 호출할 때 변경 규모/복잡도에 따라 `[EFFORT:<level>]` marker 를 prompt 에 prepend 한다. `~/.codex/config.toml` 은 건드리지 않는다 (사용자 환경 보존).

| 조건                                                                                    | Effort   | 근거                                                        |
| --------------------------------------------------------------------------------------- | -------- | ----------------------------------------------------------- |
| docs-only, 3-10줄 diff, 기존 패턴 반복, markdown/comment 수정                           | `low`    | reasoning 최소. 2분 내 완료 → harness auto-background 방지. |
| 단일 모듈 코드 변경 <100줄, hook 수정 1-2개, 아키텍처 변화 없음, 로컬 로직 추가         | `medium` | 표준 리뷰. 대부분 2-3분 내 완료.                            |
| 다중 파일 + 보안 표면 / 새 데이터 흐름 / 아키텍처 변경 / 복잡한 상태 관리 / 동시성 이슈 | `high`   | 심층 reasoning 필요. 3분 초과로 background 전환 수용.       |

**판단 경계**:

- 경계 케이스는 한 단계 **낮춰서** 시작 → 리뷰 결과가 "더 깊은 분석 필요" 면 재리뷰 round 에서 `high` 로 승급.
- security-reviewer 와 codex-review 는 **별개 agent**. codex-review 의 effort 는 보안 review 와 무관.
- 사용자가 prompt 에 명시적 `[EFFORT:...]` 를 붙이면 Claude 의 자동 판단을 **오버라이드**. Claude 는 이를 존중.

### 6.4 사용 예 (agent 내부 자동 호출)

입력 prompt:

```
[NON_INTERACTIVE] spec review for plan: docs/plans/2026-04-20-v011-workflow-hardening.md.
Validate scope coverage and implementation feasibility.
```

→ skill 처리 후 실제 codex exec:

```
codex exec -m gpt-5.4 --config model_reasoning_effort="high" --sandbox read-only \
  --skip-git-repo-check "spec review for plan: ..."
```

### 6.5 사용자 직접 호출과의 차이

`[NON_INTERACTIVE]` marker 없이 `/codex-review` 호출 시 기존 interactive 경로 (§2 "Running a Task" 의 AskUserQuestion 절차) 따름. 자동 mode 는 agent 내부 호출 전용.

### 6.6 보안 노트

`[SANDBOX:danger-full-access]` 는 자동 호출에서 무조건 거부. agent 가 주입한 prompt 에 해당 marker 가 있으면 codex-review skill 이 명시적으로 사용자 confirmation 을 다시 요구. 이는 자동화 경로의 권한 상승을 방지하기 위한 가드.

### 6.7 Stamp 분리 — spec review vs code review (CRITICAL)

non-interactive mode 는 **두 경로** 로 쓰인다:

- **Code review 자동화** (향후) — agent 가 구현 완료 후 codex-review 를 호출하는 경우. 기존 §5 Stamp 생성 규정 따름 → `trail/dod/.codex-reviewed` 생성.
- **Spec review 자동화** (v1.0.0 plan-writer 경로) — agent 가 plan/design 을 검증받는 경우. `.codex-reviewed` / `.review-pending` 는 **절대 건드리지 않음**. 코드리뷰 gate 는 별개 절차.

**Spec review 모드 감지**: prompt 첫 줄이 `[NON_INTERACTIVE] spec review for plan:` 또는 `[NON_INTERACTIVE] spec review for design:` 형식으로 시작하면 spec-review 서브플로우로 분기.

Spec review 서브플로우 동작:

1. codex exec 실행 → verdict 캡처 (PASS / NEEDS-FIX / REJECT)
2. **`.codex-reviewed` stamp 생성하지 않음** (코드리뷰 게이트 오염 방지)
3. **`.review-pending` 건드리지 않음** (`rm` 금지)
4. PASS 시 caller (plan-writer 등) 가 책임지고 `bash scripts/rein-mark-spec-reviewed.sh <path> <reviewer>` 호출 — 이는 spec-review 전용 stamp (`trail/dod/.spec-reviews/<hash>.reviewed`) 생성
5. NEEDS-FIX/REJECT 시 caller 가 handoff (stamp 생성 안 함)

**왜 분리?**: `.codex-reviewed` 는 `pre-bash-guard.sh` 의 코드 commit/test gate. spec review 에서 이 stamp 가 찍히면 코드 변경 없이도 gate 통과 가능해져 rein 규율이 깨짐.

**Sonnet fallback 분기도 동일**: spec review 모드에서 codex 실패로 code-reviewer fallback 이 호출되더라도 `.codex-reviewed` 생성 금지. code-reviewer skill 이 spec-review context 를 인식할 수 있도록 prompt 전달 경로에서 `[NON_INTERACTIVE] spec review` prefix 보존.

---

## 7. Resume 정책

**허용**: 같은 리뷰 사이클 내 재리뷰 (fix 후 재검토) 는 `codex exec resume --last` 를 사용한다. 세션 컨텍스트가 같은 변경분을 다루므로 이전 대화가 도움이 된다.

```bash
echo "new prompt" | codex exec resume --last
```

resume 된 세션은 원 세션의 model, reasoning effort, sandbox mode 를 그대로 이어받는다.

**사이클 경계**: 새 DoD, 새 PR, 새 기능 개발로 전환될 때는 resume 하지 않고 새 `codex exec` 세션으로 시작한다. Second opinion 용도로는 절대 이 스킬이 아니라 `/codex-ask` 를 사용한다 (stamp 미생성 + resume 금지).

---

## 8. Error Handling

- `codex --version` 또는 `codex exec` 가 non-zero exit → 즉시 중단 + 보고. 재시도 전 사용자 지시 요청.
- 고위험 플래그 (`--full-auto`, `--sandbox danger-full-access`, `--skip-git-repo-check`) 사용 전 `AskUserQuestion` 으로 허가 획득 (이미 허가되지 않은 경우).
- 경고/부분 결과가 포함된 출력은 요약 후 `AskUserQuestion` 으로 조정 방향을 확인.
- Codex 실행 실패 → §4 Sonnet fallback 경로. 실패 사유를 stamp `fallback_reason` 필드에 기록.
- **Hang 증상 탐지** (§2 실행 모드 절 참고):
  - codex 프로세스가 수 분 이상 진행 없음 + CPU 0 + 네트워크 연결 0개 → Bash 도구 auto-background 전환으로 stdin 이 unix socket 에 붙어 sandbox/auth 초기화가 멈춤
  - 체크: `lsof -p <pid> -i` 결과 비어있으면 API 요청 미도달. `ps -o stat,%cpu,etime -p <pid>` 로 Sleep + 0% CPU 확인
  - 대응: kill 후 **foreground + stdin close + 직접 파일 출력** 형태로 재호출 (wrapper 경로 권장)
  - stamp 상태 정리: hang 이 발생한 사이클은 `.review-pending` 만 남고 `.codex-reviewed` 가 미생성된 staleness 가 흔함. 재호출 전 `ls trail/dod/.review-pending .codex-reviewed` 로 현재 상태 확인, 필요시 `.review-pending` 은 유지 (재리뷰 필요 signal)
  - 배경: `.claude/rules/background-jobs.md` 예외 절 + `trail/dod/dod-2026-04-22-codex-foreground-policy.md`
