#!/bin/bash
# hooks/lib/source-path-classify.sh
#
# Single source of truth for "is this edited path a source file that the DoD
# gate cares about" (GMF-3 four-stage classification + the runtime-state /
# trail / .gitkeep path exemptions that sit in front of it).
#
# Extracted from pre-edit-dod-gate.sh (previously inlined at the top of that
# hook, ~lines 233-335) so the same classification can be reused by hooks
# that need to agree with the DoD gate on "is this a source edit" WITHOUT
# depending on pre-edit-dod-gate.sh's process lifetime — notably
# post-edit-src-touch-marker.sh and pre-edit-coverage-gate.sh, both added to
# take over marker-production duties pre-edit-dod-gate.sh used to perform
# inline (see those hooks' headers for why). A second, hand-copied case
# statement would silently drift from this one over time (e.g. a new source
# extension added to only one copy) — a single shared function makes drift
# structurally impossible instead of relying on discipline.
#
# pre-edit-dod-gate.sh itself is refactored to call this function too (in
# place of its old inline block) — this is a pure move, not a duplication:
# the case-statement bodies below are copied verbatim from the original
# inline code, unchanged.
#
# Usage:
#   . "$SCRIPT_DIR/lib/source-path-classify.sh"
#   rein_classify_source_path "$FILE_PATH"   # $FILE_PATH already normalized
#   case "$REIN_SRC_CLASS" in
#     exempt)    exit 0 ;;                   # runtime-state/trail/.gitkeep
#     source)    ... ;;                      # $EXT_SOURCE_HIT tells you
#                                             # whether the ext-only tier (4)
#                                             # is what classified it (GMF-3
#                                             # notice trigger)
#     nonsource) exit 0 ;;
#   esac
#
# Output (globals set by the call, not `local` — callers read them directly,
# matching how pre-edit-dod-gate.sh used the values before extraction):
#   REIN_SRC_CLASS   "exempt" | "source" | "nonsource"
#   IS_SOURCE        "true" | "false"  (kept for the exact pre-existing
#                     variable name pre-edit-dod-gate.sh's downstream code
#                     already reads; redundant with REIN_SRC_CLASS=source)
#   EXT_SOURCE_HIT    "true" | "false" — true only when tier (4) (extension
#                     whitelist, not directory whitelist) is what classified
#                     the path as source. Meaningless when CLASS != source.
#
# The function always returns 0; it never calls `exit` (unlike the original
# inline block, which called `exit 0` directly for the exempt cases — moving
# an `exit` into a library function that might be sourced by more than one
# caller would silently terminate whichever hook happens to call it, which is
# not always the right thing to do — see pre-edit-coverage-gate.sh, which
# treats "exempt" the same as "nonsource" itself rather than trusting a
# library-owned `exit`). Callers own the exit decision.

