#!/usr/bin/env bash
# tests/scripts/test-mark-security-reviewed.sh
#
# Phase 7 웨이브 3 ③-a 로 신설, ③-d 로 재조준 —
# plugins/rein-core/scripts/rein-mark-security-reviewed.sh 의 behavioral
# regression. rein-mark-spec-reviewed.sh 를 검증하는 tests/hooks/
# test-project-dir-resolution.sh Suite H 와 동일한 스타일(mktemp 샌드박스 +
# PASS/FAIL 카운터 + assert_* 헬퍼)을 따른다.
#
# ③-d 갱신: 이 스크립트는 더 이상 legacy `trail/dod/.security-reviewed`
# 표식을 쓰지 않는다 — v2 증거 발급(`bin/rein issue-evidence
# security_review`)이 유일한 기록 경로로 좁혀졌다. 그 결과 exit 계약도
# 재편됐다: 성공(exit 0)과 subject-empty(정상 스킵, exit 0) 을 제외한 모든
# 경로 — subject-unresolved / --reviewed-digest 미지정 / digest-mismatch /
# 그 외 명확한 거부 사유 / 발급 인프라 실패(bin/rein·python3 부재, 비정상
# CLI 종료) — 가 전부 ERROR + exit 1 로 통일됐다 (이전엔 "legacy 표식은
# 그대로 있으니 non-fatal" 이던 항목들). 이 스크립트는 이 사이클과 별도
# 워커가 병렬 구현한 `bin/rein issue-evidence` 서브커맨드를 실제로 호출하지만,
# 여기서는 여전히 **fake bin/rein 스텁**을 fixture plugin root 에 배치해
# 인터페이스 계약(`--print-digest` → digest stdout / exit 0 or a closed-value
# sentinel, `--verdict PASS --reviewed-digest <D>` → exit 0/2/기타)의 각
# 분기를 정확히 어떻게 다루는지 격리된 상태로 검증한다 — behavioral, not
# source-only (실제 서브프로세스를 기동해 stdout/exit code 를 관찰한다).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MARK_SCRIPT_SRC="$PROJECT_ROOT/plugins/rein-core/scripts/rein-mark-security-reviewed.sh"

PASS=0
FAIL=0

# All fixtures live under one base tmpdir, removed on exit. (The per-fixture
# helpers below run inside `$(...)` command substitution — a subshell — so an
# array they append to would never be visible to the parent; a single shared
# base dir sidesteps that entirely instead of trying to thread state back out
# of a subshell.)
BASE_TMP=$(mktemp -d "/tmp/mark-sec-test-XXXXXX")
trap 'rm -rf "$BASE_TMP"' EXIT

pass() {
  PASS=$((PASS + 1))
  printf '  ok  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '    %s\n' "$2"
}

assert_equal() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected=[$expected] actual=[$actual]"
  fi
}

echo "=== test-mark-security-reviewed ==="

if [ ! -f "$MARK_SCRIPT_SRC" ]; then
  echo "FAIL: $MARK_SCRIPT_SRC missing" >&2
  exit 1
fi

bash -n "$MARK_SCRIPT_SRC"
if [ $? -eq 0 ]; then
  pass "rein-mark-security-reviewed.sh passes bash -n"
else
  fail "rein-mark-security-reviewed.sh fails bash -n"
fi

# --- Fixture plugin root: <root>/scripts/rein-mark-security-reviewed.sh
# (real script, copied so its self-location-derived PLUGIN_ROOT resolves to
# this fixture) + <root>/bin/rein (fake stub). No hooks/lib/project-dir.sh is
# provided — the script's conservative PROJECT_DIR fallback engages, driven
# by REIN_PROJECT_DIR_OVERRIDE (same override rein-mark-spec-reviewed.sh's
# test suite already relies on).
#
# <root>/hooks/lib/security-axis-policy-resolve.sh (real copy) +
# <root>/policies/security-axis/commit-security.yaml (a placeholder, content
# irrelevant here) ARE provided — the script now hard-requires the resolver
# lib and resolves a POLICY_DIR before it can proceed to any mode, and every
# scenario below uses the FAKE bin/rein stub, which ignores REIN_POLICY_DIR's
# actual content entirely (it never reads the directory) so a placeholder
# bundled policy is enough to let resolution succeed without affecting any
# assertion. This fixture represents "no project override, but a genuine,
# undamaged plugin install" — the resolver falls back to this bundled
# location because _mk_fixture_project() never creates a project override.
_mk_fixture_plugin() {
  local root
  root=$(mktemp -d "$BASE_TMP/plugin-XXXXXX")
  mkdir -p "$root/scripts" "$root/bin" "$root/hooks/lib" "$root/policies/security-axis"
  cp "$MARK_SCRIPT_SRC" "$root/scripts/rein-mark-security-reviewed.sh"
  chmod +x "$root/scripts/rein-mark-security-reviewed.sh"
  cp "$PROJECT_ROOT/plugins/rein-core/hooks/lib/security-axis-policy-resolve.sh" \
    "$root/hooks/lib/security-axis-policy-resolve.sh"
  printf 'trigger: tool.pre\nwhen:\n  command.type: git.commit\nrequire:\n  - security_review\nfailure_mode: closed\n' \
    > "$root/policies/security-axis/commit-security.yaml"
  cat > "$root/bin/rein" <<'PYEOF'
#!/usr/bin/env python3
# Fake bin/rein stub for test-mark-security-reviewed.sh — implements just
# enough of the `issue-evidence` interface contract to drive the caller's
# branches. Behavior is controlled entirely via environment variables set by
# the test (FAKE_REIN_*) so one stub file serves every scenario.
import json
import os
import sys


def main():
    argv = sys.argv[1:]
    if len(argv) < 2 or argv[0] != "issue-evidence" or argv[1] != "security_review":
        sys.stderr.write("fake-bin-rein: unsupported invocation: %r\n" % (argv,))
        return 2
    rest = argv[2:]

    record_path = os.environ.get("FAKE_REIN_RECORD", "")

    if "--print-digest" in rest:
        digest = os.environ.get("FAKE_REIN_DIGEST", "")
        rc = int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        if digest:
            sys.stdout.write(digest + "\n")
        return rc

    if "--print-subject" in rest:
        # Passthrough mode (Phase 7 웨이브 3 ③-a code review round 3,
        # Finding 2) — same env-var control as --print-digest, wrapped in
        # the {"subject": ..., "paths": [...]} JSON envelope the real
        # `bin/rein issue-evidence security_review --print-subject`
        # returns. FAKE_REIN_SUBJECT_PATHS is a newline-separated path
        # list (repo-relative), empty by default.
        digest = os.environ.get("FAKE_REIN_DIGEST", "")
        rc = int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        paths_raw = os.environ.get("FAKE_REIN_SUBJECT_PATHS", "")
        paths = [p for p in paths_raw.split("\n") if p]
        if digest:
            sys.stdout.write(
                json.dumps({"subject": digest, "paths": paths}) + "\n"
            )
        return rc

    if "--verdict" in rest:
        if record_path:
            with open(record_path, "a") as f:
                f.write(" ".join(rest) + "\n")
        stderr_noise = os.environ.get("FAKE_REIN_ISSUE_STDERR", "")
        if stderr_noise:
            sys.stderr.write(stderr_noise + "\n")
        rc = int(os.environ.get("FAKE_REIN_ISSUE_RC", "0"))
        payload = os.environ.get(
            "FAKE_REIN_ISSUE_JSON", '{"issued": true}'
        )
        sys.stdout.write(payload + "\n")
        return rc

    sys.stderr.write("fake-bin-rein: unrecognized args: %r\n" % (rest,))
    return 2


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "$root/bin/rein"
  echo "$root"
}

