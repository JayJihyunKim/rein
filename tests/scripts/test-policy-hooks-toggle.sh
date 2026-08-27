#!/usr/bin/env bash
# test-policy-hooks-toggle.sh - Plugin-First Restructure Phase 2 Task 2.7.
#
# Verifies rein-policy-loader.py BEHAVIOR for .rein/policy/hooks.yaml:
#   Fixture A: hook enabled by default (entry omitted)              -> exit 0
#   Fixture B: hook explicitly disabled (enabled: false)            -> exit 1
#   Fixture C: yaml file missing                                     -> exit 0
#   Fixture D: yaml malformed                                        -> exit 0 + stderr warning
#   Fixture E: only OTHER hook in yaml, target hook missing key      -> exit 0
#   Fixture F: hook explicitly disabled (boolean shorthand false)    -> exit 1
#
# Loader contract: fail-open (Plan Task 2.10) - never accidentally disable a
# hook because the config file is broken. Disable accepts either
# `<hook-name>: false` shorthand or `<hook-name>: { enabled: false }`.
#
# Scope ID: policy-hooks-yaml-overrides-plugin-hook-toggles-when-present
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOADER="$PROJECT_DIR/plugins/rein-core/scripts/rein-policy-loader.py"

if [ ! -x "$LOADER" ]; then
  echo "FAIL: loader missing or not executable: $LOADER" >&2
  exit 1
fi

# Fixtures use isolated temp dirs because the loader reads
# `.rein/policy/hooks.yaml` *relative to cwd*. We never touch the rein-dev
# repo's own .rein/ tree.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

ok() {
  echo "  ok: $1"
}

run_loader() {
  # Run loader from given workdir with given hook-name; capture stderr+exit.
  local workdir="$1"
  local hook="$2"
  local stderr_file="$3"
  set +e
  ( cd "$workdir" && python3 "$LOADER" "$hook" 2>"$stderr_file" )
  local rc=$?
  set -e
  echo "$rc"
}

# run_loader_strict — same as run_loader but invokes the STRICT contract
# (Phase 7 wave 3 ③-c code review round 1 High fix): `--strict <hook-name>`,
# where rc 78 (EX_CONFIG) means "explicitly disabled" and rc 0 means
# "enabled". Used by Fixtures O/P below.
run_loader_strict() {
  local workdir="$1"
  local hook="$2"
  local stderr_file="$3"
  set +e
  ( cd "$workdir" && python3 "$LOADER" --strict "$hook" 2>"$stderr_file" )
  local rc=$?
  set -e
  echo "$rc"
}

# -----------------------------------------------------------------------------
# Fixture A: hook enabled by default (entry omitted from yaml)
# -----------------------------------------------------------------------------
A_DIR="$TMP_ROOT/A"
mkdir -p "$A_DIR/.rein/policy"
cat >"$A_DIR/.rein/policy/hooks.yaml" <<'YAML'
# entry intentionally omitted - default is enabled
post-edit-plan-coverage:
  enabled: true
YAML
A_STDERR="$A_DIR/stderr"
rc="$(run_loader "$A_DIR" "pre-bash-safety-guard" "$A_STDERR")"
[ "$rc" = "0" ] || fail "Fixture A: expected exit 0 (enabled default), got $rc"
ok "Fixture A: hook enabled by default (no entry) -> exit 0"

# -----------------------------------------------------------------------------
# Fixture B: hook explicitly disabled
# -----------------------------------------------------------------------------
B_DIR="$TMP_ROOT/B"
mkdir -p "$B_DIR/.rein/policy"
cat >"$B_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-safety-guard:
  enabled: false
YAML
B_STDERR="$B_DIR/stderr"
rc="$(run_loader "$B_DIR" "pre-bash-safety-guard" "$B_STDERR")"
[ "$rc" = "1" ] || fail "Fixture B: expected exit 1 (disabled), got $rc"
ok "Fixture B: hook explicitly disabled -> exit 1"

