---
name: incidents-to-rule
description: SOT/incidents/ 파일을 분석해 AGENTS.md에 추가할 규칙 후보를 생성한다
triggers:
  - reviewer가 incident draft 작성 직후 (자동)
  - daily audit 시 (하루 1회)
  - 수동: "최근 incidents를 보고 규칙 후보 돌려줘"
---

# Skill: incidents-to-rule

## 목적
반복되는 실수와 실패 패턴을 분석해 AGENTS.md에 추가할 규칙 후보를 생성한다.

## 입력
- `SOT/incidents/{target}.md` 또는 `SOT/incidents/` 전체

## 실행 절차

### Step 1: Incident 수집
```
[ ] SOT/incidents/ 전체 파일 목록 확인
[ ] 최신 순 정렬
[ ] 미처리(규칙 미생성) incident 필터링
```

### Step 2: 패턴 분석
```
[ ] 동일 유형의 incident 그룹화
[ ] 2회 이상 반복된 패턴 식별
[ ] 각 패턴의 근본 원인 분석
```

### Step 3: 규칙 후보 생성
```markdown
## 규칙 후보: [패턴 이름]
- 근거: INC-NNN, INC-MMM (반복: N회)
- 추가 위치: AGENTS.md §[섹션] 또는 [언어]/AGENTS.md
- 규칙 초안: > [AGENTS.md에 추가할 규칙 문장]
- 우선순위: HIGH / MEDIUM / LOW
```

## 출력
1. 규칙 후보 목록 (우선순위 순)
2. AGENTS.md 수정 초안
3. SOT/index.md 업데이트

## 완료 기준
```
[ ] 모든 미처리 incident 검토 완료
[ ] 규칙 후보 생성됨 (패턴 발견 시)
[ ] 사람이 검토/승인하도록 안내
[ ] 승인된 규칙은 즉시 AGENTS.md에 추가
```
