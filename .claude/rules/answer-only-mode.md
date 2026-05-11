# Answer-only Mode — 단순 질문 turn 의 ceremony skip 규칙

> 이 규칙은 매 user turn 시작 시 Claude 가 self-classify 한 결과로 적용된다. hook 강제 없음 — Claude 의 판단 규율로 운영한다. 위반은 회고로 잡는다.
>
> **근거 (2026-04-29 codex-ask 진단)**: rein 의 11단계 강제 작업 시퀀스 + 65KB SessionStart trail 주입이 "프로젝트 ritual 을 따른 답변" 쪽으로 attention 을 끌어가, 단순 사실 질문에서도 git 같은 권위 source 재검증을 건너뛰게 만들었다. 자세한 회고: `trail/dod/dod-2026-04-29-session-context-reduction.md`.

---

## 1. Trigger — Answer-only mode 가 적용되는 turn

다음 중 하나에 명확히 해당하는 user turn 은 Answer-only mode 로 처리한다:

- (a) **정보 조회** — "X 가 뭐야", "Y 의 현재 상태", "Z 와 W 의 차이"
- (b) **의견 / 추천 요청** — "어느 쪽이 좋아", "이 접근 어때", "왜 그렇게 했어"
- (c) **tradeoff 설명** — "이걸 하면 뭐가 달라져", "위험은 뭐야"
- (d) **second opinion 호출** — `/codex-ask`, "독립 시각으로 봐줘" 류
- (e) **계획 수립 단계 대화** — 아직 실제 변경 없이 design choice 를 좁혀가는 turn

다음은 Answer-only mode 가 **적용되지 않는** turn 이다 (정상 11단계 시퀀스 적용):

- 코드 편집 / 파일 신규 생성 / 시스템 변경 / 커밋 / 테스트 실행 의도가 있는 turn
- 사용자가 "구현해줘", "고쳐줘", "만들어줘", "/<implementation-skill>" 등으로 명시적 작업 의뢰
- 사용자가 "Answer-only 그만, 정상 모드로" 류로 명시적 escape 요청

---

## 2. Skip 대상

Answer-only mode 에서는 아래 ceremony 를 모두 skip 한다:

- DoD 작성 (`trail/dod/dod-*.md`)
- 라우팅 추천 + `approved_by_user: true`
- `/codex-review` (Mode A) 자동 호출
- `security-reviewer` 자동 호출
- inbox 기록 (`trail/inbox/YYYY-MM-DD-*.md`)
- index 갱신 (`trail/index.md`)

이건 **ceremony skip 일 뿐 사실 검증 skip 이 아니다** — §3 참조.

---

## 3. Skip 하지 않는 것 (필수 유지)

Answer-only mode 라도 아래는 반드시 한다:

### 3.1 Volatile claim 의 명령 기반 재검증

답변에 다음 종류의 claim 이 들어가면 답변 전에 반드시 명령으로 재검증한다 (trail/index.md / inbox / daily / 메모리 단독 신뢰 금지):

- **release / version / tag / publish 상태** → `git tag --sort=-creatordate | head`, `git ls-remote --tags <remote>`, `git log --decorate -n 5 --all`
- **branch / merge 상태** → `git status -sb`, `git log <branch>..<other>`, remote 비교
- **파일 / 디렉토리 / 코드 존재 여부** → `ls`, `Read`, `grep` (또는 검색 도구). "기억" 으로 단정 금지
- **CI / workflow 동작** → `.github/workflows/*.yml` 직접 read, `gh` 명령
- **dependency / 패키지 버전** → 실제 manifest 파일 read

명령 결과가 trail 과 모순되면 **명령 결과를 trust** + trail/index.md 갱신 후보로 메모. trail 을 우선시하지 않는다.

### 3.2 사용자 의도 재확인

질문이 모호하거나 결정 변수가 누락되면 답변 전에 `AskUserQuestion` 으로 명시적 확인. 답변에 추측이 끼어들지 않게.

