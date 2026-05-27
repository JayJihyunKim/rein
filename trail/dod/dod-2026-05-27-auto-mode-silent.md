# 자동모드 시맨틱 — 마커 파일 + 알림 hook 5개 silent (block 포함)

- 날짜: 2026-05-27
- 유형: feat (자동모드 incident 알림 silence)
- plan ref: 없음 (need-to-confirm.md `# 자동모드` 항목 단발 구현, 사용자 결정 2건 stamped)
- 선행 commit: dev `413169d` (TONE-1 + G3 cleanup)

## 범위

사용자가 자율 진행 (`/loop`, "Auto Mode Active" system-reminder, 사용자 명시 자동 cycle) 중 `incidents-to-rule` 권고 / pending incident 알림 / session-end block 이 매 turn 발화하는 문제 해결. 마커 파일 1개 + helper 함수 1개 + 자동 토글 스킬 2개 + 알림 발화 hook 5개 silence 분기 추가.

## 사용자 결정 (2026-05-27 turn)

1. 감지 방식 = **마커 파일 + 자동 스킬 (rein:auto-mode-on / rein:auto-mode-off)**
2. 알림 범위 = **block 도 포함 (완전 silent)** — 자동모드에서 stop-session-gate block 도 bypass. 안전 장치 = block bypass 시 `trail/incidents/auto-mode-bypass.log` 에 audit 기록.

## 변경 파일

### Plugin source

- `plugins/rein-core/hooks/lib/auto-mode.sh` (신규) — `is_auto_mode()` 함수. `.rein/auto-mode.flag` 존재 검사. fail-open (helper 부재/권한 오류 → 0 false 반환 = 자동모드 아님).
- `plugins/rein-core/skills/auto-mode-on/SKILL.md` (신규) — `mkdir -p .rein && touch .rein/auto-mode.flag` 가이드.
- `plugins/rein-core/skills/auto-mode-off/SKILL.md` (신규) — `rm -f .rein/auto-mode.flag` 가이드.
- `plugins/rein-core/hooks/session-start-load-trail.sh` (modify, line 317 부근) — incident 알림 emit 직전 `is_auto_mode` 체크.
- `plugins/rein-core/hooks/stop-session-gate.sh` (modify, 3 emit 지점: line 91 advisory + line 391 block-missing-emit + line 400 main block) — 자동모드 시 block 우회 + audit log 기록.
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` (modify, line 116 + 325 누적 WARNING) — 자동모드 시 silent.
- `plugins/rein-core/hooks/lib/bash-guard-infra.sh` (modify, line 92 누적 WARNING) — 자동모드 시 silent.

### Tests

- `tests/hooks/test-auto-mode.sh` (신규) — (a) is_auto_mode helper 동작 (marker 있/없), (b) stop-session-gate block bypass + audit log 기록 검증, (c) pre-edit-dod-gate 누적 WARNING silent 검증.

### Trail

- `trail/dod/dod-2026-05-27-auto-mode-silent.md` (본 DoD)
- `trail/dod/.active-dod` / `.codex-reviewed`
- `trail/inbox/2026-05-27-auto-mode-silent.md` (완료 시점)
- `trail/index.md` (세션 종료 직전)
- `need-to-confirm.md` (수정 — `# 자동모드` 항목 strike, dev commit reference)

## 검증 기준

1. **helper**: `is_auto_mode` 가 marker 존재 시 exit 0, 부재 시 exit 1, 권한 오류/helper 부재 시 fail-open (exit 1 = 자동모드 아님으로 가정 — 안전).
2. **silent 분기**: 5 hook 모두 자동모드 시 알림 emit 0 byte (stdout/stderr empty for that branch).
3. **block bypass audit**: stop-session-gate block 우회 시 `trail/incidents/auto-mode-bypass.log` 에 1 line append (timestamp + reason + 우회 incident count).
4. **무자동모드 회귀**: marker 부재 시 기존 알림/block 정상 발화 (기존 동작 100% 보존).
5. **회귀 테스트**: `bash tests/hooks/test-auto-mode.sh` PASS + Phase 1/TONE-1 회귀 (`test-routing-map-emit.sh` + `test-user-prompt-submit-rules.sh`) PASS + plugin drift 0 + `claude plugin validate` PASS.
6. **need-to-confirm 정리**: `# 자동모드` 항목 strike + commit reference. confirmed.md 이관은 별 cycle (TONE-1 과 함께 묶어).

## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  Marker 파일 + 정적 markdown skill 2 + bash helper + 5 hook 분기 추가 + 신규 test.
  외부 입력 / 비밀정보 / 명령 주입 / 경로 traversal 표면 부재 — marker 는 git
  root relative path 고정. 변경 surface 전부 plugin source + 사용자 git root
  `.rein/`. security_tier: light 적정 (정적 marker + boolean helper + emit 분기
  추가만).

  **block bypass 위험 인지**: stop-session-gate block 우회 mechanism 추가 —
  사용자 명시 결정 (turn 2026-05-27). 안전 장치 = audit log 1줄 append +
  marker 가 명시적 opt-in (touch 필요) 이라 default 동작 무변화. 사용자
  책임 영역.

  사용자 명시 "마무리해" = implicit routing approval. TONE-1 cycle 직후 짧은
  cycle 으로 진행.
