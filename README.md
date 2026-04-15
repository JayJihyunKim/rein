# Rein — AI Native Development Framework

> Rein in your AI — 규칙·게이트·훅으로 AI의 고삐를 쥐는 프레임워크

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
│   ├── security/                ← 보안 프로필 및 성숙도 설정
│   ├── router/                  ← 스마트 라우터 설정
│   └── hooks/                   ← 라이프사이클 자동화 스크립트
├── SOT/                         ← 증거 저장소 (상태/결정/사고 기록)
├── docs/SETUP_GUIDE.md          ← 프레임워크 적용 가이드
└── .github/workflows/           ← GitHub Actions 자동화
```

## 새 프로젝트에 적용하기

### 설치

```bash
gh api repos/JayJihyunKim/rein/contents/scripts/rein.sh --jq '.content' | base64 -d | sudo tee /usr/local/bin/rein > /dev/null && sudo chmod +x /usr/local/bin/rein
```

> `gh` CLI가 필요합니다. (`brew install gh && gh auth login`)

### 새 프로젝트 생성

```bash
rein new my-project
cd my-project && git init
```

템플릿의 `.claude/`, `SOT/`, `AGENTS.md`가 자동으로 복사되고 `{{PROJECT_NAME}}`이 프로젝트명으로 치환됩니다.

### 기존 프로젝트에 병합

```bash
cd existing-project
rein merge
```

이미 존재하는 파일은 `[overwrite / skip / diff]` 프롬프트로 하나씩 확인합니다.

### 템플릿 업데이트

```bash
cd existing-project
rein update
```

템플릿 레포의 최신 버전과 비교하여 변경된 파일만 업데이트합니다. 동일한 파일은 건너뛰고, 다른 파일만 프롬프트로 확인합니다.

### 환경변수

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `REIN_TEMPLATE_REPO` | 템플릿 Git 레포 URL | `git@github.com:JayJihyunKim/rein.git` |
| `CLAUDE_TEMPLATE_REPO` | (deprecated) `REIN_TEMPLATE_REPO`의 별칭 | — |

Fork하거나 별도 템플릿 레포를 사용하려면:
```bash
REIN_TEMPLATE_REPO="git@github.com:my-org/my-template.git" rein new my-project
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

## 버전 히스토리

### v0.4.1 (2026-04-15) — hotfix
- **fix**: `stat -f` / `stat -c` 폴백 체인이 Linux GNU stat 에서 동작하지 않아 `pre-edit-dod-gate.sh`, `pre-bash-guard.sh`, `inbox-compress.sh` 훅이 Linux 사용자 전원에게 블록되던 문제 수정. `uname` 기반 `_mtime()` 헬퍼로 교체 (macOS=BSD, Linux/WSL/Git Bash/Cygwin=GNU)
- **feat**: 신규 `post-edit-index-sync-inbox.sh` 훅 — `SOT/index.md` 편집 시 훅 프로세스가 직접 오늘자 inbox 를 생성. 3rd party 플러그인(`gateguard-fact-force` 등)이 Claude Write 도구의 새 파일 생성을 차단할 때 발생하는 `stop-session-gate` 데드락 자동 해소
- **test**: `tests/hooks/` 32/32 통과 (신규 13개 — portability 6 + sync-inbox 7)

### v0.4.0 (2026-04-15) — codex 리뷰 강제 + 에스컬레이션
- **feat**: 신규 `post-edit-review-gate.sh` 훅 — Edit/Write 시 `.review-pending` 자동 추적
- **feat**: `pre-bash-guard` 강화 — `.review-pending` 검증, `.env` 읽기 차단, `git checkout`/`git restore` 차단
- **feat**: `codex` 스킬 폴백 체인 + 에스컬레이션 규칙 + stamp 메타데이터
- **feat**: AGENTS.md §5-1 코드 리뷰 필수 규칙 + 에스컬레이션 기준
- **fix**: 전체 코드 리뷰 지적사항 반영 (보안, DoD gate, 확장자, 경로 검증)

### v0.3.0 — 스마트 라우터 + 템플릿 정리
- **feat**: 스마트 라우터 도입 (`.claude/router/`) — DoD 내용과 에이전트/스킬/MCP description 매칭으로 최적 조합 자동 추천
- **feat**: 서브프로젝트 AGENTS.md 계층 구조 가이드 (`docs/SETUP_GUIDE.md` 통합)
- **chore**: `COPY_TARGETS` 누락 파일 보강 (router, 서브프로젝트, SETUP_GUIDE)
- **fix**: ISO week-year `%G` + 프로젝트명 슬래시 차단 (2차 Codex 리뷰 반영)
- **fix**: inbox weekly 주차 계산 + `rein new` 경로 검증 + stitch-design 오타 수정

### v0.2.0 (2026-04-09) — Security Layer
- **feat**: 보안 레이어 도입 (`.claude/security/profile.yaml`) — 프로젝트별 보안 레벨 설정
- **feat**: `security-reviewer` 에이전트 — Codex 리뷰 완료 후 자동 보안 리뷰
- **feat**: 보안 레벨 기반 자동 리뷰 스탬프 시스템
- **chore**: CLI 이름 변경 (`claude-init` → `rein`)

### v0.1.0 — 최초 릴리즈
- **feat**: `rein` CLI 기본 기능 (`new` / `merge` / `update`)
- **feat**: AGENTS.md + `.claude/` 규칙·훅 스캐폴드
- **feat**: DoD gate (`pre-edit-dod-gate.sh`) — 소스 편집 전 DoD 파일 필수
- **feat**: Stop session gate — 세션 종료 전 inbox + index 갱신 필수
- **feat**: Codex 코드 리뷰 필수 단계
- **feat**: inbox → daily → weekly 자동 회전 훅
- **feat**: Stitch MCP UI 디자인 스킬팩 8종

---

> 상세 변경 이력은 `git log main --oneline` 을 참조하세요.

## 참고 저장소

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [getsentry/sentry](https://github.com/getsentry/sentry) — 실사용 AGENTS.md 예시
- [anthropics/skills](https://github.com/anthropics/skills) — skill 정의 방식
- [google-labs-code/stitch-skills](https://github.com/google-labs-code/stitch-skills) — Stitch UI 디자인 스킬
