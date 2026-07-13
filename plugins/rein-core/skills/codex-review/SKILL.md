---
name: codex-review
description: "Codex CLI 코드 리뷰 모드. stamp 생성, severity escalation, Sonnet fallback, 동일 사이클 resume --last 허용. rein 의 리뷰 게이트(`trail/dod/.codex-reviewed`) 를 생성하는 유일한 스킬."
---

# Codex Review Skill (Mode A)

## 1. 목적

코드 리뷰 전용 — rein 의 리뷰 게이트 생성 스킬. `/codex-review` 슬래시 명령으로 호출한다.

이 스킬은 **리뷰 gate** 다. 실행 결과로 `trail/dod/.codex-reviewed` stamp 를 생성하며, 이 stamp 가 있어야만 `pre-bash-test-commit-gate.sh` 가 `git commit` / `pytest` 를 허용한다.

Second opinion (brainstorm 반박, spec sanity, refactor tradeoff 이중 검증) 이 필요하면 `/codex-review` 가 아니라 `/codex-ask` 를 사용한다 — stamp 를 생성하지 않는 별도 스킬.

### Mode 대비

| 항목         | Mode A (`/codex-review`)                                                | Mode B (`/codex-ask`)                                                                  |
| ------------ | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| 용도         | 리뷰 게이트                                                             | Second opinion                                                                         |
| Stamp 생성   | **필수** (`.codex-reviewed`)                                            | **절대 금지**                                                                          |
| Resume --last | 같은 사이클 내 허용                                                    | **금지** — 매번 새 세션                                                                |
| Sandbox      | 상황별 (기본 read-only)                                                 | 항상 `read-only`                                                                       |
| **Fallback** | codex 실행 **실패** 시에만 Sonnet/code-reviewer/human fallback 허용 (§4) | **same-session Claude fallback 금지**. 독립 reviewer 부재 시 degraded / no-second-opinion 으로 명시 |

Fallback 정책 비대칭 이유: Mode A 는 "리뷰가 어떤 형태로든 수행되어 stamp 가 생성" 되는 것이 게이트 통과의 전제이므로 codex 실행 실패 시 차순위 reviewer 로 대체할 수 있다. Mode B 는 "독립 관점" 자체가 가치이므로 same-session Claude 가 대신하면 본질이 깨진다 — 호출자는 결과 없이 작업을 계속하거나, 별도 시점에 Mode B 를 다시 시도한다.

---

## 2. Running a review

`/codex-review` 는 `scripts/rein-codex-review.sh` wrapper 를 호출한다.
Wrapper 가 context assembly, envelope 4 slots, codex exec, stamp 생성을 담당한다.

### Usage

- Interactive (code review): `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-codex-review.sh"`
- Automated (agent, code review, **file redirect 필수**):

  ```bash
  # 1. prompt 를 임시 파일로 작성 (Write 도구 또는 echo > file)
  # 2. file redirect 으로 wrapper 호출 — pipe (`|`) 사용 금지 (pre-bash-safety-guard 차단)
  bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-codex-review.sh" --non-interactive < /tmp/codex-prompt.txt
  ```

- Spec review (plan review): prompt 파일 맨 앞에 `[NON_INTERACTIVE] spec review for plan: <path>` marker. wrapper 가 spec-review mode 로 분기.
- Spec review (design review): prompt 파일 맨 앞에 `[NON_INTERACTIVE] spec review for design: <path>` marker.

> **Pipe vs file redirect**: `printf '...' | bash wrapper.sh` 패턴은 pre-bash-safety-guard 가
> 차단한다 (이유: stdin 의 명령 source 를 hook 가 검증할 수 없음). 항상 `< /tmp/<file>`
> 형태로 호출하라.

### 요청서 작성 규약 — review-readiness 사전검사

