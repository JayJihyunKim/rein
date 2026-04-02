# 규칙 준수 강제화 플랜 (Rev 4)

> 수정이력: [hook-enforcement-revisions.md](hook-enforcement-revisions.md)

## Context

CLAUDE.md와 AGENTS.md에 규칙이 잘 정의되어 있지만, 현재 대부분이 "텍스트 권고"에 불과하여 Claude가 위반할 수 있다. 기존 hook 3개 중 **실제로 차단하는 것은 0개** (pre-bash-guard도 `exit 1`을 사용하여 non-blocking).

**목표**: 최소한의 hook 추가로 고영향 규칙을 기계적으로 강제한다.

---

## 핵심 전략: 3계층 강제화

| 계층 | 방식 | 적용 대상 |
|------|------|-----------|
| **Hook (block)** | `exit 2`로 도구 호출을 차단 | 커밋 포맷, 시크릿 스캔, .env 커밋 방지, DoD gate |
| **Gate (file)** | 특정 파일이 존재해야 다음 단계 허용 | DoD 작성 → 소스 편집 허용 |
| **Prompt (강화)** | CLAUDE.md에 "hook이 block한다"고 명시 | Self-review, inbox 기록, SOT 압축, 테스트 커버리지 |

> 차단 메커니즘: Claude Code에서 `exit 2` = 차단, `exit 1` = non-blocking error (통과됨), `exit 0` = proceed

---

## 변경 대상 파일 (4개 수정 + 1개 신규)

| 파일 | 작업 |
|------|------|
| `.claude/hooks/pre-bash-guard.sh` | **수정** — 커밋 포맷 검증 + .env 차단 + exit 코드 수정 |
| `.claude/hooks/post-edit-lint.sh` | **수정** — 시크릿 스캔 + console.log 감지 추가 |
| `.claude/hooks/pre-edit-dod-gate.sh` | **신규** — DoD 파일 없으면 소스 편집 차단 |
| `.claude/hooks/task-completed-incident.sh` | **수정** — 리마인더 유지 (blocking 아님) |
| `.claude/settings.json` | **수정** — 새 hook 등록 + 매처 확장 |
| `.claude/CLAUDE.md` | **수정** — 강제 시퀀스 섹션 추가 |

> Rev 1 대비 변경: `stop-session-gate.sh` 삭제 (Stop 이벤트가 비정상 종료 시 미실행), `task-completed-gate.sh` blocking → 리마인더로 축소

---

## 구현 상세

### 1. `pre-bash-guard.sh` 강화

**기존 문제**: `exit 1` 사용 → 실제로 차단하지 않음
**수정**: 모든 차단을 `exit 2`로 통일

추가 검증:
- `git commit` 감지 → 메시지가 `^(feat|fix|docs|refactor|test|chore): .+` 패턴인지 검증
  - `-m "..."` 뿐 아니라 `--message "..."` 도 처리
  - merge/rebase commit은 면제
- `git add` 감지 → `.env` 관련 차단
  - `git add .`, `git add -A`, `git add .env*`, `git add -f .env` 모두 포함
  - `git commit -am` 도 감지

차단 시:
```bash
echo "BLOCKED: 커밋 메시지 형식이 올바르지 않습니다. 형식: [type]: [설명]" >&2
exit 2
```

### 2. `post-edit-lint.sh` 강화

추가 검증 (warn만, block 아님):
- 편집된 파일이 test 디렉토리 밖이면:
  - `(api[_-]?key|secret|password|token)\s*[:=]\s*["'][^"']{8,}` 패턴 grep → stderr 경고
  - `.ts/.tsx/.js/.jsx` 파일에서 `console.log` → stderr 경고
- `exit 0` 유지 (사후 피드백 목적, 차단은 부적절)

### 3. `pre-edit-dod-gate.sh` 신규 생성

**이벤트**: PreToolUse, 매처: `Edit|Write|MultiEdit`

로직:
1. stdin에서 `tool_input.file_path` 추출 (jq 또는 grep)
2. **경로 기반 면제**: `.claude/`, `SOT/` 하위 파일 → `exit 0`
3. **소스 디렉토리 한정 gate**: 아래 경로 내 파일만 검사
   - `src/`, `app/`, `services/`, `apps/`, `lib/`, `components/`, `hooks/`, `store/`, `types/`
   - 위 경로 밖이면 → `exit 0`
