#!/bin/bash
# Hook: PostToolUse(Agent) — feature-builder 완료 후 codex-review 넛지
#
# Phase 7 웨이브 3 ③-d 재조준. 이전엔 trail/dod/ 아래의 구 pending 마커
# 파일의 존재로 "리뷰 대기 상태"를 판정했다 — 그 마커의 유일한 생산자였던
# post-edit-review-gate.sh 가 이 웨이브에서 삭제됐으므로(legacy 리뷰 표식
# write/read 경로 전면 제거, v2 증거 발급이 유일한 기록 경로가 됨) 판정
# 수단도 이관한다.
#
# 새 판정: feature-builder 계열 subagent 가 완료되면 `bin/rein issue-evidence
# code_review --print-digest` 로 지금 이 changeset 의 code_review subject
# digest 를 조회한다(부작용 없음 — 발급을 시도하지 않는다). subject 가 두
# 닫힌 값 센티널(SUBJECT_EMPTY="empty:no-subject" / SUBJECT_UNRESOLVED=
# "unresolved:no-subject", `rein/kernel/changeset.py`) 중 하나가 아니라 실제
# digest 문자열이면 "리뷰할 실제 코드 변경이 있다"는 뜻이므로 Claude 에게
# /codex-review 실행을 지시하는 PostToolUse "block" 피드백을 반환한다.
# 센티널이거나 조회 자체가 실패하면(bin/rein 부재, CLI 비0 종료, 빈 출력)
# 안내를 생략한다 — 이 훅은 "리뷰 완료 여부"를 판정하지 않는다(그건 커밋
# 게이트의 몫이다), 오직 "지금 안내할 가치가 있는 변경이 있는가"만 본다.
#
# 중복 안내 억제 (코드리뷰 Medium 시정, 2026-08-24) — 이 훅은 "리뷰
# evidence 가 이 digest 에 대해 이미 유효하게 발급됐는지"를 판정하지
# 않는다(위 문단 — 그건 커밋 게이트의 몫). 그런데 digest 만 보면 같은
# subagent 완료가 연달아(또는 review PASS 후 추가 변경 없이 다음
# subagent 가 완료) 일어날 때 **같은 digest 에 대해 매번 다시** 안내가
# 나간다 — 사용자가 이미 리뷰를 요청/완료했어도 반복 소음이다. 이를
# `.rein/cache/review-nudge/last-digest`(신규 dedup 캐시)로 완화한다 —
# 같은 digest 에는 한 번만 안내하고, digest 가 바뀌면(새 변경) 다시
# 안내한다. **경로 정정 (2026-08-24, 코드리뷰 round 2 High)**: 최초
# 구현은 이 캐시를 `trail/dod/` 아래(git 이 추적하는 경로)에 뒀는데,
# `git status` 는 기본적으로 untracked 파일도 열거하므로(`worktree_
# changeset()` 의 `--untracked-files=all`) 이 캐시 파일 자체가 그
# changeset digest 계산에 들어가 버렸다(재현: 파일 생성 전/후 digest
# 가 달라짐) — "governance 판정에 전혀 관여하지 않는다"는 원 설계
# 의도가 tests_passed/user_approval 이 읽는 일반 changeset digest 에는
# 실제로 성립하지 않았다(code_review 전용 digest 는 `trail/**` 허용
# 목록으로 원래도 무관했다). `.rein/cache/` 는 저장소 `.gitignore`
# 에 이미 등록돼 있어 `git status` 자체가 이 경로를 열거하지 않는다
# (기본 옵션엔 `--ignored` 가 없다) — 어떤 digest 계산에도 물리적으로
# 들어갈 수 없다. `hooks/stop-session-gate.sh` 등 기존 캐시 파일들과
# 동일한 위치 관례. 세션 시작 시 초기화(session-start-load-trail.sh).
#
# Fail-open, silent: PostToolUse 는 best-effort nudge 이므로 python3 부재·
# bin/rein 부재·CLI 실패·JSON 파싱 실패 시 exit 0 으로 조용히 종료 (pre-hook
# 의 fail-closed 정책과 다름). 잘못된 envelope 는 절대 emit 하지 않는다.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/project-dir.sh
. "$SCRIPT_DIR/lib/project-dir.sh"

PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# self-location — 이 훅은 항상 plugin 트리 hooks/ 아래에 상주한다(scripts/
# 처럼 메인테이너 repo-root 폴백 사본이 존재하지 않는다), 그래서 후보
# 하나면 충분하다 (rein-codex-review.sh 의 `_rein_v2_bin()` 두-후보 패턴과
# 달리 이 파일은 layout 이 하나뿐 — CLAUDE_PLUGIN_ROOT 는 일부러 의존하지
# 않는다, reference_skill_bash_no_plugin_root_env 메모 참조).
BIN_REIN="$SCRIPT_DIR/../bin/rein"

# --- Python resolver (post-hook: silent/fail-open on failure) -----------------
resolve_python 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  exit 0
fi

