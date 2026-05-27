---
name: auto-mode-off
description: 자동모드 marker (.rein/auto-mode.flag) 를 끈다. 자율 cycle 종료 후 호출. marker 제거 이후 모든 rein hook 의 incident advisory 와 session-end block 이 정상 발화로 돌아간다.
---

# Skill: auto-mode-off

자동모드 marker 파일을 제거한다.

## 실행

```bash
rm -f .rein/auto-mode.flag
echo "[auto-mode] OFF"
```

## 후속 정리

자동모드 중 우회된 block / advisory 는 `trail/incidents/auto-mode-bypass.log` 에 누적되어 있다. `trail/incidents/` 의 미해결 draft 가 있으면 `incidents-to-rule` 스킬로 처리 권장 (자동모드 중에는 차단되지 않았지만 누적 자체는 그대로 남아 있다).
