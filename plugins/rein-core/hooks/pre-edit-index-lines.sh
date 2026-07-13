#!/bin/bash
# Hook: PreToolUse(Edit|Write|MultiEdit) sub-hook — trail/index.md 줄 수
# 작성 시점 강제 (2026-07-13, 사용자 요청).
#
# 세션 종료 게이트(stop-session-gate.sh)가 사후 검사하던 5~25줄 규칙을
# 편집 시점으로 앞당긴다: 이 편집이 적용된 "결과물"의 줄 수를 시뮬레이션해
# 한도 위반이면 exit 2 로 거부하고 압축 안내를 낸다. "초과 작성 → 종료 시
# 적발 → 다시 줄이기" 왕복을 제거하는 사전검사.
#
# 설계 원칙:
#   - 대상은 프로젝트 루트 trail/index.md 단 하나. 다른 파일 무간섭.
#   - 위반 탈출 허용: 이미 한도 밖인 파일을 "더 나아지게" (초과분 축소)
#     하는 편집은 결과가 여전히 한도 밖이어도 통과시킨다 — 아니면 초과
#     상태에서 단계적 압축이 불가능해 교착한다.
#   - 도구/파싱 오류는 fail-open (exit 0): 이 게이트가 죽어도 세션 종료
#     게이트가 backstop 으로 같은 규칙을 재검사한다 (이중 방어 — 종료
#     게이트는 제거하지 않는다). 정책 위반만 차단한다.
#   - Bash 로 파일을 직접 조작하는 우회는 이 훅이 못 본다 — 그 경로 역시
#     종료 게이트 몫.
#   - 수용 한계 (codex review 2026-07-13 R3/R4): 문자열 fast-path (입력에
#     'index.md' 미포함 시 즉시 통과) 는 index.md 를 가리키는 symlink 별칭
#     경로를 놓친다. 위협 모델(정직한 에이전트 규율, 2026-06-12 결정 —
#     적대적 우회 하드닝 보류)과 편집 hot-path 성능(전 편집 python 기동
#     회피) 근거로 수용 — 별칭 편집은 즉시 차단 대신 종료 게이트가 실파일
#     재검사로 적발한다.
set -u

MIN_LINES=5
MAX_LINES=25

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh" 2>/dev/null || exit 0
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

INPUT=$(cat 2>/dev/null) || exit 0

# 빠른 탈출: 입력에 index.md 언급 자체가 없으면 python 기동 없이 통과.
case "$INPUT" in
  *index.md*) : ;;
  *) exit 0 ;;
esac

# python resolver (fail-open — dod-gate 와 달리 이 게이트는 종료 게이트
# backstop 이 있으므로 python 부재 시 조용히 비활성).
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh" 2>/dev/null || exit 0
  resolve_python >/dev/null 2>&1 || exit 0
else
  command -v python3 >/dev/null 2>&1 || exit 0
  PYTHON_RUNNER=(python3)
fi

