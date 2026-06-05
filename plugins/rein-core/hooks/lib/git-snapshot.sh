#!/usr/bin/env bash
# Plugin helper — authoritative git-fact snapshot for session state.
#
# Writes <project_dir>/.rein/state/git-snapshot.md (gitignored, regenerated
# every session by SessionStart + Stop). The snapshot is the SSOT for objective
# git facts so trail/index.md narrative never hand-maintains them (and thus
# can't drift). See docs/specs/2026-06-05-session-state-git-snapshot.md.
#
# Usage (source from SessionStart / Stop hooks):
#   . "$SCRIPT_DIR/lib/git-snapshot.sh"
#   rein_write_git_snapshot "$PROJECT_DIR"
#
# Function:
#   rein_write_git_snapshot <project_dir>
#       Regenerate the snapshot file atomically (tmp -> mv). Always non-blocking
#       (return 0). Network is NEVER used (no ls-remote / fetch) — ahead/behind
#       is a LOCAL remote-tracking snapshot, not remote truth.
#
#       fresh-write-or-clear contract: on success, atomically replace with fresh
#       content; if the dir is not a git repo, or computation/write fails, the
#       EXISTING stale file is removed (rm -f). Invariant: "a fresh file, or no
#       file at all" — never a stale file. Callers inject only when the file
#       exists, so a stale injection is structurally impossible.
#
#       Fields: branch (detached-aware) / HEAD short sha / clean|dirty(N) /
#       ahead·behind (vs local origin/<branch>) / latest tag (newest-created
#       local, NOT highest semver) / UTC generation timestamp.

# BC-INFO1 env hygiene: inherited GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR /
# GIT_INDEX_FILE could latch a DECOY repo, so a snapshot taken with project_dir=A
# would record repo B's facts. Since this snapshot is the authoritative SSOT,
# that is a blocking correctness bug — strip those vars for every git call.
# Mirrors the same defense in lib/project-dir.sh. GIT_CEILING_DIRECTORIES is kept
# (it can only narrow discovery, never redirect it).
_rein_git_clean() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

rein_write_git_snapshot() {
  local project_dir="${1:-${PWD:-.}}"
  local snapshot_file="$project_dir/.rein/state/git-snapshot.md"

  # Not a git repo (or git unavailable) → clear any stale file, no-op.
  if ! _rein_git_clean -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rm -f "$snapshot_file" 2>/dev/null
    return 0
  fi

  # Unborn HEAD (empty repo, no commit yet) — facts can't be computed. Honor the
  # fresh-write-or-clear contract: clear any stale file rather than writing a
  # snapshot with an empty HEAD (codex Medium).
  if ! _rein_git_clean -C "$project_dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    rm -f "$snapshot_file" 2>/dev/null
    return 0
  fi

  # --- collect facts (all local; no network) ---
  local short_sha branch wt_line ab_line tag_line ts changed branch_display

  short_sha=$(_rein_git_clean -C "$project_dir" rev-parse --short HEAD 2>/dev/null) || short_sha=""

  # branch — detached-aware. symbolic-ref fails on detached HEAD; we label it
  # explicitly rather than using rev-parse --abbrev-ref's bogus "HEAD".
  if branch=$(_rein_git_clean -C "$project_dir" symbolic-ref -q --short HEAD 2>/dev/null) && [ -n "$branch" ]; then
    branch_display="$branch"
  else
    branch=""
    branch_display="detached (HEAD ${short_sha})"
  fi

  # dirty/clean — count porcelain lines.
  changed=$(_rein_git_clean -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  case "$changed" in *[!0-9]*|'') changed=0 ;; esac
  if [ "$changed" -eq 0 ]; then
    wt_line="clean"
  else
    wt_line="dirty (${changed} changed)"
  fi

  # ahead/behind — local origin ref only (no network). right=ahead, left=behind.
  if [ -z "$branch" ]; then
    ab_line="detached — no branch tracking"
  elif _rein_git_clean -C "$project_dir" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    local lr left right
    lr=$(_rein_git_clean -C "$project_dir" rev-list --left-right --count "origin/$branch...$branch" 2>/dev/null)
    left=$(printf '%s' "$lr" | awk '{print $1}')
    right=$(printf '%s' "$lr" | awk '{print $2}')
    case "$left" in *[!0-9]*|'') left=0 ;; esac
    case "$right" in *[!0-9]*|'') right=0 ;; esac
    ab_line="ahead ${right} / behind ${left} (vs origin/${branch}, 로컬)"
  else
    ab_line="no local origin/${branch} ref"
  fi

  # latest tag — newest-created LOCAL tag (NOT highest semver). describe is
  # wrong here (it reports the nearest ancestor tag, a different meaning).
  tag_line=$(_rein_git_clean -C "$project_dir" tag --sort=-creatordate 2>/dev/null | head -1)
  [ -n "$tag_line" ] || tag_line="(none)"

  ts=$(date -u +%FT%TZ 2>/dev/null) || ts=""

  # Security: neutralize backticks in git-derived free-text (branch / tag). A ref
  # name may legally contain ` / ``` / $() (git only forbids newline/control/~/^/
  # space/etc.), and this snapshot is injected inside a markdown fence in the
  # agent context — a triple-backtick in a ref name would otherwise close the
  # fence early and surface attacker-controlled text outside it. Stripping at the
  # source keeps the file-at-rest safe for every consumer (the injection fence is
  # a second layer). Other fields are sha/numeric/timestamp (no free text).
  local _bt='`'
  branch_display="${branch_display//$_bt/}"
  tag_line="${tag_line//$_bt/}"
  # ab_line embeds the RAW branch name (e.g. "no local origin/<branch> ref" /
  # "vs origin/<branch>"); the raw name is required for the git lookups above but
  # must be neutralized before it lands in the written text.
  ab_line="${ab_line//$_bt/}"

  # --- atomic write (fresh-write-or-clear: success path) ---
  if ! mkdir -p "$project_dir/.rein/state" 2>/dev/null; then
    rm -f "$snapshot_file" 2>/dev/null
    return 0
  fi
  local tmp="${snapshot_file}.tmp.$$"
  {
    printf '# git 상태 스냅샷 (자동 생성 — git 권위본)\n\n'
    printf '> 훅이 git 에서 직접 생성. index.md 서술과 다르면 **이 스냅샷(궁극적으로 살아있는 git)이 권위본**.\n'
    printf '> ahead/behind 는 **로컬 추적 스냅샷** — 원격 진실 아님(네트워크 조회 안 함).\n\n'
    printf -- '- branch: %s\n' "$branch_display"
    printf -- '- HEAD: %s\n' "$short_sha"
    printf -- '- working tree: %s\n' "$wt_line"
    printf -- '- ahead/behind: %s\n' "$ab_line"
    printf -- '- 최신 태그(로컬 최근 생성, 최고 semver 아님): %s\n' "$tag_line"
    printf -- '- 생성 시각(UTC): %s\n' "$ts"
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv "$tmp" "$snapshot_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; rm -f "$snapshot_file" 2>/dev/null; }
  else
    # write failed → fresh-write-or-clear: never leave a stale file.
    rm -f "$tmp" 2>/dev/null
    rm -f "$snapshot_file" 2>/dev/null
  fi
  return 0
}