정량(개수/비율/백분율)·테스트 통과 주장을 쓰려면 각 주장을 `[EVIDENCE]` 블록으로 선언한다. 블록 없이 주장을 쓰면 래퍼가 review-readiness 사전검사에서 **exit 4 로 거부**한다 (codex 미호출 — 비용 0). 주장 없는 요청서는 종전대로 블록 불필요 (완전 하위호환 — 기존 요청서 무변경). output 발췌에 `[EFFORT:...]` 리터럴을 포함하지 마라 — 래퍼의 기존 전역 strip 단계가 제거한다 (사전검사가 보는 "원문" 은 strip 이후의 PROMPT_BODY).

- 증거 블록 문법 전문: §4.1
- exit 4 판별 계약 + 호출자 행동: §4.2 (Sonnet 폴백 비대상)
- spec-review 모드는 사전검사 비대상: §6.7

### Mode 별 stamp 규칙 (CRITICAL)

- **Code review mode**: PASS 시 `trail/dod/.codex-reviewed` 생성 (test/commit gate 통과용). `.review-pending` 이 있으면 제거. stamp 에 `diff_base: <sha>` 라인 포함 (GI-codex-review-diff-base).
- **Spec review mode (plan 또는 design)**: `.codex-reviewed` **절대 생성 안 함**. `.review-pending` 도 건드리지 않음. verdict 만 stdout 으로 방출. caller 가 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-mark-spec-reviewed.sh" <path> <reviewer>` 를 별도로 호출해 `trail/dod/.spec-reviews/*.reviewed` 를 생성할 책임.
- Rationale: `.codex-reviewed` 는 code commit/test gate. spec review 가 이를 찍으면 코드 변경 없이도 gate 통과 → rein 규율 붕괴.

### Legacy interactive model selection

아래는 wrapper 가 없던 시기의 manual invocation 절차로, 현재는 wrapper 가 담당한다. 참고용으로 남긴다.

1. 모델은 단일 출처(`plugins/rein-core/config/codex-models.sh` 의 `CODE_GATE_MODEL` — 게이트 고정 모델, 프로필 구조)가 결정한다. 래퍼가 이 값을 `-m` 으로 전달하므로 수동 모델 선택은 불필요하다 — 모델 rename 시 그 파일만 수정한다. (legacy alias `CODE_MODEL` 은 신값을 노출한다.)
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

`plugins/rein-core/rules/background-jobs.md` 예외 절에 따라, 어떤 경로로 codex 를 호출하든 Bash 도구에서는 foreground 실행이 강제된다. Bash 도구의 auto-background 전환이 stdin 을 unix socket 으로 붙이면 codex sandbox/auth 초기화가 hang 한다 (증상: 네트워크 연결 0개, CPU 0, `~/.codex/sessions/` 미갱신).

**공통 규칙** (wrapper / direct 모두):

- Bash 도구 호출 시 `run_in_background: false` 필수
- timeout 상한: `low ≤120s`, `medium ≤180s`, `high ≤300s`. 600s harness limit 넘어가면 prompt 쪼개기

**Wrapper 경로** — `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-codex-review.sh" [--non-interactive] < /tmp/<prompt>.txt`:

- wrapper 는 stdin 으로 prompt 를 받는다. **항상 file redirect (`< /tmp/<file>`)** 사용 — pipe (`printf '...' | bash wrapper.sh`) 는 pre-bash-safety-guard 가 차단 (stdin 명령 source 검증 불가)
- prompt 작성: Write 도구로 `/tmp/codex-prompt.txt` 등에 작성 후 redirect
- 출력은 wrapper 가 stamp 생성 + stdout 요약을 동기 반환. `> /tmp/<output>.log 2>&1` 형태로 직접 파일에 쓰고 Read 로 확인. `| tail -N` 추가 pipe 는 불필요
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