4. 소스 파일이면: `SOT/dod/dod-*.md`가 최근 4시간 내 존재하는지 확인
5. 없으면 → stderr에 이유 출력 + `exit 2`
6. 있으면 → `exit 0`

**캐시**: 프로젝트별 격리
```bash
CACHE="/tmp/.claude-dod-$(echo "${CLAUDE_PROJECT_DIR:-$(pwd)}" | md5 -q | cut -c1-8)"
```
- TTL: 5분
- 첫 확인 통과 후 캐시 생성, 이후 stat 비교만

**성능**: edit-heavy turn에서도 `stat` 1회 (캐시 히트 시). 캐시 미스 시 `find` 1회.

### 4. `task-completed-incident.sh` 유지 (blocking 아님)

**Rev 1에서 변경**: blocking gate → 리마인더로 축소

이유: `TaskCompleted` 이벤트는 `TaskUpdate`로 task를 완료 처리할 때만 트리거됨. 일반 작업 흐름에서는 발생하지 않으므로 gate로 신뢰할 수 없음.

동작:
- 기존 리마인더 메시지 유지 + inbox 기록 여부 확인 추가
- `exit 0` (non-blocking)
- 실제 강제는 CLAUDE.md prompt 계층에서 처리

### 5. `settings.json` 변경

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": ".claude/hooks/pre-bash-guard.sh"}]
    },
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [{"type": "command", "command": ".claude/hooks/pre-edit-dod-gate.sh"}]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [{"type": "command", "command": ".claude/hooks/post-edit-lint.sh"}]
    }
  ],
  "TaskCompleted": [
    {
      "hooks": [{"type": "command", "command": ".claude/hooks/task-completed-incident.sh"}]
    }
  ]
}
```

> Rev 1 대비 변경: `Stop` 이벤트 제거, 매처에 `MultiEdit` 추가

### 6. `CLAUDE.md` 강제 시퀀스 섹션

기존 "중요 원칙" 섹션을 아래로 교체:

```markdown
## 강제 작업 시퀀스 (hook이 위반을 차단합니다)

아래 순서를 반드시 따른다. Hook이 도구 호출을 차단하므로 건너뛸 수 없다.

1. **READ** `SOT/index.md` — 항상 첫 번째
2. **WRITE** `SOT/dod/dod-[작업명].md` — 소스 코드 편집 전 필수
   → `pre-edit-dod-gate.sh`가 DoD 파일 없으면 Edit/Write/MultiEdit를 차단함 (exit 2)
   → DoD는 inbox과 분리. inbox은 "작업 완료 기록", dod는 "작업 시작 전 기준"
3. **IMPLEMENT** — 소스 코드 편집 가능
4. **SELF-REVIEW** — AGENTS.md §5 항목을 명시적으로 답변
5. **WRITE** `SOT/inbox/YYYY-MM-DD-[작업명].md` — 작업 완료 기록
   → 비정상 종료 대비. 세션 종료가 아닌 작업 완료 시점에 즉시 기록
6. **UPDATE** `SOT/index.md` — 세션 종료 전

**차단 시 행동 규칙**:
- hook이 차단(exit 2)하면 작업을 멈추지 않는다
- 차단 이유를 확인하고, 원인을 수정한 뒤 즉시 재시도한다
- 차단 로그는 hook이 자동 기록하므로 별도 조치 불필요
```

---

## 적용 후 예상 효과

| 규칙 | Before | After | 방식 | 비고 |
|------|--------|-------|------|------|
| DoD 먼저 | 0% | ~85% | pre-edit-dod-gate (exit 2) | MultiEdit 포함, Bash 편집은 미커버 |
| 커밋 메시지 포맷 | 0% | ~95% | pre-bash-guard (exit 2) | merge/rebase 면제 |
| 시크릿 하드코딩 방지 | ~30% | ~80% | post-edit-lint (warn) | 사후 피드백, 차단 아님 |
| console.log 방지 | ~50% | ~90% | post-edit-lint (warn) | eslint 연계 |
| .env 커밋 방지 | ~70% | ~95% | pre-bash-guard (exit 2) | -f, -am 포함 |
| inbox 기록 | 0% | ~50% | CLAUDE.md prompt | hook 강제 불가, prompt 의존 |
| index.md 갱신 | 0% | ~40% | CLAUDE.md prompt | hook 강제 불가, prompt 의존 |
| Self-review | 0% | ~40% | CLAUDE.md prompt | 기계적 검증 불가 |

> Rev 1 대비 변경: inbox 기록/index.md 갱신의 예상 효과를 현실적으로 하향 (hook으로 강제 불가하므로)

---

## 차단 후 처리: 작업 재개 + 학습 루프

hook이 `exit 2`로 차단하면, 두 가지가 **동시에** 진행된다:

### 작업 흐름 (즉시)

```
차단 발생
  ↓
