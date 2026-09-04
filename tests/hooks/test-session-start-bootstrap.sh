#!/usr/bin/env bash
# test-session-start-bootstrap.sh
#
# Verifies the SessionStart bootstrap flow (v1.3.0 BG-A six-branch model):
#   A   — non-git project cwd → degraded marker `non-git-dir`, no mutation
#   B   — uninitialized git repo + safe path → auto-bootstrap fires (creates
#          trail/, .rein/project.json with plugin.json version)
#   C   — approved helper invocation (direct rein-bootstrap-project.py)
#          remains the contract for explicit/manual bootstrap callers
#   D   — initialized repo is silent on next SessionStart
#   E   — plugin cache path is hook-silent and Python helper refuses it
#   F   — exact ~/.claude/plugins root refused by Python helper
#   G   — partial init (.rein only or trail only) keeps prompting per BG-1
#   H   — REIN_NO_AUTO_BOOTSTRAP=1 → degraded marker `user-opt-out`
#   I   — git binary missing (PATH stripped) → degraded marker `git-missing`
#   K   — $PWD and the hook envelope's stdin.cwd
#          resolve to DIFFERENT non-git folders → the degraded marker AND
#          the rendered guidance both land under the envelope-resolved dir
#          (the shared resolver's own resolution), not under $PWD.
#   N   — GIT_DIR poisoning: $PWD is a git repo, envelope cwd is a different
#          non-git dir, GIT_DIR points at the $PWD repo's .git — branch 3's
#          git check must not honor the poisoned GIT_DIR.
#   O   — TMPDIR names a nonexistent directory — guidance + marker must
#          still be produced (no temp-file dependency).
#   P   — non-git dir whose name contains a literal tab byte — guidance +
#          degraded marker must land under the FULL path, not truncated at
#          the tab.
#   Q   — non-git dir whose name ENDS in a literal LF byte — guidance +
#          degraded marker must land under the FULL path (trailing LF
#          intact), not silently dropped by a resolution failure.
#   R   — fresh git repo + stale non-git-dir marker under an unwritable
#          .claude/cache (bootstrap script exits 4, DEGRADED_MARKER_STUCK_
#          EXIT) — auto-bootstrap branch must not relabel this as
#          bootstrap-refused; repo-local state lands, marker stays
#          untouched, exit 0. stdout is exactly ONE line containing both the
#          Korean and English recovery sentences (joined with " / ") and the
#          marker path rendered through `printf %q`.
#   S   — same exit-4 scenario as R, but the git repo's directory name
#          contains a literal LF AND POSIXLY_CORRECT=1 is exported for the
#          hook invocation — POSIX-mode `echo` must not split the `printf %q`
#          rendering of the LF-bearing marker path into two physical lines.
#   T   — bootstrapped repo (rc=0) whose .gitignore predates the
#          file-shaped runtime patterns (/.rein/state.json et al) — the
#          rc=0 branch heals it via `--ensure-gitignore`, silently.
#   U   — bootstrapped repo (rc=0) whose .gitignore already has every
#          runtime pattern — the heal call is a true no-op (byte-identical).
#
# BG-H (v1.3.0): Fixture A/B assertions invert. Pre-BG-A behaviour was
# "no mutation in either case" — Claude was expected to ask the user before
# anything ran. v1.3.0 replaces that with auto-bootstrap on safe git repos
# and degraded markers on the other branches.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-bootstrap.sh"
HELPER="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"
PLUGIN_MANIFEST="$PROJECT_DIR/plugins/rein-core/.claude-plugin/plugin.json"

[ -x "$HOOK" ] || { echo "FAIL: missing executable hook: $HOOK" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "FAIL: missing executable helper: $HELPER" >&2; exit 1; }
[ -f "$PLUGIN_MANIFEST" ] || { echo "FAIL: missing plugin manifest: $PLUGIN_MANIFEST" >&2; exit 1; }

# Read expected version from the plugin manifest — BG-F (v1.3.0) makes the
# bootstrap helper default `--version` track plugin.json, and BG-A passes it
# explicitly. Tests must derive the expected value the same way to stay
# correct across version bumps.
PLUGIN_VERSION="$(python3 -c "import json,sys; print(json.load(open('$PLUGIN_MANIFEST'))['version'])")"
[ -n "$PLUGIN_VERSION" ] || { echo "FAIL: cannot read plugin version" >&2; exit 1; }

TMP="$(mktemp -d -t rein-session-bootstrap-XXXXXX)"
# chmod -R u+w before rm -rf: fixture R chmod's a subdirectory 555 (and
# restores it on success), but a failure mid-fixture must not leave the trap
# unable to remove the tree.
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ok: $1"; }

run_hook() {
  local cwd="$1" out="$2"
  printf '{"cwd":"%s"}\n' "$cwd" | (
    cd "$cwd"
    CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
  ) >"$out"
}

run_hook_env() {
  # Like run_hook, but allow caller to override env (e.g. REIN_NO_AUTO_BOOTSTRAP,
  # PATH for git-missing simulation). $1=cwd $2=out $3=env-prefix
  local cwd="$1" out="$2" env_prefix="$3"
  printf '{"cwd":"%s"}\n' "$cwd" | (
    cd "$cwd"
    # shellcheck disable=SC2086
    env $env_prefix CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
  ) >"$out"
}

json_cwd_envelope() {
  # Build a {"cwd": ...} envelope via json.dumps. A raw tab byte embedded in
  # a printf-built JSON string value is invalid JSON and would be rejected
  # by the parser — json.dumps escapes it correctly.
  python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1]}))' "$1"
}

run_hook_from_envelope() {
  # Like run_hook, but takes a pre-built JSON envelope instead of a bare cwd
  # (needed for cwd values that printf-built JSON cannot represent safely).
  local envelope="$1" cwd="$2" out="$3"
  printf '%s\n' "$envelope" | (
    cd "$cwd"
    CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
  ) >"$out"
}

run_hook_from_envelope_env() {
  # Like run_hook_from_envelope, but allow caller to override env (e.g.
  # POSIXLY_CORRECT=1 for fixture S).
  local envelope="$1" cwd="$2" out="$3" env_prefix="$4"
  printf '%s\n' "$envelope" | (
    cd "$cwd"
    # shellcheck disable=SC2086
    env $env_prefix CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
  ) >"$out"
}

# A: non-git project cwd → BG-A branch 3 writes degraded marker `non-git-dir`.
#
# Resolution chain: bootstrap-check.sh consumes stdin.cwd → no git root → uses
# stdin.cwd verbatim → rc=10 (trail+marker missing, path safe). BG-A then
# resolves PROJECT_DIR via project-dir.sh which (CLAUDE_PLUGIN_ROOT set)
# tries `git rev-parse` from $PWD → fails → falls back to $PWD = $TMP/non-git.
# `git -C $PROJECT_DIR rev-parse` in BG-A branch 3 also fails → marker written.
mkdir -p "$TMP/non-git"
run_hook "$TMP/non-git" "$TMP/non-git.out"
[ -f "$TMP/non-git/.claude/cache/.rein-session-degraded" ] \
  || fail "A: degraded marker not created in non-git dir"
MARKER_A="$(cat "$TMP/non-git/.claude/cache/.rein-session-degraded")"
[ "$MARKER_A" = "non-git-dir" ] \
  || fail "A: degraded marker reason mismatch (got '$MARKER_A', want 'non-git-dir')"
grep -q "저장소가 아니" "$TMP/non-git.out" \
  || fail "A: non-git guidance line missing (expected '저장소가 아니')"
