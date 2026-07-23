#!/usr/bin/env bash
# test-policy-loader-persona.sh - 페르소나 loader 중립 기본 + 커스텀 해석 회귀 테스트.
#
# Plan: docs/plans/2026-07-22-persona-user-selection.md Task 1.1.
# Scope IDs: loader-persona-disabled-when-yaml-absent-unparsable-or-enabled-not-true,
#            loader-keeps-boss-ace-for-existing-enabled-true-yaml,
#            loader-resolves-custom-file-under-rein-policy-persona-only-after-format-validation,
#            loader-downgrades-unresolvable-name-to-boss-ace-when-enabled,
#            loader-persona-file-cli-prints-resolved-path-when-active-else-empty
#            (PP-5 drift via assert (a)).
#
# NEW contract (replaces the v1.5.0 default-ON contract):
#   - NEUTRAL DEFAULT: persona is active ONLY when persona.yaml parses to a
#     dict with `enabled` literally True (`data.get("enabled") is True`). Every
#     other state (missing file, parse error, non-dict, enabled absent, string
#     "true", int 1, PyYAML absent, explicit false) -> `--persona` AND
#     `--persona-file` both print NOTHING, exit 0.
#   - `--persona-file` prints the resolved absolute source path (one line) when
#     active and resolvable, else empty stdout. Builtin tier resolves under
#     $CLAUDE_PLUGIN_ROOT/rules/persona/<name>.md; custom tier resolves under
#     cwd `.rein/policy/persona/<name>.md` after containment + UTF-8 decode +
#     <=4000-char validation. Builtin names always win over same-name customs.
#   - Downgrade (PP-3 extended): enabled + format-violating / unresolvable
#     preset -> boss-ace name + builtin boss-ace path.
#   - D1: CLAUDE_PLUGIN_ROOT unset -> `--persona-file` is ALWAYS empty (the
#     invariant layer is unresolvable, so no source path may be emitted), while
#     `--persona` stays deterministic at name level.
#   - `--persona-greeting <name>` (spec OQ2): prints the stored frontmatter
#     `greeting:` for a VALIDATED builtin/custom preset named on argv, else
#     empty stdout, always exit 0 (fail-open). It does NOT reuse the downgrade
#     path (resolve_persona_source), so a typo/invalid name yields empty — never
#     the boss-ace greeting (High-1). A (P)∧¬(A)-fence custom is not loaded by
#     either boundary, and `--turn-brief` reads only `summary:`, never greeting.
#
# Harness pattern mirrors test-policy-yaml-fails-open.sh: each fixture uses a
# fresh temp cwd so the loader's relative `.rein/policy/` resolution is
# isolated and the rein-dev repo's own .rein/ is never touched. The builtin
# tier is served from a FAKE plugin-root fixture tree inside the temp dir
# (rules/persona/{boss-ace,jennie,_invariant}.md stubs) so this test never
# depends on the real plugin tree.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"
FALLBACK_LOADER="$PROJECT_DIR/scripts/rein-policy-loader.py"

if [ ! -x "$PLUGIN_LOADER" ]; then
  echo "FAIL: plugin loader missing or not executable: $PLUGIN_LOADER" >&2
  exit 1
fi
if [ ! -x "$FALLBACK_LOADER" ]; then
  echo "FAIL: fallback loader missing or not executable: $FALLBACK_LOADER" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
