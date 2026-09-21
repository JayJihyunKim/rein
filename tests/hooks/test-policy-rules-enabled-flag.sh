#!/usr/bin/env bash
# tests/hooks/test-policy-rules-enabled-flag.sh — OFD-FLAG-1
#
# `rein-policy-loader.py --rule-enabled <rule>` prints "true" only when
# `.rein/policy/rules.yaml` has `<rule>: {enabled: true}`; every other path
# prints "false" (always exit 0). FAIL-CLOSED — the deliberate opposite of
# `--rule-override`'s fail-open (test-policy-rules-override.sh Fixture 4): a
# broken yaml must never switch a new default behaviour on.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"
[ -f "$LOADER" ] || { echo "FAIL: $LOADER missing" >&2; exit 1; }

TMP_ROOT="$(mktemp -d "/tmp/test-policy-rules-enabled-flag-XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# probe <case-dir> <expected> — run the CLI from the fixture dir.
probe() {
  local out rc
  set +e
  out="$( cd "$TMP_ROOT/$1" && python3 "$LOADER" --rule-enabled orchestrator-first 2>/dev/null )"
  rc=$?
  set -e
  [ "$rc" = "0" ] || fail "$1: expected exit 0, got $rc"
  [ "$out" = "$2" ] || fail "$1: expected '$2', got '$out'"
  echo "  ok: $1 → $2"
}

# (a) 항목 없음 → 비활성: yaml 부재 / yaml 은 있으나 이 rule 항목 없음.
mkdir -p "$TMP_ROOT/a-no-yaml" "$TMP_ROOT/a-no-entry/.rein/policy"
printf 'code-style:\n  override: "x"\n' > "$TMP_ROOT/a-no-entry/.rein/policy/rules.yaml"
probe a-no-yaml false
probe a-no-entry false
# (b) enabled: true → 활성.
mkdir -p "$TMP_ROOT/b-enabled/.rein/policy"
printf 'orchestrator-first:\n  enabled: true\n' > "$TMP_ROOT/b-enabled/.rein/policy/rules.yaml"
probe b-enabled true
# (c) yaml 파싱 불가 → 비활성 (fail-closed).
mkdir -p "$TMP_ROOT/c-malformed/.rein/policy"
printf ':::\nnot yaml: at all: extra: colons:\n  : invalid\n' > "$TMP_ROOT/c-malformed/.rein/policy/rules.yaml"
probe c-malformed false
# (d) 활성으로 새면 안 되는 값 모양 — YAML 불리언 true 만 활성이다. 기본값이
#     켜짐인 다른 enabled 정규화 헬퍼를 재사용하면 이 경우들이 활성으로 뒤집힌다.
shape() {
  mkdir -p "$TMP_ROOT/$1/.rein/policy"
  printf '%b' "$2" > "$TMP_ROOT/$1/.rein/policy/rules.yaml"
  probe "$1" false
}
shape d-string-true    'orchestrator-first:\n  enabled: "true"\n'
shape d-string-false   'orchestrator-first:\n  enabled: "false"\n'
shape d-number-one     'orchestrator-first:\n  enabled: 1\n'
shape d-empty-mapping  'orchestrator-first: {}\n'
shape d-scalar-entry   'orchestrator-first: true\n'
shape d-top-level-list '- orchestrator-first\n'
# (e) 규칙 이름 인자 누락 → 비활성, exit 0 (활성 fixture 에서도).
set +e
out="$( cd "$TMP_ROOT/b-enabled" && python3 "$LOADER" --rule-enabled 2>/dev/null )"
rc=$?
set -e
[ "$rc" = "0" ] && [ "$out" = "false" ] || fail "e-missing-arg: expected 'false' + exit 0, got '$out' rc=$rc"
echo "  ok: e-missing-arg → false"
echo "test-policy-rules-enabled-flag: OK (absent / enabled / malformed / non-bool shapes / missing arg)"
