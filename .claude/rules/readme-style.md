# README Style Rule — 신규 유입자 우선 원칙

> 이 규칙은 `README.md` / `README.en.md` 편집 시 적용된다. 기본 방향은 **"내부자 문서가 아니라 신규 유입자가 60초 안에 결심할 수 있는 랜딩 페이지"**.
>
> 근거: 2026-04-22 codex second-opinion 세션. 진단 한 줄 — "정보가 없는 게 아니라, 사용자 가치를 증명하기 전에 내부 구현을 먼저 설명한다."
>
> 강도: **advisory 체크리스트**. hook 강제 없음. 편집 시작 전 이 파일을 읽고, 편집 완료 후 자가 검증.

---

## 1. Pre-install 이해도 체크리스트

설치 섹션(`## Installation` / `## 설치`) **이전** 에 독자가 아래 3가지를 확실히 이해해야 한다. 하나라도 실패하면 README 는 실패.

- [ ] **(a) 이 프로젝트가 해결하는 문제가 무엇인가** — 한 문장으로 요약 가능해야 한다. "AI 어시스턴트가 inconsistent 하다" 수준은 통과.
- [ ] **(b) 채택 후 내 워크플로가 어떻게 달라지는가** — 구현 전략(rules/gates/hooks) 이 아니라 사용자 관점의 **before/after 예시 1개**. 30초 분량.
- [ ] **(c) 언제 쓰고 언제 쓰지 말아야 하는가** — "Use Rein if / Don't use Rein if" 섹션 필수.

### 금지 패턴

- 오프너에서 "rules + automatic gates + lifecycle hooks" 같은 **메커니즘 언어** 로 가치를 설명하는 것. outcome 언어로 바꾸라.
- "agents, skills, and MCPs 조합을 자동 추천" 같이 **내부 모델을 전제로 한 설명**. 독자는 아직 Rein 의 내부 모델을 모른다.
- 설치 전에 Windows 진단 / design-plan coverage / governance Stage 같은 **깊은 내부 디테일**.
- **툴 지원 허위 주장**: 오프너에서 "Claude Code, Cursor, Copilot" 을 나열했으면 Quick Start 도 정말 3개 모두에서 동작해야 한다. 아니라면 **가장 지원이 강한 툴을 명시** 하고 나머지는 "best-effort / planned" 로 분리.

---

## 2. Jargon Disposition 판정 테이블

용어 처리 기준 3단계:

- **(i) inline 정의** — 핵심 개념. 첫 등장 지점에서 한 문장 또는 한 줄 괄호 설명.
- **(ii) 하위 문서로 이동** — README 밖 docs 로. README 에서는 한 줄 언급만 + 링크.
- **(iii) README 에서 완전 제거** — 내부 구현/롤아웃 디테일. CHANGELOG 또는 dev-only doc 으로.

### 현재 확정된 판정 (2026-04-22 기준)

| 용어 | 처리 | 사유 |
|---|---|---|
| `DoD gate`, `trail/`, `hook` | (i) inline | 핵심 개념. Rein 이 뭔지 설명할 때 필수. |
| `covers:` tag, `Scope ID`, `coverage matrix` | (ii) 하위 문서 | 고급 워크플로. 신규 유입자 결정에 불필요. |
| `codex-review`, `brainstorming skill`, `MCP` | (ii) 하위 문서 | 선택적 에코시스템 요소. |
| `rein job`, `rein remove`, `3-way merge` | (ii) 하위 문서 | 고급 CLI. 채택 결정에 불필요. |
| `stamp`, `manifest v2`, `severity escalation` | (iii) 제거 | 내부 구현 디테일. |
| `governance Stage 1/2/3` | (iii) 제거 | 내부 롤아웃 정책. CHANGELOG 소재. |

### 새 용어 추가 시

