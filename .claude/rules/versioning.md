# Versioning Rule — 변경 유형 기반 semver

> 이 규칙은 `scripts/rein.sh` 의 `VERSION=` 값과 git tag 를 결정할 때 적용된다. 기본 방향은 **"main 머지 횟수 = 버전 수"** 가 아니라 **"user-visible 변화 = 버전 수"**.
>
> 근거: 2026-04-22 세션 회고 — 2026-04-19/20/21 3일간 v0.7.2 ~ v1.1.0 까지 **총 11개 버전** 이 릴리즈됨. 패치와 minor, major 의 구분이 약해졌고, `rein update` 사용자가 "뭐가 실제로 바뀌었나" 를 판단하기 어려워짐.
>
> 강도: **advisory 체크리스트**. hook 강제 없음. main 머지 직전 이 파일을 읽고, CHANGELOG + tag 결정 시 자가 검증.

---

## Rule A — 변경 유형별 bump 정책

### 판정 테이블

| 변경 유형 | bump 등급 | 예시 |
|---|---|---|
| **User-facing breaking** | **major** (`X+1.0.0`) | CLI 명령 signature 변경·제거, hook 동작 변경 (exit code / 차단 범위), install path 이동, 환경변수 rename |
| **User-facing 신규 기능** | **minor** (`X.Y+1.0`) | 새 CLI 명령 추가, 새 hook 유형, 새 user-exposed skill, 새 user-visible workflow |
| **User-facing 버그 수정** | **patch** (`X.Y.Z+1`) | hook 오작동 수정, install 스크립트 수정, Windows 호환성 patch |
| **내부 전용 변경** | **no bump** | internal refactor, test 추가/수정, 메인테이너 tooling, CI 변경, docs-only, internal rule 조정, CHANGELOG 정리 |

### 복합 변경 처리

한 번의 main 머지에 여러 등급이 섞여 있으면 **최상위 등급 1회만** 적용한다.

- breaking + feature + patch + docs → **major** 1회
- feature + patch + docs → **minor** 1회
- patch + docs → **patch** 1회
- docs-only → **no bump**

### "user-facing" 판정 기준

아래 중 하나 이상 해당하면 user-facing:

- [ ] `rein` CLI 명령 표면이 바뀜 (새 명령 / 옵션 / exit code)
- [ ] 사용자 프로젝트의 hook 동작이 바뀜 (차단 조건 / 메시지)
- [ ] `rein update` 가 사용자 repo 에 다른 파일을 쓰거나 기존 동작을 바꿈
- [ ] AGENTS.md / CLAUDE.md / rules 의 **사용자 프로젝트에 복사되는** 내용이 바뀜
- [ ] 설치·환경변수·install path 가 바뀜
- [ ] 사용자가 호출할 수 있는 skill / slash command 가 추가·제거·signature 변경

아래 중 하나에만 해당하면 internal (no bump):

- 메인테이너 전용 규칙 / 개발 프로세스 문서
- `tests/**` 만 변경
- main 제외 경로만 변경 (`docs/specs/**`, `trail/**` 등 branch-strategy.md §제외 항목)
- internal hook helper (`.claude/hooks/lib/**`) 의 리팩토링 — 외부 hook 동작 불변
- CHANGELOG.md 자체 수정 / README 리라이트 / REIN_SETUP_GUIDE 수정

---

## Rule B — 같은 날 복수 bump 금지

하루에 main 머지는 **1회** + 버전 승격 **최대 1단계**.

### 이유

- semver 의 신호 가치 보존 (`v1.2.0 → v1.3.0` 은 "실제로 뭔가 바뀌었음" 을 의미해야 함)
- `rein update` 알림 피로도 방지
- 회고·롤백 용이성 — 하루 1 버전 = 하루 1 롤백 단위

### 예외 — 긴급 hotfix

critical 버그 (설치 실패 / 훅 deadlock / 보안 regression) 는 같은 날 patch+1 1회 허용. 단:

