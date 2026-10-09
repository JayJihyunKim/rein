#!/usr/bin/env bash
# tests/scripts/test-policy-loader-test-selection.sh
# spec docs/specs/2026-10-08-affected-tests-and-precheck.md §3.6.1 (2) — PL1~PL10
# Scope ID: ATP-POLICY
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LP="$ROOT/plugins/rein-core/scripts/rein-policy-loader.py"
LR="$ROOT/scripts/rein-policy-loader.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/policy-tsel-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

mk_case() {   # $1=id [$2=정책 파일 내용 — 인자가 없으면 파일 없음]
  mkdir -p "$WORK/$1"
  if [ "$#" -ge 2 ]; then
    mkdir -p "$WORK/$1/.rein/policy"
    printf '%s' "$2" > "$WORK/$1/.rein/policy/test-selection.yaml"
  fi
}
check() {     # $1=id $2=기대 stdout $3=warn|any — PYTHONPATH 는 전역 PL_PP(비어 있으면 미설정)
  local d="$WORK/$1" out rc
  if [ -n "${PL_PP:-}" ]; then
    out=$(cd "$d" && PYTHONPATH="$PL_PP" python3 "$LP" --test-selection-auto-install 2>"$d.err"); rc=$?
  else
    out=$(cd "$d" && python3 "$LP" --test-selection-auto-install 2>"$d.err"); rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then _pass "$1: stdout '$out', rc 0"
  else _fail "$1: stdout '$out', rc $rc (기대 '$2', rc 0)"; fi
  if [ "$3" = warn ]; then
    if grep -q '^warning:' "$d.err"; then _pass "$1: stderr 경고"; else _fail "$1: stderr 경고 없음"; fi
  fi
}

echo "## test-policy-loader-test-selection.sh"
PL_PP=""
mk_case PL1;                                        check PL1 true any
mk_case PL2 'auto_install_test_tools: true';         check PL2 true any
mk_case PL3 'auto_install_test_tools: false';        check PL3 false any
mk_case PL4a 'other: 1';                             check PL4a true any
mk_case PL4b '';                                     check PL4b true any
mk_case PL5 'auto_install_test_tools: [';            check PL5 false warn
mk_case PL6 '- a';                                   check PL6 false warn
mk_case PL7a 'auto_install_test_tools: "false"';     check PL7a false warn
mk_case PL7b 'auto_install_test_tools: "true"';      check PL7b false warn

NOYAML="$WORK/noyaml"; mkdir -p "$NOYAML"
printf 'raise ImportError("simulated: PyYAML absent")\n' > "$NOYAML/yaml.py"
PL_PP="$NOYAML"
mk_case PL8a 'auto_install_test_tools: true';        check PL8a false warn
mk_case PL8b;                                        check PL8b true any
PL_PP=""

USAGE=$(python3 "$LP" 2>&1 >/dev/null)
case "$USAGE" in
  *--test-selection-auto-install*) _pass "PL9: usage 에 --test-selection-auto-install" ;;
  *) _fail "PL9: usage 에 --test-selection-auto-install 없음" ;;
esac
if cmp -s "$LP" "$LR"; then _pass "PL10: 두 사본 바이트 동일"; else _fail "PL10: 두 사본이 다름"; fi

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
