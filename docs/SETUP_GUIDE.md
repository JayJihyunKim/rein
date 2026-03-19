# AI-Native 프레임워크 적용 가이드

> 이 문서는 `claude-code-ai-native` 템플릿을 새 프로젝트에 적용하는 방법을 설명합니다.

---

## 목차

1. [개요](#개요)
2. [적용 방법](#적용-방법)
3. [프레임워크 구조](#프레임워크-구조)
4. [단계별 커스터마이징](#단계별-커스터마이징)
5. [파일별 상세 설명](#파일별-상세-설명)
6. [작업 흐름](#작업-흐름)
7. [자기 진화 시스템](#자기-진화-시스템)
8. [FAQ](#faq)

---

## 개요

### AI Native란?

| 구분 | AI Assisted (기존) | AI Native (이 프레임워크) |
|------|-------------------|--------------------------|
| 지시 방식 | "이 함수 이렇게 만들어줘" | "이 워크플로우를 실행해줘" |
| 기준 위치 | 사람 머릿속 | 문서 파일 (AGENTS.md, rules/) |
| 실패 대응 | 출력물 다시 요청 | 원인 분석 후 규칙 문서 수정 |
| 확장성 | 매번 사람이 개입 | 규칙이 쌓일수록 품질 자동 상승 |

### 핵심 원칙 5가지

1. 매 작업 시작 전에 **완료 기준(Definition of Done)을 먼저** 적는다
2. 결과가 나쁘면 출력물이 아니라 **시스템(규칙 파일)을 수정**한다
3. 같은 문제가 **2번 반복되면 즉시 AGENTS.md 규칙으로 승격**한다
4. SOT는 읽는 저장소가 아니라 **증거 저장소**다
5. 에이전트는 **역할 경계가 한 문장으로 설명될 때만** 분리한다

---

## 적용 방법

### 방법 A: 새 프로젝트를 템플릿으로 생성

```bash
# GitHub CLI로 템플릿 기반 새 레포 생성 + 로컬 클론
gh repo create my-project \
  --template JayJihyunKim/claude-code-ai-native \
  --private --clone

cd my-project
```

### 방법 B: 기존 프로젝트에 파일 복사

```bash
# 1. 템플릿 임시 클론
gh repo clone JayJihyunKim/claude-code-ai-native /tmp/ai-native-template

# 2. 핵심 파일 복사
cp -r /tmp/ai-native-template/.claude  /path/to/your-project/
cp -r /tmp/ai-native-template/SOT     /path/to/your-project/
cp -r /tmp/ai-native-template/.github /path/to/your-project/
cp    /tmp/ai-native-template/AGENTS.md /path/to/your-project/

# 3. .gitignore에 추가 (기존 .gitignore가 있다면 병합)
cat /tmp/ai-native-template/.gitignore >> /path/to/your-project/.gitignore

# 4. 정리
rm -rf /tmp/ai-native-template
```

### 방법 C: Git remote로 머지 (템플릿 업데이트 추적 가능)

```bash
cd /path/to/your-project

git remote add template git@github.com:JayJihyunKim/claude-code-ai-native.git
git fetch template
git merge template/main --allow-unrelated-histories
# 충돌 해결 후 커밋

# 이후 템플릿 업데이트 반영
git fetch template && git merge template/main
```

| | 방법 A (새 프로젝트) | 방법 B (파일 복사) | 방법 C (Git 머지) |
|---|---|---|---|
| 용도 | 프로젝트 신규 시작 | 기존 프로젝트 1회 적용 | 템플릿 업데이트 지속 반영 |
| 난이도 | 가장 쉬움 | 쉬움 | 충돌 해결 필요할 수 있음 |
| 히스토리 | 없음 (깨끗한 시작) | 없음 | 템플릿 커밋 히스토리 포함 |
| 이후 업데이트 | 수동 | 수동 | `git merge template/main` |

---

## 프레임워크 구조

```
your-project/
├── AGENTS.md                    ← 전역 실행 규칙 (Source of Truth)
├── .claude/
│   ├── CLAUDE.md                ← 진입점 — 세션 시작 시 자동 로드
│   ├── settings.json            ← 권한, Hooks 설정
│   ├── orchestrator.md          ← 작업 유형 → workflow + agent 라우팅
│   ├── registry/
│   │   └── agents.yml           ← 활성 에이전트 목록
│   ├── rules/                   ← 경로 기반 자동 로드 규칙
│   │   ├── code-style.md
│   │   ├── security.md
│   │   └── testing.md
│   ├── workflows/               ← 작업 유형별 절차서
│   │   ├── add-feature.md
│   │   ├── fix-bug.md
│   │   ├── build-from-scratch.md
│   │   └── research-task.md
│   ├── agents/                  ← 역할별 에이전트 정의
│   │   ├── feature-builder.md
│   │   ├── service-builder.md
│   │   ├── reviewer.md
│   │   ├── researcher.md
│   │   └── docs-writer.md
│   ├── skills/                  ← 특정 시점 호출 스킬
│   │   ├── repo-audit/
│   │   ├── incidents-to-rule/
│   │   ├── incidents-to-agent/
│   │   ├── promote-agent/
│   │   ├── changelog-writer/
│   │   └── pr-review-fixer/
│   └── hooks/                   ← 라이프사이클 자동화 스크립트
│       ├── post-edit-lint.sh
│       ├── pre-bash-guard.sh
│       └── task-completed-incident.sh
├── SOT/                         ← 증거 저장소 (상태/결정/사고 기록)
│   ├── index.md                 ← 현재 프로젝트 상태 (5~15줄)
│   ├── inbox/                   ← 세션 원본 로그
│   ├── daily/                   ← 하루 1회 압축 요약
│   ├── weekly/                  ← 주 1회 재요약
│   ├── decisions/               ← 확정 기술/운영 결정 (DEC-NNN.md)
│   ├── incidents/               ← 실패 사례, 반복 문제 (INC-NNN.md)
│   └── agent-candidates/        ← 에이전트 승격 후보
└── .github/workflows/           ← GitHub Actions 자동화
    ├── daily-sot-audit.yml
    ├── repo-audit.yml
    ├── issue-triage.yml
    └── weekly-agent-evolution.yml
```

### 컨텍스트 로딩 순서

Claude Code가 세션 시작 시 자동으로 읽는 순서:

```
1. .claude/CLAUDE.md          — 자동 로드 (진입점, @import 허브)
2. AGENTS.md                  — 전역 실행 규칙
3. 작업 디렉토리의 nearest AGENTS.md — 언어/프레임워크별 규칙 (예: services/api/AGENTS.md)
4. SOT/index.md               — 현재 프로젝트 상태 (5~15줄)
```

필요시 추가 로드:
- `.claude/workflows/[해당].md` — 작업 유형에 따른 절차서
- `.claude/agents/[해당].md` — 담당 에이전트 정의

---

## 단계별 커스터마이징

### 1단계: 핵심 설정 (Day 1) — 반드시 수정

프레임워크를 적용한 직후, 아래 5개 파일을 프로젝트에 맞게 수정합니다.

#### 1-1. `SOT/index.md` — 프로젝트 현재 상태

**가장 먼저 수정해야 할 파일입니다.** 5~15줄로 프로젝트 상태를 작성합니다.

```markdown
# SOT/index.md — 현재 프로젝트 상태

- **프로젝트**: 쇼핑몰 백엔드 API
- **현재 스프린트**: Sprint 3 — 결제 시스템
- **최근 완료**: 상품 CRUD API, 사용자 인증
- **진행 중**: 결제 연동 (PG사: 토스페이먼츠)
- **블로커**: PG사 테스트 API 키 발급 대기 중
- **다음 우선순위**: 주문 관리 API

## 최근 결정사항
- [DEC-001]: ORM으로 SQLAlchemy 2.x 선택 (async 지원)

## 주의사항
- Python 3.12+ 필수 (match-case 문법 사용)

---
*마지막 갱신: 2026-03-19*
```

#### 1-2. `AGENTS.md` — 전역 규칙

템플릿의 규칙을 기반으로, **프로젝트에 맞지 않는 규칙은 제거하고 필요한 규칙을 추가**합니다.

수정 포인트:
- §3 코딩 규칙: 프로젝트의 언어/스타일에 맞게 조정
- §7 에이전트 역할 목록: 프로젝트에서 쓸 에이전트만 유지
- §10 Git 규칙: 팀 컨벤션에 맞게 커밋 타입 조정

#### 1-3. `.claude/CLAUDE.md` — 진입점

`@import`로 연결하는 rules 파일을 프로젝트에 맞게 수정합니다.

```markdown
## 규칙 허브
@.claude/rules/code-style.md
@.claude/rules/testing.md
@.claude/rules/security.md
# 필요시 추가:
# @.claude/rules/api-design.md
# @.claude/rules/database.md
```

#### 1-4. `.claude/settings.json` — 권한 설정

프로젝트에서 사용하는 도구에 맞게 `allow`, `ask`, `deny` 목록을 수정합니다.

```jsonc
{
  "permissions": {
    "allow": [
      // 프로젝트에서 쓰는 빌드/테스트 도구 추가
      "Bash(cargo *)",       // Rust 프로젝트라면
      "Bash(go *)",          // Go 프로젝트라면
      "Bash(docker compose *)"
    ],
    "deny": [
      // 프로젝트의 민감 파일 경로 추가
      "Read(./.env)",
      "Read(./secrets/**)"
    ]
  }
}
```

#### 1-5. `.claude/orchestrator.md` — 작업 라우팅

프로젝트에서 사용하지 않는 작업 유형이 있다면 제거합니다. 예를 들어 ML이 없는 프로젝트라면 관련 라우팅을 삭제합니다.

---

### 2단계: 에이전트 & 워크플로우 조정 (1주차)

#### 2-1. 하위 AGENTS.md 수정

프로젝트의 실제 기술 스택에 맞게 하위 AGENTS.md를 수정합니다.

**템플릿에 포함된 하위 AGENTS.md 3개:**

| 파일 | 용도 | 수정 방법 |
|------|------|-----------|
| `apps/web/AGENTS.md` | Next.js/TypeScript 규칙 | 프론트엔드 스택에 맞게 수정 |
| `services/api/AGENTS.md` | Python/FastAPI 규칙 | 백엔드 스택에 맞게 수정 |
| `ml/AGENTS.md` | ML 파이프라인 규칙 | ML이 없으면 삭제 |

**하위 AGENTS.md 필수 포함 항목:**
- 기술 스택 (언어, 프레임워크, 버전)
- 실행 명령어 (dev, build, test, lint)
- 디렉토리 구조
- 코딩 규칙 (언어/프레임워크 특화)
- 금지 패턴

**새 디렉토리에 AGENTS.md 추가 예시:**

```markdown
# services/payment/AGENTS.md — 결제 서비스 규칙

## 기술 스택
- **Language**: TypeScript 5.x
- **Framework**: Express.js
- **Testing**: Jest

## 실행 명령어
npm run dev / npm test / npm run lint

## 금지 패턴
- PG사 API 키 하드코딩 금지
- 결제 금액 부동소수점 계산 금지 → BigInt 또는 정수(원 단위) 사용
```

#### 2-2. 에이전트 조정

프로젝트에서 사용하지 않을 에이전트를 `registry/agents.yml`에서 비활성화합니다.

```yaml
# 사용하지 않는 에이전트
# - name: researcher
#   status: inactive
```

**에이전트는 5개가 기본 제공됩니다:**

| 에이전트 | 역할 | 언제 쓰이나 |
|---------|------|------------|
| `feature-builder` | 기능 추가 / 버그 수정 | 가장 자주 사용 |
| `service-builder` | 새 서비스 초기 구조 생성 | 새 모듈 만들 때 |
| `reviewer` | 코드 리뷰 + incident 작성 | PR 리뷰, self-review |
| `researcher` | 기술 조사 | 라이브러리/아키텍처 결정 |
| `docs-writer` | 문서 작성 | README, API 문서, changelog |

#### 2-3. 워크플로우 커스터마이징

4개 워크플로우는 그대로 사용해도 되지만, 필요시 Step을 추가/제거할 수 있습니다.

| 워크플로우 | 용도 | 핵심 흐름 |
|-----------|------|----------|
| `add-feature.md` | 기능 추가 | 컨텍스트 파악 → DoD → 계획 → 구현 → 검증 |
| `fix-bug.md` | 버그 수정 | 정보 수집 → 재현 → 원인 분석 → DoD → 수정 |
| `build-from-scratch.md` | 새 서비스 생성 | 요구사항 → DoD → 구조 설계 → 구현 → 검증 |
| `research-task.md` | 기술 조사 | 범위 정의 → DoD → 조사 → 비교표 → 결정 기록 |

---

### 3단계: Rules & Hooks 조정 (1~2주차)

#### 3-1. Rules (경로 기반 자동 로드)

`rules/` 디렉토리의 규칙은 `paths` frontmatter에 정의된 파일 경로와 매칭될 때 자동 로드됩니다.

**기본 제공 3개:**

| 파일 | 자동 로드 조건 | 내용 |
|------|--------------|------|
| `code-style.md` | 항상 (paths 없음) | 네이밍, 함수 규칙, 금지 패턴 |
| `security.md` | `*.env`, `secrets/**`, `*auth*` 등 | 보안 민감 파일 작업 시 |
| `testing.md` | `tests/**`, `*.test.*`, `*.spec.*` 등 | 테스트 파일 작업 시 |

**새 규칙 추가 예시** — `rules/api-design.md`:

```markdown
---
paths:
  - "**/routers/**"
  - "**/routes/**"
  - "**/controllers/**"
---

# API Design Rules

## RESTful 규칙
- GET: 조회, POST: 생성, PUT: 전체 수정, PATCH: 부분 수정, DELETE: 삭제
- 복수형 명사 사용: `/users`, `/orders`
- 중첩 2단계까지: `/users/{id}/orders` (OK), `/users/{id}/orders/{id}/items` (별도 엔드포인트로 분리)

## 응답 규칙
- 성공: 200/201/204
- 클라이언트 에러: 400/401/403/404/422
- 서버 에러: 500
```

#### 3-2. Hooks (라이프사이클 자동화)

**기본 제공 3개:**

| Hook | 트리거 | 동작 |
|------|--------|------|
| `post-edit-lint.sh` | 파일 Edit/Write 후 | 확장자별 자동 lint/format 실행 |
| `pre-bash-guard.sh` | Bash 명령 실행 전 | 위험 명령어 차단 (pipe to shell, force push 등) |
| `task-completed-incident.sh` | 작업 완료 시 | self-review 체크리스트 리마인더 출력 |

**Hook 동작 원리:**

```
PostToolUse(Edit|Write) → post-edit-lint.sh
  ├── .ts/.tsx/.js/.jsx → npx eslint --fix
  └── .py → ruff check --fix + ruff format

PreToolUse(Bash) → pre-bash-guard.sh
  ├── `| bash` or `| sh` → 즉시 차단 (exit 1)
  └── `git reset --hard` 등 → 확인 요청 (exit 2)

TaskCompleted → task-completed-incident.sh
  └── self-review 완료 여부, SOT 갱신 여부 확인 메시지 출력
```

**프로젝트에 맞게 수정할 포인트:**
- `post-edit-lint.sh`: 프로젝트에서 사용하는 린터로 교체 (예: `biome`, `black`)
- `pre-bash-guard.sh`: 차단할 위험 명령어 패턴 추가

---

### 4단계: GitHub Actions 설정 (1달 후)

프로젝트가 안정되면 자동화를 활성화합니다.

| 워크플로우 | 주기 | 하는 일 |
|-----------|------|---------|
| `daily-sot-audit.yml` | 매일 18:00 UTC | SOT/index.md 줄 수, inbox 미압축 파일 확인 |
| `repo-audit.yml` | 매주 월요일 | AGENTS.md 크기, 레지스트리 일관성, 보안 점검 |
| `issue-triage.yml` | 이슈 생성 시 | 제목/본문 기반 자동 라벨 + 버그 시 incident 안내 |
| `weekly-agent-evolution.yml` | 매주 월요일 | incident 누적 확인, 에이전트 후보 감지 |

---

## 파일별 상세 설명

### 핵심 파일 (반드시 이해해야 할 5개)

#### `AGENTS.md` — Source of Truth

프레임워크의 **핵심 파일**입니다. 모든 실행 규칙이 여기에 있습니다.

포함 내용:
- §1 핵심 원칙 5가지
- §2 작업 시작 전 체크리스트
- §3 코딩 규칙 (일반, 파일 구조, 금지 패턴)
- §4 완료 기준 (Definition of Done)
- §5 Self-review 기준
- §6 Incident 기록 규칙
- §7 에이전트 운영 원칙 (역할 목록, 추가 기준)
- §8 SOT 운영 규칙
- §9 컨텍스트 절감 전략
- §10 Git 규칙

**중요**: 결과가 나쁘면 출력물이 아니라 **이 파일을 수정**합니다. 같은 문제가 2번 반복되면 즉시 이 파일에 규칙을 추가합니다.

#### `SOT/index.md` — 프로젝트 상태

매 세션 시작 시 Claude가 읽는 **유일한 상태 파일**입니다. 5~15줄을 유지합니다.

- 현재 진행 중인 작업, 블로커, 다음 우선순위
- 최근 결정사항, 주의사항
- 세션 종료 시 반드시 갱신

#### `.claude/CLAUDE.md` — 진입점

세션 시작 시 자동 로드됩니다. `@import`로 rules 파일을 연결하는 허브입니다.

#### `.claude/orchestrator.md` — 라우팅

"이 작업은 어떤 workflow + agent 조합으로 처리하지?"를 결정하는 라우팅 테이블입니다.

#### `.claude/settings.json` — 권한 & Hooks

Claude Code의 도구 사용 권한과 자동화 Hook을 정의합니다.

### 에이전트 파일 구조

모든 에이전트 파일은 동일한 구조를 따릅니다:

```markdown
---
name: [에이전트명]
description: [한 줄 설명]
---

# [에이전트명]
> **역할 한 문장**: ...

## 담당
## 담당하지 않는 것
## 작업 시작 전 체크리스트
## 구현 원칙 (또는 리뷰 체크리스트 등)
## 완료 기준
```

### SOT 디렉토리 구조

```
SOT/
├── index.md             ← 현재 상태 (5~15줄, 매 세션 갱신)
├── inbox/               ← 세션 원본 로그 → daily에서 요약 후 삭제
├── daily/               ← 하루 1회 압축 요약
├── weekly/              ← 주 1회 재요약
├── decisions/           ← 기술 결정 (DEC-001.md, DEC-002.md, ...)
├── incidents/           ← 실패 사례 (INC-001.md, INC-002.md, ...)
└── agent-candidates/    ← 에이전트 후보 (promote-agent 전 대기)
```

**SOT 파일 규칙:**
- 한 파일 = 한 사건, 한 결정
- inbox를 실행 컨텍스트에 직접 넣지 않는다
- 같은 문제 2회 이상 반복 → SOT에만 두지 말고 AGENTS.md에 규칙 추가

### Skills (6개)

| Skill | 트리거 | 하는 일 |
|-------|--------|---------|
| `repo-audit` | 주 1회 또는 수동 | 저장소 전체 상태 점검 (규칙, 레지스트리, SOT, 보안) |
| `incidents-to-rule` | incident 작성 후 | 반복 패턴 → AGENTS.md 규칙 후보 생성 |
| `incidents-to-agent` | 동일 실패 3회+ | 새 에이전트 필요성 판단 + 후보 생성 |
| `promote-agent` | 사람 승인 시 | 에이전트 후보 → 정식 에이전트 승격 |
| `changelog-writer` | 배포 전 | Git log + decisions → CHANGELOG.md 작성 |
| `pr-review-fixer` | PR 리뷰 후 | 리뷰 코멘트 → 자동 수정 적용 |

---

## 작업 흐름

### 프롬프트 형식

Claude Code에 작업을 요청할 때 아래 형식을 사용합니다:

```
Task: [작업 설명]

Definition of done:
- [완료 기준 1]
- [완료 기준 2]

Before editing:
- Summarize current patterns in the target area
- List files you will change
- Write a short plan (10 lines max)
- Self-review
- If any rule was missing, draft a SOT/incidents entry
```

### 작업 유형별 흐름

#### 기능 추가

```
사용자: "사용자 프로필 API 추가해줘"
                    ↓
orchestrator.md 참조 → add-feature workflow + feature-builder agent
                    ↓
Step 1: SOT/index.md 읽기 → 현재 상태 파악
Step 2: 대상 디렉토리 AGENTS.md 확인 (services/api/AGENTS.md)
Step 3: DoD 작성 → 사용자 확인
Step 4: 10줄 계획 → 구현 → 테스트
Step 5: Self-review → SOT/index.md 갱신
```

#### 버그 수정

```
사용자: "로그인 시 500 에러 발생"
                    ↓
orchestrator.md 참조 → fix-bug workflow + feature-builder agent
                    ↓
Step 1: 증상/재현조건 파악 → 재현 테스트 작성
Step 2: 코드 흐름 추적 → 근본 원인 특정
Step 3: DoD 작성 → 최소 변경으로 수정
Step 4: 회귀 테스트 추가 → SOT/incidents/INC-NNN.md 작성
```

#### 새 서비스 생성

```
사용자: "결제 서비스 만들어줘"
                    ↓
orchestrator.md 참조 → build-from-scratch workflow + service-builder agent
                    ↓
Step 1: 서비스 목적 + MVP 범위 + 기술 스택 결정
Step 2: SOT/decisions/DEC-NNN.md 기록
Step 3: 디렉토리 구조 설계 → 진입점 생성 → 테스트 구조
Step 4: 하위 AGENTS.md 작성 → SOT/index.md 갱신
```

---

## 자기 진화 시스템

이 프레임워크의 핵심은 **사용할수록 규칙이 쌓여 품질이 자동으로 올라가는 구조**입니다.

### 진화 파이프라인

```
실수 발생
    ↓
SOT/incidents/INC-NNN.md 작성
    ↓
incidents-to-rule skill 실행 (2회 반복 시)
    ↓
AGENTS.md 규칙 후보 생성 → 사람 승인 → 규칙 추가
    ↓
incidents-to-agent skill 실행 (3회 반복 시)
    ↓
SOT/agent-candidates/{name}.md 생성
    ↓
promote-agent skill 실행 → 사람 승인
    ↓
.claude/agents/{name}.md 활성화 + registry 등록
```

### Incident 파일 작성 예시

```markdown
# INC-001: API 응답에 민감 정보 노출
- 날짜: 2026-03-19
- 작업: 사용자 프로필 API 구현
- 증상: GET /users/{id} 응답에 password_hash 필드 포함
- 원인: Pydantic response_model 미설정
- 해결: UserResponse 스키마에 password_hash 제외
- 규칙 후보: "모든 API 엔드포인트는 반드시 response_model을 명시한다"
```

### Decision 파일 작성 예시

```markdown
# DEC-001: ORM으로 SQLAlchemy 2.x 선택
- 날짜: 2026-03-19
- 결정: SQLAlchemy 2.x (async mode)
- 이유: FastAPI async와 자연스러운 통합, 타입 힌트 지원
- 대안: Tortoise ORM (커뮤니티 작음), Prisma (Python 미성숙)
- 영향: services/api/ 전체 DB 레이어에 적용
```

---

## FAQ

### Q: 모든 파일을 처음부터 수정해야 하나요?

아닙니다. **단계별 도입**을 권장합니다:

| 단계 | 시점 | 수정 대상 |
|------|------|-----------|
| 1단계 | Day 1 | `SOT/index.md`, `AGENTS.md`, `CLAUDE.md`, `settings.json`, `orchestrator.md` |
| 2단계 | 1주차 | 하위 `AGENTS.md`, `registry/agents.yml`, 워크플로우 |
| 3단계 | 1~2주차 | `rules/`, `hooks/` |
| 4단계 | 1달 후 | `.github/workflows/` |

### Q: 우리 프로젝트는 모노레포가 아닌데요?

`apps/web/`, `services/api/`, `ml/` 디렉토리는 예시입니다. 프로젝트 구조에 맞게 삭제하고, 실제 소스 디렉토리에 하위 `AGENTS.md`를 배치하세요.

단일 서비스 프로젝트라면:
```
my-project/
├── AGENTS.md          ← 전역 규칙 + 언어별 규칙 포함
├── .claude/           ← 그대로 유지
├── SOT/               ← 그대로 유지
└── src/               ← 소스 코드
```

### Q: 에이전트를 꼭 써야 하나요?

아닙니다. 에이전트는 프레임워크의 선택적 요소입니다. Claude Code에 직접 작업을 지시해도 됩니다. 에이전트 파일은 Claude가 작업할 때 **역할과 완료 기준을 자동으로 참조하는 가이드**입니다.

### Q: `AGENTS.md`가 너무 길어지면요?

150줄 이상이면 `repo-audit`에서 경고합니다. 아래 방법으로 줄입니다:
- 구체적인 숫자/상태 → `SOT/`로 이동
- 언어/프레임워크 특화 규칙 → 하위 `AGENTS.md`로 분리
- 오래된/사용 안 되는 규칙 → 삭제

### Q: 기존 `.claude/` 설정이 있는 프로젝트에 적용하면요?

기존 `settings.json`과 병합이 필요합니다:
1. 기존 `permissions`는 유지하면서 템플릿의 `hooks` 설정을 추가
2. 기존 `.claude/` 파일과 충돌 나는 부분은 수동으로 병합
3. 특히 `CLAUDE.md`는 기존 내용을 보존하면서 `@import` 패턴만 추가

### Q: 팀원들도 이 프레임워크를 같이 쓸 수 있나요?

네. `.claude/settings.local.json`을 제외한 모든 설정이 Git에 커밋됩니다. 팀원이 Claude Code를 실행하면 동일한 규칙이 자동 적용됩니다. 개인 설정은 `settings.local.json`에 작성하고 `.gitignore`에 포함되어 있습니다.