_mk_fixture_project() {
  local root
  root=$(mktemp -d "$BASE_TMP/project-XXXXXX")
  mkdir -p "$root/trail/dod"
  echo "$root"
}

# Run the mark script with a clean, controlled environment. Positional args
# after the fixture roots are passed straight through to the script.
_run_mark() {
  local plugin_root="$1" project_root="$2"
  shift 2
  (
    unset REIN_PROJECT_DIR CLAUDE_PLUGIN_ROOT
    export REIN_PROJECT_DIR_OVERRIDE="$project_root"
    bash "$plugin_root/scripts/rein-mark-security-reviewed.sh" "$@"
  )
}

# No legacy stamp exists anywhere anymore — every scenario below asserts
# trail/dod/.security-reviewed is ABSENT (write path fully removed, ③-d).
_assert_no_stamp() {
  local project_root="$1" label="$2"
  if [ -e "$project_root/trail/dod/.security-reviewed" ]; then
    fail "$label" "unexpected legacy stamp file present: $project_root/trail/dod/.security-reviewed"
  else
    pass "$label"
  fi
}

# ----------------------------------------------------------------------------
# (i) v2 issuance ALLOW path — exit 0, no legacy stamp (never written)
# ----------------------------------------------------------------------------
echo ""
echo "[i] v2 issuance ALLOW path: exit 0, no legacy stamp file"

PLUGIN_I=$(_mk_fixture_plugin)
PROJECT_I=$(_mk_fixture_project)
RECORD_I="$PROJECT_I/issue-record.log"

# Finding 2 (code review round 1) — the script does not self-capture a
# digest via --print-digest; the caller must supply --reviewed-digest
# (the review-START value) directly.
out_i=$(FAKE_REIN_ISSUE_RC=0 \
        FAKE_REIN_ISSUE_JSON='{"issued": true, "id": "ev-1"}' \
        FAKE_REIN_RECORD="$RECORD_I" \
        _run_mark "$PLUGIN_I" "$PROJECT_I" --level standard --cycle cycle-i --verdict PASS \
          --reviewed-digest sha256:deadbeef 2>&1)
rc_i=$?

assert_equal "exit 0 on successful ALLOW issuance" "0" "$rc_i"
_assert_no_stamp "$PROJECT_I" "no legacy stamp file created on ALLOW (write path removed)"

if [ -f "$RECORD_I" ] && grep -q -- "--reviewed-digest sha256:deadbeef" "$RECORD_I"; then
  pass "issuance attempted with the caller-supplied --reviewed-digest"
else
  fail "issuance attempted with the caller-supplied --reviewed-digest" \
    "record file: $(cat "$RECORD_I" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$out_i" | grep -q "OK: \[mark-security-reviewed\] v2 evidence issued"; then
  pass "stderr confirms v2 evidence issued on ALLOW"
else
  fail "stderr confirms v2 evidence issued on ALLOW" "stderr: $out_i"
fi

# ----------------------------------------------------------------------------
# (ii) Non-PASS verdict issues nothing and exits non-zero
# ----------------------------------------------------------------------------
echo ""
echo "[ii] non-PASS verdict issues nothing, exits non-zero"

PLUGIN_II=$(_mk_fixture_plugin)
PROJECT_II=$(_mk_fixture_project)

