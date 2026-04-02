# 규칙 준수 강제화 플랜 — 수정이력

---

## Rev 1 (2026-04-01) — 초안

### Context
- CLAUDE.md/AGENTS.md 규칙 위반 방지를 위한 hook 기반 강제화
- 3계층 전략: Hook(block) + Gate(file) + Prompt(강화)

### 핵심 설계
- hook 3개 → 5개 확장 (2 수정 + 2 신규 + 1 rename)
- `pre-edit-dod-gate.sh`: DoD 파일 없으면 소스 편집 차단
- `task-completed-gate.sh`: inbox 기록 없으면 작업 완료 차단 (TaskCompleted 이벤트)
- `stop-session-gate.sh`: 세션 종료 시 index.md 미갱신 경고 (Stop 이벤트)
- 차단 방식: `{"decision": "block"}` JSON 응답
- DoD 캐시: `/tmp/.claude-dod-verified` (5분 TTL)
- 면제 목록: `.claude/`, `SOT/`, `*.md`, `*.json`, `*.yml` 등
- hook 경로: 상대경로 (`.claude/hooks/...`)

---

## Rev 2 (2026-04-02) — Codex(gpt-5.4) 검토 반영

### 검토에서 발견된 문제 6가지

| # | 문제 | 심각도 | Rev 1 설계 | 실제 동작 |
|---|------|--------|-----------|-----------|
| 1 | 차단 메커니즘 오류 | **치명적** | `{"decision":"block"}` JSON 또는 `exit 1` | `exit 2`만 차단. `exit 1`은 non-blocking error로 통과됨 |
| 2 | `Edit\|Write` 매처 누락 | **높음** | `Edit\|Write`만 매칭 | `MultiEdit` 도구가 별도 존재, Bash로 파일 수정도 안 잡힘 |
| 3 | `TaskCompleted` 트리거 불일치 | **높음** | 모든 작업 완료 시 발생한다고 가정 | `TaskUpdate`로 task 완료 처리할 때만 발생. 일반 작업 흐름에서는 트리거 안 됨 |
| 4 | `Stop` 비정상 종료 미보장 | **중간** | 세션 종료 시 경고 출력 | `Ctrl+C`, 터미널 닫기 등에서 실행 안 됨 |
| 5 | 면제 목록 부정확 | **중간** | `.json`, `.yml` 전체 면제 | package.json, workflow 파일 등 고위험 파일도 면제됨. `.mjs`, `.sql`, `Dockerfile` 등 누락 |
| 6 | 캐시/경로 오염 | **중간** | `/tmp/.claude-dod-verified` 전역 캐시, 상대경로 hook | 프로젝트/세션 간 캐시 오염 가능. cwd 변경 시 hook 경로 깨짐 |

### 변경 사항 요약

#### 차단 메커니즘 변경
- Before: `{"decision":"block"}` JSON 출력 + `exit 0`
- After: stderr에 reason 출력 + `exit 2` (Claude Code 공식 차단 코드)

#### 매처 확장
- Before: `Edit|Write`
- After: `Edit|Write|MultiEdit`

#### TaskCompleted 역할 축소
- Before: inbox 기록 없으면 blocking
- After: 리마인더만 출력 (exit 0). 실제 강제는 CLAUDE.md prompt 계층에서 처리

#### Stop 역할 축소
- Before: index.md 미갱신 경고 (best-effort)
- After: 리마인더만 출력 (exit 0). 비정상 종료 대비는 "작업 완료 시점에 즉시 기록" 규칙으로 대체

#### 면제 목록 재설계
- Before: 확장자 기반 광범위 면제 (*.md, *.json, *.yml)
- After: 경로 기반 면제 (.claude/, SOT/) + 소스 디렉토리 한정 gate (src/, app/, services/, apps/, lib/, components/)

#### 캐시 격리
- Before: `/tmp/.claude-dod-verified`
- After: `/tmp/.claude-dod-$(echo "$CLAUDE_PROJECT_DIR" | md5sum | cut -c1-8)` (프로젝트별 격리)

#### hook 경로 안정화
- Before: `.claude/hooks/pre-bash-guard.sh`
- After: `"$CLAUDE_PROJECT_DIR/.claude/hooks/pre-bash-guard.sh"` 또는 환경변수 미지원 시 상대경로 유지 + cwd 검증 추가

---

## Rev 3 (2026-04-02) — DoD 파일 위치 분리

### 문제
- Rev 2에서 DoD 파일을 `SOT/inbox/dod-*.md`에 저장하도록 설계
- inbox의 원래 용도는 "작업 완료 기록"인데, DoD(작업 시작 전 기준)를 같은 곳에 넣으면 역할이 섞임

### 변경 사항

#### DoD 저장 위치 분리
- Before: `SOT/inbox/dod-[작업명].md`
- After: `SOT/dod/dod-[작업명].md`