**모델 설정 에러(종료 코드 3)는 폴백 대상이 아니다.** 래퍼가 exit 3 으로 종료하면 codex 가 모델명을 거부한 것(upstream rename 등)이다. sonnet 폴백으로 넘기면 잘못된 모델 설정이 가려지므로, 폴백하지 말고 `plugins/rein-core/config/codex-models.sh` 의 `CODE_GATE_MODEL` 을 codex 의 최신 모델명으로 갱신하도록 사용자에게 안내한다. 래퍼가 경로와 현재 값을 stderr 로 출력한다.

**review-readiness 거부(종료 코드 4 + 거부 진단행)도 폴백 대상이 아니다.** codex 실행 실패가 아니라 요청서 결함이므로, sonnet 폴백으로 새면 요청서 결함이 가려진다 (exit 3 과 동일한 비대상 원리). 준비도 거부는 codex spawn **이전**에만 발생하며 (비용 0), stamp 계열 파일(`.codex-reviewed`/`.review-pending`/`.spec-reviews/*`)을 건드리지 않는다. 호출자는 stderr 안내대로 요청서를 수정한 뒤 재호출한다 — 문법은 §4.1, 판별 계약과 호출자 행동은 §4.2.

### 4.1 증거 블록 문법 (`[EVIDENCE]`)

리뷰 요청서(래퍼 stdin 의 PROMPT_BODY)에서 정량/PASS 주장의 재현 증거는 다음 고정 형식으로 선언한다. 래퍼의 review-readiness 사전검사가 codex 호출 전에 형식을 결정론적으로 검증한다 (code-review 모드 한정 — spec-review 모드는 비대상, §6.7):

```
[EVIDENCE]
claim: 테스트 21건 GREEN
command: bash tests/skills/run-all.sh
exit_code: 0
output:
...(생략)...
ok 21 - test-codex-model-profile-routing
21 passed, 0 failed
[/EVIDENCE]
```

**문법 규칙 (결정론적 — 위반 = exit 4)**:

0. **fence 상태 전이 (단일 좌→우 스캔)**: fence 토글(``` ```)은 **증거 블록 밖에서만** 유효하다 — 블록 밖에서 fence 열림 상태의 `[EVIDENCE]`/`[/EVIDENCE]` 단독 라인은 블록 경계로도 형식 위반으로도 취급하지 않는다 (문법 예시·diff 인용 보호). 반대로 **증거 블록 안(output 영역 포함)의 ``` 는 일반 출력 텍스트**이며 fence 상태를 토글하지 않는다 — output 에 미폐쇄 ``` 가 있어도 뒤따르는 실제 `[/EVIDENCE]` 가 정상 폐쇄로 인식된다. 정량/PASS 패턴 스캐너는 이 스캔이 남긴 같은 마스킹 결과를 공유한다 (마스킹 1회). 인라인 백틱은 라인 단독 마커가 될 수 없으므로 블록 파서에는 무관 (패턴 스캐너에만 적용).
1. `[EVIDENCE]` / `[/EVIDENCE]` 는 각각 **한 줄에 단독**으로 위치한다 (선행 공백 허용).
2. 블록 내부 필드는 **고정 순서** `claim:` → `command:` → `exit_code:` → `output:` 4종, 각 정확히 1회. 순서 위반·누락·중복 = 형식 위반.
3. `claim:` = 이 블록이 뒷받침하는 자연어 주장 한 줄 (비어있으면 위반). `command:` = 재현 명령 한 줄 (비어있으면 위반).
4. `exit_code:` = 0–255 정수. 그 외 값 = 위반.
5. `output:` 라인 **다음 줄부터** `[/EVIDENCE]` 직전까지가 출력 원문이다 — 어떤 escaping 도 불필요 (여러 줄·특수문자 그대로). 단 출력 영역 안에 `[EVIDENCE]` 단독 라인이 나타나면 중첩 금지 위반. 출력 0줄 허용 (명령이 무출력인 경우) — `output:` 라인 자체는 필수.
6. **출력 상한**: 블록당 output 60줄 이하 **그리고** 8000바이트 이하. **바이트 정의**: `output:` 다음 줄부터 `[/EVIDENCE]` 직전 줄까지 output 영역의 **UTF-8 원시 바이트 수** — 각 줄의 LF 개행 바이트를 포함하고, 문자 수가 아니라 바이트 수다 (한글 등 다중바이트 문자는 인코딩된 바이트만큼 계수). **경계 포함**: 정확히 60줄·정확히 8000바이트는 통과, 61줄 또는 8001바이트부터 위반. 초과 = 형식 위반 (래퍼는 절단·변조하지 않는다 — 작성자가 관련 발췌로 줄인다. stderr 안내: `tail`/`grep` 발췌 권장).
7. **블록 수 상한**: 요청서당 유효 블록 16개 이하. 초과 = 형식 위반 (envelope 크기 보호).
8. 다중 주장 = 다중 블록 (주장 1 : 블록 1). 하나의 명령 출력이 여러 주장을 뒷받침하면 블록을 주장별로 나누고 output 발췌를 각각 최소화한다 (규약 — 래퍼는 주장:블록 대응의 의미를 검증하지 않는다).

