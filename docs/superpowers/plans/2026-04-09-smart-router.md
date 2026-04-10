# Smart Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DoD 작성 시점에 작업 내용을 분석하여 최적의 에이전트 + 스킬 + MCP 조합을 자동 추천하고, 사용자 확인 후 진행하는 Smart Router를 구축한다.

**Architecture:** 메타데이터 레지스트리(registry.yaml)에 각 에이전트/스킬/MCP의 매칭 조건을 선언하고, 라우터 절차(orchestrator.md)가 DoD를 분석하여 점수 기반으로 최적 조합을 추천한다. 사용자 피드백은 overrides.yaml과 feedback-log.yaml에 기록되어 점진적으로 매칭 정확도를 개선한다.

**Tech Stack:** YAML (레지스트리), Markdown (절차/규칙), Shell script (없음 — 라우터는 Claude 추론 기반)

---

## File Structure

```
.claude/router/                    (신규 디렉토리)
├── registry.yaml                  # 에이전트/스킬/MCP 메타데이터 전체
├── overrides.yaml                 # 사용자 수정 이력
└── feedback-log.yaml              # 라우팅 결과 피드백

.claude/orchestrator.md            (수정) — 스마트 라우팅 절차 섹션 추가
.claude/CLAUDE.md                  (수정) — 강제 시퀀스에 ROUTE 단계 삽입
```

---

### Task 1: 레지스트리 디렉토리 및 빈 파일 생성

**Files:**
- Create: `.claude/router/registry.yaml`
- Create: `.claude/router/overrides.yaml`
- Create: `.claude/router/feedback-log.yaml`

- [ ] **Step 1: 디렉토리 및 빈 파일 생성**

```bash
mkdir -p .claude/router
```

- [ ] **Step 2: overrides.yaml 초기화**

```yaml
# Smart Router — 사용자 수정 이력
# 사용자가 추천 조합을 수정하면 여기에 기록된다.
# 같은 패턴에서 동일 수정 3회 이상 시 registry.yaml 자동 보정 대상.
entries: []
```

- [ ] **Step 3: feedback-log.yaml 초기화**

```yaml
# Smart Router — 라우팅 결과 피드백
# 각 라우팅의 추천/수정/결과를 기록하여 매칭 정확도를 개선한다.
entries: []
```

- [ ] **Step 4: 커밋**

```bash
git add .claude/router/
git commit -m "chore: Smart Router 디렉토리 및 초기 파일 생성"
```

---

### Task 2: 프로젝트 에이전트 메타데이터 작성 (레이어 1)

**Files:**
- Modify: `.claude/router/registry.yaml`

프로젝트의 5개 에이전트를 `.claude/agents/*.md`의 역할 설명에서 추출하여 메타데이터로 변환한다.

- [ ] **Step 1: registry.yaml에 에이전트 메타데이터 작성**

```yaml
# Smart Router — 메타데이터 레지스트리
# 각 에이전트/스킬/MCP의 매칭 조건을 선언한다.
# auto_generated: true인 항목은 description에서 자동 추출된 것.
# confidence: 자동 생성 신뢰도 (0~1). 사용자 보정 시 1.0으로 상승.

# ============================================================
# Layer 1: 프로젝트 에이전트
# ============================================================

- id: agent:feature-builder
  layer: agent
  keywords: [기능, 구현, 추가, 수정, 버그, fix, feature, implement, 리팩토링, refactor]
  file_patterns: ["src/**", "app/**", "services/**", "apps/**", "lib/**"]
  task_types: [add-feature, fix-bug]
  domains: [backend, frontend, python, typescript, general]
  priority: 0.8
  requires: []
  conflicts: [agent:service-builder]
  auto_generated: false
  confidence: 1.0

- id: agent:service-builder
  layer: agent
  keywords: [새 서비스, 새 모듈, 새 앱, 초기 구조, scaffold, 생성, create service]
  file_patterns: []
  task_types: [build-from-scratch]
  domains: [backend, frontend, python, typescript, general]
  priority: 0.8
  requires: []
  conflicts: [agent:feature-builder]
  auto_generated: false
  confidence: 1.0

- id: agent:reviewer
  layer: agent
  keywords: [리뷰, review, 코드 리뷰, PR, 품질, 검토, incident]
  file_patterns: []
  task_types: []
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: false
  confidence: 1.0

- id: agent:researcher
  layer: agent
  keywords: [조사, 비교, research, investigate, 라이브러리, 프레임워크, 아키텍처, 트렌드]
  file_patterns: []
  task_types: [research-task]
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: false
  confidence: 1.0

- id: agent:docs-writer
  layer: agent
  keywords: [문서, 문서화, README, changelog, 가이드, documentation, docs]
  file_patterns: ["*.md", "docs/**"]
  task_types: []
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: false
  confidence: 1.0
```

