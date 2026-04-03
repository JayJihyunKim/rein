# Claude Code AI-Native Repo Template

이 저장소는 **AI Native** 방식으로 Claude Code를 운영하기 위한 템플릿입니다.

## AI Native란?

| 구분 | AI Assisted (기존) | AI Native (목표) |
|------|-------------------|-----------------|
| 지시 방식 | "이 함수 이렇게 만들어줘" | "이 워크플로우를 실행해줘" |
| 기준 위치 | 사람 머릿속 | 문서 파일 |
| 실패 대응 | 출력물 다시 요청 | 원인 분석 후 규칙 문서 수정 |
| 확장성 | 매번 사람이 개입 | 규칙이 쌓일수록 품질 자동 상승 |

## 핵심 원칙

1. 매 작업 시작 전에 **완료 기준(Definition of Done)을 먼저** 적는다
2. 결과가 나쁘면 출력물이 아니라 **시스템(규칙 파일)을 수정**한다
3. 같은 문제가 **2번 반복되면 즉시 AGENTS.md 규칙으로 승격**한다
4. SOT는 읽는 저장소가 아니라 **증거 저장소**다
5. 에이전트는 **역할 경계가 한 문장으로 설명될 때만** 분리한다

## 폴더 구조

```
repo/
├── AGENTS.md                    ← 전역 실행 규칙 (source of truth)
├── .claude/
│   ├── CLAUDE.md                ← 진입점 + @import 허브
│   ├── settings.json            ← 권한 및 동작 설정 (Hooks 포함)
│   ├── orchestrator.md          ← 작업 유형별 라우팅 기준
│   ├── registry/agents.yml      ← 활성 에이전트 목록
│   ├── rules/                   ← 경로 스코프 규칙
│   ├── workflows/               ← 작업 유형별 절차
│   ├── agents/                  ← 역할별 에이전트 정의
│   ├── skills/                  ← 특정 시점에 호출되는 스킬
│   └── hooks/                   ← 라이프사이클 자동화 스크립트
├── SOT/                         ← 증거 저장소 (상태/결정/사고 기록)
└── .github/workflows/           ← GitHub Actions 자동화
```

## 새 프로젝트에 적용하기

### 설치

```bash
gh api repos/JayJihyunKim/claude-code-ai-native/contents/scripts/claude-init.sh --jq '.content' | base64 -d | sudo tee /usr/local/bin/claude-init > /dev/null && sudo chmod +x /usr/local/bin/claude-init
```

> `gh` CLI가 필요합니다. (`brew install gh && gh auth login`)

### 새 프로젝트 생성

```bash
claude-init new my-project
cd my-project && git init
```

템플릿의 `.claude/`, `SOT/`, `AGENTS.md`가 자동으로 복사되고 `{{PROJECT_NAME}}`이 프로젝트명으로 치환됩니다.

### 기존 프로젝트에 병합

```bash
cd existing-project
claude-init merge
```

이미 존재하는 파일은 `[overwrite / skip / diff]` 프롬프트로 하나씩 확인합니다.

### 템플릿 업데이트

```bash
cd existing-project
claude-init update
```

템플릿 레포의 최신 버전과 비교하여 변경된 파일만 업데이트합니다. 동일한 파일은 건너뛰고, 다른 파일만 프롬프트로 확인합니다.

### 환경변수

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `CLAUDE_TEMPLATE_REPO` | 템플릿 Git 레포 URL | `git@github.com:JayJihyunKim/claude-code-ai-native.git` |

Fork하거나 별도 템플릿 레포를 사용하려면:
```bash
CLAUDE_TEMPLATE_REPO="git@github.com:my-org/my-template.git" claude-init new my-project
```

> 상세한 커스터마이징 방법은 [docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)를 참고하세요.

## 빠른 시작

```bash
# 1. SOT/index.md에 프로젝트 현재 상태 작성
# 2. AGENTS.md와 .claude/CLAUDE.md를 프로젝트에 맞게 수정
# 3. Stitch MCP 연결 (UI 디자인 스킬 사용 시)
cp .claude/settings.local.json.example .claude/settings.local.json
# settings.local.json에 본인의 STITCH_API_KEY 입력
# 4. Claude Code 실행
claude
```

### 작업 요청 프롬프트 형식
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

## 단계별 도입 로드맵

| 단계 | 시점 | 내용 |
|------|------|------|
| 1단계 | Day 1 | AGENTS.md, CLAUDE.md, settings.json, orchestrator.md, SOT/index.md |
| 2단계 | 1주차 | workflows/, agents/, registry/agents.yml |
| 3단계 | 1~2주차 | rules/, skills/, hooks/ |
| 4단계 | 1달 후 | .github/workflows/ 자동화 |

## 포함된 스킬

### 프로젝트 운영 스킬
| 스킬 | 역할 |
|------|------|
| `repo-audit` | 저장소 상태 점검 |
| `pr-review-fixer` | PR 리뷰 코멘트 자동 수정 |
| `incidents-to-rule` | incident → AGENTS.md 규칙 후보 생성 |
| `incidents-to-agent` | 반복 패턴 → 에이전트 후보 생성 |
| `changelog-writer` | CHANGELOG 자동 작성 |
| `promote-agent` | 에이전트 후보 승격 |

### Stitch UI 디자인 스킬 (Stitch MCP 필요)
| 스킬 | 역할 |
|------|------|
| `stitch-design` | 디자인 시스템 총괄, 프롬프트 강화 |
| `stitch-loop` | 바톤 패턴 멀티페이지 자동 생성 |
| `design-md` | 프로젝트 → DESIGN.md 추출 |
| `enhance-prompt` | 모호한 UI 요청 → 정교한 프롬프트 변환 |
| `react-components` | 디자인 → React 컴포넌트 코드 변환 |
| `shadcn-ui` | shadcn/ui 컴포넌트 통합 가이드 |
| `taste-design` | 프리미엄 안티제네릭 디자인 기준 |
| `remotion` | 워크스루 영상 생성 |

> Stitch 스킬은 호출 시에만 로드되므로 미사용 시 컨텍스트를 차지하지 않습니다.
> Stitch MCP 없이도 `enhance-prompt`, `taste-design`, `shadcn-ui`는 독립적으로 사용 가능합니다.

## 참고 저장소

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [getsentry/sentry](https://github.com/getsentry/sentry) — 실사용 AGENTS.md 예시
- [anthropics/skills](https://github.com/anthropics/skills) — skill 정의 방식
- [google-labs-code/stitch-skills](https://github.com/google-labs-code/stitch-skills) — Stitch UI 디자인 스킬
