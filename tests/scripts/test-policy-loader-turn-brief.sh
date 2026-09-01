#!/usr/bin/env bash
# tests/scripts/test-policy-loader-turn-brief.sh — --turn-brief mode (PT-10)
#
# rein-policy-loader.py --turn-brief composes the per-turn UserPromptSubmit
# envelope (answer-only + response-tone + persona summaries, optional bootstrap
# prepend via env) in ONE process — replacing the per-turn hook's previous
# three python spawns. This test drives the real loader.
#
# Assertions:
#   (a) two loader copies byte-identical (PT-7 drift)
#   (b) persona enabled (explicit fixture: enabled:true + preset:boss-ace)
#       -> valid envelope with answer-only + response-tone + persona markers
#       + active-preset line (`활성 프리셋:` + `boss-ace`)
#   (b2) persona-summary.md marker file is preset-agnostic (no `보스` /
#        `boss-ace` hardcoding) — Task 3.1
#   (c) persona disabled -> active-preset line absent, other two present
#   (d) answer-only summary absent -> empty stdout (hard-requirement fail-open)
#   (e) response-tone summary absent -> answer-only still emitted (optional skip)
#   (f) CLAUDE_PLUGIN_ROOT unset -> empty stdout + exit 0 (env fail-open)
#   (g) REIN_TURN_BRIEF_PREPEND set -> text prepended at the front of body
#   (h) every path exits 0
#   (i) custom preset with frontmatter summary -> `활성 프리셋: <name> — <summary>`
#   (j) preset without frontmatter summary -> name-only line `활성 프리셋: <name>`
#
# NOTE (Task 3.1 sweep): no assert below premises the old default-ON persona —
# (b)/(c)/(i)/(j) all pin explicit persona.yaml fixtures.
#
# Scope ID: PT-10, turn-brief-appends-active-preset-name-and-summary-line
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"
LOADER="$PLUGIN_ROOT/scripts/rein-policy-loader.py"
LOADER_FALLBACK="$PROJECT_DIR/scripts/rein-policy-loader.py"

PASS=0; FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
ok()   { echo "  ok: $1"; PASS=$((PASS + 1)); }

TMP_ROOT="$(mktemp -d "/tmp/test-turn-brief-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Decode hookSpecificOutput.additionalContext; print '' when no envelope.
extract_ctx() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
data = json.loads(raw)  # raises on invalid JSON -> test sees nonzero
ctx = (data.get("hookSpecificOutput") or {}).get("additionalContext", "")
ev = (data.get("hookSpecificOutput") or {}).get("hookEventName", "")
assert ev == "UserPromptSubmit", f"event={ev!r}"
sys.stdout.write(ctx)
'
}

# (a) byte-identical copies ---------------------------------------------------
if diff -q "$LOADER" "$LOADER_FALLBACK" >/dev/null 2>&1; then
  ok "(a) loader 2 copies byte-identical"
else
  fail "(a) loader copies differ (PT-7 drift)"
fi

# (b) persona enabled ---------------------------------------------------------
B_DIR="$TMP_ROOT/b"; mkdir -p "$B_DIR/.rein/policy"
printf 'enabled: true\npreset: boss-ace\n' > "$B_DIR/.rein/policy/persona.yaml"
B_OUT="$( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
B_RC=$?
B_CTX="$(printf '%s' "$B_OUT" | extract_ctx)"
if [ "$B_RC" = "0" ] && printf '%s' "$B_CTX" | grep -q 'Answer-only' \
   && printf '%s' "$B_CTX" | grep -q 'Response Tone' \
   && printf '%s' "$B_CTX" | grep -q '활성 프리셋:' \
   && printf '%s' "$B_CTX" | grep -q '마르코' \
   && ! printf '%s' "$B_CTX" | grep -qE '활성 프리셋:[^\n]*boss-ace'; then
  ok "(b) persona enabled -> answer-only + response-tone + active-preset line (display name, no slug)"