_run_mark "$PLUGIN_II" "$PROJECT_II" --level base --cycle cycle-ii --verdict NEEDS-FIX >/dev/null 2>&1
rc_needsfix=$?
assert_equal "explicit --verdict NEEDS-FIX exits non-zero" "1" "$rc_needsfix"
_assert_no_stamp "$PROJECT_II" "no legacy stamp for --verdict NEEDS-FIX"

# Missing --verdict entirely must also refuse (only PASS may issue).
_run_mark "$PLUGIN_II" "$PROJECT_II" --level base --cycle cycle-ii >/dev/null 2>&1
rc_missing=$?
if [ "$rc_missing" -ne 0 ]; then
  pass "omitted --verdict exits non-zero"
else
  fail "omitted --verdict exits non-zero" "got rc=0"
fi
_assert_no_stamp "$PROJECT_II" "no legacy stamp when --verdict omitted"

# ----------------------------------------------------------------------------
# (iii-a) subject-empty sentinel -> normal skip, exit 0, NOTICE
# ----------------------------------------------------------------------------
echo ""
echo "[iii-a] empty:no-subject sentinel -> normal skip (exit 0)"

PLUGIN_IIIA=$(_mk_fixture_plugin)
PROJECT_IIIA=$(_mk_fixture_project)
RECORD_IIIA="$PROJECT_IIIA/issue-record.log"

out_iiia=$(FAKE_REIN_RECORD="$RECORD_IIIA" \
           _run_mark "$PLUGIN_IIIA" "$PROJECT_IIIA" --level strict --cycle cycle-empty --verdict PASS \
             --reviewed-digest "empty:no-subject" 2>&1)
rc_iiia=$?

assert_equal "exit 0 for empty:no-subject (nothing sensitive to review)" "0" "$rc_iiia"
_assert_no_stamp "$PROJECT_IIIA" "no legacy stamp for empty:no-subject"

if [ -f "$RECORD_IIIA" ]; then
  fail "issuance NOT attempted for empty:no-subject" \
    "unexpected record: $(cat "$RECORD_IIIA")"
else
  pass "issuance NOT attempted for empty:no-subject"
fi

if printf '%s' "$out_iiia" | grep -q "NOTICE: \[mark-security-reviewed\]"; then
  pass "stderr carries a NOTICE for empty:no-subject"
else
  fail "stderr carries a NOTICE for empty:no-subject" "stderr: $out_iiia"
fi

# ----------------------------------------------------------------------------
# (iii-b) subject-unresolved sentinel -> NOW an ERROR (③-d — no legacy
# fallback left to soften "could not determine what to review").
# ----------------------------------------------------------------------------
echo ""
echo "[iii-b] unresolved:no-subject sentinel -> ERROR (exit 1, ③-d reversal)"

PLUGIN_IIIB=$(_mk_fixture_plugin)
PROJECT_IIIB=$(_mk_fixture_project)
RECORD_IIIB="$PROJECT_IIIB/issue-record.log"

out_iiib=$(FAKE_REIN_RECORD="$RECORD_IIIB" \
           _run_mark "$PLUGIN_IIIB" "$PROJECT_IIIB" --level strict --cycle cycle-unresolved --verdict PASS \
             --reviewed-digest "unresolved:no-subject" 2>&1)
rc_iiib=$?

if [ "$rc_iiib" -ne 0 ]; then
  pass "exit non-zero for unresolved:no-subject (fail-closed, no legacy fallback)"
else
  fail "exit non-zero for unresolved:no-subject (fail-closed, no legacy fallback)" "got rc=0"
fi
_assert_no_stamp "$PROJECT_IIIB" "no legacy stamp for unresolved:no-subject"

if [ -f "$RECORD_IIIB" ]; then
  fail "issuance NOT attempted for unresolved:no-subject" \
    "unexpected record: $(cat "$RECORD_IIIB")"
else
  pass "issuance NOT attempted for unresolved:no-subject"
fi

if printf '%s' "$out_iiib" | grep -q "ERROR: \[mark-security-reviewed\] the review subject could not be determined"; then
  pass "stderr carries an ERROR (not a NOTICE) for unresolved:no-subject"
else
  fail "stderr carries an ERROR (not a NOTICE) for unresolved:no-subject" "stderr: $out_iiib"
fi

# ----------------------------------------------------------------------------
# (iv) Issuance refusal (exit 2, reason != digest-mismatch) is NOW an ERROR
# (③-d reversal — was non-fatal/WARNING while the legacy stamp existed).
# ----------------------------------------------------------------------------
echo ""
echo "[iv] issuance exit 2 refusal (reason=no-active-dod) -> ERROR (exit 1, ③-d reversal)"

PLUGIN_IV=$(_mk_fixture_plugin)
PROJECT_IV=$(_mk_fixture_project)
RECORD_IV="$PROJECT_IV/issue-record.log"

out_iv=$(FAKE_REIN_ISSUE_RC=2 \
         FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "no-active-dod"}' \
         FAKE_REIN_RECORD="$RECORD_IV" \
         _run_mark "$PLUGIN_IV" "$PROJECT_IV" --level standard --cycle cycle-iv --verdict PASS \
           --reviewed-digest sha256:cafebabe 2>&1)
rc_iv=$?

if [ "$rc_iv" -ne 0 ]; then
  pass "exit non-zero on a non-digest-mismatch refusal (no legacy fallback left)"
else
  fail "exit non-zero on a non-digest-mismatch refusal (no legacy fallback left)" "got rc=0"
fi
_assert_no_stamp "$PROJECT_IV" "no legacy stamp after issuance refusal"

if printf '%s' "$out_iv" | grep -q "ERROR: \[mark-security-reviewed\] v2 evidence issuance was refused — nothing was recorded this cycle"; then
  pass "stderr carries an ERROR (not the old non-fatal WARNING) for the refusal"