fail() {
  echo "FAIL: $1" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

# -----------------------------------------------------------------------------
# Fake plugin-root fixture tree (builtin tier). boss-ace / jennie now carry an
# EXACT `---`(LF) frontmatter with BOTH `summary:` and `greeting:` so the greeting
# read path (--persona-greeting) AND the turn-brief summary read path resolve real
# fields (path-only resolution still works too — is_file unchanged). Marker values
# are ASCII sentinels (SUMMARY_*_7f3a / ZZ_GREET_*_7f3a) embedded in Korean text:
# json.dumps(ensure_ascii) \u-escapes the Korean but leaves the ASCII markers
# verbatim, so substring asserts on the JSON turn-brief envelope stay reliable.
# _invariant.md stays a bare heading (its underscore name is a format violation,
# so it never reaches a body read).
# -----------------------------------------------------------------------------
FIXTURE_ROOT="$TMP_ROOT/plugin-root"
mkdir -p "$FIXTURE_ROOT/rules/persona"
# Builtin greeting/summary sentinels — reused by --persona-greeting positives
# (equality, g1/g2) and the turn-brief leak probe (tb1/tb2): boss-ace's greeting
# must NOT appear in --turn-brief output while its summary MUST.
BOSS_SUMMARY='보스라 부르는 조직의 에이스 SUMMARY_BOSS_7f3a'
BOSS_GREETING='보스! 에이스 대기 완료 ZZ_GREET_BOSS_7f3a'
JENNIE_SUMMARY='애교의 여동생 SUMMARY_JENNIE_7f3a'
JENNIE_GREETING='오빠 저 왔어요 ZZ_GREET_JENNIE_7f3a'
printf '%s\n' \
  '---' \
  "summary: $BOSS_SUMMARY" \
  "greeting: $BOSS_GREETING" \
  '---' \
  '# Persona: boss-ace (fixture stub)' \
  >"$FIXTURE_ROOT/rules/persona/boss-ace.md"
printf '%s\n' \
  '---' \
  "summary: $JENNIE_SUMMARY" \
  "greeting: $JENNIE_GREETING" \
  '---' \
  '# Persona: jennie (fixture stub)' \
  >"$FIXTURE_ROOT/rules/persona/jennie.md"
printf '%s\n' '# Persona invariant (fixture stub)' >"$FIXTURE_ROOT/rules/persona/_invariant.md"
# Expected paths are RESOLVED (realpath) — the loader's builtin tier now
# .resolve()s to honor the absolute-path CLI contract, which on macOS also
# canonicalizes the mktemp /var -> /private/var symlink.
BUILTIN_BOSS="$(python3 -c "from pathlib import Path; print(Path('$FIXTURE_ROOT/rules/persona/boss-ace.md').resolve())")"
BUILTIN_JENNIE="$(python3 -c "from pathlib import Path; print(Path('$FIXTURE_ROOT/rules/persona/jennie.md').resolve())")"

# Create a fresh case dir with the given persona.yaml body ($1, or no file when
# the literal token __NOFILE__). Sets global CASE_DIR. Callers may then plant
# extra fixtures (custom persona files, symlinks) before run_case.
prep_case() {
  local body="$1"
  CASE_DIR="$(mktemp -d "$TMP_ROOT/case.XXXXXX")"
  mkdir -p "$CASE_DIR/.rein/policy"
  if [ "$body" != "__NOFILE__" ]; then
    printf '%s' "$body" >"$CASE_DIR/.rein/policy/persona.yaml"
  fi
}

# Run BOTH `--persona` and `--persona-file` inside CASE_DIR. $1 selects the
# CLAUDE_PLUGIN_ROOT: a path (usually $FIXTURE_ROOT), or the literal token
# __NOROOT__ to run with the variable UNSET (D1 cases). Captures stdout/exit
# into P_OUT/P_RC (persona name) and F_OUT/F_RC (persona file). Runs with the
# DEFAULT PYTHONPATH (the PyYAML-absent shim in assert (n7) is isolated).
run_case() {
  local root="$1"
  set +e
  if [ "$root" = "__NOROOT__" ]; then
    P_OUT="$(cd "$CASE_DIR" && env -u CLAUDE_PLUGIN_ROOT python3 "$PLUGIN_LOADER" --persona 2>/dev/null)"
    P_RC=$?
    F_OUT="$(cd "$CASE_DIR" && env -u CLAUDE_PLUGIN_ROOT python3 "$PLUGIN_LOADER" --persona-file 2>/dev/null)"
    F_RC=$?
  else
    P_OUT="$(cd "$CASE_DIR" && CLAUDE_PLUGIN_ROOT="$root" python3 "$PLUGIN_LOADER" --persona 2>/dev/null)"
    P_RC=$?
    F_OUT="$(cd "$CASE_DIR" && CLAUDE_PLUGIN_ROOT="$root" python3 "$PLUGIN_LOADER" --persona-file 2>/dev/null)"
    F_RC=$?
  fi
  set -e
}

# Convenience: prep + run with the fixture plugin root.
run_persona() {
  prep_case "$1"
  run_case "${2:-$FIXTURE_ROOT}"
}

assert_rc0() {
  local label="$1"
  [ "$P_RC" = "0" ] || fail "$label: --persona expected exit 0, got $P_RC"
  [ "$F_RC" = "0" ] || fail "$label: --persona-file expected exit 0, got $F_RC"
}

# NEUTRAL: both CLIs silent, exit 0.
expect_neutral() {
  local label="$1" body="$2"
  run_persona "$body"
  assert_rc0 "$label"
  [ -z "$P_OUT" ] || fail "$label: --persona expected EMPTY stdout (neutral default), got '$P_OUT'"
  [ -z "$F_OUT" ] || fail "$label: --persona-file expected EMPTY stdout (neutral default), got '$F_OUT'"
  ok "$label"
}

# ACTIVE with a specific name + resolved source path.
assert_active() {
  local label="$1" name="$2" path="$3"
  assert_rc0 "$label"
  [ "$P_OUT" = "$name" ] || fail "$label: --persona expected '$name', got '$P_OUT'"
  [ "$F_OUT" = "$path" ] || fail "$label: --persona-file expected '$path', got '$F_OUT'"
  ok "$label"
}

# DOWNGRADE: enabled but unresolvable/invalid preset -> boss-ace + builtin path.
expect_downgrade() {
  local label="$1" body="$2"
  run_persona "$body"
  assert_active "$label" "boss-ace" "$BUILTIN_BOSS"
}

# -----------------------------------------------------------------------------
# (a) byte-identical drift guard (PP-5): the two loader copies (plugin SSOT +
#     root fallback) must be byte-for-byte identical. A drift here would let the
#     plugin and fallback resolvers disagree on persona resolution.
# -----------------------------------------------------------------------------
if diff "$PLUGIN_LOADER" "$FALLBACK_LOADER" >/dev/null 2>&1; then
  ok "(a) two loader copies byte-identical (diff empty)"
else
  echo "  --- diff plugin vs fallback ---" >&2
  diff "$PLUGIN_LOADER" "$FALLBACK_LOADER" >&2 || true
  fail "(a) loader copies differ (PP-5 drift): plugin SSOT and root fallback must be byte-identical"
fi

# -----------------------------------------------------------------------------
# (n) NEUTRAL DEFAULT — every non-`enabled: true` state yields empty stdout on
#     BOTH `--persona` and `--persona-file`, exit 0. This replaces the old
#     default-ON (b)/(c)/(e) contract.
# -----------------------------------------------------------------------------
expect_neutral "(n1) missing persona.yaml -> neutral (empty)" "__NOFILE__"
expect_neutral "(n2) parse-error YAML (enabled: : :) -> neutral" $'enabled: : :\n'
expect_neutral "(n3) non-dict top-level (- a) -> neutral" $'- a\n'
expect_neutral "(n4) enabled key absent (preset only) -> neutral" $'preset: boss-ace\n'
expect_neutral "(n5) enabled: \"true\" (string, not bool True) -> neutral" $'enabled: "true"\npreset: boss-ace\n'
expect_neutral "(n6) enabled: 1 (int, not bool True) -> neutral" $'enabled: 1\npreset: boss-ace\n'
expect_neutral "(n8) explicit enabled: false -> neutral (canonical off)" $'enabled: false\npreset: boss-ace\n'

# -----------------------------------------------------------------------------
# (n7) PyYAML-absent branch — shim a fake `yaml.py` that raises ImportError on
#      `import yaml`, place it FIRST on PYTHONPATH so the loader's top-level
#      `import yaml` hits it, falling into `except ImportError: yaml = None`.
#      NEW contract: yaml=None means the enabled:true opt-in CANNOT be read, so
#      the loader stays NEUTRAL (empty stdout on both CLIs), exit 0. Isolated
#      to subshells so the poisoned PYTHONPATH never leaks to other asserts.
# -----------------------------------------------------------------------------
FAKE_DIR="$TMP_ROOT/fakeyaml"
mkdir -p "$FAKE_DIR"
printf '%s\n' 'raise ImportError("simulated missing PyYAML")' >"$FAKE_DIR/yaml.py"
C_DIR="$(mktemp -d "$TMP_ROOT/noyaml.XXXXXX")"
mkdir -p "$C_DIR/.rein/policy"
# A perfectly valid opt-in persona.yaml: proves the neutral result is driven by
# the absent-PyYAML branch, not by a parse/shape error.
printf '%s\n%s\n' 'enabled: true' 'preset: boss-ace' >"$C_DIR/.rein/policy/persona.yaml"
set +e
C_P_OUT="$(
  cd "$C_DIR" && \
  CLAUDE_PLUGIN_ROOT="$FIXTURE_ROOT" \
  PYTHONPATH="$FAKE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$PLUGIN_LOADER" --persona 2>/dev/null
)"
C_P_RC=$?
C_F_OUT="$(
  cd "$C_DIR" && \
  CLAUDE_PLUGIN_ROOT="$FIXTURE_ROOT" \
  PYTHONPATH="$FAKE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$PLUGIN_LOADER" --persona-file 2>/dev/null
)"
C_F_RC=$?
set -e
[ "$C_P_RC" = "0" ] || fail "(n7) PyYAML absent: --persona expected exit 0, got $C_P_RC"
[ "$C_F_RC" = "0" ] || fail "(n7) PyYAML absent: --persona-file expected exit 0, got $C_F_RC"
[ -z "$C_P_OUT" ] || fail "(n7) PyYAML absent: --persona expected EMPTY stdout (neutral), got '$C_P_OUT'"
[ -z "$C_F_OUT" ] || fail "(n7) PyYAML absent: --persona-file expected EMPTY stdout (neutral), got '$C_F_OUT'"
# Sanity: confirm the shim actually broke `import yaml` (guard against a stdlib
# path or installed PyYAML silently shadowing the fake and giving a false pass).
set +e
SHIM_PROBE="$(
  cd "$C_DIR" && \
  PYTHONPATH="$FAKE_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -c 'import yaml' 2>&1
)"
SHIM_RC=$?
set -e
[ "$SHIM_RC" != "0" ] || fail "(n7) PyYAML shim ineffective: 'import yaml' unexpectedly succeeded (fake not first on PYTHONPATH)"
case "$SHIM_PROBE" in
  *"simulated missing PyYAML"*) : ;;
  *) fail "(n7) PyYAML shim ineffective: import error was not the simulated one: $SHIM_PROBE" ;;
