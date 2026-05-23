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

## Claude Code 워크플로와 Rein 의 차이

Claude Code 워크플로는 에이전트가 작업을 *수행* 하도록 돕습니다. Rein 은 그 작업이 *언제 진행되어도 되는지* 를 제약합니다.

| 레이어 | Claude Code | Rein |
|---|---|---|
| 명령 | 에이전트에게 작업을 요청 | 작업이 절차를 따르도록 강제 |
| 훅 | lifecycle 지점에서 자동화 실행 | lifecycle 전반에 게이트 강제 |
| 리뷰 | 선택적 명령/습관 | commit 전 필수 stamp |
| 컨텍스트 | 프롬프트/세션 메모리 | repo-local 증거 trail |
| 팀 규칙 | 지침 | 실행 가능한 정책 |

Claude Code 는 에이전트에게 도구를 줍니다. Rein 은 팀에게 통제권을 줍니다. hook lifecycle 은 [docs/architecture.md](docs/architecture.md), governance 모델은 [docs/policy-model.md](docs/policy-model.md) 참조.

---

## 무엇을 보장하나

1. **코드 편집 전에 작업이 먼저 정의된다.** 모든 소스 편집 전에 완료 기준 (Definition of Done) 파일이 필요합니다.
2. **리뷰 통과 전엔 commit·테스트가 차단된다.** 리뷰 기록이 생기기 전까지 `git commit` 과 테스트 실행이 막힙니다.
3. **증거가 자동으로 쌓이고 회전된다.** 새 작업은 `trail/inbox/` 에 기록됩니다. 다음 날 어제까지의 inbox 가 `daily/` 요약으로 병합되고, 7일 지난 daily 항목은 `weekly/` 로 병합됩니다. 다음 세션 시작 시 `trail/index.md` 만 자동 로드되며, 과거 요약은 필요 시 명시 read 합니다.
4. **업데이트는 Claude Code 플러그인 매니저가 처리한다.** 플러그인이 자기 파일을 소유하므로 사용자 수정 파일은 건드리지 않습니다.
5. **두 모델을 한 세션에서.** Rein 은 구현은 Claude 에, 코드 리뷰는 Codex 에 라우팅합니다 (Codex 미설치 시 자동으로 Claude fallback). 두 모델의 강점을 Claude Code 세션 안에서 그대로 활용하므로 도구를 전환할 필요가 없습니다.

---

## 설치

> Claude Code 안에서 명령 두 개 → 첫 편집 시점에 Rein 이 안내하는 bootstrap 명령을 실행하면 끝. 셸 설치 스크립트 없음.

```
1. /plugin marketplace add JayJihyunKim/rein
2. /plugin install rein@rein
3. Claude Code 세션 재시작
```

설치 후, 에이전트가 처음으로 소스 편집 (Edit / Write / MultiEdit) 또는 Bash 명령을 시도하면 Rein 의 bootstrap gate 가 `trail/` 부재를 감지해 **해당 동작을 차단**하고 한 줄짜리 `python3 …/rein-bootstrap-project.py` 명령을 표시합니다. 그 명령을 실행하면 `trail/` 과 `.rein/` 이 생성되며 이후 편집은 정상적으로 통과합니다. `/reload-plugins` 이후에도 동일한 흐름이 적용됩니다 — 새 세션 시작과 같은 경로로 수렴합니다.

non-git 프로젝트도 지원됩니다 — `git init` 은 **불필요**합니다. `git_root` 가 없으면 bootstrap 이 프로젝트 디렉토리 자체를 root 로 사용합니다.

gate 를 끄려면 `.rein/policy/hooks.yaml` 에 `bootstrap-gate: false` 를 추가하세요. 자세한 옵션은 troubleshooting docs 에 있습니다.

### 요구사항

