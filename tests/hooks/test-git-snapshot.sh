#!/usr/bin/env bash
# test-git-snapshot.sh
#
# GS-1..GS-4 regressions — authoritative git-fact snapshot for session state.
# (docs/specs|plans/2026-06-05-session-state-git-snapshot.md)
#
# Assertions:
#   (a) lib writes a snapshot file containing all 6 fields
#   (b) ahead/behind token mapping is correct (right=ahead, left=behind)
#   (c) latest tag uses `tag --sort=-creatordate` (newest-created), NOT describe
#       — proven with an UNREACHABLE newer tag that describe would miss
#   (d) no network commands (ls-remote/fetch) in the lib
#   (e) SessionStart injects the snapshot block AFTER the index block, and only
#       when the file exists; early-exit (no index) → no injection
#   (f) Stop advisory fires on hand-written git numbers (positive) but NOT on
#       semantic prose (negative); never changes the exit code (non-blocking)
#   (g) git-absent / non-git / failure → stale file is REMOVED (fresh-write-or-clear)
#   (h) detached HEAD → `detached` label + no origin/HEAD comparison
#   codex Low — index-less + trail dir: Stop regenerates the snapshot, SessionStart
#               injection is skipped (index-absent early-exit)
#   Stop High #1 — no-source-edit session still refreshes the snapshot (regen sits
#               before the line-158 early exit)
#
# Strategy: real temp git repos + CLAUDE_PLUGIN_ROOT pointed at this repo's plugin
# root, mirroring test-onboarding-primer.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LIB="$PLUGIN_ROOT/hooks/lib/git-snapshot.sh"
SESSION_START_HOOK="$PLUGIN_ROOT/hooks/session-start-load-trail.sh"
STOP_HOOK="$PLUGIN_ROOT/hooks/stop-session-gate.sh"
SNAP_REL=".rein/state/git-snapshot.md"

# NOTE: assertion blocks run in subshells `( ... )`, so a plain integer counter
# would not propagate failures back to the parent. Record failures in a file
# (a write survives the subshell) and count lines at the end.
FAILFILE="$(mktemp "/tmp/gitsnap-fail-XXXXXX")"
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; printf 'x\n' >> "$FAILFILE"; }

