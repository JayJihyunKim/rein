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
| 5 | CODEX REVIEW | `/codex-review` → `.codex-reviewed` stamp | 외부 모델 second opinion + gate |
| 6 | SECURITY REVIEW | `security-reviewer` → `.security-reviewed` stamp | profile.yaml 레벨 기준 검토 |
| 7 | FIX | 두 리뷰 결과 반영 수정 | 의견 반영 후 stamp 유지 |
| 8 | TEST | 테스트 실행 | 두 stamp 있어야 통과 (`pre-bash-guard.sh`) |
| 9 | SELF-REVIEW | AGENTS.md §6 명시적 답변 | 자가 점검으로 누락 방지 |
| 10 | WRITE inbox | `trail/inbox/YYYY-MM-DD-<작업명>.md` | 작업 완료 기록 (gate 강제) |
| 11 | UPDATE index | `trail/index.md` 갱신 | 세션 종료 전 상태 (gate 강제) |

## 차단 시 행동

1. hook 차단 (exit 2) 시 작업 중단 금지 — stderr 의 차단 이유 확인 후 원인 수정·즉시 재시도.
2. 같은 위반 2회 누적 시 `incidents-to-rule` 실행 권장 (반복 패턴 → 규칙화).
3. 같은 위반 3회 누적 시 `incidents-to-agent` 실행 권장 (반복 패턴 → 에이전트 후보화).