README 에 신규 용어 도입 시, 본 테이블에 한 줄 추가. 판정 기준: **"이 용어를 모르면 독자가 구글링을 시작하는가?"** — yes 면 (i) 또는 (ii), README 에서 빼도 되는 내부 디테일이면 (iii).

---

## 3. Version History Cut-off 정책

- **README 에 표기하는 릴리즈** = **최신 1개만**. 2-3 bullet 평문 요약. 메인테이너 디테일 금지.
- 나머지 전체 히스토리 = `CHANGELOG.md` 로 이관. README 에는 `See CHANGELOG for full history` 링크.
- Breaking change 가 있는 최근 릴리즈는 짧은 migration note 한 줄 + CHANGELOG 링크로 분리.

### 릴리즈 summary 평문 rule

아래 단어는 README 의 릴리즈 요약에서 **사용 금지** (CHANGELOG 소재):

- `validator v2`, `manifest v2`, `anchored segment matcher`, `POSIX setsid pgroup`, `taskkill /F /T`, `9009 mod 256 = 49`, `automigrate`, `envelope slot`, `path-policy library`, `CLI shim`, `Stage 1/2/3 rollout` 류 전부.

대신 user-facing outcome 으로 번역:
- ❌ `manifest v2 + 3-way merge + .rej 분리`
- ✅ "사용자가 수정한 파일은 업데이트 시 자동 병합되고, 충돌만 사용자에게 물어봅니다"

---

## 4. 권장 섹션 순서 (10 단계)

신규 유입자 시선의 자연스러운 flow:

1. **What Rein is** — 평문 2-3 줄. mechanism 아닌 outcome.
2. **30초 before/after 워크플로 예제** — 1 단락 또는 다이어그램 1개.
3. **Use Rein if / Don't use Rein if** — 각 3-4 bullet.
4. **Install** — 1 명령어.
5. **Quick Start** — 4 단계 이내.
6. **What gets added to your repo** — 간단한 트리 + 한 줄 설명.
7. **CLI reference (trimmed)** — 핵심 명령 6개 이하. 고급 명령은 링크.
8. **Platform support + troubleshooting** — WSL2 지침 및 Windows 진단 **여기로 이동** (상단 금지).
9. **Advanced docs** — skills, compatibility notes, design/plan coverage 등 **링크만**.
10. **CHANGELOG 링크** — "See CHANGELOG for full release history."

### 금지 배치

- Windows 진단 섹션을 설치 이전에 두는 것 (현재 문제).
- Included Skills 테이블을 Quick Start 직후에 두는 것 (jargon 밀도 과다).
- Project Structure 를 상단 전면에 두는 것 (Quick Start 이후로).

---

## 5. KR / EN Parity 규칙

두 README 는 **구조 동일 + 내용 병렬** 이어야 한다.

- [ ] 섹션 구조 1:1 일치 (순서, 제목, 개수)
- [ ] Feature list 동기화 — 한쪽에만 있는 feature 금지 (예: KR 에 있는 "설계 → 플랜 커버리지" 가 EN 에 없으면 **둘 중 하나로 통일**)
- [ ] Version history 항목 동기화 (양쪽 동일한 릴리즈 목록)
- [ ] **미번역 텍스트 검출** — EN 파일에 한글 잔존 금지, KR 파일에 번역 안 된 영문 잔존 금지 (고유명사·코드 블록 제외)
- [ ] 예시 코드 / 경로 / 명령어 동일
- [ ] 링크 대상 동일 (docs, CHANGELOG, 외부 레퍼런스)

### 편집 원칙

한쪽만 편집하면 반드시 다른 쪽도 즉시 동기화. **drift 가 한 번 발생하면 다음 세션에 알아채지 못한다**.

### Grep 체크

편집 완료 후:

```bash
# EN 파일의 한글 탐지 (코드 블록은 예외)
rg '[ㄱ-힝]' README.en.md

# KR 파일에 영문 문장이 통째로 남았는지 (수동 점검)
```

---

