# Smart Router — DoD 기반 지능형 스킬/에이전트/MCP 자동 라우팅

> 작성일: 2026-04-09
> 상태: 승인됨 (brainstorming 완료)
> 수정: 2026-04-09 — 정적 카탈로그 → 동적 발견 + 학습 캐시 방식으로 전환

---

## 1. 목표

DoD 작성 시점에 작업 내용을 분석하여 최적의 **에이전트 + 스킬 + MCP** 조합을 자동으로 추천하고, 사용자 확인 후 진행한다.

### 핵심 요구사항

- 라우팅 대상: 레이어 1(프로젝트 에이전트) + 레이어 3(SuperClaude 스킬) + 레이어 4(MCP 서버)
- 판단 근거: DoD 내용, 파일 확장자/경로, 사용자 메시지 키워드, SOT/index.md 상태
- 사용자 확인: 항상 조합을 제시하고 승인 후 진행
- 실패 처리: 확인 단계 즉시 수정 + incidents 기반 사후 학습
- 동적 발견: 세션 컨텍스트에서 사용 가능한 스킬/MCP를 동적으로 발견, registry.yaml은 학습 캐���로만 활용

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
|  +-- 세션에서 가용 항목 동적 발견|
|  +-- description 기반 매칭     |
|  +-- 학습 캐시 보정 반영        |
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
       결과 피드백 -> 학습 캐시 보정
