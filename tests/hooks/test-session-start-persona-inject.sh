#!/usr/bin/env bash
# tests/hooks/test-session-start-persona-inject.sh — persona hook contract
# (invariant layer + frontmatter strip + neutral default + custom presets)
#
# Functional regression test for the DEDICATED persona SessionStart hook
# plugins/rein-core/hooks/session-start-persona.sh, driven against the REAL
# plugin tree (no hook copies). Contract under test (persona-user-selection
# plan, Phase 2 / Task 2.1):
#
#   - The hook consumes ONE loader answer (`--persona-file` resolved path) and
#     never composes preset paths itself (single trust boundary, spec §10).
#   - The emitted envelope = invariant layer (_invariant.md) + frontmatter-
#     stripped preset body. The invariant fingerprint appears EXACTLY once.
#   - Neutral default: no persona.yaml -> no envelope (opt-in, not default-ON).
#   - Custom presets under <cwd>/.rein/policy/persona/<name>.md are injectable,
#     but builtin names always win over same-named customs.
#
# Assertions (real hook via stdout envelope; PASS/FAIL tally, no fail-fast so
# a RED run reports every broken clause):
#   (a) enabled:true, preset:boss-ace -> envelope has boss-ace fingerprint AND
#       invariant fingerprint (exactly once); ctx neither starts with "---"
#       nor contains "summary:" nor the boss-ace "greeting:" value (frontmatter
#       stripped — (a5) pins greeting non-injection, Task 5.4).
#   (b) enabled:false               -> EMPTY stdout (no envelope; opt-out).
#   (c) unknown preset (mentor, no custom file) -> downgraded to boss-ace,
#       body + invariant present (PP-3 membership fail-safe).
#   (d) hooks.json registers session-start-persona.sh AFTER session-start-
#       rules.sh ("tone applied last" ordering).
#   (e) persona.yaml absent          -> EMPTY stdout (neutral default — flips
#       the old default-ON contract; Low advisory 1).
#   (f) custom preset: .rein/policy/persona/mia.md (frontmatter summary) +
#       preset:mia -> envelope has "# Persona: mia" + invariant, no "summary:".
#   (g) builtin-wins: custom .rein/policy/persona/boss-ace.md (different body)
#       + preset:boss-ace -> envelope carries the PLUGIN boss-ace body; the
#       custom body fingerprint is ABSENT.
#   (h) static single-trust-boundary check on the hook source: consumes
#       `--persona-file`, and the self-composition pattern
#       `RULES_DIR/persona/${PERSONA}` is gone. Source-unchanged pins (Task
#       5.4): the frontmatter awk-strip line `NR==1 && $0=="---"` survives (h3),
#       and the hook never references `--persona-greeting` (h4) — greeting is a
#       skill-only read; the hook consumes only `--persona-file`.
#   (i) (P)∧¬(A) awk-mismatch fence CUSTOM (padded ` --- ` / CRLF `---\r` /
#       bare-CR `---\r` no-`\n` / U+2028, written as EXACT bytes) activated by
#       name -> the loader's _custom_persona_valid rejects it and downgrades to
#       boss-ace, so none of the custom's greeting/body sentinels reach the
#       injected envelope (runtime no-leak boundary — Task 5.4, R5/R6/R7 leak
#       classes).
#
# covers: hook-injects-invariant-layer-plus-frontmatter-stripped-preset-from-loader-path-only,
#         invariant-file-underscore-name-never-selectable-as-preset,
#         session-start-persona-hook-unmodified-and-greeting-absent-from-injected-body
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/session-start-persona.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
BOSS_ACE="$PLUGIN_ROOT/rules/persona/boss-ace.md"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