esac
ok "(n7) PyYAML absent (PYTHONPATH shim) -> exit 0 + neutral (empty both CLIs)"

# -----------------------------------------------------------------------------
# (u) existing-user continuity — an explicit enabled:true opt-in keeps working
#     and `--persona-file` resolves the builtin path under the fixture root.
# -----------------------------------------------------------------------------
run_persona $'enabled: true\npreset: boss-ace\n'
assert_active "(u1) enabled:true + preset:boss-ace -> boss-ace + builtin path" \
  "boss-ace" "$BUILTIN_BOSS"

run_persona $'enabled: true\npreset: jennie\n'
assert_active "(u2) enabled:true + preset:jennie -> jennie + builtin path" \
  "jennie" "$BUILTIN_JENNIE"

# -----------------------------------------------------------------------------
# (d) downgrade (PP-3 extended): enabled + format-violating or unresolvable
#     preset -> boss-ace name AND builtin boss-ace path (never a composed
#     malicious path, never a missing file).
# -----------------------------------------------------------------------------
expect_downgrade "(d1) preset ../x (traversal) -> boss-ace + builtin path" $'enabled: true\npreset: "../x"\n'
expect_downgrade "(d2) preset a/b (slash) -> boss-ace + builtin path" $'enabled: true\npreset: "a/b"\n'
expect_downgrade "(d3) preset \$(x) (substitution) -> boss-ace + builtin path" $'enabled: true\npreset: "$(x)"\n'
expect_downgrade "(d4) preset empty string -> boss-ace + builtin path" $'enabled: true\npreset: ""\n'
expect_downgrade "(d5) preset mentor (unregistered, no custom file) -> boss-ace + builtin path" $'enabled: true\npreset: mentor\n'
expect_downgrade "(d6) preset _invariant (underscore = format violation, never selectable) -> boss-ace + builtin path" $'enabled: true\npreset: _invariant\n'