```

### 핵심 컴포넌트

| 컴포넌트 | 역할 |
|---------|------|
| 동적 발견 | 세션 컨텍스트에서 사용 가능한 에이전트/스킬/MCP를 실시간 수집 |
| 라우터 로직 | DoD 분석 -> description 기반 매칭 -> 조합 추천 |
| 학습 캐시 (registry.yaml) | 과거 피드백/보정 데이터 저장, 매칭 정확도 점진 개선 |
| 피드백 루프 | 사용자 수정/incidents 반영 -> 학습 캐시 보정 |

---

## 3. 동적 발견과 학습 캐시

### 핵심 원칙

registry.yaml은 사전 등록된 카탈로그가 **아니다.**
사용 가능한 항목은 매 라우팅 시점에 세션 컨텍스트에서 **동적으로 발견**한다.
registry.yaml은 과거 사용 피드백에서 축적된 **학습 데이터(보정값)**만 저장한다.

### 동적 발견 소스

| 레이어 | 발견 방법 | 소스 |
|--------|----------|------|
| 프로젝트 에이전트 | `.claude/agents/*.md` 파일 스캔 | 로컬 프로젝트 |
| 스킬 | 세션 system-reminder의 `skills are available` 목록 | 로컬 + 글로벌 플러그인 자동 병합 |
| MCP | 세션 system-reminder의 `deferred tools` 목록에서 `mcp__서버명__` 접두사 | 로컬 + 글로벌 설정 자동 병합 |

사용자의 개발 환경마다 설치된 스킬/MCP가 다르더라도, 세션 시작 시 Claude Code가 모든 소스를 병합하여 제공하므로 라우터는 출처를 구분할 필요가 없다.

### 저장 위치

```
.claude/router/
+-- registry.yaml          # 학습 캐시 (제외 패턴 + 보정 데이터)
+-- overrides.yaml         # 사용자가 수정한 이력
+-- feedback-log.yaml      # 라우팅 결과 피드백 이력
```

### 학습 캐시 스키마 (registry.yaml)

```yaml
excluded_patterns:          # 프로세스 스킬 제외 목록
  - "superpowers:brainstorming"
  - "superpowers:writing-plans"
  - ...

learned_preferences:        # 피드백에서 자동 축적
  - id: "skill:python-pro"
    boost: 0.2              # 매칭 점수 가산
    context: "*.py 파일 작업 시 사용자가 반복 선택"
    last_updated: 2026-04-09
```

### 프로세스 스킬 제외 목록

아래 패턴의 스킬은 기존 흐름이 제어하므로 라우팅 추천에서 제외한다:

```yaml
excluded_patterns:
  - "superpowers:brainstorming"
  - "superpowers:writing-plans"
  - "superpowers:executing-plans"
  - "superpowers:verification-before-completion"
  - "superpowers:using-superpowers"
  - "superpowers:using-git-worktrees"
  - "superpowers:finishing-a-development-branch"
  - "superpowers:requesting-code-review"
  - "superpowers:receiving-code-review"
  - "superpowers:dispatching-parallel-agents"
  - "superpowers:subagent-driven-development"
```

---

## 4. 라우터 로직

### 매칭 방식: description 기반 실시간 분석

사전 정의된 키워드 목록이 아닌, 각 항목의 **description 텍스트를 DoD 신호와 실시간으로 대조**한다.

매칭 판단 기준:
- description에 명시된 용도/트리거 조건이 DoD의 작업 내용과 부합하는가
- description에 언급된 파일 유형/도메인이 DoD의 대상 파일과 일치하는가
- description에 언급된 작업 유형(bug, feature, test 등)이 DoD의 작업 유형과 일치하는가
- registry.yaml에 해당 항목의 학습 보정(boost)이 있으면 반영

### 조합 생성 규칙

1. **에이전트**: 가장 적합한 1개 선택 (필수)
2. **스킬**: 관련성 높은 순 상위 3개까지 선택
3. **MCP**: 관련성 높은 순 상위 2개까지 선택

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

피드백 이력을 분석하여 registry.yaml의 `learned_preferences`에 보정 데이터를 축적한다.

| 조건 | 행동 |
|------|------|
| 같은 패턴에서 동일 수정 3회 | 해당 항목에 boost 가산/감산 추가 |
| 특정 조합 성공률 90%+ (5회 이상) | 해당 항목들에 boost +0.2 |
| 특정 조합 실패율 50%+ (3회 이상) | 경고 표시, 해당 항목에 boost -0.2 |

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
| `.claude/router/registry.yaml` | 신규 | 학습 캐시 (제외 패턴 + 보정 데이터) |
| `.claude/router/overrides.yaml` | 신규 | 사용자 수정 이력 |
| `.claude/router/feedback-log.yaml` | 신규 | 라우팅 결과 피드백 |
| `.claude/orchestrator.md` | 수정 | 스마트 라우팅 절차 추가 |
| `.claude/CLAUDE.md` | 수정 | 강제 시퀀스에 ROUTE 단계 삽입 |
| `AGENTS.md` | 변경 없음 | 기존 유지 |
| `.claude/hooks/*` | 변경 없음 | 기존 유지 |
| `.claude/agents/*` | 변경 없음 | 기존 유지 |
| `.claude/workflows/*` | 변경 없음 | 기존 유지 |

---

## 7. 동적 발견 (초기 부트스트랩 불필요)

### 기존 설계와의 차이

기존: 최초 1회 init-router 실행하여 모든 항목을 registry.yaml에 사전 등록
변경: **초기 부트스트랩 불필요.** 매 라우팅 시 세션 컨텍스트에서 동적 발견.

### 발견 과정 (매 라우팅 시)

1. **프로젝트 에이전트**: `.claude/agents/*.md` 파일 스캔 -> 역할 설명(description/역할 한 문장) 읽기
2. **스킬**: 세션 system-reminder의 `The following skills are available` 목록에서 이름 + description 수집
3. **MCP**: 세션 system-reminder의 `deferred tools` 목록에서 `mcp__서버명__도구명` 패턴으로 서버 식별
4. `excluded_patterns` 목록에 해당하는 프로세스 스킬 제외
5. 남은 항목의 description을 DoD 신호와 대조하여 관련성 판단

### 환경 적응

- **사용자 A** (SuperClaude + Playwright + Stitch 설치) -> 그 환경의 항목들에서 추천
- **사용자 B** (기본 스킬 + Context7만 설치) -> 그 환경의 항목들에서 추천
- 같은 프로젝트라도 환경이 다르면 다른 추천이 나온다
- 새 플러그인 설치/제거 시 다음 라우팅부터 자동 반영 (별도 등록 불필요)

---

## 8. 제약 사항과 한계

### 라우터가 하지 않는 것

- **프로세스 스킬 제어**: brainstorming, writing-plans 등은 기존 흐름이 관리
- **내장 서브에이전트(레이어 2) 선택**: backend-architect, debugger 등은 라우팅 대상 아님
- **hook 시스템 변경**: 기존 hook은 그대로 유지
- **자동 실행**: 항상 사용자 확인 후 진행 (자동 실행 없음)

### 알려진 한계

- description 텍스트 품질에 의존 -> description이 부실한 스킬은 매칭 정확도가 낮을 수 있음
- 복합 작업(Python + Frontend 동시)의 경우 매칭이 분산될 수 있음 -> 사용자 확인 단계에서 보완
- 피드백 학습은 같은 패턴 3회 이상 반복 후 적용 -> 초기에는 수동 수정이 필요할 수 있음
- 세션 컨텍스트에서 스킬/MCP description 전체를 읽는 것은 아님 -> 이름과 한 줄 설명으로 판단