## 6. 재작성 우선순위 (레버리지 순)

버그성 이슈가 아닌 재작성 작업은 아래 순서로 진행. **상위 3개만 해도 신규 유입자 체감 난이도 급격히 감소**.

1. **버전 히스토리 → CHANGELOG.md 이관** (README 에는 최신 1개 요약만).
2. **Windows Git Bash 진단 섹션 → `docs/troubleshooting/windows.md` 로 분리**.
3. **30초 before/after 예제 + "Use Rein if / Don't use Rein if" 섹션 추가**.
4. **오프너 재작성** — outcome 언어로. mechanism 언어 금지.
5. **툴 지원 현황 명시** — Claude Code 중심이면 그렇게 표기.
6. **Design → Plan coverage 섹션 → design/planning doc 으로 이동** (현재 KR README 65-86 줄).
7. **Key Features → 4개 user-facing outcome 으로 재구성**.
8. **Included Skills 테이블 → 별도 docs 페이지** (README 엔 한 줄 요약).
9. **Project Structure → Quick Start 아래 또는 `REIN_SETUP_GUIDE.md` 로**.
10. **미번역 한국어 검출·제거** (현재 EN README 109 줄 `"Python launch 실패 (9009 계열)"`).
11. **KR / EN parity 전면 검토** — feature list + version history 동기화.

---

## 7. Replacement Opener Template

### Template 구조

```
# <Project> — <one-liner positioning>

> <tagline — mechanism-free, outcome-only>

**[KR](...)** | English    (또는 반대)

[License badge]

## What <Project> is

<2-3 문장. outcome 중심. "X is a ... for teams that ... It adds ... so that ...">

**Use <Project> if**:
- <bullet>
- <bullet>

**Don't use <Project> if**:
- <bullet>
- <bullet>

## 30-second workflow example

<diagram or 1-paragraph narrative. 사용자가 실제로 보게 될 변화.>
```

### Rein 에 적용한 예시 (codex 제안, 2026-04-22)

> Rein is a repository scaffold for teams that let AI agents write code but do not want to rely on prompt discipline alone. It adds a small set of repo rules and guardrails so the agent has to define the task, leave an evidence trail, and pass review before code lands.
>
> **Use Rein if** you maintain a long-lived codebase where consistency matters more than raw speed.
>
> **Don't use Rein if** you write throwaway scripts, your team does not want process files in the repo, or you run outside POSIX / WSL.

### "What Rein is NOT" 섹션 (선택)

필요 시 Use/Don't use 바로 아래에 오해 방지용 섹션 추가:

- Rein is **not** a linter / formatter / test runner — it wraps those, does not replace them.
- Rein is **not** an AI model — it shapes how your agent interacts with your repo.
- Rein is **not** a CI/CD system — it runs in your local editing session.

---

## 자가 검증 체크리스트 (편집 완료 후)

- [ ] 설치 섹션 이전에 (a) problem / (b) workflow impact / (c) when-to-use 3개 다 답변됨
- [ ] 오프너에 mechanism 언어(`rules/gates/hooks`, `agents/skills/MCPs`) 없음
- [ ] 신규 용어는 §2 테이블 기준으로 처리됨 (inline / deeper doc / 제거)
- [ ] Version history 는 최신 1개 + CHANGELOG 링크만 남음
- [ ] 섹션 순서가 §4 권장 순서와 일치
- [ ] Windows 진단 섹션이 Platform support 이후로 이동됨
- [ ] KR / EN 구조·내용 sync 확인 (rg 로 미번역 텍스트 0 건)
- [ ] "Use X if / Don't use X if" 섹션 존재
- [ ] 30초 before/after 예제 존재
- [ ] 툴 지원 현황이 정확히 표기됨 (과장 없음)

---

## 변경 이력

- 2026-04-22: 초안 작성 (source: codex-ask 2026-04-22 세션, 대상 `README.md` / `README.en.md`)
