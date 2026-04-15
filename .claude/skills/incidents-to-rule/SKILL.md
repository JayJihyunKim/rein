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

## 입력 포맷

### 신규 자동 생성 포맷 (`auto-*.md`)
```markdown
---
status: "pending"
pattern_hash: "3f4a8b2c9d1e5f6a"
hook: "pre-bash-guard"
reason: "파이프 쉘 실행"
count: "5"
first_seen: "2026-04-10T14:23:10"
last_seen_at: "2026-04-15T09:17:45"
---

# Incident: pre-bash-guard / 파이프 쉘 실행

## 예시 (최근 최대 5건)
...
```

**처리 규칙**:
- `auto-*.md` 파일은 frontmatter `status: pending` 인 것만 처리
- `status: processed` 또는 `status: declined` 는 건너뜀
- 처리 완료 후 해당 파일의 frontmatter `status` 를 `processed` 또는 `declined` 로 갱신

### 레거시 포맷 (`INC-NNN.md`)
```markdown
# INC-001: [제목]
...
```

**처리 규칙**:
- 레거시 `INC-NNN.md` 는 `SOT/incidents/legacy/` 디렉토리에 있을 때만 처리 (opt-in)
- 루트 `SOT/incidents/` 의 frontmatter 없는 `.md` 파일은 무시 (gate 영구 발동 방지)
- 레거시 파일을 처리하려면 `SOT/incidents/legacy/` 로 이동 후 스킬 호출

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