# Preconditions — a missing harness input is an ERROR (hard exit), not a RED.
[ -f "$HOOK" ]     || { echo "ERROR: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ]     || { echo "ERROR: $HOOK is not executable" >&2; exit 1; }
[ -f "$LOADER" ]   || { echo "ERROR: $LOADER missing" >&2; exit 1; }
[ -f "$BOSS_ACE" ] || { echo "ERROR: $BOSS_ACE missing" >&2; exit 1; }

# Fingerprints — literal substrings so a body rewrite that drops them fails
# loudly (and is fixed deliberately).
PERSONA_FINGERPRINT="# Persona: boss-ace"       # plugin boss-ace.md heading
INVARIANT_FINGERPRINT="Persona 공통 불변층"       # _invariant.md heading phrase
MIA_FINGERPRINT="# Persona: mia"                # custom mia.md body heading
CUSTOM_BOSS_MARKER="커스텀 그림자 본문 boss-ace"  # shadow custom body marker

TMP_ROOT="$(mktemp -d "/tmp/test-session-start-persona-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }

# Run the persona hook from a given workdir so the loader reads that workdir's
# .rein/policy/persona.yaml (+ .rein/policy/persona/ customs). Capture stdout
# + stderr separately. Echo rc.
run_hook() {
  local workdir="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  ( cd "$workdir" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" \
      </dev/null >"$stdout_file" 2>"$stderr_file" )
  local rc=$?
  echo "$rc"
}

# Extract additionalContext (string) from envelope JSON; empty when no envelope.
extract_ctx() {
  local stdout_file="$1"
  python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    raw = fh.read()
if not raw.strip():
    sys.exit(0)  # empty stdout: no envelope
data = json.loads(raw)
hso = data.get("hookSpecificOutput") or {}
ctx = hso.get("additionalContext", "")
sys.stdout.write(ctx if isinstance(ctx, str) else "")
' "$stdout_file"
}

# Count occurrences of a literal substring in stdin (exactly-once checks).
count_substr() {
  python3 -c 'import sys; print(sys.stdin.read().count(sys.argv[1]))' "$1"
}

# Extract the `greeting:` frontmatter value from a preset file (empty when the
# file has no leading `---` frontmatter greeting line). Mirrors the loader's
# _read_frontmatter_greeting closure semantics so the pinned value matches the
# byte the loader would read — the value that (a5) asserts is stripped, not a
# hardcoded copy that would rot if Task 1.1 re-words the curated greeting.
extract_greeting() {
  python3 -c '
import re, sys
from pathlib import Path
try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
except Exception:
    sys.exit(0)
lines = text.splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit(0)
greeting = ""
for line in lines[1:]:
    if line.strip() == "---":
        break  # closed block
    m = re.match(r"^greeting:\s*(.+)$", line)
    if m:
        greeting = m.group(1).strip()
        break
sys.stdout.write(greeting)
' "$1"
}

# The curated boss-ace greeting (Wave 1 / Task 1.1). Read dynamically so (a5)
# and the fence-variant downgrade checks pin the ACTUAL stored value.
BOSS_ACE_GREETING="$(extract_greeting "$BOSS_ACE")"

# -----------------------------------------------------------------------------
# (a) enabled:true, preset:boss-ace -> body + invariant (exactly once),
#     frontmatter stripped.
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
cat >"$A_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: boss-ace
YAML
A_OUT="$A_DIR/stdout"; A_ERR="$A_DIR/stderr"
rc="$(run_hook "$A_DIR" "$A_OUT" "$A_ERR")"
if [ "$rc" != "0" ]; then
  cat "$A_ERR" >&2
  fail "(a) hook rc=$rc, expected 0"
fi
A_CTX="$(extract_ctx "$A_OUT")"
if [ -z "$A_CTX" ]; then
  fail "(a) additionalContext is empty (persona envelope expected)"
