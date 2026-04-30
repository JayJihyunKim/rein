<div align="right">
  <strong>한국어</strong> · <a href="README.md">English</a>
</div>

<div align="center">

  <img src="main_img.png" alt="Rein — Guide Autonomy. Ship Quality." width="320">

  <p>
    <strong>GUIDE AUTONOMY. SHIP QUALITY.</strong>
    <br>
    AI 에이전트가 전속력으로 달리되, 계획·증거·리뷰를 거친 코드만 main 에 도달하게 하는 Claude Code 플러그인.
  </p>

  <p>
    <a href="https://github.com/JayJihyunKim/rein/issues/new?labels=bug">버그 신고</a>
    ·
    <a href="https://github.com/JayJihyunKim/rein/issues/new?labels=enhancement">기능 요청</a>
    ·
    <a href="docs/agents-md-examples.md">AGENTS.md 예시</a>
  </p>

  <p>
    <a href="https://github.com/JayJihyunKim/rein/releases">
      <img src="https://img.shields.io/github/v/release/JayJihyunKim/rein?style=flat-square&label=version" alt="Latest release version">
    </a>
    <a href="LICENSE">
      <img src="https://img.shields.io/github/license/JayJihyunKim/rein?style=flat-square" alt="MIT License">
    </a>
    <a href="https://github.com/JayJihyunKim/rein/stargazers">
      <img src="https://img.shields.io/github/stars/JayJihyunKim/rein?style=flat-square" alt="GitHub stars">
    </a>
    <img src="https://img.shields.io/badge/Claude%20Code-required-5A67D8?style=flat-square" alt="Claude Code 필수">
    <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL2-lightgrey?style=flat-square" alt="지원 플랫폼">
  </p>

</div>

---

## Rein 이란

Rein 은 AI 에이전트에게 운영 코드를 맡기되 "프롬프트 규율" 에만 의존하고 싶지 않은 팀을 위한 Claude Code 플러그인입니다. 저장소 차원의 가드레일을 추가해 에이전트가 **작업을 먼저 정의**하고 **증거를 남기고** **리뷰를 통과한 뒤에만** 코드를 커밋할 수 있게 합니다.

**Rein 을 쓰면 좋은 경우**:

- 장기 유지보수하는 코드베이스
- AI 출력의 **일관성**이 raw 속도보다 중요한 팀
- 코드 리뷰·증거·체크포인트를 사람의 머릿속이 아니라 **팀의 규율로 코드화**하고 싶은 경우

**Rein 을 쓰지 말아야 하는 경우**:

- 일회성 스크립트, throwaway 프로젝트
- 저장소에 process 파일이 추가되는 것을 원하지 않는 팀
- POSIX bash / WSL2 외 환경 (네이티브 Windows PowerShell 미지원)

> **툴 지원**: Rein 의 자동 가드레일은 Claude Code 의 hook 라이프사이클을 기반으로 합니다. 동일한 규약 (AGENTS.md, rule 파일) 은 Cursor / Copilot 에서는 **참고 문서로만** 작동하며 자동 차단은 일어나지 않습니다.

---

## 무엇이 달라지나 — 30초 예시

**Rein 없이 — 흔한 흐름**

```
개발자: "로그인 기능 구현해줘"
   ↓
AI: 코드 작성 → git commit
   ↓
리뷰 없음. 완료 기준 없음.
다음 세션엔 무엇을 왜 했는지 흔적이 없다.
```

**Rein 적용 — 같은 요청**

```
개발자: "로그인 기능 구현해줘"
   ↓
Rein: "먼저 trail/dod/dod-2026-04-22-login.md 에 완료 기준을 작성하세요"
   → AI 가 체크리스트 작성 (DoD 파일)
   ↓
AI 가 코드 편집 (DoD 가 존재하므로 허용됨)
   ↓
AI 가 git commit 시도
   → Rein: "리뷰 완료 기록이 없습니다. 차단."
   → AI 가 codex 리뷰 실행 → 리뷰 기록 생성 → 커밋 허용
   ↓
세션 종료 시 결정·변경 내역이 trail/inbox/ 에 자동 기록.
다음 세션 시작 시 trail/index.md (프로젝트 상태 요약) 가
자동 로드되어 컨텍스트가 이어집니다.
```

---

## 왜 AI-Native?

| | AI Assisted (기존) | AI Native (Rein) |
|---|---|---|
| 지시 방식 | "이 함수 이렇게 만들어줘" | "이 워크플로우를 실행해줘" |
| 기준 위치 | 사람 머릿속 | `AGENTS.md`, `rules/`, `trail/` |
| 결과가 나쁠 때 | 출력물 다시 요청 | 잘못 통과시킨 규칙을 수정 |
| 확장성 | 매번 사람이 개입 | 규칙이 쌓일수록 품질 자동 상승 |