| 항목 | 버전 | 비고 |
|---|---|---|
| OS | macOS, Linux, Windows WSL2 | — |
| Claude Code | 최신 버전 | 필수 |
| git | 임의 버전 | — |
| bash | 3.2+ | hook 실행에만 사용 |
| **Codex CLI + 유료 ChatGPT 요금제** | 최신 버전 | **강력 권장.** Rein 의 리뷰 게이트는 독립적이고 신뢰도 높은 second opinion 을 위해 코드 리뷰를 Codex 로 라우팅합니다. Codex 실행에는 유료 ChatGPT 요금제 (**Plus 이상**) 또는 OpenAI API 키가 필요합니다. Codex 가 없으면 Rein 은 Claude (`code-reviewer` 스킬) 로 fallback 하고 사유를 리뷰 기록에 남깁니다 — 동작은 하지만 Rein 이 설계상 전제하는 두 번째 모델 리뷰를 잃습니다. |

> **권장 설정 — Rein 을 의도대로 쓰려면.** Rein 은 **Claude 가 구현하고 Codex 가 리뷰하는** 두 모델 분리 구조를 전제로 설계됐습니다. 제대로 된 경험을 위해 [Codex CLI](https://github.com/openai/codex) 를 설치하고 유료 ChatGPT 요금제 — **Plus 이상** — 로 로그인하세요. 독립적인 Codex 리뷰는 Rein 가드레일의 핵심입니다. Codex 가 없을 때의 Claude fallback 은 Rein 을 동작은 시키지만, 의도된 구성이 아닌 degraded 모드입니다.

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

저장소 단위 hook 정책은 `.rein/policy/hooks.yaml` 에서 조정합니다 — `<hook-name>: false` 또는 `<hook-name>: { enabled: false }` 가 모두 허용됩니다. `profile:` 키 (`lean` / `standard` / `strict` 중 하나) 로 무거운 gate 의 기본값을 한꺼번에 바꿀 수 있습니다 — `lean` 은 `post-edit-plan-coverage`, `post-write-spec-review-gate`, `post-write-dod-routing-check` 를 끄고(탐색·문서 작업용), `standard` (기본) 는 모두 활성, `strict` 는 향후 추가 strictness 의 reserved slot 입니다. 개별 hook 항목은 항상 profile 보다 우선합니다.

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
<summary>bootstrap 명령이 보이지 않음</summary>

Rein 은 더 이상 세션 시작 시 자동으로 bootstrap 을 묻지 않습니다. bootstrap 명령은 `trail/` 이 없는 디렉토리에서 에이전트가 **첫 소스 편집** (Edit / Write / MultiEdit) 또는 **첫 Bash 명령** 을 시도하는 시점에만 노출됩니다. 에이전트에게 어떤 편집이든 시켜 보세요 — gate 가 한 줄짜리 `python3 …/rein-bootstrap-project.py` 명령을 출력합니다. 한 번 실행하면 이후 편집은 정상 통과합니다.

`/reload-plugins` 이후에도 동일하게 동작합니다 — 별도의 "첫 세션" 경로가 없습니다. non-git 프로젝트도 지원하므로 `git init` 은 **불필요**합니다.

gate 자체를 끄려면 `.rein/policy/hooks.yaml` 에 `bootstrap-gate: false` 를 추가하세요. 개별 hook 키 (`pre-edit-trail-bootstrap-gate`, `pre-tool-use-bash-bootstrap-gate`) 도 동일한 방식으로 토글할 수 있습니다.

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

최신 릴리즈: **v1.3.7** (2026-05-24) — 보안 하드닝: v1.3.6 의 git 환경 보호를 프로젝트 위치 탐지의 모든 경로(작업 resolver, 세션 상태, trail 보호 게이트, 리뷰 스탬프 기록, legacy 정리 도구)로 확장해, 오염된 `GIT_DIR` 이 엉뚱한 저장소를 프로젝트 루트로 잡는 경로를 전부 닫았습니다 — trail 게이트 우회 가능성 한 곳 포함. 일반 사용 영향 없음. ([CHANGELOG](CHANGELOG.md))

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
