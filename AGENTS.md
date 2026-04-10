# AGENTS.md — 전역 실행 규칙

> **이 파일은 Source of Truth다.**
> 결과가 나쁘면 출력물이 아니라 이 파일을 수정한다.
> 같은 문제가 2번 반복되면 즉시 이 파일에 규칙을 추가한다.

---

## 1. 핵심 원칙

1. **DoD 먼저**: 작업 시작 전 Definition of Done을 반드시 명시한다
2. **규칙 수정**: 결과가 나쁘면 출력물 재요청이 아닌 이 파일을 수정한다
3. **2회 반복 → 규칙 승격**: 같은 문제가 2회 반복되면 즉시 AGENTS.md 규칙으로 추가한다
4. **역할 경계**: 에이전트는 역할이 한 문장으로 설명될 때만 분리한다
5. **최소 에이전트**: 새 에이전트보다 기존 에이전트 + 하위 AGENTS.md 조합을 먼저 시도한다

---

## 2. 작업 시작 전 체크리스트

모든 작업을 시작하기 전 아래를 순서대로 수행한다:

```
[ ] SOT/index.md 읽기 — 현재 프로젝트 상태 파악
[ ] 해당 workflow 파일 읽기 — 절차 확인
[ ] 해당 agent 파일 읽기 — 역할/완료 기준 확인
[ ] Definition of Done 명시 — 작업 완료 기준 먼저 작성
[ ] 변경 대상 파일 목록 작성
[ ] 10줄 이내 작업 계획 작성
```

---

## 3. 상호작용 규칙

- **질문 후 답변 대기**: "~할까요?", "진행할까?" 등 확인 질문을 던졌으면 사용자 답변을 받기 전까지 실행하지 않는다. 질문과 실행이 같은 응답에 공존하면 안 된다.
- **승인 후 실행**: 빌드, 배포, 삭제, push 등 비가역적 작업은 반드시 사용자의 명시적 승인("해", "진행해", "좋아") 후에만 실행한다.

---

## 4. 코딩 규칙

### 일반
- 함수는 단일 책임 원칙을 따른다 (한 함수 = 한 가지 일)
- 함수/변수명은 행동을 설명하는 동사형으로 작성한다 (`getUserById`, not `user`)
- 매직 넘버/문자열은 상수로 분리한다
- 에러 처리는 생략하지 않는다 — 모든 외부 I/O는 try/catch 또는 에러 반환 처리
- 주석은 "왜(why)"를 설명한다. "무엇(what)"은 코드가 설명한다

### 파일 구조
- 파일 하나 = 하나의 책임 (컴포넌트, 유틸, 서비스 등 혼합 금지)
- 임포트 순서: 외부 라이브러리 → 내부 모듈 → 상대 경로 순

### 금지 패턴
- `console.log` 운영 코드에 방치 금지 (디버그용은 작업 완료 전 제거)
- `any` 타입 사용 금지 (TypeScript)
- 하드코딩된 URL/API 키 금지 — 환경변수 사용
- `.env` 파일 커밋 금지

---

## 5. 완료 기준 (Definition of Done)

작업이 완료되었다고 판단하려면 아래를 모두 충족해야 한다:

```
[ ] 기능이 요구사항대로 동작함
[ ] 기존 테스트가 모두 통과함
[ ] 신규 기능에 대한 테스트가 작성됨
[ ] lint/format 검사 통과
[ ] Codex 코드 리뷰 실행 및 수정사항 반영 완료
[ ] 관련 문서(주석, README) 업데이트
[ ] Self-review 완료 — 내가 리뷰어라면 승인할 수 있는가?
[ ] 빠뜨린 규칙이 있으면 SOT/incidents/ 초안 작성
```

---

## 5-1. 코드 리뷰 필수 규칙 (sub-agent 포함)

- 소스 코드(.ts, .py, .sh, .json 등)를 수정한 **모든 에이전트(sub-agent 포함)**는 작업 완료 전 반드시 codex 리뷰를 실행한다
- codex 리뷰: `/codex` 스킬 호출 → `SOT/dod/.codex-reviewed` stamp 생성
- codex 실패(에러/타임아웃) 시에만 sonnet 폴백 허용 — 그 외 사유로 sonnet 리뷰 대체 금지
- sonnet 폴백 시 stamp에 `fallback_reason` 기록 필수
- 리뷰 없이 결과를 반환하거나 테스트/커밋 시도 시 hook이 차단함 (exit 2)
- 리뷰 후 추가 코드 수정 시 `.review-pending` 재생성 → 재리뷰 필수

### 리뷰 에스컬레이션 규칙
- **High 이슈** → 수정 후 codex 재리뷰 (필수)
- **Medium만 + 수정 3줄 초과** → codex 재리뷰
- **Medium만 + 수정 3줄 이하** → sonnet 셀프리뷰 (stamp에 `reviewer: self-review`)
- **Low만** → sonnet 셀프리뷰
- **3회차에도 High 잔존** → 사람에게 에스컬레이션 (stamp에 `resolution: escalated_to_human`)

