# CLAUDE.md — 진입점

> 이 파일은 매 세션 시작 시 자동으로 로드된다.
> 규칙의 허브 역할을 하며, 하위 파일을 @import로 연결한다.

---

## 로딩 순서

Claude Code는 세션 시작 시 아래 순서로 컨텍스트를 구성한다:

1. 이 파일 (`.claude/CLAUDE.md`) — 자동 로드
2. `/AGENTS.md` — 전역 실행 규칙
3. 작업 디렉토리의 nearest `AGENTS.md` — 언어/프레임워크별 규칙
4. **SessionStart 훅 (`session-start-load-trail.sh`)** 이 다음을 자동 주입 (lean mode, 2026-04-29~):
   - `trail/index.md` 전량 (5~25줄)
   - 비권위 캐시 freshness 경고 1줄 — release/git/tag/publish 류 volatile claim 은 답변 전 git 명령으로 재검증
   - `trail/dod/.spec-reviews/*.pending` 있으면 "⚠️ 미해결 spec review" 요약
   - `trail/incidents/` 미처리 incident 카운트 (있으면 첫 source 편집 차단)
   - skill/MCP 인벤토리 가이드 (`.claude/cache/skill-mcp-guide.md`)
   - **자동 주입에서 제외**: `trail/inbox/*.md`, `trail/daily/*.md`, `trail/weekly/*.md`, `MEMORY.md`. 필요 시 명시 read 로 가져온다 (raw 회고/절차 텍스트가 stale anchoring 을 유발한 회고: `trail/dod/dod-2026-04-29-session-context-reduction.md`)

작업 유형에 따라 추가 로드:
- 워크플로우: `.claude/workflows/[relevant].md`
- 에이전트: `.claude/agents/[relevant].md`

---

## 규칙 허브

@.claude/rules/answer-only-mode.md
@.claude/rules/code-style.md
@.claude/rules/testing.md
@.claude/rules/security.md
@.claude/rules/subagent-review.md
@.claude/rules/design-plan-coverage.md
@.claude/rules/background-jobs.md

---

## 오케스트레이터

작업 유형 → workflow + agent 조합은 아래 파일 참조:

@.claude/orchestrator.md

---

## trail 운영 규칙

### 세션 시작 시 (hook이 자동 실행)
1. `trail/index.md` 읽기
2. `pre-edit-dod-gate.sh`가 세션 첫 Edit/Write 시 자동으로 아래를 수행:
   - `trail/inbox/`에 **어제 이전** 파일 → `trail/daily/YYYY-MM-DD.md`로 병합 → inbox 원본 삭제
   - `trail/daily/`에 **7일 이전** 파일 → `trail/weekly/YYYY-WNN.md`로 병합 → daily 원본 삭제
   - 하루 1회만 실행 (마커 파일로 중복 방지)

### 작업 완료 시 (inbox 기록)
- 작업 1개를 완료할 때마다 `trail/inbox/YYYY-MM-DD-작업명.md`에 기록한다
- 포맷:
  ```
  # [작업명]
  - 날짜: YYYY-MM-DD
  - 유형: feat | fix | refactor | research | docs
  - 변경 파일: [목록]
  - 요약: [1~3줄]
  ```
- 비정상 종료에 대비하여, 세션 종료가 아닌 **작업 완료 시점**에 즉시 기록한다

### 세션 종료 시
- `trail/index.md`를 최신 상태로 갱신한다

---

## 강제 작업 시퀀스 (hook이 위반을 차단합니다)

> **Answer-only mode 가 적용되는 turn 은 이 시퀀스를 skip 한다** — 단순 정보 조회·의견 요청·tradeoff 설명·second opinion 호출은 DoD/route/review/inbox/index ceremony 없이 답변에 집중. 단 release/git/tag/publish 류 volatile claim 은 답변 전 명령으로 재검증한다. 자세한 trigger·escape·검증 의무: `.claude/rules/answer-only-mode.md`. 코드 편집·파일 신규 생성 의도가 발생하는 즉시 정상 시퀀스로 자동 전환 (`pre-edit-dod-gate.sh` 가 강제).

