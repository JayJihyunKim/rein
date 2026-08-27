#!/bin/bash
# hooks/lib/governance-invalid-gate.sh
#
# Governance-stage INVALID axis of the precondition chain the (now-retired)
# pre-edit-dod-gate.sh used to own inline (Plan A §6, GI-governance-stage-
# config). Extracted verbatim from that hook's "Governance stage" block
# (its L345-362, right after the GMF-3 emit_ext_source_notice() definition
# and before the incident-review-pending check) as part of the Phase 7
# wave 3 ③-b edit-gate handoff — pre-edit-dod-gate.sh is being retired and
# replaced by pre-edit-discipline-gate.sh + pre-edit-task-gate.sh. This
# block belongs to the discipline axis (v1 surviving governance-stage
# awareness, out of scope for the v2 active_task hand-off), so it moves to
# a lib alongside its siblings (lib/incident-review-gate.sh,
# lib/spec-review-gate.sh, lib/routing-gate.sh) rather than staying
# inlined in a hook file that no longer exists.
#
# This is a MECHANICAL move, not a rewrite: the log-append + DOD_MISMATCH_
# MARKER touch + stderr message + log_block + exit 2 sequence is copied
# byte-for-byte from the original inline block. No decision logic changed.
#
# Contract for the caller (pre-edit-discipline-gate.sh):
#   Source lib/governance-stage.sh FIRST (this file calls
#   read_governance_stage / resolve_governance_config_path, both defined
#   there — not re-sourced here, to avoid a redundant load of that
#   library from inside this one; the caller already needs it directly for
#   its own RES-1/Plan-A-Phase-4 requirements anyway).
#   Then source this file and call `rein_check_governance_invalid` with NO
#   arguments at the exact point the old inline block used to run. The
#   function reads ambient globals the caller has already established:
#     PROJECT_DIR, DOD_DIR, DOD_MISMATCH_MARKER, FILE_PATH
#   and calls `log_block` (defined locally in the caller — see
#   lib/incident-review-gate.sh's header for why this is never shared
#   across hooks). On INVALID it calls `exit 2` directly (exactly as the
#   original inline code did) — because it runs SOURCED into the caller's
#   own shell process, `exit` here terminates the whole hook, not just the
#   function. On any other stage value it returns 0 (nothing to do here).
#
#   Also sets the ambient global GOVERNANCE_STAGE (as the original inline
#   block did) — callers that want the resolved stage value for their own
#   purposes after a non-INVALID return can read it directly.
#
# Usage:
#   . "$SCRIPT_DIR/lib/governance-stage.sh"
#   . "$SCRIPT_DIR/lib/governance-invalid-gate.sh"
#   rein_check_governance_invalid

if [ -n "${__REIN_GOVERNANCE_INVALID_GATE_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_GOVERNANCE_INVALID_GATE_LOADED=1

rein_check_governance_invalid() {
  # Fail-closed on malformed / unknown stage: "silent Stage 1 downgrade" is a
  # bypass path. Stage 1 (default / file-absent) is advisory; Stage 2/3 is
  # blocking. INVALID → block all Edits until config is fixed.
  GOVERNANCE_STAGE=$(cd "$PROJECT_DIR" && read_governance_stage)
  if [ "$GOVERNANCE_STAGE" = "INVALID" ]; then
    mkdir -p "$PROJECT_DIR/trail/incidents"
    printf '%s\t%s\n' "$(date -u +%FT%TZ)" "invalid_stage" \
      >> "$PROJECT_DIR/trail/incidents/governance-config-invalid.log" 2>/dev/null || true
    mkdir -p "$DOD_DIR"
    touch "$DOD_MISMATCH_MARKER"
    # governance.json path is mode-aware. Surface the actually-resolved path so
    # the user fixes the right file in plugin / legacy installs.
    GOVERNANCE_CONFIG_PATH=$(cd "$PROJECT_DIR" && resolve_governance_config_path)
    echo "[rein] The edit gate cannot run because the governance config file ($GOVERNANCE_CONFIG_PATH) is corrupt. Fix or remove the file to re-initialize to Stage 1 (advisory mode)." >&2
    log_block "governance config invalid" "$FILE_PATH"
    exit 2
  fi
  return 0
}