# -----------------------------------------------------------------------------
# (c) custom resolution — `.rein/policy/persona/<name>.md` under the case cwd,
#     accepted only after validation (containment + UTF-8 decode + <=4000
#     chars); builtin names always win over same-name customs.
# -----------------------------------------------------------------------------

# (c0) happy path: valid custom mia.md -> name mia + its resolved absolute path.
prep_case $'enabled: true\npreset: mia\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '%s\n%s\n%s\n%s\n' \
  '---' \
  'summary: 테스트용 커스텀 페르소나' \
  '---' \
  '# Persona: mia (custom fixture)' \
  >"$CASE_DIR/.rein/policy/persona/mia.md"
MIA_EXPECTED="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve())' \
  "$CASE_DIR/.rein/policy/persona/mia.md")"
run_case "$FIXTURE_ROOT"
assert_active "(c0) valid custom mia -> mia + resolved custom path" "mia" "$MIA_EXPECTED"

# (c1) oversize custom (4001 chars) -> validation fails -> boss-ace downgrade.
prep_case $'enabled: true\npreset: mia\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; sys.stdout.write("x" * 4001)' >"$CASE_DIR/.rein/policy/persona/mia.md"
run_case "$FIXTURE_ROOT"
assert_active "(c1) oversize custom (4001 chars) -> boss-ace downgrade" "boss-ace" "$BUILTIN_BOSS"

# (c2) same-name custom shadowing a builtin -> builtin path wins, custom ignored.
prep_case $'enabled: true\npreset: boss-ace\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '%s\n' '# Persona: boss-ace (malicious same-name custom, must be ignored)' \
  >"$CASE_DIR/.rein/policy/persona/boss-ace.md"
run_case "$FIXTURE_ROOT"
assert_active "(c2) same-name custom boss-ace -> builtin path wins (custom ignored)" \
  "boss-ace" "$BUILTIN_BOSS"

# (c3) symlink escaping .rein/policy/persona/ -> containment fails -> downgrade.
prep_case $'enabled: true\npreset: mia\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '%s\n' 'outside content (must never be selectable via symlink)' >"$CASE_DIR/outside.md"
ln -s ../../../outside.md "$CASE_DIR/.rein/policy/persona/mia.md"
run_case "$FIXTURE_ROOT"
assert_active "(c3) symlink custom escaping persona dir -> boss-ace downgrade" \
  "boss-ace" "$BUILTIN_BOSS"

# (c4) UTF-8 decode failure -> validation fails -> downgrade.
prep_case $'enabled: true\npreset: mia\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '\xff\xfe' >"$CASE_DIR/.rein/policy/persona/mia.md"
run_case "$FIXTURE_ROOT"
assert_active "(c4) non-UTF-8 custom bytes -> boss-ace downgrade" "boss-ace" "$BUILTIN_BOSS"

