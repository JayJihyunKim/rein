#!/bin/bash
# tests/integration/test-governance-e2e.sh
#
# Plan A Phase 8 Task 8.1 end-to-end integration test for the governance
# integrity trio (validator v2 + pre-edit-discipline-gate + the commit gate
# chain (pre-bash-commit-discipline-gate.sh → pre-bash-commit-review-gate.sh,
# ③-c successors of the deleted pre-bash-test-commit-gate.sh) + codex-review
# wrapper + govcheck).
#
# Phase 7 웨이브 3 ③-b (편집 게이트 교대, 2026-08-21): pre-edit-dod-gate.sh 는
# 삭제되고 pre-edit-discipline-gate.sh + pre-edit-task-gate.sh 로 교대된다. 이
# 파일의 모든 시나리오는 거버넌스 훼손 / 라우팅 / 사건 검토 / 스펙 리뷰 축만
# 다룬다 — discipline-gate 의 관할이다.
#
# 2026-08-23 갱신 (③-b 순차 디스패처, code review round 6 High 수리):
# run_pre_edit_gate() 는 이제 discipline-gate + coverage-gate 를 각각
# 개별 실행해 이 스위트 자신이 "deny wins" 를 손으로 OR-병합하던 방식을
# 버리고, 실제 프로덕션 진입점인 pre-edit-dispatcher.sh 하나만 호출한다
# — 그 디스패처가 discipline-gate → task-gate → coverage-gate 를 순서를
# 보장해 순차 실행하고 첫 차단에서 즉시 중단한다(그 훅 자신의 헤더 참조).
# 이 교체로 task-gate(활성작업 축)가 이 스위트의 실행 경로에 새로 끼게
# 됐다 — 프로덕션 배선과 동일하게 만들려면 피할 수 없다. task-gate 가
# "전환 상태 읽기 실패 → fail-closed exit 2" 로 모든 시나리오(happy path
# 포함)를 오염시키지 않도록, 이 스위트는 실제 rein 패키지를 링크하되
# `.rein/policy/authority.yaml` 에서 active_task 를 전환 대상에서 제외한다
# (문서화된 opt-out — pre-edit-task-gate.sh 자신의 헤더 판정 트리 참조).
# 이렇게 하면 task-gate 는 이 스위트의 모든 시나리오에서 NOT_SWITCHED 판정
# 으로 조용히 exit 0 하고 v2 위임 자체를 시도하지 않는다 — 이전 버전이
# "task-gate 를 조합에서 아예 빼서" 달성하던 것과 동일한 효과를, 이제는
# 실제 프로덕션 배선(디스패처가 항상 세 자식을 전부 호출) 위에서 얻는다.
# 활성작업 축 자체의 실제 v2 위임 동작(전환 on + DENY/ALLOW/FAIL)은
# tests/hooks/test-active-task-authority-switch.sh + tests/hooks/
# test-pre-edit-task-gate.sh + tests/hooks/test-pre-edit-dispatcher.sh 가
# 전담한다 — 이 스위트에서는 그 축을 의도적으로 비활성 상태로 고정한다.
#
# Scope IDs covered (regression):
#   - GI-validator-v2-parser-single-source
#   - GI-codex-review-wrapper-script
#
# Scenarios (plan Task 8.1):
#   1. Happy path — design + plan + DoD all align → edit passes, commit passes.
#   2. DoD unknown-covers-ID + Tier 1 marker → pre-edit-discipline-gate exits 2 +
#      .dod-coverage-mismatch created → pre-bash-commit-discipline-gate.sh
#      (③-c successor) blocks commit.
#   3. Governance stage corruption → pre-edit-discipline-gate blocks.
#   4. codex-review wrapper emits envelope with diff_base (fake codex).
#   5. govcheck smoke — running it in a sandbox with a fake broken ref
#      returns exit 2, restoring the ref returns exit 0.
#
# Each scenario uses an isolated sandbox (mktemp -d) with a minimal
# rein-shaped tree: .claude/hooks + hooks lib, scripts, docs, trail,
# and a fake codex binary for wrapper assertions.
#
# 2026-08-23 갱신 (③-c 커밋 게이트 교대): pre-bash-test-commit-gate.sh 는
# 삭제되고 pre-bash-commit-discipline-gate.sh(coverage matrix + 커밋 메시지
# 포맷 — 이 스위트가 실제로 검증하는 축) → pre-bash-commit-review-gate.sh
# (code_review/security_review 두 축, v2 authority 로 전량 위임 — v1 폴백
# 없음, 그 훅 자신의 헤더 참조)의 순차 체인으로 교대됐다. run_bash_guard()
# 는 이제 pre-bash-dispatcher.sh Step 3 의 캡처-릴레이-중단 계약을 그
# 두 자식에 한해 재현한다(bootstrap-gate/safety-guard/bash-rules 는 여전히
# 대상 밖 — 이 스위트가 항상 그래왔듯 test-commit 축 자체만 직접
# 구동한다). sandbox_init() 의 `.rein/policy/authority.yaml` opt-out 은
# active_task 뿐 아니라 code_review/security_review 축까지 포함하도록
# 확장됐다 — review-gate 는 ③-c 이후 v1 폴백이 없어(위 판정 트리 참조)
# 전환이 켜져 있으면 실제 v2 엔진(`bin/rein hook`) 위임이 필요한데, 그
# 엔진의 real end-to-end 배선은 이 스위트의 범위가 아니다(task-gate 축을
# 이미 같은 이유로 의도적으로 비활성 고정해 온 것과 동일한 원리 — 두 축의
# 실제 v2 위임 동작은 tests/hooks/test-code-review-authority-switch.sh +
# tests/hooks/test-security-review-authority-switch.sh 가 전담한다). 이
# 결과 review-gate 는 이 스위트의 모든 시나리오에서 NOT_SWITCHED 판정으로
# 조용히 opt-out 하고, discipline-gate 가 검증하는 축(coverage-mismatch /
# 커밋 메시지 포맷)만 이 스위트의 실제 판정 지점으로 남는다 — 각 시나리오가
# 원래 의도한 "coverage 불일치 → 커밋 차단" 등의 의미는 그대로 보존된다.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAKE_CODEX="$REAL_PROJECT_DIR/tests/fixtures/fake-codex.sh"

