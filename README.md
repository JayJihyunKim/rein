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

## 빠른 시작

```bash
# 1. AGENTS.md와 .claude/CLAUDE.md를 프로젝트에 맞게 수정
# 2. SOT/index.md에 프로젝트 현재 상태 작성
# 3. Claude Code 실행
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

## 참고 저장소

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [getsentry/sentry](https://github.com/getsentry/sentry) — 실사용 AGENTS.md 예시
- [anthropics/skills](https://github.com/anthropics/skills) — skill 정의 방식