### 3.3 정직성

- 모르는 것은 "모름 / 미확인" 으로 표시. 추측을 사실처럼 쓰지 않음
- 메모리 / 직전 세션 / trail 을 인용할 때는 "verified at <시각> by <명령>" 또는 "unverified — 확인 필요" 명시

---

## 4. 자동 escape — Answer-only → 정상 시퀀스

Answer-only turn 으로 시작했어도 다음 중 하나가 발생하는 즉시 정상 11단계 시퀀스로 전환한다:

- 사용자가 후속 turn 에서 "이제 구현해줘" / "고쳐줘" / "/<implementation>" 호출
- Claude 가 답변 도중 코드 편집 / 파일 신규 생성이 필요하다고 판단
- `Edit` / `Write` / `MultiEdit` 도구 호출 의도 발생

전환 시점은 **첫 source 편집 의도 발생 직전**. DoD 부터 다시 시작한다 (`pre-edit-dod-gate.sh` 가 자동으로 차단해서 강제됨).

---

## 5. 사례

### 5.1 GOOD — Answer-only 로 처리해야 할 turn

**예시 1**: "이 프로젝트 v2.0.0 인데 OSS launch 전에 버전 낮출 수 있어?"

→ 정보 + 의견 요청. ceremony skip. 단, "v2.0.0 이 publish 됐나?" 는 volatile claim 이므로 `git ls-remote` / public repo 확인 후 답변.

**예시 2**: "codex-ask 와 codex-review 차이가 뭐야?"

→ 정보 조회. ceremony skip. `.claude/skills/codex-ask/SKILL.md` 와 `codex-review/SKILL.md` 직접 read 후 답변.

### 5.2 BAD — Answer-only 로 잘못 처리한 사례 (trail 우선시)

**실제 사례 (2026-04-29)**: "v2.0.0 인데 버전 낮출 수 있나?"

❌ Claude 가 SessionStart 로 주입된 `trail/index.md` 의 "main 머지 + tag 대기" 문구를 그대로 믿고 "publish 안 됐으니 reset 가능" 이라고 답변. 사용자가 "메인에 머지 안 했어?" 로 지적 후에야 git 으로 재확인.

✅ 올바른 처리: §3.1 에 따라 답변 전 `git log main`, `git tag`, `git ls-remote <public>` 으로 재검증. trail 의 stale 문구는 trust 하지 않음.

### 5.3 BAD — Answer-only 로 처리하면 안 될 turn

**예시**: "session-start hook 의 bulk load 를 제거해줘"

→ 코드 편집 의도 명확. Answer-only 아님. 정상 11단계 시퀀스 적용 (DoD → route → implement → review → test → inbox → index).

---

## 6. 자가 점검 체크리스트 (turn 시작 시)

다음 질문에 답하면 mode 가 결정된다:

- [ ] 이 turn 에서 코드 편집·파일 신규 생성·시스템 변경이 필요한가? → Yes 면 정상 11단계
- [ ] 사용자가 명시적으로 implementation 을 요청했는가? → Yes 면 정상 11단계
- [ ] 둘 다 No 면 Answer-only mode

답변 전 추가 점검:

- [ ] 답변에 release / version / branch / tag / 파일 존재 류 volatile claim 이 있는가? → 있으면 §3.1 명령 재검증
- [ ] 답변에 추측이 사실로 적힌 곳이 있는가? → 있으면 "미확인" 표시 또는 검증

---

## 7. 운영 노트

- 이 규칙은 **advisory** — hook 강제 없음. 위반 발견 시 incident 로 기록 (`trail/incidents/`) 후 회고에서 규칙 강화
- 같은 위반 (예: trail 단독 trust 로 오답) 2회 반복 시 `incidents-to-rule` 로 본 규칙 강화 또는 hook 도입 검토
- §3.1 의 volatile claim 카테고리는 incident 누적에 따라 확장
