#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit)
# 언어중립 hygiene: 하드코딩 시크릿 스캔 + console.log/print 경고
#
# Exit code: 항상 0 (사후 피드백, 차단하지 않음)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
# HK-4: 분할 후 dispatcher 가 처리하던 정책 평가를 각 sub-hook 이 자체 호출.
# shellcheck source=./lib/post-edit-policy-gate.sh
. "$SCRIPT_DIR/lib/post-edit-policy-gate.sh"
post_edit_policy_gate "post-edit-hygiene"

hook_input_load   # 캐시 활성 시 stdin 안 읽음. 없으면 INPUT 만 채워짐.

if [ "${REIN_HOOK_INPUT_CACHE:-0}" = "1" ]; then
  : # FILE_PATH 가 캐시에서 채워짐 — Python resolver 호출 자체를 건너뜀.
else
  # Python resolver (soft fail, silent — hygiene 은 단순 console.log/시크릿 grep 만
  # 수행하는 사후 피드백이므로 resolver 실패 시 조용히 skip). marker 를 생성하지
  # 않는다 — 다음 편집을 BLOCK 할 이유가 없다.
  resolve_python 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit 0
  fi

  FILE_PATH=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_input.file_path --default '' 2>/dev/null)
fi

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# test 디렉토리·테스트 파일은 제외.
# FU-4: `*test_*` 는 `latest_release.py` 같은 일반 소스를 test 파일로 오인했다
# (substring glob). `*/test_*|test_*` 로 좁혀 basename 이 `test_` 로 시작하는
# 파일 (pytest 규약) 만 잡는다 — 경로 컴포넌트 경계를 요구한다.
case "$FILE_PATH" in
  */test/*|*/tests/*|*/__tests__/*|*/test_*|test_*|*.test.*|*.spec.*)
    exit 0
    ;;
esac

# 하드코딩 시크릿 스캔 (언어 무관)
if grep -qEi "(api[_-]?key|secret|password|token|credential)\s*[:=]\s*[\"'][^\"']{8,}[\"']" "$FILE_PATH" 2>/dev/null; then
  echo "WARNING: 하드코딩된 시크릿 패턴이 감지되었습니다: $FILE_PATH" >&2
  echo "환경변수 또는 secret manager 를 사용하세요." >&2
fi

# console.log / print 운영 코드 감지
EXT="${FILE_PATH##*.}"
case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs)
    if grep -qE "console\.(log|debug|info)\(" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: console.log/debug/info 가 감지되었습니다: $FILE_PATH" >&2
      echo "운영 코드에서는 logger 를 사용하세요." >&2
    fi
    ;;
  py)
    if grep -qE "^\s*print\(" "$FILE_PATH" 2>/dev/null; then
      echo "WARNING: print() 가 감지되었습니다: $FILE_PATH" >&2
      echo "운영 코드에서는 logging 모듈을 사용하세요." >&2
    fi
    ;;
esac

exit 0