# 결과 줄 수 시뮬레이션. stdout 한 줄:
#   SKIP                — 대상 아님 / 시뮬레이션 불가 (fail-open)
#   LINES <before> <after>
# 프로그램이 stdin(heredoc)으로 들어가므로 hook 입력 JSON 은 env 로 전달한다
# (stdin 이중 사용 불가 — heredoc 이 pipe 를 덮는다).
RESULT=$(REIN_IDX_HOOK_INPUT="$INPUT" "${PYTHON_RUNNER[@]}" - "$PROJECT_DIR" <<'PY' 2>/dev/null
import json
import os
import sys

def out(s):
    print(s)
    sys.exit(0)

try:
    data = json.loads(os.environ.get("REIN_IDX_HOOK_INPUT", ""))
except Exception:
    out("SKIP")

project_dir = sys.argv[1]
tool = data.get("tool_name") or ""
ti = data.get("tool_input") or {}

target = os.path.realpath(os.path.join(project_dir, "trail", "index.md"))

# 상대경로는 hook 프로세스 CWD 가 아니라 PROJECT_DIR 기준으로 해석한다 —
# CWD 기준이면 도구 입력이 'trail/index.md' 일 때 대상인데도 SKIP 된다
# (codex review 2026-07-13 R1 Medium).
def is_target(path):
    if not path:
        return False
    if not os.path.isabs(path):
        path = os.path.join(project_dir, path)
    return os.path.realpath(path) == target

# 줄 수는 stop-session-gate.sh 의 `wc -l` 과 동일하게 "개행 문자 수" 로 센다
# — 계산이 다르면 "편집 게이트 통과 → 종료 게이트 차단" 왕복이 잔존한다.
def count_lines(s):
    return s.count("\n")

try:
    with open(target, encoding="utf-8", errors="replace") as f:
        current = f.read()
except OSError:
    current = ""
before = count_lines(current)

if tool == "Write":
    if not is_target(ti.get("file_path")):
        out("SKIP")
    result = ti.get("content")
    if result is None:
        out("SKIP")
elif tool in ("Edit", "MultiEdit"):
    # MultiEdit 실계약은 tool_input.edits[*].file_path (edit 별 경로 — 여러
    # 파일 혼합 가능, post-edit-review-gate.sh 의 수집 순서와 동일). per-edit
    # 경로가 없으면 top-level file_path 로 fallback (Edit 단건 / 변형 스키마).
    # (codex review 2026-07-13 R2 High)
    raw_edits = ti.get("edits")
    if raw_edits is None:
        raw_edits = [{
            "file_path": ti.get("file_path"),
            "old_string": ti.get("old_string"),
            "new_string": ti.get("new_string"),
            "replace_all": ti.get("replace_all", False),
        }]
    top_path = ti.get("file_path")
    matched = [e for e in raw_edits
               if isinstance(e, dict) and is_target(e.get("file_path") or top_path)]
    if not matched:
        out("SKIP")
    result = current
    for e in matched:
        old = e.get("old_string")
        new = e.get("new_string")
        if not old or new is None or old not in result:
            # 도구 자체가 실패할 편집 — 시뮬레이션 포기 (fail-open).
            out("SKIP")
        if e.get("replace_all"):
            result = result.replace(old, new)
        else:
            result = result.replace(old, new, 1)
else:
    out("SKIP")

out(f"LINES {before} {count_lines(result)}")
PY
) || exit 0

case "$RESULT" in
  LINES\ *) : ;;
  *) exit 0 ;;
esac

BEFORE=$(printf '%s' "$RESULT" | cut -d' ' -f2)
AFTER=$(printf '%s' "$RESULT" | cut -d' ' -f3)
case "$BEFORE$AFTER" in *[!0-9]*) exit 0 ;; esac

# 한도 안 → 통과.
if [ "$AFTER" -ge "$MIN_LINES" ] && [ "$AFTER" -le "$MAX_LINES" ]; then
  exit 0
fi

# 위반 탈출 허용: 이미 한도 밖이던 파일이 편집으로 한도에 "가까워지면" 통과.
if [ "$BEFORE" -gt "$MAX_LINES" ] && [ "$AFTER" -lt "$BEFORE" ]; then
  exit 0
fi
if [ "$BEFORE" -lt "$MIN_LINES" ] && [ "$BEFORE" -ge 1 ] && [ "$AFTER" -gt "$BEFORE" ] && [ "$AFTER" -lt "$MIN_LINES" ]; then
  exit 0
fi

echo "[rein] 이 편집을 적용하면 trail/index.md 가 ${AFTER}줄이 됩니다 — 허용 범위는 ${MIN_LINES}~${MAX_LINES}줄입니다." >&2
if [ "$AFTER" -gt "$MAX_LINES" ]; then
  echo "  작성 전에 줄이세요: 오래된 '이전 릴리스/이전 완료' 항목을 한 줄로 합치거나 상세를 trail/inbox/ 로 이관한 뒤, ${MAX_LINES}줄 이내 내용으로 다시 편집하세요." >&2
else
  echo "  index.md 는 최소 ${MIN_LINES}줄의 상태 요약을 유지해야 합니다 — 현재 상태/직전 완료/주의사항을 채워 주세요." >&2
fi
echo "  (이 검사는 세션 종료 게이트의 5~25줄 규칙을 편집 시점으로 앞당긴 것입니다.)" >&2
exit 2