# -----------------------------------------------------------------------------
# Fixture C: yaml file missing entirely
# -----------------------------------------------------------------------------
C_DIR="$TMP_ROOT/C"
mkdir -p "$C_DIR"
[ ! -e "$C_DIR/.rein/policy/hooks.yaml" ] || fail "Fixture C setup: yaml should not exist"
C_STDERR="$C_DIR/stderr"
rc="$(run_loader "$C_DIR" "pre-bash-safety-guard" "$C_STDERR")"
[ "$rc" = "0" ] || fail "Fixture C: expected exit 0 (default enabled), got $rc"
ok "Fixture C: yaml missing -> exit 0"

# -----------------------------------------------------------------------------
# Fixture D: yaml malformed -> fail-open + stderr warning
# -----------------------------------------------------------------------------
D_DIR="$TMP_ROOT/D"
mkdir -p "$D_DIR/.rein/policy"
# Truly malformed YAML: triple colon at start of line is a syntax error.
cat >"$D_DIR/.rein/policy/hooks.yaml" <<'YAML'
:::
not yaml: at all: extra: colons:
  : invalid
YAML
D_STDERR="$D_DIR/stderr"
rc="$(run_loader "$D_DIR" "pre-bash-safety-guard" "$D_STDERR")"
[ "$rc" = "0" ] || fail "Fixture D: expected exit 0 (fail-open on malformed), got $rc"
if ! grep -q -i "warning" "$D_STDERR"; then
  echo "  loader stderr captured:" >&2
  cat "$D_STDERR" >&2
  fail "Fixture D: expected 'warning' in stderr, got nothing"
fi
ok "Fixture D: malformed yaml -> exit 0 + stderr warning"

# -----------------------------------------------------------------------------
# Fixture E: only OTHER hook configured, target hook key missing
# -----------------------------------------------------------------------------
E_DIR="$TMP_ROOT/E"
mkdir -p "$E_DIR/.rein/policy"
cat >"$E_DIR/.rein/policy/hooks.yaml" <<'YAML'
other-hook:
  enabled: false
YAML
E_STDERR="$E_DIR/stderr"
rc="$(run_loader "$E_DIR" "pre-bash-safety-guard" "$E_STDERR")"
[ "$rc" = "0" ] || fail "Fixture E: expected exit 0 (missing key default), got $rc"
ok "Fixture E: target hook key missing -> exit 0 (default enabled)"

# -----------------------------------------------------------------------------
# Fixture F: hook explicitly disabled via documented boolean shorthand
# -----------------------------------------------------------------------------
F_DIR="$TMP_ROOT/F"
mkdir -p "$F_DIR/.rein/policy"
cat >"$F_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-safety-guard: false
YAML
F_STDERR="$F_DIR/stderr"
rc="$(run_loader "$F_DIR" "pre-bash-safety-guard" "$F_STDERR")"
[ "$rc" = "1" ] || fail "Fixture F: expected exit 1 (boolean shorthand disabled), got $rc"
ok "Fixture F: boolean shorthand disabled -> exit 1"

# -----------------------------------------------------------------------------
# Fixture G: profile=lean 이 무거운 gate 의 기본값을 disable
# -----------------------------------------------------------------------------
G_DIR="$TMP_ROOT/G"
mkdir -p "$G_DIR/.rein/policy"
cat >"$G_DIR/.rein/policy/hooks.yaml" <<'YAML'
profile: lean
YAML
G_STDERR="$G_DIR/stderr"
rc="$(run_loader "$G_DIR" "post-edit-plan-coverage" "$G_STDERR")"
[ "$rc" = "1" ] || fail "Fixture G: lean profile expected disable post-edit-plan-coverage (exit 1), got $rc"
rc="$(run_loader "$G_DIR" "post-edit-spec-review-gate" "$G_STDERR")"
[ "$rc" = "1" ] || fail "Fixture G: lean profile expected disable post-edit-spec-review-gate (exit 1), got $rc"
rc="$(run_loader "$G_DIR" "post-edit-dod-routing-check" "$G_STDERR")"
[ "$rc" = "1" ] || fail "Fixture G: lean profile expected disable post-edit-dod-routing-check (exit 1), got $rc"
# unrelated hook 은 기본값 enabled 유지
rc="$(run_loader "$G_DIR" "pre-bash-safety-guard" "$G_STDERR")"
[ "$rc" = "0" ] || fail "Fixture G: lean profile expected enable pre-bash-safety-guard (exit 0), got $rc"
ok "Fixture G: profile=lean disables heavy gates, leaves others enabled"