**검증 깊이 (확정)**: 형식만. 래퍼는 `command:` 를 **재실행하지 않고**, output 과 exit_code 의 진위를 확인하지 않는다. 형식은 갖췄지만 거짓인 증거는 기존대로 codex 가 잡는다 — 유효 블록은 PROMPT_BODY 원문 위치에 그대로 보존되고, envelope 의 `evidence_manifest:` 슬롯(블록별 claim/command/exit_code 요약)과 Claim Audit sub-item 7 로 codex 에 구조화 전달된다. 블록 밖 잔존 정량 매칭은 비차단 advisory (`WARNING: [codex-review][readiness-advisory]`) + envelope `unbacked_quant_flags:` 슬롯으로 전달된다.

### 4.2 exit code 4 — review-readiness 거부 (판별 계약 + 호출자 행동)

**호출자 행동 표**:

| exit | 의미 | 호출자 행동 |
|---|---|---|
| 4 (+거부 진단행 — `ERROR: [codex-review][readiness-reject]` 로 시작하는 stderr 라인) | review-readiness 거부 — codex 미호출 (비용 0) | stderr 안내대로 요청서를 수정(증거 블록 추가 또는 형식 교정)해 **재호출**. Sonnet fallback 비대상 — codex 실행 실패가 아니라 요청서 결함이므로 fallback 으로 새면 결함이 가려진다 (exit 3 과 동일한 비대상 원리). 재리뷰 카운트(§3 escalation)에 포함하지 않는다 — 리뷰가 수행되지 않았다. |
| 4 (거부 진단행 0 — advisory 경고·발췌 내용 무관) | codex 실행 실패 passthrough (드묾 — `CODEX_RC` passthrough 와의 이론적 겹침) | 기존 실행 실패 경로와 동일 — Sonnet fallback 후보 (§4 본문). |

**호출자 판별 계약 (기계 계약 — 사람 판독 아님)**:

```
거부 진단행    := 정확히 "ERROR: [codex-review][readiness-reject]" 로 시작하는 stderr 라인 (라인 시작 anchored — substring 검색 금지)
준비도 거부    := exit == 4 AND 거부 진단행 ≥ 1
codex 실행실패 := exit == 4 AND 거부 진단행 0  → 기존 실행 실패 처리 (Sonnet fallback 후보) 그대로
```

substring 이 아니라 **라인 시작 anchored 접두사**로 판별하는 이유: 발췌·기존 진단 등 다른 stderr 내용에 예약 문자열이 섞여도(래퍼의 발췌 소독 — 발췌 내 예약 태그를 `[readiness-…]` 로 치환 — 이 1차 차단, 접두사 anchoring 이 2차 방어) 판별이 오염되지 않는다. advisory 는 별도 접두사 `WARNING: [codex-review][readiness-advisory]` (비차단) 이므로, advisory 경고가 방출된 뒤 codex 자신이 exit 4 를 반환하는 조합에서도 stderr 에 거부 진단행이 없어 호출자가 passthrough 로 정확히 분류한다.