- [ ] **Step 2: 검증 — YAML 문법 확인**

```bash
python3 -c "import yaml; yaml.safe_load(open('.claude/router/registry.yaml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 3: 커밋**

```bash
git add .claude/router/registry.yaml
git commit -m "feat: 프로젝트 에이전트 메타데이터 등록 (레이어 1)"
```

---

### Task 3: SuperClaude 스킬 메타데이터 작성 (레이어 3)

**Files:**
- Modify: `.claude/router/registry.yaml`

SuperClaude 스킬 중 구현/도메인 특화 스킬만 등록한다. 프로세스 스킬(brainstorming, writing-plans 등)은 제외.

- [ ] **Step 1: registry.yaml에 스킬 메타데이터 추가**

아래를 registry.yaml 하단에 추가:

```yaml
# ============================================================
# Layer 3: SuperClaude 스킬 (구현/도메인 특화만)
# ============================================================

# --- 디버깅/품질 ---

- id: skill:systematic-debugging
  layer: skill
  keywords: [버그, bug, error, 에러, 실패, failure, 디버깅, debug, stack trace, 예외]
  file_patterns: []
  task_types: [fix-bug]
  domains: [general]
  priority: 0.8
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.9

- id: skill:test-driven-development
  layer: skill
  keywords: [테스트, TDD, test, 단위테스트, coverage, 커버리지, pytest, jest]
  file_patterns: ["*.test.*", "*.spec.*", "tests/**", "__tests__/**"]
  task_types: [add-feature, fix-bug]
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.9

- id: skill:verification-before-completion
  layer: skill
  keywords: [검증, verify, 확인, 완료, completion, 테스트 통과]
  file_patterns: []
  task_types: [add-feature, fix-bug, build-from-scratch]
  domains: [general]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

# --- 프론트엔드 ---

- id: skill:frontend-design
  layer: skill
  keywords: [UI, 프론트엔드, frontend, 컴포넌트, component, 페이지, page, 디자인, 인터페이스]
  file_patterns: ["*.tsx", "*.jsx", "*.vue", "*.svelte", "components/**", "pages/**", "app/**/*.tsx"]
  task_types: [add-feature, build-from-scratch]
  domains: [frontend]
  priority: 0.8
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

- id: skill:shadcn-ui
  layer: skill
  keywords: [shadcn, ui 라이브러리, 컴포넌트 라이브러리, radix, tailwind 컴포넌트]
  file_patterns: ["components/ui/**", "*.tsx"]
  task_types: [add-feature]
  domains: [frontend]
  priority: 0.6
  requires: [skill:frontend-design]
  conflicts: []
  auto_generated: true
  confidence: 0.7

# --- 백엔드 ---

- id: skill:api-design-principles
  layer: skill
  keywords: [API, REST, GraphQL, 엔드포인트, endpoint, 라우터, router, 스키마]
  file_patterns: ["*/routers/**", "*/routes/**", "*/api/**", "*/schemas/**"]
  task_types: [add-feature, build-from-scratch]
  domains: [backend]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

- id: skill:architecture-patterns
  layer: skill
  keywords: [아키텍처, architecture, 클린, hexagonal, DDD, 도메인, 레이어]
  file_patterns: ["*/domain/**", "*/application/**", "*/infrastructure/**"]
  task_types: [build-from-scratch]
  domains: [backend]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.7

