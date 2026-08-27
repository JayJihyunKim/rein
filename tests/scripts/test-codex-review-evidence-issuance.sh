#!/usr/bin/env bash
# tests/scripts/test-codex-review-evidence-issuance.sh
#
# Phase 7 웨이브 3 ③-a — plugins/rein-core/scripts/rein-codex-review.sh 의
# v2 evidence 발급 배선 behavioral regression. 자매 스위트
# tests/scripts/test-mark-security-reviewed.sh 와 동일한 fake bin/rein
# 스텁 패턴을 code_review capability 에 적용한다 — 그 서브커맨드
# (`bin/rein issue-evidence`)는 별도 워커가 이 사이클과 병렬로 구현 중이라
# 이 worktree 에는 아직 실물이 없다. 이 스위트는 인터페이스 계약만으로
# 래퍼의 세 분기(캡처 성공 → 발급 시도 / 발급 거부(exit 2) → non-fatal /
# 캡처 실패 → 발급 스킵)를 격리 검증한다. 실제 bin/rein 구현이 착륙한
# 뒤에도 이 스텁 기반 테스트는 계약 준수를 계속 잠근다.
#
# 무대 — tests/skills/test-codex-review-wrapper.sh 의
# test_wrapper_plugin_layout_user_repo_without_claude_dir_uses_bundled_lib
# 와 동일 원리 (plugin 레이아웃(scripts/+hooks/lib/ 형제) + user repo 분리):
#   <plugin_root>/scripts/rein-codex-review.sh — 실제 스크립트 사본
#     (self-location 이 이 fixture 를 가리키므로 bin/rein 도
#     <plugin_root>/bin/rein 으로 해석된다)
#   <plugin_root>/hooks/lib/{select-active-dod,path-containment}.sh
#   <plugin_root>/bin/rein — fake 스텁
#   <repo_root> — 최소 git + Tier 1 DoD/plan/design 시드 (user repo)
#
# behavioral (subprocess) 전용 — source 하지 않는다 (저장소 규율: source
# 테스트는 false-green 위험, tests/skills/test-codex-review-wrapper.sh 헤더
# 참조).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER_SRC="$PROJECT_ROOT/plugins/rein-core/scripts/rein-codex-review.sh"
SAD_SRC="$PROJECT_ROOT/plugins/rein-core/hooks/lib/select-active-dod.sh"
PATHCONTAIN_SRC="$PROJECT_ROOT/plugins/rein-core/hooks/lib/path-containment.sh"
FAKE_CODEX="$PROJECT_ROOT/tests/fixtures/fake-codex.sh"

PASS=0
FAIL=0

BASE_TMP=$(mktemp -d "/tmp/codex-review-evidence-XXXXXX")
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

echo "=== test-codex-review-evidence-issuance ==="

if [ ! -f "$WRAPPER_SRC" ]; then
  echo "FAIL: $WRAPPER_SRC missing" >&2
  exit 1
fi
if [ ! -f "$FAKE_CODEX" ]; then
  echo "FAIL: $FAKE_CODEX missing" >&2
  exit 1
fi

bash -n "$WRAPPER_SRC"
if [ $? -eq 0 ]; then
  pass "rein-codex-review.sh passes bash -n"
else
  fail "rein-codex-review.sh fails bash -n"
fi