else
  fail "(b) persona-enabled turn-brief missing a marker or leaked raw slug (rc=$B_RC)"
fi

# (b2) persona-summary.md marker file is preset-agnostic (Task 3.1) ------------
PERSONA_SUMMARY_FILE="$PLUGIN_ROOT/rules/short/persona-summary.md"
if [ -f "$PERSONA_SUMMARY_FILE" ] \
   && ! grep -q '보스' "$PERSONA_SUMMARY_FILE" \
   && ! grep -q 'boss-ace' "$PERSONA_SUMMARY_FILE"; then
  ok "(b2) persona-summary.md has no preset hardcoding (보스/boss-ace zero)"
else
  fail "(b2) persona-summary.md still hardcodes a preset (보스/boss-ace found)"
fi

# (c) persona disabled --------------------------------------------------------
C_DIR="$TMP_ROOT/c"; mkdir -p "$C_DIR/.rein/policy"
printf 'enabled: false\n' > "$C_DIR/.rein/policy/persona.yaml"
C_CTX="$( cd "$C_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$C_CTX" | grep -q 'Answer-only' \
   && printf '%s' "$C_CTX" | grep -q 'Response Tone' \
   && ! printf '%s' "$C_CTX" | grep -q '활성 프리셋:'; then
  ok "(c) persona disabled -> persona absent, other two present"
else
  fail "(c) persona-disabled turn-brief wrong markers"
fi

# Build a fake plugin root with a controllable rules/short/ for (d)/(e).
fake_root() {
  local dir="$1"; shift
  mkdir -p "$dir/rules/short"
  for f in "$@"; do
    printf '# %s marker\n' "$f" > "$dir/rules/short/$f.md"
  done
  echo "$dir"
}

# (d) answer-only absent -> empty stdout --------------------------------------
D_ROOT="$(fake_root "$TMP_ROOT/d" response-tone-summary)"  # no answer-only-summary
D_OUT="$( CLAUDE_PLUGIN_ROOT="$D_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
D_RC=$?
if [ "$D_RC" = "0" ] && [ -z "$D_OUT" ]; then
  ok "(d) answer-only absent -> empty stdout + exit 0"
else
  fail "(d) answer-only absent should be empty (rc=$D_RC, len=${#D_OUT})"
fi

# (e) response-tone absent -> answer-only still emitted ------------------------
E_ROOT="$(fake_root "$TMP_ROOT/e" answer-only-summary)"  # no response-tone, no persona
E_OUT="$( CLAUDE_PLUGIN_ROOT="$E_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null )"
E_CTX="$(printf '%s' "$E_OUT" | extract_ctx)"
if printf '%s' "$E_CTX" | grep -q 'answer-only-summary marker'; then
  ok "(e) response-tone absent -> answer-only still emitted (optional skip)"
else
  fail "(e) answer-only-only turn-brief failed"
fi

# (f) CLAUDE_PLUGIN_ROOT unset -> empty + exit 0 ------------------------------
F_OUT="$( env -u CLAUDE_PLUGIN_ROOT python3 "$LOADER" --turn-brief 2>/dev/null )"
F_RC=$?
if [ "$F_RC" = "0" ] && [ -z "$F_OUT" ]; then
  ok "(f) CLAUDE_PLUGIN_ROOT unset -> empty stdout + exit 0"
else
  fail "(f) unset env should be empty exit 0 (rc=$F_RC, len=${#F_OUT})"
fi

# (g) REIN_TURN_BRIEF_PREPEND prepended --------------------------------------
G_CTX="$( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" REIN_TURN_BRIEF_PREPEND="PREPEND_SENTINEL_123" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
case "$G_CTX" in
  "PREPEND_SENTINEL_123"*) ok "(g) REIN_TURN_BRIEF_PREPEND prepended at front" ;;
  *) fail "(g) prepend not at front of body" ;;
esac