아래 순서를 반드시 따른다. Hook이 도구 호출을 차단(exit 2)하므로 건너뛸 수 없다.

1. **READ** `trail/index.md` — 항상 첫 번째
2. **WRITE** `trail/dod/dod-YYYY-MM-DD-<slug>.md` — 소스 코드 편집 전 필수 (날짜=작업 시작일, slug=영문 kebab-case, AGENTS.md §2 규칙 준수)
   → `pre-edit-dod-gate.sh`가 DoD 파일 없으면 Edit/Write/MultiEdit를 차단함
   → DoD는 inbox과 분리. inbox은 "작업 완료 기록", dod는 "작업 시작 전 기준"
3. **ROUTE** — 스마트 라우터로 최적 조합 추천 → 사용자 확인 → DoD 에 `## 라우팅 추천` 섹션 기록
   → `.claude/orchestrator.md`의 "스마트 라우팅 절차"를 따른다
   → 세션 컨텍스트에서 사용 가능한 에이전트/스킬/MCP를 동적으로 발견
   → DoD 내용과 description 매칭으로 에이전트 1 + 스킬 최대 3 + MCP 최대 2 추천
   → DoD 파일에 `## 라우팅 추천` YAML 섹션 기록 (agent/skills/mcps/rationale/approved_by_user)
   → 사용자 승인 후 `approved_by_user: true` 로 교체. `pre-edit-dod-gate.sh` 가 누락 시 Edit/Write 차단 (exit 2)
   → 수정 시 `python3 scripts/rein-route-record.py override ...` 로 overrides.yaml 에 기록
4. **IMPLEMENT** — 승인된 조합의 에이전트/스킬/MCP를 활용하여 소스 코드 편집
5. **CODEX REVIEW** — 구현 완료 후 반드시 Codex로 코드 리뷰 실행
   → `/codex-review` 스킬 (Mode A) 로 변경된 파일에 대해 리뷰 요청. `/codex-ask` (Mode B — second opinion) 는 stamp 를 생성해서는 안 되며 리뷰 gate 를 대체하지 않는다.
   → 리뷰 완료 후 `trail/dod/.codex-reviewed` stamp 를 `/codex-review` 스킬이 생성 (수동 touch 는 `.claude/rules/subagent-review.md` 예외 조건에서만 허용)
6. **SECURITY REVIEW** — Codex 리뷰 완료 후 보안 리뷰 실행
   → `security-reviewer` 에이전트가 `.claude/security/profile.yaml`의 보안 레벨 기준으로 리뷰
   → 리뷰 완료 후 `touch trail/dod/.security-reviewed`로 stamp 생성
   → `pre-bash-guard.sh`가 테스트/커밋 시 두 stamp 모두 없으면 차단함 (exit 2)
7. **FIX** — Codex 리뷰 + 보안 리뷰 결과 반영하여 코드 수정
8. **TEST** — 테스트 실행 (두 리뷰 stamp가 모두 있어야 실행 가능)
9. **SELF-REVIEW** — AGENTS.md §6 항목을 명시적으로 답변
10. **WRITE** `trail/inbox/YYYY-MM-DD-[작업명].md` — 작업 완료 기록
    → `stop-session-gate.sh`가 세션 종료 시 inbox 기록 없으면 차단함 (exit 2)
    → 라우팅 피드백을 `.rein/policy/router/feedback-log.yaml`에도 기록
11. **UPDATE** `trail/index.md` — 세션 종료 전
    → `stop-session-gate.sh`가 세션 종료 시 index.md 미갱신이면 차단함 (exit 2)

**차단 시 행동 규칙**:
- hook이 차단(exit 2)하면 작업을 멈추지 않는다
- 차단 이유를 확인하고, 원인을 수정한 뒤 즉시 재시도한다
- 차단 로그는 hook이 `trail/incidents/blocks.log`에 자동 기록한다
- 같은 위반 2회 누적 시 `incidents-to-rule` 실행을 권장받는다
- 같은 위반 3회 누적 시 `incidents-to-agent` 실행을 권장받는다
