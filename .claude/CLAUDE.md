# CLAUDE.md — 진입점

> 이 파일은 매 세션 시작 시 자동으로 로드된다.
> 규칙의 허브 역할을 하며, 하위 파일을 @import로 연결한다.

---

## 로딩 순서

Claude Code는 세션 시작 시 아래 순서로 컨텍스트를 구성한다:

1. 이 파일 (`.claude/CLAUDE.md`) — 자동 로드
2. `/AGENTS.md` — 전역 실행 규칙
3. 작업 디렉토리의 nearest `AGENTS.md` — 언어/프레임워크별 규칙
4. `/SOT/index.md` — 현재 프로젝트 상태 (5~15줄)

작업 유형에 따라 추가 로드:
- 워크플로우: `.claude/workflows/[relevant].md`
- 에이전트: `.claude/agents/[relevant].md`

---

## 규칙 허브

@.claude/rules/code-style.md
@.claude/rules/testing.md
@.claude/rules/security.md

---

## 오케스트레이터

작업 유형 → workflow + agent 조합은 아래 파일 참조:

@.claude/orchestrator.md

---

## SOT 운영 규칙

### 세션 시작 시 (자동 정리)
1. `SOT/index.md` 읽기
2. `SOT/inbox/`에 **어제 이전** 파일이 있으면 → `SOT/daily/YYYY-MM-DD.md`로 압축 요약 → inbox 원본 삭제
3. `SOT/daily/`에 **지난주 이전** 파일이 있으면 → `SOT/weekly/YYYY-WNN.md`로 재요약 → daily 원본 삭제

### 작업 완료 시 (inbox 기록)
- 작업 1개를 완료할 때마다 `SOT/inbox/YYYY-MM-DD-작업명.md`에 기록한다
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
- `SOT/index.md`를 최신 상태로 갱신한다

---

## 중요 원칙 (항상 적용)

- 작업 시작 전 반드시 DoD를 명시한다
- Self-review 없이 작업을 완료로 표시하지 않는다
- 빠뜨린 규칙이 있으면 `SOT/incidents/` 초안을 즉시 작성한다
- `SOT/index.md`는 세션 종료 시 최신 상태로 갱신한다