# (h) every invocation above exited 0 (implicit: loader contract). Spot-check a
#     malformed persona.yaml still exits 0.
H_DIR="$TMP_ROOT/h"; mkdir -p "$H_DIR/.rein/policy"
printf 'enabled: : :\n' > "$H_DIR/.rein/policy/persona.yaml"
( cd "$H_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief >/dev/null 2>&1 )
if [ "$?" = "0" ]; then
  ok "(h) malformed persona.yaml -> exit 0 (fail-open)"
else
  fail "(h) malformed persona.yaml should exit 0"
fi

# (i) custom preset WITH frontmatter summary -> name + summary line ------------
I_DIR="$TMP_ROOT/i"; mkdir -p "$I_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: mia\n' > "$I_DIR/.rein/policy/persona.yaml"
cat > "$I_DIR/.rein/policy/persona/mia.md" <<'EOF'
---
summary: 시크한 밤샘 메이트
---

# Persona: mia

차분한 말투를 유지한다.
EOF
I_CTX="$( cd "$I_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$I_CTX" | grep -q '^활성 프리셋: 이름 없는 페르소나 — 시크한 밤샘 메이트$'; then
  ok "(i) preset with summary but no display_name -> fallback label + summary"
else
  fail "(i) fallback-label summary line missing"
fi

# (j) preset WITHOUT frontmatter summary -> name-only line ---------------------
J_DIR="$TMP_ROOT/j"; mkdir -p "$J_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nosumm\n' > "$J_DIR/.rein/policy/persona.yaml"
cat > "$J_DIR/.rein/policy/persona/nosumm.md" <<'EOF'
# Persona: nosumm

frontmatter 없는 커스텀 프리셋.
EOF
J_CTX="$( cd "$J_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$J_CTX" | grep -q '^활성 프리셋: 이름 없는 페르소나$'; then
  ok "(j) preset without display_name or summary -> fallback label only"
else
  fail "(j) fallback-label-only line missing"
fi

# (k) UNCLOSED frontmatter (summary present, no closing ---) -> summary IGNORED,
#     name-only line (integrated-review Medium regression — an unclosed fence
#     makes the hook's awk swallow the whole body, so reporting its summary
#     would describe a preset that injects nothing).
K_DIR="$TMP_ROOT/k"; mkdir -p "$K_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: unclosed\n' > "$K_DIR/.rein/policy/persona.yaml"
cat > "$K_DIR/.rein/policy/persona/unclosed.md" <<'EOF'
---
summary: 미폐쇄 머리말 요약
# Persona: unclosed

본문이 통째로 머리말로 삼켜지는 형태.
EOF
K_CTX="$( cd "$K_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$K_CTX" | grep -q '^활성 프리셋: 이름 없는 페르소나$' \
   && ! printf '%s' "$K_CTX" | grep -q '미폐쇄 머리말 요약'; then
  ok "(k) unclosed frontmatter -> summary AND display_name ignored, fallback label"
else
  fail "(k) unclosed frontmatter must fall back to '이름 없는 페르소나'"
fi

# (l) display_name + display_name_en + summary -> full parenthesized format.
L_DIR="$TMP_ROOT/l"; mkdir -p "$L_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nova\n' > "$L_DIR/.rein/policy/persona.yaml"
cat > "$L_DIR/.rein/policy/persona/nova.md" <<'EOF'
---
summary: 시크한 밤샘 메이트
display_name: 노바
display_name_en: Nova
---

# Persona: nova

차분한 말투를 유지한다.
EOF
L_CTX="$( cd "$L_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$L_CTX" | grep -q '^활성 프리셋: 노바 (Nova) — 시크한 밤샘 메이트$' \
   && ! printf '%s' "$L_CTX" | grep -q 'nova'; then
  ok "(l) display_name+alias+summary -> full format, raw slug absent"
else
  fail "(l) display_name+alias+summary format wrong or slug leaked"
fi

# (m) display_name + summary, no alias -> dash format.
M_DIR="$TMP_ROOT/m"; mkdir -p "$M_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nova2\n' > "$M_DIR/.rein/policy/persona.yaml"
cat > "$M_DIR/.rein/policy/persona/nova2.md" <<'EOF'
---
summary: 시크한 밤샘 메이트
display_name: 노바
---

# Persona: nova2

차분한 말투를 유지한다.
EOF
M_CTX="$( cd "$M_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$M_CTX" | grep -q '^활성 프리셋: 노바 — 시크한 밤샘 메이트$'; then
  ok "(m) display_name+summary, no alias -> dash format"
else
  fail "(m) display_name+summary(no alias) format wrong"
fi

# (n) display_name + alias, no summary -> parens only.
N_DIR="$TMP_ROOT/n"; mkdir -p "$N_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nova3\n' > "$N_DIR/.rein/policy/persona.yaml"
cat > "$N_DIR/.rein/policy/persona/nova3.md" <<'EOF'
---
display_name: 노바
display_name_en: Nova
---

# Persona: nova3

차분한 말투를 유지한다.
EOF
N_CTX="$( cd "$N_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$N_CTX" | grep -q '^활성 프리셋: 노바 (Nova)$'; then
  ok "(n) display_name+alias, no summary -> parens only"
else
  fail "(n) display_name+alias(no summary) format wrong"
fi

# (o) display_name only -> bare name line.
O_DIR="$TMP_ROOT/o"; mkdir -p "$O_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nova4\n' > "$O_DIR/.rein/policy/persona.yaml"
cat > "$O_DIR/.rein/policy/persona/nova4.md" <<'EOF'
---
display_name: 노바
---

# Persona: nova4

차분한 말투를 유지한다.
EOF
O_CTX="$( cd "$O_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$O_CTX" | grep -q '^활성 프리셋: 노바$'; then
  ok "(o) display_name only -> bare name line"
else
  fail "(o) display_name-only format wrong"
fi

# (p) neither display_name nor summary is already covered by (j) above (regression).

# (q) persona-summary nudge carries the language-adaptation contract sentence
#     (implemented by Task 3.1, wave 2 — RED until then, expected-RED allowlisted
#     for wave 1 close-out).
Q_CTX="$( cd "$B_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$Q_CTX" | grep -qF '지금 응답 언어에 맞춰 자연스럽게 자칭하되 직역하지 않는다'; then
  ok "(q) turn-brief carries persona-summary language-adaptation nudge sentence"
else
  fail "(q) language-adaptation nudge sentence missing from turn-brief output"
fi

# (r) [High-3 regression] display_name_en present but display_name ABSENT -> fallback
#     label WITHOUT alias attached. A naive `label = display_name or "..."` followed by
#     `if display_name_en: label += f" ({display_name_en})"` bug would incorrectly
#     attach the alias to the fallback label — this must never happen.
R_DIR="$TMP_ROOT/r"; mkdir -p "$R_DIR/.rein/policy/persona"
printf 'enabled: true\npreset: nova5\n' > "$R_DIR/.rein/policy/persona.yaml"
cat > "$R_DIR/.rein/policy/persona/nova5.md" <<'EOF'
---
summary: 시크한 밤샘 메이트
display_name_en: Nova
---

# Persona: nova5

차분한 말투를 유지한다.
EOF
R_CTX="$( cd "$R_DIR" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 "$LOADER" --turn-brief 2>/dev/null | extract_ctx )"
if printf '%s' "$R_CTX" | grep -q '^활성 프리셋: 이름 없는 페르소나 — 시크한 밤샘 메이트$' \
   && ! printf '%s' "$R_CTX" | grep -q 'Nova'; then
  ok "(r) display_name absent + display_name_en present -> fallback label, no alias attached"
else
  fail "(r) fallback label must not carry alias when display_name is absent"
fi

echo "test-policy-loader-turn-brief: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