TEST_COUNT=0
FAIL_COUNT=0
CURRENT_FAILS=0

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  CURRENT_FAILS=$((CURRENT_FAILS + 1))
  echo "  FAIL: $1" >&2
}

# ------------------------------------------------------------
# Shared sandbox helpers
# ------------------------------------------------------------

sandbox_init() {
  SANDBOX=$(mktemp -d "/tmp/gov-e2e-XXXXXX")
  mkdir -p "$SANDBOX/.claude/hooks/lib"
  mkdir -p "$SANDBOX/.claude/.rein-state"
  mkdir -p "$SANDBOX/scripts"
  mkdir -p "$SANDBOX/trail/dod"
  mkdir -p "$SANDBOX/trail/inbox"
  mkdir -p "$SANDBOX/trail/incidents"
  mkdir -p "$SANDBOX/docs/specs"
  mkdir -p "$SANDBOX/docs/plans"

  # Copy hooks + libs. Source dir: `.claude/hooks` (legacy dev overlay) preferred,
  # else plugin SSOT `plugins/rein-core/hooks` — Option C Phase 3 removed the dev
  # overlay so the plugin tree is the single source. Same fallback as
  # tests/hooks/lib/test-harness.sh; the sandbox TARGET layout stays
  # `.claude/hooks/` because the hooks resolve their lib via a relative path.
  local HOOKS_SRC="$REAL_PROJECT_DIR/.claude/hooks"
  [ -d "$HOOKS_SRC/lib" ] || HOOKS_SRC="$REAL_PROJECT_DIR/plugins/rein-core/hooks"
  # ③-b sequential dispatcher (2026-08-23): copy the dispatcher plus all
  # three of its children. run_pre_edit_gate below invokes ONLY the
  # dispatcher — the dispatcher itself runs the three children internally
  # in guaranteed order with first-block-wins semantics, matching the real
  # hooks.json pipeline exactly (hooks.json now registers this dispatcher
  # alone in the PreToolUse Edit|Write|MultiEdit matcher group).
  cp "$HOOKS_SRC/pre-edit-dispatcher.sh" \
     "$SANDBOX/.claude/hooks/pre-edit-dispatcher.sh"
  cp "$HOOKS_SRC/pre-edit-discipline-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-edit-discipline-gate.sh"
  cp "$HOOKS_SRC/pre-edit-task-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-edit-task-gate.sh"
  # feature-builder-refactor task step 1 (2026-08-14, Marker B relocation):
  # the coverage-validator tier/exit-code table + .dod-coverage-mismatch /
  # .dod-coverage-advisory marker production moved out of pre-edit-dod-
  # gate.sh into this sibling hook (same PreToolUse Edit|Write|MultiEdit
  # matcher group). The dispatcher runs all three and stops at the first
  # block, matching the real hooks.json pipeline.
  cp "$HOOKS_SRC/pre-edit-coverage-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-edit-coverage-gate.sh"
  # ③-c (2026-08-23): pre-bash-test-commit-gate.sh deleted, replaced by the
  # sequential two-hook chain below. Their respective real sourcing libs
  # (lib/bash-guard-infra.sh, lib/git-subcommand-model.sh, lib/code-review-
  # gate.sh, lib/security-review-gate.sh, lib/extract-commit-msg.py, etc.)
  # come along via the blanket `cp -R lib/.` a few lines down — no per-file
  # lib list needed here.
  cp "$HOOKS_SRC/pre-bash-commit-discipline-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-bash-commit-discipline-gate.sh"
  cp "$HOOKS_SRC/pre-bash-commit-review-gate.sh" \
     "$SANDBOX/.claude/hooks/pre-bash-commit-review-gate.sh"
  cp -R "$HOOKS_SRC/lib/." \
        "$SANDBOX/.claude/hooks/lib/"
  chmod +x "$SANDBOX/.claude/hooks"/*.sh

  # task-gate opt-out (see this file's own header for the full rationale):
  # link the real rein package (needed for is_switched() to even attempt
  # reading the override — see hooks/lib/active-task-gate.sh's
  # self-location comment) and explicitly exclude active_task from the
  # switched set, so pre-edit-task-gate.sh always takes its documented
  # NOT_SWITCHED opt-out (silent exit 0) instead of attempting real v2
  # delegation or fail-closing on an unset switch state.
  #
  # ③-c 갱신: code_review/security_review 도 함께 opt-out 한다(`switched:
  # none` sentinel — rein/engine/authority.py 의 _EMPTY_SWITCHED_SENTINEL
  # 참조, 빈 block sequence 는 authority.yaml 의 D3 부분집합 문법으로 표현
  # 불가해 예약된 스칼라 값이다). 이유: pre-bash-commit-review-gate.sh 는
  # ③-c 이후 v1 폴백이 없어(그 훅 자신의 헤더 판정 트리 참조), 이 두 축이
  # 전환 상태였다면 FAIL(엔진 미배선)이 그대로 fail-closed exit 2 가 되어
  # 이 스위트의 모든 시나리오를 "리뷰 축 미배선"이라는, 각 시나리오가
  # 의도한 축과 무관한 이유로 오염시킨다 — task-gate 축에 이미 적용한
  # 것과 동일한 원리의 opt-out 확장이다(위 파일 헤더 참조).
  ln -sfn "$REAL_PROJECT_DIR/plugins/rein-core/rein" "$SANDBOX/.claude/rein"
  mkdir -p "$SANDBOX/.rein/policy"
  printf 'switched: none\n' \
    > "$SANDBOX/.rein/policy/authority.yaml"

  # Scripts
  cp "$REAL_PROJECT_DIR/scripts/rein-validate-coverage-matrix.py" \
     "$SANDBOX/scripts/rein-validate-coverage-matrix.py"
  cp "$REAL_PROJECT_DIR/scripts/rein-codex-review.sh" \
     "$SANDBOX/scripts/rein-codex-review.sh"
  cp "$REAL_PROJECT_DIR/scripts/rein-govcheck.py" \
     "$SANDBOX/scripts/rein-govcheck.py"
  chmod +x "$SANDBOX/scripts"/*

  # Init git for diff_base and govcheck.
  ( cd "$SANDBOX" && git init -q \
    && git config user.email e2e@test && git config user.name e2e \
    && git commit --allow-empty -q -m "init" )

  # Seed AGENTS.md so govcheck has an entry point (even if minimal).
  printf '# Sandbox AGENTS\n\nTest fixture for govcheck.\n' > "$SANDBOX/AGENTS.md"
  mkdir -p "$SANDBOX/.claude"
  printf '# Sandbox CLAUDE.md\n' > "$SANDBOX/.claude/CLAUDE.md"
  printf '# Sandbox orchestrator\n' > "$SANDBOX/.claude/orchestrator.md"
}

sandbox_clean() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

seed_trio() {
  # Design + plan + DoD that all align on S1.
  cat > "$SANDBOX/docs/specs/sample-design.md" <<'EOF'
# Sample
## Scope Items

| ID | desc |
|----|------|
| S1 | sample |
EOF

  cat > "$SANDBOX/docs/plans/sample-plan.md" <<'EOF'
# Plan
## Design 범위 커버리지 매트릭스

> design ref: docs/specs/sample-design.md

| Scope ID | 상태 | 위치/사유 |
|----------|------|----------|
| S1 | implemented | Phase 1 |

## Phase 1
covers: [S1]
EOF

  cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1]
EOF
}

seed_trio_with_bad_dod() {
  seed_trio
  # Overwrite DoD with unknown covers ID → validator fails.
  cat > "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'
# DoD
## 범위 연결
plan ref: docs/plans/sample-plan.md
covers: [S1, UNKNOWN]
EOF
}

run_pre_edit_gate() {
  # Runs the single PreToolUse(Edit) entry point that decides whether an
  # edit proceeds: pre-edit-dispatcher.sh. This IS what hooks.json now
  # registers for the PreToolUse Edit|Write|MultiEdit matcher group — the
  # dispatcher runs pre-edit-discipline-gate.sh (governance / incident-
  # review / routing / spec-review) → pre-edit-task-gate.sh (active-task
  # axis, opt-out per sandbox_init) → pre-edit-coverage-gate.sh
  # (coverage-validator tier/exit-code table) in guaranteed sequence,
  # stopping at the first block. This replaces the PREVIOUS version of this
  # function, which ran discipline-gate and coverage-gate as two separate
  # processes and hand-merged their verdicts with "deny wins" — that
  # hand-merge modeled Claude Code's OLD parallel, non-deterministic
  # PreToolUse scheduling, which pre-edit-coverage-gate.sh's own
  # precondition-awareness peek relied on and which code review round 6
  # (High) found unsound (see pre-edit-dispatcher.sh's own header for the
  # full defect + fix). Calling the dispatcher directly is what makes this
  # suite's scenario 2 (Tier 1 unknown-covers-ID block) and scenarios 6-11
  # (stale-marker / duplicate-log preservation under a sibling precondition
  # block) exercise the REAL production sequencing instead of a hand-rolled
  # approximation of it.
  local rel_file="$1"
  local abs="$SANDBOX/$rel_file"
  local json
  json=$(printf '{"tool_input":{"file_path":"%s"}}' "$abs")

  printf '%s' "$json" \
    | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-edit-dispatcher.sh" \
      > /tmp/gate-dispatcher-stdout.$$ 2> /tmp/gate-dispatcher-stderr.$$
  GATE_RC=$?
  GATE_STDOUT=$(cat /tmp/gate-dispatcher-stdout.$$)
  GATE_STDERR=$(cat /tmp/gate-dispatcher-stderr.$$)
  rm -f /tmp/gate-dispatcher-stdout.$$ /tmp/gate-dispatcher-stderr.$$
}

run_bash_guard() {
  # ③-c (2026-08-23): pre-bash-test-commit-gate.sh was deleted and replaced
  # by a sequential two-hook chain (pre-bash-commit-discipline-gate.sh →
  # pre-bash-commit-review-gate.sh), the same children pre-bash-dispatcher.sh
  # Step 3 invokes in production. This helper reproduces ONLY that Step 3
  # sub-chain (not bootstrap-gate/safety-guard/bash-rules — matching this
  # suite's pre-existing scope of driving the test-commit axis directly,
  # same as the single-hook call this replaces). Capture-relay-stop contract
  # mirrors pre-bash-dispatcher.sh's own invoke_bash_child() (see that
  # file's header for the full rationale): rc=0 + non-empty stdout (JSON
  # deny) relays immediately without running the second child; rc=2 stops
  # immediately; any other rc is treated as an abnormal child failure and
  # also stops immediately (fail-closed) rather than silently falling
  # through to the second child.
  local command="$1"
  # Use python3 to produce a correctly-escaped JSON value. Avoids the
  # manual \"...\"  / "..." escape minefield that breaks on realistic
  # git commit -m messages.
  local json
  json=$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}}))
' "$command")

  local out rc
  out=$(printf '%s' "$json" \
    | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-bash-commit-discipline-gate.sh" \
      2> /tmp/bg-stderr.$$)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
    # rc=2 (block) or rc=0+non-empty stdout (JSON deny relay): stop here,
    # do not invoke the review-gate. Any other non-zero rc is an abnormal
    # child exit — also stops here (fail-closed), matching the dispatcher's
    # own posture for a corrupted/misbehaving child.
    GUARD_RC="$rc"
    GUARD_STDOUT="$out"
    GUARD_STDERR=$(cat /tmp/bg-stderr.$$)
    rm -f /tmp/bg-stderr.$$
    return
  fi
  rm -f /tmp/bg-stderr.$$

  out=$(printf '%s' "$json" \
    | REIN_PROJECT_DIR_OVERRIDE="$SANDBOX" \
      bash "$SANDBOX/.claude/hooks/pre-bash-commit-review-gate.sh" \
      2> /tmp/bg-stderr2.$$)
  rc=$?
  GUARD_RC="$rc"
  GUARD_STDOUT="$out"
  GUARD_STDERR=$(cat /tmp/bg-stderr2.$$)
  rm -f /tmp/bg-stderr2.$$
}

run_test() {
  local fn="$1"
  CURRENT_FAILS=0
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "RUN $fn"
  sandbox_init
  trap 'sandbox_clean' RETURN
  "$fn"
  if [ "$CURRENT_FAILS" -eq 0 ]; then
    echo "  OK"
  fi
  trap - RETURN
  sandbox_clean
}

# ------------------------------------------------------------
# Scenario 1 — Happy path.
# ------------------------------------------------------------
test_happy_path_passes_gate_and_guard() {
  seed_trio
  # Tier 1 marker so the DoD is unambiguously the active one.
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c: review-gate opts out of the code_review/security_review axes
  # entirely (sandbox_init's `switched: none`), so no review evidence/marker
  # seeding is needed here — review axes never enter this scenario's
  # decision. ③-d (2026-08-24): the legacy .codex-reviewed/.security-
  # reviewed touches this comment used to justify as "vestigial but
  # harmless" are removed outright — their write path no longer exists
  # anywhere in the codebase, so seeding them here would create files
  # nothing produces in production (정당 소멸, not merely inert).
  # IMPORTANT: NO inbox file for the DoD slug → DoD is "pending/active" →
  # pre-edit-discipline-gate considers it the active DoD. If we seed an inbox
  # match, the DoD is marked "complete" and the gate can't match.

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "0" ] || fail "happy path pre-edit-discipline-gate exit=$GATE_RC stderr=$GATE_STDERR"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    && fail "happy path should not create .dod-coverage-mismatch"

  # bash-guard with heredoc message — use simpler format to avoid JSON escape.
  run_bash_guard 'git commit -m "feat: integration test"'
  [ "$GUARD_RC" = "0" ] || fail "happy path bash-guard exit=$GUARD_RC stderr=$GUARD_STDERR"
}

# ------------------------------------------------------------
# Scenario 2 — Tier 1 marker + unknown ID → gate blocks + marker set,
# then pre-bash-commit-discipline-gate.sh (③-c successor) blocks commit due
# to the marker.
# ------------------------------------------------------------
test_tier1_unknown_id_blocks_edit_and_commit() {
  seed_trio_with_bad_dod
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c: review-gate opts out of code_review/security_review entirely
  # (sandbox_init's `switched: none`) — no seeding needed, and ③-d removed
  # the legacy stamps' write path outright (정당 소멸).
  # NO inbox file → DoD is active/pending → gate evaluates it.

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "2" ] || fail "tier1 unknown ID should block (exit=$GATE_RC, stderr=$GATE_STDERR)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    || fail "tier1 unknown ID should create .dod-coverage-mismatch"

  # Now pre-bash-commit-discipline-gate.sh (③-c successor, owns the
  # coverage-matrix axis) must refuse commit while the marker exists. The
  # DoD carries an unknown covers ID → coverage validator FAIL → P2 deny,
  # emitted as a JSON deny (exit 0 + stdout permissionDecision:deny) per the
  # json-deny migration — NOT exit 2. Mirrors
  # test-pre-bash-commit-discipline-gate.sh assert_json_deny("COVERAGE_MISMATCH").
  run_bash_guard 'git commit -m "feat: integration test"'
  [ "$GUARD_RC" = "0" ] || fail "bash-guard JSON-deny path should exit 0 (exit=$GUARD_RC, stderr=$GUARD_STDERR)"
  echo "$GUARD_STDOUT" | grep -qF '"permissionDecision": "deny"' \
    || fail "bash-guard should JSON-deny with marker (stdout=$GUARD_STDOUT)"
  echo "$GUARD_STDOUT" | grep -qF "COVERAGE_MISMATCH" \
    || fail "bash-guard JSON deny missing COVERAGE_MISMATCH reason-code"
}

# ------------------------------------------------------------
# Scenario 3 — Governance config corruption → fail-closed block.
# ------------------------------------------------------------
test_governance_corruption_fails_closed() {
  seed_trio
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # Corrupt governance.json — fail-closed runs before DoD detection.
  echo 'corrupted' > "$SANDBOX/.claude/.rein-state/governance.json"

  run_pre_edit_gate "scripts/foo.sh"
  [ "$GATE_RC" = "2" ] || fail "corrupt governance.json should block (exit=$GATE_RC)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    || fail "corrupt governance → missing .dod-coverage-mismatch"
  [ -f "$SANDBOX/trail/incidents/governance-config-invalid.log" ] \
    || fail "corrupt governance → missing governance-config-invalid.log"
}

# ------------------------------------------------------------
# Scenario 4 — codex-review wrapper PASS → v2 발급 경로 진입 (Phase 7 웨이브
# 3 ③-d 재조준). 원래 이 시나리오는 "래퍼가 .codex-reviewed 에 diff_base:
# 필드를 쓴다"를 검증했다. ③-d 로 legacy stamp 의 write 경로 자체가
# `scripts/rein-codex-review.sh` 에서 전면 제거됐다 — PASS 시 v2
# code_review 증거 발급이 유일한 기록 경로다. 이 시나리오는 bin/rein 을
# 링크하지 않으므로(다른 축을 다루는 이 스위트의 sandbox_init 은 review
# 두 축을 opt-out 하지만, 이 wrapper 직접 호출 경로는 그 opt-out 과 무관
# — 발급은 "캡처된 digest 없음" 경로로 빠지며, 그 자체가 write_code_
# review_stamp() 가 실제로 호출됐다는 관측 가능한 증거다(stderr ERROR
# 로그, tests/skills/test-codex-review-wrapper.sh Verification 4 와 동일
# 패턴). diff_base 계산 자체의 회귀(무조건 HEAD~1)는
# tests/skills/test-codex-review-stale-stamp.sh 가 전담한다(대체).
# ------------------------------------------------------------
test_code_review_pass_enters_v2_evidence_issuance_path() {
  seed_trio
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  # Ensure no legacy marker present — proves it stays absent, not merely
  # unwritten-because-pre-seeded.
  rm -f "$SANDBOX/trail/dod/.codex-reviewed" "$SANDBOX/trail/dod/.review-pending"

  local capture stdin_file stderr_file
  capture="$SANDBOX/.cap-e2e.txt"
  stdin_file="$SANDBOX/.stdin.txt"
  stderr_file="$SANDBOX/.stderr-e2e.txt"
  # 자가검증 관문(2026-07-21 review-cycle-efficiency A축) fixture 통행증 —
  # sandbox 의 untracked 준비물로 관문이 발동하므로 none 폴백 선언으로 통과.
  printf 'integration test prompt\nverification_commands: none\ndiff_self_review: harness fixture pass\n' > "$stdin_file"
  (
    cd "$SANDBOX"
    export CODEX_BIN="$FAKE_CODEX"
    export FAKE_CODEX_CAPTURE="$capture"
    # Default FAKE_CODEX_VERDICT = PASS.
    bash "$SANDBOX/scripts/rein-codex-review.sh" --non-interactive \
      < "$stdin_file" > /dev/null 2> "$stderr_file"
  )
  local rc=$?
  [ "$rc" = "0" ] || fail "wrapper e2e exit=$rc"
  [ ! -e "$SANDBOX/trail/dod/.codex-reviewed" ] \
    || fail "legacy .codex-reviewed stamp unexpectedly created (③-d write path removed)"
  [ ! -e "$SANDBOX/trail/dod/.review-pending" ] \
    || fail "legacy .review-pending marker unexpectedly created (③-d write path removed)"
  grep -q "no review-start subject digest was captured" "$stderr_file" \
    || fail "write_code_review_stamp() ERROR not observed in stderr (v2 issuance path not reached): $(cat "$stderr_file")"
  grep -qF "Required review sections" "$capture" \
    || fail "captured envelope missing 'Required review sections'"
}

# ------------------------------------------------------------
# Scenario 5 — govcheck smoke: happy path exit 0, fake broken ref exit 2.
#
# We use a hermetic sandbox where all referenced scripts exist (copied
# from the real repo) + minimal governance docs. Happy path = govcheck
# passes. Then we inject a dangling reference to prove it catches the
# break.
# ------------------------------------------------------------
test_govcheck_happy_and_broken_ref() {
  # Copy every rein-* script the hooks reference so govcheck's ref graph
  # resolves. We simply mirror the entire scripts dir from the real repo —
  # it's light and guarantees the happy path.
  mkdir -p "$SANDBOX/scripts"
  cp "$REAL_PROJECT_DIR/scripts/"rein-*.{sh,py} "$SANDBOX/scripts/" 2>/dev/null || true

  # Happy path: govcheck exits 0 on a well-formed sandbox.
  ( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" \
      > /tmp/gc-stdout.$$ 2> /tmp/gc-stderr.$$ )
  local gc_rc=$?
  local gc_err
  gc_err=$(cat /tmp/gc-stderr.$$)
  rm -f /tmp/gc-stdout.$$ /tmp/gc-stderr.$$
  [ "$gc_rc" = "0" ] || fail "govcheck happy path exit=$gc_rc (stderr: $gc_err)"

  # Broken ref: inject a dangling reference into AGENTS.md → exit 2.
  printf 'see scripts/rein-nonexistent-zzzz.sh for details\n' >> "$SANDBOX/AGENTS.md"
  ( cd "$SANDBOX" && python3 "$SANDBOX/scripts/rein-govcheck.py" \
      > /tmp/gc-stdout.$$ 2> /tmp/gc-stderr.$$ )
  local gc_rc2=$?
  rm -f /tmp/gc-stdout.$$ /tmp/gc-stderr.$$
  [ "$gc_rc2" = "2" ] || fail "govcheck broken ref expected exit 2, got $gc_rc2"
}

# ------------------------------------------------------------
# Shared assertions — "a sibling precondition gate (routing-gate /
# incident-review-gate / spec-review-gate) is blocking this edit; did
# pre-edit-coverage-gate.sh corrupt marker/audit-log state anyway?"
#
# Factored out (feature-builder-fix, coverage-gate perf-fix round 2,
# 2026-08-14) because scenarios 6-11 below are the SAME two assertions
# repeated once per precondition axis — only the block SETUP differs (a
# routing-section violation, an unresolved incident, or an unreviewed
# design doc). Before this factoring each axis was ~30 lines of near-
# identical copy/paste; keeping the axes as separate test FUNCTIONS (rather
# than a single parametrized loop) is deliberate — each axis needs its own
# hand-shaped fixture (routing YAML block / incident frontmatter / spec
# .pending marker) that does not compress cleanly into one table, and a
# named `test_*` function per axis keeps failures individually attributable
# and individually skippable/bisectable.
# ------------------------------------------------------------
_assert_block_preserves_stale_marker() {
  # $1 = short label identifying the precondition axis, for failure messages
  local label="$1"
  [ "$GATE_RC" = "2" ] || fail "$label: edit should block (exit=$GATE_RC, stderr=$GATE_STDERR)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    || fail "$label: pre-existing .dod-coverage-mismatch marker did not survive the block — pre-edit-coverage-gate.sh cleared it independently while the edit was blocked for an unrelated reason"
}

_assert_block_skips_fresh_marker_and_dup_log() {
  # $1 = short label identifying the precondition axis, for failure messages
  local label="$1"
  [ "$GATE_RC" = "2" ] || fail "$label: edit should block (exit=$GATE_RC, stderr=$GATE_STDERR)"
  [ -f "$SANDBOX/trail/dod/.dod-coverage-mismatch" ] \
    && fail "$label: pre-edit-coverage-gate.sh created a FRESH .dod-coverage-mismatch marker while a sibling precondition gate was already blocking this same edit"
  local block_count=0
  if [ -f "$SANDBOX/trail/incidents/blocks.jsonl" ]; then
    block_count=$(wc -l < "$SANDBOX/trail/incidents/blocks.jsonl" | tr -d '[:space:]')
  fi
  [ "$block_count" = "1" ] || fail "$label: expected exactly 1 blocks.jsonl entry for this single blocked edit, got $block_count (pre-edit-coverage-gate.sh should not add its own duplicate entry while a sibling gate is blocking)"
}

# ------------------------------------------------------------
# Scenario 6 — routing-gate block (approved_by_user missing) + otherwise
# VALID coverage: a pre-existing .dod-coverage-mismatch marker (left over
# from an earlier bad state) must SURVIVE the block. 현행 실행 모델(③-b
# round 6~, pre-edit-dispatcher.sh): 디스패처가 discipline → task →
# coverage 를 순차 실행하고 **첫 차단에서 중단**하므로, routing-gate 가
# discipline 단계에서 차단하면 coverage-gate 는 아예 실행되지 않는다 —
# 마커가 살아남는 근거가 (구 병렬 모델의) "coverage 가 sibling 차단을
# 알아채고 스스로 건너뜀" 에서 "coverage 가 실행 자체가 안 됨" 으로
# 바뀌었고, 이 시나리오는 그 새 보장을 검증한다.
# Before the coverage-gate precondition-awareness fix this cleared the
# marker; after the fix the coverage-gate precheck detects the routing
# block and skips touching the marker entirely, matching what a single
# combined gate (the pre-separation design) would have done — the routing
# check exits 2 before the validator code is ever reached.
# ------------------------------------------------------------
test_routing_block_preserves_stale_coverage_marker() {
  seed_trio  # S1 covers correctly -> the validator would PASS (Tier 1, exit 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # Routing section present but NOT approved -> pre-edit-discipline-gate.sh's
  # routing gate blocks (a precondition coverage-gate does not own).
  cat >> "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'

## 라우팅 추천
agent: feature-builder
approved_by_user: false
EOF

  # ③-c: review-gate opts out of code_review/security_review entirely — no
  # seeding needed, and ③-d removed the legacy stamps' write path (정당 소멸).

  # Pre-existing marker from an earlier bad state — this is what must
  # survive the block (the bug: coverage-gate silently cleared it).
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_preserves_stale_marker "routing-gate"
}

# ------------------------------------------------------------
# Scenario 7 — routing-gate block (approved_by_user missing) + INVALID
# coverage: pre-edit-coverage-gate.sh must not (a) freshly create
# .dod-coverage-mismatch on its own — that marker's producer is only
# meaningful once the routing precondition clears — nor (b) add a second
# blocks.jsonl entry for what is logically ONE blocked edit. Before the
# fix, the coverage-gate ran its validator independently, found the
# UNKNOWN covers ID, touched the marker fresh, and logged its own "dod
# covers mismatch (tier 1)" block entry on TOP of pre-edit-discipline-gate.sh's
# "routing section 위반" entry — a duplicate audit-log record for a single
# block. After the fix, the coverage-gate precheck detects the routing
# block and skips both the marker touch and the validator invocation
# (so no second log entry is produced), matching the pre-separation
# single-hook behavior where the routing check exits 2 before the
# validator code is ever reached.
# ------------------------------------------------------------
test_routing_block_skips_fresh_marker_and_duplicate_log() {
  seed_trio_with_bad_dod  # unknown covers ID -> the validator would FAIL (Tier 1, exit != 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  cat >> "$SANDBOX/trail/dod/dod-2026-04-21-sample.md" <<'EOF'

## 라우팅 추천
agent: feature-builder
approved_by_user: false
EOF

  # No pre-existing marker — this scenario checks nothing NEW gets created.
  rm -f "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_skips_fresh_marker_and_dup_log "routing-gate"
}

# ------------------------------------------------------------
# Scenario 8 — incident-review-pending block (an unresolved incident, no
# bypass marker) + otherwise VALID coverage: a pre-existing
# .dod-coverage-mismatch marker must SURVIVE. Same defect class as scenario
# 6, but exercising the incident-review-gate axis instead of routing-gate —
# before the coverage-gate precondition-awareness fix, NEITHER axis was
# checked by pre-edit-coverage-gate.sh, so a fix that only special-cased
# routing-gate (the axis scenario 6/7 already covered) could still regress
# this one silently.
# ------------------------------------------------------------
test_incident_review_block_preserves_stale_coverage_marker() {
  seed_trio  # S1 covers correctly -> the validator would PASS (Tier 1, exit 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c/③-d: review-gate opts out and legacy stamps' write path is gone —
  # no seeding needed (정당 소멸).

  # One unresolved (status: pending) incident + the INCIDENT_STAMP marker —
  # matches the shape rein_check_incident_review_gate requires to enter its
  # blocking branch (LIVE_COUNT > 0, no .skip-incident-gate bypass).
  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/auto-hook-e2e111.md" <<'EOF'
---
status: "pending"
pattern_hash: "e2e111"
hook: "hook"
reason: "e2e test incident"
count: "2"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-02T00:00:00"
---

# Incident: hook / e2e test incident
EOF
  touch "$SANDBOX/trail/dod/.incident-review-pending"

  # Pre-existing marker from an earlier bad state — must survive the block.
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_preserves_stale_marker "incident-review-gate"
}

# ------------------------------------------------------------
# Scenario 9 — incident-review-pending block + INVALID coverage: no fresh
# .dod-coverage-mismatch marker, no duplicate blocks.jsonl entry. Mirrors
# scenario 7 on the incident-review-gate axis.
# ------------------------------------------------------------
test_incident_review_block_skips_fresh_marker_and_duplicate_log() {
  seed_trio_with_bad_dod  # unknown covers ID -> the validator would FAIL (Tier 1, exit != 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c/③-d: review-gate opts out and legacy stamps' write path is gone —
  # no seeding needed (정당 소멸).

  mkdir -p "$SANDBOX/trail/incidents"
  cat > "$SANDBOX/trail/incidents/auto-hook-e2e222.md" <<'EOF'
---
status: "pending"
pattern_hash: "e2e222"
hook: "hook"
reason: "e2e test incident"
count: "2"
first_seen: "2026-01-01T00:00:00"
last_seen_at: "2026-01-02T00:00:00"
---

# Incident: hook / e2e test incident
EOF
  touch "$SANDBOX/trail/dod/.incident-review-pending"

  rm -f "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_skips_fresh_marker_and_dup_log "incident-review-gate"
}

# ------------------------------------------------------------
# Scenario 10 — spec-review-gate block (an unreviewed design doc referenced
# by the active DoD's plan) + otherwise VALID coverage: a pre-existing
# .dod-coverage-mismatch marker must SURVIVE. Same defect class as scenario
# 6/8, exercising the spec-review-gate axis (the O(N) marker scan whose
# unconditional-precheck cost this fix cycle's performance fix specifically
# targets — this scenario proves the perf fix did not also remove the
# correctness guard on this axis).
#
# docs/specs/sample-design.md is pulled into the GSD-2 relatedness corpus
# via docs/plans/sample-plan.md's `design ref:` line, which the active DoD's
# own `plan ref:` line reaches — so an unreviewed .pending marker for it is
# a BLOCKING (not merely warned-and-passed) unresolved spec.
# ------------------------------------------------------------
test_spec_review_block_preserves_stale_coverage_marker() {
  seed_trio  # S1 covers correctly -> the validator would PASS (Tier 1, exit 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c/③-d: review-gate opts out and legacy stamps' write path is gone —
  # no seeding needed (정당 소멸).

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/trail/dod/.spec-reviews/e2e-spec-block.pending" <<EOF
path=$SANDBOX/docs/specs/sample-design.md
created=2020-01-01T00:00:00
EOF

  # Pre-existing marker from an earlier bad state — must survive the block.
  touch "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_preserves_stale_marker "spec-review-gate"
}

# ------------------------------------------------------------
# Scenario 11 — spec-review-gate block + INVALID coverage: no fresh
# .dod-coverage-mismatch marker, no duplicate blocks.jsonl entry. Mirrors
# scenario 7/9 on the spec-review-gate axis.
# ------------------------------------------------------------
test_spec_review_block_skips_fresh_marker_and_duplicate_log() {
  seed_trio_with_bad_dod  # unknown covers ID -> the validator would FAIL (Tier 1, exit != 0)
  echo "path=trail/dod/dod-2026-04-21-sample.md" > "$SANDBOX/trail/dod/.active-dod"
  touch "$SANDBOX/scripts/foo.sh"

  # ③-c/③-d: review-gate opts out and legacy stamps' write path is gone —
  # no seeding needed (정당 소멸).

  mkdir -p "$SANDBOX/trail/dod/.spec-reviews"
  cat > "$SANDBOX/trail/dod/.spec-reviews/e2e-spec-block.pending" <<EOF
path=$SANDBOX/docs/specs/sample-design.md
created=2020-01-01T00:00:00
EOF

  rm -f "$SANDBOX/trail/dod/.dod-coverage-mismatch"

  run_pre_edit_gate "scripts/foo.sh"
  _assert_block_skips_fresh_marker_and_dup_log "spec-review-gate"
}

summary() {
  local pass=$((TEST_COUNT - FAIL_COUNT))
  echo ""
  echo "================================"
  echo "Tests run: $TEST_COUNT"
  echo "Passed:    $pass"
  echo "Failed:    $FAIL_COUNT"
  echo "================================"
  [ "$FAIL_COUNT" -eq 0 ]
}

main() {
  run_test test_happy_path_passes_gate_and_guard
  run_test test_tier1_unknown_id_blocks_edit_and_commit
  run_test test_governance_corruption_fails_closed
  run_test test_code_review_pass_enters_v2_evidence_issuance_path
  run_test test_govcheck_happy_and_broken_ref
  run_test test_routing_block_preserves_stale_coverage_marker
  run_test test_routing_block_skips_fresh_marker_and_duplicate_log
  run_test test_incident_review_block_preserves_stale_coverage_marker
  run_test test_incident_review_block_skips_fresh_marker_and_duplicate_log
  run_test test_spec_review_block_preserves_stale_coverage_marker
  run_test test_spec_review_block_skips_fresh_marker_and_duplicate_log
  summary
}

main "$@"