# --- Fixture plugin root -----------------------------------------------
# <root>/scripts/rein-codex-review.sh (real wrapper, self-location resolves
# bin/rein to <root>/bin/rein) + <root>/hooks/lib/ (select-active-dod +
# path-containment, the wrapper's plugin-layout dependency) + <root>/bin/rein
# (fake stub).
_mk_fixture_plugin() {
  local root
  root=$(mktemp -d "$BASE_TMP/plugin-XXXXXX")
  mkdir -p "$root/scripts" "$root/hooks/lib" "$root/bin"
  cp "$WRAPPER_SRC" "$root/scripts/rein-codex-review.sh"
  chmod +x "$root/scripts/rein-codex-review.sh"
  cp "$SAD_SRC" "$root/hooks/lib/select-active-dod.sh"
  cp "$PATHCONTAIN_SRC" "$root/hooks/lib/path-containment.sh" 2>/dev/null || true
  cat > "$root/bin/rein" <<'PYEOF'
#!/usr/bin/env python3
# Fake bin/rein stub for test-codex-review-evidence-issuance.sh — implements
# just enough of the `issue-evidence` interface contract to drive the
# caller's branches. Mirrors tests/scripts/test-mark-security-reviewed.sh's
# stub (same FAKE_REIN_* env-var control scheme) for the code_review
# capability. Behavior is controlled entirely via env vars the test sets, so
# one stub file serves every scenario.
import json
import os
import sys


def main():
    argv = sys.argv[1:]
    if len(argv) < 2 or argv[0] != "issue-evidence" or argv[1] != "code_review":
        sys.stderr.write("fake-bin-rein: unsupported invocation: %r\n" % (argv,))
        return 2
    rest = argv[2:]

    record_path = os.environ.get("FAKE_REIN_RECORD", "")

    if "--print-subject" in rest:
        # 2026-08-20 code review round 3 refinement (High-1): the wrapper
        # now fetches subject digest + certified paths in ONE call instead
        # of two separate --print-digest / --print-subject-paths calls
        # (which could disagree if the tree changed between them). This
        # stub keeps the same env-var control surface (FAKE_REIN_DIGEST/
        # FAKE_REIN_DIGEST_RC drive the subject + the single rc,
        # FAKE_REIN_SUBJECT_PATHS drives the paths list) and just combines
        # them into the one-line JSON contract the wrapper now parses.
        #
        # FAKE_REIN_SUBJECT_JSON (round 4, High-1 regression): when set,
        # this is written to stdout VERBATIM instead of being assembled
        # from FAKE_REIN_DIGEST/FAKE_REIN_SUBJECT_PATHS — the latter joins
        # paths on "\n" (test-harness convenience), which cannot itself
        # represent a path whose VALUE contains a real newline character.
        # A raw JSON override lets a test inject a `paths` entry like
        # "dir_line\nbreak.py" (a JSON-escaped newline — i.e. a single,
        # valid, single-line JSON payload whose decoded string value
        # contains an embedded newline byte) without needing a real
        # newline-named file on disk in a bash test harness.
        raw_json = os.environ.get("FAKE_REIN_SUBJECT_JSON", "")
        if raw_json:
            sys.stdout.write(raw_json)
            if not raw_json.endswith("\n"):
                sys.stdout.write("\n")
            return int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        subject = os.environ.get("FAKE_REIN_DIGEST", "")
        rc = int(os.environ.get("FAKE_REIN_DIGEST_RC", "0"))
        paths_raw = os.environ.get("FAKE_REIN_SUBJECT_PATHS", "")
        paths = [p for p in paths_raw.split("\n") if p]
        if rc == 0 and subject:
            sys.stdout.write(json.dumps({"subject": subject, "paths": paths}) + "\n")
        return rc

    if "--verdict" in rest:
        if record_path:
            with open(record_path, "a") as f:
                f.write(" ".join(rest) + "\n")
        rc = int(os.environ.get("FAKE_REIN_ISSUE_RC", "0"))
        # FAKE_REIN_ISSUE_STDOUT_RAW (round 4, High-2 regression): when
        # set, this is written to stdout VERBATIM instead of
        # FAKE_REIN_ISSUE_JSON — lets a test simulate a genuinely
        # unparseable (non-JSON) exit-2 response, which the real
        # `bin/rein` never emits on its own JSON-only interface but which
        # this stub must be able to model to exercise the wrapper's
        # fail-closed handling of an unparseable refusal.
        raw_stdout = os.environ.get("FAKE_REIN_ISSUE_STDOUT_RAW", "")
        if raw_stdout:
            sys.stdout.write(raw_stdout)
            if not raw_stdout.endswith("\n"):
                sys.stdout.write("\n")
            return rc
        payload = os.environ.get("FAKE_REIN_ISSUE_JSON", '{"issued": true}')
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

# --- Fixture user repo ---------------------------------------------------
# git init + minimal design/plan/DoD (Tier 1 marker) so the wrapper's
# active-DoD selector + self-verification gate pass cleanly (mirrors
# tests/skills/test-codex-review-wrapper.sh's plugin-layout regression
# fixture).
_mk_fixture_repo() {
  local root
  root=$(mktemp -d "$BASE_TMP/repo-XXXXXX")
  mkdir -p "$root/trail/dod" "$root/docs/specs" "$root/docs/plans"
  ( cd "$root" && git init -q && git config user.email t@example.com \
    && git config user.name t && git commit --allow-empty -q -m init )
  {
    echo "# Design"; echo ""; echo "## Scope Items"; echo ""
    echo "| ID | 설명 |"; echo "|----|------|"; echo "| E1 | evidence issuance fixture |"
  } > "$root/docs/specs/evidence-design.md"
  {
    echo "# Plan"; echo ""; echo "## Design 범위 커버리지 매트릭스"; echo ""
    echo "> design ref: docs/specs/evidence-design.md"; echo ""
    echo "| Scope ID | 상태 | 위치/사유 |"; echo "|----------|------|----------|"
    echo "| E1 | implemented | Phase 1 |"; echo ""
    echo "## Phase 1"; echo "covers: [E1]"
  } > "$root/docs/plans/evidence-plan.md"
  {
    echo "# DoD"; echo ""; echo "## 범위 연결"; echo ""
    echo "plan ref: docs/plans/evidence-plan.md"
    echo "work unit: Phase 1"; echo "covers: [E1]"
  } > "$root/trail/dod/dod-2026-08-20-evidence.md"
  echo "path=trail/dod/dod-2026-08-20-evidence.md" > "$root/trail/dod/.active-dod"
  echo "$root"
}

# _run_wrapper <plugin_root> <repo_root> [capture_file]
#   Invokes the fixture wrapper in non-interactive code-review mode with the
#   self-verification-gate markers (verification_commands: none +
#   diff_self_review:) FAKE_CODEX defaults to a PASS verdict. Sets globals
#   RUN_RC / RUN_OUT / RUN_ERR — stdout and stderr are captured to separate
#   files so JSON/NOTICE assertions target the right stream. Optional third
#   arg wires FAKE_CODEX_CAPTURE so the assembled envelope (what codex
#   actually received) can be inspected — used by the untracked-only case
#   below to assert the changed_files slot content/label.
_run_wrapper() {
  local plugin_root="$1" repo_root="$2" capture_file="${3:-}"
  local stdin_file out_file err_file rc
  stdin_file=$(mktemp "$BASE_TMP/stdin-XXXXXX")
  out_file=$(mktemp "$BASE_TMP/out-XXXXXX")
  err_file=$(mktemp "$BASE_TMP/err-XXXXXX")
  printf 'code review please\nverification_commands: none\ndiff_self_review: harness fixture pass\n' \
    > "$stdin_file"
  (
    cd "$repo_root"
    export CODEX_BIN="$FAKE_CODEX"
    export CLAUDE_PROJECT_DIR="$repo_root"
    if [ -n "$capture_file" ]; then
      export FAKE_CODEX_CAPTURE="$capture_file"
    fi
    bash "$plugin_root/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > "$out_file" 2> "$err_file"
  )
  rc=$?
  RUN_RC="$rc"
  RUN_OUT="$(cat "$out_file")"
  RUN_ERR="$(cat "$err_file")"
  rm -f "$stdin_file" "$out_file" "$err_file"
}

# ----------------------------------------------------------------------------
# (i) PASS path captures the digest at review start and issues it
# ----------------------------------------------------------------------------
echo ""
echo "[i] PASS path captures digest at review start and issues it"

PLUGIN_I=$(_mk_fixture_plugin)
REPO_I=$(_mk_fixture_repo)
RECORD_I="$REPO_I/issue-record.log"

FAKE_REIN_DIGEST="sha256:reviewed-i" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_ISSUE_RC=0 \
  FAKE_REIN_ISSUE_JSON='{"issued": true, "id": "ev-i"}' \
  FAKE_REIN_RECORD="$RECORD_I" \
  _run_wrapper "$PLUGIN_I" "$REPO_I"

assert_equal "wrapper exits 0 on PASS" "0" "$RUN_RC"

# Phase 7 웨이브 3 ③-d: 래퍼는 더 이상 trail/dod/.codex-reviewed legacy
# stamp 를 쓰지 않는다 — v2 발급이 유일한 기록 경로다. 아래 두 확인
# (RECORD_I 로 발급 호출 자체를 관측 + stderr NOTICE) 이 "PASS 시 기록됨"
# 을 이미 완전히 규명한다.
if [ -f "$RECORD_I" ] && grep -q -- "--reviewed-digest sha256:reviewed-i" "$RECORD_I"; then
  pass "issuance invoked with the digest captured at review start"
else
  fail "issuance invoked with the digest captured at review start" \
    "record file: $(cat "$RECORD_I" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$RUN_ERR" | grep -q "NOTICE: \[codex-review\] v2 evidence recorded"; then
  pass "stderr confirms v2 evidence recorded"
else
  fail "stderr confirms v2 evidence recorded" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (ii-a) issuance refusal reason=digest-mismatch — Phase 7 웨이브 3 ③-d
# 갱신: 레거시 stamp 시절엔 이 결과가 non-fatal 이었고(표식은 이미 확정
# 기록됐고, .review-pending 재생성이 안전망이었다) — 지금은 레거시 표식
# write/read 경로 전체가 제거됐으므로, 이 회차는 문자 그대로 아무것도
# 기록하지 못한다. 그래서 severity 가 WARNING → **ERROR** 로 격상됐고
# (rein-codex-review.sh 의 "Elevated to ERROR (was WARNING pre-③-d)" 주석
# 참조), .review-pending 재생성 안전망도 소멸했다 — digest 결속 자체가
# 이제 안전장치이므로 별도 재생성이 불필요해졌다.
# ----------------------------------------------------------------------------
echo ""
echo "[ii-a] issuance refusal reason=digest-mismatch -> ERROR (exit still 0, nothing recorded)"

PLUGIN_IIA=$(_mk_fixture_plugin)
REPO_IIA=$(_mk_fixture_repo)
RECORD_IIA="$REPO_IIA/issue-record.log"

FAKE_REIN_DIGEST="sha256:reviewed-iia" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_ISSUE_RC=2 \
  FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "digest-mismatch"}' \
  FAKE_REIN_RECORD="$RECORD_IIA" \
  _run_wrapper "$PLUGIN_IIA" "$REPO_IIA"

