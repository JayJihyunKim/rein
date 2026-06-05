#!/usr/bin/env bash
# Plugin helper — first-session onboarding marker management.
#
# Marker: <project_dir>/.rein/.onboarded (persistent; NOT under cache/ to
# avoid rotation re-firing the primer). Presence alone means "primer seen" —
# no freshness comparison (first-session one-shot).
#
# Usage (source from a SessionStart hook):
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/onboarded-check.sh"
#   rein_is_onboarded "$PROJECT_DIR" || rein_primer_body   # emit on first session
#
# Functions:
#   rein_is_onboarded [project_dir]
#       Returns 0 if marker exists (primer already seen), 1 otherwise.
#       Default project_dir is $PWD.
#   rein_mark_onboarded <project_dir> [version]
#       Write the marker (onboarded=<ISO 8601 UTC> + version=<plugin version>).
#       mkdir -p .rein/ for backfill-path safety. Non-blocking on failure
#       (caller must not abort SessionStart — see assumption B in the design).
#   rein_primer_body
#       Print the shared first-session primer copy (one paragraph + three core
#       flows + "getting stuck is normal"). Single definition consumed by both
#       SessionStart channels (bootstrap stdout + rules additionalContext) so
#       the two channels stay byte-identical (asserted by the regression test).
#       Deliberately free of internal identifiers (hook filenames, marker
#       paths, rc codes) per NFR-TERM.

rein_is_onboarded() {
  local project_dir="${1:-${PWD:-.}}"
  [ -f "$project_dir/.rein/.onboarded" ]
}

rein_mark_onboarded() {
  local project_dir="$1"
  local version="${2:-}"
  [ -n "$project_dir" ] || return 1
  mkdir -p "$project_dir/.rein" 2>/dev/null || return 1
  {
    printf 'onboarded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S)"
    printf 'version=%s\n' "$version"
  } > "$project_dir/.rein/.onboarded" 2>/dev/null || return 1
}

rein_primer_body() {
  cat <<'PRIMER'
처음 오셨네요, 반갑습니다 👋 이 저장소의 첫 세션이라 짧게 안내드릴게요.
rein 은 코드가 들어오기 전에 "무엇을 할지 정하기 → 당신의 승인 → 리뷰 통과"를 곁에서 도와드려요.
가다가 막혀도 괜찮아요 — 그때마다 다음에 뭘 하면 되는지 바로 알려드릴게요.
PRIMER
}
