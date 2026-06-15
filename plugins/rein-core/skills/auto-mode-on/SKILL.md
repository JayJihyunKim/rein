---
name: auto-mode-on
description: 자동모드 marker (.rein/auto-mode.flag) 를 켠다. 자율 작업 (`/loop`, 사용자가 명시한 multi-step autonomous cycle) 시작 직전 호출. marker 가 켜져 있는 동안 모든 rein hook 이 incident 관련 advisory 와 incident 종료 차단을 silent 처리하고 (inbox/index 작업증거 종료 차단은 자동모드여도 그대로 발동), block 우회 이력은 trail/incidents/auto-mode-bypass.log 에 누적 기록한다.
---

# Skill: auto-mode-on

자동모드 marker 파일을 생성한다. 이후 incident-to-rule 권고, session-start 미처리 incident 안내, stop-session-gate 의 **incident 관련 block** 이 silent 처리된다.

> **범위 주의**: 자동모드가 끄는 건 incident 관련 블록뿐이다. `stop-session-gate` 의 inbox/index **작업증거(trail 기록 미갱신) 종료 차단** 은 incident 와 무관한 별도 게이트라 자동모드여도 그대로 발동한다. 자율 cycle 중에도 세션 종료 전 trail 기록(inbox/index)은 갱신해야 한다.

## 실행

```bash
mkdir -p .rein && touch .rein/auto-mode.flag
echo "[auto-mode] ON — marker: .rein/auto-mode.flag"
```

## 해제

자동모드 종료 시 `rein:auto-mode-off` 스킬 호출 또는 직접 `rm -f .rein/auto-mode.flag`.

## 주의

- **block bypass 위험**: incident 관련 session-end block 이 silent 되므로 미해결 incident 가 쌓인 상태로 세션이 종료될 수 있다. 자율 cycle 종료 후 반드시 `auto-mode-off` + `incidents-to-rule` 또는 `incidents-to-agent` 로 누적 incident 정리.
- **audit log**: 모든 block 우회는 `trail/incidents/auto-mode-bypass.log` 에 timestamp + reason 1줄 append. 사후 추적 가능.
- marker 위치 = 사용자 git root 의 `.rein/` 안. plugin tarball 에 포함되지 않으며, 사용자 repo 의 `.rein/` 가 gitignored 라면 git 추적도 안 됨.