else
  fail "stderr carries an ERROR (not the old non-fatal WARNING) for the refusal" "stderr: $out_iv"
fi

if [ -f "$RECORD_IV" ] && grep -q -- "--reviewed-digest sha256:cafebabe" "$RECORD_IV"; then
  pass "issuance was attempted (and recorded) before being refused"
else
  fail "issuance was attempted (and recorded) before being refused" \
    "record file: $(cat "$RECORD_IV" 2>/dev/null || echo '<absent>')"
fi

# ----------------------------------------------------------------------------
# (v) --reviewed-digest omitted -> NOW an ERROR (③-d reversal — no
# start-time digest means there is nothing honest to bind evidence to, and
# there is no longer a legacy fallback to skip issuance in favor of).
# ----------------------------------------------------------------------------
echo ""
echo "[v] --reviewed-digest omitted -> ERROR (exit 1, ③-d reversal)"

PLUGIN_V2=$(_mk_fixture_plugin)
PROJECT_V2=$(_mk_fixture_project)
RECORD_V2="$PROJECT_V2/issue-record.log"

out_v2=$(FAKE_REIN_RECORD="$RECORD_V2" \
         _run_mark "$PLUGIN_V2" "$PROJECT_V2" --level base --cycle cycle-v2 --verdict PASS 2>&1)
rc_v2=$?

if [ "$rc_v2" -ne 0 ]; then
  pass "exit non-zero when --reviewed-digest is omitted"
else
  fail "exit non-zero when --reviewed-digest is omitted" "got rc=0"
fi
_assert_no_stamp "$PROJECT_V2" "no legacy stamp when --reviewed-digest is omitted"

if [ -f "$RECORD_V2" ]; then
  fail "issuance NOT attempted when --reviewed-digest is omitted" \
    "unexpected record: $(cat "$RECORD_V2")"
else
  pass "issuance NOT attempted when --reviewed-digest is omitted"
fi

if printf '%s' "$out_v2" | grep -q "ERROR: \[mark-security-reviewed\] no --reviewed-digest was provided"; then
  pass "stderr carries an ERROR (not the old NOTICE) explaining the omitted --reviewed-digest"
else
  fail "stderr carries an ERROR (not the old NOTICE) explaining the omitted --reviewed-digest" "stderr: $out_v2"
fi

# ----------------------------------------------------------------------------
# (vi) digest-mismatch refusal — still an ERROR (exit 1), unchanged in
# spirit from ③-a; only the "no legacy stamp exists to protect" framing and
# the exact stderr wording changed.
# ----------------------------------------------------------------------------
echo ""
echo "[vi] digest-mismatch refusal -> ERROR (exit 1)"

PLUGIN_VI=$(_mk_fixture_plugin)
PROJECT_VI=$(_mk_fixture_project)
RECORD_VI="$PROJECT_VI/issue-record.log"

out_vi=$(FAKE_REIN_ISSUE_RC=2 \
         FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "digest-mismatch"}' \
         FAKE_REIN_RECORD="$RECORD_VI" \
         _run_mark "$PLUGIN_VI" "$PROJECT_VI" --level strict --cycle cycle-vi --verdict PASS \
           --reviewed-digest sha256:stale 2>&1)
rc_vi=$?

if [ "$rc_vi" -ne 0 ]; then
  pass "exit non-zero on digest-mismatch refusal"
else
  fail "exit non-zero on digest-mismatch refusal" "got rc=0"
fi
_assert_no_stamp "$PROJECT_VI" "no legacy stamp on digest-mismatch refusal"

if [ -f "$RECORD_VI" ] && grep -q -- "--reviewed-digest sha256:stale" "$RECORD_VI"; then
  pass "issuance was attempted (and recorded) before being refused as digest-mismatch"
else
  fail "issuance was attempted (and recorded) before being refused as digest-mismatch" \
    "record file: $(cat "$RECORD_VI" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$out_vi" | grep -q "ERROR: \[mark-security-reviewed\] v2 evidence issuance refused (digest-mismatch)"; then
  pass "stderr identifies the refusal as digest-mismatch"
else
  fail "stderr identifies the refusal as digest-mismatch" "stderr: $out_vi"
fi

if printf '%s' "$out_vi" | grep -q "Nothing was recorded this cycle; re-review the current tree"; then
  pass "stderr states nothing was recorded and a re-review is needed"
else
  fail "stderr states nothing was recorded and a re-review is needed" "stderr: $out_vi"
fi

# ----------------------------------------------------------------------------
# (vii) non-digest-mismatch refusal (reason=no-active-dod) — duplicate of
# (iv) kept as an explicit named scenario per the original suite's
# "machinery errors i.e. non-2 exits or exit 2 with other reasons" carve-out,
# now unified into the ERROR path.
# ----------------------------------------------------------------------------
echo ""
echo "[vii] refusal for a reason OTHER than digest-mismatch -> ERROR (exit 1)"

PLUGIN_VII=$(_mk_fixture_plugin)
PROJECT_VII=$(_mk_fixture_project)
RECORD_VII="$PROJECT_VII/issue-record.log"

out_vii=$(FAKE_REIN_ISSUE_RC=2 \
          FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "no-active-dod"}' \
          FAKE_REIN_RECORD="$RECORD_VII" \
          _run_mark "$PLUGIN_VII" "$PROJECT_VII" --level standard --cycle cycle-vii --verdict PASS \
            --reviewed-digest sha256:other-reason 2>&1)
rc_vii=$?

if [ "$rc_vii" -ne 0 ]; then
  pass "exit non-zero for a non-digest-mismatch refusal"