# 래퍼 자신의 exit code 는 여전히 0 이다 — codex 리뷰 실행 자체(verdict 판정)
# 는 성공했고, "기록" 이라는 별도 관심사의 실패는 wrapper exit code 에
# 반영되지 않는다(write_code_review_stamp() 가 `return 0` 하는 이유,
# rein-codex-review.sh 자신의 주석 참조).
assert_equal "wrapper still exits 0 despite digest-mismatch refusal" "0" "$RUN_RC"

if [ -f "$RECORD_IIA" ] && grep -q -- "--reviewed-digest sha256:reviewed-iia" "$RECORD_IIA"; then
  pass "issuance was attempted (and recorded) before being refused"
else
  fail "issuance was attempted (and recorded) before being refused" \
    "record file: $(cat "$RECORD_IIA" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$RUN_ERR" | grep -q "ERROR: \[codex-review\] v2 evidence issuance refused — reason: digest-mismatch"; then
  pass "stderr carries an ERROR (not the old non-fatal WARNING) for digest-mismatch refusal"
else
  fail "stderr carries an ERROR (not the old non-fatal WARNING) for digest-mismatch refusal" "stderr: $RUN_ERR"
fi

if printf '%s' "$RUN_ERR" | grep -q "nothing was recorded this cycle; re-review the current tree"; then
  pass "ERROR states nothing was recorded and a re-review is needed"
