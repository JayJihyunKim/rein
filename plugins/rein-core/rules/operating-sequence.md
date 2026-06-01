# Operating Sequence — 11-step 강제 작업 시퀀스

## 행동 강령

DoD → routing → implement → codex-review → security-review → fix → test → self-review → inbox → index 순서를 따른다. hook 이 차단하면 stderr 안내에 따라 이전 단계로 복귀. Answer-only mode (단순 정보·의견·tradeoff) 는 skip 하지만 코드 편집 의도 발생 즉시 정상 시퀀스 자동 전환 (`pre-edit-dod-gate.sh`).

## 11-step 압축 표

| # | Step | 행동 / 산출물 | Why |
|---|------|------|-----|
| 1 | READ | `trail/index.md` 읽기 | 현재 상태·미해결 작업 파악 |
| 2 | WRITE DoD | `trail/dod/dod-YYYY-MM-DD-<slug>.md` | 작업 기준 — gate 가 source 편집 차단 |
| 3 | ROUTE | DoD `## 라우팅 추천` (agent/skills/mcps/approved_by_user) | 조합 추천 후 사용자 승인 |
| 4 | IMPLEMENT | 승인된 조합으로 코드 편집 | DoD 범위 안에서만 변경 |
| 5 | CODEX REVIEW | `/codex-review` → `.codex-reviewed` stamp | 외부 모델 second opinion. stamp 는 commit gate 가 강제 |
| 6 | SECURITY REVIEW | `security-reviewer` → `.security-reviewed` stamp | profile.yaml 레벨 기준 검토. stamp 는 commit gate 가 강제. **단**, DoD 라우팅 추천의 `security_tier: light` + `approved_by_user: true` 이면 stamp 없이 commit 허용 (`.codex-reviewed` 는 여전히 필수) |
| 7 | FIX | 두 리뷰 결과 반영 수정 | 의견 반영 후 stamp 유지 |
| 8 | TEST | 테스트 실행 | 테스트 실행 자체는 비차단 (TDD red-green 허용) — 두 stamp 는 `git commit` gate 가 강제 (`pre-bash-test-commit-gate.sh`) |
| 9 | SELF-REVIEW | AGENTS.md §6 명시적 답변 | 자가 점검으로 누락 방지 |
| 10 | WRITE inbox | `trail/inbox/YYYY-MM-DD-<작업명>.md` | 작업 완료 기록 (gate 강제) |
| 11 | UPDATE index | `trail/index.md` 갱신 | 세션 종료 전 상태 (gate 강제) |

## 차단 시 행동

1. **게이트 우회 절대 금지 (가드레일).** hook 차단(exit 2)을 만나면 차단을 유발한 조건을 **정당한 경로로만** 해소한다 — 누락 단계 완료, 실제 조건 수정. 게이트를 통과시키려고 환경을 조작하는 행위는 **금지**: 파일 수정시각(mtime) 되돌리기·`touch`, 마커/도장(stamp) 위조·삭제·내용 편집, 타임스탬프 조작, hook 비활성화. 차단이 **오탐**으로 보여도 스스로 우회하지 말고 **멈춘다**.
2. **오탐은 escalate.** 차단이 오탐으로 보이면 (a) 막힌 파일, (b) 차단 이유, (c) 오탐이라 보는 근거를 보고한다 — 메인 세션은 **사용자에게**, 서브에이전트는 **부모 호출자에게** (worker 는 최종 메시지의 구조화 결과 `status: blocked` 로 신호). 정당한 해소는 사용자/메인테이너가 수행한다 (재리뷰 → 내용 기반 도장, 또는 승인 후 retrospective 재도장).
3. 차단이 정당하면 stderr 안내에 따라 원인 수정·즉시 재시도 (작업 중단 금지).
4. 같은 위반 2회 누적 시 `incidents-to-rule` 권장 (반복 패턴 → 규칙화), 3회 누적 시 `incidents-to-agent` 권장 (반복 패턴 → 에이전트 후보화).

## DoD 의무 섹션 (Step 2)

신규 DoD 작성 시 다음 섹션을 반드시 포함:

- `## 범위` — IN/OUT 명시
- `## 변경 파일` — repo-relative literal path 를 1개 이상 bullet list (`- <path>`) 로 나열. glob / regex 미지원 (G3-DOD-TEMPLATE-CHANGED-FILES-SECTION, 첫 cycle). `post-edit-meta-check.sh` sub-hook 가 본 섹션을 dirty git diff 와 비교해 advisory 발화
- `## 검증 기준` — 완료 판정 가능한 측정값 / 실행 명령
- `## 라우팅 추천` — agent / skills / mcps / security_tier / approved_by_user (pre-edit-dod-gate 가 누락 시 source 편집 차단)
