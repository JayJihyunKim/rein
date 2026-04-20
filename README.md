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

### 7. Design → Plan 범위 커버리지 추적

설계 문서의 scope item 이 구현 plan 으로 전환될 때 조용히 누락되는 것을 **기계 가독 꼬리표**로 방지합니다:

```markdown
## Design 범위 커버리지 매트릭스       ← plan 에 필수 섹션
> design ref: docs/specs/foo-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| A1 | implemented | Phase 2 |
| A2 | deferred | Stage 2.5 연기 — 사유 |

## Phase 2: 데이터 정합성              ← work unit 이름 자유
covers: [A1]                          ← 기계 가독 꼬리표
```

plan 파일을 편집하면 validator (`scripts/rein-validate-coverage-matrix.py`) 가 자동 실행됩니다:
- design scope ID 누락/중복/unknown 감지 시 `trail/dod/.coverage-mismatch` 마커 생성
- pre-bash-guard 가 마커 존재 시 `git commit` / `pytest` 차단 (exit 2)
- Gate/Phase/Sprint 이름은 자유 (추적성은 `covers:` 꼬리표가 담당)
- legacy plan (matrix 섹션 없음) 은 경고만, 차단하지 않음 — gradual adoption

---

## 지원 플랫폼

| 플랫폼 | 상태 | 비고 |
|--------|------|------|
| macOS | ✅ 공식 지원 | |
| Linux | ✅ 공식 지원 | |
| Windows (WSL2) | ✅ 공식 지원 | 아래 "Windows 사용자" 안내 참조 |
| Windows (Git Bash / MSYS2) | ⚠️ best-effort | 정식 테스트 대상 아님 |
| Windows (PowerShell / CMD native) | ❌ 미지원 | 훅이 POSIX bash + GNU coreutils 를 전제로 함 |

### Windows 사용자

Rein 의 훅은 bash + GNU coreutils 를 전제로 동작하며, 일부 Python 스크립트는 `fcntl` 같은 POSIX API 에 의존합니다. Windows 에서는 **WSL2 (Ubuntu) 환경을 권장**합니다.

**WSL2 설치** (PowerShell 을 **관리자 권한**으로 열고 실행):

```powershell
wsl --install
```

- Windows 10 2004 (빌드 19041) 이상 또는 Windows 11 에서 한 줄로 완료됩니다
- 기본 배포판 Ubuntu 가 자동 설치되고 사용자 계정을 만들라는 프롬프트가 뜹니다
- 재부팅 후 `wsl` 을 다시 실행하면 Ubuntu 셸로 진입합니다

그 다음 WSL Ubuntu 셸 안에서 일반 Linux 와 동일하게 설치합니다:

```bash
# 필수 도구 (대부분 Ubuntu 기본 포함)
sudo apt update && sudo apt install -y git curl python3

# Rein 설치
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
source ~/.rein/env
rein --version
```

프로젝트 체크아웃 경로는 `/mnt/c/...` (Windows 파일시스템) 보다 `~/` (WSL 파일시스템) 가 디스크 I/O 가 훨씬 빠릅니다.

