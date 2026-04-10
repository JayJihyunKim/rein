# claude-init: 템플릿 이식 CLI 도구

> 설계 승인일: 2026-04-03

## 목적

`claude-code-ai-native` 레포의 Claude Code 설정 (.claude/, SOT/, AGENTS.md)을 다른 프로젝트에 쉽게 이식하기 위한 단일 셸 스크립트 CLI 도구.

## 명령어

```bash
claude-init new <project-name>   # 새 프로젝트 생성
claude-init merge                # 기존 프로젝트에 병합 (프로젝트 루트에서)
claude-init update               # 템플릿 최신 버전으로 업데이트 (프로젝트 루트에서)
```

## 동작 흐름

### `new <project-name>`

1. 대상 디렉토리가 이미 존재하면 에러 종료
2. 템플릿 레포를 임시 디렉토리에 `git clone --depth 1`
3. 대상 디렉토리 생성
4. 복사 대상 파일을 대상 디렉토리에 복사
5. `.md` 파일 내 `{{PROJECT_NAME}}`을 `<project-name>`으로 치환
6. 임시 디렉토리 정리

### `merge`

1. 현재 디렉토리에 `.git`이 있는지 확인 (없으면 에러 종료)
2. 템플릿 레포를 임시 디렉토리에 `git clone --depth 1`
3. 복사 대상 파일을 순회하며:
   - 파일이 없으면 → 바로 복사
   - 파일이 있으면 → 충돌 프롬프트
4. `.md` 파일 내 `{{PROJECT_NAME}}`을 현재 디렉토리명으로 치환
5. 임시 디렉토리 정리

### `update`

`merge`와 동일한 로직. 의미적 차이만 존재 (최초 병합 vs 이후 업데이트).
내부적으로 같은 함수를 호출한다.

## 복사 대상

```
.claude/CLAUDE.md
.claude/settings.json
.claude/settings.local.json.example
.claude/orchestrator.md
.claude/hooks/*
.claude/rules/*
.claude/workflows/*
.claude/agents/*
.claude/registry/*
.claude/skills/**/*
SOT/  (디렉토리 구조 + .gitkeep만)
AGENTS.md
```

## 제외 대상

```
.claude/settings.local.json
.claude/plans/*
SOT/inbox/*   (.gitkeep 제외)
SOT/daily/*   (.gitkeep 제외)
SOT/weekly/*  (.gitkeep 제외)
SOT/incidents/* (.gitkeep 제외)
SOT/dod/*     (.gitkeep 제외)
```

## 충돌 처리 (merge/update)

파일이 이미 존재할 때 표시되는 프롬프트:

```
File exists: .claude/rules/code-style.md
  [o]verwrite  [s]kip  [d]iff  [a]ll-overwrite  [q]uit  → 
```

| 선택 | 동작 |
|------|------|
| `o` | 템플릿 버전으로 교체 |
| `s` | 기존 파일 유지 |
| `d` | `diff --color` 출력 후 다시 `o/s` 선택 |
| `a` | 이후 모든 충돌을 덮어쓰기 |
| `q` | 중단 (이미 복사된 파일은 유지) |

## 변수 치환

- 대상: `.md` 파일만
- 변수: `{{PROJECT_NAME}}` → 프로젝트 디렉토리명
  - `new`: 인자로 받은 `<project-name>`
  - `merge`/`update`: `basename $(pwd)`

## 설정

스크립트 상단 상수:

```bash
TEMPLATE_REPO="https://github.com/<user>/claude-code-ai-native.git"
```

환경변수로 오버라이드 가능:

```bash
CLAUDE_TEMPLATE_REPO="https://github.com/my-org/my-template.git" claude-init new my-project
```

## 배포

### 스크립트 위치

레포 루트 `scripts/claude-init.sh`

### 설치

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/claude-code-ai-native/main/scripts/claude-init.sh \
  -o /usr/local/bin/claude-init && chmod +x /usr/local/bin/claude-init
```

## 의존성

macOS/Linux 기본 도구만 사용:

- `git` — clone
- `sed` — 변수 치환
- `diff` — 충돌 비교
- `mktemp` — 임시 디렉토리

## 에러 처리

| 상황 | 동작 |
|------|------|
| `new` 대상 디렉토리 이미 존재 | 에러 메시지 출력, exit 1 |
| `merge`/`update`에서 `.git` 없음 | 에러 메시지 출력, exit 1 |
| `git clone` 실패 | 에러 메시지 출력, 임시 디렉토리 정리, exit 1 |
| 사용자가 `q` 입력 | 중단 메시지 출력, 임시 디렉토리 정리, exit 0 |