# -----------------------------------------------------------------------------
# Fixture H: profile=standard / strict 는 기본값 enabled
# -----------------------------------------------------------------------------
H_DIR="$TMP_ROOT/H"
mkdir -p "$H_DIR/.rein/policy"
cat >"$H_DIR/.rein/policy/hooks.yaml" <<'YAML'
profile: standard
YAML
H_STDERR="$H_DIR/stderr"
rc="$(run_loader "$H_DIR" "post-edit-plan-coverage" "$H_STDERR")"
[ "$rc" = "0" ] || fail "Fixture H: standard expected enabled, got $rc"

H2_DIR="$TMP_ROOT/H2"
mkdir -p "$H2_DIR/.rein/policy"
cat >"$H2_DIR/.rein/policy/hooks.yaml" <<'YAML'
profile: strict
YAML
H2_STDERR="$H2_DIR/stderr"
rc="$(run_loader "$H2_DIR" "post-edit-plan-coverage" "$H2_STDERR")"
[ "$rc" = "0" ] || fail "Fixture H: strict expected enabled, got $rc"
ok "Fixture H: profile=standard/strict keeps heavy gates enabled"

# -----------------------------------------------------------------------------
# Fixture I: per-hook override 가 profile 보다 우선
# -----------------------------------------------------------------------------
I_DIR="$TMP_ROOT/I"
mkdir -p "$I_DIR/.rein/policy"
cat >"$I_DIR/.rein/policy/hooks.yaml" <<'YAML'
profile: lean
post-edit-plan-coverage: true
YAML
I_STDERR="$I_DIR/stderr"
rc="$(run_loader "$I_DIR" "post-edit-plan-coverage" "$I_STDERR")"
[ "$rc" = "0" ] || fail "Fixture I: per-hook=true expected to override profile=lean, got $rc"
# 다른 lean-disabled hook 은 여전히 disabled
rc="$(run_loader "$I_DIR" "post-edit-spec-review-gate" "$I_STDERR")"
[ "$rc" = "1" ] || fail "Fixture I: unrelated lean default still disabled, got $rc"
ok "Fixture I: per-hook entry overrides profile default"

# -----------------------------------------------------------------------------
# Fixture J: 알 수 없는 profile 이름은 warning + fall-through (enabled)
# -----------------------------------------------------------------------------
J_DIR="$TMP_ROOT/J"
mkdir -p "$J_DIR/.rein/policy"
cat >"$J_DIR/.rein/policy/hooks.yaml" <<'YAML'
profile: nonsense-mode
YAML
J_STDERR="$J_DIR/stderr"
rc="$(run_loader "$J_DIR" "post-edit-plan-coverage" "$J_STDERR")"
[ "$rc" = "0" ] || fail "Fixture J: unknown profile expected fall-through enabled, got $rc"
grep -q -i "unknown profile" "$J_STDERR" || fail "Fixture J: missing 'unknown profile' warning"
ok "Fixture J: unknown profile -> warning + fall-through enabled"

# -----------------------------------------------------------------------------
# Fixture K/L/M/N: 2-hop 승계 우선순위 (Phase 7 wave 3 ③-c 리뷰 1회차
# Medium 수리) — pre-bash-commit-discipline-gate.sh /
# pre-bash-commit-review-gate.sh 둘 다 UMBRELLA_KEYS 에
# ("pre-bash-test-commit-gate", "pre-bash-guard") 2-hop 체인으로 등록돼
# 있다(rein-policy-loader.py 참조). 개별 키가 최우선, hop1 이 hop2 보다
# 먼저 결정된다는 것을 두 successor 훅 모두에 대해 실측한다.
# -----------------------------------------------------------------------------

# K: 개별 키가 hop1 umbrella 보다 우선 (discipline-gate)
K_DIR="$TMP_ROOT/K"
mkdir -p "$K_DIR/.rein/policy"
cat >"$K_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-commit-discipline-gate: true
pre-bash-test-commit-gate: false
YAML
K_STDERR="$K_DIR/stderr"
rc="$(run_loader "$K_DIR" "pre-bash-commit-discipline-gate" "$K_STDERR")"
[ "$rc" = "0" ] || fail "Fixture K: explicit per-hook key must override hop1 umbrella (pre-bash-test-commit-gate: false), got $rc"
ok "Fixture K: pre-bash-commit-discipline-gate explicit true overrides hop1 pre-bash-test-commit-gate:false"

