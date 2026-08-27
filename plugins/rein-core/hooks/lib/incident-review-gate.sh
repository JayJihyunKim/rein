#!/bin/bash
# hooks/lib/incident-review-gate.sh
#
# Incident-review-pending axis of the precondition chain pre-edit-dod-gate.sh
# owns before it ever reaches the DoD-existence / coverage branch (dod-gate
# fix cycle, 2026-08-14 — coverage-gate precondition-awareness). Extracted
# verbatim from pre-edit-dod-gate.sh's inline "Incident Review Pending 검사"
# block (previously the block right after the governance-stage check) so
# that pre-edit-coverage-gate.sh can independently re-derive "is this
# currently blocking" WITHOUT hand-copying the self-heal / bypass / auto-mode
# decision tree into a second location that could silently drift from this
# one (the same rationale lib/dod-found.sh and lib/source-path-classify.sh
# already established for their own predicates).
#
# This is a MECHANICAL move, not a rewrite: every branch (self-heal on
# LIVE_COUNT==0, one-shot INCIDENT_BYPASS consumption, auto-mode silence,
# the blocking message) is copied byte-for-byte from the original inline
# block. No decision logic changed.
#
# Contract for the caller (CURRENT: pre-edit-discipline-gate.sh, the
# ENFORCING caller — the successor to, and byte-for-byte behavioral
# continuation of, the now-deleted pre-edit-dod-gate.sh; it runs as a child
# of pre-edit-dispatcher.sh's guaranteed-sequential invocation, Phase 7
# wave 3 ③-b round 6, 2026-08-23):
#   Source this file, then call `rein_check_incident_review_gate` with NO
#   arguments at the exact point the old inline block used to run. The
#   function reads ambient globals the caller has already established:
#     PROJECT_DIR, DOD_DIR, FILE_PATH, PYTHON_RUNNER (array), CLAUDE_PLUGIN_ROOT
#   and calls `resolve_helper_script` (lib/plugin-script-path.sh) and
#   `log_block` (defined locally in the caller — a second local copy exists
#   in pre-bash-test-commit-gate.sh and pre-edit-coverage-gate.sh; none of
#   these share one copy, see pre-edit-coverage-gate.sh's own comment on why).
#   On a blocking outcome the function calls `exit 2` directly (exactly as
#   the original inline code did) — because it runs SOURCED into the
#   caller's own shell process, `exit` here terminates the whole hook, not
#   just the function. It never `return`s a "please exit" signal.
#
# HISTORY, not current contract (Phase 7 wave 3 ③-b round 1 → round 6,
# 2026-08-14 → 2026-08-23) — kept for the record, but the "READ-ONLY
# peeking caller" this section describes no longer exists in production:
#
#   Contract for a READ-ONLY caller (pre-edit-coverage-gate.sh, the PEEKING
#   caller) AS IT USED TO WORK: this hook was never meant to enforce this
#   precondition itself (that authority stayed with pre-edit-dod-gate.sh —
#   deny wins across the PreToolUse hook set regardless of which hook
#   produces it), it only needed to know whether this precondition was
#   currently blocking the same edit, so it could skip touching the
#   coverage markers / running the coverage validator. The peeking caller
#   ran this exact function (`rein_check_incident_review_gate`, zero
#   duplicated judgment) inside a subshell with its own `log_block` locally
#   neutralized to a no-op.
#
#   Ordering correction (round 1): an earlier revision of this paragraph
#   assumed pre-edit-dod-gate.sh's enforcing call had ALREADY run — and
#   already consumed INCIDENT_BYPASS / performed the LIVE_COUNT==0
#   self-heal — by the time the peek ran, because hooks.json happened to
#   list it earlier in the same matcher group. That assumption was false:
#   Claude Code ran every hook matched to the same event IN PARALLEL, "the
#   order is non-deterministic" (hooks guide), so the peek could just as
#   easily run BEFORE or CONCURRENTLY WITH the enforcing call, letting a
#   peek that won that race consume the user's one-shot bypass (or the
#   self-heal) for good. The round-1 fix guarded both `rm -f` sites below
#   with `REIN_GATE_PEEK_MODE` (set by the peek caller — pre-edit-coverage-
#   gate.sh's `_rein_precheck_would_block`) so a peek observed the exact
#   same judgment without ever performing the mutation for real.
#
#   REMOVED at round 6 (2026-08-23, pre-edit-dispatcher.sh introduced): the
#   peek itself — `_rein_precheck_would_block` and its call sites, plus the
#   three lib sourcings that existed solely to support it — was deleted
#   from pre-edit-coverage-gate.sh (see that hook's own "Precondition-
#   awareness" comment). The dispatcher now runs discipline-gate → task-
#   gate → coverage-gate in guaranteed sequence and stops at the first
#   block, so coverage-gate running at all is itself proof every
#   precondition ahead of it already passed — there is nothing left to peek
#   at. There is currently NO caller of this file in "peek" mode.
#
# CURRENT state of the `REIN_GATE_PEEK_MODE` guards below: they are an
# INERT defense layer with zero live consumers (no caller sets this
# variable to "1" any more) — left in place in case a future caller
# reintroduces a same-process peek; they cost nothing while unused. Do not
# read their presence as evidence that a peek path is still exercised in
# production.
#
# Sets no new state the caller doesn't already read directly off disk
# (INCIDENT_STAMP / INCIDENT_BYPASS existence). Always falls through
# normally (implicit return 0) unless it blocks (`exit 2`).

