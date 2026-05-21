#!/usr/bin/env bash
# Hook: Stop — Cycle X4.C.2 (영역 C).
#
# design ref: docs/specs/2026-05-21-area-c-state-machine.md §3.2 + §4.2
# Responsibility: append "turn-end" to .rein/state-pending-stop.log so the next
# dispatcher drain transitions mode → answer.
# Fail-soft on missing lib.

[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -z "${REIN_PROJECT_DIR_OVERRIDE:-}" ] && exit 0

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/state-machine.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=./lib/state-machine.sh
. "$LIB" 2>/dev/null || exit 0

append_journal stop "turn-end" >/dev/null 2>&1 || true

exit 0
