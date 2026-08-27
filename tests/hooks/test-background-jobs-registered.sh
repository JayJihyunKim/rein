#!/usr/bin/env bash
# test-background-jobs-registered.sh — Plugin-First Restructure Phase 2 Task 2.5.
#
# Verifies the background-jobs rule (codex foreground policy) is registered in
# the rein-core plugin:
#   (a) the always-run safety guard AND the two ③-c commit-gate successors
#       exist in the plugin mirror (Phase 7 웨이브 3 ③-c, 2026-08-23 갱신:
#       the former single (구)pre-bash-test-commit-gate.sh was deleted and
#       replaced by pre-bash-commit-discipline-gate.sh + pre-bash-commit-
#       review-gate.sh, sequential children of pre-bash-dispatcher.sh Step 3
#       — see that dispatcher's own header).
#   (b) hooks.json contains a PreToolUse / Bash registration that reaches
#       pre-tool-use-bash-rules.sh (the background-jobs rule hook) — either
#       directly, or indirectly via the single dispatcher entry point
#       (pre-bash-dispatcher.sh, Cycle X2 영역 A collapse) that conditionally
#       invokes it as its own Step 4 child.
#   (c) the HK-2 split hooks contain the codex foreground policy enforcement
#       surface — namely the pipe-to-bash blocking pattern that prevents
#       'codex exec ... | tail -N' or similar pipe-bash forms (which the Bash
#       tool would auto-background, breaking codex's TTY/stdin contract; see
#       .claude/rules/background-jobs.md "Exception — codex 계열 명령은
#       foreground 전용"). Detection is structural: we require the bash-pipe
#       blocking grep pattern (safety guard) AND the codex review evidence
#       consumer so the codex foreground policy has both the gate (pipe-bash
#       block) and the review evidence consumer. ③-c 갱신 + ③-d 재조준: the
#       review consumer's *enforcement body* no longer lives in a
#       hooks/lib/*.sh file — ③-c moved it to rein/engine/authority.py's
#       legacy dual-read layer, and ③-d (2026-08-24) removed that layer
#       entirely, leaving rein/capabilities/review/capability.py's
#       CodeReviewRequirement.evaluate() as the sole enforcement body — while
#       the commit review gate hook + lib/code-review-gate.sh only carry the
#       *wiring* (authority-switch check + delegation call). We verify all three
#       layers: hook wiring → lib delegation functions → engine enforcement
#       body.
#   (d) docs/rules/background-jobs.md exists in the plugin and is sha256-
#       identical to the source .claude/rules/background-jobs.md.
#
# Scope ID: rein-core-plugin-bundles-hooks-skills-agents-in-single-package-on-publish
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

PLUGIN_DIR="plugins/rein-core"
# HK-2 split (original): the former single Bash guard became two hooks. The
# pipe-to-bash block (P1, codex foreground gate) lives in the safety guard.
# ③-c split (2026-08-23): the codex review-stamp *wiring* now lives in the
# commit REVIEW gate (the discipline gate sibling owns coverage/commit-msg
# discipline only — no review stamp axis, see that hook's own header).
SAFETY_GUARD="$PLUGIN_DIR/hooks/pre-bash-safety-guard.sh"
DISCIPLINE_GATE="$PLUGIN_DIR/hooks/pre-bash-commit-discipline-gate.sh"
REVIEW_GATE="$PLUGIN_DIR/hooks/pre-bash-commit-review-gate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
RULE_NAME="background-jobs.md"
PLUGIN_RULE_DOC="$PLUGIN_DIR/rules/$RULE_NAME"
SOURCE_RULE_DOC="plugins/rein-core/rules/$RULE_NAME"

EXPECTED_EVENT="PreToolUse"
EXPECTED_MATCHER="Bash"
EXPECTED_BASENAME="pre-tool-use-bash-rules.sh"
DISPATCHER_BASENAME="pre-bash-dispatcher.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

# (a) Hook script presence — the always-run safety guard AND both ③-c
#     commit-gate successors must exist.
[ -f "$SAFETY_GUARD" ] || fail "hook script missing: $SAFETY_GUARD"
[ -f "$DISCIPLINE_GATE" ] || fail "hook script missing: $DISCIPLINE_GATE"
[ -f "$REVIEW_GATE" ] || fail "hook script missing: $REVIEW_GATE"

