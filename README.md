# Rein — AI Native Development Framework

> Rein in your AI — 규칙·게이트·훅으로 AI 에이전트의 고삐를 쥐는 프레임워크

[English](README.en.md) | **한국어**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 왜 Rein 인가?

AI 코딩 어시스턴트(Claude Code, Cursor, Copilot 등)는 강력하지만 **일관성이 없습니다**. 같은 질문에 다른 답을 하고, 프로젝트 규칙을 잊고, 리뷰 없이 코드를 수정합니다.

Rein 은 이 문제를 **규칙 파일 + 자동 게이트 + 훅**으로 해결합니다:

| 구분 | AI Assisted (기존) | AI Native (Rein) |
|------|-------------------|-----------------|
| 지시 방식 | "이 함수 이렇게 만들어줘" | "이 워크플로우를 실행해줘" |
| 품질 기준 | 사람 머릿속 | 문서 파일 (AGENTS.md, rules/) |
| 실패 대응 | 출력물 다시 요청 | 원인 분석 후 **규칙 문서 수정** |
| 확장성 | 매번 사람이 개입 | 규칙이 쌓일수록 품질 자동 상승 |

## 핵심 기능

### 1. Definition of Done (DoD) 게이트

모든 소스 코드 편집 전에 **완료 기준 파일**을 먼저 작성하도록 강제합니다. DoD 없이 코드를 수정하면 훅이 차단합니다.

```
trail/dod/dod-2026-04-16-auth-refactor.md  ← 먼저 작성
src/auth.ts                                 ← 그 다음 편집 가능
```

### 2. 코드 리뷰 강제

구현이 끝나면 반드시 코드 리뷰를 거쳐야 테스트와 커밋이 가능합니다. 리뷰 없이 `git commit`이나 `pytest`를 실행하면 차단됩니다.

### 3. 증거 저장소 (trail/)

세션 기록이 자동으로 쌓이고 회전됩니다:

```
trail/
├── inbox/          ← 오늘 완료한 작업 기록
├── daily/          ← 7일 지나면 자동 병합
├── weekly/         ← 4주 지나면 자동 병합
├── dod/            ← Definition of Done 파일
├── incidents/      ← 훅 차단 로그 + 자동 집계
└── index.md        ← 현재 프로젝트 상태 (5~15줄)
```

### 4. 스마트 라우터

작업 유형에 따라 최적의 에이전트·스킬·MCP 조합을 자동 추천합니다.

### 5. 자기 진화 시스템

같은 문제가 2번 반복되면 **규칙으로 자동 승격**됩니다:
- 2회 반복 → `incidents-to-rule` 스킬이 AGENTS.md 규칙 후보 생성
- 3회 반복 → `incidents-to-agent` 스킬이 에이전트 후보 생성

### 6. CLI 자가 업데이트

`rein update` 실행 시 템플릿 파일뿐만 아니라 **CLI 자체도 최신 버전으로 자동 갱신**됩니다. sudo 불필요.

---

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
```

`$HOME/.rein/bin/rein` 에 설치됩니다. **sudo 불필요**. 설치 후:

```bash
source ~/.rein/env
rein --version
```

## CLI 명령어

| 명령어 | 설명 |
|--------|------|
| `rein new <project>` | 템플릿에서 새 프로젝트 생성. `.claude/`, `trail/`, `AGENTS.md` 자동 복사 + `{{PROJECT_NAME}}` 치환 |
| `rein merge` | 기존 프로젝트에 템플릿 병합. 충돌 시 `[overwrite / skip / diff]` 프롬프트 |
| `rein update` | 템플릿 최신 버전으로 갱신. 동일 파일 스킵, CLI 자가 업데이트 포함 |
| `rein update --yes` | 모든 프롬프트 자동 승인 (CI 용) |
| `rein update --prune` | 템플릿에서 제거된 파일 감지 (dry-run) |
| `rein update --prune --confirm` | 제거된 파일 실제 삭제 (백업 생성 후) |
| `rein --version` | 버전 출력 |
| `rein --help` | 도움말 |

### 환경변수

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `REIN_TEMPLATE_REPO` | 템플릿 Git 레포 URL | `git@github.com:JayJihyunKim/rein.git` |
| `REIN_BUDGET_BYTES` | 세션 시작 시 trail 로딩 용량 예산 | `65536` |

## 프로젝트 구조

```
repo/
├── AGENTS.md                    ← 전역 실행 규칙
├── .claude/
│   ├── CLAUDE.md                ← 진입점 + @import 허브
│   ├── settings.json            ← Hook + 권한 설정
│   ├── orchestrator.md          ← 스마트 라우터 기준
│   ├── rules/                   ← 코드 스타일, 테스트, 보안 규칙
│   ├── hooks/                   ← 라이프사이클 자동화 스크립트
│   ├── agents/                  ← 역할별 에이전트 정의
│   ├── skills/                  ← 호출형 스킬
│   └── workflows/               ← 작업 유형별 절차
├── trail/                       ← 증거 저장소
├── REIN_SETUP_GUIDE.md          ← 상세 적용 가이드
└── install.sh                   ← CLI 설치 스크립트
```

## 빠른 시작

```bash
# 1. 프로젝트 생성
rein new my-project && cd my-project && git init

# 2. trail/index.md 에 프로젝트 현재 상태 기입
# 3. AGENTS.md 를 프로젝트에 맞게 수정

