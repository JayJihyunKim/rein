#!/usr/bin/env bash
# test-policy-yaml-fails-open.sh - Plugin-First Restructure Phase 2 Task 2.10.
#
# Verifies fail-open semantics when a `.rein/policy/{rules,hooks}.yaml` is
# malformed. Critical contract (Plan §636-651): malformed config MUST NOT
# abort the caller hook. Loader emits a one-line `warning:` to stderr and
# returns the most permissive default; the caller hook proceeds and stays
# at exit 0.
#
# Round 6 fix in plan: each fixture exercises the **actual code path** of the
# matching yaml file, not just the loader CLI in isolation:
#   Fixture A (rules.yaml malformed) -> session-start-rules.sh   (Task 2.8 path)
#   Fixture B (hooks.yaml malformed) -> rein-policy-loader.py    (Task 2.7 path)
#
# Both fixtures use mktemp -d, set cwd to the temp dir for the loader's
# relative path resolution, and never touch the rein-dev repo's own .rein/.
#
# Scope ID: policy-yaml-load-error-fails-open-on-session-start
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
SESSION_START_RULES="$PLUGIN_ROOT/hooks/session-start-rules.sh"

if [ ! -x "$LOADER" ]; then
  echo "FAIL: loader missing or not executable: $LOADER" >&2
  exit 1
fi
if [ ! -x "$SESSION_START_RULES" ]; then
  echo "FAIL: session-start-rules.sh missing or not executable: $SESSION_START_RULES" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

ok() {
  echo "  ok: $1"
}

# -----------------------------------------------------------------------------
# Fixture A: rules.yaml malformed -> session-start-rules.sh stays exit 0,
# emits stderr warning, and stdout JSON envelope contains the 3 default rule
# bodies (code-style + security + testing) verbatim — proving "no override
# applied, defaults preserved" under malformed input.
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
# Use truly malformed yaml (mirroring test-policy-hooks-toggle.sh Fixture D).
# `:::` at start of line is a yaml syntax error; the `: invalid` line layered
# under colon-soup makes it definitive.
cat >"$A_DIR/.rein/policy/rules.yaml" <<'YAML'
:::
not yaml: at all: extra: colons:
  : invalid
YAML
# hooks.yaml deliberately not present — only the rules.yaml path under test.
[ ! -e "$A_DIR/.rein/policy/hooks.yaml" ] || fail "Fixture A setup: hooks.yaml should not exist"

A_STDOUT="$A_DIR/stdout"
A_STDERR="$A_DIR/stderr"
set +e
(
  cd "$A_DIR" && \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SESSION_START_RULES" \
    >"$A_STDOUT" 2>"$A_STDERR"
)
A_RC=$?
set -e
[ "$A_RC" = "0" ] || {
  echo "  hook stdout:" >&2; cat "$A_STDOUT" >&2
  echo "  hook stderr:" >&2; cat "$A_STDERR" >&2
  fail "Fixture A: expected exit 0 (fail-open), got $A_RC"
}

# stderr must contain a warning. Loader emits lowercase `warning:`; we
# match case-insensitive to be robust against future tone tweaks.
if ! grep -q -i "warning" "$A_STDERR"; then
  echo "  hook stderr captured:" >&2
  cat "$A_STDERR" >&2
  fail "Fixture A: expected 'warning' in stderr, got nothing"
fi

# stdout must be a single SessionStart envelope whose additionalContext
# contains all 3 default rule bodies. Parse with python3 stdlib (no PyYAML
# needed for JSON).
python3 - "$A_STDOUT" <<'PY' || fail "Fixture A: stdout JSON missing one or more default rule bodies"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    raw = fh.read()
try:
    payload = json.loads(raw)
except Exception as exc:
    print(f"stdout is not valid JSON: {exc}", file=sys.stderr)
    print(raw, file=sys.stderr)
    sys.exit(1)
ctx = payload.get("hookSpecificOutput", {}).get("additionalContext", "")
# Substrings unique to each rule's SHORT summary (PT-2: malformed rules.yaml
# fails open to the default-injected summaries, not the full bodies).
required = [
    "Code Style — quick rule",   # code-style-summary.md heading
    "Testing — quick rule",      # testing-summary.md heading
    "Security — quick rule",     # security-summary.md heading
]
missing = [r for r in required if r not in ctx]
if missing:
    print(f"missing default rule markers: {missing}", file=sys.stderr)
    print(f"additionalContext head: {ctx[:400]!r}", file=sys.stderr)
    sys.exit(1)
