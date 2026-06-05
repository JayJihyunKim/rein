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
trap 'rm -rf "$TMP"' EXIT

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
grep -q "git 저장소가 아닙니다" "$TMP/non-git.out" \
  || fail "A: non-git guidance line missing (expected 'git 저장소가 아닙니다')"
grep -q "감시 기능이 이번 세션에서 비활성화됩니다" "$TMP/non-git.out" \
  || fail "A: degraded notice missing (expected '감시 기능이 이번 세션에서 비활성화됩니다')"
[ ! -e "$TMP/non-git/trail" ] \
  || fail "A: degraded branch must not create trail/"
[ ! -e "$TMP/non-git/.rein" ] \
  || fail "A: degraded branch must not create .rein/"
ok "A: non-git project → degraded marker (non-git-dir), no trail/.rein mutation"

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
grep -q "git 가 설치되어 있지 않아" "$TMP/gitmissing.out" \
  || fail "I: git-missing guidance line missing on stdout (expected 'git 가 설치되어 있지 않아')"
# Install guidance covers major platforms.
grep -q "macOS" "$TMP/gitmissing.out" \
  || fail "I: install guidance should mention macOS"
grep -q "apt install git" "$TMP/gitmissing.out" \
  || fail "I: install guidance should mention apt install git"
[ ! -e "$GITMISS_REPO/trail" ] \
  || fail "I: git-missing branch must not bootstrap trail/"
[ ! -e "$GITMISS_REPO/.rein" ] \
  || fail "I: git-missing branch must not bootstrap .rein/"
ok "I: git binary missing → degraded marker (git-missing) + install guidance, no mutation"

# J: bootstrap healthy on next SessionStart clears stale degraded marker.
#
# HIGH-1 fix (codex-review NEEDS-FIX round 1): if a previous session wrote a
# degraded marker (user opt-out / git-missing / bootstrap-refused) and the
# user later resolves the underlying condition (manual bootstrap, git
# installed, env var dropped), the bootstrap_check helper now returns rc=0
# on the next SessionStart. Without an explicit clear in the rc=0 branch,
# the stale marker would survive and keep BG-B/C/D in pass-through forever.
# This fixture proves the rc=0 branch clears the marker.
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

echo "test-session-start-bootstrap: OK (10/10 fixtures)"