---

## 5. Stamp 생성 (필수)

리뷰 완료 후 반드시 `trail/dod/.codex-reviewed` 를 생성한다. stamp 없으면 `pre-bash-test-commit-gate.sh` 가 커밋을 차단한다.

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

**실행 증빙 5필드** (additive — 기존 필드의 이름·순서·포맷 불변, 커밋 게이트 파서는 이 필드들에 비의존):

- `model` — 실제 게이트 실행 모델 (`CODE_GATE_MODEL` 해석 결과, 예: `gpt-5.6-sol`)
- `effort` — 실제 적용된 reasoning effort (`low` | `medium` | `high`)
- `effort_source` — effort 결정 경로: `marker`(유효 `[EFFORT:]` 마커) | `computed`(변경 규모 산출) | `computed+floor`(산출 low → 위험도 floor 로 medium 승격) | `fail_closed`(측정 실패 폴백)
- `policy_version` — config 의 `CODE_ROUTING_POLICY_VERSION`. config 부재로 canonical fallback 실행 시 `0` (내장 폴백 실행 식별용)
- `codex_version` — stamp 작성 시점 `codex --version` best-effort 1회 해석. 실패/빈 출력 시 `(unavailable)` (순수 증빙 필드 — 해석 실패가 stamp 작성을 막지 않음)

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
model: [CODE_GATE_MODEL 해석 결과, 예: gpt-5.6-sol]
effort: [low|medium|high]
effort_source: [marker|computed|computed+floor|fail_closed]
policy_version: [CODE_ROUTING_POLICY_VERSION, canonical fallback 시 0]
codex_version: [codex --version 1줄, 실패 시 (unavailable)]
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
model: [CODE_GATE_MODEL 해석 결과, 예: gpt-5.6-sol]
effort: [low|medium|high]
effort_source: [marker|computed|computed+floor|fail_closed]
policy_version: [CODE_ROUTING_POLICY_VERSION, canonical fallback 시 0]
codex_version: [codex --version 1줄, 실패 시 (unavailable)]
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
model: [CODE_GATE_MODEL 해석 결과, 예: gpt-5.6-sol]
effort: [low|medium|high]
effort_source: [marker|computed|computed+floor|fail_closed]
policy_version: [CODE_ROUTING_POLICY_VERSION, canonical fallback 시 0]
codex_version: [codex --version 1줄, 실패 시 (unavailable)]
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
model: [CODE_GATE_MODEL 해석 결과, 예: gpt-5.6-sol]
effort: [low|medium|high]
effort_source: [marker|computed|computed+floor|fail_closed]
policy_version: [CODE_ROUTING_POLICY_VERSION, canonical fallback 시 0]
codex_version: [codex --version 1줄, 실패 시 (unavailable)]
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
- `[MODEL:<name>]` — model override (기본값은 단일 출처 `plugins/rein-core/config/codex-models.sh` 의 `CODE_GATE_MODEL` — 게이트 고정 모델)
  - 허용 값: codex 가 지원하는 임의 모델명. 하드코딩 화이트리스트를 두지 않는다 (모델 rename 시 문서 수정 불필요).
- `[EFFORT:<level>]` — reasoning effort override (마커 부재 시 래퍼가 변경 규모로 산출 + 위험도 floor 적용; 측정 실패 시 fail-closed 페어의 `CODE_FAIL_CLOSED_EFFORT`(=`high`))
  - 허용 값: `low`, `medium`, `high`
  - **거부 값 (각자 사유 + 산출 진입)**:
    - `ultra` — 게이트에서 **명시 거부**. ultra 는 자동 하위작업 위임(auto subagents)으로 동작해 게이트 판정이 비결정적이 되고 quota/timeout 충돌을 일으킨다. stderr 에 ultra 전용 사유 메시지 출력.
    - `max` / `xhigh` — timeout 실측 전 **미지원** (후속 재검토 대상). stderr 에 각자 사유 메시지 출력.
    - 셋 다 거부 후에는 마커 없음과 동일하게 **변경 규모 산출 경로로 진입**하며(floor 포함), 마커는 strip 되어 codex 프롬프트/인자 어디로도 전달되지 않는다. 기타 무효값(`low2` 등)은 기존 generic warning 유지.