else
  fail "exit non-zero for a non-digest-mismatch refusal" "got rc=0"
fi
_assert_no_stamp "$PROJECT_VII" "no legacy stamp for a non-digest-mismatch refusal"

if printf '%s' "$out_vii" | grep -q "ERROR: \[mark-security-reviewed\] v2 evidence issuance was refused — nothing was recorded this cycle"; then
  pass "stderr carries the unified ERROR (not the old non-fatal WARNING) for the other-reason refusal"
else
  fail "stderr carries the unified ERROR (not the old non-fatal WARNING) for the other-reason refusal" "stderr: $out_vii"
fi

# ----------------------------------------------------------------------------
# (viii) a genuine machinery error (non-2 exit, e.g. a crash/UsageError) is
# NOW also an ERROR + exit 1 (③-d reversal — only subject-empty/success are
# non-fatal now; there is no legacy stamp left for anything else to spare).
# ----------------------------------------------------------------------------
echo ""
echo "[viii] non-2 machinery exit from issuance -> ERROR (exit 1, ③-d reversal)"

PLUGIN_VIII=$(_mk_fixture_plugin)
PROJECT_VIII=$(_mk_fixture_project)
RECORD_VIII="$PROJECT_VIII/issue-record.log"

out_viii=$(FAKE_REIN_ISSUE_RC=1 \
           FAKE_REIN_RECORD="$RECORD_VIII" \
           _run_mark "$PLUGIN_VIII" "$PROJECT_VIII" --level base --cycle cycle-viii --verdict PASS \
             --reviewed-digest sha256:machinery 2>&1)
rc_viii=$?

if [ "$rc_viii" -ne 0 ]; then
  pass "exit non-zero for a non-2 machinery exit from issuance"
else
  fail "exit non-zero for a non-2 machinery exit from issuance" "got rc=0"
fi
_assert_no_stamp "$PROJECT_VIII" "no legacy stamp for a non-2 machinery exit"

if printf '%s' "$out_viii" | grep -q "ERROR: \[mark-security-reviewed\] v2 evidence issuance did not complete (exit 1"; then
  pass "stderr carries an ERROR (not the old non-fatal NOTICE) for the machinery exit"
else
  fail "stderr carries an ERROR (not the old non-fatal NOTICE) for the machinery exit" "stderr: $out_viii"
fi

# ----------------------------------------------------------------------------
# (ix) --print-digest — Finding 2 (code review round 2): capture and
# issuance must share exactly one env-construction code path. This mode
# calls `bin/rein issue-evidence security_review --print-digest` with the
# same REIN_PROJECT_ROOT/REIN_POLICY_DIR the write-mode issuance call above
# uses — the fake stub's --print-digest branch is driven by FAKE_REIN_DIGEST.
# Unaffected by ③-d (this mode never touched the legacy stamp either).
# ----------------------------------------------------------------------------
echo ""
echo "[ix] --print-digest prints the digest computed via the shared env"

PLUGIN_IX=$(_mk_fixture_plugin)
PROJECT_IX=$(_mk_fixture_project)

out_ix=$(FAKE_REIN_DIGEST="sha256:review-start-value" FAKE_REIN_DIGEST_RC=0 \
         _run_mark "$PLUGIN_IX" "$PROJECT_IX" --print-digest)
rc_ix=$?

assert_equal "--print-digest exits 0 on success" "0" "$rc_ix"
assert_equal "--print-digest prints exactly the digest" "sha256:review-start-value" "$out_ix"

# Failure path: the fake stub reports a non-zero digest-probe exit.
out_ix_fail=$(FAKE_REIN_DIGEST_RC=1 \
              _run_mark "$PLUGIN_IX" "$PROJECT_IX" --print-digest 2>/dev/null)
rc_ix_fail=$?
if [ "$rc_ix_fail" -ne 0 ]; then
  pass "--print-digest exits non-zero when the digest probe fails"
else
  fail "--print-digest exits non-zero when the digest probe fails" "got rc=0, stdout=$out_ix_fail"
fi

# Mutual exclusivity: --print-digest cannot be combined with the write-mode
# flags (usage error, loud).
_run_mark "$PLUGIN_IX" "$PROJECT_IX" --print-digest --level base >/dev/null 2>&1
rc_ix_combo=$?
if [ "$rc_ix_combo" -ne 0 ]; then
  pass "--print-digest combined with --level is a usage error"
else
  fail "--print-digest combined with --level is a usage error" "got rc=0"
fi

# ----------------------------------------------------------------------------
# (x) --print-subject — passthrough mode (Finding 2, code review round 3).
# Same shared env-construction as --print-digest/issuance; unaffected by
# ③-d (never touched the legacy stamp either).
# ----------------------------------------------------------------------------
echo ""
echo "[x] --print-subject passes through the {subject, paths} JSON computed via the shared env"

PLUGIN_X=$(_mk_fixture_plugin)
PROJECT_X=$(_mk_fixture_project)

