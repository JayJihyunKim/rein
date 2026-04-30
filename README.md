# Rein — AI Native Development Framework

> AI 에이전트에게 코드를 맡기되, "프롬프트 규율" 에만 의존하지 않기 위한 저장소 스캐폴드

[English](README.en.md) | **한국어**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Rein 이 하는 일

Rein 은 AI 코딩 에이전트(현재 Claude Code 기준)가 **작업을 먼저 정의하고, 증거를 남기고, 리뷰를 통과한 뒤에야 코드를 반영하도록** 저장소에 소규모 규칙과 자동 가드레일을 추가합니다.

**Rein 을 쓰면 좋은 경우**:

- 장기 유지보수하는 코드베이스
- AI 출력의 **일관성** 이 raw 속도보다 중요한 팀
- 코드 리뷰·증거·체크포인트를 팀 규율로 **코드화** 하고 싶은 경우

**Rein 을 쓰지 말아야 하는 경우**:

- 일회성 스크립트, throwaway 프로젝트
- 리포지토리에 process 파일이 추가되는 것을 원하지 않는 팀
- POSIX bash / WSL2 외 환경 (네이티브 Windows PowerShell 미지원)

> **툴 지원 현황**: Rein 의 자동 가드레일은 Claude Code 의 hook 라이프사이클을 기반으로 합니다. 동일한 개념(AGENTS.md, 규칙 파일, 리뷰 게이트) 은 Cursor / Copilot 에서 **참고 문서로만** 작동하며, 자동 차단은 일어나지 않습니다.

---

## 실제로 어떻게 달라지나

**Rein 없이 — 흔한 문제**

```
개발자: "로그인 기능 구현해줘"
   ↓
AI: 코드 작성 → git commit
   ↓
리뷰 없음. 완료 기준 없음.
다음 세션엔 무엇을 왜 했는지 흔적이 없다.
```

**Rein 적용 — 같은 요청의 흐름**

```
개발자: "로그인 기능 구현해줘"
   ↓
Rein: "먼저 trail/dod/dod-2026-04-22-login.md 에 완료 기준을 작성하세요"
   → AI 가 체크리스트 작성 (DoD 파일)
   ↓
AI 가 코드 편집 (DoD 가 존재하므로 허용됨)
   ↓
AI 가 git commit 시도
   → Rein: "코드 리뷰 stamp 가 없습니다. 차단."
   → AI 가 리뷰 수행 → stamp 생성 → commit 허용
   ↓
세션 종료 시 결정·변경 내역이 trail/inbox/ 에 자동 기록.
다음 세션 시작 시 이 기록이 자동으로 컨텍스트에 로드됨.
```

---

## 4가지 핵심 보장

### 1. 작업을 먼저 정의해야 코드가 편집된다

모든 소스 코드 편집 전에 **완료 기준 파일 (Definition of Done)** 을 먼저 작성하도록 강제합니다. DoD 없이 코드를 수정하면 훅이 차단합니다.

```
trail/dod/dod-2026-04-22-auth-refactor.md   ← 먼저 작성
src/auth.ts                                  ← 그 다음 편집 가능
```

### 2. 리뷰 통과 전엔 commit·테스트가 차단된다

구현 후 `git commit` 이나 `pytest` 실행이 차단됩니다. 코드 리뷰가 완료되어 "리뷰 증명" 파일이 생성된 뒤에만 허용됩니다.

### 3. 증거가 자동으로 쌓이고 회전된다

세션 기록이 `trail/` 디렉토리에 누적되고, 오래된 건 주간·월간 요약으로 자동 병합됩니다. 다음 세션 시작 시 최신 기록이 AI 의 컨텍스트에 자동 로드됩니다.

```
trail/
├── inbox/      ← 오늘 완료한 작업 기록
├── daily/      ← 7일 지나면 자동 병합
├── weekly/     ← 4주 지나면 자동 병합
├── dod/        ← 완료 기준 파일
└── index.md    ← 현재 프로젝트 상태 (5~15줄)
```

### 4. 업데이트는 Claude Code plugin manager 가 처리한다

플러그인 갱신은 `claude plugin update rein-core` 로 수행합니다. 사용자 repo 의 hooks/skills/agents 는 plugin manifest 가 소유하므로 업데이트가 사용자 수정 파일을 건드리지 않습니다.

---

## 설치

```bash
curl -fsSL https://raw.githubusercontent.com/JayJihyunKim/rein/main/install.sh | bash
```

`$HOME/.rein/bin/rein` 에 설치됩니다. **sudo 불필요**.

```bash
source ~/.rein/env
rein --version
```

---

## 빠른 시작

```bash
# 1. 기존 git repo 에 진입 (rein init 은 .git 이 있어야 동작)
cd existing-project

# 2. rein init — plugin 모드로 설치 (유일한 install 경로)
rein init

# 3. trail/index.md 에 프로젝트 현재 상태 기입 (5~15줄)

# 4. AGENTS.md 를 프로젝트에 맞게 수정

# 5. Claude Code 실행 — Rein 이 자동으로 작업 플로우를 가이드합니다
claude
```