TMP_DIRS=()
cleanup() { rm -f "$FAILFILE"; for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# mk_repo → echo a fresh git repo path with one commit on the default branch.
mk_repo() {
  local d
  d="$(mktemp -d "/tmp/gitsnap-XXXXXX")"
  TMP_DIRS+=("$d")
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email "t@example.com"
  git -C "$d" config user.name "t"
  echo a > "$d/a.txt"
  git -C "$d" add a.txt
  GIT_COMMITTER_DATE="2026-01-01T00:00:00" GIT_AUTHOR_DATE="2026-01-01T00:00:00" \
    git -C "$d" commit -q -m "base"
  printf '%s\n' "$d"
}

# bootstrap_repo <repo> — add the BG-1 markers + index so hooks treat it as
# fully initialized (project.json + trail/ + trail/index.md).
bootstrap_repo() {
  local d="$1"
  mkdir -p "$d/trail" "$d/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"test"}' > "$d/.rein/project.json"
  printf '# trail/index.md\n\n## 현재 상태\n\n- x\n' > "$d/trail/index.md"
}

run_session_start() {
  ( cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$1" \
      bash "$SESSION_START_HOOK" </dev/null 2>/dev/null )
}
# run_stop <repo> <stdout_file> <stderr_file> → returns the hook exit code.
run_stop() {
  ( cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_PROJECT_DIR_OVERRIDE="$1" \
      bash "$STOP_HOOK" </dev/null ) >"$2" 2>"$3"
}

echo "## test-git-snapshot.sh"

# ---- (a) 6 fields ----------------------------------------------------------
(
  d="$(mk_repo)"
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  f="$d/$SNAP_REL"
  if [ -f "$f" ]; then
    miss=""
    for needle in "branch:" "HEAD:" "working tree:" "ahead/behind:" "최신 태그" "생성 시각(UTC)"; do
      grep -qF "$needle" "$f" || miss="$miss $needle"
    done
    [ -z "$miss" ] && pass "(a) 6 fields present" || fail "(a) missing fields:$miss"
  else
    fail "(a) snapshot file not created"
  fi
) || true

# ---- (b) ahead/behind mapping (right=ahead, left=behind) -------------------
(
  d="$(mk_repo)"
  br="$(git -C "$d" symbolic-ref --short HEAD)"
  parent="$(git -C "$d" rev-parse HEAD)"
  echo b > "$d/b.txt"; git -C "$d" add b.txt
  GIT_COMMITTER_DATE="2026-01-02T00:00:00" GIT_AUTHOR_DATE="2026-01-02T00:00:00" \
    git -C "$d" commit -q -m "second"
  # local origin ref at the PARENT → HEAD is ahead 1, behind 0
  git -C "$d" update-ref "refs/remotes/origin/$br" "$parent"
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  line="$(grep 'ahead/behind:' "$d/$SNAP_REL")"
  if printf '%s' "$line" | grep -qE 'ahead 1 / behind 0'; then
    pass "(b) ahead/behind mapping (ahead 1 / behind 0)"
  else
    fail "(b) wrong ahead/behind mapping: $line"
  fi
) || true

# ---- (c) latest tag = creatordate, not describe ----------------------------
(
  d="$(mk_repo)"
  # reachable older tag on HEAD
  GIT_COMMITTER_DATE="2026-01-03T00:00:00" git -C "$d" tag -a v0.1.0 -m v0.1.0
  reach="$(git -C "$d" rev-parse HEAD)"
  # unreachable NEWER tag on a side commit not in HEAD's ancestry
  git -C "$d" checkout -q -b side
  echo c > "$d/c.txt"; git -C "$d" add c.txt
  GIT_COMMITTER_DATE="2026-01-04T00:00:00" GIT_AUTHOR_DATE="2026-01-04T00:00:00" \
    git -C "$d" commit -q -m "side"
  GIT_COMMITTER_DATE="2026-01-05T00:00:00" git -C "$d" tag -a v0.2.0 -m v0.2.0
  git -C "$d" checkout -q "$reach"   # detached back at the older commit (v0.2.0 unreachable)
  # describe --abbrev=0 would report v0.1.0 (reachable). creatordate → v0.2.0.
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  tagline="$(grep '최신 태그' "$d/$SNAP_REL")"
  if printf '%s' "$tagline" | grep -qF "v0.2.0"; then
    pass "(c) latest tag = newest-created (v0.2.0), not describe's v0.1.0"
  else
    fail "(c) latest tag wrong (describe-like?): $tagline"
  fi
) || true

# ---- (d) no network commands in the lib ------------------------------------
(
  # strip comment lines, then look for an actual git ls-remote / fetch call
  if grep -vE '^[[:space:]]*#' "$LIB" | grep -qE 'ls-remote|[[:space:]]fetch[[:space:]]'; then
    fail "(d) lib appears to use a network git command"
  else
    pass "(d) no network commands (ls-remote/fetch) in lib"
  fi
) || true

# ---- (e) SessionStart injects AFTER index block; only when file exists ------
(
  d="$(mk_repo)"; bootstrap_repo "$d"
  out="$(run_session_start "$d")"
  idx_line="$(printf '%s\n' "$out" | grep -n '### trail/index.md' | head -1 | cut -d: -f1)"
  snap_line="$(printf '%s\n' "$out" | grep -n 'git-snapshot.md (자동' | head -1 | cut -d: -f1)"
  if [ -n "$idx_line" ] && [ -n "$snap_line" ] && [ "$snap_line" -gt "$idx_line" ]; then
    pass "(e) snapshot block injected AFTER index block"
  else
    fail "(e) injection order wrong (idx=$idx_line snap=$snap_line)"
  fi
  # early-exit: no trail/index.md → no injection
  d2="$(mk_repo)"; mkdir -p "$d2/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"test"}' > "$d2/.rein/project.json"
  out2="$(run_session_start "$d2")"
  if printf '%s\n' "$out2" | grep -qF 'git-snapshot.md (자동'; then
    fail "(e) early-exit still injected snapshot"
  else
    pass "(e) early-exit (no index) → no injection"
  fi
) || true

# ---- (f) Stop advisory positive/negative + non-blocking --------------------
(
  # positive: hand-written volatile number → advisory + exit 0
  d="$(mk_repo)"; bootstrap_repo "$d"
  printf '# index\n\n## 상태\n\n- dev 미push 5건 진행 중\n' > "$d/trail/index.md"
  touch "$d/trail/dod/.session-has-src-edit" 2>/dev/null || { mkdir -p "$d/trail/dod"; touch "$d/trail/dod/.session-has-src-edit"; }
  mkdir -p "$d/trail/inbox"; printf '# note\n' > "$d/trail/inbox/$(date +%Y-%m-%d)-x.md"
  so="$d/.so"; se="$d/.se"; run_stop "$d" "$so" "$se"; rc_pos=$?
  if grep -qF '손으로 쓴 git 수치' "$se"; then
    pass "(f) advisory fires on hand-written number"
  else
    fail "(f) advisory did not fire on '미push 5건'"
  fi

  # negative: semantic prose only → no advisory
  d2="$(mk_repo)"; bootstrap_repo "$d2"
  printf '# index\n\n## 상태\n\n- 릴리스 의도 정리, 다음 진입점은 X, 개발 중\n' > "$d2/trail/index.md"
  mkdir -p "$d2/trail/dod"; touch "$d2/trail/dod/.session-has-src-edit"
  mkdir -p "$d2/trail/inbox"; printf '# note\n' > "$d2/trail/inbox/$(date +%Y-%m-%d)-x.md"
  so2="$d2/.so"; se2="$d2/.se"; run_stop "$d2" "$so2" "$se2"; rc_neg=$?
  if grep -qF '손으로 쓴 git 수치' "$se2"; then
    fail "(f) advisory false-positive on semantic prose"
  else
    pass "(f) advisory silent on semantic prose (no false positive)"
  fi

  # non-blocking: both runs exit the same (0) — advisory never changes exit code
  if [ "$rc_pos" = "0" ] && [ "$rc_neg" = "0" ]; then
    pass "(f) advisory is non-blocking (exit 0 in both)"
  else
    fail "(f) exit changed (pos=$rc_pos neg=$rc_neg)"
  fi
) || true

# ---- (g) non-git / failure → stale file removed (fresh-write-or-clear) ------
(
  d="$(mktemp -d "/tmp/gitsnap-nongit-XXXXXX")"; TMP_DIRS+=("$d")
  mkdir -p "$d/.rein/state"
  printf 'STALE\n' > "$d/$SNAP_REL"          # pre-existing stale file, NOT a git repo
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  if [ -f "$d/$SNAP_REL" ]; then
    fail "(g) stale file survived in non-git dir"
  else
    pass "(g) non-git → stale file removed (fresh-write-or-clear)"
  fi
) || true

# ---- (g2) empty git repo (unborn HEAD) → stale file removed -----------------
(
  d="$(mktemp -d "/tmp/gitsnap-empty-XXXXXX")"; TMP_DIRS+=("$d")
  git -C "$d" init -q 2>/dev/null            # git repo but NO commit (unborn HEAD)
  mkdir -p "$d/.rein/state"
  printf 'STALE\n' > "$d/$SNAP_REL"
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  if [ -f "$d/$SNAP_REL" ]; then
    fail "(g2) empty-repo wrote snapshot with empty HEAD (stale not cleared)"
  else
    pass "(g2) empty repo (unborn HEAD) → stale file removed"
  fi
) || true

# ---- (h) detached HEAD → label + no origin/HEAD comparison -----------------
(
  d="$(mk_repo)"
  echo b > "$d/b.txt"; git -C "$d" add b.txt
  GIT_COMMITTER_DATE="2026-01-02T00:00:00" GIT_AUTHOR_DATE="2026-01-02T00:00:00" \
    git -C "$d" commit -q -m second
  git -C "$d" checkout -q --detach HEAD
  ( . "$LIB" && rein_write_git_snapshot "$d" )
  bline="$(grep '^- branch:' "$d/$SNAP_REL")"
  abline="$(grep 'ahead/behind:' "$d/$SNAP_REL")"
  if printf '%s' "$bline" | grep -qF 'detached' \
     && printf '%s' "$abline" | grep -qF 'detached' \
     && ! printf '%s' "$abline" | grep -qF 'origin/HEAD'; then
    pass "(h) detached HEAD labeled + no origin/HEAD comparison"
  else
    fail "(h) detached handling wrong (branch=$bline ab=$abline)"
  fi
) || true

# ---- (i) prompt-injection hardening: backticks in ref name neutralized -------
(
  d="$(mk_repo)"; bootstrap_repo "$d"
  # git allows backticks in ref names (only newline/control/~/^/space/.. forbidden).
  if git -C "$d" checkout -q -b 'evil```fence-break' 2>/dev/null; then
    ( . "$LIB" && rein_write_git_snapshot "$d" )
    if grep -qF '`' "$d/$SNAP_REL"; then
      fail "(i) backtick survived in snapshot body (fence-break risk)"
    else
      pass "(i) backticks stripped from git-derived branch value"
    fi
    out="$(run_session_start "$d")"
    # The snapshot block must use a ~~~ fence; and no triple-backtick may appear
    # AFTER that fence opens (the index block above legitimately uses ``` , so we
    # only inspect the snapshot tail).
    snap_tail="$(printf '%s\n' "$out" | sed -n '/~~~markdown/,$p')"
    if [ -n "$snap_tail" ] && ! printf '%s\n' "$snap_tail" | grep -qF '```'; then
      pass "(i) snapshot injected inside a ~~~ fence (no fence-breaking backticks)"
    else
      fail "(i) snapshot injection fence not hardened"
    fi
  else
    fail "(i) could not create backtick branch fixture (git rejected name?)"
  fi
) || true

# ---- codex Low: index-less + trail dir → Stop regenerates, SessionStart skips
(
  d="$(mk_repo)"; mkdir -p "$d/trail" "$d/.rein"
  printf '%s' '{"mode":"plugin","scope":"project","version":"test"}' > "$d/.rein/project.json"
  # NO trail/index.md
  out="$(run_session_start "$d")"
  if printf '%s\n' "$out" | grep -qF 'git-snapshot.md (자동'; then
    fail "(low) SessionStart injected despite missing index"
  else
    pass "(low) index-less → SessionStart injection skipped"
  fi
  so="$d/.so"; se="$d/.se"; run_stop "$d" "$so" "$se"
  if [ -f "$d/$SNAP_REL" ]; then
    pass "(low) index-less → Stop still regenerated snapshot"
  else
    fail "(low) Stop did not regenerate snapshot in index-less repo"
  fi
) || true

# ---- Stop High #1: no-source-edit session still refreshes the snapshot ------
(
  d="$(mk_repo)"; bootstrap_repo "$d"
  # NO .session-has-src-edit marker → stop-gate hits the line-158 early exit.
  rm -f "$d/trail/dod/.session-has-src-edit" 2>/dev/null
  mkdir -p "$d/.rein/state"
  printf 'STALE-SENTINEL\n' > "$d/$SNAP_REL"   # pre-existing stale snapshot
  so="$d/.so"; se="$d/.se"; run_stop "$d" "$so" "$se"
  if [ -f "$d/$SNAP_REL" ] && ! grep -qF 'STALE-SENTINEL' "$d/$SNAP_REL" \
     && grep -qF 'branch:' "$d/$SNAP_REL"; then
    pass "(high) no-source-edit session REGENERATED snapshot (stale replaced) before line-158 exit"
  else
    fail "(high) snapshot NOT regenerated in no-source-edit session"
  fi
) || true

echo ""
FAIL="$(wc -l < "$FAILFILE" 2>/dev/null | tr -d ' ')"
case "$FAIL" in *[!0-9]*|'') FAIL=0 ;; esac
if [ "$FAIL" -eq 0 ]; then
  echo "test-git-snapshot.sh: ALL PASSED"
  exit 0
else
  echo "test-git-snapshot.sh: ${FAIL} FAILED" >&2
  exit 1
fi
