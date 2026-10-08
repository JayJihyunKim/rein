# Operating Sequence — 11-step 강제 작업 시퀀스

## 행동 강령

DoD → routing → implement → codex-review → security-review → fix → test → self-review → inbox → index 순서를 따른다. hook 이 차단하면 stderr 안내에 따라 이전 단계로 복귀. Answer-only mode (단순 정보·의견·tradeoff) 는 skip 하지만 코드 편집 의도 발생 즉시 정상 시퀀스 자동 전환 (`pre-edit-discipline-gate.sh`). 작업 운영 원칙(시작·재개·전환 알림, 사용자 확인 대상의 경계, 합의된 결정 재질문 금지, 결정 기록 위치)은 `## 작업 운영 원칙` 을 따른다.

## 설계 체인

설계 작업은 brainstorm(`rein:brainstorming`) → spec-writer → plan-writer → 구현 순으로 흐른다.
spec/plan 은 전용 에이전트로 작성한다(인라인 작성 시 nudge 가 안내).

## 11-step 압축 표

| # | Step | 행동 / 산출물 | Why |
|---|------|------|-----|
| 1 | READ | `trail/index.md` 읽기 | 현재 상태·미해결 작업 파악 |
| 2 | WRITE DoD | `trail/dod/dod-YYYY-MM-DD-<slug>.md` | 작업 기준 — gate 가 source 편집 차단 |
| 3 | ROUTE | DoD `## 라우팅 추천` (agent/skills/mcps/approved_by_user) | 조합 추천 후 사용자 승인 |
| 4 | IMPLEMENT | 승인된 조합으로 코드 편집(비trivial 이면 분해·병렬 위임 먼저 판단 — 지휘자 기본, `orchestrator-first.md`) | DoD 범위 안에서만 변경 |
| 5 | CODEX REVIEW | `/codex-review` → PASS 시 v2 code_review 증거 발급 | 외부 모델 second opinion. 이 증거는 commit gate 가 강제 |
| 6 | SECURITY REVIEW | `security-reviewer` → PASS 시 v2 security_review 증거 발급 | profile.yaml 레벨 기준 검토. 이 증거는 commit gate 가 강제. `security_tier` 는 검토 강도 힌트일 뿐 게이트는 읽지 않는다 — `light` 여도 이 증거는 필수. 지휘 경로에서는 부모가 발급(`agents/orchestrator.md` 발급 절차), 단독 호출 시 검토자 직접. |
| 7 | FIX | 두 리뷰 결과 반영 수정 | 의견 반영 후에도 이미 발급된 증거는 유지되며, 재리뷰가 필요하면 재발급 |
| 8 | TEST | 테스트 실행 | 테스트 실행 자체는 비차단 (TDD red-green 허용) — 두 v2 증거는 `git commit` gate 가 강제 (`pre-bash-commit-discipline-gate.sh` → `pre-bash-commit-review-gate.sh`) |
| 9 | SELF-REVIEW | AGENTS.md §6 명시적 답변 | 자가 점검으로 누락 방지 |
| 10 | WRITE inbox | `trail/inbox/YYYY-MM-DD-<작업명>.md` | 작업 완료 기록 (gate 강제) |
| 11 | UPDATE index | `trail/index.md` 갱신 | 세션 종료 전 상태 (gate 강제) |

> **git/릴리스 사실의 권위본 = 자동 git 스냅샷** (`.rein/state/git-snapshot.md`, SessionStart/Stop 자동 생성). branch·커밋/push 여부·dirty/clean·ahead·behind·최신 태그 같은 객관 수치는 **index 서술에 손으로 쓰지 말 것** — 스냅샷이 전담한다. 둘이 어긋나면 스냅샷(궁극적으로 살아있는 git)이 이긴다.

## 차단 시 행동

1. **게이트 우회 절대 금지 (가드레일).** hook 차단(exit 2)을 만나면 차단을 유발한 조건을 **정당한 경로로만** 해소한다 — 누락 단계 완료, 실제 조건 수정. 게이트를 통과시키려고 환경을 조작하는 행위는 **금지**: 파일 수정시각(mtime) 되돌리기·`touch`, 마커/도장(stamp) 위조·삭제·내용 편집, 타임스탬프 조작, hook 비활성화. 차단이 **오탐**으로 보여도 스스로 우회하지 말고 **멈춘다**.
2. **오탐은 escalate.** 차단이 오탐으로 보이면 (a) 막힌 파일, (b) 차단 이유, (c) 오탐이라 보는 근거를 보고한다 — 메인 세션은 **사용자에게**, 서브에이전트는 **부모 호출자에게** (worker 는 최종 메시지의 구조화 결과 `status: blocked` 로 신호). 정당한 해소는 사용자/메인테이너가 수행한다 (재리뷰 → 내용 기반 도장, 또는 승인 후 retrospective 재도장).
3. 차단이 정당하면 stderr 안내에 따라 원인 수정·즉시 재시도 (작업 중단 금지).
4. 같은 위반 2회 누적 시 `incidents-to-rule` 권장 (반복 패턴 → 규칙화), 3회 누적 시 `incidents-to-agent` 권장 (반복 패턴 → 에이전트 후보화).

## 작업 운영 원칙

1. **시작·재개·전환 알림** — 작업을 시작할 때, 중단 뒤 재개할 때, 다른 단계(설계 → 구현 → 검토 등)로 넘어갈 때 사용자에게 먼저 세 가지를 알린다: 목표(무엇을 끝내려는가), 현재 위치(어느 단계까지 왔나), 남은 일. 각 1문장.
2. **사용자 확인 대상과 직접 판단 대상의 경계** — 사용자 확인: 범위(DoD·Scope) 변경, 되돌리기 어려운 작업(삭제·배포·외부 공개·강제 push), 보안 수준 완화, 비용이나 시간이 크게 드는 선택, 합의와 다른 방향 전환. 직접 판단: 합의된 범위 안의 구현 방법·파일 구성·명명·테스트 구성, 되돌리기 쉬운 문구 선택. 직접 판단한 것은 작업 완료 보고의 "이유" 에 남긴다(`response-tone.md` 보고 문장 구조).
3. **합의된 결정은 다시 묻지 않는다** — 사용자와 합의했거나 설계 문서·DoD 에 확정으로 기록된 결정은 재질문하지 않는다. 새 사실이 그 결정의 전제를 깨뜨린 경우에만, 무엇이 바뀌었는지 근거와 함께 다시 묻는다.
4. **결정 기록 위치** — 범위·방향 결정은 DoD(`trail/dod/`)와 설계 문서(brainstorm·spec·plan)에, 작업 중 내린 판단과 근거는 완료 기록(`trail/inbox/`)에, 세션을 넘어 이어질 상태는 `trail/index.md` 에 남긴다. 채팅에만 남은 결정은 기록된 것으로 보지 않는다.

## DoD 의무 섹션 (Step 2)

신규 DoD 작성 시 다음 섹션을 반드시 포함:

- `## 범위` — IN/OUT 명시
- `## 변경 파일` — repo-relative literal path 를 1개 이상 bullet list (`- <path>`) 로 나열. glob / regex 미지원 (G3-DOD-TEMPLATE-CHANGED-FILES-SECTION, 첫 cycle). `post-edit-meta-check.sh` sub-hook 가 본 섹션을 dirty git diff 와 비교해 advisory 발화
- `## 검증 기준` — 완료 판정 가능한 측정값 / 실행 명령
- `## 라우팅 추천` — agent / skills / mcps / security_tier / approved_by_user (pre-edit-dod-gate 가 누락 시 source 편집 차단)