1. 차단 이유 확인 (stderr 메시지)
2. 원인 수정 (DoD 작성, 커밋 메시지 수정 등)
3. 규칙을 준수하여 동일 작업 재시도
4. 통과 → 작업 계속 진행
```

hook이 차단만 하고 작업을 중단시키지 않는다. Claude는 차단 이유를 보고 스스로 수정한 뒤 재시도한다.

### 학습 흐름 (비동기 누적)

```
차단 발생
  ↓
hook이 차단 로그를 자동 기록:
  SOT/incidents/blocks.log에 한 줄 append
  (날짜, hook명, 차단 이유, 대상 파일)
  ↓
같은 유형 2회 누적:
  → stderr에 "동일 위반 2회. incidents-to-rule 실행 권장" 메시지 출력
  → SOT/incidents/INC-NNN.md 초안 자동 생성
  → AGENTS.md에 규칙 추가 검토
  ↓
같은 유형 3회 누적:
  → stderr에 "동일 위반 3회. incidents-to-agent 실행 권장" 메시지 출력
  → 에이전트 후보 생성 검토
```

### 차단 로그 포맷 (blocks.log)

```
2026-04-02T14:30:00|pre-edit-dod-gate|DoD 파일 미존재|src/auth/rate-limiter.ts
2026-04-02T14:35:00|pre-bash-guard|커밋 메시지 포맷 위반|git commit -m "수정"
```

### 구현 위치

- 각 hook 스크립트의 `exit 2` 직전에 blocks.log append 로직 추가
- 누적 카운트는 `grep -c "hook명" blocks.log`로 계산
- 2회/3회 임계값 도달 시 stderr 메시지 추가 출력 (차단과 별개)

---

## 알려진 한계

1. **Bash를 통한 파일 수정은 DoD gate를 우회함** — `sed`, `echo >`, `cat <<EOF` 등. pre-bash-guard에서 파일 쓰기 패턴을 감지할 수 있으나, 오탐이 많아 실용적이지 않음
2. **TaskCompleted가 일반 작업 흐름에서 트리거되지 않음** — inbox 기록 강제는 prompt 계층에만 의존
3. **Stop 이벤트가 비정상 종료 시 실행되지 않음** — 세션 종료 시 index.md 갱신은 보장할 수 없음. "작업 완료 시점에 즉시 기록"으로 대응
4. **post-edit-lint의 --fix가 Claude 문맥과 어긋날 수 있음** — eslint/ruff의 자동 수정이 Claude가 모르는 사이에 파일을 변경

---

## 검증 방법

1. **exit 코드 테스트**: 기존 pre-bash-guard의 `exit 1` → `exit 2` 변경 후, 위험 명령이 실제로 차단되는지 확인
2. **DoD gate 테스트**: DoD 파일 없이 `src/` 내 파일 편집 시도 → 차단 확인 / `.claude/` 파일 편집 → 통과 확인
3. **커밋 포맷 테스트**: `git commit -m "잘못된 형식"` → 차단 / `git commit -m "feat: 올바른"` → 통과
4. **MultiEdit 커버리지 테스트**: MultiEdit 도구로 소스 편집 시도 → DoD gate 동작 확인
5. **시크릿 스캔 테스트**: `api_key = "sk-1234567890"` 포함 파일 편집 → 경고 메시지 확인
6. **캐시 격리 테스트**: 다른 프로젝트 디렉토리에서 캐시가 공유되지 않는지 확인

---

## 구현 순서

Phase 1: exit 코드 수정 (pre-bash-guard.sh의 `exit 1` → `exit 2`)
Phase 2: pre-bash-guard 기능 추가 (커밋 포맷, .env 차단)
Phase 3: pre-edit-dod-gate.sh 신규 생성 + settings.json 매처 등록
Phase 4: post-edit-lint.sh 강화 (시크릿 스캔, console.log)
Phase 5: 차단 로그 + 학습 루프 (blocks.log append, 누적 카운트, 임계값 메시지)
Phase 6: CLAUDE.md 강제 시퀀스 섹션 추가 (차단 후 재개 규칙 포함)
Phase 7: 테스트 실행
