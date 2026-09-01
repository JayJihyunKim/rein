#!/usr/bin/env bash
# test-persona-preset-greeting.sh — builtin 프리셋 curated greeting frontmatter 계약 회귀 테스트.
#
# Plan: docs/plans/2026-07-23-persona-change-greeting.md Task 1.1 + Task 5.5.
# Scope IDs: preset-greeting-stored-in-frontmatter-field-coexisting-with-summary,
#            builtin-presets-carry-curated-signature-greeting-line-under-60-chars,
#            greeting-length-cap-tested-across-builtin-custom-and-fallback-paths,
#            greeting-stays-tone-only-and-never-weakens-judgment-warnings-or-blocks
#
# 실제 plugin 프리셋 파일(boss-ace.md / jennie.md)을 직접 읽어 각각 검증:
#   (a) 선두 정확 `---`(LF) fence + 닫는 `---` 존재.
#   (b) frontmatter 블록 안에 summary: 와 greeting: 공존.
#   (c) greeting: 값 길이 <= 60자 (Python len() — 한글 문자수).
#   (d) greeting: 값에 L4 금지 패턴(trail/·.rein/·hooks/·CLAUDE_PLUGIN_ROOT·
#       규율 침식 문구) 미포함 — greeting 은 tone-only, 규율을 약화시키지 않는다.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRESET_DIR="$PROJECT_DIR/plugins/rein-core/rules/persona"