# --- 언어 특화 ---

- id: skill:python-pro
  layer: skill
  keywords: [python, 파이썬, decorator, async, generator, pytest, pip, poetry]
  file_patterns: ["*.py", "pyproject.toml", "requirements*.txt"]
  task_types: [add-feature, fix-bug, build-from-scratch]
  domains: [python, backend]
  priority: 0.7
  requires: []
  conflicts: [skill:typescript-pro, skill:javascript-pro]
  auto_generated: true
  confidence: 0.9

- id: skill:typescript-pro
  layer: skill
  keywords: [typescript, 타입스크립트, type, interface, generic, tsx]
  file_patterns: ["*.ts", "*.tsx", "tsconfig.json"]
  task_types: [add-feature, fix-bug, build-from-scratch]
  domains: [typescript, frontend, backend]
  priority: 0.7
  requires: []
  conflicts: [skill:python-pro]
  auto_generated: true
  confidence: 0.9

- id: skill:javascript-pro
  layer: skill
  keywords: [javascript, 자바스크립트, ES6, async, promise, node]
  file_patterns: ["*.js", "*.mjs", "*.cjs"]
  task_types: [add-feature, fix-bug]
  domains: [javascript, frontend, backend]
  priority: 0.6
  requires: []
  conflicts: [skill:python-pro]
  auto_generated: true
  confidence: 0.9

# --- 인프라/배포 ---

- id: skill:mcp-builder
  layer: skill
  keywords: [MCP, 서버, model context protocol, tool, 플러그인]
  file_patterns: ["*/mcp/**", "mcp-*.py", "mcp-*.ts"]
  task_types: [build-from-scratch]
  domains: [backend]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

# --- 조사/문서 ---

- id: skill:sc:research
  layer: skill
  keywords: [조사, research, 검색, search, 분석, 최신, 트렌드, 비교]
  file_patterns: []
  task_types: [research-task]
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

- id: skill:sc:document
  layer: skill
  keywords: [문서, documentation, README, API 문서, 가이드]
  file_patterns: ["*.md", "docs/**"]
  task_types: []
  domains: [general]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

# --- 코드 품질 ---

- id: skill:simplify
  layer: skill
  keywords: [간소화, simplify, 리팩토링, refactor, 중복, 정리, cleanup]
  file_patterns: []
  task_types: [add-feature, fix-bug]
  domains: [general]
  priority: 0.5
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.7

- id: skill:webapp-testing
  layer: skill
  keywords: [E2E, 브라우저 테스트, playwright, 통합 테스트, UI 테스트, 스크린샷]
  file_patterns: ["*.test.ts", "*.spec.ts", "e2e/**", "playwright/**"]
  task_types: [add-feature]
  domains: [frontend]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8
```

- [ ] **Step 2: 검증 — YAML 문법 확인**

```bash
python3 -c "import yaml; yaml.safe_load(open('.claude/router/registry.yaml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 3: 커밋**

```bash
git add .claude/router/registry.yaml
git commit -m "feat: SuperClaude 스킬 메타데이터 등록 (레이어 3)"
```

---

### Task 4: MCP 서버 메타데이터 작성 (레이어 4)

**Files:**
- Modify: `.claude/router/registry.yaml`

현재 설정된 MCP 서버와 글로벌 CLAUDE.md의 MCP_*.md에서 정의된 서버를 등록한다.

- [ ] **Step 1: registry.yaml에 MCP 메타데이터 추가**

아래를 registry.yaml 하단에 추가:

