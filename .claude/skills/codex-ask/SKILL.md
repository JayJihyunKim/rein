---
name: codex-ask
description: "Codex CLI second opinion 모드. stamp 없음, resume --last 금지, 매번 새 세션으로 독립 관점 확보. brainstorm 반박 / spec sanity / refactor tradeoff 이중 검증에 사용."
---

# Codex Ask Skill (Mode B)

## 1. 목적

Second opinion 전용 — Claude 주 세션의 컨텍스트와 **독립적** 인 외부 관점을 얻기 위한 스킬. `/codex-ask` 슬래시 명령으로 호출한다.

대표 사용처:
- **brainstorm 반박** — "이 선택지들 중에 숨은 리스크는?" / "Option B 기각이 진짜 맞나?"
- **spec sanity check** — "이 설계에 기술적 구멍은?" / "이 접근이 over-engineering 은 아닌가?"
- **refactor tradeoff 이중 검증** — "이 refactor 가 제 3 시각에서 합리적?"
- Claude 세션 컨텍스트에 오염되지 않은 **독립 관점** 이 필요한 모든 경우

이 스킬은 리뷰 **게이트가 아니다**. 리뷰 게이트 (stamp 생성) 가 필요하면 `/codex-review` 를 사용한다.

---

## 2. Running a Task

1. 사용자 의도 확인 — 무엇에 대한 second opinion 인지, 어떤 관점을 원하는지.
2. Ask the user (via `AskUserQuestion`) which model to run: `gpt-5.4` (default, config.toml 기본값) or `gpt-5.3-codex`.
3. Ask the user (via `AskUserQuestion`) which reasoning effort to use: `low`, `medium`, or `high`.
4. Sandbox 는 항상 `--sandbox read-only`. Second opinion 은 파일 편집 권한이 불필요하다.
5. **새 `codex exec` 세션** 으로 실행 (resume 금지 — §4 참조):
   ```
   codex exec \
     -m <model> \
     --config model_reasoning_effort="<effort>" \
     --sandbox read-only \
     --full-auto \
     -C <workdir>
   ```
6. 출력을 Claude 주 컨텍스트에 반영 후, 사용자에게 summary + 필요 시 의사결정 질문으로 요약 보고.
7. 추가 질의가 필요하면 **또 다른 새 세션** 으로 시작. 기존 세션 resume 하지 않는다.

### Quick Reference

| Use case | Sandbox mode | Key flags |
| --- | --- | --- |
| Second opinion (초회) | `read-only` | `--sandbox read-only` |
| Second opinion (추가 질의) | `read-only` | **새 세션**, resume 금지 |
| 다른 디렉토리에서 실행 | `read-only` | `-C <DIR>` 추가 |

---

## 3. Stamp 미생성 정책

**의도적으로 생성하지 않는다**. Second opinion 은 "관점 제공" 이지 "승인 게이트" 가 아니다.

- `trail/dod/.codex-reviewed` 같은 stamp 파일을 **절대 만들지 않는다**.
- 다른 어떤 리뷰 marker 도 touch 하지 않는다.
- `.review-pending` 등 기존 marker 도 건드리지 않는다.

리뷰 게이트가 필요한 경우 (테스트/커밋 통과가 목적) 는 반드시 `/codex-review` (Mode A) 를 사용한다. 실수로 `/codex-ask` 결과로 stamp 를 생성하면 리뷰 없이 테스트/커밋이 통과되어 `pre-bash-guard.sh` 의 게이트가 무력화된다.

---

## 4. Resume 금지 규칙

**`codex exec resume --last` 는 절대 사용 금지**.

이유: resume 하면 이전 세션의 대화 컨텍스트가 주입되어, 새 질문에 대한 **독립 관점** 이 이전 논의의 결론이나 가정에 오염된다. Second opinion 의 핵심 가치는 "선입견 없는 별도의 시각" 이므로 매 호출마다 반드시 새 `codex exec` 세션을 띄운다.

여러 번 질문해야 할 경우에도 각 호출마다 **새 세션** — 이전 답변과 연결하려는 목적이면 `/codex-review` 로 목적 자체를 재정의하거나, Claude 주 세션에서 문맥을 명시적으로 prompt 에 포함해 새 `codex-ask` 를 띄운다.

### Mode 대비

| 항목 | Mode A (`/codex-review`) | Mode B (`/codex-ask`) |
|------|---------------------------|-------------------------|
| 용도 | 리뷰 게이트 | Second opinion |
| Stamp 생성 | **필수** (`.codex-reviewed`) | **절대 금지** |
| Resume --last | 같은 사이클 내 허용 | **금지** — 매번 새 세션 |
| Sandbox | 상황별 (기본 read-only) | 항상 `read-only` |

---

## 5. 전형적 사용 예

### 5.1 Brainstorm 결론 반박

사용자: "brainstorming 에서 Option B 는 기각됐는데, 진짜 기각이 맞는지 독립 관점으로 반박해줘."

→ `/codex-ask` 로 새 세션 실행. brainstorm 요약을 prompt 에 포함 (Claude 의 현재 세션 문맥을 독립 세션에 전달). codex 가 Option B 지지 논거 또는 기각 논거의 허점을 제시.

### 5.2 Spec Sanity Check

사용자: "이 spec 의 X 결정이 실제로 기술적으로 말이 되는지 독립 시각으로 점검해줘."

→ `/codex-ask` 로 새 세션. spec 의 관련 섹션을 prompt 에 포함. codex 가 숨은 가정·엣지 케이스·기술적 모순을 지적.

### 5.3 Refactor Tradeoff 이중 검증

사용자: "이 refactor 가 over-engineering 인지 제 3 시각으로 판단해줘."

→ `/codex-ask` 로 새 세션. 변경 diff + 동기를 prompt 에 포함. codex 가 복잡도 추가 대비 이점·대안 경량 접근·YAGNI 관점에서 평가.

### 5.4 사용처가 아닌 경우

- **리뷰 게이트 통과가 필요** → `/codex-review` (stamp 생성 필수 경로)
- **이전 `/codex-ask` 답변에 이어서 물어보고 싶음** → 이어서 resume 하지 말고, 새 `/codex-ask` 에 이전 답변 요약을 prompt 에 포함
- **구현 편집이 필요** → `/codex-ask` 아님. workspace-write 가 필요한 작업은 별도 경로

---

## 6. Error Handling

- `codex exec` 가 non-zero exit → 사용자에게 보고 후 재시도 여부 질의. **폴백 없음** — Second opinion 은 리뷰 게이트가 아니므로 실패해도 작업 차단이 발생하지 않는다.
- 고위험 플래그는 기본적으로 사용하지 않는다. `/codex-ask` 는 `--sandbox read-only` 고정이므로 `--sandbox danger-full-access` / `--full-auto` 의 위험 조합이 발생하지 않는다.
- 출력에 경고나 부분 결과가 포함되면 요약 후 `AskUserQuestion` 으로 다음 질의 방향 확인.