# git-required-onboarding DoD: the guidance must instruct the assistant to
# ask for approval FIRST, name the exact recovery command (git init), and
# give the absolute bootstrap script path so it is copy-pasteable — the same
# three things lib/bootstrap-check.sh's advisory must also say (parity is
# asserted in test-user-prompt-submit-bootstrap-advisory.sh).
grep -q "FIRST" "$TMP/non-git.out" \
  || fail "A: approval instruction missing (expected 'FIRST')"
grep -q "git init" "$TMP/non-git.out" \
  || fail "A: git init instruction missing"
grep -qF "$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py" "$TMP/non-git.out" \
  || fail "A: absolute bootstrap script path missing"
[ ! -e "$TMP/non-git/trail" ] \
  || fail "A: degraded branch must not create trail/"
[ ! -e "$TMP/non-git/.rein" ] \
  || fail "A: degraded branch must not create .rein/"
ok "A: non-git project → degraded marker (non-git-dir), approval-gated guidance, no trail/.rein mutation"

# B: uninitialized git repo + safe path → BG-A branch 4 auto-bootstraps.
REPO="$TMP/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q )
run_hook "$REPO" "$TMP/repo.out"
[ -d "$REPO/trail" ] || fail "B: auto-bootstrap should create trail/"
[ -f "$REPO/.rein/project.json" ] \
  || fail "B: auto-bootstrap should create .rein/project.json"
[ -f "$REPO/trail/index.md" ] \
  || fail "B: auto-bootstrap should create trail/index.md"
[ -f "$REPO/trail/inbox/.gitkeep" ] \
  || fail "B: auto-bootstrap should populate trail subdirs"
[ ! -f "$REPO/.claude/cache/.rein-session-degraded" ] \
  || fail "B: degraded marker must be absent after successful auto-bootstrap"
python3 - "$REPO/.rein/project.json" "$PLUGIN_VERSION" <<'PY' || fail "B: project.json contents invalid"
import json, sys
data = json.load(open(sys.argv[1]))
want_version = sys.argv[2]
# BG-A invokes rein-bootstrap-project.py with --project-dir + --version only,
# so --scope defaults to the helper's argparse default ("plugin"). Fixture C
# below still exercises an explicit --scope project caller.
assert data["mode"] == "plugin", data
assert data["scope"] == "plugin", data
assert data["version"] == want_version, (data, want_version)
PY
grep -q "bootstrap completed automatically" "$TMP/repo.out" \
  || fail "B: auto-bootstrap success notice missing on stdout"
ok "B: uninitialized git repo → auto-bootstrap (version $PLUGIN_VERSION), no degraded marker"

# C: approved helper bootstraps repo-local state only.
#
# Fixture C still exercises the *direct* helper invocation (not the hook) to
# preserve the manual/explicit bootstrap path's contract. We use a fresh repo
# so we are not asserting on the auto-bootstrapped state from B.
REPO_C="$TMP/repo-c"
mkdir -p "$REPO_C"
( cd "$REPO_C" && git init -q )
python3 "$HELPER" --project-dir "$REPO_C" --scope project --version 1.0.0 >"$TMP/helper-c.out"
[ -f "$REPO_C/.rein/project.json" ] || fail "C: .rein/project.json missing"
[ -f "$REPO_C/.rein/policy/hooks.yaml" ] || fail "C: policy hooks.yaml missing"
[ -f "$REPO_C/.rein/policy/rules.yaml" ] || fail "C: policy rules.yaml missing"
[ -f "$REPO_C/trail/index.md" ] || fail "C: trail/index.md missing"
[ -f "$REPO_C/trail/inbox/.gitkeep" ] || fail "C: trail/inbox/.gitkeep missing"
python3 - "$REPO_C/.rein/project.json" <<'PY' || fail "C: project.json invalid"
import json
import sys
data = json.load(open(sys.argv[1]))
assert data["mode"] == "plugin", data
assert data["scope"] == "project", data
assert data["version"] == "1.0.0", data
PY
ok "C: approved helper bootstraps repo-local state"

# D: initialized repo is silent on next SessionStart.
#
# After B auto-bootstrapped $REPO, a second SessionStart on the same repo
# should hit bootstrap_check rc=0 and exit silently.
#
# ONBOARD-1: the rc=0 path now emits a one-time first-session backfill primer
# when the .rein/.onboarded marker is absent (SCOPE-BACKFILL; covered by
# test-onboarding-primer.sh). Fixture B auto-bootstraps via the read-only
# bootstrap hook, which never writes that marker (the rules hook does, and this
# test never runs it). Seed the marker here so D asserts only the rc=0
# degraded-clear silence, representing an already-onboarded user.
printf 'onboarded=2026-01-01T00:00:00\nversion=1.0.0\n' > "$REPO/.rein/.onboarded"
run_hook "$REPO" "$TMP/repo-initialized.out"
[ ! -s "$TMP/repo-initialized.out" ] || fail "D: initialized repo should be silent"
ok "D: initialized repo silent"

# E: plugin cache path is ignored by hook and refused by helper.
#
# v1.1.1 spec: bash helper narrowed cache-path predicate to the explicit
# `~/.claude/plugins/cache/` prefix. Path under `cache/` is the canonical
# fixture for the hook-side silent skip (bootstrap-check returns rc=11 for
# unsafe; BG-A only branches on rc=10 so unsafe paths remain silent).
#
# The Python helper retains broader refusal coverage — see §F.
CACHE_REPO="$TMP/home/.claude/plugins/cache/rein-dev/cache-repo"
mkdir -p "$CACHE_REPO"
( cd "$CACHE_REPO" && git init -q )
run_hook_with_home() {
  local cwd="$1" out="$2"
  printf '{"cwd":"%s"}\n' "$cwd" | (
    cd "$cwd"
    HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
  ) >"$out"
}
run_hook_with_home "$CACHE_REPO" "$TMP/cache.out"
[ ! -s "$TMP/cache.out" ] || fail "E: plugin cache repo should not prompt"
[ ! -e "$CACHE_REPO/trail" ] || fail "E: hook must not create trail in plugin cache"
# Marketplaces path (broader v1.1.0 pattern): hook now prompts (helper allows
# the path through), but the Python bootstrap script still refuses it.
MARKET_REPO="$TMP/home/.claude/plugins/marketplaces/rein-dev/cache-repo"
mkdir -p "$MARKET_REPO"
( cd "$MARKET_REPO" && git init -q )
set +e
python3 "$HELPER" --project-dir "$MARKET_REPO" >"$TMP/market-helper.out" 2>"$TMP/market-helper.err"
MARKET_RC=$?
set -e
[ "$MARKET_RC" != "0" ] || fail "E: Python bootstrap helper should refuse marketplaces path"
grep -q "refusing to bootstrap" "$TMP/market-helper.err" \
  || fail "E: Python helper refusal message missing for marketplaces path"
[ ! -e "$MARKET_REPO/trail" ] || fail "E: Python helper must not create trail in marketplaces path"
set +e
python3 "$HELPER" --project-dir "$CACHE_REPO" >"$TMP/cache-helper.out" 2>"$TMP/cache-helper.err"
CACHE_RC=$?
set -e
[ "$CACHE_RC" != "0" ] || fail "E: Python bootstrap helper should refuse plugin cache path"
grep -q "refusing to bootstrap" "$TMP/cache-helper.err" \
  || fail "E: Python helper refusal message missing for cache path"