else
  case "$A_CTX" in
    *"$PERSONA_FINGERPRINT"*) ok "(a1) boss-ace body present" ;;
    *) fail "(a1) boss-ace body absent when enabled:true preset:boss-ace" ;;
  esac
  INV_COUNT="$(printf '%s' "$A_CTX" | count_substr "$INVARIANT_FINGERPRINT")"
  if [ "$INV_COUNT" = "1" ]; then
    ok "(a2) invariant layer present exactly once"
  else
    fail "(a2) invariant fingerprint count=$INV_COUNT, expected exactly 1"
  fi
  case "$A_CTX" in
    "---"*) fail "(a3) ctx starts with '---' (frontmatter leaked into envelope)" ;;
    *) ok "(a3) ctx does not start with frontmatter delimiter" ;;
  esac
  case "$A_CTX" in
    *"summary:"*) fail "(a4) ctx contains 'summary:' (frontmatter not stripped)" ;;
    *) ok "(a4) ctx carries no 'summary:' frontmatter field" ;;
  esac
  # (a5) Task 5.4: the boss-ace `greeting:` value (Wave 1 frontmatter field) is
  # inside the awk-stripped frontmatter block, so it must NOT reach the injected
  # body. Pin the ACTUAL stored value (empty -> the Wave 1 dependency is missing,
  # which is itself a failure to surface, not a silent pass).
  if [ -z "$BOSS_ACE_GREETING" ]; then
    fail "(a5) precondition: boss-ace.md carries no 'greeting:' frontmatter (Wave 1 / Task 1.1 dependency missing)"
  else
    case "$A_CTX" in
      *"$BOSS_ACE_GREETING"*) fail "(a5) boss-ace greeting value leaked into envelope (frontmatter greeting not stripped)" ;;
      *) ok "(a5) boss-ace greeting value absent from envelope (frontmatter stripped)" ;;
    esac
  fi
fi

# -----------------------------------------------------------------------------
# (b) enabled:false -> EMPTY stdout (no envelope; opt-out).
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
cat >"$B_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: false
preset: boss-ace
YAML
B_OUT="$B_DIR/stdout"; B_ERR="$B_DIR/stderr"
rc="$(run_hook "$B_DIR" "$B_OUT" "$B_ERR")"
if [ "$rc" != "0" ]; then
  cat "$B_ERR" >&2
  fail "(b) hook rc=$rc, expected 0"
elif [ -s "$B_OUT" ]; then
  fail "(b) persona hook emitted output despite enabled:false (opt-out broken)"
else
  ok "(b) enabled:false -> empty stdout (opt-out)"
fi

# -----------------------------------------------------------------------------
# (c) unknown preset (mentor, no custom file) -> downgraded to boss-ace,
#     body + invariant present (PP-3 fail-safe).
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR/.rein/policy"
cat >"$C_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: mentor
YAML
C_OUT="$C_DIR/stdout"; C_ERR="$C_DIR/stderr"
rc="$(run_hook "$C_DIR" "$C_OUT" "$C_ERR")"
if [ "$rc" != "0" ]; then
  cat "$C_ERR" >&2
  fail "(c) hook rc=$rc, expected 0"
fi
C_CTX="$(extract_ctx "$C_OUT")"
if [ -z "$C_CTX" ]; then
  fail "(c) additionalContext is empty (boss-ace downgrade expected)"
else
  case "$C_CTX" in
    *"$PERSONA_FINGERPRINT"*) ok "(c1) unknown preset 'mentor' downgraded to boss-ace body" ;;
    *) fail "(c1) unknown preset 'mentor' not downgraded to boss-ace (PP-3 fail-safe broken)" ;;
  esac
  case "$C_CTX" in
    *"$INVARIANT_FINGERPRINT"*) ok "(c2) invariant layer present on downgrade path" ;;
    *) fail "(c2) invariant layer absent on downgrade path" ;;
  esac
fi

# -----------------------------------------------------------------------------
# (d) hooks.json registers persona hook AFTER rules hook ("tone applied last").
# -----------------------------------------------------------------------------
if python3 - "$HOOKS_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    hooks = json.load(fh)
ss = [h["command"].split("/")[-1]
      for grp in hooks["hooks"]["SessionStart"] for h in grp["hooks"]]
