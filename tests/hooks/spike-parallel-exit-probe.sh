#!/usr/bin/env bash
# SPIKE-1 probe: 동일 matcher 의 2 entry 가 각각 다른 exit code/decision 을
# 반환할 때 Claude Code 의 hook 결과 병합 의미를 측정한다.
#
# 환경 변수:
#   PROBE_ROLE=allow   exit 0 + permissionDecision allow JSON dump
#   PROBE_ROLE=deny    exit 2 + permissionDecision deny  JSON dump
#
# stdin 으로 들어온 PostToolUse 입력 JSON 을 tests/fixtures/spike/parallel-exit-${PROBE_ROLE}.jsonl 에 append.
# PROJECT_DIR 결정은 CLAUDE_PROJECT_DIR > git toplevel > 호출시 cwd 순.
#
# 본 probe 는 SPIKE-1 측정 후 hooks.json 에서 제거된다 (production 미오염).

set -u

# probe_role 은 jsonl 파일명 ("parallel-exit-${probe_role}.jsonl") 에 직접 들어가므로
# path traversal 방지를 위해 허용 값 (allow|deny) 만 통과시키고 그 외는 "unknown" 으로 강제.
case "${PROBE_ROLE:-allow}" in
  allow|deny)
    probe_role="${PROBE_ROLE:-allow}"
    ;;
  *)
    probe_role="unknown"
    ;;
esac

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  project_dir="$CLAUDE_PROJECT_DIR"
elif project_dir_candidate=$(git rev-parse --show-toplevel 2>/dev/null); then
  project_dir="$project_dir_candidate"
else
  project_dir="$(pwd)"
fi

fixture_dir="${project_dir}/tests/fixtures/spike"
mkdir -p "$fixture_dir" 2>/dev/null || true

stdin_payload="$(cat 2>/dev/null || true)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# raw stdin + role + timestamp 를 한 줄 JSON 으로 dump (jq 미의존 — 단순 wrap)
{
  printf '{"timestamp":"%s","probe_role":"%s","stdin_raw":' "$timestamp" "$probe_role"
  if [ -z "$stdin_payload" ]; then
    printf '""'
  else
    printf '%s' "$stdin_payload" | python3 -c 'import sys,json; sys.stdout.write(json.dumps(sys.stdin.read()))'
  fi
  printf '}\n'
} >> "${fixture_dir}/parallel-exit-${probe_role}.jsonl" 2>/dev/null || true

case "$probe_role" in
  deny)
    cat <<'EOF'
{"continue": true, "decision": "block", "reason": "SPIKE-1 probe: intentional deny to measure entry merge semantics", "hookSpecificOutput": {"hookEventName": "PostToolUse", "permissionDecision": "deny", "permissionDecisionReason": "SPIKE-1 probe deny entry"}}
EOF
    exit 2
    ;;
  *)
    cat <<'EOF'
{"continue": true, "decision": "approve", "hookSpecificOutput": {"hookEventName": "PostToolUse", "permissionDecision": "allow"}}
EOF
    exit 0
    ;;
esac