[ ! -e "$CACHE_REPO/trail" ] || fail "E: Python helper must not create trail in plugin cache"
ok "E: plugin cache hook-silent + Python script refuses cache+marketplaces"

# F: exact ~/.claude/plugins root is also protected by the Python script.
PLUGIN_ROOT_REPO="$TMP/home/.claude/plugins"
set +e
python3 "$HELPER" --project-dir "$PLUGIN_ROOT_REPO" >"$TMP/plugins-root.out" 2>"$TMP/plugins-root.err"
ROOT_RC=$?
set -e
[ "$ROOT_RC" != "0" ] || fail "F: helper should refuse exact .claude/plugins path"
grep -q "refusing to bootstrap" "$TMP/plugins-root.err" \
  || fail "F: exact plugin root refusal message missing"
ok "F: exact .claude/plugins path refused"

# G: partial init.
#
# v1.2.0 BG-1 contract: both trail/ AND .rein/project.json must be present for
# bootstrap_check to treat the repo as bootstrapped. Either alone is partial
# state, so bootstrap_check returns rc=10, BG-A takes over.
#
# v1.3.0 BG-A change: rc=10 no longer "prompts and exits" — it auto-bootstraps
# when on a git repo + safe path. So a partial repo + git initialized hits
# BG-A branch 4 (auto-bootstrap). bootstrap helper is idempotent (creates
# missing files only) so partial state converges to full state.
#
#   G(a): .rein/project.json present, trail/ absent → auto-bootstrap fills
#         trail/, leaves project.json untouched (write_text_if_missing).
#   G(b): trail/ present, .rein/ absent → auto-bootstrap creates .rein/ and
#         project.json, leaves trail/index.md if it already exists.
PARTIAL_REPO_A="$TMP/repo-partial-a"
mkdir -p "$PARTIAL_REPO_A/.rein"
( cd "$PARTIAL_REPO_A" && git init -q )
# Marker version is intentionally NOT $PLUGIN_VERSION — bootstrap helper's
# write_text_if_missing leaves it untouched, so we can verify it survives.
echo '{"mode":"plugin","scope":"project","version":"0.9.0"}' >"$PARTIAL_REPO_A/.rein/project.json"
run_hook "$PARTIAL_REPO_A" "$TMP/repo-partial-a.out"
[ -d "$PARTIAL_REPO_A/trail" ] \
  || fail "G(a): auto-bootstrap should fill missing trail/"
[ -f "$PARTIAL_REPO_A/trail/index.md" ] \
  || fail "G(a): auto-bootstrap should create trail/index.md"
# project.json must be preserved verbatim (write_text_if_missing).
python3 - "$PARTIAL_REPO_A/.rein/project.json" <<'PY' || fail "G(a): pre-existing project.json was overwritten"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["version"] == "0.9.0", data
PY
grep -q "bootstrap completed automatically" "$TMP/repo-partial-a.out" \
  || fail "G(a): auto-bootstrap success notice missing"
[ ! -f "$PARTIAL_REPO_A/.claude/cache/.rein-session-degraded" ] \
  || fail "G(a): degraded marker must be absent after successful auto-bootstrap"

PARTIAL_REPO_B="$TMP/repo-partial-b"
mkdir -p "$PARTIAL_REPO_B/trail"
( cd "$PARTIAL_REPO_B" && git init -q )
printf '# pre-existing index\n' >"$PARTIAL_REPO_B/trail/index.md"
run_hook "$PARTIAL_REPO_B" "$TMP/repo-partial-b.out"
[ -f "$PARTIAL_REPO_B/.rein/project.json" ] \
  || fail "G(b): auto-bootstrap should create .rein/project.json"
# trail/index.md pre-existing content must be preserved (write_text_if_missing).
grep -q "^# pre-existing index$" "$PARTIAL_REPO_B/trail/index.md" \
  || fail "G(b): auto-bootstrap clobbered pre-existing trail/index.md"
grep -q "bootstrap completed automatically" "$TMP/repo-partial-b.out" \
  || fail "G(b): auto-bootstrap success notice missing"
[ ! -f "$PARTIAL_REPO_B/.claude/cache/.rein-session-degraded" ] \
  || fail "G(b): degraded marker must be absent after successful auto-bootstrap"
ok "G: partial init paths converge via idempotent auto-bootstrap"

# H: REIN_NO_AUTO_BOOTSTRAP=1 opt-out → BG-A branch 1 writes degraded marker.
OPTOUT_REPO="$TMP/repo-optout"
mkdir -p "$OPTOUT_REPO"
( cd "$OPTOUT_REPO" && git init -q )
run_hook_env "$OPTOUT_REPO" "$TMP/optout.out" "REIN_NO_AUTO_BOOTSTRAP=1"
[ -f "$OPTOUT_REPO/.claude/cache/.rein-session-degraded" ] \
  || fail "H: degraded marker not created when REIN_NO_AUTO_BOOTSTRAP=1"
MARKER_H="$(cat "$OPTOUT_REPO/.claude/cache/.rein-session-degraded")"
[ "$MARKER_H" = "user-opt-out" ] \
  || fail "H: degraded marker reason mismatch (got '$MARKER_H', want 'user-opt-out')"
grep -q "REIN_NO_AUTO_BOOTSTRAP=1" "$TMP/optout.out" \
  || fail "H: opt-out notice should mention env var name"
grep -q "감시 기능이 이번 세션에서 비활성화됩니다" "$TMP/optout.out" \
  || fail "H: degraded notice missing (expected '감시 기능이 이번 세션에서 비활성화됩니다')"
[ ! -e "$OPTOUT_REPO/trail" ] \
  || fail "H: opt-out must not bootstrap trail/"
[ ! -e "$OPTOUT_REPO/.rein/project.json" ] \
  || fail "H: opt-out must not create .rein/project.json"
ok "H: REIN_NO_AUTO_BOOTSTRAP=1 → degraded marker (user-opt-out), no mutation"

# I: git binary missing → BG-A branch 2 writes degraded marker `git-missing`.
#
# Simulate by stripping PATH so `command -v git` fails inside the hook. We
# preserve the directories that hold python3 and core utilities (bash, cat,
# mkdir, rm, printf) — the hook itself depends on them.
#
# The strategy: build a sanitized PATH containing only the dirs holding
# python3 + coreutils, but explicitly NOT the dir holding git. On most macOS
# installs python3 lives at /usr/bin/python3 while git lives at the same
# /usr/bin — they cohabit. So instead we create an isolated bin/ with
# symlinks for everything we need (excluding git), and use that as PATH.
ISO_BIN="$TMP/iso-bin"
mkdir -p "$ISO_BIN"
# Full tool set needed by bootstrap-check.sh + session-start-bootstrap.sh +
# degraded-check.sh + project-dir.sh — git is deliberately omitted. mktemp is
# critical: bootstrap-check.sh Step 5 uses it as the authoritative writable
# probe, so without it bootstrap_check returns rc=11 (unwritable) and BG-A
# never branches.
for tool in bash python3 cat mkdir rm printf grep tr wc env sed dirname \
            realpath mktemp ls head tail uname id stat touch chmod find; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$src" ]; then
    ln -sf "$src" "$ISO_BIN/$tool"
  fi
done
# Sanity: verify git is NOT in the isolated bin
[ ! -e "$ISO_BIN/git" ] || fail "I: setup error — git should not be in $ISO_BIN"
# Sanity: verify mktemp IS present (required for bootstrap_check Step 5 to
# reach rc=10 instead of rc=11 unwritable).
[ -e "$ISO_BIN/mktemp" ] || fail "I: setup error — mktemp missing from $ISO_BIN; rc=11 will mask BG-A"

