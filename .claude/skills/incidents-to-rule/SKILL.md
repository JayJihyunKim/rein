---
name: incidents-to-rule
description: trail/incidents/ 파일을 분석해 AGENTS.md에 추가할 규칙 후보를 생성한다
triggers:
  - reviewer가 incident draft 작성 직후 (자동)
  - daily audit 시 (하루 1회)
  - 수동: "최근 incidents를 보고 규칙 후보 돌려줘"
---

# Skill: incidents-to-rule

## 목적
반복되는 실수와 실패 패턴을 분석해 AGENTS.md에 추가할 규칙 후보를 생성한다.

## 입력
- `trail/incidents/{target}.md` 또는 `trail/incidents/` 전체

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
- 레거시 `INC-NNN.md` 는 `trail/incidents/legacy/` 디렉토리에 있을 때만 처리 (opt-in)
- 루트 `trail/incidents/` 의 frontmatter 없는 `.md` 파일은 무시 (gate 영구 발동 방지)
- 레거시 파일을 처리하려면 `trail/incidents/legacy/` 로 이동 후 스킬 호출

## 실행 절차

### Step 1: Incident 수집
```
[ ] trail/incidents/ 전체 파일 목록 확인
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

### Step 4: 사람 결정 수집 + status 갱신 (필수)

각 pending `auto-*.md` 에 대해:

1. AskUserQuestion 으로 "승격/거부/보류" 결정을 받는다
2. 결정이 "승격" 인 경우: AGENTS.md 에 규칙을 추가한 뒤 아래 helper 로 `processed` 마킹
3. 결정이 "거부" 인 경우: 이유만 기록하고 `declined` 마킹
4. 결정이 "보류" 인 경우: `status` 는 그대로 두고 다음 세션으로 이월 (gate 는 계속 차단됨)

**helper 호출** (Bash):
```bash
python3 scripts/rein-mark-incident-processed.py \
  trail/incidents/auto-<hook>-<hash>[-N].md \
  <processed|declined> \
  --reason "<사람이 승인한 규칙 요약 or 거부 이유>"
```

helper 는 frontmatter 의 `status` 만 atomic 하게 갱신하고 `## 승격 이력` 섹션에 timestamp + reason 한 줄을 append 한다. **수동으로 frontmatter 를 편집하지 말고 반드시 이 helper 를 사용한다** (incident 파일은 `trail/` 경로에 있어 DoD gate 면제이지만, format drift 방지).

### Step 4b: "보류" 선택 시 deferred stamp 생성 (필수)

사용자가 특정 pending 에 대해 "보류" 를 선택한 경우, 현재 세션 내 재차단을 방지하기
위해 즉시 stamp 를 생성:

```bash
touch trail/dod/.incident-decision-deferred
```

stamp 는 세션 스코프. `session-start-load-trail.sh` 가 다음 세션 시작 시
무조건 삭제하므로 다음 세션에서 재질문됨.

보류가 여러 건이어도 stamp 1개로 충분. 여러 번 touch 는 noop.

### Step 5: 검증

`--count-pending` 이 감소했는지 확인:
```bash
python3 scripts/rein-aggregate-incidents.py --count-pending
```

모두 처리되어 `0` 이 나오면 다음 source 편집 시 `pre-edit-dod-gate.sh` 의 self-heal 이 `.incident-review-pending` stamp 를 자동 제거한다.

### Step 6: /incidents-to-agent 스킬 호출 (필수)

`--count-pending` 결과와 무관하게, 본 스킬 완료 후 반드시 `/incidents-to-agent`
스킬을 호출한다. 이유:

- rule 로 승격된 건 중 일부는 agent 로도 올려야 할 수 있음 (3회↑ 반복 패턴)
- Stop hook 이 양쪽 스킬 체인 실행을 전제로 block 하므로, 본 스킬만으로는 loop 해소 불가

체인 호출 방법:
```
/incidents-to-agent
```

## 출력
1. 규칙 후보 목록 (우선순위 순)
2. AGENTS.md 수정 초안 (승격된 규칙만)
3. trail/index.md 업데이트

## 완료 기준
```
[ ] 모든 미처리 incident 검토 완료
[ ] 규칙 후보 생성됨 (패턴 발견 시)
[ ] 사람이 검토/승인하도록 AskUserQuestion 으로 결정 수집
[ ] 승인된 규칙은 즉시 AGENTS.md 에 추가
[ ] 각 pending incident 의 status 를 helper 로 processed/declined 갱신
[ ] --count-pending 결과가 0 이거나, 남은 건은 의식적 "보류"
[ ] Step 6 /incidents-to-agent 스킬 호출 완료
[ ] 보류 건이 있었다면 .incident-decision-deferred stamp 생성 확인
```