PASS=0
fail() {
  echo "FAIL: $1" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

BOSS="$PRESET_DIR/boss-ace.md"
JENNIE="$PRESET_DIR/jennie.md"
CHOI="$PRESET_DIR/choi-haengbae.md"
[ -f "$BOSS" ] || fail "builtin preset missing: $BOSS"
[ -f "$JENNIE" ] || fail "builtin preset missing: $JENNIE"

# --- check_preset -----------------------------------------------------------
# Run every frontmatter greeting assertion for one preset file in a single
# Python invocation. stdout carries a human-readable reason on failure; exit
# code drives the bash-level ok/fail. Korean length + exact LF fence + L4
# forbidden-pattern scanning all live in Python for byte/codepoint accuracy.
check_preset() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import re
import sys

label, path = sys.argv[1], sys.argv[2]

# L4 forbidden pattern groups — mirrors rein-persona-lint.py so a curated
# greeting can never smuggle a discipline-erosion phrase or an internal ops
# path/identifier into the character line.
FORBIDDEN_REGEXES = (
    re.compile(r"ignore (all |previous |above )?(rules|instructions)", re.IGNORECASE),
    re.compile(
        r"(규칙|지시|게이트|차단|경고|리뷰)[^\n]{0,20}(무시|우회|약화|건너뛰|끄|비활성)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(response-tone|응답 규칙|불변|invariant)[^\n]{0,20}(보다 우선|이긴다|무효)",
        re.IGNORECASE,
    ),
)
FORBIDDEN_LITERALS = ("trail/", ".rein/", "CLAUDE_PLUGIN_ROOT", "hooks/")
MAX_GREETING_CHARS = 60


def die(reason):
    print("%s: %s" % (label, reason))
    sys.exit(1)


# Read raw so CRLF/bare-CR cannot masquerade as an exact LF fence.
with open(path, "r", encoding="utf-8", newline="") as fh:
    text = fh.read()

# (a) leading exact `---`(LF) fence.
if not text.startswith("---\n"):
    die("does not start with an exact `---`(LF) frontmatter fence")

lines = text.split("\n")
# Closing `---` is the first line after index 0 whose content is exactly `---`.
close_idx = None
for i in range(1, len(lines)):
    if lines[i] == "---":
        close_idx = i
        break
if close_idx is None:
    die("leading frontmatter fence is never closed by a second `---`")

block = lines[1:close_idx]  # lines strictly inside the frontmatter block

# (b) summary: and greeting: coexist inside the block.
summary_lines = [ln for ln in block if ln.startswith("summary:")]
greeting_lines = [ln for ln in block if ln.startswith("greeting:")]
if not summary_lines:
    die("frontmatter block has no `summary:` field")
if not greeting_lines:
    die("frontmatter block has no `greeting:` field (must coexist with summary)")

greeting = greeting_lines[0][len("greeting:"):].strip()
if not greeting:
    die("`greeting:` value is empty")

# (c) length cap — Python len() counts Korean codepoints, not bytes.
if len(greeting) > MAX_GREETING_CHARS:
    die("greeting length %d > %d chars: %r" % (len(greeting), MAX_GREETING_CHARS, greeting))

# (d) L4 forbidden patterns must not appear in the greeting value.
for lit in FORBIDDEN_LITERALS:
    if lit in greeting:
        die("greeting contains forbidden internal path/identifier %r: %r" % (lit, greeting))
for rx in FORBIDDEN_REGEXES:
    if rx.search(greeting):
        die("greeting matches discipline-erosion pattern /%s/: %r" % (rx.pattern, greeting))

# (e) display_name 필수 + one-line scalar (block 은 이미 줄 단위 리스트라 값이
#     여러 줄에 걸칠 수 없음 — 파서 계약상 one-line 이 구조적으로 보장됨).
display_lines = [ln for ln in block if ln.startswith("display_name:")]
if not display_lines:
    die("frontmatter block has no `display_name:` field")
display_name = display_lines[0][len("display_name:"):].strip()
if not display_name:
    die("`display_name:` value is empty")

# (f) L4 forbidden pattern scan on display_name (mirrors greeting's own scan).
for lit in FORBIDDEN_LITERALS:
    if lit in display_name:
        die("display_name contains forbidden internal path/identifier %r: %r" % (lit, display_name))
for rx in FORBIDDEN_REGEXES:
    if rx.search(display_name):
        die("display_name matches discipline-erosion pattern /%s/: %r" % (rx.pattern, display_name))

# (g) display_name_en — expect_alias 인자("yes"/"no")로 존재/부재를 강제.
#     Python 실행 라인이 세 번째 인자를 항상 넘기므로(위 invocation 수정) 기본값 없이
#     필수로 읽는다 — 누락 시 IndexError 로 즉시 실패(fail-closed, silent "no" 강등 방지).
expect_alias = sys.argv[3]
alias_lines = [ln for ln in block if ln.startswith("display_name_en:")]
if expect_alias == "yes" and not alias_lines:
    die("frontmatter block has no `display_name_en:` field (expected for this preset)")
if expect_alias == "no" and alias_lines:
    die("frontmatter block has `display_name_en:` but this preset must omit it")

alias_val = alias_lines[0][len("display_name_en:"):].strip() if alias_lines else None
print(
    "%s: greeting=%r display_name=%r display_name_en=%r (len=%d) OK"
    % (label, greeting, display_name, alias_val, len(greeting))
)
PYEOF
}

LOOP_FAIL=""
for spec in "boss-ace:$BOSS:yes" "jennie:$JENNIE:yes" "choi-haengbae:$CHOI:no"; do
  label="${spec%%:*}"
  rest="${spec#*:}"
  file="${rest%%:*}"
  expect_alias="${rest#*:}"
  if OUT="$(check_preset "$label" "$file" "$expect_alias")"; then
    ok "$OUT"
  else
    # 즉시 exit 하지 않고 실패를 누적한다 — 3개 프리셋을 모두 관찰해야 웨이브
    # allowlist 가 jennie·choi-haengbae 상태를 각각 검증할 수 있다 (즉시 fail 은
    # 첫 실패에서 종료해 뒤 프리셋을 가림).
    echo "FAIL: $OUT" >&2
    LOOP_FAIL="${LOOP_FAIL} ${label}"
  fi
done
[ -z "$LOOP_FAIL" ] || fail "preset frontmatter/display_name checks failed for:${LOOP_FAIL}"

echo ""
echo "test-persona-preset-greeting: OK ($PASS asserts passed)"
