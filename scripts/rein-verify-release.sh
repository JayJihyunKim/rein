#!/usr/bin/env bash
# rein-verify-release.sh — release postcondition verifier.
#
# Usage:
#   bash scripts/rein-verify-release.sh <version>
#   e.g. bash scripts/rein-verify-release.sh 1.3.0
#
# Runs all postcondition checks for the given release version and reports
# per-check status (PASS / FAIL / SKIP). Exits 0 if no FAILs, 1 otherwise.
#
# Checks (in order):
#   a. Local tag exists                              (git tag -l)
#   b. Local tag pushed to origin AND peels to the release commit
#   c. main HEAD on origin == local main HEAD        (anchored to release commit)
#   d. mirror-to-public.yml latest run for tag = success
#   e. publish-plugin.yml run for tag = success
#      OR failure that is *confirmed* (via run log) to be the expected
#      Anthropic-token-absence failure AND workflow has
#      REIN_PUBLISH_SELF_HOSTED_ONLY="1" → SKIP "Anthropic token absent (expected)".
#      Any other failure → FAIL (never masked).
#   f. Public mirror remote tag exists AND peels to the public main HEAD
#
# Contract notes (read before editing):
#   - Per `plugins/rein-core/scripts/rein-publish.sh` line 127-129, when
#     REIN_PUBLISH_SELF_HOSTED_ONLY="1" is set in the publish workflow env,
#     the Anthropic POST is skipped and only the self-hosted manifest is
#     updated. The publish-plugin.yml job currently fails fast on a missing
#     Anthropic token even with that env. Check (e) SKIPs such a failure ONLY
#     when the run's `--log-failed` output contains the specific token-absence
#     signature; a genuine failure (build break, drift-check, network) is
#     reported as FAIL and never swallowed.
#   - Tag-comparison uses `^{commit}` / `^{}` peel form so annotated tags
#     compare against the commit they point to, not the tag-object SHA.
#   - Remote tag checks compare the tag's *peeled commit*, not mere existence:
#     check (b) against the local release commit; check (f) against the public
#     mirror's main HEAD (the mirror strips files, so the public tag commit
#     never equals the local commit — it tracks public main instead).
#   - `gh run list --workflow <name>` returns runs ordered most-recent first;
#     for tag-triggered workflows, headBranch is the tag name (e.g. "v1.3.0"),
#     for branch-triggered workflows it is the branch ("main"). We filter by
#     the appropriate field per workflow.

set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

PUBLIC_REPO_URL="${REIN_PUBLIC_REPO_URL:-https://github.com/JayJihyunKim/rein}"
MIRROR_WORKFLOW="mirror-to-public.yml"
PUBLISH_WORKFLOW="publish-plugin.yml"

# Resolve repo root so we can read the publish workflow yml regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# ---------------------------------------------------------------------------
# Output helpers — color when stderr is a tty.
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'
  C_RED='\033[0;31m'
  C_YELLOW='\033[0;33m'
  C_BOLD='\033[1m'
  C_RESET='\033[0m'
else
  C_GREEN='' C_RED='' C_YELLOW='' C_BOLD='' C_RESET=''
fi

# Counters — bumped by record_pass / record_fail / record_skip.
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Pretty-print one check result line.
#   $1 = letter (a|b|...)
#   $2 = name
#   $3 = PASS|FAIL|SKIP
#   $4 = reason (one line, no newlines)
print_check() {
  local letter="$1" name="$2" status="$3" reason="$4"
  local color
  case "$status" in
    PASS) color="$C_GREEN" ;;
    FAIL) color="$C_RED" ;;
    SKIP) color="$C_YELLOW" ;;
    *)    color="" ;;
  esac
  printf "  %s) %-40s %b%-4s%b  %s\n" "$letter" "$name" "$color" "$status" "$C_RESET" "$reason"
}

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); print_check "$1" "$2" "PASS" "$3"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); print_check "$1" "$2" "FAIL" "$3"; }
record_skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); print_check "$1" "$2" "SKIP" "$3"; }

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "usage: bash scripts/rein-verify-release.sh <version>" >&2
  echo "  e.g. bash scripts/rein-verify-release.sh 1.3.0" >&2
  exit 2
fi

VERSION="$1"
TAG="v$VERSION"

