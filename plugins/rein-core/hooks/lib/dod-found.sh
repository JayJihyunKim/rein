#!/bin/bash
# hooks/lib/dod-found.sh
#
# "Is there at least one pending (new-format, not-yet-completed) DoD file"
# — extracted verbatim from pre-edit-dod-gate.sh's inline "Pending DoD 판정"
# block (feature-builder-refactor task step 1, Marker B relocation).
#
# Why this needs to be shared, not just the coverage-validator invocation
# itself: pre-edit-coverage-gate.sh (the new Marker B producer) must agree
# with pre-edit-dod-gate.sh on "is there active work" BEFORE it is safe to
# call select_active_dod() (lib/select-active-dod.sh). select_active_dod's
# Tier 1/2 selection does NOT filter out a DoD that already has a matching
# completed inbox entry — Tier 1 trusts any contained, existing marker
# target; Tier 2 picks the mtime-latest `## 범위 연결` file with no inbox
# check at all. So calling select_active_dod unconditionally (without first
# confirming DOD_FOUND) could select an already-completed DoD as a Tier 2
# candidate and run the coverage validator (and touch/clear the coverage
# markers) against a task that finished — something the original single-hook
# flow could never do, because DOD_FOUND=false already forced pre-edit-dod-
# gate.sh's own gate to exit 2 ("no active task record") before it ever
# reached select_active_dod. Duplicating (or worse, hand-adapting) this scan
# in two files would silently drift the moment DoD naming/completion rules
# change in only one copy — hence one shared function.
#
# Usage:
#   . "$SCRIPT_DIR/lib/dod-found.sh"
#   rein_dod_found            # reads ambient DOD_DIR, INBOX_DIR
#   [ "$DOD_FOUND" = true ] && ...
#
# Sets global DOD_FOUND ("true"|"false"). Always returns 0.

if [ -n "${__REIN_DOD_FOUND_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__REIN_DOD_FOUND_LOADED=1

rein_dod_found() {
  # pending = 신 포맷 dod 파일 존재 AND 같은 slug 의 inbox 파일 없음
  DOD_FOUND=false
  local dod_file fname slug matched inbox_file inbox_slug_val
  if [ -d "$DOD_DIR" ]; then
    for dod_file in "$DOD_DIR"/dod-*.md; do
      [ -f "$dod_file" ] || continue
      fname=$(basename "$dod_file")

      # 신 포맷만 처리 (레거시는 별도 스윕)
      echo "$fname" | grep -q '^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-' || continue

      slug=$(echo "$fname" | sed 's/^dod-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//' | sed 's/\.md$//')

      # inbox/ 에 slug 완전 일치하는 파일이 있는지
      matched=false
      if [ -d "$INBOX_DIR" ]; then
        for inbox_file in "$INBOX_DIR"/[0-9]*.md; do
          [ -f "$inbox_file" ] || continue
          inbox_slug_val=$(basename "$inbox_file" .md | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
          if [ "$inbox_slug_val" = "$slug" ]; then
            matched=true
            break
          fi
        done
      fi

      if [ "$matched" = false ]; then
        DOD_FOUND=true
        break
      fi
    done
  fi
  return 0
}