PY
ok "Fixture A: rules.yaml malformed -> session-start-rules.sh exit 0 + stderr warning + 3 defaults emitted"

# -----------------------------------------------------------------------------
# Fixture B: hooks.yaml malformed -> rein-policy-loader.py stays exit 0
# (default enabled), emits stderr warning. This is the Task 2.7 code path
# (is_enabled), distinct from Fixture A's Task 2.8 code path
# (get_rule_override).
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
cat >"$B_DIR/.rein/policy/hooks.yaml" <<'YAML'
:::
not yaml: at all: extra: colons:
  : invalid
YAML
# rules.yaml deliberately not present — only the hooks.yaml path under test.
[ ! -e "$B_DIR/.rein/policy/rules.yaml" ] || fail "Fixture B setup: rules.yaml should not exist"

B_STDERR="$B_DIR/stderr"
set +e
( cd "$B_DIR" && python3 "$LOADER" "pre-bash-safety-guard" 2>"$B_STDERR" )
B_RC=$?
set -e
[ "$B_RC" = "0" ] || {
  echo "  loader stderr:" >&2; cat "$B_STDERR" >&2
  fail "Fixture B: expected exit 0 (default enabled, fail-open), got $B_RC"
}
if ! grep -q -i "warning" "$B_STDERR"; then
  echo "  loader stderr captured:" >&2
  cat "$B_STDERR" >&2
  fail "Fixture B: expected 'warning' in stderr, got nothing"
fi
ok "Fixture B: hooks.yaml malformed -> loader exit 0 + stderr warning"

# -----------------------------------------------------------------------------
# Fixture C: hooks.yaml malformed -> ACTUAL gate hook stays non-blocking.
# Per plan §644 Round 6 fix, fixture must exercise the caller hook, not just
# the loader in isolation. The hook's policy check block (Task 2.7) must fall
# through on fail-open and let the hook reach its normal logic. We feed it a
# trail/* path (line 170 exemption) so the hook proceeds to its own exit 0 —
# proving the policy block did not trigger an early exit/fail under malformed
# hooks.yaml.
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대): pre-edit-dod-gate.sh 는 삭제되고
# pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 로 교대된다. 이 두 훅은
# 각자 자기 이름의 GMF-4 정책 토글 키를 갖는다(`pre-edit-discipline-gate` /
# `pre-edit-task-gate` — task-gate 도 "own key" 로 자체 토글을 조회한다, 그
# 훅 자신의 "Policy toggle" 주석 참조. 이전 개정에서 "task-gate 는 자체
# 토글이 없다"고 적었던 것은 오기였다). 두 훅의 GMF-4 코드 모양은 동일
# (resolve_python 직후 loader 호출, resolver-after 순서)하므로, 라이브 훅
# 프로세스를 통한 malformed-YAML fail-open 검증은 discipline-gate.sh 하나만
# 대표로 실행하고(중복된 배관을 두 번 반복하지 않기 위해), 구 키
# umbrella 매핑이 두 훅 모두에 실제로 적용되는지는 loader CLI 를 직접
# 호출하는 Fixture D(아래)가 커버한다.
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein/policy"
cp "$B_DIR/.rein/policy/hooks.yaml" "$C_DIR/.rein/policy/hooks.yaml"

GATE_HOOK="$PROJECT_DIR/plugins/rein-core/hooks/pre-edit-discipline-gate.sh"
[ -f "$GATE_HOOK" ] || fail "Fixture C setup: gate hook missing at $GATE_HOOK"

# Edit/Write input shape Claude Code passes to PreToolUse hooks. Use a
# trail/* path so the hook hits its built-in exemption (line 170) and exits 0.
GATE_INPUT='{"tool_input":{"file_path":"trail/foo.md"}}'

