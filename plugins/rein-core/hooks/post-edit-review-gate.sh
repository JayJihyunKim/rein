#!/bin/bash
# Hook: PostToolUse(Edit/Write/MultiEdit) - 소스 코드 편집 시 리뷰 대기 상태 추적
#
# 소스 코드 파일 편집 시 trail/dod/.review-pending 생성
# trail/, docs/, .md 파일은 제외 (규칙/문서 파일)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"

PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"
REVIEW_PENDING="$PROJECT_DIR/trail/dod/.review-pending"

INPUT=$(cat)

# Python resolver — post-hook silent on failure.
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit 0
fi

# 모든 편집 파일 경로 추출 (MultiEdit는 여러 파일 가능)
# 수집 순서 (기존 semantics 와 동일):
#   1) tool_input.file_path          (Edit/Write)
#   2) tool_input.edits[*].file_path (MultiEdit 입력)
#   3) tool_result.edits[*].file_path(MultiEdit 결과)
#   4) tool_result.file_path         (fallback — 1~3 에서 아무것도 못 찾은 경우만)
# extract-hook-json.py 는 dedup/빈 문자열 필터링을 하지 않으므로 shell 에서 후처리.
FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
  --field tool_input.file_path \
  --array-of tool_input.edits --subfield file_path \
  --array-of tool_result.edits --subfield file_path \
  --default '' 2>/dev/null | awk 'NF && !seen[$0]++')

# fallback: tool_result.file_path 는 1~3 에서 경로를 찾지 못했을 때만 사용.
# 이는 Claude Code hook schema 기존 semantics 를 보존하기 위함 (Codex final review A4).
if [ -z "$FILE_PATHS" ]; then
  FILE_PATHS=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
    --field tool_result.file_path --default '' 2>/dev/null | awk 'NF && !seen[$0]++')
fi

if [ -z "$FILE_PATHS" ]; then
  exit 0
fi

SOURCE_EXT_PATTERN='\.(ts|tsx|js|jsx|py|sh|yml|yaml|json|toml|css|scss|html|sql|go|rs|java|kt|rb)$'
FOUND_SOURCE=false

while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue

  # 경로 정규화 — `./trail/...`, `//trail/...`, 비정규 절대경로 edge case
  # 보호 (need-to-confirm.md 그룹 8 item 2). python resolver 부재/실패 시
  # 원본 사용 (post-hook 은 best-effort, silent fail 정책).
  FILE_PATH_NORM=$("${PYTHON_RUNNER[@]}" -c \
    'import os,sys; print(os.path.normpath(sys.argv[1]))' \
    "$FILE_PATH" 2>/dev/null) || FILE_PATH_NORM=""
  [ -z "$FILE_PATH_NORM" ] && FILE_PATH_NORM="$FILE_PATH"

  # 제외 경로: trail/, docs/, *.md 파일 (정규화된 경로로 매치)
  case "$FILE_PATH_NORM" in
    trail/*|*/trail/*|docs/*|*/docs/*|*.md)
      continue
      ;;
  esac

  # 프로젝트 외부 경로는 source 가 아니다. subagent 가 codex/security review 중
  # mktemp -d 로 만든 임시 fixture (/tmp/*, /var/folders/* — macOS mktemp 기본
  # 위치) 에 .sh 등을 쓸 때 .review-pending 이 잘못 재생성되어 stamp 비교가
  # 깨지는 회귀 (incident pre-bash-guard-2fbe7edae5a10b1f). PROJECT_DIR 시작
  # 검사로 외부 경로 면제. 상대 경로는 PROJECT_DIR 내부로 간주 (cwd-based).
  case "$FILE_PATH_NORM" in
    /*)
      case "$FILE_PATH_NORM" in
        "$PROJECT_DIR"/*) ;;  # 프로젝트 내부 절대경로 → fall through
        *) continue ;;        # 그 외 절대경로 → 면제 (외부)
      esac
      ;;
  esac

  # 소스 코드 확장자 확인
  if echo "$FILE_PATH_NORM" | grep -qE "$SOURCE_EXT_PATTERN"; then
    FOUND_SOURCE=true
    break
  fi

  # Dockerfile (확장자 없음) 처리
  BASENAME=$(basename "$FILE_PATH_NORM")
  if [ "$BASENAME" = "Dockerfile" ] || echo "$BASENAME" | grep -qE "^Dockerfile\."; then
    FOUND_SOURCE=true
    break
  fi
done <<< "$FILE_PATHS"

if [ "$FOUND_SOURCE" = false ]; then
  exit 0
fi

# .review-pending 생성 (이미 있으면 타임스탬프만 갱신)
mkdir -p "$(dirname "$REVIEW_PENDING")"
touch "$REVIEW_PENDING"

exit 0