---

## 6. Self-review 기준

코드 제출 전 스스로 아래를 점검한다:

- [ ] 변경 범위가 DoD와 일치하는가? (범위 초과 금지)
- [ ] 엣지 케이스가 처리되었는가?
- [ ] 에러 메시지가 사용자/운영자에게 충분한 정보를 주는가?
- [ ] 이 변경으로 인해 깨질 수 있는 다른 부분이 있는가?
- [ ] 규칙 파일에 없는 패턴을 새로 사용했다면 이유를 주석으로 남겼는가?

---

## 7. Incident 기록 규칙

- 같은 실수가 **2회 이상** 반복되면 즉시 `SOT/incidents/INC-NNN.md` 작성
- Incident 작성 후 `incidents-to-rule` skill 실행 → 규칙 후보 생성
- **3회 이상** 반복되면 `incidents-to-agent` skill 실행 → 에이전트 후보 감지

Incident 파일 포맷:
```markdown
# INC-NNN: [문제 요약]
- 날짜: YYYY-MM-DD
- 작업: [어떤 작업 중 발생]
- 증상: [무슨 일이 일어났는가]
- 원인: [왜 발생했는가]
- 해결: [어떻게 해결했는가]
- 규칙 후보: [AGENTS.md에 추가할 규칙 초안]
```

---

## 8. 에이전트 운영 원칙

### 역할 목록
| 에이전트 | 역할 | 파일 |
|---------|------|------|
| feature-builder | 신규 기능 구현 전담 | `.claude/agents/feature-builder.md` |
| service-builder | 새 서비스 초기 구조 생성 전담 | `.claude/agents/service-builder.md` |
| reviewer | 코드리뷰 + incident 초안 작성 전담 | `.claude/agents/reviewer.md` |
| researcher | 기술 조사 및 문서 수집 전담 | `.claude/agents/researcher.md` |
| docs-writer | 문서화 및 changelog 작성 전담 | `.claude/agents/docs-writer.md` |
| security-reviewer | 보안 취약점 탐지 및 수정 제안 전담 | `.claude/agents/security-reviewer.md` |

### 새 에이전트 추가 기준 (3가지 모두 충족 시만)
1. 동일 작업 유형에서 기존 에이전트의 self-review 실패가 **3회 이상** 반복
2. 작업 유형이 **한 문장으로 설명 가능**하고 기존 에이전트와 명확히 구분됨
3. `promote-agent` 프로세스를 거쳐 **사람이 승인**함

### 언어별 에이전트를 만들지 않는 이유
에이전트 분리 기준은 "언어가 다른가"가 아니라 "역할과 완료 기준이 다른가"이다.
- Python → `feature-builder` + `services/api/AGENTS.md`에 언어별 규칙 추가
- TypeScript → `feature-builder` + `apps/web/AGENTS.md`에 언어별 규칙 추가

---

## 9. SOT 운영 규칙

- `SOT/index.md`: 프로젝트 현재 상태 **5~15줄** 유지 (매 세션 시작 시 읽는 유일한 상태 파일)
- `SOT/inbox/`: 세션 원본 로그 저장 (daily에서 요약 후 삭제)
- `SOT/daily/`: 하루 1회 압축 요약
- `SOT/weekly/`: 주 1회 재요약
- `SOT/decisions/`: 확정된 기술/운영 결정 (`DEC-NNN.md`)
- `SOT/incidents/`: 실패 사례, 반복 문제 (`INC-NNN.md`)

**SOT 파일 규칙**
- 한 파일 = 한 사건, 한 결정, 한 회고
- `SOT/inbox/`를 실행 컨텍스트에 직접 넣지 않는다
- 같은 문제가 2회 이상 반복되면 SOT에만 두지 말고 즉시 이 파일에 규칙 추가

---

## 10. 컨텍스트 절감 전략

- 작업 시 `SOT/index.md`만 읽고, 관련 incidents/decisions는 필요 시만 파일명 지정
- 이 파일(AGENTS.md)은 숫자가 아닌 **원칙만** 유지 (숫자/상태는 SOT에)
- 세션이 길어질 때: "현재 상태 요약해줘" 요청 후 `SOT/index.md` 갱신
- Agent Teams 활용 시: 각 서브 에이전트는 독립 컨텍스트로 실행하여 메인 컨텍스트 보호

---

## 11. Git 규칙

- 커밋 메시지: `[type]: [설명]` 형식
  - type: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
- PR 단위: 하나의 기능 또는 버그 수정 (여러 기능 혼합 금지)
- 머지 전 self-review 완료 필수
- `.env`, `secrets/`, 개인 인증 정보 커밋 절대 금지