- [ ] 사유를 커밋 메시지 1줄에 명시 (`hotfix: <증상>`)
- [ ] CHANGELOG 에도 "hotfix for <prev-version>" 표기
- [ ] 같은 날 hotfix 는 1회만. 2회차부터는 원인 재분석 필요

### 하루 누적 변경 처리

하루 동안 여러 PR / commit 이 main 대상이라면:

1. 모두 dev 에 쌓기
2. 다음 근무일 아침에 한번에 main 머지
3. 누적 변경의 **최상위 등급** 으로 1회 승격 (Rule A 복합 변경 처리)

---

## Rule C — CHANGELOG 는 user-facing 만

### CHANGELOG.md 의 수용 범위

`CHANGELOG.md` = **`rein update` 사용자가 읽는 문서**. internal 변경은 git log 로 충분.

포함 대상:
- 새 CLI 명령 / 옵션 / 환경변수
- hook 동작 변경
- 사용자 repo 에 쓰이는 파일 변경 (AGENTS.md, rules, skills, workflows)
- 설치·업데이트 동작 변경
- 심각한 버그 수정 (hotfix 포함)

제외 대상:
- 메인테이너 tooling (`rein-govcheck`, 내부 validator 개선)
- hook helper 리팩토링 (외부 동작 불변)
- 테스트 신설·수정
- 내부 규칙 문서 (`.claude/rules/versioning.md`, `readme-style.md`, `branch-strategy.md`)
- docs path 변경·오타 수정
- CI 워크플로 변경

### 분리 옵션

internal 변경 로그가 필요하면 `CHANGELOG-internal.md` 로 분리 — main 제외 대상으로 branch-strategy.md 에 명시.

---

## Rule 적용 체크리스트 (main 머지 직전)

- [ ] 누적 변경을 Rule A 판정 테이블로 분류 — 최상위 등급 확인
- [ ] 오늘 이미 main 머지한 게 없는지 확인 (Rule B)
- [ ] 있다면 오늘은 추가 머지 skip, 다음날로 이월 (hotfix 예외는 사유 명시 후 허용)
- [ ] 선정된 bump 등급으로 `scripts/rein.sh` 의 `VERSION=` 수정
- [ ] `CHANGELOG.md` 에 **user-facing 항목만** 추가 (Rule C)
- [ ] main 머지 + tag 생성 (`git tag vX.Y.Z`)
- [ ] trail/index.md 의 "직전 릴리즈" 업데이트

---

## 자가 검증 예시

### 본 세션 (2026-04-22 README 재작성)

| 변경 | 분류 | 등급 |
|---|---|---|
| README.md / README.en.md 재작성 | docs-only | no bump |
| `.claude/rules/readme-style.md` 신설 | internal 규칙 | no bump |
| `docs/troubleshooting/windows.md` 신설 | docs-only | no bump |
| `.claude/CLAUDE.md` @import 추가 | internal | no bump |
| `.claude/rules/branch-strategy.md` 갱신 | internal 규칙 | no bump |

→ **Rule A 판정: no bump**. 현재 버전 v1.1.0 유지.

### 가상 예시 — 새 CLI 명령 + docs

| 변경 | 분류 | 등급 |
|---|---|---|
| `rein doctor` 신규 명령 | user-facing 신규 | minor |
| `rein --help` 출력 표현 조정 | docs-only | no bump |

→ Rule A 최상위 등급 = **minor**. bump.

### 가상 예시 — 여러 patch 하루 누적

v1.1.0 에서 오전에 hook 수정 patch 1건, 오후에 hook 수정 patch 또 1건:

- Rule B 적용: 첫 머지는 v1.1.1 (hotfix 사유 명시), 두 번째는 **다음날로 이월**
- 다음날 아침 머지: v1.1.2 (누적 patch 1건)

---

## 변경 이력

- 2026-04-22: 초안 작성. 이전 규칙 ("main 머지 = 버전 bump") 을 Rule A/B/C 로 교체. 근거는 본 파일 상단 참조.