if "session-start-persona.sh" not in ss:
    print(f"FAIL (d): persona hook not in SessionStart: {ss}", file=sys.stderr); sys.exit(1)
if "session-start-rules.sh" not in ss:
    print(f"FAIL (d): rules hook not in SessionStart: {ss}", file=sys.stderr); sys.exit(1)
if not (ss.index("session-start-rules.sh") < ss.index("session-start-persona.sh")):
    print(f"FAIL (d): persona not after rules: {ss}", file=sys.stderr); sys.exit(1)
PY
then
  ok "(d) hooks.json: persona hook registered after rules hook"
else
  fail "(d) persona hook not registered after rules hook in hooks.json"
fi

# -----------------------------------------------------------------------------
# (e) persona.yaml absent -> EMPTY stdout (neutral default; flips the old
#     default-ON contract — persona is opt-in via /rein:persona).
# -----------------------------------------------------------------------------
E_DIR="$TMP_ROOT/E"
mkdir -p "$E_DIR"
[ ! -e "$E_DIR/.rein/policy/persona.yaml" ] || { echo "ERROR: (e) setup: persona.yaml should not exist" >&2; exit 1; }
E_OUT="$E_DIR/stdout"; E_ERR="$E_DIR/stderr"
rc="$(run_hook "$E_DIR" "$E_OUT" "$E_ERR")"
if [ "$rc" != "0" ]; then
  cat "$E_ERR" >&2
  fail "(e) hook rc=$rc, expected 0"
elif [ -s "$E_OUT" ]; then
  fail "(e) persona hook emitted output with persona.yaml absent (neutral default broken — expected empty stdout)"
else
  ok "(e) persona.yaml absent -> empty stdout (neutral default)"
fi

# -----------------------------------------------------------------------------
# (f) custom preset mia: .rein/policy/persona/mia.md with frontmatter summary
#     -> envelope has mia body + invariant, frontmatter stripped.
# -----------------------------------------------------------------------------
F_DIR="$TMP_ROOT/F"
mkdir -p "$F_DIR/.rein/policy/persona"
cat >"$F_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: mia
YAML
cat >"$F_DIR/.rein/policy/persona/mia.md" <<'MD'
---
summary: 테스트용
---
# Persona: mia

밝고 상냥한 테스트 전용 페르소나. 판단은 냉정하게, 말투만 부드럽게.
MD
F_OUT="$F_DIR/stdout"; F_ERR="$F_DIR/stderr"
rc="$(run_hook "$F_DIR" "$F_OUT" "$F_ERR")"
if [ "$rc" != "0" ]; then
  cat "$F_ERR" >&2
  fail "(f) hook rc=$rc, expected 0"
fi
F_CTX="$(extract_ctx "$F_OUT")"
if [ -z "$F_CTX" ]; then
  fail "(f) additionalContext is empty (custom preset mia expected)"
else
  case "$F_CTX" in
    *"$MIA_FINGERPRINT"*) ok "(f1) custom preset mia body injected" ;;
    *) fail "(f1) custom preset mia body absent (custom resolution broken)" ;;
  esac
  case "$F_CTX" in
    *"$INVARIANT_FINGERPRINT"*) ok "(f2) invariant layer present with custom preset" ;;
    *) fail "(f2) invariant layer absent with custom preset" ;;
  esac
  case "$F_CTX" in
    *"summary:"*) fail "(f3) ctx contains 'summary:' (custom frontmatter not stripped)" ;;
    *) ok "(f3) custom frontmatter stripped from envelope" ;;
  esac
fi

# -----------------------------------------------------------------------------
# (g) builtin-wins: same-named custom boss-ace.md must NOT shadow the plugin
#     builtin — envelope carries the plugin body, custom marker absent.
# -----------------------------------------------------------------------------
G_DIR="$TMP_ROOT/G"
mkdir -p "$G_DIR/.rein/policy/persona"
cat >"$G_DIR/.rein/policy/persona.yaml" <<'YAML'
enabled: true
preset: boss-ace
YAML
cat >"$G_DIR/.rein/policy/persona/boss-ace.md" <<MD
---
summary: 내장 이름을 가로채려는 커스텀
---
# Shadow: boss-ace

