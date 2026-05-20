#!/usr/bin/env bash
# SPIKE-1 probe: PreToolUse / PostToolUse 단계 각각의 stdin JSON 에 tool_use_id
# (또는 등가 unique id) 가 포함되는지 + Pre/Post 가 동일 id 를 공유하는지 측정.
#
# 환경 변수:
#   PROBE_PHASE=pre    PreToolUse 위치 dump
#   PROBE_PHASE=post   PostToolUse 위치 dump
#
# stdin 의 전체 JSON 을 tests/fixtures/spike/tool-use-id-${PROBE_PHASE}.jsonl 에 append.
# 본 probe 는 SPIKE-1 측정 후 hooks.json 에서 제거된다 (production 미오염).

set -u

# probe_phase 는 jsonl 파일명 ("tool-use-id-${probe_phase}.jsonl") 에 직접 들어가므로
# path traversal 방지를 위해 허용 값 (pre|post) 만 통과시키고 그 외는 "unknown" 으로 강제.
case "${PROBE_PHASE:-unknown}" in
  pre|post)
    probe_phase="${PROBE_PHASE}"
    ;;
  *)
    probe_phase="unknown"
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

stdin_tmp="$(mktemp -t spike-tool-use-id.XXXXXX)"
trap 'rm -f "$stdin_tmp"' EXIT
cat > "$stdin_tmp" 2>/dev/null || true

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
target_path="${fixture_dir}/tool-use-id-${probe_phase}.jsonl"

# stdin 의 top-level keys + raw payload 를 jsonl 한 줄로 dump.
# id 후보 필드 (tool_use_id / toolUseId / id / event_id) 모두 raw 에 남겨 사후 식별 가능.
python3 - "$timestamp" "$probe_phase" "$target_path" "$stdin_tmp" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

timestamp, phase, target_path, stdin_path = sys.argv[1:5]
raw = Path(stdin_path).read_text(encoding="utf-8", errors="replace")

record = {
    "timestamp": timestamp,
    "phase": phase,
    "stdin_raw": raw,
}

try:
    parsed = json.loads(raw) if raw.strip() else None
    if isinstance(parsed, dict):
        record["top_level_keys"] = sorted(parsed.keys())
        for candidate in ("tool_use_id", "toolUseId", "id", "event_id"):
            if candidate in parsed:
                record[f"id_field_{candidate}"] = parsed[candidate]
except (json.JSONDecodeError, TypeError):
    record["parse_error"] = True

with open(target_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PY

exit 0