# --- Read stdin JSON and extract tool_input.subagent_type ---------------------
INPUT=$(cat)

SUBAGENT_TYPE=$(printf '%s' "$INPUT" \
  | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" \
      --field tool_input.subagent_type --default '' 2>/dev/null) || SUBAGENT_TYPE=""

# --- Normalize: strip leading namespace (e.g. "rein:feature-builder" → "feature-builder") ---
# Remove everything up to and including the first colon if present.
SUBAGENT_TYPE_NORM="${SUBAGENT_TYPE#*:}"
# If there was no colon, the above is a no-op; if the whole string was "rein:foo", we get "foo".
# Guard: if original had no colon, #*: strips nothing (bash keeps the original). This is correct.
# But if input is "feature-builder" (no colon), ${var#*:} = "feature-builder" (unchanged). Good.

# --- Allowlist check ----------------------------------------------------------
case "$SUBAGENT_TYPE_NORM" in
  feature-builder|feature-builder-fix|feature-builder-refactor)
    : # in allowlist, continue
    ;;
  *)
    exit 0
    ;;
esac

# --- Guard: bin/rein must exist ------------------------------------------------
[ -f "$BIN_REIN" ] || exit 0

# --- Guard: current code_review subject must be a real digest (not a sentinel,
#     not an empty/failed probe) -----------------------------------------------
# 30초 safety-net timeout — hooks/lib/code-review-gate.sh 의 REIN_CRG_DELEGATE_
# TIMEOUT_S=30 관례와 동일 근거(정상 지연 예산이 아니라 진짜 멈춤에 대한
# 방어). macOS BSD 에는 기본 GNU timeout 이 없을 수 있어 그 경우 감싸지
# 않은 채 호출을 계속한다(동일 저장소 전례와 동일 폴백).
DIGEST=""
DIGEST_RC=0
if command -v timeout >/dev/null 2>&1; then
  DIGEST=$(REIN_PROJECT_ROOT="$PROJECT_DIR" timeout 30 \
    "${PYTHON_RUNNER[@]}" "$BIN_REIN" issue-evidence code_review --print-digest 2>/dev/null) \
    || DIGEST_RC=$?
else
  DIGEST=$(REIN_PROJECT_ROOT="$PROJECT_DIR" \
    "${PYTHON_RUNNER[@]}" "$BIN_REIN" issue-evidence code_review --print-digest 2>/dev/null) \
    || DIGEST_RC=$?
fi

if [ "$DIGEST_RC" -ne 0 ] || [ -z "$DIGEST" ]; then
  exit 0
fi

# 닫힌 값 2상태 센티널 (rein/kernel/changeset.py SUBJECT_EMPTY/
# SUBJECT_UNRESOLVED) — 리뷰할 실제 대상이 없거나 판정 불능. 두 경우 모두
# 안내를 낼 근거가 없다(침묵 = advisory 훅의 정상 동작).
case "$DIGEST" in
  empty:no-subject|unresolved:no-subject)
    exit 0
    ;;
esac

# --- Dedup: same digest already nudged → silent (see header comment) ----------
# .rein/cache/ — gitignored, so this file can never enter a worktree_changeset()
# digest computation (see header comment for the round-2 code-review fix).
NUDGE_CACHE="$PROJECT_DIR/.rein/cache/review-nudge/last-digest"
if [ -f "$NUDGE_CACHE" ]; then
  PREV_DIGEST=$(cat "$NUDGE_CACHE" 2>/dev/null) || PREV_DIGEST=""
  if [ "$PREV_DIGEST" = "$DIGEST" ]; then
    exit 0
  fi
fi
mkdir -p "$(dirname "$NUDGE_CACHE")" 2>/dev/null
(umask 077; printf '%s' "$DIGEST" > "$NUDGE_CACHE") 2>/dev/null
chmod 600 "$NUDGE_CACHE" 2>/dev/null

# --- Emit PostToolUse block feedback via python3 json.dumps -------------------
# Build JSON safely — never hand-rolled string concat.
"${PYTHON_RUNNER[@]}" - <<'PYEOF'
import json
import sys

reason = (
    "A feature-builder-family subagent just finished, and the source-code "
    "changes now need a code review before they can be committed. "
    "Run `/codex-review` on the changed files next. "
    "Do not commit or make further edits until code-review evidence for "
    "this exact changeset has been issued (a PASS verdict, bound to the "
    "current changeset digest). "
    "When you relay this state to the user in chat, translate it into "
    "plain language (\"changes are waiting for code review\" / "
    "\"code-review evidence has been recorded for this changeset\") and "
    "avoid raw internal identifiers like `digest` or `issue-evidence` — "
    "see `plugins/rein-core/rules/response-tone.md`."
)

envelope = {
    "decision": "block",
    "reason": reason,
}

sys.stdout.write(json.dumps(envelope))
sys.stdout.write("\n")
PYEOF
rc=$?
if [ "$rc" -ne 0 ]; then
  # Python failed to emit — fail open, no malformed output.
  exit 0
fi

exit 0
