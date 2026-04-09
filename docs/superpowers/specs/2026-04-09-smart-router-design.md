# Smart Router — DoD 기반 지능형 스킬/에이전트/MCP 자동 라우팅

> 작성일: 2026-04-09
> 상태: 승인됨 (brainstorming 완료)

---

## 1. 목표

DoD 작성 시점에 작업 내용을 분석하여 최적의 **에이전트 + 스킬 + MCP** 조합을 자동으로 추천하고, 사용자 확인 후 진행한다.

### 핵심 요구사항

- 라우팅 대상: 레이어 1(프로젝트 에이전트) + 레이어 3(SuperClaude 스킬) + 레이어 4(MCP 서버)
- 판단 근거: DoD 내용, 파일 확장자/경로, 사용자 메시지 키워드, SOT/index.md 상태
- 사용자 확인: 항상 조합을 제시하고 승인 후 진행
- 실패 처리: 확인 단계 즉시 수정 + incidents 기반 사후 학습
- 메타데이터 자동 생성: 스킬 description 파싱으로 초기화, 새 스킬 추가 시 자동 감지

---

## 2. 아키텍처

```
사용자 메시지
    |
    v
DoD 작성 (기존 흐름)
    |
    v
+-------------------------------+
|  Smart Router                 |
|                               |
|  입력:                         |
|  +-- DoD 파일 내용             |
|  +-- 대상 파일 확장자/경로      |
|  +-- 사용자 메시지 키워드       |
|  +-- SOT/index.md 상태        |
|                               |
|  처리:                         |
|  +-- 메타데이터 레지스트리 로드  |
|  +-- 매칭 점수 계산            |
|  +-- 상위 조합 추천            |
+---------------+---------------+
                |
                v
       사용자 확인/수정
                |
                v
           작업 실행
                |
                v
       결과 피드백 -> 메타데이터 보정
```

### 핵심 컴포넌트

| 컴포넌트 | 역할 |
|---------|------|
| 메타데이터 레지스트리 | 각 에이전트/스킬/MCP의 매칭 조건 저장 |
| 라우터 로직 | DoD 분석 -> 레지스트리 매칭 -> 조합 추천 |
| 피드백 루프 | 사용자 수정/incidents 반영 -> 메타데이터 보정 |

---

## 3. 메타데이터 레지스트리

### 저장 위치

```
.claude/router/
+-- registry.yaml          # 전체 메타데이터 (자동 생성 + 보정 결과)
+-- overrides.yaml         # 사용자가 수정한 내용만 별도 보관
+-- feedback-log.yaml      # 라우팅 결과 피드백 이력
```

### 메타데이터 스키마

```yaml
- id: "superpowers:test-driven-development"
  layer: skill                    # agent | skill | mcp
  keywords: [테스트, TDD, test, 단위테스트, coverage]
  file_patterns: ["*.test.*", "*.spec.*", "tests/**"]
  task_types: [add-feature, fix-bug]
  domains: [backend, frontend, python, typescript]
  priority: 0.8                   # 기본 매칭 가중치 (0~1)
  requires: []                    # 함께 필요한 다른 항목
  conflicts: []                   # 동시 사용 불가 항목
  auto_generated: true            # 자동 생성 여부
  confidence: 0.7                 # 자동 생성 시 신뢰도
```

### 레이어별 등록 대상

| 레이어 | 대상 | 개수 (대략) |
|--------|------|------------|
| agent | feature-builder, service-builder, reviewer, researcher, docs-writer | 5개 |
| skill | SuperClaude 스킬 중 구현/도메인 특화 | ~20개 |
| mcp | Context7, Playwright, Serena, Tavily, Sequential, Stitch | 6개 |

### 프로세스 스킬 제외 목록

아래 스킬은 기존 흐름이 제어하므로 라우팅 대상에서 제외한다:

```yaml
excluded_skills:
  - superpowers:brainstorming
  - superpowers:writing-plans
  - superpowers:executing-plans
  - superpowers:verification-before-completion
  - superpowers:using-superpowers
  - superpowers:using-git-worktrees
  - superpowers:finishing-a-development-branch
  - superpowers:requesting-code-review
  - superpowers:receiving-code-review
  - superpowers:dispatching-parallel-agents
  - superpowers:subagent-driven-development
```

---