$CUSTOM_BOSS_MARKER
MD
G_OUT="$G_DIR/stdout"; G_ERR="$G_DIR/stderr"
rc="$(run_hook "$G_DIR" "$G_OUT" "$G_ERR")"
if [ "$rc" != "0" ]; then
  cat "$G_ERR" >&2
  fail "(g) hook rc=$rc, expected 0"
fi
G_CTX="$(extract_ctx "$G_OUT")"
if [ -z "$G_CTX" ]; then
  fail "(g) additionalContext is empty (plugin boss-ace expected)"
else
  case "$G_CTX" in
    *"$PERSONA_FINGERPRINT"*) ok "(g1) plugin boss-ace body wins over same-named custom" ;;
    *) fail "(g1) plugin boss-ace body absent (builtin-wins broken)" ;;
  esac
  case "$G_CTX" in
    *"$CUSTOM_BOSS_MARKER"*) fail "(g2) custom shadow body injected (builtin name shadowed by custom file)" ;;
    *) ok "(g2) custom shadow body absent from envelope" ;;
  esac
fi

# -----------------------------------------------------------------------------
# (h) static single-trust-boundary check on the hook source (spec §10):
#     the hook must consume the loader's `--persona-file` resolved path and
#     must NOT compose preset paths itself.
# -----------------------------------------------------------------------------
if grep -qF -- '--persona-file' "$HOOK"; then
  ok "(h1) hook source consumes loader --persona-file"
else
  fail "(h1) hook source does not reference --persona-file (single trust boundary missing)"
fi
if grep -qF -- '/persona/${PERSONA}' "$HOOK"; then
  fail "(h2) hook source still self-composes RULES_DIR/persona/\${PERSONA} path (trust boundary duplicated)"
else
  ok "(h2) hook source has no self-composed persona path"
fi

# (h3) Task 5.4: the frontmatter awk-strip line must survive — it is what keeps
# the preset's `---` frontmatter (summary + greeting) out of the injected body.
if grep -qF -- 'NR==1 && $0=="---"' "$HOOK"; then
  ok "(h3) hook source keeps the frontmatter awk-strip line (NR==1 && \$0==\"---\")"
else
  fail "(h3) hook source lost the frontmatter awk-strip line (frontmatter may leak into envelope)"
fi

# (h4) Task 5.4: greeting is a SKILL-only read (loader --persona-greeting). The
# session-start hook must NOT reference it — it consumes only --persona-file.
if grep -qF -- '--persona-greeting' "$HOOK"; then
  fail "(h4) hook source references --persona-greeting (hook must consume only --persona-file)"
else
  ok "(h4) hook source has no --persona-greeting reference (consumes only --persona-file)"
fi

