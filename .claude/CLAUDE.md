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

## 강제 작업 시퀀스 (hook이 위반을 차단합니다)

아래 순서를 반드시 따른다. Hook이 도구 호출을 차단(exit 2)하므로 건너뛸 수 없다.

1. **READ** `SOT/index.md` — 항상 첫 번째
2. **WRITE** `SOT/dod/dod-[작업명].md` — 소스 코드 편집 전 필수
   → `pre-edit-dod-gate.sh`가 DoD 파일 없으면 Edit/Write/MultiEdit를 차단함
   → DoD는 inbox과 분리. inbox은 "작업 완료 기록", dod는 "작업 시작 전 기준"
3. **IMPLEMENT** — 소스 코드 편집 가능
4. **SELF-REVIEW** — AGENTS.md §5 항목을 명시적으로 답변
5. **WRITE** `SOT/inbox/YYYY-MM-DD-[작업명].md` — 작업 완료 기록
   → 비정상 종료 대비. 세션 종료가 아닌 작업 완료 시점에 즉시 기록
6. **UPDATE** `SOT/index.md` — 세션 종료 전

**차단 시 행동 규칙**:
- hook이 차단(exit 2)하면 작업을 멈추지 않는다
- 차단 이유를 확인하고, 원인을 수정한 뒤 즉시 재시도한다
- 차단 로그는 hook이 `SOT/incidents/blocks.log`에 자동 기록한다
- 같은 위반 2회 누적 시 `incidents-to-rule` 실행을 권장받는다
- 같은 위반 3회 누적 시 `incidents-to-agent` 실행을 권장받는다