else
  fail "ERROR states nothing was recorded and a re-review is needed" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (ii-b) issuance refusal for a DIFFERENT reason (e.g. malformed) stays a
# WARNING (not elevated to ERROR like digest-mismatch — this is an
# issuance-machinery condition, not evidence the reviewed tree changed).
# Phase 7 웨이브 3 ③-d: 레거시 표식 자체가 사라졌으므로 "재생성하지 않음"
# 검사는 더 이상 아무것도 구분하지 못한다 — 대신 "기록되지 않았다"는
# 사실이 WARNING 문구에 명시됐는지를 확인한다.
# ----------------------------------------------------------------------------
echo ""
echo "[ii-b] issuance refusal reason=malformed stays WARNING (nothing recorded)"

PLUGIN_IIB=$(_mk_fixture_plugin)
REPO_IIB=$(_mk_fixture_repo)
RECORD_IIB="$REPO_IIB/issue-record.log"

FAKE_REIN_DIGEST="sha256:reviewed-iib" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_ISSUE_RC=2 \
  FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "malformed"}' \
  FAKE_REIN_RECORD="$RECORD_IIB" \
  _run_wrapper "$PLUGIN_IIB" "$REPO_IIB"

assert_equal "wrapper still exits 0 despite malformed-reason refusal" "0" "$RUN_RC"

if [ -f "$RECORD_IIB" ] && grep -q -- "--reviewed-digest sha256:reviewed-iib" "$RECORD_IIB"; then
  pass "issuance was attempted (and recorded) before being refused"
else
  fail "issuance was attempted (and recorded) before being refused" \
    "record file: $(cat "$RECORD_IIB" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$RUN_ERR" | grep -q "WARNING: \[codex-review\] v2 evidence issuance refused"; then
  pass "stderr carries a WARNING (not ERROR — machinery refusal, not a tree change) for malformed-reason refusal"
else
  fail "stderr carries a WARNING (not ERROR — machinery refusal, not a tree change) for malformed-reason refusal" "stderr: $RUN_ERR"
fi

if printf '%s' "$RUN_ERR" | grep -q "reason: malformed"; then
  pass "WARNING quotes the JSON reason field (malformed)"
else
  fail "WARNING quotes the JSON reason field (malformed)" "stderr: $RUN_ERR"
fi

if printf '%s' "$RUN_ERR" | grep -q "Nothing was recorded this cycle"; then
  pass "WARNING states nothing was recorded this cycle (no legacy stamp fallback left)"
else
  fail "WARNING states nothing was recorded this cycle (no legacy stamp fallback left)" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (iii) subject-snapshot fetch failure skips issuance entirely — ERROR,
# nothing recorded (fix 1 High-1 / fix 5a regression: the combined
# `--print-subject` call now fetches subject digest + certified paths
# atomically; a failure here is the SINGLE failure point for both, so
# issuance must never be attempted — verify that invariant explicitly
# below. Phase 7 웨이브 3 ③-d: this used to be non-fatal because the
# legacy stamp still got written; now it means the cycle recorded nothing).
# ----------------------------------------------------------------------------
echo ""
echo "[iii] subject-snapshot fetch failure skips issuance, ERROR (nothing recorded)"

PLUGIN_III=$(_mk_fixture_plugin)
REPO_III=$(_mk_fixture_repo)
RECORD_III="$REPO_III/issue-record.log"

FAKE_REIN_DIGEST_RC=1 \
  FAKE_REIN_RECORD="$RECORD_III" \
  _run_wrapper "$PLUGIN_III" "$REPO_III"

assert_equal "wrapper exits 0 despite subject-snapshot fetch failure" "0" "$RUN_RC"

# Phase 7 웨이브 3 ③-d: 래퍼는 더 이상 trail/dod/.codex-reviewed legacy
# stamp 를 쓰지 않는다 — PASS 판정이라 write_code_review_stamp() 는
# 호출되지만, 캡처 실패로 REIN_REVIEWED_DIGEST 가 빈 값이므로 발급을
# 시도조차 하지 않고 ERROR 만 남긴다(아래 RECORD_III 부재 확인이 발급
# 미시도를 이미 증명한다).
if printf '%s' "$RUN_ERR" | grep -q "no review-start subject digest was captured"; then
  pass "stderr carries the write_code_review_stamp ERROR (no digest to bind evidence to)"
else
  fail "stderr carries the write_code_review_stamp ERROR (no digest to bind evidence to)" "stderr: $RUN_ERR"
fi

if [ -f "$RECORD_III" ]; then
  fail "issuance NOT attempted when subject-snapshot fetch fails (PASS path must not attempt issuance)" \
    "unexpected record: $(cat "$RECORD_III")"