#### 근거
- `SOT/inbox/` = 작업 완료 기록 (사후)
- `SOT/dod/` = 작업 시작 기준 (사전)
- 둘 다 SOT "증거 저장소"에 속하지만 시점과 용도가 다름
- 작업 완료 후 inbox 기록과 dod 파일이 짝을 이루는 참조 관계

#### 영향 범위
- `pre-edit-dod-gate.sh`: 검사 경로를 `SOT/dod/dod-*.md`로 변경
- `CLAUDE.md` 강제 시퀀스: Step 2의 경로 변경
- `SOT/dod/.gitkeep` 신규 생성

---

## Rev 4 (2026-04-02) — 차단 후 처리 흐름 추가

### 문제
- Rev 3까지는 "차단"만 있고, 차단 후 어떻게 되는지가 빠져있음
- 차단 후 작업이 멈추면 안 됨 → 수정 후 재시도해야 함
- 차단이 반복되면 학습 루프로 연결되어야 함 (AGENTS.md의 2회→규칙, 3회→에이전트 원칙)

### 추가 사항

#### 1. 차단 후 작업 재개 규칙
- 차단(exit 2) 발생 시 작업을 멈추지 않음
- 차단 이유 확인 → 원인 수정 → 즉시 재시도 → 작업 계속
- CLAUDE.md 강제 시퀀스에 "차단 시 행동 규칙" 명시

#### 2. 차단 로그 자동 기록
- 각 hook의 `exit 2` 직전에 `SOT/incidents/blocks.log`에 한 줄 append
- 포맷: `날짜|hook명|차단 이유|대상 파일`
- 예: `2026-04-02T14:30:00|pre-edit-dod-gate|DoD 파일 미존재|src/auth/rate-limiter.ts`

#### 3. 누적 임계값 → 학습 루프 트리거
- 같은 유형 2회 누적: stderr에 "incidents-to-rule 실행 권장" 메시지 + INC 초안 생성 유도
- 같은 유형 3회 누적: stderr에 "incidents-to-agent 실행 권장" 메시지
- 카운트: `grep -c "hook명" blocks.log`

#### 4. 두 흐름의 관계
- 작업 흐름(즉시): 수정 → 재시도 → 작업 계속
- 학습 흐름(비동기): 로그 누적 → 임계값 도달 시 규칙 승격
- 두 흐름은 독립적. 작업 재개를 학습 완료까지 기다리지 않음

---

## Rev 5 (2026-04-02) — Codex 검토 반영: 미사용 이벤트 활용 + 추가 gate

### 문제
- Rev 4에서 "hook으로 더 강제할 규칙은 거의 없다"고 판단
- Codex(gpt-5.4) 검토 결과: **틀림**. Stop 이벤트, PreToolUse/Bash의 commit gate 등 미활용 메커니즘이 있음

### Codex 피드백 요약
1. Codex 리뷰 강제: git commit 시 review stamp 파일 검사로 hook 차단 **가능**
2. inbox 기록 강제: Stop hook에서 오늘 날짜 inbox 파일 없으면 세션 종료 차단 **가능**
3. index.md 갱신: Stop hook에서 mtime 검사로 정상 종료 시 차단 **가능** (비정상 종료는 불가)

### 추가/변경 사항

#### 1. Codex 리뷰 stamp gate (pre-bash-guard.sh 강화)
- Before: git commit 시 메시지 포맷만 검증
- After: git commit 시 `SOT/dod/.codex-reviewed` stamp 파일 존재 + 1시간 이내 여부 검사
- stamp 없거나 만료 → exit 2 차단
- stamp는 Codex 리뷰 완료 후 `touch SOT/dod/.codex-reviewed`로 생성

#### 2. Stop 이벤트 활용 (stop-session-gate.sh 신규)
- Before: Rev 2에서 "Stop은 비정상 종료 시 미실행이라 사용 안 함"으로 제거
- After: 정상 종료 gate로 복원. 비정상 종료는 한계로 수용
- 검사 항목: 오늘 날짜 inbox 파일 존재 + index.md 오늘 수정 여부
- 미충족 시 exit 2로 세션 종료 차단

#### 3. 적용 후 커버리지 변화
| 규칙 | Rev 4 | Rev 5 | 방식 |
|------|-------|-------|------|
| Codex 리뷰 | ~40% (prompt) | ~85% (stamp gate) | pre-bash-guard |
| inbox 기록 | ~50% (prompt) | ~80% (Stop gate) | stop-session-gate |
| index.md 갱신 | ~40% (prompt) | ~75% (Stop gate) | stop-session-gate |

#### 4. 알려진 한계 (변경 없음)
- 비정상 종료 시 Stop hook 미실행
- stamp를 수동 touch로 우회 가능 (악의적 우회)
- 최종 보장은 git pre-commit hook + CI 필요
