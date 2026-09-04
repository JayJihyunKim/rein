#!/usr/bin/env bash
# tests/hooks/test-security-axis-policy-resolve.sh — unit contract of
# hooks/lib/security-axis-policy-resolve.sh (the single resolver shared by
# the commit gate pre-check, the security-review delegate and the evidence
# recorder). Pins every kind the resolver can return and, above all, that a
# project override which exists in ANY form but is not usable never resolves
# to the bundle.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/plugins/rein-core/hooks/lib/security-axis-policy-resolve.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB missing" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAILN=0
pass() { PASS=$((PASS + 1)); echo "  ok  $1"; }
fail() { FAILN=$((FAILN + 1)); echo "  FAIL $1 — $2" >&2; }

TMP=$(mktemp -d -t rein-sapr-XXXXXX)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

mk_plugin() { # $1=root ; creates a bundle with commit-security.yaml
  mkdir -p "$1/policies/security-axis"
  printf 'trigger: tool.pre\nwhen:\n  command.type: git.commit\nrequire:\n  - security_review\nfailure_mode: closed\n' > "$1/policies/security-axis/commit-security.yaml"
  printf 'version: 1\n' > "$1/policies/security-axis/_version.yaml"
}
expect_kind() { # $1=label $2=expected kind $3=project $4=plugin
  rein_security_axis_policy_resolve "$3" "$4"
  if [ "$rein_security_axis_policy_kind" = "$2" ]; then
    pass "$1 → $2"
  else
    fail "$1" "expected $2, got ${rein_security_axis_policy_kind} (dir=${rein_security_axis_policy_dir})"
  fi
}

PLUGIN="$TMP/plugin"; mk_plugin "$PLUGIN"
NOPLUGIN="$TMP/plugin-empty"; mkdir -p "$NOPLUGIN"

# 1. no project folder at all → BUNDLE
P1="$TMP/p1"; mkdir -p "$P1/.rein/policy"
expect_kind "no override, bundle present" BUNDLE "$P1" "$PLUGIN"
# 2. no project folder, no bundle → NONE
expect_kind "no override, no bundle" NONE "$P1" "$NOPLUGIN"
# 3. override with file → PROJECT (even when bundle present)
P3="$TMP/p3"; mkdir -p "$P3/.rein/policy/security-axis"
printf 'trigger: tool.pre\nwhen:\n  command.type: git.commit\nrequire:\n  - security_review\nfailure_mode: closed\n' > "$P3/.rein/policy/security-axis/commit-security.yaml"
expect_kind "override with policy file" PROJECT "$P3" "$PLUGIN"
# 4. override folder without the file → PROJECT_DAMAGED (bundle present, never used)
P4="$TMP/p4"; mkdir -p "$P4/.rein/policy/security-axis"
expect_kind "override folder without file" PROJECT_DAMAGED "$P4" "$PLUGIN"
# 5. override path is a dangling symlink → PROJECT_DAMAGED
P5="$TMP/p5"; mkdir -p "$P5/.rein/policy"; ln -s "$P5/.rein/policy/gone" "$P5/.rein/policy/security-axis"
expect_kind "override path is a dangling symlink" PROJECT_DAMAGED "$P5" "$PLUGIN"
# 6. override path is a regular file → PROJECT_DAMAGED
P6="$TMP/p6"; mkdir -p "$P6/.rein/policy"; printf 'x\n' > "$P6/.rein/policy/security-axis"
expect_kind "override path is a regular file" PROJECT_DAMAGED "$P6" "$PLUGIN"
# 7. symlink to a valid override directory → PROJECT
P7="$TMP/p7"; mkdir -p "$P7/.rein/policy" "$P7/real-axis"
printf 'trigger: tool.pre\nwhen:\n  command.type: git.commit\nrequire:\n  - security_review\nfailure_mode: closed\n' > "$P7/real-axis/commit-security.yaml"
ln -s "$P7/real-axis" "$P7/.rein/policy/security-axis"
expect_kind "override path is a symlink to a valid folder" PROJECT "$P7" "$PLUGIN"
# 8. parent .rein/policy exists but is unsearchable → PROJECT_DAMAGED (skipped as root)
if [ "$(id -u)" != "0" ]; then
  P8="$TMP/p8"; mkdir -p "$P8/.rein/policy/security-axis"
  printf 'trigger: tool.pre\n' > "$P8/.rein/policy/security-axis/commit-security.yaml"
  chmod 000 "$P8/.rein/policy"
  expect_kind "policy parent folder unsearchable" PROJECT_DAMAGED "$P8" "$PLUGIN"
  chmod 755 "$P8/.rein/policy"
fi
# 10. parent .rein/policy is a dangling symlink → PROJECT_DAMAGED
P10="$TMP/p10"; mkdir -p "$P10/.rein"; ln -s "$P10/.rein/gone" "$P10/.rein/policy"
expect_kind "policy parent is a dangling symlink" PROJECT_DAMAGED "$P10" "$PLUGIN"
# 11. parent .rein/policy is an executable regular file → PROJECT_DAMAGED
P11="$TMP/p11"; mkdir -p "$P11/.rein"; printf '#!/bin/sh\n' > "$P11/.rein/policy"; chmod 755 "$P11/.rein/policy"
expect_kind "policy parent is an executable regular file" PROJECT_DAMAGED "$P11" "$PLUGIN"
# 12. .rein itself is a regular file → PROJECT_DAMAGED
P12="$TMP/p12"; mkdir -p "$P12"; printf 'x\n' > "$P12/.rein"
expect_kind ".rein is a regular file" PROJECT_DAMAGED "$P12" "$PLUGIN"
# 13. .rein absent entirely (never bootstrapped) → BUNDLE
P13="$TMP/p13"; mkdir -p "$P13"
expect_kind ".rein absent entirely" BUNDLE "$P13" "$PLUGIN"
# 9. empty project dir argument → falls to bundle tier only
expect_kind "empty project dir argument, bundle present" BUNDLE "" "$PLUGIN"

echo "test-security-axis-policy-resolve: PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ]