if [ -n "${__REIN_SOURCE_PATH_CLASSIFY_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_SOURCE_PATH_CLASSIFY_LOADED=1

rein_classify_source_path() {
  local _p="$1"
  IS_SOURCE=false
  NONSOURCE_DECIDED=false
  EXT_SOURCE_HIT=false
  REIN_SRC_CLASS="nonsource"

  # --- 경로 기반 면제 (runtime state + operational data + git infra only) ---
  # verbatim from pre-edit-dod-gate.sh's original inline block.
  case "$_p" in
    # .gitignore 는 **어느 디렉토리에 있든** 항상 source (main-포함, tracking 정책
    # 변경 가능). Runtime-state 경로 (.claude/cache/) 에 있어도 예외 아님. 이
    # 최상단 match 는 아래 exempt 케이스가 .gitignore 를 가로채지 못하도록 보호한다.
    */.gitignore|.gitignore)
      :  # fall through to IS_SOURCE classification below
      ;;
    # Runtime state — hook/validator 가 자동 기록. Edit/Write 로 올 일 거의 없지만 안전용.
    */.claude/cache/*|*/.claude/.rein-state/*)
      REIN_SRC_CLASS="exempt"
      return 0
      ;;
    # Trail 운영 데이터 — DoD 파일 자체가 여기 살고, inbox/daily/weekly/incidents/decisions 포함.
    */trail/*)
      REIN_SRC_CLASS="exempt"
      return 0
      ;;
    # Git 인프라 파일 — .gitkeep 만 면제 (디렉토리 placeholder).
    *.gitkeep)
      REIN_SRC_CLASS="exempt"
      return 0
      ;;
  esac

  # --- 소스 판정 gate (GMF-3: 디렉토리 화이트리스트 + 소스 확장자 화이트리스트) ---
  # 판정 순서(우선순위) — tightening-only 를 보장하도록 고정:
  #   (1) generated/vendored 제외 — source-dir *앞*
  #   (2) 기존 디렉토리(source-dir) 화이트리스트 — 변경 없음 (불완화)
  #   (3) doc/data/lock 확장자 제외 — source-dir *뒤*
  #   (4) 소스 확장자 화이트리스트 (additive)

  # (1) generated/vendored 제외 — source-dir 판정보다 앞. 매칭 시 비소스 확정.
  case "$_p" in
    */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.next/*|*/generated/*|*/__generated__/*|*/__pycache__/*)
      NONSOURCE_DECIDED=true ;;
    *.min.js|*.generated.*|*_pb2.py|*.pb.go)
      NONSOURCE_DECIDED=true ;;
  esac

  # (2) 기존 디렉토리 화이트리스트 — generated/vendored 가 아닐 때만 평가 (불완화).
  if [ "$NONSOURCE_DECIDED" != true ]; then
    case "$_p" in
      # 일반 소스 경로 (사용자 프로젝트 코드). `*/hooks/*` 가 `.claude/hooks/*` 도 잡음.
      */src/*|*/app/*|*/services/*|*/apps/*|*/lib/*|*/components/*|*/hooks/*|*/store/*|*/types/*|*/models/*|*/schemas/*|*/repositories/*|*/routers/*|*/alembic/*|*/scripts/*|scripts/*)
        IS_SOURCE=true
        ;;
      # rein-internal source — branch-strategy.md 의 main 포함 경로.
      */.claude/rules/*|*/.claude/skills/*|*/.claude/agents/*|*/.claude/workflows/*)
        IS_SOURCE=true
        ;;
      # rein-dev 메인테이너 환경에서만 존재하는 paths.
      */.claude/CLAUDE.md|*/.claude/orchestrator.md|*/.claude/settings.json)
        IS_SOURCE=true
        ;;
      # AGENTS.md at any depth (repo root 또는 subdir 모두).
      */AGENTS.md|AGENTS.md)
        IS_SOURCE=true
        ;;
      # .gitignore — main 포함. tracking 정책 변경 가능.
      */.gitignore|.gitignore)
        IS_SOURCE=true
        ;;
    esac
  fi

  # (3) doc/data/lock 확장자 제외 — source-dir *뒤*.
  if [ "$IS_SOURCE" != true ] && [ "$NONSOURCE_DECIDED" != true ]; then
    case "$_p" in
      *.md|*.txt|*.rst|*.adoc) NONSOURCE_DECIDED=true ;;
      *.json|*.yaml|*.yml|*.toml|*.ini|*.csv|*.xml|*.env) NONSOURCE_DECIDED=true ;;
      *.lock|*.sum) NONSOURCE_DECIDED=true ;;  # Cargo.lock / poetry.lock / go.sum / *-lock.yaml(=*.yaml)
    esac
  fi

  # (4) 소스 확장자 화이트리스트 (additive) — 위 어느 단계로도 결정 안 된 파일.
  if [ "$IS_SOURCE" != true ] && [ "$NONSOURCE_DECIDED" != true ]; then
    case "$_p" in
      *.go|*.rs|*.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.java|*.kt|*.kts|*.scala|*.c|*.h|*.cpp|*.cc|*.cxx|*.hpp|*.hh|*.rb|*.php|*.sh|*.bash|*.swift|*.m|*.mm|*.cs|*.ex|*.exs|*.erl|*.hs|*.clj|*.cljs|*.lua|*.dart|*.pl|*.pm|*.r|*.R|*.jl|*.zig|*.ml|*.mli|*.fs|*.fsx|*.groovy)
        IS_SOURCE=true; EXT_SOURCE_HIT=true ;;
      Dockerfile|*/Dockerfile|Makefile|*/Makefile|*.mk)
        IS_SOURCE=true; EXT_SOURCE_HIT=true ;;
    esac
  fi

  if [ "$IS_SOURCE" = true ]; then
    REIN_SRC_CLASS="source"
  else
    REIN_SRC_CLASS="nonsource"
  fi
  return 0
}