C_STDERR="$C_DIR/stderr"
C_STDOUT="$C_DIR/stdout"
# Round 2 code review fix (Medium): `VAR=val cmd1 | cmd2` scopes VAR to cmd1
# ONLY — a shell env-assignment prefix binds to the single simple command it
# precedes, and bash never propagates it across a `|` to a later command in
# the same pipeline. The previous form here put CLAUDE_PLUGIN_ROOT on
# `printf`, not on `bash "$GATE_HOOK"`, so the gate hook process never saw
# it — its "if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]" policy-toggle branch was
# silently skipped every run, and this fixture passed for the wrong reason
# (the trail/* path exemption alone). Moving the assignment onto the
# right-hand side of the pipe scopes it to the command that actually needs
# it.
set +e
( cd "$C_DIR" && \
    printf '%s' "$GATE_INPUT" \
    | CLAUDE_PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core" bash "$GATE_HOOK" \
    >"$C_STDOUT" 2>"$C_STDERR" )
C_RC=$?
set -e
[ "$C_RC" = "0" ] || {
  echo "  gate hook stderr:" >&2; cat "$C_STDERR" >&2
  echo "  gate hook stdout:" >&2; cat "$C_STDOUT" >&2
  fail "Fixture C: expected gate hook exit 0 with malformed hooks.yaml + trail/* path, got $C_RC"
}
if ! grep -q -i "warning" "$C_STDERR"; then
  echo "  gate hook stderr captured:" >&2
  cat "$C_STDERR" >&2
  fail "Fixture C: expected the policy loader's 'warning: failed to parse ...' on stderr (proves the plugin-mode branch actually ran) — got nothing. If this fails, CLAUDE_PLUGIN_ROOT is not reaching the gate hook process."
fi
ok "Fixture C: hooks.yaml malformed -> gate hook (pre-edit-discipline-gate.sh) exit 0 (non-blocking via fail-open) + loader warning surfaced (plugin-mode branch actually exercised)"

# -----------------------------------------------------------------------------
# Fixture D: legacy `pre-edit-dod-gate` toggle key (Phase 7 wave 3 ③-b code
# review round 1 fix). rein-policy-loader.py's UMBRELLA_KEYS now maps this
# retired hook name to BOTH successor hooks (pre-edit-discipline-gate.sh +
# pre-edit-task-gate.sh) — same precedent as the pre-bash-guard umbrella. A
# project that had `pre-edit-dod-gate: false` set before the pre-edit-dod-
# gate.sh retirement must keep BOTH successors disabled after upgrading (the
# user's stated intent survives the hook-name churn), while unrelated hooks
# (e.g. pre-edit-coverage-gate, which was never part of pre-edit-dod-gate.sh
# in the first place) must stay unaffected. This exercises the loader CLI
# directly (Task 2.7 mode: exit 0 = enabled, exit 1 = disabled) rather than a
# live hook process — same style as Fixture B above.
# -----------------------------------------------------------------------------
D_DIR="$TMP_ROOT/D"
mkdir -p "$D_DIR/.rein/policy"
cat >"$D_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-edit-dod-gate: false
YAML

set +e
( cd "$D_DIR" && python3 "$LOADER" "pre-edit-discipline-gate" )
D_DISCIPLINE_RC=$?
( cd "$D_DIR" && python3 "$LOADER" "pre-edit-task-gate" )
D_TASK_RC=$?
( cd "$D_DIR" && python3 "$LOADER" "pre-edit-coverage-gate" )
D_COVERAGE_RC=$?
set -e

[ "$D_DISCIPLINE_RC" = "1" ] \
  || fail "Fixture D: legacy pre-edit-dod-gate:false should disable pre-edit-discipline-gate via umbrella (expected exit 1, got $D_DISCIPLINE_RC)"
[ "$D_TASK_RC" = "1" ] \
  || fail "Fixture D: legacy pre-edit-dod-gate:false should disable pre-edit-task-gate via umbrella (expected exit 1, got $D_TASK_RC)"
[ "$D_COVERAGE_RC" = "0" ] \
  || fail "Fixture D: legacy pre-edit-dod-gate:false must NOT affect unrelated hooks like pre-edit-coverage-gate (expected exit 0/enabled, got $D_COVERAGE_RC)"
ok "Fixture D: legacy pre-edit-dod-gate toggle key umbrella-maps to both pre-edit-discipline-gate and pre-edit-task-gate, leaves unrelated hooks unaffected"

echo "test-policy-yaml-fails-open: OK (4/4 fixtures)"
