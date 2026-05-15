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

# Resolve PROJECT_DIR for degraded-marker writes / git probes.
# Plan b-prancy-valiant §BG-A uses PROJECT_DIR as the bootstrap target;
# session-start-bootstrap.sh previously had no such variable, so source
# the shared resolver before any rc=10 branch needs it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/project-dir.sh"
PROJECT_DIR="$(resolve_project_dir "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bootstrap-check.sh"

# Capture helper stdout (the bilingual guidance text on rc=10) without
# letting `set -e` short-circuit on rc=10/11. The `set -uo pipefail` above
# does not include `errexit`, so this $() will not abort on non-zero rc.
#
# Sentinel idiom — plain command substitution `$(bootstrap_check)` strips
# the helper's trailing newline, breaking byte-level parity with direct
# helper invocation (and with the pre-refactor hook which used a here-doc
# emit that retained the newline). Wrap the call so the subshell appends a
# sentinel `x` AFTER the helper's stdout, then strip the sentinel; this
# preserves any trailing `\n` the helper wrote while keeping the subshell's
# exit code equal to bootstrap_check's rc (same pattern as
# user-prompt-submit-rules.sh:39 and the rule-inject body capture).
HELPER_RC=0
HELPER_OUT=$(if bootstrap_check; then printf x; else rc=$?; printf x; exit "$rc"; fi) || HELPER_RC=$?
HELPER_OUT="${HELPER_OUT%x}"

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
    echo "rein: degraded mode (REIN_NO_AUTO_BOOTSTRAP=1). Gates inactive for this session."
    exit 0
  fi

  # 2. git binary check
  if ! command -v git >/dev/null 2>&1; then
    rein_write_degraded "$PROJECT_DIR" "git-missing"
    cat <<'EOF'
rein: degraded mode — git is not installed. Install git first, then run `git init` + bootstrap.
  macOS:        xcode-select --install   (or: brew install git)
  Debian/Ubuntu: sudo apt install git
  Fedora:        sudo dnf install git
  Arch:          sudo pacman -S git
  Windows:       install Git for Windows or `winget install Git.Git`
Gates inactive for this session.
EOF
    exit 0
  fi

  # 3. cwd-in-git-repo check
  if ! git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    rein_write_degraded "$PROJECT_DIR" "non-git-dir"
    echo "rein: degraded mode — '$PROJECT_DIR' is not a git repo. Run \`git init\` here first, then bootstrap. Gates inactive for this session."
    exit 0
  fi

  # 4. Auto-bootstrap (git repo + safe path guaranteed by rc=10)
  #
  # MEDIUM-1 fix: helper writes chatter like "security profile created: ..."
  # and "Rein repo state bootstrapped at ..." to stdout. Redirecting helper
  # stdout to stderr would still surface them in the SessionStart prompt
  # alongside our 1-line notice. Silence the helper entirely (stdout+stderr
  # to /dev/null) so only our authoritative 1-line notice reaches the user.
  # Helper failure surfaces via the rc check (falls into branch 5 refusal).
  bootstrap_version=$(python3 -c "import json,sys;print(json.load(open('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "")
  if python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" \
       --project-dir "$PROJECT_DIR" \
       ${bootstrap_version:+--version "$bootstrap_version"} >/dev/null 2>&1; then
    echo "rein: bootstrap completed automatically — created trail/ and .rein/project.json in $PROJECT_DIR (version $bootstrap_version)."
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
  rein_clear_degraded "$PROJECT_DIR"
fi
exit 0