## 4. 라우터 로직

### 매칭 점수 계산

```
총점 = (키워드 매칭 x 0.4) + (파일 패턴 매칭 x 0.3) + (작업 유형 매칭 x 0.2) + (SOT 컨텍스트 x 0.1)
```

| 신호 | 가중치 | 예시 |
|------|--------|------|
| 키워드 매칭 | 0.4 | DoD에 "성능 최적화" -> performance-engineer 점수 상승 |
| 파일 패턴 | 0.3 | 대상 파일이 `*.py` -> python-pro, Context7 점수 상승 |
| 작업 유형 | 0.2 | fix-bug 워크플로우 -> systematic-debugging 점수 상승 |
| SOT 컨텍스트 | 0.1 | 현재 진행 중인 작업, 블로커 정보 반영 |

### 조합 생성 규칙

1. **에이전트**: 점수 최상위 1개 선택 (필수)
2. **스킬**: 점수 0.5 이상인 것 중 상위 3개까지 선택
3. **MCP**: 점수 0.5 이상인 것 중 상위 2개까지 선택
4. **conflicts 검사**: 충돌하는 항목 제거
5. **requires 검사**: 필수 의존 항목 추가

### 사용자 확인 출력 형태

```
[라우팅] 작업: "유저 프로필 API 버그 수정"

추천 조합:
  에이전트: feature-builder (fix-bug 워크플로우)
  스킬:    systematic-debugging, python-pro
  MCP:     Context7, Sequential

  근거:
  - DoD 키워드 "버그", "수정" -> fix-bug + systematic-debugging
  - 대상 파일 services/api/users.py -> python-pro + Context7
  - 복합 디버깅 -> Sequential

이 조합으로 진행할까요? (수정하려면 말씀해 주세요)
```

### 사용자 수정 처리

사용자가 조합을 수정하면:
1. 즉시 조합 변경 후 진행
2. `overrides.yaml`에 기록
3. 같은 패턴에서 동일 수정 3회 이상 -> `registry.yaml` 기본 점수 자동 보정

---

## 5. 피드백 루프와 학습

### 피드백 수집 시점

```
작업 시작 --> 사용자 확인에서 수정 발생?
               +-- YES -> overrides.yaml에 즉시 기록
               +-- NO  -> "조합 승인됨" 기록
                          |
                          v
             작업 완료 --> incidents 발생?
                           +-- YES -> feedback-log.yaml에 기록
                           +-- NO  -> 성공 기록 (해당 조합 신뢰도 +0.05)
```

### feedback-log.yaml 형태

```yaml
- date: 2026-04-09
  dod: "dod-fix-user-profile-api.md"
  recommended:
    agent: feature-builder
    skills: [systematic-debugging, python-pro]
    mcp: [Context7, Sequential]
  user_modified:
    removed: [python-pro]
    added: [Playwright]
  outcome: success          # success | partial | failed
  notes: "브라우저 연동 버그라 Playwright가 필요했음"
```

### 자동 보정 규칙

| 조건 | 행동 |
|------|------|
| 같은 패턴에서 동일 수정 3회 | registry.yaml 점수 자동 조정 |
| 특정 조합 성공률 90%+ (5회 이상) | confidence를 0.9로 승격 |
| 특정 조합 실패율 50%+ (3회 이상) | 해당 조합 경고 표시, 대안 우선 추천 |
| 새 스킬 추가 후 첫 5회 사용 | confidence 낮게 시작 (0.5), 점진 상승 |

### 기존 incidents 체계와의 연결

라우팅 실패는 기존 incidents 파이프라인을 그대로 활용한다:

- 2회 반복 -> `incidents-to-rule` -> 라우팅 규칙 보완
- 3회 반복 -> `incidents-to-agent` -> 새 에이전트 필요성 검토

라우팅 관련 피드백은 `feedback-log.yaml`에도 병행 기록한다.

---

## 6. 기존 흐름 통합

### CLAUDE.md 강제 작업 시퀀스 변경

기존 9단계에서 ROUTE 단계를 삽입하여 10단계로 변경:

```
1.  READ    SOT/index.md
2.  WRITE   SOT/dod/dod-[작업명].md
3.  ROUTE   라우터 실행 -> 조합 추천 -> 사용자 확인  (신규)
4.  IMPLEMENT
5.  CODEX REVIEW
6.  FIX
7.  TEST
8.  SELF-REVIEW
9.  WRITE   SOT/inbox/YYYY-MM-DD-[작업명].md
10. UPDATE  SOT/index.md
```

