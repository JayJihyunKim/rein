#!/usr/bin/env bash
# test-mirror-workflow-q9-fix.sh — guards the Q9 mirror tag-trigger fix.
#
# Q9 defect: mirror-to-public.yml only triggered on `push: branches:[main]`,
# so a release tag pushed separately never reached the public repo (the
# origin-side retag block silently found nothing). v1.2.0 and v1.3.0 both
# needed a manual public tag push.
#
# The fix: the workflow also triggers on `v*` tag pushes. The branch-triggered
# run records refs/mirror-state/main/<release-commit> -> <stripped commit>;
# the tag-triggered run resolves the EXACT stripped commit by that
# authoritative lookup. Content inference is deliberately NOT used — stripping
# is lossy (two releases differing only in maintainer-only files strip to the
# same tree), so public main content alone cannot identify the release.
#
# This test does NOT run the workflow. It asserts the fixed structure against
# a comment-stripped view (so prose can neither trip nor satisfy a check) and,
# when PyYAML is present, parses the YAML to verify trigger / concurrency /
# step gates structurally. There is no behavioural-extraction layer: the fix
# is git-plumbing glue wired in YAML, not an extractable algorithm — the prior
# inferential predicate that warranted such a test was removed.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$PROJECT_DIR/.github/workflows/mirror-to-public.yml"

[ -f "$WF" ] || { echo "FAIL: $WF missing" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Executable-only view: drop pure-comment lines (both YAML `#` and shell `#`
# comment-only lines). Inline trailing comments are not used on code lines in
# this workflow, so a leading-`#` filter is sufficient and conservative.
CODE=$(grep -vE '^[[:space:]]*#' "$WF")
has() { grep -qF "$1" <<<"$CODE"; }

# --- negative contract: superseded mechanisms must be gone -----------------
has 'git tag --points-at' \
  && fail "broken Q9 retag block still present in executable code (git tag --points-at)" || true
has 'ATTACHED_TAGS' \
  && fail "broken Q9 retag block still present in executable code (ATTACHED_TAGS)" || true
# The earlier content-inference predicate is superseded by the authoritative
# mirror-state mapping — stripping is lossy, see the header.
has 'public_main_reflects_release' \
  && fail "obsolete content-inference predicate public_main_reflects_release still present" || true

# --- positive contract: ref-type split ------------------------------------
has "if: github.ref_type == 'branch'" || fail "no branch-gated step"
has "if: github.ref_type == 'tag'" || fail "no tag-gated step"

# --- positive contract: branch step records the mirror-state mapping -------
has 'refs/mirror-state/main/${GITHUB_SHA}' \
  || fail "branch step does not record refs/mirror-state/main/<release-commit>"
has "ls-remote public 'refs/mirror-state/main/*'" \
  || fail "branch step does not prune stale mirror-state mappings"
has '[ "$stale" = "$CURRENT_MAPPING" ] && continue' \
  || fail "branch-step prune does not skip the freshly-written mapping"

# --- positive contract: tag step resolves via the mapping ------------------
has 'rev-parse "${GITHUB_REF}^{commit}"' \
  || fail "tag step does not resolve TAG_COMMIT explicitly"
grep -Eq 'TAG_COMMIT.*!=.*ORIGIN_MAIN' <<<"$CODE" \
  || fail "tag step missing TAG_COMMIT == origin/main precondition"
has 'refs/mirror-state/main/${TAG_COMMIT}' \
  || fail "tag step does not look up the mapping keyed by TAG_COMMIT"
has 'merge-base --is-ancestor "$TAG_COMMIT" "$STRIPPED"' \
  || fail "tag step missing the descend-from-release sanity check"
# The tag must be pushed from the resolved stripped commit — never public
# main or the unstripped release commit.
has '"${STRIPPED}:refs/tags/${TAG}"' \
  || fail "tag step does not push the tag from the resolved stripped commit"

# --- positive contract: postconditions (Option C — fail loud on silent skip)
has 'did not propagate to public' || fail "tag postcondition missing"
has 'does not match pushed HEAD' || fail "branch postcondition missing"
# The tag run cleans up the mapping ref it consumed (origin SHA hygiene).
has 'git push public --delete "${MAPPING_REF}"' \
  || fail "tag step does not delete the consumed mapping ref"

# --- token hygiene ---------------------------------------------------------
has 'PUBLIC_REPO_TOKEN: ${{ secrets.PUBLIC_REPO_TOKEN }}' \
  || fail "PUBLIC_REPO_TOKEN not wired through step env:"
if grep -E 'git remote add' <<<"$CODE" | grep -q 'secrets\.'; then
  fail "git remote add interpolates the secret inline — use the env var"
fi

# --- structural checks (YAML parse — requires PyYAML) ----------------------
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$WF" <<'PY' || fail "workflow structural check failed"
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
# YAML 1.1 parses the `on:` key as boolean True — accept either spelling.
on = wf.get('on', wf.get(True))
push = on['push']
assert 'v*' in (push.get('tags') or []), "on.push.tags must include 'v*'"
assert 'main' in (push.get('branches') or []), "on.push.branches must include main"
group = wf['concurrency']['group']
assert 'github.ref_type' in group and 'github.ref_name' in group, \
    "concurrency group must be the ref-type/ref-name conditional form"
assert wf['concurrency'].get('cancel-in-progress') is False, \
    "concurrency must set cancel-in-progress: false"
ifs = [s.get('if', '') for s in wf['jobs']['mirror']['steps']]
assert any("ref_type == 'branch'" in x for x in ifs), "no branch-gated step `if:`"
assert any("ref_type == 'tag'" in x for x in ifs), "no tag-gated step `if:`"
print("structural check: OK")
PY
else
  echo "test-mirror-workflow-q9-fix: (PyYAML absent — structural check skipped)"
fi

echo "test-mirror-workflow-q9-fix: OK"