# Reject obviously bogus version strings (we accept semver-ish: digits/dots/dashes/letters).
case "$VERSION" in
  ''|*[!A-Za-z0-9._+-]*)
    echo "error: invalid version '$VERSION' (must match [A-Za-z0-9._+-]+)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Tool availability — soft preflight.
# ---------------------------------------------------------------------------

if ! command -v git >/dev/null 2>&1; then
  echo "error: git not found in PATH" >&2
  exit 2
fi
HAS_GH=0
if command -v gh >/dev/null 2>&1; then HAS_GH=1; fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

echo -e "${C_BOLD}rein release verifier — checking $TAG${C_RESET}"
echo

# ---------------------------------------------------------------------------
# Check (a) — local tag exists
# ---------------------------------------------------------------------------

LOCAL_TAG_LINE="$(git -C "$REPO_ROOT" tag -l "$TAG" 2>/dev/null || true)"
if [ "$LOCAL_TAG_LINE" = "$TAG" ]; then
  LOCAL_TAG_COMMIT="$(git -C "$REPO_ROOT" rev-parse "${TAG}^{commit}" 2>/dev/null || true)"
  record_pass "a" "local tag exists" "$TAG -> ${LOCAL_TAG_COMMIT:0:12}"
else
  record_fail "a" "local tag exists" "git tag -l '$TAG' returned no match"
  LOCAL_TAG_COMMIT=""
fi

# ---------------------------------------------------------------------------
# Check (b) — local tag pushed to origin AND points at the release commit.
# We resolve the origin tag's *peeled* commit (the `^{}` ls-remote line for an
# annotated tag; the plain `refs/tags/$TAG` line for a lightweight tag) and
# compare it to the commit the local tag resolves to. Existence alone is
# insufficient — a stale/wrong tag pointing at an unrelated commit must FAIL.
# ---------------------------------------------------------------------------

# ls-remote returns up to two lines for an annotated tag:
#   <tag-object-sha>  refs/tags/$TAG
#   <commit-sha>      refs/tags/$TAG^{}
# For a lightweight tag only the first line exists and already points at a commit.
ORIGIN_TAG_REFS="$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null || true)"
if [ -z "$ORIGIN_TAG_REFS" ]; then
  record_fail "b" "tag pushed to origin" "git ls-remote origin refs/tags/$TAG returned empty"
else
  # Peeled commit: prefer the `^{}` line, fall back to the plain ref line.
  ORIGIN_TAG_PEELED="$(printf '%s\n' "$ORIGIN_TAG_REFS" \
    | awk '$2 == "refs/tags/'"$TAG"'^{}" {print $1}')"
  if [ -z "$ORIGIN_TAG_PEELED" ]; then
    ORIGIN_TAG_PEELED="$(printf '%s\n' "$ORIGIN_TAG_REFS" \
      | awk '$2 == "refs/tags/'"$TAG"'" {print $1}')"
  fi
  if [ -z "$ORIGIN_TAG_PEELED" ]; then
    record_fail "b" "tag pushed to origin" "could not resolve origin tag commit from ls-remote output"
  elif [ -z "$LOCAL_TAG_COMMIT" ]; then
    # Local tag missing (check a failed) — report origin SHA but cannot anchor.
    record_fail "b" "tag pushed to origin" \
      "origin tag at ${ORIGIN_TAG_PEELED:0:12} but local tag unresolvable (see check a)"
  elif [ "$ORIGIN_TAG_PEELED" = "$LOCAL_TAG_COMMIT" ]; then
    record_pass "b" "tag pushed to origin" "origin tag -> ${ORIGIN_TAG_PEELED:0:12} (== local)"
  else
    record_fail "b" "tag pushed to origin" \
      "origin tag -> ${ORIGIN_TAG_PEELED:0:12} != local ${LOCAL_TAG_COMMIT:0:12}"
  fi
fi

# ---------------------------------------------------------------------------
# Check (c) — main HEAD on origin matches local main HEAD (anchored to
# release commit). We pick the release commit as: the commit the tag points
# at (peeled). Both local main and origin main should be at-or-ahead of
# this commit. For a just-released tag, they will match exactly.
# ---------------------------------------------------------------------------