```yaml
# ============================================================
# Layer 4: MCP 서버
# ============================================================

- id: mcp:context7
  layer: mcp
  keywords: [라이브러리, 프레임워크, 공식 문서, documentation, import, require, API, SDK, 패키지]
  file_patterns: ["package.json", "pyproject.toml", "requirements*.txt", "*.config.*"]
  task_types: [add-feature, fix-bug, build-from-scratch, research-task]
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.9

- id: mcp:sequential
  layer: mcp
  keywords: [분석, 디버깅, 아키텍처, 설계, 복합, 다단계, 추론, 시스템, 성능, 병목]
  file_patterns: []
  task_types: [fix-bug, research-task]
  domains: [general]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

- id: mcp:playwright
  layer: mcp
  keywords: [브라우저, E2E, 스크린샷, UI 테스트, 접근성, WCAG, 폼, 클릭, 렌더링]
  file_patterns: ["*.tsx", "*.jsx", "*.vue", "pages/**", "components/**", "e2e/**"]
  task_types: [add-feature]
  domains: [frontend]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.8

- id: mcp:tavily
  layer: mcp
  keywords: [검색, 웹 검색, 최신 정보, 트렌드, 뉴스, 현재, 실시간, 리서치]
  file_patterns: []
  task_types: [research-task]
  domains: [general]
  priority: 0.7
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.9

- id: mcp:serena
  layer: mcp
  keywords: [심볼, 리네임, 참조, LSP, 프로젝트 메모리, 세션, 대규모 코드베이스]
  file_patterns: []
  task_types: [add-feature, fix-bug]
  domains: [general]
  priority: 0.5
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.7

- id: mcp:stitch
  layer: mcp
  keywords: [디자인, 디자인 시스템, 화면 생성, 스크린, UI 생성, 프로토타입]
  file_patterns: [".stitch/**", "DESIGN.md"]
  task_types: [build-from-scratch, add-feature]
  domains: [frontend]
  priority: 0.6
  requires: []
  conflicts: []
  auto_generated: true
  confidence: 0.7
```

- [ ] **Step 2: 검증 — YAML 문법 확인**

```bash
python3 -c "import yaml; yaml.safe_load(open('.claude/router/registry.yaml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 3: 커밋**

```bash
git add .claude/router/registry.yaml
git commit -m "feat: MCP 서버 메타데이터 등록 (레이어 4)"
```

---

### Task 5: orchestrator.md에 스마트 라우팅 절차 추가

**Files:**
- Modify: `.claude/orchestrator.md`

기존 라우팅 테이블 아래에 스마트 라우팅 절차 섹션을 추가한다.

- [ ] **Step 1: orchestrator.md 끝에 스마트 라우팅 절차 추가**

`orchestrator.md`의 `## 에이전트 추가 파이프라인` 섹션 위에 아래 섹션을 삽입:

```markdown
---

## 스마트 라우팅 절차

DoD 작성 완료 후, 구현 시작 전에 아래를 수행한다.

### 실행 시점
- **트리거**: DoD 파일(`SOT/dod/dod-*.md`) 작성 완료 직후
- **목적**: 최적의 에이전트 + 스킬 + MCP 조합을 추천하여 사용자 확인

### 절차

1. **신호 추출**: DoD 파일에서 아래 4가지 신호를 추출
   - 키워드: 작업명, 완료 기준, 요약에서 핵심 단어
   - 파일 패턴: 변경 대상 파일의 확장자와 경로
   - 작업 유형: add-feature | fix-bug | build-from-scratch | research-task
   - SOT 컨텍스트: `SOT/index.md`의 현재 상태, 블로커

2. **매칭 점수 계산**: `.claude/router/registry.yaml`의 각 항목과 점수 계산
   ```
   총점 = (키워드 매칭 x 0.4) + (파일 패턴 매칭 x 0.3) + (작업 유형 매칭 x 0.2) + (SOT 컨텍스트 x 0.1)
   ```

3. **조합 생성**:
   - 에이전트: 점수 최상위 1개 (필수)
   - 스킬: 점수 0.5 이상 중 상위 3개까지
   - MCP: 점수 0.5 이상 중 상위 2개까지
   - conflicts 검사: 충돌 항목 제거
   - requires 검사: 필수 의존 항목 추가

4. **사용자 확인**: 아래 형식으로 추천 조합을 제시
   ```
   [라우팅] 작업: "[DoD 작업명]"

   추천 조합:
     에이전트: [에이전트명] ([워크플로우명])
     스킬:    [스킬1], [스킬2]
     MCP:     [MCP1], [MCP2]

     근거:
     - [매칭 근거 1]
     - [매칭 근거 2]

   이 조합으로 진행할까요? (수정하려면 말씀해 주세요)
   ```

5. **수정 사항 기록**: 사용자가 수정하면 `.claude/router/overrides.yaml`에 기록
6. **승인된 조합으로 작업 진행**

### overrides.yaml 기록 형식

```yaml
- date: YYYY-MM-DD
  dod: "dod-[작업명].md"
  pattern:
    keywords: [매칭된 키워드]
    file_patterns: [매칭된 파일 패턴]
    task_type: [작업 유형]
  modification:
    removed: [제거된 항목 id]
    added: [추가된 항목 id]
  reason: "사용자가 말한 수정 이유 (있으면)"