- `[SANDBOX:<mode>]` — sandbox override (default `read-only`)
  - 허용 값: `read-only`, `workspace-write`
  - **금지**: `danger-full-access` 는 자동 호출에서 거부 (사용자 명시 confirmation 필요)

### 6.2 Marker 처리 절차

1. prompt 에서 marker 패턴 (`\[NON_INTERACTIVE\]`, `\[MODEL:[^\]]+\]` 등) 추출
2. 추출 후 prompt 본문에서 marker 제거 (codex exec 로 전달 안 함)
3. 추출된 값 또는 default 로 codex exec 명령 조립
4. 실행 후 결과 캡처

**구현 상태** (v1.1.2~):

- `[EFFORT:<level>]` — ✅ wrapper (`scripts/rein-codex-review.sh`) 에 구현됨. 유효 값은 `low|medium|high`. `ultra`/`max`/`xhigh` 는 각자 전용 사유의 stderr 메시지(ultra=자동위임 게이트 금지, max/xhigh=timeout 실측 전 미지원) 후 산출 진입, 기타 무효값은 기존 generic warning + **변경 규모 기반 산출 진입**(`_compute_effort`). marker 는 유효성과 무관하게 codex 로 전달되는 prompt 에서 제거.
- `[NON_INTERACTIVE]` — ✅ wrapper 의 `--non-interactive` CLI 플래그로 처리. marker 자체는 prompt 에 보존 (spec-review 모드 감지에 사용).
- `[MODEL:<name>]` — ⏳ marker override 자체는 wrapper 미구현(legacy — prompt-controlled downgrade 차단 목적의 의도된 미구현). 단 **기본 모델은 단일 출처 `plugins/rein-core/config/codex-models.sh` 의 `CODE_GATE_MODEL`** 을 wrapper 가 `-m` 으로 항상 전달한다 (config 전 후보 부재 시 래퍼 내장 canonical `gpt-5.6-sol`+`high` 로 명시 폴백 — 무모델 호출 없음, §6.3). `[SANDBOX:<mode>]` — ⏳ wrapper 미구현. prompt 에 포함 시 wrapper 는 무시하고 codex 기본 sandbox 를 사용.

### 6.3 래퍼 자동 effort 산출 기준

`/codex-review` 호출 시 **래퍼(`rein-codex-review.sh`)가 변경 규모로 effort 를 결정론적으로 산출**한다(마커 부재 시). caller 가 `[EFFORT:<level>]` marker 를 직접 prepend 하면 그 값이 산출을 **오버라이드**하고, 그 외에는 래퍼 산출이 적용된다. `~/.codex/config.toml` 은 어느 경로에서도 건드리지 않는다 (사용자 환경 보존). 측정 실패/불가 시 fail-closed **모델+effort 페어**(`CODE_FAIL_CLOSED_MODEL`+`CODE_FAIL_CLOSED_EFFORT` = `gpt-5.6-sol`+`high`)로 폴백 (`effort_source: fail_closed`).

**코드 산출이 권위**다. 아래 표는 산출 휴리스틱의 의도를 설명하며, Claude 본체/사용자의 수동 `[EFFORT:]` 는 산출을 **오버라이드**(상향/하향)하는 용도다.