LOCAL_MAIN_SHA="$(git -C "$REPO_ROOT" rev-parse main 2>/dev/null || true)"
ORIGIN_MAIN_LINE="$(git -C "$REPO_ROOT" ls-remote origin "refs/heads/main" 2>/dev/null || true)"
ORIGIN_MAIN_SHA="$(printf '%s\n' "$ORIGIN_MAIN_LINE" | awk '{print $1}')"

if [ -z "$LOCAL_MAIN_SHA" ]; then
  record_fail "c" "main HEAD origin == local" "local main not resolvable"
elif [ -z "$ORIGIN_MAIN_SHA" ]; then
  record_fail "c" "main HEAD origin == local" "origin main not resolvable"
elif [ "$LOCAL_MAIN_SHA" = "$ORIGIN_MAIN_SHA" ]; then
  # Best case: exact match. Optionally call out if the release commit IS this HEAD.
  if [ -n "$LOCAL_TAG_COMMIT" ] && [ "$LOCAL_TAG_COMMIT" = "$LOCAL_MAIN_SHA" ]; then
    record_pass "c" "main HEAD origin == local" "both at ${LOCAL_MAIN_SHA:0:12} (release commit)"
  else
    record_pass "c" "main HEAD origin == local" "both at ${LOCAL_MAIN_SHA:0:12}"
  fi
else
  record_fail "c" "main HEAD origin == local" \
    "local=${LOCAL_MAIN_SHA:0:12} vs origin=${ORIGIN_MAIN_SHA:0:12}"
fi

# ---------------------------------------------------------------------------
# Check (d) — mirror-to-public.yml latest run for the release commit was
# success. This workflow triggers on push to main; headBranch == "main",
# headSha == the main commit pushed (which equals the release commit when
# tag and main were pushed together).
# ---------------------------------------------------------------------------

if [ "$HAS_GH" -ne 1 ]; then
  record_skip "d" "mirror-to-public success" "gh CLI not installed"
else
  MIRROR_RUNS_JSON="$(gh run list --workflow "$MIRROR_WORKFLOW" --limit 10 \
    --json conclusion,headBranch,headSha,event,status,databaseId 2>/dev/null || true)"
  if [ -z "$MIRROR_RUNS_JSON" ]; then
    record_fail "d" "mirror-to-public success" "no runs returned (gh auth or workflow missing?)"
  else
    # Match by headSha == release commit (LOCAL_TAG_COMMIT). Fallback: headSha
    # == ORIGIN_MAIN_SHA (covers race where caller passes an older version).
    MATCH_TARGET_SHA="${LOCAL_TAG_COMMIT:-$ORIGIN_MAIN_SHA}"
    # JSON and the target SHA cross the shell->python boundary via the
    # environment, not via interpolation into the python source. The heredoc
    # delimiter is quoted (<<'PY') so the shell performs no expansion on the
    # python body — an attacker-controlled field (e.g. a ref name containing
    # the ''' delimiter) cannot break out of the string literal (CWE-94).
    MIRROR_PARSED="$(MIRROR_RUNS_JSON="$MIRROR_RUNS_JSON" MATCH_TARGET_SHA="$MATCH_TARGET_SHA" python3 - <<'PY' 2>/dev/null
import json, os
runs = json.loads(os.environ["MIRROR_RUNS_JSON"])
target = os.environ.get("MATCH_TARGET_SHA", "")
for r in runs:
    if r.get("headSha") == target:
        print(f"{r.get('conclusion','')}|{r.get('status','')}|{r.get('databaseId','')}")
        break
PY
)"
    if [ -z "$MIRROR_PARSED" ]; then
      record_fail "d" "mirror-to-public success" \
        "no run found with headSha=${MATCH_TARGET_SHA:0:12}"
    else
      MIRROR_CONCL="${MIRROR_PARSED%%|*}"
      MIRROR_REST="${MIRROR_PARSED#*|}"
      MIRROR_STATUS="${MIRROR_REST%%|*}"
      MIRROR_RUNID="${MIRROR_PARSED##*|}"
      if [ "$MIRROR_STATUS" != "completed" ]; then
        record_fail "d" "mirror-to-public success" \
          "run #$MIRROR_RUNID still in status=$MIRROR_STATUS"
      elif [ "$MIRROR_CONCL" = "success" ]; then
        record_pass "d" "mirror-to-public success" "run #$MIRROR_RUNID success"
      else
        record_fail "d" "mirror-to-public success" \
          "run #$MIRROR_RUNID conclusion=$MIRROR_CONCL"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check (e) — publish-plugin.yml for tag.