# 4. Claude Code 실행 — rein 이 자동으로 작업 플로우를 가이드합니다
claude
```

> 상세한 커스터마이징은 [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) 를 참고하세요.

## 포함된 스킬

| 스킬 | 역할 |
|------|------|
| `repo-audit` | 저장소 상태 점검 (오래된 규칙, 누락 테스트 감지) |
| `incidents-to-rule` | 반복 실패 → AGENTS.md 규칙 후보 자동 생성 |
| `incidents-to-agent` | 반복 패턴 → 에이전트 후보 생성 |
| `promote-agent` | 에이전트 후보를 정식 에이전트로 승격 |
| `changelog-writer` | Git 히스토리 기반 CHANGELOG 자동 작성 |
| `pr-review-fixer` | PR 리뷰 코멘트 자동 수정 적용 |

**Stitch UI 디자인 스킬** (Stitch MCP 연결 시):

| 스킬 | 역할 |
|------|------|
| `stitch-design` | 디자인 시스템 총괄 + 프롬프트 강화 |
| `stitch-loop` | 멀티페이지 자동 생성 |
| `enhance-prompt` | 모호한 UI 요청 → 정교한 프롬프트 변환 |
| `react-components` | 디자인 → React 컴포넌트 변환 |

> Stitch 스킬은 호출 시에만 로드되므로 미사용 시 컨텍스트를 차지하지 않습니다.

## 호환성 주의

### `everything-claude-code` 플러그인

`everything-claude-code` (>= 1.9.0) 의 `gateguard-fact-force` 훅은 Rein 과 호환되지 않습니다. 함께 설치하면 모든 Edit/Write/Bash 가 deadlock 됩니다. Rein 이 동등한 기능을 이미 제공하므로 해당 플러그인은 제거하세요.

### v0.6.x 이하에서 업그레이드

v0.7.0 부터 CLI 설치 경로가 `/usr/local/bin/rein` → `$HOME/.rein/bin/rein` 으로 변경되었습니다. 기존 사용자는 [install.sh](install.sh) 를 한 번 실행하면 됩니다. 이후 `rein update` 가 자가 업데이트를 자동 처리합니다.

## 버전 히스토리

### v0.7.3 (2026-04-19)
- **Critical 보안 수정**: hook (`pre-edit-dod-gate.sh`, `pre-bash-guard.sh`) 이 python3 부재/파싱 실패 시 `exit 0` 으로 gate 전체가 우회됐던 fail-open 결함. python3 검사 + RC 체크로 fail-closed 로 전환
- aggregate `LIVE_COUNT` RC 분리 캡처 (실패 시 차단)
- `rein-aggregate-incidents.py` lock 파일 unlink 제거 (동시 집계 race 방지) + threshold 로직 분리 (open_inc 는 무조건 누적 갱신, 신규 생성만 threshold 적용)
- SessionStart 세션 스코프 stamp 초기화를 조건문 밖으로 (누수 방지)
- Stop hook aggregate 출력 stderr 로 분리, PENDING=0 시 counter 정리
- `rein-mark-agent-candidate.py --hash` 형식 검증 (path traversal 방지)
- helper exception 범위 확장 (OSError/UnicodeDecodeError 포괄)

### v0.7.2 (2026-04-19)
- incidents 반자동화 **Stop hook 게이트** 도입 — 작업 종료 시 pending incident 감지하면 자동으로 `/incidents-to-rule` + `/incidents-to-agent` 스킬 체인 호출을 Claude 에게 지시
- 진전 감지 + 3회 block 가드 + 메타 incident (무한 루프 방지)
- 세션 경계 상태 스냅샷 (`.last-aggregate-state.json`) + 비정상 종료 감지
- helper 스크립트 신규: `rein-stop-emit-block.py`, `rein-mark-incident-processed.py`, `rein-mark-agent-candidate.py`
- `incidents-to-agent` 스킬 재작성 (decision skip + batch AskUserQuestion UX)
- pre-edit-dod-gate: incident gate 를 cache 앞으로 이동 (cache hit 우회 버그 수정)
- log_block 경고를 hook+reason 조합별 카운트로 (오인 표시 수정)

### v0.7.1 (2026-04-17)
- public release 준비 (README 영문 버전, MIT LICENSE)
- `rein` public mirror workflow (dev-remote `main` → public `rein` repo)

### v0.7.0 (2026-04-16)
- CLI 설치 경로 `$HOME/.rein/bin/rein` 전환 (sudo 제거)
- `install.sh` 신규 설치 스크립트 + CLI 자가 업데이트
- `SOT/` → `trail/` 리네임

### v0.6.0 (2026-04-15)
- 세션 시작 시 trail 자동 로딩 (SessionStart 훅)
- 설계 문서 리뷰 강제 게이트
- incidents 자동 집계 (JSONL + Python)
- skill/MCP 인벤토리 자동 스캔

### v0.5.0 (2026-04-15)
- manifest 기반 파일 추적 + `--prune` 지원
- symlink / path traversal 보안 강화

### v0.4.x (2026-04-15)
- codex 리뷰 강제 + 에스컬레이션 규칙
- stop-session-gate 데드락 해소
- Linux/macOS stat 호환성 수정
- 커밋 메시지 검증 개선

### v0.3.0
- 스마트 라우터 도입

### v0.2.0 (2026-04-09)
- 보안 레이어 도입 (프로젝트별 보안 레벨)

### v0.1.0
- 최초 릴리즈: CLI, DoD gate, stop-session gate, inbox 회전

## Contributing

이슈나 PR 은 환영합니다. [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) 에서 프레임워크 구조를 먼저 파악한 후 기여해 주세요.

## License

MIT License. See [LICENSE](LICENSE) for details.

## 참고

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [getsentry/sentry](https://github.com/getsentry/sentry) — 실사용 AGENTS.md 예시
- [anthropics/skills](https://github.com/anthropics/skills) — skill 정의
