# Background jobs quick rule

## 행동 강령

긴 sync 명령 (pytest, npm test, cargo build, integration E2E 등) 은 `rein job start <name> -- <cmd>` 로 background 처리, foreground 로 세션 붙잡지 마라. 예외: codex 계열 (codex exec, /codex-review, /codex-ask) 은 foreground 전용 + stdin close + 직접 파일 출력 (`< /dev/null > /tmp/file 2>&1`) + `run_in_background: false`. BashOutput 으로 턴 경계 너머 상태 보관 금지.

전체 본문은 `${CLAUDE_PLUGIN_ROOT}/rules/background-jobs.md` 참조.