else
  pass "issuance NOT attempted when subject-snapshot fetch fails (PASS path must not attempt issuance)"
fi

if printf '%s' "$RUN_ERR" | grep -q "NOTICE: \[codex-review\] v2 certified review-subject snapshot unavailable"; then
  pass "stderr carries a NOTICE for subject-snapshot fetch failure"
else
  fail "stderr carries a NOTICE for subject-snapshot fetch failure" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (iv, bonus) bin/rein entirely absent (older/un-migrated install) — same
# degrade as (iii), exercising the "no candidate found" branch instead of a
# non-zero exit from an existing binary.
# ----------------------------------------------------------------------------
echo ""
echo "[iv, bonus] missing bin/rein entirely also skips issuance, ERROR (nothing recorded)"

PLUGIN_IV=$(_mk_fixture_plugin)
rm -f "$PLUGIN_IV/bin/rein"
REPO_IV=$(_mk_fixture_repo)

_run_wrapper "$PLUGIN_IV" "$REPO_IV"

assert_equal "wrapper exits 0 when bin/rein is entirely absent" "0" "$RUN_RC"

# Phase 7 웨이브 3 ③-d: 동일 원리 — legacy stamp 는 쓰이지 않는다.
# write_code_review_stamp() 는 여전히 호출되지만(PASS 판정), 캡처 실패로
# digest 가 없어 발급을 시도하지 않고 ERROR 만 남긴다.
if printf '%s' "$RUN_ERR" | grep -q "no review-start subject digest was captured"; then
  pass "stderr carries the write_code_review_stamp ERROR when bin/rein is absent"
