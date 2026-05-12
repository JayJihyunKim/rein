#!/usr/bin/env bash
# test-session-start-bootstrap.sh
#
# Verifies the SessionStart bootstrap prompt flow:
#   - non-git project cwd gets prompt context but no files are created
#   - uninitialized git repo gets prompt context but no files are created
#   - approved helper bootstraps only the repo root
#   - Claude plugin cache / marketplace paths are never prompted or mutated
#   - initialized repo is silent

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-bootstrap.sh"
HELPER="$PROJECT_DIR/plugins/rein-core/scripts/rein-bootstrap-project.py"

[ -x "$HOOK" ] || { echo "FAIL: missing executable hook: $HOOK" >&2; exit 1; }
[ -x "$HELPER" ] || { echo "FAIL: missing executable helper: $HELPER" >&2; exit 1; }

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

# Wave 4 Task 3.1 grep-pattern update: v1.1.1 moved the prompt template into
# the shared helper (hooks/lib/bootstrap-check.sh). The legacy phrase "Rein
# bootstrap required" no longer appears; the new bilingual marker is
#   "ERROR: rein plugin trail/ directory missing — bootstrap not initialized."
# and the bootstrap command is quoted:
#   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/rein-bootstrap-project.py" --project-dir "..."
# We assert the EN marker (substring "trail/ directory missing") plus the
# command substring "rein-bootstrap-project.py" and the flag "--project-dir".

# A: non-git project cwd gets prompt context but no state mutation.
mkdir -p "$TMP/non-git"
run_hook "$TMP/non-git" "$TMP/non-git.out"
grep -q "trail/ directory missing" "$TMP/non-git.out" \
  || fail "A: non-git project bootstrap prompt missing"
grep -q "rein-bootstrap-project.py" "$TMP/non-git.out" \
  || fail "A: non-git project bootstrap command missing"
grep -q -- "--project-dir" "$TMP/non-git.out" \
  || fail "A: non-git project bootstrap --project-dir flag missing"
[ ! -e "$TMP/non-git/trail" ] || fail "A: hook must not create trail without user approval"
[ ! -e "$TMP/non-git/.rein" ] || fail "A: hook must not create .rein without user approval"
ok "A: non-git project prompts without mutation"

# B: uninitialized git repo gets prompt context but no state mutation.
REPO="$TMP/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q )
run_hook "$REPO" "$TMP/repo.out"
grep -q "trail/ directory missing" "$TMP/repo.out" \
  || fail "B: bootstrap prompt missing"
grep -q "rein-bootstrap-project.py" "$TMP/repo.out" \
  || fail "B: bootstrap command missing"
grep -q -- "--project-dir" "$TMP/repo.out" \
  || fail "B: bootstrap --project-dir flag missing"
[ ! -e "$REPO/trail" ] || fail "B: hook must not create trail without user approval"
[ ! -e "$REPO/.rein" ] || fail "B: hook must not create .rein without user approval"
ok "B: uninitialized repo prompts without mutation"

# C: approved helper bootstraps repo-local state only.
python3 "$HELPER" --project-dir "$REPO" --scope project --version 1.0.0 >"$TMP/helper-c.out"
[ -f "$REPO/.rein/project.json" ] || fail "C: .rein/project.json missing"
[ -f "$REPO/.rein/policy/hooks.yaml" ] || fail "C: policy hooks.yaml missing"
[ -f "$REPO/.rein/policy/rules.yaml" ] || fail "C: policy rules.yaml missing"
[ -f "$REPO/trail/index.md" ] || fail "C: trail/index.md missing"
[ -f "$REPO/trail/inbox/.gitkeep" ] || fail "C: trail/inbox/.gitkeep missing"
python3 - "$REPO/.rein/project.json" <<'PY' || fail "C: project.json invalid"
import json
import sys
data = json.load(open(sys.argv[1]))
assert data["mode"] == "plugin", data
assert data["scope"] == "project", data
assert data["version"] == "1.0.0", data
PY
ok "C: approved helper bootstraps repo-local state"

# D: initialized repo is silent on next SessionStart.
run_hook "$REPO" "$TMP/repo-initialized.out"
[ ! -s "$TMP/repo-initialized.out" ] || fail "D: initialized repo should be silent"
ok "D: initialized repo silent"

# E: plugin cache path is ignored by hook and refused by helper.
#
# v1.1.1 spec change (Scope ID
#   bootstrap-check-helper-exit-code-equals-11-and-stderr-diagnostic-when-resolution-failure-or-plugin-cache-path-or-plugin-install-dir-or-unwritable-project-dir-or-sensitive-path-detected):
# the shared bash helper narrowed the cache-path predicate to the explicit
# `~/.claude/plugins/cache/` prefix only. v1.1.0 used the broader pattern
# `*/.claude/plugins/*` (incl. marketplaces/). Path under `cache/` is the
# canonical fixture for the hook-side silent skip.
#
# The Python `rein-bootstrap-project.py` helper retains its own broader
# refusal set (marketplaces / plugins root / cache) since it has independent
# guardrails — see §F below.
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
# the path through), but the Python bootstrap script still refuses it. Verify
# the second half of the contract — defense in depth.
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
# Plus the canonical cache path is also refused by the Python script:
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
# v1.1.1 spec change (Scope ID
#   bootstrap-check-helper-treats-trail-dir-presence-as-sole-initialized-predicate-not-checking-dot-rein-project-json-or-trail-index-md):
# the shared helper treats `trail/` presence as the SOLE bootstrap predicate.
# `.rein/project.json` and `trail/index.md` are deliberately NOT consulted.
#
#   G(a): .rein/ present, trail/ absent → still prompt (predicate fails)
#   G(b): trail/ present, .rein/ absent → SILENT (predicate succeeds; the
#         repo is considered initialized even without .rein/). This is the
#         intentional v1.1.1 contract: completing the missing .rein/ is the
#         user's responsibility once trail/ exists.
PARTIAL_REPO_A="$TMP/repo-partial-a"
mkdir -p "$PARTIAL_REPO_A/.rein"
( cd "$PARTIAL_REPO_A" && git init -q )
echo '{"mode":"plugin","scope":"project","version":"1.0.0"}' >"$PARTIAL_REPO_A/.rein/project.json"
run_hook "$PARTIAL_REPO_A" "$TMP/repo-partial-a.out"
grep -q "trail/ directory missing" "$TMP/repo-partial-a.out" \
  || fail "G(a): partial init (.rein only) must still prompt"
[ ! -e "$PARTIAL_REPO_A/trail" ] || fail "G(a): hook must not create trail in partial state"

PARTIAL_REPO_B="$TMP/repo-partial-b"
mkdir -p "$PARTIAL_REPO_B/trail"
( cd "$PARTIAL_REPO_B" && git init -q )
printf '# trail/index.md\n' >"$PARTIAL_REPO_B/trail/index.md"
run_hook "$PARTIAL_REPO_B" "$TMP/repo-partial-b.out"
[ ! -s "$TMP/repo-partial-b.out" ] \
  || fail "G(b): trail/ present → helper must treat as initialized (silent)"
[ ! -e "$PARTIAL_REPO_B/.rein" ] || fail "G(b): hook must not create .rein in partial state"
ok "G: partial init handled per v1.1.1 trail-only predicate"

echo "test-session-start-bootstrap: OK (7/7 assertions)"
