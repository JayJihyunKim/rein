#!/usr/bin/env bash
# Plugin PreToolUse(Bash) — single-entry dispatcher.
#
# Cycle X2 (영역 A, plan §4.1). Replaces the multi-entry Bash matcher in
# hooks.json (bootstrap-gate + safety-guard always + ~30 `if`-gated entries for
# test-commit-gate + bash-rules) with a single hook invocation. The dispatcher
# inlines the always-run check ordering, classifies the command via
# lib/bash-classifier.sh, then invokes the conditional helpers as needed.
#
# Why this collapse exists:
#   - hooks.json shrinks from ~36 Bash matcher entries to 1, removing the
#     "forgot to add pattern X to both `if` lists" foot-gun
#   - INPUT JSON is parsed exactly once per Bash invocation in the dispatcher,
#     and re-fed to downstream helpers via stdin so they see the same envelope
#   - Classification is centralized in lib/bash-classifier.sh — single source
#     of truth that both the dispatcher and adversarial tests share
#
# Why this is NOT (yet) a full inline:
#   - The downstream helper bodies (bootstrap, safety, test-commit, rules)
#     each pull in several `lib/*` sources and have their own policy-toggle
#     logic. Inlining them would require a larger refactor of those libs into
#     pure functions — deferred to a follow-up cycle (X2.5 / X3 bundle).
#   - This cycle prioritizes the hooks.json simplification + classification
#     SSOT; latency measurement (SPIKE-1 style) is a separate cycle.
#
# Exit codes propagate from the first failing downstream helper. Order:
#   1. pre-tool-use-bash-bootstrap-gate.sh  (always)
#   2. pre-bash-safety-guard.sh             (always)
#   3. pre-bash-commit-discipline-gate.sh → pre-bash-commit-review-gate.sh
#      (if classified as test/commit — Phase 7 웨이브 3 ③-c 교대, 아래 Step 3
#      의 자체 헤더 참조. 구 단일 pre-bash-test-commit-gate.sh(파일 자체도
#      ③-c 커밋에서 삭제 완료)는 더 이상 이 매처의 자식이 아니다)
#   4. pre-tool-use-bash-rules.sh           (if classified as test/build)
#
# Plugin runtime guard — outside the plugin runtime (ad-hoc shell invocation),
# pass through silently. Same posture as the individual gates.
[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Read INPUT once, feed downstream via stdin ---
#
# Each downstream helper independently re-reads stdin to extract tool_input.
# We hold the captured INPUT in this dispatcher and pipe it back so every
# helper sees the same envelope. The captured INPUT also feeds the classifier
# below, so a single python3 invocation does the JSON extraction.
#
# Fail-closed posture (Cycle X2, codex review Rounds 1-3): if the classifier
# or its preconditions are unavailable, CLASS_NEEDS_TC defaults to 1 so the
# test-commit gate still fires conservatively. Only the bash-rules advisory
# helper is allowed to silently no-op when absent. See invoke_hook_required
# vs invoke_hook_advisory below for the missing-helper policy.
INPUT=$(cat)

# --- Extract command for classification ---
#
# COMMAND_EXTRACTED tracks whether tool_input.command was *positively*
# extracted from INPUT. python3 missing, extractor missing, or any rc != 0
# leaves COMMAND_EXTRACTED=0, which keeps the conservative default
# CLASS_NEEDS_TC=1 (no classifier call). An EMPTY-string command on rc=0 is
# treated as successfully extracted and intentionally empty — classifier
# correctly classifies it as no-gates-needed.
#
# Codex review Round 2 Medium 2.2: previously, extraction failure produced
# COMMAND="" and the classifier reset CLASS_NEEDS_TC=0, silently bypassing
# the commit gate on malformed envelopes. Separating extraction success
# from "command is empty" closes that hole.
COMMAND=""
COMMAND_EXTRACTED=0
if [ -f "$SCRIPT_DIR/lib/python-runner.sh" ]; then
  # shellcheck source=./lib/python-runner.sh
  . "$SCRIPT_DIR/lib/python-runner.sh"
  if resolve_python 2>/dev/null; then
    # No --default flag: an absent tool_input.command field MUST surface as a
    # non-zero rc (extractor returns 21 for missing field) so the
    # COMMAND_EXTRACTED tracking can distinguish "field absent" from "field is
    # an explicitly empty string". With --default '' the extractor would
    # collapse both into rc 0 + empty COMMAND, which the classifier resets to
    # CLASS_NEEDS_TC=0 — the commit-gate bypass Round 3 Medium 3.1 caught.
    if COMMAND=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" \
        "$SCRIPT_DIR/lib/extract-hook-json.py" \
        --field tool_input.command 2>/dev/null); then
      COMMAND_EXTRACTED=1
    fi
  fi
fi

# --- Source classifier (fail-closed when source rc != 0) ---
#
# Defaults: CLASS_NEEDS_TC=1 (conservative), CLASS_NEEDS_BR=0 (advisory).
#
# The classifier is invoked only when ALL three preconditions hold:
#   (1) the lib file exists
#   (2) sourcing it succeeded (rc=0) — partial source failure (Round 2
#       Medium 2.1) is detected via the explicit rc capture below, not via
#       declare -F alone which would still pass for a partial load
#   (3) classify_bash_command function ended up defined after source
#   (4) the tool_input.command extraction above succeeded
# If any precondition fails, CLASS_NEEDS_TC stays at 1 (conservative) and
# CLASS_NEEDS_BR stays at 0 (advisory off), preserving the commit gate.
CLASS_NEEDS_TC=1
CLASS_NEEDS_BR=0
SOURCE_OK=0
if [ -f "$SCRIPT_DIR/lib/bash-classifier.sh" ]; then
  # shellcheck source=./lib/bash-classifier.sh
  if . "$SCRIPT_DIR/lib/bash-classifier.sh" 2>/dev/null; then
    SOURCE_OK=1
  fi
fi

# --- canonical git subcommand token model SSOT (GMF-1) ---
#
# Shared with the classifier + the gate-internal command_invokes. The classifier
# may have already sourced it (pure definition — re-source is idempotent); we
# re-source here so the _SM_CLASS commit detection below uses the SAME matcher
# even if the classifier source above failed. fail-closed (codex R2 HIGH):
# _GIT_MODEL_OK=0 → a `commit` token conservatively classifies as commit.
_GIT_MODEL_OK=0
if [ -f "$SCRIPT_DIR/lib/git-subcommand-model.sh" ] && . "$SCRIPT_DIR/lib/git-subcommand-model.sh" 2>/dev/null \
   && declare -F git_clause_invokes >/dev/null 2>&1; then
  _GIT_MODEL_OK=1
fi
if [ "$SOURCE_OK" = "1" ] \
   && declare -F classify_bash_command >/dev/null 2>&1 \
   && [ "$COMMAND_EXTRACTED" = "1" ]; then
  classify_bash_command "$COMMAND"
fi

# --- Cycle X4.C.2: state machine drain (영역 C) ---
#
# Fail-soft for state machine — drain errors do NOT change dispatcher exit code.
# The state.json + journal layer is advisory: if absent or broken, the legacy
# hook chain runs unchanged (design memo Scope ID 4: "state-json-absence-...
# zero-test-regression"). Drain is invoked BEFORE the downstream gates so that
# they see a fresh state.json if they ever start to read it (X4.C.3).
#
# Pass current Bash class so drain_state applies the about-to-execute
# transition (design memo §4.3 step 6 — codex Round 1 X4.C.2 HIGH fix).
if [ -f "$SCRIPT_DIR/lib/state-machine.sh" ]; then
  # shellcheck source=./lib/state-machine.sh
  if . "$SCRIPT_DIR/lib/state-machine.sh" 2>/dev/null \
     && declare -F drain_state >/dev/null 2>&1; then
    # Independent classification for state machine (codex Round 2 HIGH fix —
    # bash-classifier.sh misses `git  commit` repeated-whitespace; relying on
    # CLASS_NEEDS_TC would inherit that defect).
    _SM_CLASS=""
    if [ -n "$COMMAND" ]; then
      # Commit detection via canonical SSOT matcher (GMF-1) — skips git global
      # options + multi-space + shell-token boundary, the forms the old
      # `git[[:space:]]+commit\b` grep missed (`git -C . commit`, `git  commit`).
      if [ "$_GIT_MODEL_OK" = 1 ] && git_clause_invokes "$GIT_COMMIT_ERE" "$COMMAND"; then
        _SM_CLASS="commit"
      elif [ "$_GIT_MODEL_OK" != 1 ] && printf '%s' "$COMMAND" | grep -q 'commit'; then
        # Model load failed = fail-closed. A `commit` token present → classify as
        # commit so the state-machine drain does not bypass the commit gate.
        # over-trigger is the safe direction.
        _SM_CLASS="commit"
      elif echo "$COMMAND" | grep -qE '(^|[^a-zA-Z_])(pytest|jest|vitest|mocha)\b' \
           || echo "$COMMAND" | grep -qE 'npm[[:space:]]+(run[[:space:]]+)?test\b' \
           || echo "$COMMAND" | grep -qE 'yarn[[:space:]]+test\b' \
           || echo "$COMMAND" | grep -qE 'pnpm[[:space:]]+test\b' \
           || echo "$COMMAND" | grep -qE 'python[[:space:]]+-m[[:space:]]+pytest\b'; then
        _SM_CLASS="test"
      fi
    fi
    drain_state "$_SM_CLASS" 2>/dev/null || true
  fi
fi

# --- invoke_hook_required: call a critical helper, fail-closed if missing ---
#
# For bootstrap / safety / (conditional) test-commit. A missing file here
# indicates plugin corruption — refusing the Bash call is safer than silently
# disabling the block points the helper enforces.
#
# Returns the helper's exit code. Helpers write their JSON deny payload to
# stdout (policy blocks) or `[rein] ...` lines to stderr (infra-integrity);
# both are forwarded as-is because we do not capture either stream.
invoke_hook_required() {
  local hook="$1"
  local label="$2"
  if [ ! -f "$hook" ]; then
    echo "[rein] Critical Bash gate helper missing: $label. The plugin install may be corrupted — run /plugin update rein to repair." >&2
    return 2
  fi
  printf '%s' "$INPUT" | bash "$hook"
  return $?
}

# --- invoke_hook_advisory: best-effort, skip if missing ---
#
# For bash-rules (rule injection only — no block enforcement). A missing file
# here only drops advisory context, which is acceptable as a degraded mode.
invoke_hook_advisory() {
  local hook="$1"
  [ -f "$hook" ] || return 0
  printf '%s' "$INPUT" | bash "$hook"
  return $?
}

# --- Step 1: bootstrap gate (always, required) ---
invoke_hook_required "$SCRIPT_DIR/pre-tool-use-bash-bootstrap-gate.sh" "bootstrap gate"
RC=$?
[ "$RC" -ne 0 ] && exit "$RC"

# --- Step 2: safety guard (always, required) ---
invoke_hook_required "$SCRIPT_DIR/pre-bash-safety-guard.sh" "safety guard"
RC=$?
[ "$RC" -ne 0 ] && exit "$RC"

# --- Step 3: commit review pair (conditional, required when triggered) ---
#
# Phase 7 웨이브 3 ③-c (commit-gate 교대, 2026-08-23). 구 단일
# pre-bash-test-commit-gate.sh 가 이 자리에서 invoke_hook_required 로 한
# 번에 호출되던 것을, 이제 두 자식으로 쪼갠 pre-bash-commit-discipline-
# gate.sh(coverage matrix [P2]/[I3] + 커밋 메시지 포맷 [P7]/[I4]/[I5] 등
# v1 존속 규율)와 pre-bash-commit-review-gate.sh(code_review/security_review
# 두 축의 v2 authority 위임, ③-c 신설)로 **순서를 보장해 순차** 호출한다.
#
# 왜 위 invoke_hook_required 를 그대로 못 쓰는가: 그 helper 는 자식이
# stdout 에 JSON deny 를 낸 그 자리에서 그대로 relay 하고 종료하는 것을
# 전제하지 않는다 — 자식이 정확히 하나일 때는 "helper 의 stdout/stderr 를
# 캡처 없이 곧장 이 프로세스의 것으로 흘려보내고 rc 만 확인"해도 충분했다
# (그 helper 자신의 docstring 참조 — "Returns the helper's exit code...
# both are forwarded as-is because we do not capture either stream"). 자식이
# 둘이 되면서 새로운 클래스의 문제가 생긴다: 선행 자식(discipline-gate)이
# JSON deny(exit 0 + stdout)를 냈는데도 같은 방식으로 그냥 넘어가면 rc=0
# 이므로 디스패처가 "통과"로 오인해 후행 자식(review-gate)을 마저 실행하고,
# 그 자식이 또 다른 사유로 JSON deny 를 내면 이 프로세스의 stdout 에 JSON
# 오브젝트 2개가 연달아 섞여 나간다 — Claude Code 가 기대하는 hook 출력
# 계약(단일 JSON 오브젝트)을 깨는 새 결함 클래스다. pre-edit-dispatcher.sh
# 가 discipline/task/coverage 세 자식을 순차 호출할 때 이미 정확히 같은
# 문제(같은 근본 원인 — "exit 0 이 곧 통과"라는 낡은 가정이 자식이 둘 이상
# 일 때 깨진다)를 캡처-릴레이-중단 패턴으로 봉합한 선례가 있다(그 파일의
# invoke_child() 및 그 헤더의 "자식 응답 계약" 절 참조) — 그 패턴을 여기로
# 그대로 가져온다. bootstrap(Step 1)/safety(Step 2)와 bash-rules(Step 4)는
# 여전히 자식이 하나뿐이라 이 클래스의 문제가 없다 — 그 두 Step 은 기존
# invoke_hook_required/invoke_hook_advisory 그대로 유지한다(범위 밖 — 기존
# 동작 불변).
#
# invoke_bash_child HOOK_FILENAME LABEL — pre-edit-dispatcher.sh 의
# invoke_child() 와 동일한 계약(그 파일 참조): stdout 만 캡처(_BC_OUT),
# rc 는 별도 캡처(_BC_RC — stdout 캡처 명령 자체의 $? 를 즉시 읽는다).
# stderr 는 캡처하지 않고 상속(자식의 [rein]/WARNING/NOTICE 진단이 지연·
# 순서왜곡 없이 사용자에게 도달해야 한다 — pre-edit-dispatcher.sh 헤더의
# 동일 원칙). 자식 파일 자체가 없으면(플러그인 설치 손상) 실행을 시도하지
# 않고 곧바로 fail-closed.
invoke_bash_child() {
  local hook="$1"
  local label="$2"
  local path="$SCRIPT_DIR/$hook"
  if [ ! -f "$path" ]; then
    echo "[rein] Critical Bash gate helper missing: $label ($hook). The plugin install may be corrupted — run 'rein update' to repair." >&2
    _BC_RC=2
    _BC_OUT=""
    return
  fi
  _BC_OUT=$(printf '%s' "$INPUT" | bash "$path")
  _BC_RC=$?
}

if [ "$CLASS_NEEDS_TC" = "1" ]; then
  for _tc_child_spec in \
    "pre-bash-commit-discipline-gate.sh|commit discipline gate" \
    "pre-bash-commit-review-gate.sh|commit review gate"; do
    _tc_hook="${_tc_child_spec%%|*}"
    _tc_label="${_tc_child_spec#*|}"
    invoke_bash_child "$_tc_hook" "$_tc_label"
    case "$_BC_RC" in
      0)
        if [ -n "$_BC_OUT" ]; then
          # exit 0 + non-empty stdout — JSON deny relay 관례. 그대로 relay
          # 하고 즉시 종료 (잔여 자식 미실행 — Step 4 도 건너뛴다, 구
          # invoke_hook_required 경로가 그 자식의 rc=0 을 받은 즉시 Step 4
          # 로 넘어갔던 것과 달리, JSON deny 는 "이번 Bash 호출은 이미
          # 최종 응답을 얻었다"는 뜻이라 뒤의 어떤 자식도 실행할 필요가
          # 없다).
          printf '%s\n' "$_BC_OUT"
          exit 0
        fi
        # exit 0 + stdout 없음 — 허용, 다음 자식으로.
        ;;
      2)
        # 차단 — 자식이 이미 stderr 에 이유를 냈다. 잔여 자식 미실행.
        exit 2
        ;;
      *)
        # 비정상 종료 — 게이트 실행 실패를 통과로 삼키지 않는다.
        echo "[rein] The Bash dispatcher cannot continue because $_tc_hook exited abnormally (rc=$_BC_RC, expected 0 or 2). This is treated as a failure, not a pass — run 'rein update' to check for a corrupted plugin install, or check the child gate's own stderr output above for the underlying cause." >&2
        exit 2
        ;;
    esac
  done
fi

# --- Step 4: bash-rules rule injection (conditional, advisory) ---
if [ "$CLASS_NEEDS_BR" = "1" ]; then
  invoke_hook_advisory "$SCRIPT_DIR/pre-tool-use-bash-rules.sh"
  RC=$?
  [ "$RC" -ne 0 ] && exit "$RC"
fi

exit 0
