# Orchestrator — 작업 유형별 라우팅 기준

> 작업을 시작할 때 이 파일을 참조해 올바른 workflow + agent 조합을 선택한다.

---

## 라우팅 테이블

| 작업 유형 | Workflow | Agent | 하위 AGENTS.md |
|----------|----------|-------|----------------|
| 새 기능 추가 | `add-feature.md` | `feature-builder` | 해당 언어 디렉토리 |
| 버그 수정 | `fix-bug.md` | `feature-builder` | 해당 언어 디렉토리 |
| 새 서비스 생성 | `build-from-scratch.md` | `service-builder` | 해당 언어 디렉토리 |
| 기술 조사 | `research-task.md` | `researcher` | — |
| 코드 리뷰 | — | `reviewer` | — |
| 문서 작성 | — | `docs-writer` | — |

---

## 작업 유형 판단 기준

### 새 기능 추가 (`add-feature`)
- 기존 서비스/모듈에 새 기능을 추가하는 경우
- 기존 코드를 수정하거나 확장하는 경우

### 버그 수정 (`fix-bug`)
- 예상과 다른 동작을 수정하는 경우
- 에러/예외 처리가 잘못된 경우

### 새 서비스 생성 (`build-from-scratch`)
- 새로운 서비스, 모듈, 앱을 처음부터 만드는 경우
- 디렉토리 구조 자체를 새로 설계하는 경우

### 기술 조사 (`research-task`)
- 라이브러리/프레임워크 비교가 필요한 경우
- 아키텍처 결정을 위한 조사가 필요한 경우

---

## Agent Teams 활용 기준

아래 조건을 모두 충족할 때 Agent Teams(병렬 실행)를 고려한다:
1. 작업이 독립적인 두 개 이상의 서브태스크로 분리 가능
2. 서브태스크 간 의존성이 없거나 명확히 분리됨
3. 컨텍스트 창이 절반 이상 사용된 경우 (컨텍스트 분리 목적)

Agent Teams 사용 시:
- 각 서브 에이전트에게 독립적인 DoD를 부여한다
- 서브 에이전트 결과를 메인 컨텍스트로 가져올 때는 요약본만 포함한다
- 병렬 결과 머지 시 `reviewer` 에이전트가 최종 검토한다

---

## 에이전트 추가 파이프라인

```
SOT/incidents/ 축적 (동일 유형 3회 이상)
        ↓
incidents-to-agent SKILL 실행
        ↓ (기준 충족 시)
SOT/agent-candidates/{name}.md 생성
        ↓
promote-agent SKILL 실행
        ↓
.claude/agents/{name}.md.draft 생성 + registry 업데이트 초안
        ↓
Human Approval (역할 1문장 + 중복 없음 + DoD 명확)
        ↓
활성화: .draft 제거 + registry 활성화
```