# -----------------------------------------------------------------------------
# (i) (P)∧¬(A) awk-mismatch fence CUSTOM activation -> no leak (runtime boundary,
#     Task 5.4). A custom whose leading `---` fence the lenient parser accepts
#     (P) but the hook's awk does NOT (¬A) is rejected by the loader's
#     _custom_persona_valid and DOWNGRADES to boss-ace, so none of the custom's
#     frontmatter/greeting/body bytes reach the injected envelope. Fixtures are
#     written with EXACT bytes (python open(...,"wb")) so universal-newline
#     normalization cannot silently erase CRLF / bare-CR / U+2028 terminators.
# -----------------------------------------------------------------------------
check_fence_variant() {
  local label="$1" name="$2" kind="$3"
  local dir="$TMP_ROOT/I_$name"
  mkdir -p "$dir/.rein/policy/persona"
  cat >"$dir/.rein/policy/persona.yaml" <<YAML
enabled: true
preset: $name
YAML
  # Exact-byte custom fixture: unique greeting + body sentinels, leading fence
  # terminator per $kind. Written raw so the terminator survives to the loader.
  python3 - "$dir/.rein/policy/persona/$name.md" "$kind" "$name" <<'PY'
import sys
path, kind, name = sys.argv[1], sys.argv[2], sys.argv[3]
greet = ("ZZ_FENCE_GREET_" + name).encode("utf-8")
body = ("ZZ_FENCE_BODY_" + name).encode("utf-8")
if kind == "padded":       # leading " --- " (whitespace-padded); LF elsewhere
    data = (b" --- \n"
            b"summary: x\n"
            b"greeting: " + greet + b"\n"
            b"---\n"
            b"# Shadow " + name.encode() + b"\n\n" + body + b"\n")
elif kind == "crlf":       # leading "---\r\n"; CRLF line ends throughout
    data = (b"---\r\n"
            b"summary: x\r\n"
            b"greeting: " + greet + b"\r\n"
            b"---\r\n"
            b"# Shadow " + name.encode() + b"\r\n\r\n" + body + b"\r\n")
elif kind == "barecr":     # bare-CR line ends, NO \n anywhere in the file
    data = (b"---\r"
            b"summary: x\r"
            b"greeting: " + greet + b"\r"
            b"---\r"
            b"# Shadow " + name.encode() + b"\r\r" + body + b"\r")
elif kind == "u2028":      # U+2028 line separators (\xe2\x80\xa8)
    sep = "\u2028".encode("utf-8")
    data = (b"---" + sep
            + b"summary: x" + sep
            + b"greeting: " + greet + sep
            + b"---" + sep
            + b"# Shadow " + name.encode() + sep + sep + body + b"\n")
else:
    raise SystemExit("unknown fence kind: " + kind)
with open(path, "wb") as fh:
    fh.write(data)
PY
  local out="$dir/stdout" err="$dir/stderr"
  local rc; rc="$(run_hook "$dir" "$out" "$err")"
  if [ "$rc" != "0" ]; then
    cat "$err" >&2
    fail "($label) hook rc=$rc, expected 0"
    return
  fi
  local ctx; ctx="$(extract_ctx "$out")"
  if [ -z "$ctx" ]; then
    fail "($label) additionalContext empty (expected boss-ace downgrade envelope)"
    return
  fi
  # no-leak: neither the custom greeting value nor the custom body sentinel
  # appears (proves the fence custom was rejected, not loaded+awk-stripped —
  # padded/CRLF/etc. would slip through the awk strip if the custom loaded).
  case "$ctx" in
    *"ZZ_FENCE_GREET_$name"*) fail "($label) custom greeting value leaked (fence custom loaded, not rejected)" ;;
    *) ok "($label) custom greeting value absent (fence custom rejected)" ;;
  esac
  case "$ctx" in
    *"ZZ_FENCE_BODY_$name"*) fail "($label) custom body sentinel leaked (fence custom loaded, not rejected)" ;;
    *) ok "($label) custom body sentinel absent (fence custom rejected)" ;;
  esac
  # downgrade confirmed: boss-ace body + invariant present (injection happened,
  # not just empty) — distinguishes "rejected -> downgrade" from "rejected -> off".
  case "$ctx" in
    *"$PERSONA_FINGERPRINT"*) ok "($label) downgraded to boss-ace body (no-leak via known-good fallback)" ;;
    *) fail "($label) boss-ace body absent (expected downgrade on rejected fence custom)" ;;
  esac
  case "$ctx" in
    *"$INVARIANT_FINGERPRINT"*) ok "($label) invariant layer present on downgrade" ;;
    *) fail "($label) invariant layer absent on downgrade" ;;
  esac
}

check_fence_variant "i-padded"  "fpad"    "padded"
check_fence_variant "i-crlf"    "fcrlf"   "crlf"
check_fence_variant "i-barecr"  "fbarecr" "barecr"
check_fence_variant "i-u2028"   "fu2028"  "u2028"

echo "test-session-start-persona-inject: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