#
# This workflow triggers on tag push (refs/tags/v*); headBranch == TAG name
# (e.g. "v1.3.0"). We match by headBranch == TAG.
#
# Failure handling: if the workflow yml has REIN_PUBLISH_SELF_HOSTED_ONLY=1
# in the publish step env, then a failure conclusion is the EXPECTED state
# (per rein-publish.sh fail-fast on missing ANTHROPIC_TOKEN before that env
# can take effect at the publish step). Treat as SKIP in that case.
# ---------------------------------------------------------------------------

self_hosted_only_active() {
  # Returns 0 if the publish workflow yml contains an active (non-comment)
  # `REIN_PUBLISH_SELF_HOSTED_ONLY: "1"` env line; 1 otherwise.
  local yml="$REPO_ROOT/.github/workflows/$PUBLISH_WORKFLOW"
  [ -f "$yml" ] || return 1
  # grep for non-commented line setting the env to "1". Yaml comments start
  # with '#' (allowing leading whitespace).
  grep -E '^[[:space:]]*REIN_PUBLISH_SELF_HOSTED_ONLY:[[:space:]]*"1"' "$yml" \
    | grep -v -E '^[[:space:]]*#' >/dev/null 2>&1
}

publish_failure_is_token_absence() {
  # Returns 0 only if the failing publish-plugin run's log shows the EXPECTED
  # Anthropic-token-absence signature; 1 otherwise (genuine failure, or the
  # log could not be retrieved). $1 = run id.
  #
  # We must NOT mask arbitrary failures (build break, drift-check failure,
  # network error) as a SKIP — only the specific known-and-accepted failure
  # mode is SKIP-able. Requires gh; if the log fetch fails we return 1 so the
  # caller records a FAIL rather than silently swallowing the failure.
  local run_id="$1" log
  [ -n "$run_id" ] || return 1
  log="$(gh run view "$run_id" --log-failed 2>/dev/null || true)"
  [ -n "$log" ] || return 1
  printf '%s\n' "$log" \
    | grep -E 'ANTHROPIC_MARKETPLACE_API env var required|ANTHROPIC_TOKEN env var required' \
      >/dev/null 2>&1
}

if [ "$HAS_GH" -ne 1 ]; then
  record_skip "e" "publish-plugin success" "gh CLI not installed"
else
  PUBLISH_RUNS_JSON="$(gh run list --workflow "$PUBLISH_WORKFLOW" --limit 10 \
    --json conclusion,headBranch,headSha,event,status,databaseId 2>/dev/null || true)"
  if [ -z "$PUBLISH_RUNS_JSON" ]; then
    record_fail "e" "publish-plugin success" "no runs returned (gh auth or workflow missing?)"
  else
    # JSON and the tag name cross the shell->python boundary via the
    # environment, not via interpolation into the python source. The heredoc
    # delimiter is quoted (<<'PY') so the shell performs no expansion on the
    # python body — an attacker-controlled field (e.g. headBranch carrying the
    # ''' delimiter) cannot break out of the string literal (CWE-94).
    PUBLISH_PARSED="$(PUBLISH_RUNS_JSON="$PUBLISH_RUNS_JSON" TAG="$TAG" python3 - <<'PY' 2>/dev/null
import json, os
runs = json.loads(os.environ["PUBLISH_RUNS_JSON"])
tag = os.environ.get("TAG", "")
for r in runs:
    if r.get("headBranch") == tag:
        print(f"{r.get('conclusion','')}|{r.get('status','')}|{r.get('databaseId','')}")
        break