GITMISS_REPO="$TMP/repo-gitmissing"
mkdir -p "$GITMISS_REPO"

# Run the hook with PATH containing only $ISO_BIN. We cannot use the regular
# run_hook helper because we need to strip PATH entirely inside the subshell.
printf '{"cwd":"%s"}\n' "$GITMISS_REPO" | (
  cd "$GITMISS_REPO"
  PATH="$ISO_BIN" CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/gitmissing.out" 2>"$TMP/gitmissing.err" || true

[ -f "$GITMISS_REPO/.claude/cache/.rein-session-degraded" ] \
  || fail "I: degraded marker not created when git binary missing"
MARKER_I="$(cat "$GITMISS_REPO/.claude/cache/.rein-session-degraded")"
[ "$MARKER_I" = "git-missing" ] \
  || fail "I: degraded marker reason mismatch (got '$MARKER_I', want 'git-missing')"
grep -q "설치되어 있지 않아" "$TMP/gitmissing.out" \
  || fail "I: git-missing guidance line missing on stdout (expected '설치되어 있지 않아')"
# Install guidance covers major platforms.
grep -q "macOS" "$TMP/gitmissing.out" \
  || fail "I: install guidance should mention macOS"
grep -q "apt install git" "$TMP/gitmissing.out" \
  || fail "I: install guidance should mention apt install git"
# git-required-onboarding DoD: same approval-gated contract as fixture A —
# ask FIRST, then the absolute bootstrap script path (after git init).
grep -q "FIRST" "$TMP/gitmissing.out" \
  || fail "I: approval instruction missing (expected 'FIRST')"
grep -qF "$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py" "$TMP/gitmissing.out" \
  || fail "I: absolute bootstrap script path missing"
[ ! -e "$GITMISS_REPO/trail" ] \
  || fail "I: git-missing branch must not bootstrap trail/"
[ ! -e "$GITMISS_REPO/.rein" ] \
  || fail "I: git-missing branch must not bootstrap .rein/"
ok "I: git binary missing → degraded marker (git-missing) + approval-gated install guidance, no mutation"

# L: git binary missing (same isolated PATH as I) AND $PWD != envelope cwd →
# marker + guidance must land under the envelope-resolved dir, not $PWD. Same
# defect class as fixture K but for the git-missing branch (2) instead of the
# non-git-dir branch (3) — 5-f requires every branch to key off the single
# bootstrap_check-confirmed path.
L_PWD_DIR="$TMP/l-pwd-dir"
L_ENVELOPE_DIR="$TMP/l-envelope-dir"
mkdir -p "$L_PWD_DIR" "$L_ENVELOPE_DIR"
printf '{"cwd":"%s"}\n' "$L_ENVELOPE_DIR" | (
  cd "$L_PWD_DIR"
  PATH="$ISO_BIN" CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/l.out" 2>"$TMP/l.err" || true
L_ENVELOPE_DIR_REAL="$(cd "$L_ENVELOPE_DIR" && pwd -P)"
[ -f "$L_ENVELOPE_DIR/.claude/cache/.rein-session-degraded" ] \
  || fail "L: degraded marker must land under the envelope-resolved dir, not \$PWD (git-missing)"
[ ! -e "$L_PWD_DIR/.claude/cache/.rein-session-degraded" ] \
  || fail "L: degraded marker must NOT land under \$PWD when it differs from the envelope dir (git-missing)"
grep -qF "$L_ENVELOPE_DIR_REAL" "$TMP/l.out" \
  || fail "L: rendered git-missing guidance must name the envelope-resolved dir"
if grep -qF "$L_PWD_DIR" "$TMP/l.out"; then
  fail "L: rendered git-missing guidance must NOT name \$PWD when it differs from the envelope dir"
fi
ok "L: git binary missing + \$PWD != envelope cwd → marker + guidance both under the envelope-resolved dir"

# J: bootstrap healthy on next SessionStart clears stale degraded marker.
#
# If a previous session wrote a degraded marker (user opt-out / git-missing
# / bootstrap-refused) and the user later resolves the underlying condition
# (manual bootstrap, git installed, env var dropped), the bootstrap_check
# helper now returns rc=0 on the next SessionStart. Without an explicit
# clear in the rc=0 branch, the stale marker would survive and keep
# BG-B/C/D in pass-through forever. This fixture proves the rc=0 branch
# clears the marker.
HEALED_REPO="$TMP/repo-healed"
mkdir -p "$HEALED_REPO/trail/inbox" "$HEALED_REPO/.rein" \
         "$HEALED_REPO/.claude/cache"
( cd "$HEALED_REPO" && git init -q )
# Seed a bootstrapped layout (trail/ + .rein/project.json) so bootstrap_check
# returns rc=0.
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
  > "$HEALED_REPO/.rein/project.json"
printf '# index\n' > "$HEALED_REPO/trail/index.md"
# Seed a stale degraded marker (as if the previous session had been opt-out
# but the user has since cleared REIN_NO_AUTO_BOOTSTRAP=1).
printf 'user-opt-out\n' > "$HEALED_REPO/.claude/cache/.rein-session-degraded"
[ -f "$HEALED_REPO/.claude/cache/.rein-session-degraded" ] \
  || fail "J: setup error — stale marker not seeded"
# ONBOARD-1: seed the onboarded marker so the rc=0 backfill primer
# (SCOPE-BACKFILL, covered by test-onboarding-primer.sh) does not fire here.
# This fixture asserts only the degraded-clear rc=0 silence for an
# already-onboarded user.
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$HEALED_REPO/.rein/.onboarded"
run_hook "$HEALED_REPO" "$TMP/repo-healed.out"
[ ! -f "$HEALED_REPO/.claude/cache/.rein-session-degraded" ] \
  || fail "J: stale degraded marker must be cleared when bootstrap is healthy (rc=0 path)"
# rc=0 path is silent — no stdout chatter expected.
[ ! -s "$TMP/repo-healed.out" ] \
  || fail "J: rc=0 path must remain silent on stdout"
ok "J: healthy bootstrap on rc=0 path clears stale degraded marker"

# T: heal-existing-project (2026-09-04, rein-state-gitignore-digest DoD) — a
# bootstrapped repo (trail/index.md + .rein/project.json present, so
# bootstrap_check returns rc=0) whose .gitignore predates the file-shaped
# runtime patterns (/.rein/state.json etc — REIN_RUNTIME_GITIGNORE_PATTERNS
# grew after this repo was bootstrapped). The rc=0 branch must call
# `rein-bootstrap-project.py --ensure-gitignore` so the missing pattern gets
# appended without a full re-bootstrap, and the hook's own stdout stays
# silent (the call is wrapped `>/dev/null 2>&1`).
T_REPO="$TMP/repo-heal-missing"
mkdir -p "$T_REPO/trail/inbox" "$T_REPO/.rein"
( cd "$T_REPO" && git init -q )
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
  > "$T_REPO/.rein/project.json"
printf '# index\n' > "$T_REPO/trail/index.md"
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$T_REPO/.rein/.onboarded"
# Pre-2026-09-04 .gitignore: has the three directory patterns, missing the
# three file-shaped ones this DoD adds.
printf 'node_modules/\n/.rein/state/\n/.rein/cache/\n/.rein/logs/\n' > "$T_REPO/.gitignore"
run_hook "$T_REPO" "$TMP/repo-heal-missing.out"
[ ! -s "$TMP/repo-heal-missing.out" ] \
  || fail "T: rc=0 heal path must remain silent on stdout"
grep -qxF 'node_modules/' "$T_REPO/.gitignore" \
  || fail "T: pre-existing .gitignore content must be preserved"
for p in '/.rein/state.json' '/.rein/state-pending-*.log' '/.rein/.onboarded'; do
  grep -qF "$p" "$T_REPO/.gitignore" \
    || fail "T: missing pattern '$p' was not healed into .gitignore on the rc=0 path"
done
ok "T: rc=0 path heals a missing runtime .gitignore pattern into an already-bootstrapped repo"

# V: a bootstrapped repo whose .gitignore is a FIFO with no writer — the
# rc=0 heal call must not hang the hook (SessionStart waits on it
# synchronously): the hook finishes within a bound, exits 0, stays silent,
# and the FIFO is left as-is.
V_REPO="$TMP/repo-heal-fifo"
mkdir -p "$V_REPO/trail/inbox" "$V_REPO/.rein"
( cd "$V_REPO" && git init -q )
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
  > "$V_REPO/.rein/project.json"
printf '# index\n' > "$V_REPO/trail/index.md"
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$V_REPO/.rein/.onboarded"
mkfifo "$V_REPO/.gitignore"
( run_hook "$V_REPO" "$TMP/repo-heal-fifo.out"; echo "$?" > "$TMP/repo-heal-fifo.rc" ) &
V_PID=$!
V_WAITED=0
while kill -0 "$V_PID" 2>/dev/null && [ "$V_WAITED" -lt 80 ]; do sleep 0.25; V_WAITED=$((V_WAITED+1)); done
if kill -0 "$V_PID" 2>/dev/null; then
  kill "$V_PID" 2>/dev/null; pkill -P "$V_PID" 2>/dev/null
  fail "V: rc=0 heal path hung on a FIFO .gitignore (hook still running after 20s)"
fi
[ "$(cat "$TMP/repo-heal-fifo.rc" 2>/dev/null)" = "0" ] \
  || fail "V: hook must exit 0 even when the heal call is refused"
[ ! -s "$TMP/repo-heal-fifo.out" ] \
  || fail "V: rc=0 heal path must remain silent on stdout with a FIFO .gitignore"
[ -p "$V_REPO/.gitignore" ] || fail "V: FIFO .gitignore must be left untouched"
ok "V: rc=0 path completes within bound and stays silent when .gitignore is a FIFO"

# W: already-bootstrapped repo (rc=0 path) whose stale degraded marker
# cannot be removed (.claude/cache is read-only): the hook must not stay
# silent — it prints the same one-line recovery guidance as the exit-4
# auto-bootstrap branch (R/S), leaves the marker in place, exits 0, and —
# with the primer backfill otherwise eligible (no .rein/.onboarded) — that
# notice is the ONLY stdout line.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: W (rc=0 stuck marker) — running as root, chmod 555 ineffective"
else
  W_REPO="$TMP/repo-rc0-stuck-marker"
  mkdir -p "$W_REPO/trail/inbox" "$W_REPO/.rein" "$W_REPO/.claude/cache"
  ( cd "$W_REPO" && git init -q )
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
    > "$W_REPO/.rein/project.json"
  printf '# index\n' > "$W_REPO/trail/index.md"
  # Deliberately NO .rein/.onboarded: the one-time primer backfill would
  # otherwise be eligible on this run — the stuck notice must still be the
  # only stdout line (the primer is skipped on a run that printed it).
  printf 'node_modules/\n/.rein/state/\n/.rein/cache/\n/.rein/logs/\n/.rein/state.json\n/.rein/state-pending-*.log\n/.rein/.onboarded\n' \
    > "$W_REPO/.gitignore"
  printf '%s\n' "non-git-dir" > "$W_REPO/.claude/cache/.rein-session-degraded"
  chmod 555 "$W_REPO/.claude/cache"
  set +e
  run_hook "$W_REPO" "$TMP/repo-rc0-stuck-marker.out" 2>"$TMP/repo-rc0-stuck-marker.err"
  W_RC=$?
  set -e
  chmod 755 "$W_REPO/.claude/cache" 2>/dev/null || true
  [ "$W_RC" -eq 0 ] || fail "W: rc=0 path with a stuck marker must still exit 0, got $W_RC"
  [ -f "$W_REPO/.claude/cache/.rein-session-degraded" ] \
    || fail "W: the stale marker must still exist (removal failed, must not be papered over)"
  W_LINE_COUNT="$(wc -l < "$TMP/repo-rc0-stuck-marker.out" | tr -d ' ')"
  [ "$W_LINE_COUNT" = "1" ] \
    || fail "W: stdout must be exactly one line when the marker is stuck on the rc=0 path, even with the primer backfill eligible (got $W_LINE_COUNT)"
  printf -v W_MARKER_Q '%q' "$W_REPO/.claude/cache/.rein-session-degraded"
  grep -qF "$W_MARKER_Q" "$TMP/repo-rc0-stuck-marker.out" \
    || fail "W: stdout must contain the %q-rendered marker path"
  grep -q "삭제" "$TMP/repo-rc0-stuck-marker.out" || fail "W: stdout must contain the Korean word 삭제"
  grep -q "세션" "$TMP/repo-rc0-stuck-marker.out" || fail "W: stdout must contain the Korean word 세션"
  ok "W: rc=0 path prints the one-line recovery guidance when the stale marker cannot be removed"
  # Control: once the marker CAN be removed, the same repo's next run prints
  # the primer backfill (several lines) — proving the primer was eligible
  # above and that the one-line result came from the skip, not from the
  # primer being unavailable.
  rm -f "$W_REPO/.claude/cache/.rein-session-degraded"
  run_hook "$W_REPO" "$TMP/repo-rc0-stuck-marker-2.out" 2>/dev/null
  W_LINE_COUNT_2="$(wc -l < "$TMP/repo-rc0-stuck-marker-2.out" | tr -d ' ')"
  [ "$W_LINE_COUNT_2" -ge 2 ] \
    || fail "W(control): with the marker gone the primer backfill should print on the next run (got $W_LINE_COUNT_2 lines)"
  grep -q "삭제" "$TMP/repo-rc0-stuck-marker-2.out" \
    && fail "W(control): no stuck notice once the marker is removable"
  ok "W(control): primer prints on the next run once the marker is gone — the one-line result above came from the skip"

  # W2: a DIRECTORY squatting on the marker name — `rm -f` fails, but the
  # gates' own test (`-f`) does not see a marker, so governance is not
  # disabled and no recovery notice must be printed.
  W2_REPO="$TMP/repo-rc0-marker-dir"
  mkdir -p "$W2_REPO/trail/inbox" "$W2_REPO/.rein" "$W2_REPO/.claude/cache/.rein-session-degraded"
  ( cd "$W2_REPO" && git init -q )
  printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
    > "$W2_REPO/.rein/project.json"
  printf '# index\n' > "$W2_REPO/trail/index.md"
  printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$W2_REPO/.rein/.onboarded"
  printf 'node_modules/\n/.rein/state/\n/.rein/cache/\n/.rein/logs/\n/.rein/state.json\n/.rein/state-pending-*.log\n/.rein/.onboarded\n' \
    > "$W2_REPO/.gitignore"
  set +e
  run_hook "$W2_REPO" "$TMP/repo-rc0-marker-dir.out" 2>/dev/null
  W2_RC=$?
  set -e
  [ "$W2_RC" -eq 0 ] || fail "W2: rc=0 path with a directory on the marker name must exit 0, got $W2_RC"
  [ ! -s "$TMP/repo-rc0-marker-dir.out" ] \
    || fail "W2: no recovery notice when the marker name is a directory (governance is not disabled): $(head -c 200 "$TMP/repo-rc0-marker-dir.out")"
  [ -d "$W2_REPO/.claude/cache/.rein-session-degraded" ] || fail "W2: the directory must be left in place"
  ok "W2: rc=0 path stays silent when a directory squats on the marker name"
fi

# U: a bootstrapped repo whose .gitignore ALREADY has every runtime
# pattern — the rc=0 heal call must be a true no-op (byte-identical file,
# no duplicate lines).
U_REPO="$TMP/repo-heal-complete"
mkdir -p "$U_REPO/trail/inbox" "$U_REPO/.rein"
( cd "$U_REPO" && git init -q )
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
  > "$U_REPO/.rein/project.json"
printf '# index\n' > "$U_REPO/trail/index.md"
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$U_REPO/.rein/.onboarded"
printf 'node_modules/\n/.rein/state/\n/.rein/cache/\n/.rein/logs/\n/.rein/state.json\n/.rein/state-pending-*.log\n/.rein/.onboarded\n' \
  > "$U_REPO/.gitignore"
U_HASH_BEFORE=$(shasum -a 256 "$U_REPO/.gitignore" | awk '{print $1}')
run_hook "$U_REPO" "$TMP/repo-heal-complete.out"
U_HASH_AFTER=$(shasum -a 256 "$U_REPO/.gitignore" | awk '{print $1}')
[ ! -s "$TMP/repo-heal-complete.out" ] \
  || fail "U: rc=0 path must remain silent on stdout"
[ "$U_HASH_BEFORE" = "$U_HASH_AFTER" ] \
  || fail "U: .gitignore must be byte-identical when every pattern is already present"
ok "U: rc=0 path leaves an already-complete .gitignore byte-identical"

# K — $PWD and the hook envelope's stdin.cwd point at DIFFERENT
# non-git folders. bootstrap_check prefers stdin.cwd (K_ENVELOPE_DIR);
# project-dir.sh's resolve_project_dir (this hook's own PROJECT_DIR) falls
# back to $PWD (K_PWD_DIR) since neither directory is a git repo. Before this
# fix, the degraded marker + guidance were written under $PWD while a
# later bootstrap_check call (e.g. UserPromptSubmit, reading the SAME
# envelope) would resolve K_ENVELOPE_DIR, find no marker there, and print
# the generic template — the exact contradiction this DoD exists to close.
K_PWD_DIR="$TMP/k-pwd-dir"
K_ENVELOPE_DIR="$TMP/k-envelope-dir"
mkdir -p "$K_PWD_DIR" "$K_ENVELOPE_DIR"
printf '{"cwd":"%s"}\n' "$K_ENVELOPE_DIR" | (
  cd "$K_PWD_DIR"
  CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/k.out"
K_ENVELOPE_DIR_REAL="$(cd "$K_ENVELOPE_DIR" && pwd -P)"
[ -f "$K_ENVELOPE_DIR/.claude/cache/.rein-session-degraded" ]   || fail "K: degraded marker must land under the envelope-resolved dir, not \$PWD"
[ ! -e "$K_PWD_DIR/.claude/cache/.rein-session-degraded" ]   || fail "K: degraded marker must NOT land under \$PWD when it differs from the envelope dir"
grep -qF "$K_ENVELOPE_DIR_REAL" "$TMP/k.out"   || fail "K: rendered guidance must name the envelope-resolved dir"
if grep -qF "$K_PWD_DIR" "$TMP/k.out"; then
  fail "K: rendered guidance must NOT name \$PWD when it differs from the envelope dir"
fi
ok "K: \$PWD != envelope cwd → marker + guidance both under the envelope-resolved dir"

# M1: $PWD is a FRESH GIT REPO (not bootstrapped), envelope cwd is a
# different NON-GIT folder. 5-f requires the single bootstrap_check-confirmed
# path to drive every judgement — the git-repo $PWD must NOT be silently
# auto-bootstrapped just because it happens to pass the branch-3 git check on
# its own $PWD-based resolution; only the envelope-resolved dir is in play.
M1_A="$TMP/m1-repo-a"
M1_B="$TMP/m1-dir-b"
mkdir -p "$M1_A" "$M1_B"
( cd "$M1_A" && git init -q )
printf '{"cwd":"%s"}\n' "$M1_B" | (
  cd "$M1_A"
  CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/m1.out"
[ ! -e "$M1_A/trail" ] \
  || fail "M1: \$PWD git repo A must NOT be auto-bootstrapped when the envelope cwd resolves elsewhere"
[ ! -e "$M1_A/.rein/project.json" ] \
  || fail "M1: \$PWD git repo A must NOT get .rein/project.json"
[ ! -f "$M1_A/.claude/cache/.rein-session-degraded" ] \
  || fail "M1: \$PWD git repo A must NOT get a degraded marker either"
[ -f "$M1_B/.claude/cache/.rein-session-degraded" ] \
  || fail "M1: envelope non-git dir B must get the degraded marker"
MARKER_M1="$(cat "$M1_B/.claude/cache/.rein-session-degraded")"
[ "$MARKER_M1" = "non-git-dir" ] \
  || fail "M1: degraded marker reason mismatch (got '$MARKER_M1', want 'non-git-dir')"
grep -q "git init" "$TMP/m1.out" || fail "M1: guidance missing 'git init'"
M1_B_REAL="$(cd "$M1_B" && pwd -P)"
grep -qF "$M1_B_REAL" "$TMP/m1.out" || fail "M1: guidance missing envelope dir B's path"
ok "M1: \$PWD git repo A + envelope non-git dir B → marker/guidance under B only, A untouched"

# M2: $PWD is a NON-GIT folder, envelope cwd is a different FRESH GIT REPO
# (not bootstrapped). The envelope-resolved repo must be auto-bootstrapped;
# neither dir gets a degraded marker.
M2_A="$TMP/m2-repo-a"
M2_B="$TMP/m2-dir-b"
mkdir -p "$M2_A" "$M2_B"
( cd "$M2_A" && git init -q )
printf '{"cwd":"%s"}\n' "$M2_A" | (
  cd "$M2_B"
  CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/m2.out"
[ -d "$M2_A/trail" ] \
  || fail "M2: envelope git repo A should be auto-bootstrapped (trail/ missing)"
[ -f "$M2_A/.rein/project.json" ] \
  || fail "M2: envelope git repo A should be auto-bootstrapped (.rein/project.json missing)"
[ ! -f "$M2_A/.claude/cache/.rein-session-degraded" ] \
  || fail "M2: A must not have a degraded marker after auto-bootstrap"
[ ! -e "$M2_B/trail" ] \
  || fail "M2: \$PWD non-git dir B must NOT be bootstrapped"
[ ! -f "$M2_B/.claude/cache/.rein-session-degraded" ] \
  || fail "M2: \$PWD non-git dir B must NOT get a degraded marker"
grep -q "bootstrap completed automatically" "$TMP/m2.out" \
  || fail "M2: auto-bootstrap success notice missing"
ok "M2: \$PWD non-git dir B + envelope git repo A → A auto-bootstrapped, no degraded marker anywhere"

# M3: envelope cwd is an already-bootstrapped git repo carrying a STALE
# degraded marker; $PWD is a different dir entirely. The confirmed path (the
# envelope repo) must still get its stale marker cleared even though $PWD
# differs.
M3_A="$TMP/m3-repo-a"
M3_OTHER="$TMP/m3-other"
mkdir -p "$M3_A/trail/inbox" "$M3_A/.rein" "$M3_A/.claude/cache" "$M3_OTHER"
( cd "$M3_A" && git init -q )
printf '%s' '{"mode":"plugin","scope":"project","version":"1.3.0"}' \
  > "$M3_A/.rein/project.json"
printf '# index\n' > "$M3_A/trail/index.md"
printf 'git-missing\n' > "$M3_A/.claude/cache/.rein-session-degraded"
printf 'onboarded=2026-01-01T00:00:00\nversion=1.3.0\n' > "$M3_A/.rein/.onboarded"
printf '{"cwd":"%s"}\n' "$M3_A" | (
  cd "$M3_OTHER"
  CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/m3.out"
[ ! -f "$M3_A/.claude/cache/.rein-session-degraded" ] \
  || fail "M3: envelope git repo A's stale degraded marker must be cleared even though \$PWD differs"
ok "M3: envelope-resolved bootstrapped repo A with stale marker + \$PWD elsewhere → A's marker cleared"

# N: same layout as M1 ($PWD=git repo A, envelope cwd=non-git B) but
# additionally exports GIT_DIR=A/.git. Without env-stripping, branch 3's
# `git -C $PROJECT_DIR rev-parse` would honor the poisoned GIT_DIR and treat
# non-git B as if it were inside git repo A, letting branch 4 auto-bootstrap
# B without approval.
N_A="$TMP/n-repo-a"
N_B="$TMP/n-dir-b"
mkdir -p "$N_A" "$N_B"
( cd "$N_A" && git init -q )
printf '{"cwd":"%s"}\n' "$N_B" | (
  cd "$N_A"
  GIT_DIR="$N_A/.git" CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/n.out"
[ ! -e "$N_A/trail" ] \
  || fail "N: \$PWD git repo A must NOT be auto-bootstrapped (GIT_DIR poisoning)"
[ ! -f "$N_A/.claude/cache/.rein-session-degraded" ] \
  || fail "N: \$PWD git repo A must NOT get a degraded marker either"
[ -f "$N_B/.claude/cache/.rein-session-degraded" ] \
  || fail "N: envelope non-git dir B must get the degraded marker even with GIT_DIR=A/.git exported"
MARKER_N="$(cat "$N_B/.claude/cache/.rein-session-degraded")"
[ "$MARKER_N" = "non-git-dir" ] \
  || fail "N: degraded marker reason mismatch (got '$MARKER_N', want 'non-git-dir') — GIT_DIR poisoning made B look like a git repo"
[ ! -e "$N_B/trail" ] \
  || fail "N: envelope dir B must NOT be auto-bootstrapped despite the poisoned GIT_DIR"
ok "N: \$PWD git repo A + envelope non-git dir B + GIT_DIR=A/.git exported → B still gets non-git-dir marker, A untouched"

# O: TMPDIR names a nonexistent directory. Guidance + marker must still
# be produced (no temp-file dependency left in this hook).
O_DIR="$TMP/o-nongit"
mkdir -p "$O_DIR"
printf '{"cwd":"%s"}\n' "$O_DIR" | (
  cd "$O_DIR"
  TMPDIR=/nonexistent/dir CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$HOOK"
) >"$TMP/o.out"
[ -f "$O_DIR/.claude/cache/.rein-session-degraded" ] \
  || fail "O: degraded marker not created when TMPDIR is broken"
MARKER_O="$(cat "$O_DIR/.claude/cache/.rein-session-degraded")"
[ "$MARKER_O" = "non-git-dir" ] \
  || fail "O: degraded marker reason mismatch (got '$MARKER_O', want 'non-git-dir')"
grep -q "git init" "$TMP/o.out" || fail "O: guidance missing 'git init' (TMPDIR broken)"
ok "O: TMPDIR=/nonexistent/dir → guidance + marker still produced (no temp-file dependency)"

# P: non-git project dir whose name contains a literal tab byte → the
# degraded marker must be written under the FULL path (not truncated at the
# tab) and the guidance must still print. The envelope is built via
# json_cwd_envelope (json.dumps) since a raw tab in a printf-built JSON
# string value is invalid JSON.
TAB="$(printf '\t')"
P_DIR="$TMP/p-tab${TAB}dir"
mkdir -p "$P_DIR"
P_ENVELOPE="$(json_cwd_envelope "$P_DIR")"
run_hook_from_envelope "$P_ENVELOPE" "$P_DIR" "$TMP/p.out"
[ -f "$P_DIR/.claude/cache/.rein-session-degraded" ] \
  || fail "P: degraded marker not created under the full tab-containing path"
MARKER_P="$(cat "$P_DIR/.claude/cache/.rein-session-degraded")"
[ "$MARKER_P" = "non-git-dir" ] \
  || fail "P: degraded marker reason mismatch (got '$MARKER_P', want 'non-git-dir')"
grep -q "git init" "$TMP/p.out" || fail "P: guidance missing 'git init' (tab-named dir)"
[ ! -e "$P_DIR/trail" ] \
  || fail "P: degraded branch must not create trail/ (tab-named dir)"
[ ! -e "$P_DIR/.rein" ] \
  || fail "P: degraded branch must not create .rein/ (tab-named dir)"
ok "P: tab-named non-git dir → guidance printed + non-git-dir marker written under the FULL path"

# Q: non-git project dir whose name ENDS in a literal LF byte → the degraded
# marker must be written under the FULL path (trailing LF intact), not
# silently dropped by a resolution failure. Built directly under an
# already-`pwd -P`-resolved parent (never via `$(cd "$d" && pwd -P)` on the
# LF-suffixed leaf itself — that capture would suffer the same truncation
# bug this fixture exists to catch).
LF=$'\n'
Q_PARENT="$TMP/q-parent"
mkdir -p "$Q_PARENT"
Q_PARENT_REAL="$(cd "$Q_PARENT" && pwd -P)"
Q_DIR="${Q_PARENT_REAL}/q-lfdir-$$${LF}"
mkdir -p "$Q_DIR"
Q_ENVELOPE="$(json_cwd_envelope "$Q_DIR")"
run_hook_from_envelope "$Q_ENVELOPE" "$Q_DIR" "$TMP/q.out"
[ -f "$Q_DIR/.claude/cache/.rein-session-degraded" ] \
  || fail "Q: degraded marker not created under the full LF-terminated path"
MARKER_Q="$(cat "$Q_DIR/.claude/cache/.rein-session-degraded")"
[ "$MARKER_Q" = "non-git-dir" ] \
  || fail "Q: degraded marker reason mismatch (got '$MARKER_Q', want 'non-git-dir')"
grep -q "git init" "$TMP/q.out" || fail "Q: guidance missing 'git init' (LF-terminated dir)"
[ ! -e "$Q_DIR/trail" ] \
  || fail "Q: degraded branch must not create trail/ (LF-terminated dir)"
[ ! -e "$Q_DIR/.rein" ] \
  || fail "Q: degraded branch must not create .rein/ (LF-terminated dir)"
ok "Q: LF-terminated non-git dir → guidance printed + non-git-dir marker written under the FULL path"

# R: BG-A branch 4 (auto-bootstrap) must branch on the bootstrap script's own
# DEGRADED_MARKER_STUCK_EXIT (4) instead of folding every non-zero exit into
# the generic bootstrap-refusal branch. Fixture: a fresh (un-bootstrapped)
# git repo carrying a STALE non-git-dir marker under .claude/cache, with that
# cache dir made unwritable (555) so the bootstrap script's own marker-clear
# step fails with exit 4 even though trail/ + .rein/project.json get written
# successfully. Skipped when running as root — root bypasses permission bits
# entirely, so exit 4 never reproduces.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: R (exit-4 degraded-marker-stuck branch) — running as root, chmod 555 ineffective"
else
  R_DIR="$TMP/r-repo"
  mkdir -p "$R_DIR"
  ( cd "$R_DIR" && git init -q )
  mkdir -p "$R_DIR/.claude/cache"
  printf '%s\n' "non-git-dir" >"$R_DIR/.claude/cache/.rein-session-degraded"
  chmod 555 "$R_DIR/.claude/cache"
  set +e
  run_hook "$R_DIR" "$TMP/r.out"
  R_RC=$?
  set -e
  chmod 755 "$R_DIR/.claude/cache" 2>/dev/null || true
  [ "$R_RC" -eq 0 ] \
    || fail "R: expected exit 0 from SessionStart even when the bootstrap script hits DEGRADED_MARKER_STUCK_EXIT, got $R_RC"
  [ -f "$R_DIR/trail/index.md" ] \
    || fail "R: trail/index.md must exist — repo-local state was written despite the stuck marker"
  [ -f "$R_DIR/.rein/project.json" ] \
    || fail "R: .rein/project.json must exist — repo-local state was written despite the stuck marker"
  [ -f "$R_DIR/.claude/cache/.rein-session-degraded" ] \
    || fail "R: the stale marker must still exist (removal failed, must not be papered over)"
  MARKER_R="$(head -n 1 "$R_DIR/.claude/cache/.rein-session-degraded")"
  [ "$MARKER_R" = "non-git-dir" ] \
    || fail "R: marker content must remain 'non-git-dir' (not relabelled 'bootstrap-refused'), got '$MARKER_R'"
  grep -qF "$R_DIR/.claude/cache/.rein-session-degraded" "$TMP/r.out" \
    || fail "R: stdout must name the stuck marker's path"
  R_LINE_COUNT="$(wc -l < "$TMP/r.out" | tr -d ' ')"
  [ "$R_LINE_COUNT" = "1" ] \
    || fail "R: stdout must be exactly one line (got $R_LINE_COUNT)"
  R_MARKER_Q="$(printf '%q' "$R_DIR/.claude/cache/.rein-session-degraded")"
  grep -qF "$R_MARKER_Q" "$TMP/r.out" \
    || fail "R: stdout must contain the %q-rendered marker path"
  grep -q "삭제" "$TMP/r.out" \
    || fail "R: stdout must contain the Korean word 삭제"
  grep -q "세션" "$TMP/r.out" \
    || fail "R: stdout must contain the Korean word 세션"
  grep -qi "remove" "$TMP/r.out" \
    || fail "R: stdout must contain the English word 'remove'"
  grep -qi "restart" "$TMP/r.out" \
    || fail "R: stdout must contain the English word 'restart'"
  ok "R: exit-4 (degraded marker stuck) → repo-local state written, marker left untouched, single line with %q-rendered path + KR/EN recovery instructions, exit 0"
fi

# S: same exit-4 (DEGRADED_MARKER_STUCK_EXIT) scenario as R, but (1) the git
# repo's directory name contains a literal LF byte and (2) POSIXLY_CORRECT=1
# is exported for the hook invocation. Under POSIX mode, bash's `echo`
# reinterprets backslash-escape sequences by default — the `printf %q`
# rendering of an LF-bearing path contains a literal `\n` two-char sequence,
# which POSIX-mode `echo` would expand into a real newline, splitting the
# single-line message into two physical lines. `printf '%s\n'` must not.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: S (exit-4 stuck-marker branch, LF dir + POSIXLY_CORRECT=1) — running as root, chmod 555 ineffective"
else
  S_PARENT="$TMP/s-parent"
  mkdir -p "$S_PARENT"
  S_PARENT_REAL="$(cd "$S_PARENT" && pwd -P)"
  S_DIR="${S_PARENT_REAL}/s-lfrepo-$$${LF}"
  mkdir -p "$S_DIR"
  ( cd "$S_DIR" && git init -q )
  mkdir -p "$S_DIR/.claude/cache"
  printf '%s\n' "non-git-dir" >"$S_DIR/.claude/cache/.rein-session-degraded"
  chmod 555 "$S_DIR/.claude/cache"
  S_ENVELOPE="$(json_cwd_envelope "$S_DIR")"
  set +e
  run_hook_from_envelope_env "$S_ENVELOPE" "$S_DIR" "$TMP/s.out" "POSIXLY_CORRECT=1" 2>"$TMP/s.err"
  S_RC=$?
  set -e
  chmod 755 "$S_DIR/.claude/cache" 2>/dev/null || true
  [ "$S_RC" -eq 0 ] \
    || fail "S: expected exit 0 from SessionStart even under POSIXLY_CORRECT=1 with an LF-bearing stuck marker, got $S_RC"
  [ -f "$S_DIR/trail/index.md" ] \
    || fail "S: trail/index.md must exist — repo-local state was written despite the stuck marker"
  [ -f "$S_DIR/.rein/project.json" ] \
    || fail "S: .rein/project.json must exist — repo-local state was written despite the stuck marker"
  [ -f "$S_DIR/.claude/cache/.rein-session-degraded" ] \
    || fail "S: the stale marker must still exist (removal failed, must not be papered over)"
  MARKER_S="$(head -n 1 "$S_DIR/.claude/cache/.rein-session-degraded")"
  [ "$MARKER_S" = "non-git-dir" ] \
    || fail "S: marker content must remain 'non-git-dir' (not relabelled 'bootstrap-refused'), got '$MARKER_S'"
  S_LINE_COUNT="$(wc -l < "$TMP/s.out" | tr -d ' ')"
  [ "$S_LINE_COUNT" = "1" ] \
    || fail "S: stdout must be exactly one line under POSIXLY_CORRECT=1 (got $S_LINE_COUNT)"
  printf -v S_MARKER_Q '%q' "$S_DIR/.claude/cache/.rein-session-degraded"
  grep -qF "$S_MARKER_Q" "$TMP/s.out" \
    || fail "S: stdout must contain the %q-rendered marker path"
  grep -q "삭제" "$TMP/s.out" \
    || fail "S: stdout must contain the Korean word 삭제"
  grep -q "세션" "$TMP/s.out" \
    || fail "S: stdout must contain the Korean word 세션"
  grep -qi "remove" "$TMP/s.out" \
    || fail "S: stdout must contain the English word 'remove'"
  grep -qi "restart" "$TMP/s.out" \
    || fail "S: stdout must contain the English word 'restart'"
  ! grep -qi "Permission denied" "$TMP/s.err" \
    || fail "S: hook stderr must not leak a Permission denied message from the read-only guidance-flag write (got: $(cat "$TMP/s.err"))"
  ok "S: exit-4 + LF-bearing dir + POSIXLY_CORRECT=1 → stdout still exactly one line with %q-rendered path + KR/EN recovery instructions, exit 0, no Permission-denied stderr leak"
fi

echo "test-session-start-bootstrap: OK (26/26 fixtures)"