else
  fail "stderr carries the write_code_review_stamp ERROR when bin/rein is absent" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (v) untracked-only CODE change resolves to working_tree mode (not
# commit_range), and the untracked file appears in the collected changed_files
# set (High finding, code review round 2 — "review subject must cover what
# the digest certifies"). Before the fix, _changed_files/_resolve_review_
# subject only unioned staged+unstaged: an untracked-only changeset looked
# like a CLEAN working tree, so the wrapper degraded to commit_range mode and
# the reviewer never saw the untracked file (and never saw ANY diff, since
# the fixture's only commit is an empty one) even though changeset.
# review_digest already certifies untracked files.
#
# 2026-08-20 refinement: the wrapper no longer unions in ALL untracked files
# (that regressed the golden wrapper suite's seeded untracked docs and had a
# real false-positive-mode risk — see case (vi) below). It now asks
# `bin/rein issue-evidence code_review --print-subject` for the
# certified (allowlist-filtered) set, so this fixture's fake bin/rein must
# report the untracked code file via FAKE_REIN_SUBJECT_PATHS for the wrapper
# to see it as "certified".
# ----------------------------------------------------------------------------
echo ""
echo "[v] untracked-only CODE change is treated as working_tree (not commit_range)"

PLUGIN_V=$(_mk_fixture_plugin)
REPO_V=$(_mk_fixture_repo)
CAPTURE_V="$BASE_TMP/capture-v.txt"

# An untracked (never `git add`-ed) code file — the working tree has no
# staged/unstaged changes to any TRACKED file, only this new untracked one
# (plus the fixture's own untracked seed docs, which are review-exemption
# allowlisted — under docs/**/trail/** — and irrelevant to this assertion).
echo 'def handler(): return 1' > "$REPO_V/untracked_handler.py"

FAKE_REIN_DIGEST="sha256:reviewed-v" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_SUBJECT_PATHS="untracked_handler.py" \
  FAKE_REIN_ISSUE_RC=0 \
  FAKE_REIN_ISSUE_JSON='{"issued": true, "id": "ev-v"}' \
  _run_wrapper "$PLUGIN_V" "$REPO_V" "$CAPTURE_V"

assert_equal "wrapper exits 0 for an untracked-only code change" "0" "$RUN_RC"

if [ -f "$CAPTURE_V" ]; then
  pass "fake-codex captured the envelope"

  if grep -qE "^changed_files \(working tree" "$CAPTURE_V"; then
    pass "untracked-only change resolves to working_tree mode (not commit_range)"
  else
    fail "untracked-only change resolves to working_tree mode (not commit_range)" \
      "changed_files label: $(grep '^changed_files' "$CAPTURE_V" 2>/dev/null || echo '<absent>')"
  fi

  if grep -qE "^changed_files \(.*\.\.HEAD\):" "$CAPTURE_V"; then
    fail "untracked-only change must NOT degrade to the committed-range (..HEAD) label" \
      "$(grep '^changed_files' "$CAPTURE_V")"
  else
    pass "untracked-only change does not show the committed-range (..HEAD) label"
  fi

  if grep -qF "untracked_handler.py" "$CAPTURE_V"; then
    pass "the untracked file appears in the collected changed_files set"
  else
    fail "the untracked file appears in the collected changed_files set" \
      "envelope did not mention untracked_handler.py"
  fi
else
  fail "fake-codex captured the envelope" "missing: $CAPTURE_V"
fi

# ----------------------------------------------------------------------------
# (vi) untracked ALLOWLISTED-only changes must NOT flip an otherwise-clean
# tree into working_tree mode (2026-08-20 refinement — this is exactly the
# regression the "union in ALL untracked files, unfiltered" fix introduced:
# a stray untracked operational note, e.g. `trail/incidents/*.md`, would
# flip a clean post-commit review into working_tree mode and the reviewer
# would only ever see the note). The fixture repo's own seed files
# (docs/specs/*.md, docs/plans/*.md, trail/dod/*) are already untracked and
# already allowlisted — no extra file needed to exercise this: with the fake
# bin/rein reporting an EMPTY certified-path set (the correct answer for an
# allowlist-only tree), the wrapper must degrade to commit_range.
# ----------------------------------------------------------------------------
echo ""
echo "[vi] untracked allowlisted-only files do NOT flip a clean tree to working_tree"

PLUGIN_VI=$(_mk_fixture_plugin)
REPO_VI=$(_mk_fixture_repo)
CAPTURE_VI="$BASE_TMP/capture-vi.txt"

# Extra stray allowlisted untracked note, on top of the fixture's own seed
# docs — belt-and-suspenders so this case does not depend solely on the
# fixture helper's internal file set.
mkdir -p "$REPO_VI/trail/incidents"
echo "stray incident note" > "$REPO_VI/trail/incidents/stray-note.md"

# FAKE_REIN_DIGEST is the real `empty:no-subject` sentinel (rein.kernel.
# changeset.SUBJECT_EMPTY) — what a real `--print-subject` call actually
# returns for an allowlist-only tree — rather than an unset/blank value;
# the combined stub treats "" as a fetch failure (see _mk_fixture_plugin's
# stub), so this fixture must use the real sentinel string to correctly
# exercise "fetch succeeded, subject is the empty sentinel, paths is empty"
# rather than "fetch failed".
FAKE_REIN_DIGEST="empty:no-subject" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_SUBJECT_PATHS="" \
  _run_wrapper "$PLUGIN_VI" "$REPO_VI" "$CAPTURE_VI"

assert_equal "wrapper exits 0 for an allowlisted-only untracked tree" "0" "$RUN_RC"

if [ -f "$CAPTURE_VI" ]; then
  pass "fake-codex captured the envelope"

  if grep -qE "^changed_files \(working tree" "$CAPTURE_VI"; then
    fail "allowlisted-only untracked files must NOT flip the tree to working_tree mode" \
      "changed_files label: $(grep '^changed_files' "$CAPTURE_VI")"
  else
    pass "allowlisted-only untracked files leave the tree in commit_range mode"
  fi

  if grep -qE "^changed_files \(.*\.\.HEAD\):" "$CAPTURE_VI"; then
    pass "allowlisted-only untracked tree shows the committed-range (..HEAD) label"
  else
    fail "allowlisted-only untracked tree shows the committed-range (..HEAD) label" \
      "changed_files label: $(grep '^changed_files' "$CAPTURE_VI" 2>/dev/null || echo '<absent>')"
  fi

  if grep -qF "stray-note.md" "$CAPTURE_VI"; then
    fail "the allowlisted stray note must not appear in the collected changed_files set" \
      "$(grep '^changed_files' -A2 "$CAPTURE_VI" 2>/dev/null)"
  else
    pass "the allowlisted stray note does not appear in the collected changed_files set"
  fi
else
  fail "fake-codex captured the envelope" "missing: $CAPTURE_VI"
fi

# ----------------------------------------------------------------------------
# (vii) a certified path containing a newline (JSON-escaped in the fake
# bin/rein response) must be treated as ONE entry by the wrapper's
# collection — not silently split into two paths (Phase 7 wave 3 ③-a code
# review round 4, High-1). git allows newline-containing filenames and
# `review_subject_paths()` returns them raw; the wrapper's NUL-safe
# consumption reads the certified path list from a NUL-delimited temp file
# and escapes any embedded newline in a path to a literal `\n` (two-char
# backslash-n) before it enters the newline-per-entry changed_files
# display — so the captured envelope's changed_files section must show
# exactly ONE line containing that literal escape, never two separate
# lines (the pre-fix `head`/`tail` newline parsing would have split this
# into "dir_line" and "break.py" as two separate collected paths).
#
# This case also covers round 5's High finding: the render was not
# INJECTIVE. A file literally named `dir_line\nbreak.py` (a two-char
# backslash-n IN THE FILENAME, no real newline) and a file named
# `dir_line<LF>break.py` (a real embedded newline) both used to render as
# the identical string `dir_line\nbreak.py`, because the old
# `${p//$'\n'/\\n}` substitution escaped the real LF to a literal `\n`
# WITHOUT first escaping any backslash already present in the literal-name
# case — so the two distinct certified paths collapsed to one line and the
# downstream `awk '!seen[$0]++'` dedup silently merged them (digest ⊇ 2
# paths, displayed set = 1). The fix escapes backslash FIRST (`\` → `\\`),
# then LF → `\n` (JSON-string-style order): the real-LF path renders as
# `dir_line\nbreak.py` (ONE backslash) while the literal-backslash-n path
# renders as `dir_line\\nbreak.py` (TWO backslashes) — always
# distinguishable, so both this test's paths below (a real-LF path AND a
# literal-backslash-n path, requested together in the same certified-paths
# response) must survive dedup as TWO distinct lines.
# ----------------------------------------------------------------------------
echo ""
echo "[vii] a newline-containing certified path is treated as ONE entry (not split), and a real-LF path never collides with a literal-backslash-n path"

PLUGIN_VII=$(_mk_fixture_plugin)
REPO_VII=$(_mk_fixture_repo)
CAPTURE_VII="$BASE_TMP/capture-vii.txt"

# paths[0] = "dir_line\nbreak.py" as JSON text -> `\n` is a JSON escape ->
#            decodes to a REAL embedded newline byte.
# paths[1] = "dir_line\\nbreak.py" as JSON text -> `\\` is a JSON escape for
#            a single literal backslash, followed by literal `n` -> decodes
#            to a filename that literally contains the two characters
#            backslash + n (no newline byte at all). Bash single-quotes
#            below pass both sequences through to the JSON payload
#            verbatim, so what python's json.loads sees is exactly the
#            JSON text quoted in this comment.
FAKE_REIN_SUBJECT_JSON='{"subject": "sha256:reviewed-vii", "paths": ["dir_line\nbreak.py", "dir_line\\nbreak.py"]}' \
  FAKE_REIN_ISSUE_RC=0 \
  FAKE_REIN_ISSUE_JSON='{"issued": true, "id": "ev-vii"}' \
  _run_wrapper "$PLUGIN_VII" "$REPO_VII" "$CAPTURE_VII"

assert_equal "wrapper exits 0 for a newline-containing certified path" "0" "$RUN_RC"

if [ -f "$CAPTURE_VII" ]; then
  pass "fake-codex captured the envelope"

  # Extract just the changed_files section body (between the label line
  # and the next blank line) so the line-count check below is not
  # confused by unrelated envelope content.
  cf_body_vii=$(awk '/^changed_files \(/{found=1; next} found && /^$/{exit} found{print}' "$CAPTURE_VII")

  if printf '%s\n' "$cf_body_vii" | grep -qxF 'dir_line\nbreak.py'; then
    pass "the real-LF path renders as a single-backslash escape (dir_line\\nbreak.py, one backslash)"
  else
    fail "the real-LF path renders as a single-backslash escape (dir_line\\nbreak.py, one backslash)" \
      "changed_files body: $cf_body_vii"
  fi

  if printf '%s\n' "$cf_body_vii" | grep -qxF 'dir_line\\nbreak.py'; then
    pass "the literal-backslash-n path renders as a double-backslash escape (dir_line\\\\nbreak.py, two backslashes)"
  else
    fail "the literal-backslash-n path renders as a double-backslash escape (dir_line\\\\nbreak.py, two backslashes)" \
      "changed_files body: $cf_body_vii"
  fi

  cf_lines_vii=$(printf '%s\n' "$cf_body_vii" | grep -c .)
  assert_equal "changed_files section has exactly TWO lines (real-LF and literal-backslash-n paths both survive dedup, neither split nor merged)" "2" "$cf_lines_vii"

  cf_line1_vii=$(printf '%s\n' "$cf_body_vii" | sed -n '1p')
  cf_line2_vii=$(printf '%s\n' "$cf_body_vii" | sed -n '2p')
  if [ "$cf_line1_vii" != "$cf_line2_vii" ]; then
    pass "the two rendered forms are distinct strings (injective escape — no collision)"
  else
    fail "the two rendered forms are distinct strings (injective escape — no collision)" \
      "both lines rendered identically: $cf_line1_vii"
  fi

  if printf '%s\n' "$cf_body_vii" | grep -qxF 'break.py'; then
    fail "the path must NOT have been split into a separate 'break.py' line" \
      "changed_files body: $cf_body_vii"
  else
    pass "no separate 'break.py' line appears (path was not split)"
  fi
else
  fail "fake-codex captured the envelope" "missing: $CAPTURE_VII"
fi

# ----------------------------------------------------------------------------
# (viii) issuance refusal with an UNPARSEABLE (non-JSON) exit-2 stdout must
# be treated exactly like digest-mismatch — fail-closed (Phase 7 wave 3
# ③-a code review round 4, High-2). ③-d 갱신: 레거시 stamp 시절엔 "fail-
# closed" 가 ".review-pending 재생성" 으로 표현됐지만, 그 표식 자체가
# 사라졌으므로 이제는 severity 격상(ERROR, digest-mismatch 와 동일 취급)
# 으로만 표현된다 — 별도 재생성 안전망이 불필요해졌다(digest 결속 자체가
# 안전장치).
# ----------------------------------------------------------------------------
echo ""
echo "[viii] unparseable (non-JSON) exit-2 response is fail-closed (treated as digest-mismatch)"

PLUGIN_VIII=$(_mk_fixture_plugin)
REPO_VIII=$(_mk_fixture_repo)
RECORD_VIII="$REPO_VIII/issue-record.log"

FAKE_REIN_DIGEST="sha256:reviewed-viii" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_ISSUE_RC=2 \
  FAKE_REIN_ISSUE_STDOUT_RAW='not json at all, garbage output' \
  FAKE_REIN_RECORD="$RECORD_VIII" \
  _run_wrapper "$PLUGIN_VIII" "$REPO_VIII"

assert_equal "wrapper still exits 0 despite an unparseable exit-2 response" "0" "$RUN_RC"

if printf '%s' "$RUN_ERR" | grep -q "ERROR: \[codex-review\] v2 evidence issuance refused (exit 2) but the response could not be positively parsed"; then
  pass "stderr carries an ERROR (fail-closed, same severity as digest-mismatch) for an unparseable exit-2 response"
else
  fail "stderr carries an ERROR (fail-closed, same severity as digest-mismatch) for an unparseable exit-2 response" "stderr: $RUN_ERR"
fi

if printf '%s' "$RUN_ERR" | grep -q "Nothing was recorded this cycle; re-review the current tree"; then
  pass "ERROR states nothing was recorded and a re-review is needed (same as digest-mismatch)"
else
  fail "ERROR states nothing was recorded and a re-review is needed (same as digest-mismatch)" "stderr: $RUN_ERR"
fi

if [ -f "$RECORD_VIII" ] && grep -q -- "--reviewed-digest sha256:reviewed-viii" "$RECORD_VIII"; then
  pass "issuance was attempted (and recorded) before being refused"
else
  fail "issuance was attempted (and recorded) before being refused" \
    "record file: $(cat "$RECORD_VIII" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$RUN_ERR" | grep -q "could not be positively parsed to a reason OTHER than digest-mismatch"; then
  pass "stderr explains the fail-closed treatment of the unparseable response"
else
  fail "stderr explains the fail-closed treatment of the unparseable response" "stderr: $RUN_ERR"
fi

# ----------------------------------------------------------------------------
# (ix) issuance refusal reason=subject-empty is NOT a failure (Phase 7 웨이브
# 3 ③-d 코드리뷰 라운드 1 Medium 시정, rein-codex-review.sh 의
# write_code_review_stamp() subject-empty 분기). 이 사유는 "지금 review
# 대상에 non-exempt 코드가 없다"는 뜻이므로 — spec §3.6 종국 상태표가 이
# 상태를 authority 층에서 직접 satisfied 로 판정해, 증거 레코드 자체가
# 필요 없다. digest-mismatch/malformed 처럼 "재리뷰가 필요하다"는 취지의
# WARNING/ERROR 가 아니라, "이건 정상 상태다"라는 NOTICE 여야 한다.
# ----------------------------------------------------------------------------
echo ""
echo "[ix] issuance refusal reason=subject-empty stays NOTICE (expected, not a failure)"

PLUGIN_IX=$(_mk_fixture_plugin)
REPO_IX=$(_mk_fixture_repo)
RECORD_IX="$REPO_IX/issue-record.log"

FAKE_REIN_DIGEST="sha256:reviewed-ix" \
  FAKE_REIN_DIGEST_RC=0 \
  FAKE_REIN_ISSUE_RC=2 \
  FAKE_REIN_ISSUE_JSON='{"issued": false, "reason": "subject-empty"}' \
  FAKE_REIN_RECORD="$RECORD_IX" \
  _run_wrapper "$PLUGIN_IX" "$REPO_IX"

assert_equal "wrapper still exits 0 for a subject-empty refusal" "0" "$RUN_RC"

if [ -f "$RECORD_IX" ] && grep -q -- "--reviewed-digest sha256:reviewed-ix" "$RECORD_IX"; then
  pass "issuance was attempted (and recorded) before being refused as subject-empty"
else
  fail "issuance was attempted (and recorded) before being refused as subject-empty" \
    "record file: $(cat "$RECORD_IX" 2>/dev/null || echo '<absent>')"
fi

if printf '%s' "$RUN_ERR" | grep -q "NOTICE: \[codex-review\] no v2 evidence was issued because there is nothing non-exempt to bind it to"; then
  pass "stderr carries a NOTICE (expected/satisfied state) for subject-empty refusal"
else
  fail "stderr carries a NOTICE (expected/satisfied state) for subject-empty refusal" "stderr: $RUN_ERR"
fi

if printf '%s' "$RUN_ERR" | grep -q "ERROR: \[codex-review\]"; then
  fail "subject-empty must NOT be reported as an ERROR (that severity is reserved for digest-mismatch/unparseable)" "stderr: $RUN_ERR"
else
  pass "no ERROR line present for subject-empty refusal"
fi

if printf '%s' "$RUN_ERR" | grep -q "WARNING: \[codex-review\] v2 evidence issuance refused"; then
  fail "subject-empty must NOT be reported as an issuance-refusal WARNING (that severity is reserved for other machinery refusals, e.g. malformed)" "stderr: $RUN_ERR"
else
  pass "no issuance-refusal WARNING line present for subject-empty refusal"
fi

if printf '%s' "$RUN_ERR" | grep -qi "re-review"; then
  fail "subject-empty NOTICE must not carry re-review-needed phrasing (it is a satisfied state, not a pending one)" "stderr: $RUN_ERR"
else
  pass "no 're-review needed' phrasing present for subject-empty refusal"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-codex-review-evidence-issuance: $PASS PASS"
  exit 0
else
  echo "test-codex-review-evidence-issuance: $FAIL FAIL / $((PASS + FAIL)) total"
  exit 1
fi