if [ -n "${__REIN_INCIDENT_REVIEW_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_INCIDENT_REVIEW_GATE_LOADED=1

rein_check_incident_review_gate() {
  # --- Incident Review Pending 검사 (cache 보다 앞. self-heal 포함) ---
  # cache hit 로 우회되면 안 되는 gate. 항상 실시간 검증.
  INCIDENT_STAMP="$DOD_DIR/.incident-review-pending"
  INCIDENT_BYPASS="$DOD_DIR/.skip-incident-gate"

  if [ -f "$INCIDENT_STAMP" ]; then
    # v0.10.1: resolver 는 이미 위에서 성공했으므로 PYTHON_RUNNER 가 populated 되어 있음.
    # exit code 를 분리 캡처하여 스크립트 실패 시 fail-closed 로 처리한다.
    # `|| echo 0` 방식은 실패 시에도 0 으로 보여 stamp 를 잘못 지우고 통과시켰음
    # (codex v0.7.2 review High).
    # RES-1: helper script 경로는 plugin-aware resolver 로 해석한다. resolver
    # 실패 시 stamp 검증 자체가 불가능하므로 fail-closed (VALIDATOR_PATH 패턴과
    # 동일). plugin install 환경에서 ${CLAUDE_PLUGIN_ROOT}/scripts/ 우선, 메인테이너
    # repo fallback 으로 ${PROJECT_DIR}/scripts/ 가 사용된다.
    AGGREGATE_PY=$(resolve_helper_script rein-aggregate-incidents.py) || {
      echo "[rein] The incident count check cannot run because the aggregate helper (rein-aggregate-incidents.py) could not be found. Run 'rein update' to restore it." >&2
      log_block "aggregate helper missing" "$FILE_PATH"
      exit 2
    }
    LIVE_COUNT=$("${PYTHON_RUNNER[@]}" "$AGGREGATE_PY" \
      --project-dir "$PROJECT_DIR" --count-pending 2>/dev/null)
    LIVE_RC=$?
    if [ "$LIVE_RC" -ne 0 ]; then
      echo "[rein] The incident count check failed (exit $LIVE_RC). Check that Python is working correctly and run 'rein update' if the problem persists." >&2
      log_block "incident count 검증 실패" "$FILE_PATH"
      exit 2
    fi
    if [ "$LIVE_COUNT" -eq 0 ]; then
      # REIN_GATE_PEEK_MODE 가드: peek(coverage-gate 의 precheck)는 이 self-heal
      # 을 실제로 수행하면 안 된다 — 병렬·순서 비보장 훅 실행에서 peek 가 먼저
      # 뛰면 진짜(enforcing) 호출보다 먼저 마커를 지워버릴 수 있다. 판정(통과)
      # 자체는 이 분기가 exit 하지 않으므로 가드 유무와 무관하게 동일하다.
      [ "${REIN_GATE_PEEK_MODE:-0}" = "1" ] || rm -f "$INCIDENT_STAMP"  # 자가 치유 — 통과
    elif [ -f "$INCIDENT_BYPASS" ]; then
      REASON=$(grep '^reason=' "$INCIDENT_BYPASS" 2>/dev/null | cut -d= -f2- || echo "unspecified")
      echo "WARNING: incident gate 1회성 바이패스 — reason: $REASON" >&2
      log_block "incident gate bypass" "$FILE_PATH"
      # REIN_GATE_PEEK_MODE 가드: 1회성 바이패스는 enforcing 호출만 소비해야
      # 한다 — peek 가 먼저 소비하면 진짜 집행 훅이 바이패스를 못 보고 사용자가
      # 승인한 편집을 차단한다(이 수리의 핵심 결함 클래스).
      [ "${REIN_GATE_PEEK_MODE:-0}" = "1" ] || rm -f "$INCIDENT_BYPASS"
    elif [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/auto-mode.sh" ] && \
         { . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/auto-mode.sh" 2>/dev/null || true; } && \
         declare -F is_auto_mode >/dev/null 2>&1 && is_auto_mode; then
      # Auto mode: silence the pending-incident block + skip stderr noise.
      # The user opted in via the marker file; block bypass is audit-logged.
      #
      # REIN_GATE_PEEK_MODE 가드 (Phase 7 wave 3 ③-b code review round 2,
      # Medium — 재현 완료): auto_mode_log_bypass() 는 trail/incidents/
      # auto-mode-bypass.log 에 실제로 append 하는 영속 부수효과인데(lib/
      # auto-mode.sh 참조, 위 spec-review-gate.sh 의 BYPASS_LOG 와 동일
      # 파일), round 1 은 이 호출을 가드하지 않았다 — peek(coverage-gate
      # 단독 실행)에서도 auto-mode 가 켜져 있으면 이 감사 로그에 실제 줄이
      # 남았다. 이 분기 자체는 exit 하지 않으므로(판정=통과) 가드를 걸어도
      # 판정 결과는 바뀌지 않는다 — "peek 는 판정만, 변이는 집행만" 계약을
      # 이 lib 의 마지막 미가드 지점까지 완결한다.
      if [ "${REIN_GATE_PEEK_MODE:-0}" != "1" ] \
         && declare -F auto_mode_log_bypass >/dev/null 2>&1; then
        auto_mode_log_bypass "incident-review-gate: skip pending-incident block (LIVE_COUNT=$LIVE_COUNT)"
      fi
    else
      echo "[rein] There are $LIVE_COUNT unresolved incidents that need a decision before source files can be edited. To proceed:" >&2
      echo "  1) Run /incidents-to-rule to review and resolve them." >&2
      echo "  2) Ask the user to approve or decline each incident." >&2
      echo "  3) Add any approved rule to AGENTS.md." >&2
      echo "  4) Mark each incident as processed: python3 <scripts-dir>/rein-mark-incident-processed.py <path> <processed|declined>" >&2
      echo "     (scripts-dir = \${CLAUDE_PLUGIN_ROOT}/scripts/ on plugin install, \${PROJECT_DIR}/scripts/ on maintainer repo)" >&2
      echo "  5) The check clears itself automatically on the next source edit once all incidents are resolved." >&2
      echo "" >&2
      echo "  Emergency bypass: echo 'reason=<reason>' > $INCIDENT_BYPASS" >&2
      log_block "incident review pending" "$FILE_PATH"
      exit 2
    fi
  fi
}