| 조건                                                                                    | Effort   | 근거                                                        |
| --------------------------------------------------------------------------------------- | -------- | ----------------------------------------------------------- |
| docs-only, 3-10줄 diff, 기존 패턴 반복, markdown/comment 수정                           | `low`    | reasoning 최소. 2분 내 완료 → harness auto-background 방지. |
| 단일 모듈 코드 변경 <100줄, hook 수정 1-2개, 아키텍처 변화 없음, 로컬 로직 추가         | `medium` | 표준 리뷰. 대부분 2-3분 내 완료.                            |
| 다중 파일 + 보안 표면 / 새 데이터 흐름 / 아키텍처 변경 / 복잡한 상태 관리 / 동시성 이슈 | `high`   | 심층 reasoning 필요. 3분 초과로 background 전환 수용.       |

**판단 경계**:

- 경계 케이스는 한 단계 **낮춰서** 시작 → 리뷰 결과가 "더 깊은 분석 필요" 면 재리뷰 round 에서 `high` 로 승급.
- security-reviewer 와 codex-review 는 **별개 agent**. codex-review 의 effort 는 보안 review 와 무관.
- 사용자가 prompt 에 명시적 `[EFFORT:...]` 를 붙이면 Claude 의 자동 판단을 **오버라이드**. Claude 는 이를 존중.
- **재승급 불변식 (E5)**: 3회차 재리뷰 high 강제·재리뷰 round high 승급은 caller 가 `[EFFORT:high]` 마커를 주입해 동작하며, 마커는 산출보다 우선이므로 어떤 산출 결과도 재승급된 high 를 약화시키지 않는다.

**위험도 floor (경로 기반 하한선)**:

변경 크기 ≠ 위험도(3줄 인증 우회 = 고위험, 500줄 생성 문서 = 저위험)의 보완으로, **산출된 effort 에만** path 기반 하한선을 적용한다:

- 위험 경로 패턴 5종: `hooks/**` · `security/**` · `config/**` (임의 깊이 디렉토리 세그먼트 매칭), `.github/workflows/**` (repo 루트 앵커), `scripts/rein-*.sh` (`scripts/` 세그먼트 하위).
- 변경 파일 중 한 줄이라도 매칭 + 산출 effort 가 `low` 면 `medium` 으로 승격 (도장에 `effort_source: computed+floor` 기록).
- **low→medium 단방향만**: `medium`/`high` 산출은 무변경 — floor 는 하한선이지 가산기가 아니다.
- **마커 > floor**: 유효 `[EFFORT:]` 마커가 있으면 산출·floor 블록 자체에 진입하지 않는다 — `[EFFORT:low]` + 위험 경로 = 최종 `low`. `[EFFORT:high]` 재승급도 마커 경로라 산출/floor 가 관찰하지 못한다 (E5 불변식 보존).
- **spec-review 모드 미적용**: 문서 리뷰는 코드 경로가 아니므로 위험 경로 매칭 자체를 건너뛴다.
- 측정 실패 폴백(`fail_closed`)은 이미 `high` 라 floor 와 구조적으로 상호 배타.

**Canonical fallback (config 부재 시)**:

config(`codex-models.sh`) 의 전 후보가 부재해도 "빈 모델 → `-m` 생략 → codex 기본 모델 degrade" 경로는 없다(폐지됨). 래퍼 내장 canonical 상수 **`gpt-5.6-sol` + `high`** 로 명시 폴백하고 stderr 경고를 정확히 1회 출력한다(config 정상 로드 시 무발화). codex 호출에 `-m` 은 **항상** 전달된다(무모델 호출 0건 — 게이트가 "codex 기본 모델" 이라는 외부 가변값에 좌우되지 않도록). 이 경로로 실행되면 도장의 `policy_version` 이 `0` 으로 기록된다.

**재리뷰 일관성 (같은 사이클 = 같은 모델)**:

같은 리뷰 사이클 내 재리뷰는 모델을 바꾸지 않고 effort 만 승급한다. 게이트 모델이 `CODE_GATE_MODEL` 단일 고정이므로 이 일관성은 **구조적으로 보장**된다 — 규모/회차별 모델 혼용은 결함 탐지 성향·severity 보정·PASS 기준이 달라져 게이트 판정 비일관을 만들므로 하지 않는다.

