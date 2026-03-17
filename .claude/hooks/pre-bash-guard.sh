#!/bin/bash
# Hook: PreToolUse(Bash) - 위험 명령어 패턴 감지 및 차단
#
# settings.json 설정:
# "hooks": { "PreToolUse": [{ "matcher": "Bash",
#   "hooks": [{"type": "command", "command": ".claude/hooks/pre-bash-guard.sh"}] }] }
#
# Exit code: 0=허용, 1=차단, 2=사용자확인

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('command', ''))" 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# 즉시 차단: 파이프로 쉘 스크립트 실행
if echo "$COMMAND" | grep -qE "\| *(bash|sh)"; then
  echo "BLOCKED: Piping to shell is not allowed" >&2
  exit 1
fi

# 확인 요청: 파괴적 git 명령어
if echo "$COMMAND" | grep -qiE "git (reset --hard|rebase|push --force)"; then
  echo "CONFIRM: Destructive git command detected. Please confirm." >&2
  exit 2
fi

exit 0