PY
)"
    if [ -z "$PUBLISH_PARSED" ]; then
      record_fail "e" "publish-plugin success" "no run found with headBranch=$TAG"
    else
      PUBLISH_CONCL="${PUBLISH_PARSED%%|*}"
      PUBLISH_REST="${PUBLISH_PARSED#*|}"
      PUBLISH_STATUS="${PUBLISH_REST%%|*}"
      PUBLISH_RUNID="${PUBLISH_PARSED##*|}"
      if [ "$PUBLISH_STATUS" != "completed" ]; then
        record_fail "e" "publish-plugin success" \
          "run #$PUBLISH_RUNID still in status=$PUBLISH_STATUS"
      elif [ "$PUBLISH_CONCL" = "success" ]; then
        record_pass "e" "publish-plugin success" "run #$PUBLISH_RUNID success"
      else
        # Failure path. A failure is SKIP-able ONLY when BOTH hold:
        #   1. self-hosted-only mode is active in the workflow yml (secondary
        #      guard — if not active, ANY failure is a real FAIL with no log
        #      inspection needed), AND
        #   2. the run log shows the specific Anthropic-token-absence signature
        #      (primary check — confirms this is the expected failure mode and
        #      not a build break / drift-check failure / network error).
        # Otherwise the failure is genuine and must be reported as FAIL — never
        # masked.
        if self_hosted_only_active && publish_failure_is_token_absence "$PUBLISH_RUNID"; then
          record_skip "e" "publish-plugin success" \
            "run #$PUBLISH_RUNID $PUBLISH_CONCL — Anthropic token absent (expected)"
        else
          record_fail "e" "publish-plugin success" \
            "run #$PUBLISH_RUNID conclusion=$PUBLISH_CONCL"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check (f) — public mirror remote tag exists AND anchors to public main HEAD.
#
# The public mirror strips files before force-pushing, so the public tag's
# commit will NOT equal the local release commit — comparing against the local
# commit would always (incorrectly) FAIL. Instead: mirror-to-public force-pushes
# `main` then re-tags, so the release tag on the public mirror should peel to
# the public mirror's current `main` HEAD. We compare those two.
#
# Existence alone is insufficient (a stale tag from an earlier mirror run would
# pass). If the tag is absent we FAIL; if present but not anchored to public
# main HEAD we FAIL and report both SHAs for human verification.
# ---------------------------------------------------------------------------

PUBLIC_TAG_REFS="$(git ls-remote "$PUBLIC_REPO_URL" "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null || true)"
if [ -z "$PUBLIC_TAG_REFS" ]; then
  record_fail "f" "public mirror tag exists" \
    "git ls-remote $PUBLIC_REPO_URL refs/tags/$TAG returned empty"
else
  # Peeled commit: prefer the `^{}` line, fall back to the plain ref line.
  PUBLIC_TAG_PEELED="$(printf '%s\n' "$PUBLIC_TAG_REFS" \
    | awk '$2 == "refs/tags/'"$TAG"'^{}" {print $1}')"
  if [ -z "$PUBLIC_TAG_PEELED" ]; then
    PUBLIC_TAG_PEELED="$(printf '%s\n' "$PUBLIC_TAG_REFS" \
      | awk '$2 == "refs/tags/'"$TAG"'" {print $1}')"
  fi
  PUBLIC_MAIN_LINE="$(git ls-remote "$PUBLIC_REPO_URL" "refs/heads/main" 2>/dev/null || true)"
  PUBLIC_MAIN_SHA="$(printf '%s\n' "$PUBLIC_MAIN_LINE" | awk '{print $1}')"
  if [ -z "$PUBLIC_TAG_PEELED" ]; then
    record_fail "f" "public mirror tag anchored" \
      "could not resolve public tag commit from ls-remote output"
  elif [ -z "$PUBLIC_MAIN_SHA" ]; then
    record_fail "f" "public mirror tag anchored" \
      "public tag at ${PUBLIC_TAG_PEELED:0:12} but public main HEAD unresolvable"
  elif [ "$PUBLIC_TAG_PEELED" = "$PUBLIC_MAIN_SHA" ]; then
    record_pass "f" "public mirror tag anchored" \
      "public tag -> ${PUBLIC_TAG_PEELED:0:12} (== public main HEAD)"
  else
    record_fail "f" "public mirror tag anchored" \
      "public tag -> ${PUBLIC_TAG_PEELED:0:12} != public main HEAD ${PUBLIC_MAIN_SHA:0:12}"
  fi
fi

# ---------------------------------------------------------------------------
# Summary + exit
# ---------------------------------------------------------------------------

echo
echo -e "${C_BOLD}Summary:${C_RESET} ${C_GREEN}$PASS_COUNT passed${C_RESET}, ${C_RED}$FAIL_COUNT failed${C_RESET}, ${C_YELLOW}$SKIP_COUNT skipped${C_RESET}"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
