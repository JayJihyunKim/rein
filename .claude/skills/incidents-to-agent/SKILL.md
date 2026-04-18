---
name: incidents-to-agent
description: 반복 실패 패턴을 분석해 새 에이전트 후보를 생성한다
triggers:
  - /incidents-to-rule 스킬이 Step 6 에서 체인 호출 (자동)
  - 수동: "최근 incidents 에서 새 agent 필요성 판단해줘"
---

# Skill: incidents-to-agent

## 목적
rule 로 해결 불가한 반복 실패 패턴을 분석해 전문 에이전트 후보를 생성한다.

## 새 에이전트 감지 기준 (3가지 모두 충족 시만)
1. 동일 작업 유형 기존 에이전트 self-review 실패 **3회 이상**
2. 작업 유형이 **한 문장으로 설명 가능**하고 기존 에이전트와 명확히 구분
3. 기존 에이전트 + 하위 AGENTS.md 조합으로 해결 **불가능**

## 입력
- `trail/incidents/auto-*.md` (status in {pending, processed}, count >= 3)
- 기존 `trail/agent-candidates/<hash>.md` (decision 확인용)

## 실행 절차

### Step 1: 후보 식별
각 auto-*.md 를 순회:
- `count >= 3` 체크
- 기존 candidate `<pattern_hash>.md` 존재? → decision != pending 이면 skip
- 남은 건을 후보 리스트에 추가

candidate stub 생성:
```bash
python3 scripts/rein-mark-agent-candidate.py create \
  --hash <pattern_hash> \
  --source-incident <auto-*.md 파일명> \
  --role-one-liner "<추정 역할 한 문장>"
```

### Step 2: Batch 사용자 결정

후보가 1건 이상이면 한 번의 AskUserQuestion (multiSelect) 호출:
- 질문: "agent 후보로 승격할 건을 선택하세요 (미선택은 declined 처리)"
- 옵션: 후보별로 `<hash> — <role_one_liner> (count=N)`
- 후보 0건이면 이 단계 skip.

### Step 3: 결정 반영

각 후보에 대해:
- 선택됨 → `decide` 서브커맨드로 `approved`
- 선택 안 됨 → `decide` 서브커맨드로 `declined`

```bash
python3 scripts/rein-mark-agent-candidate.py decide \
  --hash <hash> --decision <approved|declined> \
  --reason "<사람이 제시한 이유>"
```

### Step 4: 검증

approved 후보가 있으면:
- `trail/index.md` 에 "agent-candidates 승격 대기" 한 줄 추가
- 사용자에게 "다음 단계: `/promote-agent <hash>` 로 정식 에이전트 초안 작성" 안내

## 재평가 (opt-in)

기존 declined 후보를 다시 검토하려면 수동으로 해당 파일의 `decision` 을 `pending`
으로 편집한 뒤 본 스킬 재실행.

## 완료 기준
```
[ ] 식별된 후보 모두 candidate 파일 생성 (또는 skip)
[ ] 후보 있으면 batch AskUserQuestion 호출 완료
[ ] 각 후보의 decision 갱신 (approved/declined)
[ ] approved 건은 index.md 에 반영
```

## 주의
- 에이전트 수 증가 = 조정 비용 + 토큰 비용 + 충돌 위험
- 불확실하면 에이전트 생성보다 규칙 추가 (/incidents-to-rule) 를 선택
- 본 스킬은 사람의 최종 승인 없이 에이전트를 활성화하지 않는다 (`/promote-agent` 전용)