### 6.4 사용 예 (agent 내부 자동 호출)

입력 prompt:

```
[NON_INTERACTIVE] spec review for plan: docs/plans/2026-04-20-v011-workflow-hardening.md.
Validate scope coverage and implementation feasibility.
```

→ skill 처리 후 실제 codex exec:

```
# 모델은 래퍼가 단일 출처(codex-models.sh)의 CODE_GATE_MODEL 을 -m 으로 전달.
codex exec -m "$CODE_GATE_MODEL" --config model_reasoning_effort="high" --sandbox read-only \
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

**spec-review 모드는 review-readiness 사전검사 대상이 아니다** — 사전검사·정량/PASS 휴리스틱·`evidence_manifest:` 슬롯 전부 skip (사전검사는 code-review 모드 한정, §2 요청서 작성 규약 / §4.1 참조). spec-review 지시문의 "PASS"·"coverage" 류 관행 토큰이 false-positive 로 자동 경로를 차단하지 않도록 하기 위함이다.

Spec review 서브플로우 동작:

1. codex exec 실행 → verdict 캡처 (PASS / NEEDS-FIX / REJECT)
2. **`.codex-reviewed` stamp 생성하지 않음** (코드리뷰 게이트 오염 방지)
3. **`.review-pending` 건드리지 않음** (`rm` 금지)
4. PASS 시 caller (plan-writer 등) 가 책임지고 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-mark-spec-reviewed.sh" <path> <reviewer>` 호출 — 이는 spec-review 전용 stamp (`trail/dod/.spec-reviews/<hash>.reviewed`) 생성
5. NEEDS-FIX/REJECT 시 caller 가 handoff (stamp 생성 안 함)

**왜 분리?**: `.codex-reviewed` 는 `pre-bash-test-commit-gate.sh` 의 코드 commit gate. spec review 에서 이 stamp 가 찍히면 코드 변경 없이도 gate 통과 가능해져 rein 규율이 깨짐.

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
  - 배경: `plugins/rein-core/rules/background-jobs.md` 예외 절 + `trail/dod/dod-2026-04-22-codex-foreground-policy.md`

---

## 9. 사용자 안내

이 SKILL 의 결과를 사용자에게 보고할 때 (호출자 = Claude 가 wrapper output 을 user-facing chat 으로 emit 할 때) 다음 짧은 형식을 **먼저** 출력한다. wrapper 자체는 raw codex output 을 그대로 emit 하며, 안내 prepend 는 호출자 책임 (호출 환경이 다양하므로 wrapper 강제 안 함). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 액션 1줄.

**Round PASS (verdict=PASS)**:
> 코드 리뷰 통과. [차단급 결함 없음 또는 Low advisory N건]. 다음은 [보안 리뷰 또는 다음 단계].

**Round NEEDS-FIX (verdict=NEEDS-FIX)**:
> 리뷰에서 N건 수정이 필요해요 — [Severity 요약, 예: "Medium printf 형식 + Low 테스트 stderr 미검증"]. [고치고 재리뷰 또는 sonnet 셀프리뷰 — escalation 규칙 §3 따라].

**Sonnet fallback 통과** (§4 — codex 실행 실패 한정. §3 의 sonnet self-review 와 다른 path):
> codex 가 떠지지 않아 sonnet 폴백 리뷰로 통과시켰습니다. stamp 에 `reviewer: sonnet-fallback` + `fallback_reason: <코드>` 기록되어 있어요.

**3회차에도 High 잔존 → 사람 에스컬레이션**:
> 3회차 리뷰에도 High N건이 남아 사람 에스컬레이션이 필요해요. stamp 의 `resolution: escalated_to_human` 확인하고 잔존 이슈를 직접 처리해 주세요.

이 짧은 안내 후에 기존 codex 본문 (Code Defects / Design Alignment / Test Alignment / Claim Audit / `FINAL_VERDICT: <X>`) 를 그대로 emit 한다.