# -----------------------------------------------------------------------------
# (r) D1 — CLAUDE_PLUGIN_ROOT unset: the invariant layer is unresolvable, so
#     `--persona-file` must be EMPTY in every case (no custom-only resolution),
#     while `--persona` stays deterministic at name level. Exit 0 always.
# -----------------------------------------------------------------------------

# (r1) builtin preset, no root -> name kept, NO path.
run_persona $'enabled: true\npreset: boss-ace\n' "__NOROOT__"
assert_rc0 "(r1) no-root builtin"
[ "$P_OUT" = "boss-ace" ] || fail "(r1) no-root builtin: --persona expected 'boss-ace', got '$P_OUT'"
[ -z "$F_OUT" ] || fail "(r1) no-root builtin: --persona-file expected EMPTY stdout (D1), got '$F_OUT'"
ok "(r1) no-root + preset:boss-ace -> name kept, --persona-file empty (D1)"

# (r2) valid custom, no root -> name kept, NO path (custom-only resolution is
#      forbidden when the invariant layer cannot be resolved).
prep_case $'enabled: true\npreset: mia\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '%s\n%s\n%s\n%s\n' \
  '---' \
  'summary: 테스트용 커스텀 페르소나' \
  '---' \
  '# Persona: mia (custom fixture)' \
  >"$CASE_DIR/.rein/policy/persona/mia.md"
run_case "__NOROOT__"
assert_rc0 "(r2) no-root custom"
[ "$P_OUT" = "mia" ] || fail "(r2) no-root custom: --persona expected 'mia' (name-level deterministic), got '$P_OUT'"
[ -z "$F_OUT" ] || fail "(r2) no-root custom: --persona-file expected EMPTY stdout (D1, custom-only forbidden), got '$F_OUT'"
ok "(r2) no-root + valid custom mia -> name kept, --persona-file empty (D1)"