AI-assisted 워크플로에서는 모든 수정이 재요청입니다. AI-native 워크플로에서는 모든 수정이 다음에 같은 실수를 막는 규칙이 됩니다. Rein 이 두 번째를 가능하게 합니다.

---

## 무엇을 보장하나

1. **코드 편집 전에 작업이 먼저 정의된다.** 모든 소스 편집 전에 완료 기준 (Definition of Done) 파일이 필요합니다.
2. **리뷰 통과 전엔 commit·테스트가 차단된다.** 리뷰 기록이 생기기 전까지 `git commit` 과 테스트 실행이 막힙니다.
3. **증거가 자동으로 쌓이고 회전된다.** 새 작업은 `trail/inbox/` 에 기록됩니다. 다음 날 어제까지의 inbox 가 `daily/` 요약으로 병합되고, 7일 지난 daily 항목은 `weekly/` 로 병합됩니다. 다음 세션 시작 시 `trail/index.md` 만 자동 로드되며, 과거 요약은 필요 시 명시 read 합니다.
4. **업데이트는 Claude Code 플러그인 매니저가 처리한다.** 플러그인이 자기 파일을 소유하므로 사용자 수정 파일은 건드리지 않습니다.
5. **두 모델을 한 세션에서.** Rein 은 구현은 Claude 에, 코드 리뷰는 Codex 에 라우팅합니다 (Codex 미설치 시 자동으로 Claude fallback). 두 모델의 강점을 Claude Code 세션 안에서 그대로 활용하므로 도구를 전환할 필요가 없습니다.

---

## 설치

> Claude Code 안에서 명령 두 개 → 첫 세션의 bootstrap 만 승인하면 끝. 셸 설치 스크립트 없음.

```
1. /plugin marketplace add JayJihyunKim/rein
2. /plugin install rein@rein
3. Claude Code 세션 재시작
4. 첫 실행 시 Claude 가 Rein 초기화 여부를 물어봅니다 — yes 답변.
```

이게 전부입니다. 첫 세션에서 Claude 가 `trail/` 과 `.rein/` 을 저장소에 자동 생성합니다. `curl` 설치 스크립트도, 직접 입력해야 할 셸 명령도 없습니다.

### 요구사항

| 항목 | 버전 | 비고 |
|---|---|---|
| OS | macOS, Linux, Windows WSL2 | — |
| Claude Code | 최신 버전 | 필수 |
| git | 임의 버전 | — |
| bash | 3.2+ | hook 실행에만 사용 |
| **Codex CLI** | 최신 버전 | **권장.** Rein 의 리뷰 게이트는 신뢰도 높은 리뷰를 위해 Codex 를 사용합니다. Codex 가 설치되어 있지 않으면 Rein 은 자동으로 Claude (`code-reviewer` 스킬) 로 fallback 하며, fallback 사유가 리뷰 기록에 남습니다. |

---

## 저장소에 추가되는 것

```
your-repo/
├── .rein/
│   ├── project.json          ← Rein 모드 + scope (커밋 대상)
│   └── policy/               ← 저장소 로컬 정책 템플릿
│       ├── hooks.yaml
│       └── rules.yaml
├── trail/                    ← 증거 저장소 (자동 회전)
│   ├── inbox/                ← 오늘 완료한 작업 기록 (다음 세션에 어제 항목이 daily/ 로 병합)
│   ├── daily/                ← 일간 요약 (7일 지난 항목은 weekly/ 로 병합)
│   ├── weekly/               ← 주간 요약
│   ├── dod/                  ← 완료 기준 파일
│   ├── decisions/            ← 주요 아키텍처 결정 기록
│   ├── incidents/            ← hook 차단 기록 (규칙 발전에 사용)
│   ├── agent-candidates/     ← 반복 incident 패턴에서 제안된 새 에이전트 후보
│   └── index.md              ← 현재 프로젝트 상태 (5~25 줄, 세션 시작 시 자동 로드)
└── .claude/
    └── settings.json         ← 한 줄: `rein` 플러그인 핀
```

이게 전부입니다. 프레임워크의 **hook·rule·agent·skill** 은 플러그인 안에 ship 되어 Claude Code 의 플러그인 캐시에 들어 있습니다 — 사용자 저장소에는 복사되지 않으므로, 플러그인 업데이트가 사용자 파일을 덮어쓰지 않습니다. 프로젝트 고유의 지시 사항을 함께 두고 싶다면 사용자 저장소에 직접 `AGENTS.md` (또는 `.claude/CLAUDE.md`) 를 작성하세요. Rein 은 이를 읽기만 하고 수정하지 않습니다.