```

### 새 스킬/MCP 자동 감지

라우터 실행 시 현재 설치된 스킬/MCP 목록과 registry.yaml을 비교한다.
새로 발견된 항목이 있으면:
1. description을 파싱하여 메타데이터 자동 생성
2. confidence를 0.5로 시작
3. 사용자에게 "[새 항목]이 감지되어 레지스트리에 추가했습니다" 알림

### 작업 완료 후 피드백 기록

작업 완료 시 `.claude/router/feedback-log.yaml`에 아래를 추가한다:

```yaml
- date: YYYY-MM-DD
  dod: "dod-[작업명].md"
  recommended:
    agent: [에이전트 id]
    skills: [스킬 id 목록]
    mcp: [MCP id 목록]
  user_modified:
    removed: [제거된 id]
    added: [추가된 id]
  outcome: success | partial | failed
  notes: "특이사항"
```

### 자동 보정 규칙

| 조건 | 행동 |
|------|------|
| 같은 패턴에서 동일 수정 3회 | registry.yaml 점수 자동 조정 |
| 특정 조합 성공률 90%+ (5회 이상) | confidence를 0.9로 승격 |
| 특정 조합 실패율 50%+ (3회 이상) | 경고 표시, 대안 우선 추천 |
| 새 항목 추가 후 첫 5회 사용 | confidence 0.5에서 시작, 점진 상승 |
```

- [ ] **Step 2: 검증 — orchestrator.md 전체 읽기로 구조 확인**

orchestrator.md를 읽어서 기존 섹션(라우팅 테이블, 작업 유형 판단 기준, Agent Teams 활용, 에이전트 추가 파이프라인)과 새 섹션이 자연스럽게 연결되는지 확인.

- [ ] **Step 3: 커밋**

```bash
git add .claude/orchestrator.md
git commit -m "feat: orchestrator.md에 스마트 라우팅 절차 추가"
```

---

### Task 6: CLAUDE.md 강제 작업 시퀀스에 ROUTE 단계 삽입

**Files:**
- Modify: `.claude/CLAUDE.md`

기존 9단계 시퀀스에 ROUTE 단계를 3번으로 삽입하고, 나머지 번호를 조정한다.

- [ ] **Step 1: CLAUDE.md의 강제 작업 시퀀스 수정**

`## 강제 작업 시퀀스 (hook이 위반을 차단합니다)` 섹션의 번호 목록을 아래로 교체:

