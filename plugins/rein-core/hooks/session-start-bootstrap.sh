#!/bin/bash
# Hook: SessionStart
# Detect a project directory where the Rein plugin is enabled but repo-local
# state has not been initialized yet. SessionStart cannot ask interactively
# itself, so it injects concise context instructing Claude to ask before
# bootstrapping.
#
# Implementation: delegates the actual safety + presence predicate to the
# shared helper `hooks/lib/bootstrap-check.sh` (Wave 1 source of truth).
# This hook owns only the SessionStart-specific stdout emit shape and the
# CLAUDE_PLUGIN_ROOT guard. The helper handles project_dir resolution,
# unsafe-path detection (plugin cache / sensitive paths / unwritable), and
# the trail/ presence check.

set -uo pipefail

# Without CLAUDE_PLUGIN_ROOT we cannot locate the helper or the bootstrap
# script the guidance text references. Silently exit so SessionStart does
# not block.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"
if [ ! -f "$HELPER" ]; then
  exit 0
fi

# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"

# Single confirmed project_dir for every judgement and side effect below —
# flag sweep, git checks, auto-bootstrap, marker writes/clears, guidance,
# primer. _bc_resolve_project_dir is the SAME resolution bootstrap_check
# itself uses (event cwd first via the inherited stdin envelope). A
# resolution failure is the helper's "unsafe: resolution" category — silent
# exit, exactly as bootstrap_check returning 11 is handled below.
#
# Output shape is "<source><TAB><resolved_real>" — source is a fixed enum
# that never contains a tab, so splitting on the FIRST tab and taking the
# remainder as the path is safe even when resolved_real itself contains a
# literal tab byte (a legal directory-name character).
#
# Sentinel capture (`; printf x` inside the SAME command substitution,
# stripped with `${RESOLUTION%x}`): a plain `$(...)` strips ALL trailing
# newlines, which would truncate resolved_real when its own last byte is a
# literal LF (also a legal directory-name character) — every branch below
# would then silently no-op (PROJECT_DIR empty → early exit 0) instead of
# writing a degraded marker / auto-bootstrapping. Exit code is not needed
# here (the emptiness check below is the only consumer), so the simple
# sentinel form suffices — no if/else needed.
RESOLUTION=$(_bc_resolve_project_dir; printf x)
RESOLUTION="${RESOLUTION%x}"
PROJECT_DIR="${RESOLUTION#*$'\t'}"
if [ -z "$PROJECT_DIR" ]; then
  exit 0
fi

# Sentinel idiom (`; printf x` inside the SAME command substitution that
# captures stdout): plain `$(cmd)` strips trailing newlines, which would
# lose the guidance's final LF. No temp file — bootstrap_check runs with
# PROJECT_DIR passed as an explicit override, so it never re-reads stdin
# here, and this hook has no TMPDIR dependency.
HELPER_OUT=$(
  if bootstrap_check "$PROJECT_DIR"; then
    printf x
  else
    rc=$?
    printf x
    exit "$rc"
  fi
)
HELPER_RC=$?
HELPER_OUT="${HELPER_OUT%x}"
STUCK_NOTICE_PRINTED=0

# Housekeeping: sweep stale git-required-guidance "shown" flags (see
# lib/git-required-guidance.sh's rein_git_guidance_* functions) older than a
# day. Mirrors session-start-load-trail.sh's active-dod-choice.session-*.flag
# sweep for the same class of leak — a session-scoped semaphore with no
# natural session-end cleanup. A day (rather than that sweep's 1h) because
# this flag's whole purpose is to survive an entire session, which can run
# far longer than 1h; deleting a still-active session's flag would just
# re-ask the approval question once. Best-effort — failure never blocks
# SessionStart. Runs on the confirmed PROJECT_DIR (post-collapse) so the
# sweep targets the same directory every branch below uses.
find "$PROJECT_DIR/.claude/cache" -maxdepth 1 -type f \
  -name '.rein-git-guidance-shown.session-*' \
  -mmin +1440 -delete 2>/dev/null || true

# Source degraded-check.sh up-front so rein_clear_degraded / rein_write_degraded
# are available across all branches below. The rc=0 branch needs `clear` so a
# stale marker from a prior degraded session is cleaned once bootstrap is
# healthy again — without this, every downstream gate (BG-B/C/D) would keep
# passing through silently, leaving the user with no governance for the rest
# of the session.
DEGRADED_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/degraded-check.sh"
DEGRADED_HELPER_LOADED=0
if [ -f "$DEGRADED_HELPER" ]; then
  # shellcheck disable=SC1091
  source "$DEGRADED_HELPER"
  DEGRADED_HELPER_LOADED=1