# L: hop1 이 present 이면 hop2 는 참조되지 않음 (discipline-gate)
L_DIR="$TMP_ROOT/L"
mkdir -p "$L_DIR/.rein/policy"
cat >"$L_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-test-commit-gate: true
pre-bash-guard: false
YAML
L_STDERR="$L_DIR/stderr"
rc="$(run_loader "$L_DIR" "pre-bash-commit-discipline-gate" "$L_STDERR")"
[ "$rc" = "0" ] || fail "Fixture L: hop1 present (true) must decide before hop2 is consulted (pre-bash-guard:false ignored), got $rc"
ok "Fixture L: pre-bash-commit-discipline-gate — hop1 pre-bash-test-commit-gate:true wins over hop2 pre-bash-guard:false"

# M: 개별 키가 hop1 umbrella 보다 우선 (review-gate — 같은 조합, 다른 훅)
M_DIR="$TMP_ROOT/M"
mkdir -p "$M_DIR/.rein/policy"
cat >"$M_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-commit-review-gate: true
pre-bash-test-commit-gate: false
YAML
M_STDERR="$M_DIR/stderr"
rc="$(run_loader "$M_DIR" "pre-bash-commit-review-gate" "$M_STDERR")"
[ "$rc" = "0" ] || fail "Fixture M: explicit per-hook key must override hop1 umbrella (pre-bash-test-commit-gate: false), got $rc"
ok "Fixture M: pre-bash-commit-review-gate explicit true overrides hop1 pre-bash-test-commit-gate:false"

# N: hop1 이 present 이면 hop2 는 참조되지 않음 (review-gate)
N_DIR="$TMP_ROOT/N"
mkdir -p "$N_DIR/.rein/policy"
cat >"$N_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-test-commit-gate: true
pre-bash-guard: false
YAML
N_STDERR="$N_DIR/stderr"
rc="$(run_loader "$N_DIR" "pre-bash-commit-review-gate" "$N_STDERR")"
[ "$rc" = "0" ] || fail "Fixture N: hop1 present (true) must decide before hop2 is consulted (pre-bash-guard:false ignored), got $rc"
ok "Fixture N: pre-bash-commit-review-gate — hop1 pre-bash-test-commit-gate:true wins over hop2 pre-bash-guard:false"

# -----------------------------------------------------------------------------
# Fixture O/P: --strict 모드 계약 (Phase 7 wave 3 ③-c 리뷰 1회차 High 수리)
# -----------------------------------------------------------------------------

# O: --strict + 명시 disable -> exit 78 (EX_CONFIG)
O_DIR="$TMP_ROOT/O"
mkdir -p "$O_DIR/.rein/policy"
cat >"$O_DIR/.rein/policy/hooks.yaml" <<'YAML'
pre-bash-commit-discipline-gate: false
YAML
O_STDERR="$O_DIR/stderr"
rc="$(run_loader_strict "$O_DIR" "pre-bash-commit-discipline-gate" "$O_STDERR")"
[ "$rc" = "78" ] || fail "Fixture O: --strict explicit disable expected exit 78 (EX_CONFIG), got $rc"
ok "Fixture O: --strict + explicit disable -> exit 78 (EX_CONFIG)"

# P: --strict + 무설정 -> exit 0 (enabled, fail-open default)
P_DIR="$TMP_ROOT/P"
mkdir -p "$P_DIR"
[ ! -e "$P_DIR/.rein/policy/hooks.yaml" ] || fail "Fixture P setup: yaml should not exist"
P_STDERR="$P_DIR/stderr"
rc="$(run_loader_strict "$P_DIR" "pre-bash-commit-discipline-gate" "$P_STDERR")"
[ "$rc" = "0" ] || fail "Fixture P: --strict with no policy configured expected exit 0 (enabled default), got $rc"
ok "Fixture P: --strict + no config -> exit 0 (enabled)"

echo "test-policy-hooks-toggle: OK (16/16 fixtures)"