```markdown
1. **READ** `SOT/index.md` — 항상 첫 번째
2. **WRITE** `SOT/dod/dod-[작업명].md` — 소스 코드 편집 전 필수
   → `pre-edit-dod-gate.sh`가 DoD 파일 없으면 Edit/Write/MultiEdit를 차단함
   → DoD는 inbox과 분리. inbox은 "작업 완료 기록", dod는 "작업 시작 전 기준"
3. **ROUTE** — 스마트 라우터로 최적 조합 추천 → 사용자 확인
   → `.claude/orchestrator.md`의 "스마트 라우팅 절차"를 따른다
   → `.claude/router/registry.yaml`에서 메타데이터 매칭
   → 에이전트 1개 + 스킬 최대 3개 + MCP 최대 2개 조합 추천
   → 사용자 승인 후 다음 단계 진행 (수정 시 overrides.yaml에 기록)
4. **IMPLEMENT** — 승인된 조합의 에이전트/스킬/MCP를 활용하여 소스 코드 편집
5. **CODEX REVIEW** — 구현 완료 후 반드시 Codex로 코드 리뷰 실행
   → `/codex` 스킬로 변경된 파일에 대해 리뷰 요청
   → 리뷰 완료 후 `touch SOT/dod/.codex-reviewed`로 stamp 생성
   → `pre-bash-guard.sh`가 테스트 명령 실행 시 stamp 없으면 차단함 (exit 2)
6. **FIX** — Codex 리뷰 결과 반영하여 코드 수정
7. **TEST** — 테스트 실행 (리뷰 stamp가 있어야 실행 가능)
8. **SELF-REVIEW** — AGENTS.md §5 항목을 명시적으로 답변
9. **WRITE** `SOT/inbox/YYYY-MM-DD-[작업명].md` — 작업 완료 기록
   → `stop-session-gate.sh`가 세션 종료 시 inbox 기록 없으면 차단함 (exit 2)
   → 라우팅 피드백을 `.claude/router/feedback-log.yaml`에도 기록
10. **UPDATE** `SOT/index.md` — 세션 종료 전
    → `stop-session-gate.sh`가 세션 종료 시 index.md 미갱신이면 차단함 (exit 2)
```

- [ ] **Step 2: 검증 — CLAUDE.md 전체 읽기로 시퀀스 번호 일관성 확인**

10단계가 순서대로 번호가 맞는지, 기존 설명과 충돌하는 부분이 없는지 확인.

- [ ] **Step 3: 커밋**

```bash
git add .claude/CLAUDE.md
git commit -m "feat: 강제 작업 시퀀스에 ROUTE 단계 삽입 (3번)"
```

---

### Task 7: 전체 통합 검증

**Files:**
- Read: `.claude/router/registry.yaml`
- Read: `.claude/orchestrator.md`
- Read: `.claude/CLAUDE.md`

- [ ] **Step 1: registry.yaml YAML 유효성 최종 확인**

```bash
python3 -c "
import yaml
data = yaml.safe_load(open('.claude/router/registry.yaml'))
agents = [x for x in data if x['layer'] == 'agent']
skills = [x for x in data if x['layer'] == 'skill']
mcps = [x for x in data if x['layer'] == 'mcp']
print(f'Agents: {len(agents)}, Skills: {len(skills)}, MCPs: {len(mcps)}')
print(f'Total: {len(data)} entries')
for item in data:
    assert 'id' in item, f'Missing id in {item}'
    assert 'layer' in item, f'Missing layer in {item}'
    assert 'keywords' in item, f'Missing keywords in {item}'
    assert item['layer'] in ('agent', 'skill', 'mcp'), f'Invalid layer: {item[\"layer\"]}'
print('All entries valid')
"
```

Expected:
```
Agents: 5, Skills: 14, MCPs: 6
Total: 25 entries
All entries valid
```

- [ ] **Step 2: orchestrator.md에 스마트 라우팅 절차 섹션 존재 확인**

```bash
grep -c "스마트 라우팅 절차" .claude/orchestrator.md
```

Expected: `1` (이상)

- [ ] **Step 3: CLAUDE.md에 ROUTE 단계 존재 확인**

```bash
grep -c "ROUTE" .claude/CLAUDE.md
```

Expected: `1` (이상)

- [ ] **Step 4: conflicts 상호 참조 검증**

```bash
python3 -c "
import yaml
data = yaml.safe_load(open('.claude/router/registry.yaml'))
ids = {x['id'] for x in data}
for item in data:
    for c in item.get('conflicts', []):
        assert c in ids, f'{item[\"id\"]} conflicts with unknown id: {c}'
    for r in item.get('requires', []):
        assert r in ids, f'{item[\"id\"]} requires unknown id: {r}'
print('All references valid')
"
```

Expected: `All references valid`

- [ ] **Step 5: 커밋 (필요 시 — 검증 중 수정 발생한 경우만)**

```bash
git add -A && git diff --cached --quiet || git commit -m "fix: 통합 검증에서 발견된 문제 수정"
```
