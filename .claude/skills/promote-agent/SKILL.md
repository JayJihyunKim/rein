---
name: promote-agent
description: 에이전트 후보를 정식 에이전트로 승격. 사람 승인 이후에만 실행.
triggers:
  - incidents-to-agent가 후보를 만들고 사람 승인 요청 시점
  - 상시 실행 금지 (승격 단계 전용)
---

# Skill: promote-agent

> ⚠️ 사람이 승인을 요청한 시점에만 실행한다.

## 입력
- `trail/agent-candidates/{name}.md`

## 실행 절차

### Step 1: 후보 검토
```
[ ] 역할이 한 문장으로 설명되는가?
[ ] 기존 에이전트와 명확히 구분되는가?
[ ] DoD가 명확한가?
[ ] 근거 incidents가 충분한가?
```

### Step 2: 에이전트 파일 초안
`.claude/agents/{name}.md.draft` 생성:
```markdown
---
name: {name}
description: {역할 한 문장}
---
# {name}
> **역할 한 문장**: {역할}
## 담당 작업
## 담당하지 않는 작업
## 완료 기준
```

### Step 3: Registry 초안
```yaml
- name: {name}
  status: pending-activation
  role: "{역할 한 문장}"
  file: ".claude/agents/{name}.md"
```

### Step 4: 사람 승인 후 활성화
```
[ ] .draft 확장자 제거
[ ] registry status: active로 변경
[ ] trail/agent-candidates/{name}.md 완료 표시
[ ] trail/index.md 갱신
```