`rein init` 은 Claude Code plugin 모드로 동작합니다. Claude Code marketplace 에 등록된 `rein-core` plugin 이 hooks/skills/agents 를 자동으로 fetch 하고, 사용자 repo 에는 `.rein/project.json` + `.claude/settings.json` 의 plugin pin 만 남습니다. 자세한 흐름은 [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) 를 참조하세요.

---

## 레포에 추가되는 것

```
repo/
├── AGENTS.md              ← 전역 실행 규칙
├── .claude/
│   ├── CLAUDE.md          ← Claude Code 진입점
│   ├── settings.json      ← hook 설정
│   ├── rules/             ← 코드 스타일·테스트·보안 규칙
│   ├── hooks/             ← 자동 가드레일 스크립트
│   ├── agents/            ← 역할별 에이전트 정의
│   └── skills/            ← 호출형 스킬
├── trail/                 ← 증거 저장소 (자동 회전)
└── REIN_SETUP_GUIDE.md    ← 상세 가이드
```

---

## CLI 명령

| 명령어 | 설명 |
|--------|------|
| `rein init` | 현재 git repo 에 rein-core plugin 설치 (plugin-only) |
| `rein update` | plugin 갱신 안내 출력 (실제 갱신은 `claude plugin update rein-core`) |
| `rein job <subcmd>` | 백그라운드 작업 (start/status/stop/tail/list/gc) |
| `rein --version` | 버전 출력 |
| `rein --help` | 도움말 |

자세한 환경변수·플래그는 [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) 참조.

### Slash command 호출

플러그인 모드에서 Rein 의 스킬은 `/rein:` 네임스페이스 아래로 노출됩니다. 예시: `/rein:codex-review`, `/rein:codex-ask`.

#### Custom alias 권장
설정 파일 `.claude/settings.json` 에 다음 추가 시 짧은 호출 가능:
```json
{
  "aliases": {
    "/cr": "/rein:codex-review",
    "/ca": "/rein:codex-ask"
  }
}
```

---

## 플랫폼 지원

| 플랫폼 | 상태 |
|---|---|
| macOS | ✅ 공식 지원 |
| Linux | ✅ 공식 지원 |
| Windows (WSL2) | ✅ 공식 지원 |
| Windows (Git Bash / MSYS2) | ⚠️ best-effort, 정식 테스트 대상 아님 |
| Windows (PowerShell / CMD native) | ❌ 미지원 |

Windows 사용자는 **WSL2 (Ubuntu)** 를 권장합니다. 설치 방법과 Git Bash 문제 진단은 [docs/troubleshooting/windows.md](docs/troubleshooting/windows.md) 참조.

---

## 고급 기능 (선택)

사용자 프로젝트 규모가 커지면 아래 고급 기능을 점진적으로 활성화할 수 있습니다. 기본 흐름에는 불필요합니다.

- **호출형 스킬**: 저장소 감사, 반복 실패 규칙 자동 승격, CHANGELOG 자동 생성 등. 상세: [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md)
- **Design → Plan 범위 추적**: 설계 문서의 scope item 이 구현 plan 으로 누락 없이 전환되는지 자동 검증. 상세: [.claude/rules/design-plan-coverage.md](.claude/rules/design-plan-coverage.md)
- **반복 실패 → 규칙 승격**: 같은 차단이 2-3회 반복되면 AGENTS.md 규칙 또는 에이전트 후보를 자동 생성
- **스마트 라우터**: 작업 유형에 따라 에이전트·스킬·MCP 조합을 자동 추천

## 호환성 주의

### `everything-claude-code` 플러그인

`everything-claude-code` (>= 1.9.0) 의 `gateguard-fact-force` 훅은 Rein 과 호환되지 않습니다. 함께 설치하면 모든 Edit/Write/Bash 가 deadlock 됩니다. Rein 이 동등한 기능을 이미 제공하므로 해당 플러그인은 제거하세요.

### v0.6.x 이하에서 업그레이드

v0.7.0 부터 CLI 설치 경로가 `/usr/local/bin/rein` → `$HOME/.rein/bin/rein` 로 변경되었습니다. 기존 사용자는 [install.sh](install.sh) 를 한 번 실행하면 됩니다.

---

## Release history

정식 launch 는 v1.0.0 부터입니다. 이전 dev cycle history 는 [archive](docs/changelog-archive/2026-04-pre-v1.md) 를 참조하세요.

---

## Contributing

이슈나 PR 은 환영합니다. [REIN_SETUP_GUIDE.md](REIN_SETUP_GUIDE.md) 에서 프레임워크 구조를 먼저 파악한 후 기여해 주세요.

## License

MIT License. See [LICENSE](LICENSE) for details.

## 참고

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [anthropics/skills](https://github.com/anthropics/skills) — Skill 정의