fi

# ONBOARD-1: source the first-session onboarding helper so this hook can emit
# the primer to the USER channel (stdout) when the onboarded marker is absent.
# This hook reads the marker only — it NEVER writes it. The sole marker writer
# is session-start-rules.sh (the last SessionStart hook), which guarantees
# bootstrap always observes the marker-absent snapshot in the same session
# (SCOPE-SINGLE-WRITER). Graceful-degrade: if the helper is missing the primer
# is simply skipped, SessionStart never blocks.
ONBOARDED_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/onboarded-check.sh"
ONBOARDED_HELPER_LOADED=0
if [ -f "$ONBOARDED_HELPER" ]; then
  # shellcheck disable=SC1091
  source "$ONBOARDED_HELPER"
  ONBOARDED_HELPER_LOADED=1
fi

# git-required-onboarding: single source of truth for the guidance printed
# on the git-missing / non-git-dir branches below (shared with lib/
# bootstrap-check.sh's UserPromptSubmit advisory so the two channels cannot
# give the user contradicting instructions again). Fail-soft: if the lib is
# missing (install regression), each branch below falls back to its old
# one-line text — this hook must never block on a guidance lib being absent.
GIT_GUIDANCE_HELPER="${CLAUDE_PLUGIN_ROOT}/hooks/lib/git-required-guidance.sh"
GIT_GUIDANCE_HELPER_LOADED=0
if [ -f "$GIT_GUIDANCE_HELPER" ]; then
  # shellcheck disable=SC1091
  source "$GIT_GUIDANCE_HELPER"
  GIT_GUIDANCE_HELPER_LOADED=1
fi

# Git env vars stripped for every git invocation and for the auto-bootstrap
# python call below (branches 3 and 4) — the same set bootstrap-check.sh
# strips before its own git walk-up, so an inherited GIT_DIR / GIT_WORK_TREE
# / GIT_COMMON_DIR / GIT_INDEX_FILE cannot redirect either judgement onto an
# unrelated repo. GIT_CEILING_DIRECTORIES is deliberately NOT in this list
# (policy-sensitive — left to the caller). One array so both call sites stay
# in sync.
REIN_GIT_ENV_STRIP=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE)

# Emit the first-session primer to the user (stdout) only when the helper
# loaded AND the onboarded marker is absent. Read-only — no marker write here.
rein_emit_primer_stdout() {
  [ "$ONBOARDED_HELPER_LOADED" = "1" ] || return 0
  if ! rein_is_onboarded "$PROJECT_DIR"; then
    rein_primer_body
  fi
}

# One-line recovery guidance when a stale degraded marker cannot be removed
# (e.g. read-only .claude/cache). Shared by the auto-bootstrap path (script
# exit 4) and the already-bootstrapped rc=0 path: both leave the marker in
# place (never papered over) and tell the user where it is. The marker path
# is rendered through `printf %q` so an LF or space in it stays on this one
# line and the message remains copy-pasteable as a shell argument; printed
# with printf, not echo — under POSIXLY_CORRECT=1 (or `shopt -s xpg_echo`)
# echo would re-expand the literal `\n` that %q emits for a real LF byte
# and split the single line.
rein_emit_stuck_marker_line() {
  local project_dir="$1" marker_path marker_path_q
  marker_path="$project_dir/.claude/cache/.rein-session-degraded"
  marker_path_q=$(printf '%q' "$marker_path")
  printf '%s\n' "rein: 초기화는 완료됐지만 이전 세션의 표식(${marker_path_q})을 지우지 못했습니다 — 직접 삭제하거나 세션을 다시 시작하면 감시 기능이 켜집니다. / rein: bootstrap completed, but a stale marker from a prior session (${marker_path_q}) could not be removed — remove it by hand or restart the session for governance to turn on."
}

