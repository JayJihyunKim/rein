#!/usr/bin/env bash
# Contract: no plugin shell code uses the `: > file` idiom (an output
# redirection attached to the POSIX *special* builtin `:`). In a
# non-interactive POSIX-mode shell (bash 5 with POSIXLY_CORRECT=1, i.e. a
# user's Linux environment) a redirection error on a special builtin EXITS the
# shell instead of failing the command, so a read-only directory silently
# killed the whole SessionStart helper on Linux CI (2026-09-04, fixture S of
# test-session-start-bootstrap.sh). Regular builtins (printf, true) just fail
# and `|| true` absorbs it. Scope: plugins/rein-core/{hooks,scripts,bin} +
# the root scripts/*.sh CLI (the user-installed `rein.sh` + helpers).
#
# Deliberately narrow: only `:` is scanned. The other special builtins
# (eval/export/return/exit/./break/continue/set/shift/unset/times/trap) are
# not reliably separable from quoted strings and command substitutions by a
# line regex (`export X=$(cmd > f)` is fine, `trap 'cmd' EXIT > f` is not),
# and none of them carries a file-creating redirection anywhere in the plugin;
# `exec > file` is the idiom for redirecting the current shell and is expected
# to abort on failure. Widening this scan needs a syntax-aware checker.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN="$PROJECT_DIR/plugins/rein-core"
FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# Shape: `:` at COMMAND position — preceded by start-of-line, a list/group
# operator (`; & | ( ) ! {`), a keyword that introduces a command (then else
# do elif if while until), a leading `NAME=value` assignment, or a leading
# redirection token (`2>/dev/null : > f`) — and followed by whitespace or
# directly by `>`. Then optional arguments (no `; | #`) and a `>` that is not
# part of `2>`/`>&`/`<>`. A `:` inside a word (`a=b:c`, `:foo`, `::`) is not
# a command. Single- and double-quoted spans are blanked out before matching
# (see strip_quotes) so `echo "x; : > f"` is not a command position either.
#
# This is a HEURISTIC guard for the incident shape, not a shell parser:
# multi-line quoted strings, here-documents and `eval`-built commands are
# outside what a per-line regex can judge. The authoritative regression for
# the class is the runtime case N in test-git-required-guidance.sh (the
# behaviour under POSIXLY_CORRECT=1 with a read-only directory).
strip_quotes() { sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g"; }
PREFIX='(^|[;&|()!{]|(^|[;&|({[:space:]])(then|else|do|elif|if|while|until)|(^|[;&|({[:space:]])[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|(^|[;&|({[:space:]])[0-9]*[<>]&?[^[:space:]]*)'
# No empty alternatives (`(a|)`): ugrep (a common `grep` replacement) rejects
# them; the optional group form is portable across GNU/BSD grep and ugrep.
PATTERN="${PREFIX}"'[[:space:]]*:([[:space:]]+([^#;|]*[^2&<>[:space:]])?[[:space:]]*)?>[^&]'

# Positive self-check: the pattern must catch the known-bad forms, otherwise
# the scan below is vacuous.
for sample in ': > "$flag" 2>/dev/null || true' '    : 2>/dev/null > "$f"' 'if ok; then : > x; fi' ':>x' 'true && : >"$f"' 'if : > x; then echo; fi' 'while : > x; do break; done' '{ : > x; }' '! : > x' 'X=y : > x' ': "arg" > x' 'elif : > x; then' 'case x in x) : > f ;; esac' '2>/dev/null : > f' 'cmd >/dev/null 2>&1; : > f'; do
  if printf '%s\n' "$sample" | strip_quotes | grep -qE "$PATTERN"; then
    pass "self-check catches: $sample"
  else
    fail "self-check MISSED: $sample"
  fi
done
# Negative self-check: the replacement idiom must not be flagged.
for sample in "printf '' > \"\$flag\" 2>/dev/null || true" ': 2>/dev/null' "trap 'cmd > f' EXIT" 'set -x; echo > f' 'echo "x" >&2' 'settings > f' 'exec > "$log"' 'export X=$(cmd > f)' 'case x in :) echo ;; esac' 'a=b:c > f' ':foo > x' ':: > x' 'echo "a : b" > f' 'printf "%s:\n" x > f' 'url=http://x > f' 'echo "x; : > f"' "echo 'if : > f'" 'echo "a" > f # : > g'; do
  if printf '%s\n' "$sample" | strip_quotes | grep -qE "$PATTERN"; then
    fail "self-check flags a benign line: $sample"
  else
    pass "self-check accepts: $sample"
  fi
done

# The scan — comment-only lines are skipped.
HITS="$(find "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/bin" "$PROJECT_DIR/scripts" -type f \( -name '*.sh' -o -name 'rein' \) 2>/dev/null | sort | while IFS= read -r f; do
  strip_quotes < "$f" | grep -nE "$PATTERN" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
done)"
if [ -z "$HITS" ]; then
  pass "no \`: > file\` idiom in plugin hooks/scripts/bin or root scripts/"
else
  fail "\`: > file\` idiom found (use printf ''):"
  printf '%s\n' "$HITS" >&2
fi

if [ "$FAIL" -eq 0 ]; then
  echo "test-no-special-builtin-redirect: OK"
else
  echo "test-no-special-builtin-redirect: $FAIL FAIL" >&2
  exit 1
fi