자세한 안내: Microsoft 공식 문서 [aka.ms/wsl-install](https://aka.ms/wsl-install).

### Windows Git Bash 진단 (v0.10.1+)

Windows Git Bash / MSYS2 환경에서 훅이 `BLOCKED: ... Python launch 실패 (9009 계열)` 메시지로 차단되면 아래 3종 명령으로 진단합니다:

```bash
command -v python3      # python3 가 PATH 에 잡히는가
python3 -V              # 실제 실행 성공하는가
py -3 -V                # py launcher 가 real Python 을 가리키는가
```

**해석**:
- `command -v` 성공 + `python3 -V` 실패 + `py -3 -V` 성공 → **WindowsApps App Execution Alias stub 문제** (가장 흔한 케이스)
- 세 명령 모두 실패 → real Python 미설치
- `command -v` 실패 → PATH 설정 문제

참고: 훅이 보고하는 `python3 exit 49` 는 Python 의 JSON 파싱 실패가 아니라 Windows 의 `9009` (command not found / App Execution Alias stub 실행 실패) 가 Git Bash/MSYS 에서 8비트로 잘린 값입니다 (`9009 mod 256 = 49`).

**해결책** (우선순위 순):

1. **WSL2 로 전환** — rein 의 공식 Windows 지원 경로 (위 "Windows 사용자" 섹션 참조)
2. Windows Settings → "앱 실행 별칭 관리(Manage app execution aliases)" 에서 `python.exe` / `python3.exe` 스위치를 **off** 로 바꾸고, [python.org](https://www.python.org/downloads/) 또는 Python install manager 로 실제 Python 을 설치
3. PATH 에서 real Python 또는 `py` launcher 가 `WindowsApps` 디렉토리보다 **앞에** 오도록 순서 조정
4. venv 사용자는 `export REIN_PYTHON=/path/to/python3` 로 명시 지정 (resolver 우선순위에서 1순위로 사용됨)

**alias 한계 경고**: 비대화형 hook 은 `alias python3=...` 같은 shell alias 를 상속받지 못합니다. 훅은 bash script 로 fork 되어 interactive rc 파일을 source 하지 않기 때문입니다. **실제 실행파일 wrapper 또는 PATH 조정**이 필요합니다.

**Unsupported local fork**: local hook 수정 (예: fail-closed 를 `exit 0` 으로 바꿔 gate 를 우회) 은 언제든 기술적으로 가능하지만, 그 시점에 rein 의 gate 보장은 무효가 됩니다. 이 경로를 의도적으로 쓰는 경우 rein 트래킹 대상이 아닙니다.

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

### 작업 유형별 추천 조합 (예시)

| 작업 | 추천 에이전트 | 주요 스킬 |
|---|---|---|
| 기능 추가 | feature-builder | `brainstorming` (brownfield) → writing-plans → `/codex review` |
| 버그 수정 | feature-builder | systematic-debugging, `/codex review` |
| 설계 | docs-writer / plan-writer | `brainstorming` → writing-plans |
| 리팩토링 | feature-builder | `brainstorming`, `/codex review`, repo-audit |
| 독립 관점 질의 | — | `/codex ask` (stamp 없음, 세션 컨텍스트 오염 회피) |

> `brainstorming` / `writing-plans` 는 rein-native 스킬입니다. superpowers 플러그인의 동명 스킬보다 우선 매칭됩니다.

> 사용자가 별도 스킬·플러그인을 설치하면 라우터가 세션마다 동적으로 스캔하여 자동 추천 후보에 포함한다.

## 호환성 주의

### `everything-claude-code` 플러그인

`everything-claude-code` (>= 1.9.0) 의 `gateguard-fact-force` 훅은 Rein 과 호환되지 않습니다. 함께 설치하면 모든 Edit/Write/Bash 가 deadlock 됩니다. Rein 이 동등한 기능을 이미 제공하므로 해당 플러그인은 제거하세요.

### v0.6.x 이하에서 업그레이드

v0.7.0 부터 CLI 설치 경로가 `/usr/local/bin/rein` → `$HOME/.rein/bin/rein` 으로 변경되었습니다. 기존 사용자는 [install.sh](install.sh) 를 한 번 실행하면 됩니다. 이후 `rein update` 가 자가 업데이트를 자동 처리합니다.

## 버전 히스토리

### v0.10.1 (2026-04-20) — Windows Git Bash/MSYS `python3 exit 49` 구조적 해결
- `.claude/hooks/lib/python-runner.sh` (공용 Python resolver, bash array 기반) + `.claude/hooks/lib/extract-hook-json.py` (argparse 기반 JSON stdin 추출 helper) 도입
- 8개 훅의 inline `echo "$INPUT" | python3 -c ...` 패턴을 helper 경유 호출로 전부 교체. Windows launch failure(9009 계열) / WindowsApps stub / JSON 파싱 실패를 구분 진단
- pre-hook 차단 시 `[DoD gate]` / `[Bash guard]` prefix 포함 Windows-specific 진단 메시지 (WSL2 / App execution aliases / `REIN_PYTHON` / venv 안내) 출력
- 상세: [CHANGELOG](CHANGELOG.md) · README "Windows Git Bash 진단" 섹션

### v0.10.0 (2026-04-20) — rein-native brainstorming + /codex ask + tests CI + incident classifier
- rein-native `brainstorming` skill 신설 — brownfield 에서 feasibility·compatibility 를 선검증한 뒤 선택지를 수렴 (산출물 `docs/superpowers/brainstorms/`)
- `/codex` 를 `/codex review` (Mode A, 리뷰 stamp) + `/codex ask` (Mode B, second opinion, stamp 없음, `resume --last` 금지) 로 분리
- `.github/workflows/tests.yml` 신설 — ubuntu/macOS 에서 전체 hook + script 테스트를 push/PR 마다 자동 실행. rein-dev 전용
- incident `agent_eligible` 분류 필드 도입 — `/incidents-to-agent` 가 hook-source bug 패턴 (`false`) 을 자동 제외
- router 가 `superpowers:brainstorming`/`superpowers:writing-plans` 를 id prefix 로 차단하여 rein-native 스킬이 우선 매칭됨
- 상세: [CHANGELOG](CHANGELOG.md)

### v0.9.1 (2026-04-20) — hotfix: `rein merge` hook exec bit propagation
- `scripts/rein.sh:copy_file()` 가 기존 dst 파일의 mode 를 갱신하지 못해 과거 버전에 설치된 프로젝트의 훅이 `-rw-rw-r--` 로 남던 문제 수정. src 가 실행 가능하고 dst 에 exec bit 이 없을 때만 `chmod +x` 승격 (기존 755 비삭제). 상세: [CHANGELOG](CHANGELOG.md)

### v0.9.0 (2026-04-20) — cross-platform portability + Windows WSL2 guidance
- Linux 에서 `session-start-load-trail.sh` 의 `file_size()` 가 깨지는 버그 수정 (GNU `stat -f` 가 exit 0 인 filesystem-info 모드로 해석되어 `||` fallback 이 안 타던 문제)
- 훅 전반의 BSD/GNU 분기 헬퍼를 `.claude/hooks/lib/portable.sh` 로 공통화 (`_mtime`/`_mtime_date`/`file_size` 중복 제거)
- `.gitattributes` 추가 — Windows checkout 시 CRLF 변환 방지로 shebang 훅 보호
- 지원 플랫폼 명시: macOS / Linux / Windows via WSL2. README 에 WSL2 설치 안내 추가

### v0.8.0 (2026-04-20) — core harness purity (breaking)
- 도메인·언어 무관 메타-하네스로 정리 — Stitch/shadcn 번들 분리, 에이전트 5개 재편(`plan-writer` 추가), 훅 리팩토링, rein-native `writing-plans`/`code-reviewer` 스킬, 라우터 id 검증 + `doctor`. 상세 + 마이그레이션: `CHANGELOG.md` · `REIN_SETUP_GUIDE.md`

### v0.7.5 (2026-04-19)
- 스마트 라우터 강제화 — 새 DoD 에 `## 라우팅 추천` 섹션 + 사용자 승인 필수 (훅이 누락/미승인 편집 차단)
- skill/MCP 가이드 자동 생성 스크립트 추가

### v0.7.4 (2026-04-19)
- 설계 → 플랜 범위 커버리지 추적 — design 의 scope item 이 plan 전환 시 누락되면 편집 단계에서 자동 감지

### v0.7.3 (2026-04-19)
- 훅 안전성 개선 (critical 보안 수정) — python3 부재/파싱 실패 시 gate 가 무력화되던 fail-open 을 fail-closed 로 전환

### v0.7.2 (2026-04-19)
- incidents 반자동화 — 반복 실패 패턴을 세션 종료 시점에 자동 감지해 규칙/에이전트 승격 플로우로 연결

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