# (r3) RELATIVE CLAUDE_PLUGIN_ROOT -> --persona-file still prints an ABSOLUTE
#      path (CLI contract; integrated-review Low regression — builtin tier
#      must .resolve() like the custom tier does).
prep_case $'enabled: true\npreset: boss-ace\n'
REL_ROOT="rel-plugin-root"
mkdir -p "$CASE_DIR/$REL_ROOT/rules/persona"
cp "$FIXTURE_ROOT/rules/persona/boss-ace.md" "$CASE_DIR/$REL_ROOT/rules/persona/boss-ace.md"
run_case "$REL_ROOT"
assert_rc0 "(r3) relative root"
case "$F_OUT" in
  /*) ok "(r3) relative CLAUDE_PLUGIN_ROOT -> --persona-file absolute ($F_OUT)" ;;
  "") fail "(r3) relative root: --persona-file expected absolute path, got EMPTY" ;;
  *)  fail "(r3) relative root: --persona-file expected absolute path, got relative '$F_OUT'" ;;
esac

# =============================================================================
# (g) Task 5.1 — `--persona-greeting <name>`: builtin/custom positives, invalid
#     names, and D1. Greeting is read from the frontmatter `greeting:` of a
#     VALIDATED preset only; typos/traversal/invalid customs yield EMPTY stdout,
#     never the boss-ace curated line (High-1: no downgrade in this boundary).
# =============================================================================

# Run `--persona-greeting <name>`. $1=name, $2=root ($FIXTURE_ROOT or
# __NOROOT__), $3=cwd (default: a fresh temp; pass a prepared CASE_DIR to test a
# custom under .rein/policy/persona). Captures G_OUT / G_RC.
run_greeting() {
  local name="$1" root="$2" dir="${3:-}"
  [ -n "$dir" ] || dir="$(mktemp -d "$TMP_ROOT/greet.XXXXXX")"
  set +e
  if [ "$root" = "__NOROOT__" ]; then
    G_OUT="$(cd "$dir" && env -u CLAUDE_PLUGIN_ROOT python3 "$PLUGIN_LOADER" --persona-greeting "$name" 2>/dev/null)"
    G_RC=$?
  else
    G_OUT="$(cd "$dir" && CLAUDE_PLUGIN_ROOT="$root" python3 "$PLUGIN_LOADER" --persona-greeting "$name" 2>/dev/null)"
    G_RC=$?
  fi
  set -e
}

assert_greeting() {
  local label="$1" expected="$2"
  [ "$G_RC" = "0" ] || fail "$label: --persona-greeting expected exit 0, got $G_RC"
  [ "$G_OUT" = "$expected" ] || fail "$label: --persona-greeting expected '$expected', got '$G_OUT'"
  ok "$label"
}

# Empty stdout AND explicitly NOT the boss-ace greeting (High-1: no typo/invalid
# name may downgrade to the boss-ace curated line via --persona-greeting).
assert_greeting_empty() {
  local label="$1"
  [ "$G_RC" = "0" ] || fail "$label: --persona-greeting expected exit 0, got $G_RC"
  case "$G_OUT" in
    *"$BOSS_GREETING"*) fail "$label: --persona-greeting leaked boss-ace greeting (forbidden downgrade), got '$G_OUT'" ;;
  esac
  [ -z "$G_OUT" ] || fail "$label: --persona-greeting expected EMPTY stdout, got '$G_OUT'"
  ok "$label"
}

# --- builtin positives -------------------------------------------------------
run_greeting "boss-ace" "$FIXTURE_ROOT"
assert_greeting "(g1) --persona-greeting boss-ace -> stub greeting (builtin positive)" "$BOSS_GREETING"
run_greeting "jennie" "$FIXTURE_ROOT"
assert_greeting "(g2) --persona-greeting jennie -> stub greeting (builtin positive)" "$JENNIE_GREETING"

# --- custom positive: greeting present -> flows out verbatim -----------------
GREET_C1_DIR="$(mktemp -d "$TMP_ROOT/greetc1.XXXXXX")"
mkdir -p "$GREET_C1_DIR/.rein/policy/persona"
CUSTOM_GREETING='커스텀 인사 ZZ_GREET_CUSTOM_7f3a'
printf '%s\n' \
  '---' \
  'summary: 커스텀 요약 (greeting 공존)' \
  "greeting: $CUSTOM_GREETING" \
  '---' \
  '# Persona: nova (custom greeting fixture)' \
  >"$GREET_C1_DIR/.rein/policy/persona/nova.md"
run_greeting "nova" "$FIXTURE_ROOT" "$GREET_C1_DIR"
assert_greeting "(g3) valid custom nova WITH greeting -> stored greeting verbatim (custom positive)" "$CUSTOM_GREETING"

# --- custom negative: greeting absent (summary only) -> empty (fallback tier) -
GREET_C2_DIR="$(mktemp -d "$TMP_ROOT/greetc2.XXXXXX")"
mkdir -p "$GREET_C2_DIR/.rein/policy/persona"
printf '%s\n' \
  '---' \
  'summary: 인사말 없는 커스텀 요약' \
  '---' \
  '# Persona: lumen (custom, greeting absent)' \
  >"$GREET_C2_DIR/.rein/policy/persona/lumen.md"
run_greeting "lumen" "$FIXTURE_ROOT" "$GREET_C2_DIR"
assert_greeting_empty "(g4) valid custom lumen WITHOUT greeting -> empty (custom negative, fallback target)"

# --- invalid names (6) -> empty, exit 0, NOT boss-ace greeting (High-1) -------
run_greeting "../x" "$FIXTURE_ROOT"
assert_greeting_empty "(g5) --persona-greeting ../x (traversal) -> empty (no downgrade)"
run_greeting "a/b" "$FIXTURE_ROOT"
assert_greeting_empty "(g6) --persona-greeting a/b (slash) -> empty (no downgrade)"
run_greeting '$(x)' "$FIXTURE_ROOT"
assert_greeting_empty "(g7) --persona-greeting \$(x) (substitution) -> empty (no downgrade)"
run_greeting "" "$FIXTURE_ROOT"
assert_greeting_empty "(g8) --persona-greeting '' (empty name) -> empty (no downgrade)"
run_greeting "mentor" "$FIXTURE_ROOT"
assert_greeting_empty "(g9) --persona-greeting mentor (unregistered, no file) -> empty (no downgrade)"
run_greeting "_invariant" "$FIXTURE_ROOT"
assert_greeting_empty "(g10) --persona-greeting _invariant (underscore, format violation) -> empty (no downgrade)"

# --- D1: CLAUDE_PLUGIN_ROOT unset -> empty even for a valid builtin name ------
run_greeting "boss-ace" "__NOROOT__"
assert_greeting_empty "(g11) no-root + boss-ace -> empty greeting (D1 invariant layer unresolvable)"

# --- (g12/g13) pathological root -> OSError ENAMETOOLONG must FAIL-OPEN --------
# integrated-review Medium: _resolve_persona_file wraps .resolve()/is_file(), so
# an over-long CLAUDE_PLUGIN_ROOT (Path.resolve/is_file raises OSError) yields
# None instead of a traceback. BOTH persona paths keep their "empty stdout +
# exit 0" contract. Regression for the 5000-char root repro (pre-fix: exit 1 +
# traceback on both --persona-greeting and --persona-file).
PATHOLOGICAL_ROOT="/$(python3 -c 'print("a"*5000)')"
PR_G_OUT="$(CLAUDE_PLUGIN_ROOT="$PATHOLOGICAL_ROOT" python3 "$PLUGIN_LOADER" --persona-greeting boss-ace 2>/dev/null)"; PR_G_RC=$?
[ "$PR_G_RC" = "0" ] || fail "(g12) pathological root: --persona-greeting expected exit 0 (fail-open), got $PR_G_RC"
[ -z "$PR_G_OUT" ] || fail "(g12) pathological root: --persona-greeting expected EMPTY stdout, got '$PR_G_OUT'"
ok "(g12) pathological root (ENAMETOOLONG) -> --persona-greeting empty + exit 0 (fail-open, no traceback)"
PR_F_OUT="$(CLAUDE_PLUGIN_ROOT="$PATHOLOGICAL_ROOT" python3 "$PLUGIN_LOADER" --persona-file boss-ace 2>/dev/null)"; PR_F_RC=$?
[ "$PR_F_RC" = "0" ] || fail "(g13) pathological root: --persona-file expected exit 0 (fail-open), got $PR_F_RC"
[ -z "$PR_F_OUT" ] || fail "(g13) pathological root: --persona-file expected EMPTY stdout, got '$PR_F_OUT'"
ok "(g13) pathological root (ENAMETOOLONG) -> --persona-file empty + exit 0 (fail-open, no traceback)"

# =============================================================================
# (f) Task 5.1 step 3 — a (P)∧¬(A) fence custom is NOT loaded by EITHER boundary:
#       --persona-file      -> downgrade to boss-ace (custom ignored)
#       --persona-greeting  -> empty (custom greeting never leaks)
#     Fixtures are written with EXACT bytes (python3 wb) so bare-CR / CRLF /
#     U+2028 / U+2029 survive universal-newline normalization. One rule (spec §4)
#     closes them all uniformly.
# =============================================================================

# Prep enabled:true + preset:<name>, plant a fence fixture, verify BOTH boundaries.
assert_fence_rejected() {
  local label="$1" name="$2"
  run_case "$FIXTURE_ROOT"
  assert_active "$label [--persona-file downgrade -> boss-ace]" "boss-ace" "$BUILTIN_BOSS"
  run_greeting "$name" "$FIXTURE_ROOT" "$CASE_DIR"
  assert_greeting_empty "$label [--persona-greeting empty]"
}

# (f1) padded ` --- ` open fence.
prep_case $'enabled: true\npreset: padfence\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; open(sys.argv[1],"wb").write(b" --- \nsummary: padded fence\ngreeting: PAD_LEAK_7f3a\n --- \n# body\n")' \
  "$CASE_DIR/.rein/policy/persona/padfence.md"
assert_fence_rejected "(f1) padded ' --- ' open fence custom" "padfence"

# (f2) CRLF `---\r\n`.
prep_case $'enabled: true\npreset: crlffence\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; open(sys.argv[1],"wb").write(b"---\r\nsummary: crlf fence\r\ngreeting: CRLF_LEAK_7f3a\r\n---\r\n# body\r\n")' \
  "$CASE_DIR/.rein/policy/persona/crlffence.md"
assert_fence_rejected "(f2) CRLF ---CRLF fence custom" "crlffence"

# (f3) bare-CR `---\r` with NO `\n` anywhere in the file.
prep_case $'enabled: true\npreset: barecrfence\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; open(sys.argv[1],"wb").write(b"---\rsummary: bare cr fence\rgreeting: BARECR_LEAK_7f3a\r# body\r")' \
  "$CASE_DIR/.rein/policy/persona/barecrfence.md"
assert_fence_rejected "(f3) bare-CR ---CR fence custom (no LF in file)" "barecrfence"

# (f4) U+2028 line separator.
prep_case $'enabled: true\npreset: u2028fence\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; sep="\u2028"; open(sys.argv[1],"wb").write(("---"+sep+"summary: u2028 fence"+sep+"greeting: U2028_LEAK_7f3a"+sep+"# body"+sep).encode("utf-8"))' \
  "$CASE_DIR/.rein/policy/persona/u2028fence.md"
assert_fence_rejected "(f4) U+2028 line-separator fence custom" "u2028fence"

# (f5) U+2029 paragraph separator.
prep_case $'enabled: true\npreset: u2029fence\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; sep="\u2029"; open(sys.argv[1],"wb").write(("---"+sep+"summary: u2029 fence"+sep+"greeting: U2029_LEAK_7f3a"+sep+"# body"+sep).encode("utf-8"))' \
  "$CASE_DIR/.rein/policy/persona/u2029fence.md"
assert_fence_rejected "(f5) U+2029 paragraph-separator fence custom" "u2029fence"

# =============================================================================
# (bc) Task 5.1 step 3 backward compat — exact `---`(LF) fence customs (closed
#      AND unclosed) and no-frontmatter customs stay VALID (loaded, never
#      downgraded). Rejection is (P)∧¬(A)-only; these are (P)∧(A) or ¬(P).
# =============================================================================

# (bc1/bc2) exact-LF CLOSED fence custom -> loaded (custom path), greeting flows.
prep_case $'enabled: true\npreset: aurora\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
AURORA_GREETING='정확 LF 인사 ZZ_GREET_AURORA_7f3a'
printf '%s\n' \
  '---' \
  'summary: 정확 LF 요약' \
  "greeting: $AURORA_GREETING" \
  '---' \
  '# Persona: aurora (exact-LF fence custom)' \
  >"$CASE_DIR/.rein/policy/persona/aurora.md"
AURORA_EXPECTED="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve())' \
  "$CASE_DIR/.rein/policy/persona/aurora.md")"
run_case "$FIXTURE_ROOT"
assert_active "(bc1) exact-LF fence custom aurora stays valid (loaded, not downgraded)" "aurora" "$AURORA_EXPECTED"
run_greeting "aurora" "$FIXTURE_ROOT" "$CASE_DIR"
assert_greeting "(bc2) exact-LF fence custom aurora -> greeting flows" "$AURORA_GREETING"

# (bc3/bc4) exact-LF UNCLOSED fence custom -> still valid (awk swallows body ->
# no leak); greeting parser requires closure so the greeting is empty.
prep_case $'enabled: true\npreset: unclosedlf\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
python3 -c 'import sys; open(sys.argv[1],"wb").write(b"---\nsummary: unclosed lf\ngreeting: UNCLOSED_LEAK_7f3a\n# body with no closing fence\n")' \
  "$CASE_DIR/.rein/policy/persona/unclosedlf.md"
UNCLOSED_EXPECTED="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve())' \
  "$CASE_DIR/.rein/policy/persona/unclosedlf.md")"
run_case "$FIXTURE_ROOT"
assert_active "(bc3) unclosed exact-LF fence custom stays valid (loaded, not downgraded)" "unclosedlf" "$UNCLOSED_EXPECTED"
run_greeting "unclosedlf" "$FIXTURE_ROOT" "$CASE_DIR"
assert_greeting_empty "(bc4) unclosed exact-LF fence custom -> greeting empty (closure required)"

# (bc5/bc6) no-frontmatter custom -> still valid (loaded), greeting empty.
prep_case $'enabled: true\npreset: nofm\n'
mkdir -p "$CASE_DIR/.rein/policy/persona"
printf '%s\n' \
  '# Persona: nofm (no frontmatter at all)' \
  'just a heading, no leading fence' \
  >"$CASE_DIR/.rein/policy/persona/nofm.md"
NOFM_EXPECTED="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve())' \
  "$CASE_DIR/.rein/policy/persona/nofm.md")"
run_case "$FIXTURE_ROOT"
assert_active "(bc5) no-frontmatter custom nofm stays valid (loaded, not downgraded)" "nofm" "$NOFM_EXPECTED"
run_greeting "nofm" "$FIXTURE_ROOT" "$CASE_DIR"
assert_greeting_empty "(bc6) no-frontmatter custom -> greeting empty"

# =============================================================================
# (tb) Task 5.3 — turn-brief reads ONLY `summary:`, never the `greeting:` VALUE.
#      The active preset carries a distinctive ASCII greeting sentinel; assert
#      the turn-brief envelope contains the summary marker but NOT the greeting
#      value. (Checking the VALUE, not the literal token "greeting": the real
#      greeting text has no "greeting" substring, so a value-leak would slip past
#      a token check.) turn-brief needs rules/short/ summaries under the plugin
#      root: answer-only is the hard requirement, persona-summary makes the
#      active-preset line appear.
# =============================================================================
mkdir -p "$FIXTURE_ROOT/rules/short"
printf '%s\n' '답변만 하라 (fixture answer-only summary).' >"$FIXTURE_ROOT/rules/short/answer-only-summary.md"
printf '%s\n' '톤만 조정, 판단 불변 (fixture persona nudge).' >"$FIXTURE_ROOT/rules/short/persona-summary.md"

prep_case $'enabled: true\npreset: boss-ace\n'
set +e
TB_OUT="$(cd "$CASE_DIR" && CLAUDE_PLUGIN_ROOT="$FIXTURE_ROOT" python3 "$PLUGIN_LOADER" --turn-brief 2>/dev/null)"
TB_RC=$?
set -e
[ "$TB_RC" = "0" ] || fail "(tb1) turn-brief expected exit 0, got $TB_RC"
[ -n "$TB_OUT" ] || fail "(tb1) turn-brief expected a non-empty envelope (short/ summaries present), got EMPTY"
case "$TB_OUT" in
  *"SUMMARY_BOSS_7f3a"*) ok "(tb1) turn-brief includes active preset summary marker (summary: is read)" ;;
  *) fail "(tb1) turn-brief missing active preset summary marker SUMMARY_BOSS_7f3a: $TB_OUT" ;;
esac
# The greeting sentinel is plain ASCII, so json.dumps would leave it verbatim if
# ever emitted; its absence proves the greeting VALUE never reaches turn-brief.
case "$TB_OUT" in
  *"ZZ_GREET_BOSS_7f3a"*) fail "(tb2) turn-brief LEAKED greeting sentinel value ZZ_GREET_BOSS_7f3a: $TB_OUT" ;;
  *) ok "(tb2) turn-brief omits greeting value (summary-only injection, no greeting leak)" ;;
esac

echo ""
echo "test-policy-loader-persona: OK ($PASS asserts passed)"