# (b) hooks.json registration check via Python.
[ -f "$HOOKS_JSON" ] || fail "hooks.json missing: $HOOKS_JSON"

python3 - "$HOOKS_JSON" "$EXPECTED_EVENT" "$EXPECTED_MATCHER" "$EXPECTED_BASENAME" "$DISPATCHER_BASENAME" <<'PY'
import json
import os
import sys

hooks_json_path, expected_event, expected_matcher, expected_basename, dispatcher_basename = sys.argv[1:6]

with open(hooks_json_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

# Claude Code hooks.json schema:
#   {"hooks": {"<Event>": [{"matcher": "...", "hooks": [{"command": "..."}, ...]}, ...]}}
#
# Cycle X2 (영역 A) collapsed the PreToolUse/Bash matcher group down to a
# single dispatcher entry (pre-bash-dispatcher.sh) — expected_basename
# (pre-tool-use-bash-rules.sh) is no longer spelled out directly in
# hooks.json; it is reached indirectly as the dispatcher's own Step 4
# (advisory) child. We accept either: a direct match (defensive — in case a
# future registration model reverts to direct multi-entry registration), or
# a dispatcher match whose own source still references expected_basename
# (so this check keeps testing effective reachability from PreToolUse/Bash,
# not merely literal hooks.json spelling).
hooks_by_event = data.get("hooks", {})
matched_dispatcher = False
for matcher_group in hooks_by_event.get(expected_event, []):
    if matcher_group.get("matcher", "") != expected_matcher:
        continue
    for hook in matcher_group.get("hooks", []):
        cmd = hook.get("command", "")
        basename = os.path.basename(cmd)
        if basename == expected_basename:
            sys.exit(0)
        if basename == dispatcher_basename:
            matched_dispatcher = True

if matched_dispatcher:
    dispatcher_path = os.path.join(os.path.dirname(hooks_json_path), dispatcher_basename)
    try:
        with open(dispatcher_path, "r", encoding="utf-8") as fh:
            dispatcher_src = fh.read()
    except OSError:
        print(f"FAIL: dispatcher registered but its script is missing: {dispatcher_path}", file=sys.stderr)
        sys.exit(1)
    if expected_basename in dispatcher_src:
        sys.exit(0)
    print(
        f"FAIL: dispatcher ({dispatcher_basename}) is registered but its own source does not "
        f"reference {expected_basename} (indirect registration check)",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    "FAIL: no hooks.json entry matched event="
    f"{expected_event} matcher={expected_matcher} basename={expected_basename} "
    f"(direct, or indirect via {dispatcher_basename})",
    file=sys.stderr,
)
sys.exit(1)
PY

# (c) Codex foreground policy enforcement structure.
#     HK-2 split: the two complementary surfaces now live in separate hooks.
#       (c1) pipe-to-bash blocking pattern — in the always-on safety guard
#            (prevents auto-background of 'cmd | bash' which is the failure
#            mode in trail/dod/dod-2026-04-22-codex-foreground-policy.md).
#       (c2) codex review evidence logic — the v2 code_review evidence
#            consumer. dod-gate fix cycle (2026-08-14) originally extracted
#            this axis out of check_review_stamp() into hooks/lib/code-
#            review-gate.sh. Phase 7 웨이브 3 ③-c (2026-08-23) moved it
#            again: the v1 final-judgment entry point
#            (rein_check_code_review_stamp — DOD_EXISTS precondition +
#            .review-pending freshness + direct verdict judgment) was
#            REMOVED from the lib entirely (see that file's own "Phase 7
#            웨이브 3 ③-c 갱신" header section). What remains in the lib is
#            only wiring: an authority-switch check function
#            (rein_code_review_authority_switched) and a delegation function
#            (rein_code_review_delegate) that hands off to the v2 engine
#            (bin/rein hook). Phase 7 웨이브 3 ③-d (2026-08-24) removed the
#            legacy dual-read layer that used to live in rein/engine/
#            authority.py (`_legacy_code_review_status`/`.codex-reviewed`
#            consumer — both fully deleted, `grep -n "^def "
#            authority.py` no longer lists that function) — the real
#            enforcement *body* now lives in
#            rein/capabilities/review/capability.py's
#            `CodeReviewRequirement.evaluate()` (subject-empty/unresolved/
#            digest+evidence-validity judgment, spec §3.6). So "present"
#            means all three layers hold: (i) the commit review gate hook
#            wires the lib call sites, (ii) the lib provides the v2
#            delegation functions, AND (iii) the v2 capability module still
#            carries the real code_review evidence-validity enforcement body
#            — not merely that the substring "codex" still occurs somewhere
#            in one of these files.
if ! grep -qE '\| *(bash|sh)' "$SAFETY_GUARD"; then
  fail "$SAFETY_GUARD missing pipe-to-bash blocking pattern (codex foreground gate)"
fi
CODE_REVIEW_GATE_LIB="$PLUGIN_DIR/hooks/lib/code-review-gate.sh"
if ! grep -q 'rein_code_review_authority_switched' "$REVIEW_GATE"; then
  fail "$REVIEW_GATE does not wire the code-review gate (missing rein_code_review_authority_switched call)"
fi
if ! grep -q 'rein_code_review_delegate' "$REVIEW_GATE"; then
  fail "$REVIEW_GATE does not wire the code-review gate (missing rein_code_review_delegate call)"
fi
if [ ! -f "$CODE_REVIEW_GATE_LIB" ]; then
  fail "code-review gate lib missing: $CODE_REVIEW_GATE_LIB"
fi
if ! grep -q 'rein_code_review_authority_switched()' "$CODE_REVIEW_GATE_LIB"; then
  fail "$CODE_REVIEW_GATE_LIB missing the v2 authority-switch check function (rein_code_review_authority_switched)"
fi
if ! grep -q 'rein_code_review_delegate()' "$CODE_REVIEW_GATE_LIB"; then
  fail "$CODE_REVIEW_GATE_LIB missing the v2 delegation function (rein_code_review_delegate)"
fi
# Phase 7 웨이브 3 ③-d: authority.py 의 legacy dual-read 계층
# (_legacy_code_review_status 등)이 완전히 삭제됐다 — 그 함수/표식 소비를
# 검사하던 이 블록은 재조준한다. 실제 enforcement body 는 이제
# rein/capabilities/review/capability.py 의 CodeReviewRequirement.evaluate()
# 다(subject-empty/unresolved/digest+evidence 유효성 판정, spec §3.6).
V2_AUTHORITY_MODULE="$PLUGIN_DIR/rein/engine/authority.py"
if [ ! -f "$V2_AUTHORITY_MODULE" ]; then
  fail "v2 authority engine module missing: $V2_AUTHORITY_MODULE"
fi
if grep -qE '^def _legacy_code_review_status' "$V2_AUTHORITY_MODULE"; then
  fail "$V2_AUTHORITY_MODULE still defines the removed legacy code-review status evaluator (_legacy_code_review_status) — Phase 7 wave 3 ③-d retired this function, it must not be reintroduced (a comment referencing the retired name historically is fine — only a live def is a regression)"
fi
V2_REVIEW_CAPABILITY="$PLUGIN_DIR/rein/capabilities/review/capability.py"
if [ ! -f "$V2_REVIEW_CAPABILITY" ]; then
  fail "v2 code_review capability module missing: $V2_REVIEW_CAPABILITY"
fi
if ! grep -q 'class CodeReviewRequirement' "$V2_REVIEW_CAPABILITY"; then
  fail "$V2_REVIEW_CAPABILITY missing CodeReviewRequirement (the enforcement body that replaced the legacy dual-read consumer)"
fi
if ! grep -q 'def evaluate' "$V2_REVIEW_CAPABILITY"; then
  fail "$V2_REVIEW_CAPABILITY missing an evaluate() method on the code_review requirement"
fi

# (d) Rule reference doc presence + sha256 parity with source.
[ -f "$SOURCE_RULE_DOC" ] || fail "source rule doc missing: $SOURCE_RULE_DOC"
[ -f "$PLUGIN_RULE_DOC" ] || fail "plugin rule doc missing: $PLUGIN_RULE_DOC"

src_sha="$(sha256_of "$SOURCE_RULE_DOC")"
dst_sha="$(sha256_of "$PLUGIN_RULE_DOC")"
if [ "$src_sha" != "$dst_sha" ]; then
  fail "sha256 drift for rule doc '$RULE_NAME': source=$src_sha plugin=$dst_sha"
fi

echo "test-background-jobs-registered: OK (hook + hooks.json + codex foreground gate + rule doc parity)"