out_x=$(FAKE_REIN_DIGEST="sha256:review-start-value" \
        FAKE_REIN_DIGEST_RC=0 \
        FAKE_REIN_SUBJECT_PATHS=".env
config/secrets.json" \
        _run_mark "$PLUGIN_X" "$PROJECT_X" --print-subject)
rc_x=$?

assert_equal "--print-subject exits 0 on success" "0" "$rc_x"
assert_equal "--print-subject passes through the JSON envelope unmodified" \
  '{"subject": "sha256:review-start-value", "paths": [".env", "config/secrets.json"]}' \
  "$out_x"

# Failure path: the fake stub reports a non-zero subject-probe exit.
out_x_fail=$(FAKE_REIN_DIGEST_RC=1 \
             _run_mark "$PLUGIN_X" "$PROJECT_X" --print-subject 2>/dev/null)
rc_x_fail=$?
if [ "$rc_x_fail" -ne 0 ]; then
  pass "--print-subject exits non-zero when the subject-snapshot probe fails"
else
  fail "--print-subject exits non-zero when the subject-snapshot probe fails" "got rc=0, stdout=$out_x_fail"
fi

# Mutual exclusivity: --print-subject cannot be combined with --print-digest
# or the write-mode flags (usage error, loud).
_run_mark "$PLUGIN_X" "$PROJECT_X" --print-subject --print-digest >/dev/null 2>&1
rc_x_combo_digest=$?
if [ "$rc_x_combo_digest" -ne 0 ]; then
  pass "--print-subject combined with --print-digest is a usage error"
else
  fail "--print-subject combined with --print-digest is a usage error" "got rc=0"
fi

_run_mark "$PLUGIN_X" "$PROJECT_X" --print-subject --level base >/dev/null 2>&1
rc_x_combo_level=$?
if [ "$rc_x_combo_level" -ne 0 ]; then
  pass "--print-subject combined with --level is a usage error"
else
  fail "--print-subject combined with --level is a usage error" "got rc=0"
fi

# ----------------------------------------------------------------------------
# (xi) Tempfile creation failure during issuance's exit-2 response capture
# fails closed (Finding 3, code review round 3). When the stderr-capture
# tempfile (`mktemp "${TMPDIR:-/tmp}/rein-msr-err.XXXXXX"`) cannot be
# created, the script falls back to merging stdout+stderr (`2>&1`). If the
# fake bin/rein ALSO writes noise to stderr on the --verdict call, that
# noise corrupts the JSON the script tries to parse for the refusal
# `reason` — an unparseable response must fail closed (treated exactly like
# digest-mismatch) rather than falling through to a softer branch. Since
# ③-d removed the softer branch entirely (every non-success/non-empty
# outcome is now ERROR + exit 1), this scenario's *headline* assertion
# (exit non-zero) is now identical to (iv)/(vii)/(viii) — what it still
# uniquely pins is the SPECIFIC fail-closed wording for an unparseable exit-2
# response. TMPDIR is pointed at a directory that does not exist so mktemp
# is guaranteed to fail.
# ----------------------------------------------------------------------------
echo ""
echo "[xi] tempfile creation failure + unparseable exit-2 response fails closed"

PLUGIN_XI=$(_mk_fixture_plugin)
PROJECT_XI=$(_mk_fixture_project)
RECORD_XI="$PROJECT_XI/issue-record.log"
BAD_TMPDIR_XI="$BASE_TMP/nonexistent-tmpdir-for-xi/deeper"

out_xi=$(TMPDIR="$BAD_TMPDIR_XI" \
         FAKE_REIN_ISSUE_RC=2 \
         FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "no-active-dod"}' \
         FAKE_REIN_ISSUE_STDERR='some diagnostic noise that corrupts the stdout+stderr merge' \
         FAKE_REIN_RECORD="$RECORD_XI" \
         _run_mark "$PLUGIN_XI" "$PROJECT_XI" --level strict --cycle cycle-xi --verdict PASS \
           --reviewed-digest sha256:tempfile-failure 2>&1)
rc_xi=$?

if [ "$rc_xi" -ne 0 ]; then
  pass "exit non-zero when tempfile creation fails and the exit-2 response is unparseable"
else
  fail "exit non-zero when tempfile creation fails and the exit-2 response is unparseable" "got rc=0"
fi
_assert_no_stamp "$PROJECT_XI" "no legacy stamp when tempfile creation fails and the response is unparseable"

if [ -f "$RECORD_XI" ] && grep -q -- "--reviewed-digest sha256:tempfile-failure" "$RECORD_XI"; then
  pass "issuance was attempted before failing closed"
else
  fail "issuance was attempted before failing closed" \
    "record file: $(cat "$RECORD_XI" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$out_xi" | grep -q "ERROR: \[mark-security-reviewed\] v2 evidence issuance refused (exit 2) but the response could not be positively parsed"; then
  pass "stderr states the fail-closed reason (unparseable response)"
else
  fail "stderr states the fail-closed reason (unparseable response)" "stderr: $out_xi"
fi

# ----------------------------------------------------------------------------
# Bonus: --level rejects out-of-enum values (loud usage error)
# ----------------------------------------------------------------------------
echo ""
echo "[bonus] --level enum validation"

PLUGIN_V=$(_mk_fixture_plugin)
PROJECT_V=$(_mk_fixture_project)
_run_mark "$PLUGIN_V" "$PROJECT_V" --level nonsense --cycle cycle-v --verdict PASS >/dev/null 2>&1
rc_v=$?
if [ "$rc_v" -ne 0 ]; then
  pass "unknown --level value exits non-zero"
else
  fail "unknown --level value exits non-zero" "got rc=0"
fi
_assert_no_stamp "$PROJECT_V" "no legacy stamp for unknown --level value"

# ----------------------------------------------------------------------------
# (xii) --cycle control-character hardening. CYCLE flows unquoted into a log
# line ("level=$LEVEL cycle=$CYCLE") — a raw LF/CR could inject or corrupt
# that diagnostic output. Rejecting the whole control-character class (not
# just LF) at argument-validation time keeps this closed by construction
# rather than by enumeration. Unaffected in spirit by ③-d — this validation
# happens before any issuance is attempted — only the exact stderr wording
# and the "no stamp" framing changed (there is no stamp to protect anymore,
# but the validation itself is identical).
# ----------------------------------------------------------------------------
echo ""
echo "[xii] --cycle control-character hardening"

PLUGIN_XII=$(_mk_fixture_plugin)
PROJECT_XII=$(_mk_fixture_project)

# (a) LF embedded in --cycle
cycle_lf="$(printf 'foo\nverdict=PASS')"
out_xii_lf=$(_run_mark "$PLUGIN_XII" "$PROJECT_XII" --level base --cycle "$cycle_lf" --verdict PASS 2>&1)
rc_xii_lf=$?
if [ "$rc_xii_lf" -ne 0 ]; then
  pass "--cycle with an embedded LF exits non-zero"
else
  fail "--cycle with an embedded LF exits non-zero" "got rc=0"
fi
_assert_no_stamp "$PROJECT_XII" "no legacy stamp for --cycle with an embedded LF"
if printf '%s' "$out_xii_lf" | grep -q "ERROR: \[mark-security-reviewed\]"; then
  pass "stderr carries an ERROR for --cycle with an embedded LF"
else
  fail "stderr carries an ERROR for --cycle with an embedded LF" "stderr: $out_xii_lf"
fi

# (b) CR embedded in --cycle
cycle_cr="$(printf 'foo\rbar')"
out_xii_cr=$(_run_mark "$PLUGIN_XII" "$PROJECT_XII" --level base --cycle "$cycle_cr" --verdict PASS 2>&1)
rc_xii_cr=$?
if [ "$rc_xii_cr" -ne 0 ]; then
  pass "--cycle with an embedded CR exits non-zero"
else
  fail "--cycle with an embedded CR exits non-zero" "got rc=0"
fi
_assert_no_stamp "$PROJECT_XII" "no legacy stamp for --cycle with an embedded CR"

# (c) normal cycle value (hyphen/underscore/alnum dod-slug) still passes the
# validation and reaches issuance — regression guard that the
# control-character check doesn't overreach. Uses a fresh fixture + PASS
# issuance so exit 0 reflects successful issuance, not accidental validation
# leniency.
PLUGIN_XIIC=$(_mk_fixture_plugin)
PROJECT_XIIC=$(_mk_fixture_project)
out_xii_ok=$(FAKE_REIN_ISSUE_RC=0 \
             _run_mark "$PLUGIN_XIIC" "$PROJECT_XIIC" --level base --cycle "normal-dod-slug_123" --verdict PASS \
               --reviewed-digest sha256:normal-cycle 2>&1)
rc_xii_ok=$?
assert_equal "a normal --cycle value (hyphen/underscore/alnum) still exits 0" "0" "$rc_xii_ok"

# (d) the ERROR message names the actual reason (control character / cycle),
# not just a generic usage error, so a caller can tell what tripped it.
if printf '%s' "$out_xii_lf" | grep -qi "cycle" && printf '%s' "$out_xii_lf" | grep -qi "control"; then
  pass "ERROR message names --cycle and control character as the reason"
else
  fail "ERROR message names --cycle and control character as the reason" "stderr: $out_xii_lf"
fi

# ----------------------------------------------------------------------------
# (xiii) Real bundle-only policy resolution — security-axis bundling
# (plugins/rein-core/policies/security-axis/, project override at
# .rein/policy/security-axis/ takes priority when present). Every scenario
# above drives the FAKE bin/rein stub, which ignores REIN_POLICY_DIR's
# content entirely — it cannot prove this script resolves the RIGHT
# directory. These scenarios link the REAL rein package + REAL bin/rein +
# the REAL bundled security-axis policy, with NO per-project override
# anywhere, to exercise the resolver end to end against the actual engine.
# ----------------------------------------------------------------------------
echo ""
echo "[xiii] real bundle-only policy resolution (no project override anywhere)"

# _mk_real_fixture_plugin — unlike _mk_fixture_plugin (fake bin/rein stub),
# this links the genuine rein package, bin/rein, hooks/lib/ (for the shared
# resolver + project-dir.sh), and the real policies/ tree (bundled
# security-axis default included) — the shape a real, undamaged plugin
# install has.
_mk_real_fixture_plugin() {
  local root
  root=$(mktemp -d "$BASE_TMP/realplugin-XXXXXX")
  mkdir -p "$root/scripts" "$root/bin" "$root/hooks"
  cp "$MARK_SCRIPT_SRC" "$root/scripts/rein-mark-security-reviewed.sh"
  chmod +x "$root/scripts/rein-mark-security-reviewed.sh"
  ln -sfn "$PROJECT_ROOT/plugins/rein-core/rein" "$root/rein"
  ln -sfn "$PROJECT_ROOT/plugins/rein-core/bin/rein" "$root/bin/rein"
  ln -sfn "$PROJECT_ROOT/plugins/rein-core/hooks/lib" "$root/hooks/lib"
  ln -sfn "$PROJECT_ROOT/plugins/rein-core/policies" "$root/policies"
  echo "$root"
}

# _mk_real_git_project — a real git repo (issue-evidence's digest
# computation needs one), no .rein/policy/security-axis override anywhere.
_mk_real_git_project() {
  local root
  root=$(mktemp -d "$BASE_TMP/realproject-XXXXXX")
  mkdir -p "$root/trail/dod"
  git -C "$root" init -q
  git -C "$root" config user.email "t@example.com"
  git -C "$root" config user.name "t"
  git -C "$root" config commit.gpgsign false
  printf '# baseline\n' > "$root/CHANGELOG.md"
  git -C "$root" add CHANGELOG.md
  git -C "$root" commit -q -m "chore: baseline"
  echo "$root"
}

# (a) red (before the bundled policy existed): no project override anywhere
# meant POLICY_DIR pointed at a directory that never existed, and bin/rein
# issue-evidence failed reading it — this script surfaced that as a plain
# "the digest probe failed" error, not a subject. green: the resolver falls
# back to the real bundled policy and the real engine computes a genuine
# subject for a staged sensitive-classified path (.env, the default
# `sensitive` digest_scope profile's target — the bundled _version.yaml
# declares no digest_scope override).
PLUGIN_XIII=$(_mk_real_fixture_plugin)
PROJECT_XIII=$(_mk_real_git_project)
printf 'SECRET=shh\n' > "$PROJECT_XIII/.env"
git -C "$PROJECT_XIII" add .env

out_xiii=$(_run_mark "$PLUGIN_XIII" "$PROJECT_XIII" --print-subject 2>&1)
rc_xiii=$?

if [ "$rc_xiii" -eq 0 ]; then
  pass "--print-subject exits 0 against the real bundled policy (no project override anywhere)"
else
  fail "--print-subject exits 0 against the real bundled policy (no project override anywhere)" "rc=$rc_xiii output: $out_xiii"
fi

if printf '%s' "$out_xiii" | grep -q '"subject"' && ! printf '%s' "$out_xiii" | grep -q '"subject": ""'; then
  pass "--print-subject reports a non-empty subject via the bundled default policy"
else
  fail "--print-subject reports a non-empty subject via the bundled default policy" "output: $out_xiii"
fi

# (b) a damaged project override (folder present, commit-security.yaml
# missing) must fail closed WITHOUT ever pointing the user at git — the
# original bug's issuance-side symptom was a git-misleading absorbed-OSError
# message when the axis folder did not resolve to anything real.
PLUGIN_XIIIB=$(_mk_real_fixture_plugin)
PROJECT_XIIIB=$(_mk_real_git_project)
mkdir -p "$PROJECT_XIIIB/.rein/policy/security-axis"
printf 'version: 1\n' > "$PROJECT_XIIIB/.rein/policy/security-axis/_version.yaml"
# commit-security.yaml deliberately absent — damaged override, must not
# fall through to the bundle.

out_xiiib=$(_run_mark "$PLUGIN_XIIIB" "$PROJECT_XIIIB" --print-subject 2>&1)
rc_xiiib=$?

if [ "$rc_xiiib" -ne 0 ]; then
  pass "--print-subject fails closed when the project override folder is damaged"
else
  fail "--print-subject fails closed when the project override folder is damaged" "got rc=0, output: $out_xiiib"
fi

if printf '%s' "$out_xiiib" | grep -qF ".rein/policy/security-axis"; then
  pass "the damaged-folder error names the actual folder"
else
  fail "the damaged-folder error names the actual folder" "output: $out_xiiib"
fi

# (b-2) the override path exists but is a dangling symlink — not "absent",
# so it must be treated as damaged and never fall through to the bundle.
PLUGIN_XIIIC=$(_mk_real_fixture_plugin)
PROJECT_XIIIC=$(_mk_real_git_project)
mkdir -p "$PROJECT_XIIIC/.rein/policy"
ln -s "$PROJECT_XIIIC/.rein/policy/security-axis-gone" "$PROJECT_XIIIC/.rein/policy/security-axis"

out_xiiic=$(_run_mark "$PLUGIN_XIIIC" "$PROJECT_XIIIC" --print-subject 2>&1)
rc_xiiic=$?

if [ "$rc_xiiic" -ne 0 ]; then
  pass "--print-subject fails closed when the project override path is a dangling symlink"
else
  fail "--print-subject fails closed when the project override path is a dangling symlink" "got rc=0, output: $out_xiiic"
fi

if printf '%s' "$out_xiiic" | grep -qF "not a directory"; then
  pass "the dangling-symlink error says the path is not a directory"
else
  fail "the dangling-symlink error says the path is not a directory" "output: $out_xiiic"
fi

# (b-3) the override folder is fine but its parent (.rein/policy) cannot be
# searched — the child's existence cannot be judged, so this must be treated
# as damaged (never resolved to the bundle). Skipped as root (permission
# bits are bypassed there).
if [ "$(id -u)" != "0" ]; then
  PLUGIN_XIIID=$(_mk_real_fixture_plugin)
  PROJECT_XIIID=$(_mk_real_git_project)
  mkdir -p "$PROJECT_XIIID/.rein/policy/security-axis"
  cp "$PROJECT_ROOT/tests/fixtures/policy/security-axis/"*.yaml "$PROJECT_XIIID/.rein/policy/security-axis/" 2>/dev/null || true
  chmod 000 "$PROJECT_XIIID/.rein/policy"
  out_xiiid=$(_run_mark "$PLUGIN_XIIID" "$PROJECT_XIIID" --print-subject 2>&1)
  rc_xiiid=$?
  chmod 755 "$PROJECT_XIIID/.rein/policy"
  if [ "$rc_xiiid" -ne 0 ]; then
    pass "--print-subject fails closed when the policy parent folder is unsearchable"
  else
    fail "--print-subject fails closed when the policy parent folder is unsearchable" "got rc=0, output: $out_xiiid"
  fi
fi

if printf '%s' "$out_xiiib" | grep -qi "git"; then
  fail "the damaged-folder error must not point the user at git" "output: $out_xiiib"
else
  pass "the damaged-folder error does not mention git"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-mark-security-reviewed: $PASS PASS"
  exit 0
else
  echo "test-mark-security-reviewed: $FAIL FAIL / $((PASS + FAIL)) total"
  exit 1
fi