### orchestrator.md 변경

기존 라우팅 테이블은 유지하고, "스마트 라우팅 절차" 섹션을 추가:

```markdown
## 스마트 라우팅 절차

DoD 작성 완료 후, 구현 시작 전에 아래를 수행한다:

1. DoD 파일에서 신호 추출 (키워드, 대상 파일, 작업 유형)
2. SOT/index.md에서 현재 컨텍스트 확인
3. .claude/router/registry.yaml에서 매칭 점수 계산
4. 에이전트 1개 + 스킬 최대 3개 + MCP 최대 2개 조합 추천
5. 사용자에게 조합 제시 및 확인
6. 수정 사항이 있으면 overrides.yaml에 기록
7. 승인된 조합으로 작업 진행
```

### 파일 변경 요약

| 파일 | 변경 유형 | 내용 |
|------|----------|------|
| `.claude/router/registry.yaml` | 신규 | 메타데이터 레지스트리 |
| `.claude/router/overrides.yaml` | 신규 | 사용자 수정 이력 |
| `.claude/router/feedback-log.yaml` | 신규 | 라우팅 결과 피드백 |
| `.claude/orchestrator.md` | 수정 | 스마트 라우팅 절차 추가 |
| `.claude/CLAUDE.md` | 수정 | 강제 시퀀스에 ROUTE 단계 삽입 |
| `AGENTS.md` | 변경 없음 | 기존 유지 |
| `.claude/hooks/*` | 변경 없음 | 기존 유지 |
| `.claude/agents/*` | 변경 없음 | 기존 유지 |
| `.claude/workflows/*` | 변경 없음 | 기존 유지 |

---

## 7. 메타데이터 자동 생성 (초기 부트스트랩)

### 자동 생성 과정

최초 1회 실행하는 init-router 작업:

1. **레이어 1 스캔**: `.claude/agents/*.md` 읽기 -> 역할 설명에서 메타데이터 추출
2. **레이어 3 스캔**: 설치된 SuperClaude 스킬 description 파싱 -> 메타데이터 추출
3. **레이어 4 스캔**: `MCP_*.md` 파일들의 트리거 조건 파싱
4. 추출 결과를 `registry.yaml`에 저장
5. confidence가 0.5 미만인 항목은 경고 표시

### 추출 규칙

| 소스 텍스트 | 추출 대상 | 예시 |
|------------|----------|------|
| "Use when..." / "Use this skill when..." | keywords | "encountering any bug" -> [bug, error, 버그] |
| 파일 확장자 언급 | file_patterns | "React components" -> ["*.tsx", "*.jsx"] |
| "for", "specialized in" | domains | "specialized in Python" -> [python] |
| 기존 orchestrator.md 작업 유형 | task_types | fix-bug, add-feature 등과 매칭 |

### 새 스킬 자동 감지

라우터 실행 시마다:

1. 현재 설치된 스킬 목록 확인
2. `registry.yaml`에 없는 새 스킬 발견 시 -> description 파싱 -> 메타데이터 자동 생성 -> 레지스트리에 추가
3. 사용자에게 "새 스킬 [X]가 감지되어 레지스트리에 추가했습니다" 알림

---

## 8. 제약 사항과 한계

### 라우터가 하지 않는 것

- **프로세스 스킬 제어**: brainstorming, writing-plans 등은 기존 흐름이 관리
- **내장 서브에이전트(레이어 2) 선택**: backend-architect, debugger 등은 라우팅 대상 아님
- **hook 시스템 변경**: 기존 hook은 그대로 유지
- **자동 실행**: 항상 사용자 확인 후 진행 (자동 실행 없음)

### 알려진 한계

- 메타데이터 자동 생성은 description 텍스트 품질에 의존 -> description이 부실한 스킬은 confidence가 낮게 시작
- 복합 작업(Python + Frontend 동시)의 경우 매칭 점수가 분산될 수 있음 -> 사용자 확인 단계에서 보완
- 피드백 학습은 같은 패턴 3회 이상 반복 후 적용 -> 초기에는 수동 수정이 필요할 수 있음
