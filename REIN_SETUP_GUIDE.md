# AI-Native 프레임워크 적용 가이드

> 이 문서는 Rein 프레임워크를 새 프로젝트에 적용하는 방법을 설명합니다.

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
4. trail은 읽는 저장소가 아니라 **증거 저장소**다
5. 에이전트는 **역할 경계가 한 문장으로 설명될 때만** 분리한다

---

## 적용 방법

> **Windows 사용자**: Rein 은 bash + GNU coreutils + POSIX Python API 를 전제로 하므로 **WSL2 (Ubuntu) 환경**에서 사용하세요. PowerShell 을 관리자 권한으로 열고 `wsl --install` 을 실행한 뒤, WSL Ubuntu 셸 안에서 아래 방법 중 하나를 따르면 됩니다. 자세한 설치 방법은 [README.md 의 "Windows 사용자" 섹션](README.md#windows-사용자) 을 참조하세요.

### Windows Git Bash 설치 전 체크 (v0.10.1+)

Git Bash / MSYS2 로 advisory 경로를 사용하는 경우, 설치를 시작하기 전에 Python 런타임이 실제로 실행되는지 아래 3종 명령으로 확인하세요:

- [ ] `command -v python3` 가 경로를 출력하는가?
- [ ] `python3 -V` 가 실제 버전을 출력하는가?
- [ ] `py -3 -V` 가 성공하는가?

셋 중 하나라도 실패하면 훅이 `BLOCKED: ... Python launch 실패 (9009 계열)` 으로 차단될 가능성이 높습니다. 해결 절차는 [README.md 의 "Windows Git Bash 진단" 섹션](README.md#windows-git-bash-진단-v0101)을 참조하세요 (WSL2 전환 · App execution aliases 끄기 · `REIN_PYTHON` / venv 지정).

### 방법 A: 새 프로젝트를 템플릿으로 생성

```bash
# GitHub CLI로 템플릿 기반 새 레포 생성 + 로컬 클론
gh repo create my-project \
  --template JayJihyunKim/rein \
  --private --clone

cd my-project
```

### 방법 B: 기존 프로젝트에 파일 복사

```bash
# 1. 템플릿 임시 클론
gh repo clone JayJihyunKim/rein /tmp/rein-template

# 2. 핵심 파일 복사
cp -r /tmp/rein-template/.claude  /path/to/your-project/
cp -r /tmp/rein-template/trail   /path/to/your-project/
cp -r /tmp/rein-template/.github /path/to/your-project/
cp    /tmp/rein-template/AGENTS.md /path/to/your-project/

# 3. .gitignore에 추가 (기존 .gitignore가 있다면 병합)
cat /tmp/rein-template/.gitignore >> /path/to/your-project/.gitignore

# 4. 정리
rm -rf /tmp/rein-template
```

### 방법 C: Git remote로 머지 (템플릿 업데이트 추적 가능)

```bash
cd /path/to/your-project

git remote add template git@github.com:JayJihyunKim/rein.git
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

### v1.x → v2.0 Migration (`rein migrate`)

v2.0 부터 `rein init` 의 기본 모드가 **plugin 모드** 로 변경됐습니다. 기존 v1.x 사용자(`scaffold` 모드로 설치된 repo)는 두 가지 선택지가 있습니다.

**선택 A — 그대로 scaffold 모드 유지** (변경 없음)

```bash
rein update      # 기존처럼 작동, scaffold 모드 유지. 추가 작업 없음.
```

`rein init --mode=scaffold` 가 v2.5+ 부터 stderr deprecation warning 을 emit 하지만 **v3.0 까지는 정상 동작**합니다. 기존 워크플로 그대로 유지 가능.

**선택 B — plugin 모드로 전환** (권장)

```bash
rein migrate     # 자동 변환:
                 #   - .claude/.rein-manifest.json 제거
                 #   - .claude/settings.json 에 plugin pin 추가
                 #   - .claude/hooks/, .claude/skills/, .claude/agents/ 의 plugin 미러 파일 제거
                 #     (scaffold-overlay 만 남기고 SSOT 는 plugin 으로 이관)
                 #   - .rein/project.json 에 mode=plugin 기록
                 #   - .rein/policy/router/ 로 router 학습 데이터 이관
```

전환 후 변화:
- repo 가 가벼워짐 (수십 개 파일이 plugin 영역으로 이동)
- `rein update` 대신 Claude Code 가 plugin marketplace 에서 자동 fetch
- hook/skill 직접 수정이 필요하면 `.rein/policy/{hooks,rules}.yaml` 로 override 가능
- 사용자 편집한 `.claude/CLAUDE.md` 는 plugin 모드에서 **건드리지 않음** (소유권 환원)

전환 전 백업 권장:
```bash
cp -r .claude .claude.backup-pre-v2-migrate
rein migrate
# 문제 발생 시: rm -rf .claude && mv .claude.backup-pre-v2-migrate .claude
```

migrate 가 자동 처리하지 못하는 케이스(매우 광범위한 hook 커스터마이징 등)는 `--dry-run` 으로 미리 확인:
```bash
rein migrate --dry-run
```

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
│   │   ├── plan-writer.md
│   │   ├── researcher.md
│   │   ├── docs-writer.md
│   │   └── security-reviewer.md
│   ├── skills/                  ← 특정 시점 호출 스킬
│   │   ├── repo-audit/
│   │   ├── incidents-to-rule/
│   │   ├── incidents-to-agent/
│   │   ├── promote-agent/
│   │   ├── changelog-writer/
│   │   └── pr-review-fixer/
│   └── hooks/                   ← 라이프사이클 자동화 스크립트
│       ├── post-edit-hygiene.sh
│       ├── post-edit-lint.sh.example  ← 언어별 autofix 예시 (복사 후 수정)
│       └── pre-bash-guard.sh
├── trail/                         ← 증거 저장소 (상태/결정/사고 기록)
│   ├── index.md                 ← 현재 프로젝트 상태 (5~15줄)
│   ├── inbox/                   ← 세션 원본 로그
│   ├── daily/                   ← 하루 1회 압축 요약
│   ├── weekly/                  ← 주 1회 재요약
│   ├── decisions/               ← 확정 기술/운영 결정 (DEC-NNN.md)
│   ├── incidents/               ← 실패 사례, 반복 문제 (INC-NNN.md)
│   └── agent-candidates/        ← 에이전트 승격 후보
└── .github/workflows/           ← GitHub Actions 자동화
    ├── daily-trail-audit.yml
    ├── repo-audit.yml
    ├── issue-triage.yml
    └── weekly-agent-evolution.yml
```

### 컨텍스트 로딩 순서

Claude Code가 세션 시작 시 자동으로 읽는 순서:

```
1. .claude/CLAUDE.md          — 자동 로드 (진입점, @import 허브)
2. AGENTS.md                  — 전역 실행 규칙
3. 작업 디렉토리의 nearest AGENTS.md — 언어/프레임워크별 규칙 (예: src/api/AGENTS.md)
4. trail/index.md               — 현재 프로젝트 상태 (5~15줄)
```

필요시 추가 로드:
- `.claude/workflows/[해당].md` — 작업 유형에 따른 절차서
- `.claude/agents/[해당].md` — 담당 에이전트 정의

---

## 단계별 커스터마이징

### 1단계: 핵심 설정 (Day 1) — 반드시 수정

프레임워크를 적용한 직후, 아래 5개 파일을 프로젝트에 맞게 수정합니다.

#### 1-1. `trail/index.md` — 프로젝트 현재 상태

**가장 먼저 수정해야 할 파일입니다.** 5~15줄로 프로젝트 상태를 작성합니다.

```markdown
# trail/index.md — 현재 프로젝트 상태

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

#### 1-6. Slash command 호출 규약 (플러그인 모드, v2.0+)

플러그인 모드에서 Rein 의 스킬은 `/rein-core:` 네임스페이스 아래로 노출됩니다. 예를 들어 코드 리뷰 스킬은 `/rein-core:codex-review`, second-opinion 스킬은 `/rein-core:codex-ask` 로 호출합니다.

##### Custom alias 권장
설정 파일 `.claude/settings.json` 에 다음 추가 시 짧은 호출 가능:
```json
{
  "aliases": {
    "/cr": "/rein-core:codex-review",
    "/ca": "/rein-core:codex-ask"
  }
}
```

`aliases` 는 **사용자 opt-in 커스터마이징**입니다. `rein init` 이 기본값으로 등록하지 않으므로 짧은 호출이 필요한 사용자만 추가하세요.

---

### 2단계: 에이전트 & 워크플로우 조정 (1주차)

#### 2-1. 하위 AGENTS.md 작성

프로젝트의 소스 디렉토리마다 하위 AGENTS.md를 작성합니다. Claude Code는 작업 디렉토리에서 가장 가까운 AGENTS.md를 자동으로 로드합니다.

**하위 AGENTS.md 필수 포함 항목:**
- 기술 스택 (언어, 프레임워크, 버전)
- 실행 명령어 (dev, build, test, lint)
- 디렉토리 구조
- 코딩 규칙 (언어/프레임워크 특화)
- 금지 패턴

프로젝트 구조에 맞게 아래 예시 중 필요한 것을 복사하여 사용하세요.

<details>
<summary><b>예시 A: Next.js / TypeScript 프론트엔드</b> (클릭하여 펼치기)</summary>

```markdown
# frontend/AGENTS.md — Next.js / TypeScript 규칙

> 이 파일은 frontend/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 Next.js/TypeScript 특화 규칙만 추가한다.

## 기술 스택
- **Framework**: Next.js 15 (App Router)
- **Language**: TypeScript 5.x
- **Styling**: Tailwind CSS + shadcn/ui
- **State**: Zustand (전역) / React Query (서버 상태)
- **Testing**: Vitest + Testing Library
- **Lint**: ESLint + Prettier

## 실행 명령어
npm run dev        # 개발 서버
npm run build      # 프로덕션 빌드
npm run test       # 테스트 실행
npm run lint       # ESLint 실행
npm run type-check # TypeScript 타입 검사

## 디렉토리 구조
app/           # Next.js App Router 페이지
components/    # 재사용 가능한 UI 컴포넌트
  ui/          # shadcn/ui 기반 기본 컴포넌트
  [feature]/   # 기능별 컴포넌트
hooks/         # 커스텀 React hooks
lib/           # 유틸리티 함수
store/         # Zustand 상태 관리
types/         # TypeScript 타입 정의

## TypeScript 규칙
- `any` 타입 사용 금지 — `unknown` 또는 구체 타입 사용
- 컴포넌트 props는 반드시 interface로 정의
- API 응답 타입은 `types/` 폴더에 중앙 관리
- `as` 타입 단언은 최소화 (불가피한 경우 주석으로 이유 설명)

## 컴포넌트 규칙
- 서버 컴포넌트와 클라이언트 컴포넌트를 명확히 분리
- 클라이언트 컴포넌트는 파일 상단에 `'use client'` 필수
- 컴포넌트 파일명: PascalCase (`UserCard.tsx`)
- 한 파일에 한 컴포넌트 (default export)

## 금지 패턴
- `pages/` 디렉토리 사용 금지 (App Router 전용)
- `useEffect`로 데이터 패칭 금지 → React Query 사용
- 인라인 스타일 (`style={{}}`) 금지 → Tailwind 클래스 사용
- `console.log` 운영 코드 방치 금지
```
</details>

<details>
<summary><b>예시 B: Python / FastAPI 백엔드</b> (클릭하여 펼치기)</summary>

```markdown
# api/AGENTS.md — Python API 규칙

> 이 파일은 api/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 Python/FastAPI 특화 규칙만 추가한다.

## 기술 스택
- **Language**: Python 3.12+
- **Framework**: FastAPI
- **ORM**: SQLAlchemy 2.x (async)
- **Validation**: Pydantic v2
- **Testing**: pytest + httpx
- **Lint**: Ruff + mypy

## 실행 명령어
uvicorn main:app --reload      # 개발 서버
pytest                         # 테스트 실행
ruff check . --fix             # Lint 수정
ruff format .                  # 코드 포맷
mypy .                         # 타입 검사

## 디렉토리 구조
app/
  routers/       # API 라우터 (기능별 분리)
  models/        # SQLAlchemy 모델
  schemas/       # Pydantic 스키마 (request/response)
  services/      # 비즈니스 로직
  repositories/  # DB 접근 계층
  core/          # 설정, 의존성, 미들웨어
tests/
  unit/
  integration/
alembic/         # DB 마이그레이션

## Python 코딩 규칙
- 타입 힌트 필수 (모든 함수 파라미터 및 반환값)
- async/await 일관 사용 (sync 함수와 혼용 금지)
- Pydantic 모델로 모든 외부 입력 검증
- 의존성 주입은 FastAPI `Depends()` 활용
- DB 쿼리는 Repository 계층에서만

## 금지 패턴
- 직접 SQL 문자열 조합 금지 → SQLAlchemy ORM 또는 파라미터화 쿼리
- 라우터에 비즈니스 로직 작성 금지 → services/ 계층으로 분리
- 전역 변수로 상태 관리 금지
- `print()` 디버그 코드 방치 금지 → `logging` 모듈 사용
```
</details>

<details>
<summary><b>예시 C: ML 파이프라인</b> (클릭하여 펼치기)</summary>

```markdown
# ml/AGENTS.md — ML 파이프라인 규칙

> 이 파일은 ml/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 ML 파이프라인 특화 규칙만 추가한다.

## 기술 스택
- **Language**: Python 3.12+
- **ML Framework**: PyTorch / scikit-learn
- **실험 추적**: MLflow 또는 Weights & Biases
- **데이터 버저닝**: DVC
- **Testing**: pytest

## 실행 명령어
python train.py --config configs/default.yaml   # 학습
python evaluate.py --model [checkpoint]          # 평가
dvc repro                                        # 파이프라인 재실행
pytest tests/                                    # 테스트

## 디렉토리 구조
configs/          # 실험 설정 파일 (YAML)
data/             # 데이터 (DVC로 버전 관리)
  raw/
  processed/
models/           # 모델 정의
pipelines/        # 학습/평가 파이프라인
notebooks/        # 탐색적 분석 (실험용만)
tests/

## ML 코딩 규칙
- 모든 실험은 설정 파일(YAML)로 관리 — 하드코딩된 하이퍼파라미터 금지
- 학습 결과는 MLflow/W&B에 반드시 로깅
- 재현 가능성: 랜덤 시드 고정 및 설정 파일에 기록
- 데이터 버전은 DVC로 관리 (raw 데이터 Git 커밋 금지)

## 금지 패턴
- Jupyter Notebook에 운영 코드 작성 금지 (탐색용만)
- 학습 데이터 Git 직접 커밋 금지
- 실험 결과를 파일명으로만 관리 금지 (`model_v3_final.pt` 등)
- 랜덤 시드 미설정 학습 금지
```
</details>

#### 2-2. 에이전트 조정

프로젝트에서 사용하지 않을 에이전트를 `registry/agents.yml`에서 비활성화합니다.

```yaml
# 사용하지 않는 에이전트
# - name: researcher
#   status: inactive
```

**에이전트는 5개가 기본 제공됩니다:**

| 에이전트 | 역할 |
|---|---|
| `feature-builder` | 기능 추가/버그 수정/새 모듈 초기화 |
| `plan-writer` | design → plan 변환 + coverage 매트릭스 |
| `researcher` | 기술 조사 |
| `docs-writer` | 문서/CHANGELOG/설계 산문 |
| `security-reviewer` | 보안 리뷰 |

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

**기본 제공:**

| Hook | 트리거 | 동작 |
|------|--------|------|
| `post-edit-hygiene.sh` | 파일 Edit/Write 후 | 언어 중립 위생 검사 (trailing whitespace, DoD 마커 등) |
| `post-edit-lint.sh.example` | — (복사 후 활성화) | 언어별 autofix 예시 (eslint, ruff 등). 필요 시 복사하여 수정 |
| `pre-bash-guard.sh` | Bash 명령 실행 전 | 위험 명령어 차단 (pipe to shell, force push 등) |

**Hook 동작 원리:**

```
PostToolUse(Edit|Write) → post-edit-hygiene.sh
  └── 도메인·언어 무관 위생 검사 (trailing whitespace, DoD stamp 등)

PostToolUse(Edit|Write) → post-edit-lint.sh  (활성화 시)
  ├── .ts/.tsx/.js/.jsx → npx eslint --fix
  └── .py → ruff check --fix + ruff format

PreToolUse(Bash) → pre-bash-guard.sh
  ├── `| bash` or `| sh` → 즉시 차단 (exit 1)
  └── `git reset --hard` 등 → 확인 요청 (exit 2)
```

**프로젝트에 맞게 수정할 포인트:**
- 언어별 autofix 필요 시: `post-edit-lint.sh.example` 을 `post-edit-lint.sh` 로 복사 후 린터 교체 (예: `biome`, `black`)
- `pre-bash-guard.sh`: 차단할 위험 명령어 패턴 추가

---

### 4단계: GitHub Actions 설정 (1달 후)

프로젝트가 안정되면 자동화를 활성화합니다.

| 워크플로우 | 주기 | 하는 일 |
|-----------|------|---------|
| `daily-trail-audit.yml` | 매일 18:00 UTC | trail/index.md 줄 수, inbox 미압축 파일 확인 |
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
- §8 trail 운영 규칙
- §9 컨텍스트 절감 전략
- §10 Git 규칙

**중요**: 결과가 나쁘면 출력물이 아니라 **이 파일을 수정**합니다. 같은 문제가 2번 반복되면 즉시 이 파일에 규칙을 추가합니다.

#### `trail/index.md` — 프로젝트 상태

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

### trail 디렉토리 구조

```
trail/
├── index.md             ← 현재 상태 (5~15줄, 매 세션 갱신)
├── inbox/               ← 세션 원본 로그 → daily에서 요약 후 삭제
├── daily/               ← 하루 1회 압축 요약
├── weekly/              ← 주 1회 재요약
├── decisions/           ← 기술 결정 (DEC-001.md, DEC-002.md, ...)
├── incidents/           ← 실패 사례 (INC-001.md, INC-002.md, ...)
└── agent-candidates/    ← 에이전트 후보 (promote-agent 전 대기)
```

**trail 파일 규칙:**
- 한 파일 = 한 사건, 한 결정
- inbox를 실행 컨텍스트에 직접 넣지 않는다
- 같은 문제 2회 이상 반복 → trail에만 두지 말고 AGENTS.md에 규칙 추가

### Skills (6개)

| Skill | 트리거 | 하는 일 |
|-------|--------|---------|
| `repo-audit` | 주 1회 또는 수동 | 저장소 전체 상태 점검 (규칙, 레지스트리, trail, 보안) |
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
- If any rule was missing, draft a trail/incidents entry
```

### 작업 유형별 흐름

#### 기능 추가

```
사용자: "사용자 프로필 API 추가해줘"
                    ↓
orchestrator.md 참조 → add-feature workflow + feature-builder agent
                    ↓
Step 1: trail/index.md 읽기 → 현재 상태 파악
Step 2: 대상 디렉토리 AGENTS.md 확인 (services/api/AGENTS.md)
Step 3: DoD 작성 → 사용자 확인
Step 4: 10줄 계획 → 구현 → 테스트
Step 5: Self-review → trail/index.md 갱신
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
Step 4: 회귀 테스트 추가 → trail/incidents/INC-NNN.md 작성
```

#### 새 서비스 생성

```
사용자: "결제 서비스 만들어줘"
                    ↓
orchestrator.md 참조 → build-from-scratch workflow + feature-builder agent
                    ↓
Step 1: 서비스 목적 + MVP 범위 + 기술 스택 결정
Step 2: trail/decisions/DEC-NNN.md 기록
Step 3: 디렉토리 구조 설계 → 진입점 생성 → 테스트 구조
Step 4: 하위 AGENTS.md 작성 → trail/index.md 갱신
```

---

## 자기 진화 시스템

이 프레임워크의 핵심은 **사용할수록 규칙이 쌓여 품질이 자동으로 올라가는 구조**입니다.

### 진화 파이프라인

```
실수 발생
    ↓
trail/incidents/INC-NNN.md 작성
    ↓
incidents-to-rule skill 실행 (2회 반복 시)
    ↓
AGENTS.md 규칙 후보 생성 → 사람 승인 → 규칙 추가
    ↓
incidents-to-agent skill 실행 (3회 반복 시)
    ↓
trail/agent-candidates/{name}.md 생성
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
| 1단계 | Day 1 | `trail/index.md`, `AGENTS.md`, `CLAUDE.md`, `settings.json`, `orchestrator.md` |
| 2단계 | 1주차 | 하위 `AGENTS.md`, `registry/agents.yml`, 워크플로우 |
| 3단계 | 1~2주차 | `rules/`, `hooks/` |
| 4단계 | 1달 후 | `.github/workflows/` |

### Q: 하위 AGENTS.md는 어떻게 만드나요?

SETUP_GUIDE의 [2단계: 하위 AGENTS.md 작성](#2-1-하위-agentsmd-작성)에 프론트엔드/백엔드/ML 예시가 있습니다. 프로젝트의 소스 디렉토리에 맞게 복사하여 사용하세요.

단일 서비스 프로젝트라면 하위 AGENTS.md 없이 전역 AGENTS.md에 규칙을 통합해도 됩니다:
```
my-project/
├── AGENTS.md          ← 전역 규칙 + 언어별 규칙 포함
├── .claude/           ← 그대로 유지
├── trail/               ← 그대로 유지
└── src/               ← 소스 코드
```

### Q: 에이전트를 꼭 써야 하나요?

아닙니다. 에이전트는 프레임워크의 선택적 요소입니다. Claude Code에 직접 작업을 지시해도 됩니다. 에이전트 파일은 Claude가 작업할 때 **역할과 완료 기준을 자동으로 참조하는 가이드**입니다.

### Q: `AGENTS.md`가 너무 길어지면요?

150줄 이상이면 `repo-audit`에서 경고합니다. 아래 방법으로 줄입니다:
- 구체적인 숫자/상태 → `trail/`로 이동
- 언어/프레임워크 특화 규칙 → 하위 `AGENTS.md`로 분리
- 오래된/사용 안 되는 규칙 → 삭제

### Q: 기존 `.claude/` 설정이 있는 프로젝트에 적용하면요?

기존 `settings.json`과 병합이 필요합니다:
1. 기존 `permissions`는 유지하면서 템플릿의 `hooks` 설정을 추가
2. 기존 `.claude/` 파일과 충돌 나는 부분은 수동으로 병합
3. 특히 `CLAUDE.md`는 기존 내용을 보존하면서 `@import` 패턴만 추가

### Q: 팀원들도 이 프레임워크를 같이 쓸 수 있나요?

네. `.claude/settings.local.json`을 제외한 모든 설정이 Git에 커밋됩니다. 팀원이 Claude Code를 실행하면 동일한 규칙이 자동 적용됩니다. 개인 설정은 `settings.local.json`에 작성하고 `.gitignore`에 포함되어 있습니다.

### Q: `everything-claude-code` 플러그인을 함께 써도 되나요?

**쓰지 마세요.** `everything-claude-code` (>= 1.9.0) 의 `gateguard-fact-force` 훅은 Rein 환경에서 deadlock 을 유발합니다.

- **증상**: 세션 시작 직후 모든 Edit/Write/Bash 호출이 `[Fact-Forcing Gate] Quote the user's current instruction verbatim` 메시지로 계속 차단되어 진행 불가.
- **원인**: gateguard 가 `CLAUDE_SESSION_ID` / `ECC_SESSION_ID` 미설정 시 `pid-${ppid}` 를 fallback 세션 ID 로 사용합니다. Claude Code 는 tool 호출마다 새 node subprocess 를 spawn 하므로 PID 가 매번 달라져 state 파일이 새로 생성되고, 직전 "checked" 기록을 읽지 못해 **매 호출이 "첫 실행"으로 판정되어 영원히 deny** 됩니다. `~/.gateguard/` 에 PID 다른 state 파일이 세션당 수십 개 누적되는 것으로 재현 확인 가능.
- **중복 기능**: Rein 은 `.claude/hooks/pre-bash-guard.sh` + `pre-edit-dod-gate.sh` 로 동등한 fact-forcing / DoD gate 를 이미 제공합니다. gateguard 를 따로 쓸 이유가 없습니다.
- **조치**:
  1. `/plugin` 명령으로 `everything-claude-code` 언인스톨
  2. 캐시 정리: `rm -rf ~/.claude/plugins/cache/everything-claude-code ~/.gateguard`
  3. Claude Code 세션 재시작

업스트림 (`zunoworks/gateguard`) 이 PID fallback 을 보다 안정적인 식별자 (예: `CLAUDE_SESSION_ID` 필수화, tty 기반, parent-chain 기반) 로 교체할 때까지는 병용 불가입니다.

### Q: `rein --version` 이 구버전으로 나오는데요?

v0.6.x 이전 버전에서는 `rein update` 가 템플릿 파일만 갱신하고 CLI 바이너리 자체는 그대로 두었습니다. v0.7.0 부터는 `rein update` 가 시작 시 CLI 버전을 체크해서 자동으로 최신 버전으로 교체합니다.

**원인별 조치**:

- **v0.6.x 이하 사용자**: `curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash` 로 v0.7.0+ 를 설치하면 이후부터는 `rein update` 가 자동 처리
- **v0.7.0+ 사용자인데 여전히 구버전 표시**: `rein update --yes` 로 자가 업데이트 강제 실행
- **`rein self-update` 없나?**: 현재는 `rein update` 안에 통합. 향후 릴리즈에서 분리 가능성 있음

### Q: 왜 `$HOME/.rein/` 에 설치되나요?

sudo 없이 설치·업데이트·제거가 가능하도록 rustup 패턴을 따릅니다.

**이유**:
1. **sudo 불필요** — 사용자 개인 개발 도구이므로 시스템 전역 (`/usr/local/bin`) 에 둘 이유가 없음
2. **자가 업데이트 자연스러움** — `rein update` 가 자기 자신을 `cp` 한 번으로 갱신
3. **CI 친화적** — Docker, GitHub Actions 등 sudo 없는 환경에서도 설치 가능
4. **관례 일치** — 이미 갖고 계신 `.claude/`, `.ssh/`, `.config/` 와 같은 계층

**디렉토리 구조**:

```
$HOME/.rein/
├── bin/rein       ← CLI 실행 파일
└── env            ← PATH 설정 (. ~/.rein/env 로 소스)
```

PATH 에 추가하려면 셸 rc 에 아래 한 줄:

```bash
. "$HOME/.rein/env"
```

설치 스크립트가 자동으로 추가해줍니다 (프롬프트 확인 후).

---

## Breaking changes (v0.8.0)

v0.8.0 에서 코어 하네스를 "도메인·언어 무관 메타-하네스" 로 명확화했습니다. 다음 변경점이 사용자 프로젝트에 영향을 줍니다:

| 변경 | 영향 | 사용자 조치 |
|---|---|---|
| Stitch / shadcn 스킬 8개 번들 제거 | `.claude/skills/` 에서 사라짐 | 필요하면 개인적으로 재설치 (후속 플러그인 릴리스 대기) |
| StitchMCP 설정 제거 | `.claude/settings.json` 에서 사라짐 | 사용자가 `.claude/settings.local.json` 에 개인 추가 |
| 에이전트 `service-builder`, `reviewer` 제거 | 라우팅은 `feature-builder` + `/codex-review` 로 자동 매핑 | 없음 |
| `post-edit-lint.sh` → `post-edit-hygiene.sh` + `.example` | 기본 훅 이름/동작 변경 | 언어별 autofix 필요 시 `post-edit-lint.sh.example` 복사 후 수정 |
| `task-completed-incident.sh` 제거 | 기능은 `stop-session-gate.sh` 내부로 이동 | 없음 |
| `inbox-compress.sh` → `trail-rotate.sh` 리네임 | 1-release wrapper alias 유지, 다음 릴리스에서 제거 | 외부 참조가 있다면 `trail-rotate.sh` 로 업데이트 |
| AGENTS.md `/codex-review` fallback 체인 | `superpowers:code-reviewer` → rein 자체 `code-reviewer` 스킬 | 없음 |
| `feedback-log.yaml` + `overrides.yaml` 스키마 확장 (`invalid_ids`) | 하위 호환 유지 | v1.1.2+ 에서는 작업 없음. v0.8.0 ~ v1.1.1 에는 `python3 scripts/rein-route-record.py doctor` 를 1회 실행. v1.1.2 에서 `doctor` 서브커맨드는 제거됨 (schema 안정화 후 dead code 였고 macOS CI PyYAML 블로커였음). |