> 권장: `trail/` 과 `.claude/cache/` 를 사용자 `.gitignore` 에 추가하세요 (세션 증거를 git 에 커밋하지 않으려는 경우). Rein 은 `.gitignore` 를 자동 편집하지 않습니다.

---

## 플랫폼 지원

| 플랫폼 | 상태 |
|---|---|
| macOS | ✅ 공식 지원 |
| Linux | ✅ 공식 지원 |
| Windows (WSL2) | ✅ 공식 지원 |
| Windows (Git Bash / MSYS2) | ⚠️ best-effort, 정식 테스트 대상 아님 |
| Windows (PowerShell / CMD native) | ❌ 미지원 |

Windows 사용자는 **WSL2 (Ubuntu)** 를 권장합니다. 설치 방법과 Git Bash 진단은 [docs/troubleshooting/windows.md](docs/troubleshooting/windows.md) 참조.

---

## Troubleshooting

<details>
<summary><code>/plugin marketplace add</code> 가 인식되지 않음</summary>

최신 버전의 Claude Code 를 사용하세요. marketplace 명령은 단수형 `/plugin` 입니다 (`/plugins` 아님).

```
/plugin marketplace add JayJihyunKim/rein
```

</details>

<details>
<summary>첫 세션에 Claude 가 bootstrap 을 묻지 않음</summary>

bootstrap 안내는 `.rein/project.json` 이 없는 디렉토리에서 Claude Code 를 처음 열 때 등장합니다. git 저장소 안에 있는지 확인하세요.

```bash
git init       # 새 저장소를 초기화하거나
cd your-repo   # 기존 저장소로 이동 후
# Claude Code 새 세션 시작
```

</details>

<details>
<summary>모든 편집이 차단됨</summary>

`everything-claude-code` 플러그인 (>= 1.9.0) 이 Rein 과 함께 설치되어 있으면 `gateguard-fact-force` hook 이 Rein 과 충돌해 deadlock 이 발생합니다. Rein 이 동등한 기능을 제공하므로 해당 플러그인을 제거하세요.

```bash
claude plugin remove everything-claude-code
```

</details>

<details>
<summary>Windows 에서 작동하지 않음</summary>

네이티브 Windows (PowerShell / CMD) 는 미지원입니다. WSL2 를 설치하고 Ubuntu 환경에서 실행하세요. [docs/troubleshooting/windows.md](docs/troubleshooting/windows.md) 참조.

</details>

---

## Security

**보안 취약점은 공개 GitHub 이슈로 신고하지 마세요.**

취약점을 발견한 경우 GitHub Security Advisories 를 통해 비공개 신고해 주세요: [취약점 신고](https://github.com/JayJihyunKim/rein/security/advisories/new).

---

## Contributing

이슈나 PR 은 환영합니다.

1. 저장소를 Fork
2. 기능 브랜치 생성: `git checkout -b feat/amazing-feature`
3. 변경사항 커밋: `git commit -m "feat: add amazing feature"`
4. 브랜치 Push: `git push origin feat/amazing-feature`
5. Pull Request 열기

PR 전에 [`AGENTS.md`](AGENTS.md) 에서 프레임워크 구조와 기여 규칙을 먼저 파악해 주세요.

| 커밋 타입 | 사용 시점 |
|---|---|
| `feat:` | 새 기능 |
| `fix:` | 버그 수정 |
| `docs:` | 문서 변경 |
| `refactor:` | 동작 변경 없는 코드 개선 |
| `test:` | 테스트 변경 |
| `chore:` | 유지보수 작업 |

---

## 릴리즈 히스토리

최신 릴리즈: **v1.0.0** (2026-04-30) — Plugin-only OSS launch

이전 dev cycle 히스토리 (v0.x) 는 [docs/changelog-archive/2026-04-pre-v1.md](docs/changelog-archive/2026-04-pre-v1.md) 참조.

전체 릴리즈 노트: [CHANGELOG.md](CHANGELOG.md)

---

## License

MIT — [LICENSE](LICENSE) 참조.

---

## 참고

- [agentsmd/agents.md](https://agents.md) — AGENTS.md 계층 구조
- [anthropics/skills](https://github.com/anthropics/skills) — Skill 정의
- [Shields.io](https://shields.io) — 배지 생성

---

<div align="center">
  <sub>Built by <a href="https://github.com/JayJihyunKim">JayJihyunKim</a></sub>
</div>