if [ "$HELPER_RC" = "10" ]; then
  # BG-A (v1.3.0): rc=10 means trail/ + .rein/project.json missing on a SAFE
  # project_dir. Replace the previous "emit guidance + exit 0" with a 6-step
  # branch — opt-out / git-missing / non-git / auto-bootstrap / refusal —
  # so fresh installs become self-healing instead of deadlocking on a
  # bootstrap command the bash gate would reject.
  if [ "$DEGRADED_HELPER_LOADED" = "1" ]; then
    rein_clear_degraded "$PROJECT_DIR"
  fi

  # 1. Opt-out
  if [ "${REIN_NO_AUTO_BOOTSTRAP:-}" = "1" ]; then
    rein_write_degraded "$PROJECT_DIR" "user-opt-out"
    echo "rein: REIN_NO_AUTO_BOOTSTRAP=1 이 설정되어 있어 자동 초기화를 건너뜁니다. 감시 기능이 이번 세션에서 비활성화됩니다."
    exit 0
  fi

  # 2. git binary check
  if ! command -v git >/dev/null 2>&1; then
    rein_write_degraded "$PROJECT_DIR" "git-missing"
    if [ "$GIT_GUIDANCE_HELPER_LOADED" = "1" ]; then
      rein_git_required_guidance "git-missing" "$PROJECT_DIR" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py"
      # SessionStart is the one place this guidance always fires
      # unconditionally (it only runs once at session start), so it is the
      # canonical "first time shown" moment — mark it so bootstrap_check's
      # degraded-reason override (consumed by every later UserPromptSubmit
      # in this session) prints a short reminder instead of repeating the
      # full approval question on every turn.
      rein_git_guidance_mark_shown "$PROJECT_DIR"
    else
      # Fail-soft fallback (guidance lib missing — install regression).
      echo "rein: git 가 설치되어 있지 않아 초기화를 진행할 수 없습니다. git 을 먼저 설치한 뒤 \`git init\` 과 bootstrap 을 실행해 주세요. 감시 기능이 이번 세션에서 비활성화됩니다."
    fi
    exit 0
  fi

  # 3. cwd-in-git-repo check
  if ! env "${REIN_GIT_ENV_STRIP[@]}" git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    rein_write_degraded "$PROJECT_DIR" "non-git-dir"
    if [ "$GIT_GUIDANCE_HELPER_LOADED" = "1" ]; then
      rein_git_required_guidance "non-git-dir" "$PROJECT_DIR" "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py"
      # See the matching comment in branch 2 above.
      rein_git_guidance_mark_shown "$PROJECT_DIR"
    else
      # Fail-soft fallback (guidance lib missing — install regression).
      echo "rein: '$PROJECT_DIR' 는 git 저장소가 아닙니다. \`git init\` 을 먼저 실행한 뒤 bootstrap 을 진행해 주세요. 감시 기능이 이번 세션에서 비활성화됩니다."
    fi
    exit 0
  fi

  # 4. Auto-bootstrap (git repo + safe path guaranteed by rc=10)
  #
  # The bootstrap script writes its own chatter ("security profile created:
  # ...", "Rein repo state bootstrapped at ...") to stdout — silenced
  # entirely (stdout+stderr to /dev/null) so only this hook's own 1-line
  # notice reaches the user. Helper failure surfaces via the rc check
  # (falls into branch 5 refusal). Git env stripped per REIN_GIT_ENV_STRIP
  # above (H2) — git_root_for's own subprocess call is the actual consumer.
  bootstrap_version=$(python3 -c "import json,sys;print(json.load(open('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "")
  # Capture the exit code instead of branching in the `if` itself — every
  # non-zero code used to fall straight into branch 5 (bootstrap-refused),
  # which is wrong for DEGRADED_MARKER_STUCK_EXIT (see below): repo-local
  # state was written successfully in that case, only the stale marker's
  # removal failed.
  BOOTSTRAP_RC=0
  env "${REIN_GIT_ENV_STRIP[@]}" python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" \
       --project-dir "$PROJECT_DIR" \
       ${bootstrap_version:+--version "$bootstrap_version"} >/dev/null 2>&1 || BOOTSTRAP_RC=$?
  if [ "$BOOTSTRAP_RC" = "0" ]; then
    echo "rein: bootstrap completed automatically — created trail/ and .rein/project.json in $PROJECT_DIR (version $bootstrap_version)."
    # ONBOARD-1 (F-1): first-session primer on the rc=10 auto-bootstrap path.
    # MUST sit between the notice echo and `exit 0` — after `exit 0` it would
    # never run. Read-only (no marker write); rules writes the marker.
    rein_emit_primer_stdout
    exit 0
  fi

  # DEGRADED_MARKER_STUCK_EXIT: scripts/rein-bootstrap-project.py's own
  # contract (see that script's module docstring / DEGRADED_MARKER_STUCK_EXIT
  # constant) — exit 4 means trail/ + .rein/project.json were written
  # successfully, but a stale SessionStart degraded marker under
  # .claude/cache could not be removed. This is NOT a bootstrap refusal:
  # writing "bootstrap-refused" over the marker would erase the real reason
  # and (on the non-git-dir / git-missing branches) print now-false "not a
  # git repository" advice for a folder that just got bootstrapped. Leave
  # the marker exactly as it is and tell the user how to clear it.
  #
  # Message contract: exactly ONE line of stdout carrying both the Korean
  # and English sentences (joined with " / "), never two separate `echo`
  # calls — a path containing a literal LF would otherwise add physical
  # lines to the output. The marker path is rendered through `printf %q`
  # so an LF or space in it stays on this one line and the whole message
  # remains copy-pasteable as a shell argument.
  DEGRADED_MARKER_STUCK_EXIT=4
  if [ "$BOOTSTRAP_RC" = "$DEGRADED_MARKER_STUCK_EXIT" ]; then
    rein_emit_stuck_marker_line "$PROJECT_DIR"
    exit 0
  fi

  # 5. Bootstrap refusal (rc 11 unsafe path etc.) — degraded fallback
  rein_write_degraded "$PROJECT_DIR" "bootstrap-refused"
  printf '%s' "$HELPER_OUT"
  exit 0
fi

# rc=0  (trail present)         → silent + clear stale degraded marker
# rc=11 (unsafe project_dir)    → silent (helper already logged stderr)
#
# HIGH-1 fix: rc=0 means bootstrap is healthy *now*. If a previous session
# wrote a degraded marker (e.g. user opt-out, git-missing, bootstrap-refused),
# but the user has since fixed the underlying condition (ran bootstrap
# manually, installed git, dropped REIN_NO_AUTO_BOOTSTRAP=1), the marker is
# stale and would keep BG-B/C/D in pass-through forever. Clear it here so
# governance resumes on the next gate invocation.
if [ "$HELPER_RC" = "0" ] && [ "$DEGRADED_HELPER_LOADED" = "1" ]; then
  # Removal can fail silently (read-only .claude/cache): the marker would then
  # keep every gate in pass-through with no explanation. Print the same
  # one-line guidance as the auto-bootstrap path's exit-4 branch — but only
  # when the removal FAILED and the gates would still see a marker
  # (rein_is_degraded, the consumers' own `-f` test): a directory squatting
  # on the marker name fails `rm -f` yet does not disable governance, and a
  # successful removal followed by another session re-creating the marker is
  # that session's business, not a stuck marker. Marker left as-is.
  if ! rein_clear_degraded "$PROJECT_DIR" && rein_is_degraded "$PROJECT_DIR"; then
    rein_emit_stuck_marker_line "$PROJECT_DIR"
    STUCK_NOTICE_PRINTED=1
  fi
fi

# ONBOARD-1 (F-2): backfill primer for existing users on the rc=0 path (trail/
# already present). This is an INDEPENDENT branch gated only on marker absence,
# deliberately placed OUTSIDE the DEGRADED_HELPER_LOADED if-block above so the
# primer is not skipped when the degraded helper failed to load. Read-only —
# rules writes the marker. SCOPE-BACKFILL: emit once, then permanently silent.
# Skipped on a run that just printed the stuck-marker notice: that notice is
# the one line the user must see and act on; the primer backfill is a
# one-time nicety that will print on a later session once the marker is
# gone (it is gated on marker absence, not on this run). Keeps the stuck
# case's stdout to exactly one line on every path (fixtures R/S/W).
if [ "$HELPER_RC" = "0" ] && [ "${STUCK_NOTICE_PRINTED:-0}" != "1" ]; then
  rein_emit_primer_stdout
fi

# Heal-existing-projects (2026-09-04, rein-state-gitignore-digest DoD): a
# project bootstrapped before REIN_RUNTIME_GITIGNORE_PATTERNS grew to cover
# /.rein/state.json et al. never got those patterns appended, so rein's own
# hook-rewritten state file stays tracked and dirties the review-subject
# digest on every tool call. Only the rc=0 (already-healthy) branch calls
# this — rc=10's auto-bootstrap path above already writes every pattern via
# the FULL bootstrap() call, so this would be redundant (and rc=11's unsafe
# path must never touch project files). Best-effort: stdout/stderr silenced,
# `|| true` so a failure here can never block SessionStart. Same git-env
# strip array as the auto-bootstrap call above (REIN_GIT_ENV_STRIP) — the
# sub-mode's own git_root_for() probe must not be redirected by an
# inherited GIT_DIR onto an unrelated repo either.
if [ "$HELPER_RC" = "0" ]; then
  env "${REIN_GIT_ENV_STRIP[@]}" python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" \
       --ensure-gitignore --project-dir "$PROJECT_DIR" >/dev/null 2>&1 || true
fi
exit 0
