#!/bin/bash
# Hook: TaskCompleted - 작업 완료 시 self-review 체크리스트 출력
#
# settings.json 설정:
# "hooks": { "TaskCompleted": [{ "hooks": [{"type": "command",
#   "command": ".claude/hooks/task-completed-incident.sh"}] }] }

cat << 'MSG'
{
  "decision": "proceed",
  "reason": "Task complete. Please verify: (1) Self-review done per AGENTS.md section 5 (2) Any missing rules drafted in trail/incidents/ (3) trail/index.md updated"
}
MSG

exit 0
