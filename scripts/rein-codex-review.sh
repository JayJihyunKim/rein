#!/usr/bin/env bash
# scripts/rein-codex-review.sh
#
# /codex-review wrapper — context assembly + envelope + codex exec + stamp.
#
# Scope IDs:
#   - GI-codex-review-context-assembly
#   - GI-codex-review-envelope-slots
#   - GI-codex-review-diff-base
#   - GI-codex-review-envelope-context-missing
#   - GI-codex-review-wrapper-script
#
# CRITICAL invariant (Plan A Phase 6 Task 6.3 Step 3, spec B / SKILL §6.6):
#   In spec-review mode, this wrapper MUST NOT create or modify
#   trail/dod/.codex-reviewed, and MUST NOT touch trail/dod/.review-pending.
#   The pre-bash-guard code-commit/test gate depends on .codex-reviewed as a
#   code-review stamp — spec-review writes would let reviewers bypass the
#   gate without a real code review. Regression tests live in
#   tests/skills/test-codex-review-wrapper.sh (verifications 5 + 6).
#
# Injection seam (test hook):
#   CODEX_BIN — path to the codex binary. Defaults to the first `codex`
#   on PATH. Tests override with tests/fixtures/fake-codex.sh.
#
# Usage:
#   bash scripts/rein-codex-review.sh
#       Interactive code review. Caller provides the prompt body on stdin.
#   bash scripts/rein-codex-review.sh --non-interactive
#       Automated call (agent). Prefix [NON_INTERACTIVE] added to envelope.
#   echo "[NON_INTERACTIVE] spec review for plan: docs/plans/foo.md" \
#     | bash scripts/rein-codex-review.sh --non-interactive
#       Spec-review mode (plan). No stamp written.
#   echo "[NON_INTERACTIVE] spec review for design: docs/specs/foo.md" \
#     | bash scripts/rein-codex-review.sh --non-interactive
#       Spec-review mode (design). No stamp written.

set -euo pipefail

# ---- Locate project dir (git repo root if possible). ------------------

_script_dir=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR="$(cd "$_script_dir/.." && pwd)"

# If invoked from outside PROJECT_DIR, still operate on PROJECT_DIR so
# select_active_dod reads the correct trail/dod.
cd "$PROJECT_DIR"

# ---- Inject the shared DoD selector (Phase 4.1 library). --------------

# Fail-closed if library missing (same pattern as pre-edit-dod-gate.sh).
if ! . "$PROJECT_DIR/.claude/hooks/lib/select-active-dod.sh" 2>/dev/null; then
  echo "ERROR: [codex-review] missing .claude/hooks/lib/select-active-dod.sh" >&2
  exit 2
fi

# ---- Parse CLI options + read stdin prompt. ---------------------------

NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    *) ;;  # pass-through args reserved for future codex options; ignored here
  esac
done

# Read the entire prompt body from stdin. If no stdin (tty), PROMPT_BODY
# is empty — this is the interactive case where the caller will type below.
PROMPT_BODY=""
if [ ! -t 0 ]; then
  PROMPT_BODY=$(cat)
fi

# ---- Parse [EFFORT:<level>] marker (SKILL.md §6.1/6.2). ---------------
# Supported values: low | medium | high. Invalid (e.g. [EFFORT:low2],
# [EFFORT:low-high], [EFFORT: ], [EFFORT:]) → stderr warning + fallback to
# ~/.codex/config.toml default (no --config flag passed). All [EFFORT:...]
# occurrences are stripped from PROMPT_BODY regardless of validity so codex
# never receives the marker (§6.2 contract).
#
# The outer capture uses [^]]* (any non-']' content) so malformed values
# are captured too, triggering the documented warn-and-fallback path.
# The inner value is whitespace-trimmed before whitelist check so
# "[EFFORT: medium ]" is accepted as medium.
REIN_EFFORT=""
if [ -n "$PROMPT_BODY" ]; then
  _effort_raw=$(printf '%s' "$PROMPT_BODY" | grep -oE '\[EFFORT:[^]]*\]' 2>/dev/null | head -1 || true)
  if [ -n "$_effort_raw" ]; then
    # Strip leading/trailing whitespace around the inner value.
    _effort_val=$(printf '%s' "$_effort_raw" | sed -E 's/^\[EFFORT:[[:space:]]*//; s/[[:space:]]*\]$//')
    case "$_effort_val" in
      low|medium|high)
        REIN_EFFORT="$_effort_val"
        ;;
      *)
        echo "WARNING: [codex-review] invalid effort '$_effort_val' in [EFFORT:...] marker; falling back to ~/.codex/config.toml default" >&2
        ;;
    esac
    # Strip ALL [EFFORT:...] occurrences (valid or not, any inner content).
    PROMPT_BODY=$(printf '%s' "$PROMPT_BODY" | sed -E 's/\[EFFORT:[^]]*\][[:space:]]*//g')
  fi
  unset _effort_raw _effort_val
fi

# ---- Mode detection (Task 6.1 Step 2a). -------------------------------

# Marker patterns anchored to the start of the prompt.
SPEC_REVIEW_PLAN_RE='^\[NON_INTERACTIVE\][[:space:]]+spec review for plan:'
SPEC_REVIEW_DESIGN_RE='^\[NON_INTERACTIVE\][[:space:]]+spec review for design:'

REIN_REVIEW_MODE="code-review"  # default
if printf '%s' "$PROMPT_BODY" | head -1 | grep -qE "$SPEC_REVIEW_PLAN_RE"; then
  REIN_REVIEW_MODE="spec-review"
elif printf '%s' "$PROMPT_BODY" | head -1 | grep -qE "$SPEC_REVIEW_DESIGN_RE"; then
  REIN_REVIEW_MODE="spec-review"
fi

# ---- Context assembly (Task 6.1 Step 4). ------------------------------

# 4a. diff_base.
#   Preference: latest .codex-reviewed stamp's diff_base: line → HEAD~1 →
#   empty tree (pre-commit, no HEAD).
EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

_resolve_diff_base() {
  local stamp="$PROJECT_DIR/trail/dod/.codex-reviewed"
  if [ -f "$stamp" ]; then
    local base
    base=$(grep -E '^diff_base:' "$stamp" | head -1 | sed 's/^diff_base:[[:space:]]*//' || true)
    if [ -n "$base" ]; then
      printf '%s' "$base"
      return 0
    fi
  fi
  # HEAD~1 if it exists.
  if git -C "$PROJECT_DIR" rev-parse HEAD~1 >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" rev-parse HEAD~1
    return 0
  fi
  # Pre-commit / shallow: fall back to empty tree so diff vs. this is
  # "everything tracked" — better than erroring out.
  printf '%s' "$EMPTY_TREE_SHA"
}

DIFF_BASE=$(_resolve_diff_base)

# 4b. Changed files vs. diff base. We prefer --cached first (staged), then
# merged with working-tree unstaged so we capture everything the reviewer
# might touch. For simplicity here we use `git diff --name-only <base>..HEAD`
# plus unstaged changes against HEAD. Failures degrade to empty list.
_changed_files() {
  local out
  out=$(git -C "$PROJECT_DIR" diff --name-only "$DIFF_BASE"..HEAD 2>/dev/null || true)
  if [ -z "$out" ]; then
    out=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null || true)
  fi
  if [ -z "$out" ]; then
    out=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null || true)
  fi
  printf '%s' "$out"
}
CHANGED_FILES=$(_changed_files)

# 4c. Active DoD via shared selector.
SAD_LINE=$(select_active_dod)
SAD_TIER=$(printf '%s' "$SAD_LINE" | cut -f1)
SAD_PATH=$(printf '%s' "$SAD_LINE" | cut -f2)
SAD_REASON=$(printf '%s' "$SAD_LINE" | cut -f3)

# ---- Shared path resolver (H1, 2026-04-22 retro-review-sweep). --------
#
# Mirrors scripts/rein-validate-coverage-matrix.py::_resolve_plan_ref.
# Both tools must resolve file references the same way so the envelope
# and validator agree on "does this file exist?". Divergence was the
# root cause of the v1.1.0 `design_ref: ../specs/...` silent failure.
#
# Args: $1=reference string, $2=base file used for relative resolution.
# Stdout: absolute path of first existing candidate (or empty if none).
# Exit: 0 if resolved, 1 if no candidate exists.
# Candidates tried in order:
#   1. <dirname($2)>/$1          (base-file-relative; most specific)
#   2. $PROJECT_DIR/$1           (repo-relative)
#   3. $1                        (CWD-relative / absolute)
_resolve_relative_path() {
  local ref="$1"
  local base_file="$2"
  local candidate
  local base_dir

  if [ -z "$ref" ]; then
    return 1
  fi

  if [ -n "$base_file" ] && [ -f "$base_file" ]; then
    base_dir=$(cd "$(dirname "$base_file")" 2>/dev/null && pwd)
    if [ -n "$base_dir" ]; then
      candidate="$base_dir/$ref"
      if [ -f "$candidate" ]; then
        (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
        return 0
      fi
    fi
  fi

  candidate="$PROJECT_DIR/$ref"
  if [ -f "$candidate" ]; then
    (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
    return 0
  fi

  if [ -f "$ref" ]; then
    (cd "$(dirname "$ref")" && printf '%s/%s\n' "$(pwd)" "$(basename "$ref")")
    return 0
  fi

  return 1
}

# 4d. Plan ref from active DoD `## 범위 연결` section.
#
# Single-plan contract (per .claude/rules/design-plan-coverage.md). Phase 2
# (integration DoD) will lift this; until then we return the first plan_ref
# only and use `_count_dod_plan_refs` + gap header to flag duplicates.
#
# Annotation strip (H2, 2026-04-22): only the canonical annotations
# `(Team [A-Z])` or `(<bare identifier>)` are stripped. A path that itself
# contains parentheses (e.g. `docs/plans/foo(v2).md`) is preserved — the
# previous greedy `\(.*\)` strip would have truncated it.
_parse_dod_plan_ref() {
  local dod="$1"
  [ -f "$dod" ] || return 0
  awk '
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^plan[[:space:]]*ref:/ {
      line=$0
      sub(/^plan[[:space:]]*ref:[[:space:]]*/, "", line)
      # Strip only recognized annotation suffixes.
      if (match(line, /[[:space:]]+\((Team[[:space:]]+[A-Z]|[A-Za-z0-9_-]+)\)[[:space:]]*$/) > 0) {
        line=substr(line, 1, RSTART-1)
      }
      # Trim trailing whitespace if any remains.
      sub(/[[:space:]]+$/, "", line)
      print line; exit
    }
  ' "$dod"
}

# Count plan_ref lines within the DoD `## 범위 연결` section.
# Used to flag MULTIPLE_FAIL_CLOSED state when a DoD carries more than one.
_count_dod_plan_refs() {
  local dod="$1"
  [ -f "$dod" ] || { echo 0; return 0; }
  awk '
    BEGIN {count=0}
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^plan[[:space:]]*ref:/ {count++}
    END {print count+0}
  ' "$dod"
}

PLAN_REF=""
PLAN_REF_COUNT=0
PLAN_REF_RAW=""  # first ref string as parsed (no resolve applied yet)
if [ -n "$SAD_PATH" ]; then
  PLAN_REF_RAW=$(_parse_dod_plan_ref "$SAD_PATH" 2>/dev/null || true)
  PLAN_REF_COUNT=$(_count_dod_plan_refs "$SAD_PATH" 2>/dev/null || echo 0)
  if [ -n "$PLAN_REF_RAW" ]; then
    PLAN_REF=$(_resolve_relative_path "$PLAN_REF_RAW" "$SAD_PATH" || true)
  fi
fi

# H2 warning — duplicate plan refs are Phase-2 territory. Wrapper proceeds
# with first ref only and records state in the envelope gap header.
if [ "$PLAN_REF_COUNT" -gt 1 ]; then
  echo "WARNING: [codex-review] '$SAD_PATH' declares $PLAN_REF_COUNT plan refs; using first only (integration DoD is Phase 2)" >&2
fi

# 4e. Design ref from plan. Supports two equivalent syntaxes observed in
# the spec corpus:
#   - `> design ref: <path>`          (blockquote form; Plan A canonical)
#   - `Design Reference: <path>`      (top-level form; seen in some specs)
# Returned path is resolved against the plan file's parent → PROJECT_DIR →
# as-is (`_resolve_relative_path`). If the target file does not exist, we
# return empty so `design_state` becomes MISSING (H1 truthful detection).
_parse_plan_design_ref() {
  local plan="$1"
  [ -f "$plan" ] || return 0
  local raw
  raw=$(grep -iE '^>[[:space:]]*design[[:space:]]*ref:' "$plan" 2>/dev/null \
    | head -1 \
    | sed -E 's/^>[[:space:]]*design[[:space:]]*ref:[[:space:]]*//I' || true)
  if [ -z "$raw" ]; then
    raw=$(grep -iE '^design[[:space:]]*reference:' "$plan" 2>/dev/null \
      | head -1 \
      | sed -E 's/^design[[:space:]]*reference:[[:space:]]*//I' || true)
  fi
  [ -z "$raw" ] && return 0
  _resolve_relative_path "$raw" "$plan" || true
}
DESIGN_REF=""
DESIGN_REF_RAW=""
if [ -n "$PLAN_REF" ]; then
  # Preserve raw string for diagnostics, resolve for real use.
  DESIGN_REF_RAW=$(grep -iE '^>[[:space:]]*design[[:space:]]*ref:|^design[[:space:]]*reference:' "$PLAN_REF" 2>/dev/null \
    | head -1 \
    | sed -E 's/^>?[[:space:]]*design[[:space:]]*(ref|reference):[[:space:]]*//I' || true)
  DESIGN_REF=$(_parse_plan_design_ref "$PLAN_REF" 2>/dev/null || true)
fi

# 4f. Scope items from design's `## Scope Items` table.
_parse_scope_items_table() {
  local design="$1"
  [ -f "$design" ] || return 0
  awk '
    /^## Scope Items/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec { print }
  ' "$design"
}
SCOPE_ITEMS=""
if [ -n "$DESIGN_REF" ]; then
  SCOPE_ITEMS=$(_parse_scope_items_table "$DESIGN_REF" 2>/dev/null || true)
fi

# 4g. Covers list from DoD `## 범위 연결` section.
_parse_dod_covers() {
  local dod="$1"
  [ -f "$dod" ] || return 0
  awk '
    /^## 범위 연결/ {in_sec=1; next}
    in_sec && /^## / {in_sec=0}
    in_sec && /^covers:/ {
      sub(/^covers:[[:space:]]*/, "");
      print; exit
    }
  ' "$dod"
}
COVERS=""
if [ -n "$SAD_PATH" ]; then
  COVERS=$(_parse_dod_covers "$SAD_PATH" 2>/dev/null || true)
fi

# 4h. Claim sources — REIN_PR_TITLE/REIN_PR_BODY env > HEAD commit > DoD
# title + plan Goal. We degrade gracefully — claim source is best-effort.
_claim_sources() {
  if [ -n "${REIN_PR_TITLE:-}" ] || [ -n "${REIN_PR_BODY:-}" ]; then
    printf 'title=%s\nbody=%s\n' "${REIN_PR_TITLE:-}" "${REIN_PR_BODY:-}"
    return 0
  fi
  local head_msg
  head_msg=$(git -C "$PROJECT_DIR" log -1 --pretty=%B 2>/dev/null || true)
  if [ -n "$head_msg" ]; then
    printf 'head_commit=\n%s\n' "$head_msg"
    return 0
  fi
  if [ -n "$SAD_PATH" ]; then
    local title
    title=$(head -1 "$SAD_PATH" 2>/dev/null | sed 's/^#[[:space:]]*//')
    printf 'dod_title=%s\n' "$title"
    return 0
  fi
  printf '(no claim sources available)\n'
}
CLAIM_SOURCES=$(_claim_sources)

# ---- Envelope builder (Task 6.2). -------------------------------------

# build_envelope → emits the full prompt to stdout. The heading literals
# below are owned by Spec A §5; internal heuristics (bad-test, numeric
# mapping) are defined by Spec B and are allowed to be light here.
build_envelope() {
  # 6.2 Step 5: [NON_INTERACTIVE] banner for automated calls.
  if [ "$NON_INTERACTIVE" = "1" ]; then
    printf '[NON_INTERACTIVE]\n\n'
  fi

  # 6.2 Step 2: "High process gap" header when context is incomplete.
  # H1 (2026-04-22): design_state is judged on BOTH resolved path AND scope
  # items extraction success. Previous behavior judged only on raw string
  # non-emptiness, silently reporting "present" for unresolvable refs.
  # H2 (2026-04-22): plan_state flags MULTIPLE_FAIL_CLOSED when DoD carries
  # duplicate `plan ref:` lines (integration DoD is Phase 2).
  local gap_lines=""
  local plan_state="present"
  local design_state="present"
  local covers_state="present"
  local base_state="present"
  if [ -z "$PLAN_REF" ]; then
    plan_state="MISSING"
  fi
  if [ "$PLAN_REF_COUNT" -gt 1 ]; then
    plan_state="MULTIPLE_FAIL_CLOSED (using first of $PLAN_REF_COUNT)"
  fi
  if [ -z "$DESIGN_REF" ]; then
    if [ -n "$DESIGN_REF_RAW" ]; then
      design_state="MISSING (unresolved ref: $DESIGN_REF_RAW)"
    else
      design_state="MISSING"
    fi
  elif [ -z "$SCOPE_ITEMS" ]; then
    design_state="UNUSABLE (resolved to $DESIGN_REF but no '## Scope Items' section)"
  fi
  [ -z "$COVERS" ] && covers_state="MISSING"
  [ -z "$DIFF_BASE" ] && base_state="MISSING"
  if [ "$plan_state" != "present" ] || [ "$design_state" != "present" ] \
     || [ "$covers_state" = "MISSING" ]; then
    cat <<HDR
High process gap — required context missing:
- plan_ref: ${plan_state}
- design_ref: ${design_state}
- covers: ${covers_state}
- diff_base: ${base_state}
Proceed with partial checks only.

HDR
  fi

  # Preserve caller prompt body (spec-review marker etc.) immediately
  # after any gap header. The marker must stay in the envelope so the
  # downstream reviewer (real codex) sees the same context the wrapper
  # used for mode detection.
  if [ -n "$PROMPT_BODY" ]; then
    printf '%s\n\n' "$PROMPT_BODY"
  fi

  # 6.2 Step 3: 4 fixed slots.
  cat <<'SLOTS'
Required review sections (모두 응답에 포함해야 한다):

1. Code defects and regressions
   - 기존 코드리뷰 체크 (look-ahead, 타입, 경계, resource leak 등)

2. Design Alignment  [Spec B policy]
   각 active DoD covers 의 Scope ID 에 대해 아래 4 status 중 하나로 분류 + 근거 제시:

   - MATCH: 해당 ID 가 기술한 entity/direction/scenario 가 diff 의 코드 변경 또는
            test 변경에서 명확히 반영됐다. direction 의 부등호/boolean/exact
            값이 assertion 이나 조건문에 관찰됨.
   - PARTIAL: entity 는 반영됐으나 direction/scenario 중 일부가 누락.
   - MISSING: 해당 ID 를 구현해야 하는 commit 인데 diff 에 entity 관련 변경이 없음.
   - CONTRADICTS: direction 이 반대로 구현됨. 예: design 이 "A < B" 인데
                  코드/test 가 "A == B" 또는 "A > B".

   covers 외 Scope ID 는 "out of scope of this change".

   TO-scope-id-measurable-contract-required 자기 강제: Scope ID 자체가
   direction/scenario 가 결여된 서술이면 MEDIUM 으로 플래그 ("ID 포맷 미달").
   bad ID 가 slot 을 오염시키는 것을 막는다.

3. Test Alignment  [Spec B policy — 단일 deterministic rule, parent/child 분리 구조 사용 금지]

   --- Step 1: Status 판정 ---

   test 함수 이름이 design term (mode name, state name, action name 등) 을
   사용하는가? 예: test_caution_*, test_defense_*, test_rotation_bearish_*.

   사용하면 assertion 을 design 의 해당 term 정의와 대조하여 status 분류:

   - MATCH: assertion 이 design 의 서술과 같은 방향/값
   - PARTIAL: assertion 이 term 의 일부만 검증
   - CONTRADICTS: assertion 이 design 이 명시한 동작과 상충 — 다음 중 하나:
     * 방향 반전 (design 이 A < B 인데 assertion 이 A > B 또는 A == B)
     * 임계값 누락 (design 이 수치 threshold 를 요구하는데 assertion 이 equality 만)
     * same-result 패턴 (expected == <other_mode_literal> 또는 다른 mode 의 상수와
       일치) — 단, same-result 는 design 이 divergence 를 요구하는 경우에만
       CONTRADICTS. design 이 두 mode 의 동일 결과를 허용하거나 divergence
       요구가 없으면 MATCH (false-positive 원천 차단).

   CONTRADICTS 는 status 일 뿐 severity 가 아님. severity 는 Step 2 로 결정.

   --- Step 2: Severity 판정 (corroboration matrix) ---

   status = MATCH 또는 PARTIAL: Low signal, detection log 기록 안 함.

   status = CONTRADICTS: test 에서 3 요소 추출 후 corroboration 으로 severity 결정:

   - test_entity: test 함수명에서 design term 부분 (예: test_caution_nav_* → "caution-nav")
   - test_direction: assertion 이 요구하는 방향 (부등호, boolean, exact value)
   - test_scenario: test 함수명/fixture/parameter 에서 추출된 scenario token
                    (예: *_s1_2020_03_* → "s1-2020-03")

   3 요소 중 하나라도 추출 불가능하면 corroboration 0 으로 처리 (fail-safe).

   Corroboration 출처 3 종 — 각 출처에서 entity + direction + scenario
   세 축이 모두 일치해야 1 건으로 count:

   1. design 서술체: design 본문이 test_entity 의 direction 을 명시 + test_scenario
      를 언급. generic 서술 (scenario 미언급) 은 scenario 축 fail → count 안 됨.
      다른 scenario 서술도 scenario 불일치 → count 안 됨.
   2. design Scope Items: test_entity prefix + test_direction keyword + test_scenario
      suffix 를 모두 포함하는 Scope ID 존재. scenario 다른 ID 는 count 안 됨.
   3. plan matrix covers: active DoD covers 에 출처 2 의 entity+direction+scenario
      일치 Scope ID 가 implemented 로 포함. 애매한 match 는 권한 없음 (fail-safe).

   severity matrix:
   | corroboration 건수 | severity |
   |------------------|----------|
   | 0                | Low signal, detection log ONLY (envelope 에 기록, verdict = warning) |
   | 1 이상           | High (corroboration 증거를 envelope 에 인용)                       |

   예시 1 (High — corroboration 1): design 본문 "CAUTION 은 S1 2020-03 에서
   ATTACK 보다 drawdown 작다" + Scope ID "caution-nav-drawdown-less-than-attack-in-s1-2020-03"
   존재. test_caution_nav_drawdown_less_than_attack_in_s1_2020_03 이 nav_caution
   == nav_attack 를 assert → CONTRADICTS + corroboration 2 출처 매칭 → High.

   예시 2 (Low signal): design 이 두 mode 동일 결과를 허용. test_caution_mode_nav
   이 nav == 101_000_000 assert → status 는 MATCH (divergence 요구 없음). 기록
   대상 아님.

4. Claim Audit  [Spec B policy]

   1. Claim 에 숫자가 포함된 경우 (예: "3 선행지표", "5단계 포지션", "4 ETF 쌍"):
      - 각 숫자 항목에 대해 코드/config/design 에서 1:1 mapping 을 찾아 제시.
      - 예: "3 선행지표" → 선행지표 1 (path), 선행지표 2 (path), 선행지표 3 (path).
      - mapping 이 불완전하면 High severity.

   2. 기능 이름 claim (예: "CAUTION mode 구현 완료"):
      - 해당 mode/기능의 Scope ID 가 active DoD covers 에 존재하는지 확인.
      - 존재 + Design Alignment MATCH → 통과.
      - 존재 + MISSING/CONTRADICTS → High.

   3. Matrix `deferred` 행의 사유:
      - plan matrix 의 deferred 행 "위치/사유" 가 PR/commit claim 과 일치하는가?
      - changelog 에 언급된 항목인데 matrix 에 없으면 "claim vs tracking drift" High.

   4. Claim source 우선순위 (Spec A GI-codex-review-context-assembly 에서 주입):
      PR title/body > HEAD commit > DoD/plan top > (pre-commit) "unavailable"

SLOTS

  # 6.2 Step 4: structured context block.
  cat <<CTX
---
Context:

diff_base: ${DIFF_BASE}
active_dod_tier: ${SAD_TIER}
active_dod_path: ${SAD_PATH}
active_dod_reason: ${SAD_REASON}
plan_ref: ${PLAN_REF:-(none)}
design_ref: ${DESIGN_REF:-(none)}

covers (from DoD):
${COVERS:-(none)}

scope_items (from design):
${SCOPE_ITEMS:-(none)}

changed_files (${DIFF_BASE}..HEAD):
${CHANGED_FILES:-(none)}

claim_sources:
${CLAIM_SOURCES}
---
CTX
}

# ---- Codex invocation (Task 6.3). -------------------------------------

CODEX_BIN="${CODEX_BIN:-codex}"

# Verdict parser. Stdout search order: REJECT > NEEDS-FIX > PASS.
_parse_verdict() {
  local out="$1"
  if printf '%s' "$out" | grep -qiE '^[[:space:]]*REJECT\b'; then
    printf 'REJECT'
  elif printf '%s' "$out" | grep -qiE '^[[:space:]]*NEEDS[-_ ]?FIX\b'; then
    printf 'NEEDS-FIX'
  elif printf '%s' "$out" | grep -qiE '^[[:space:]]*PASS\b'; then
    printf 'PASS'
  else
    # Unknown verdict → treat as NEEDS-FIX (conservative).
    printf 'NEEDS-FIX'
  fi
}

# Invoke codex. stdin = envelope. stdout = verdict body.
_invoke_codex() {
  # Use `exec` subcommand by default (same as SKILL.md examples).
  "$CODEX_BIN" exec "$@" || return $?
}

# ---- Stamp writer (Task 6.3 Step 3). ----------------------------------

# write_code_review_stamp <verdict> <reviewer>
#   Only invoked when REIN_REVIEW_MODE="code-review" AND verdict="PASS".
#   Creates trail/dod/.codex-reviewed with the mandatory fields,
#   including diff_base: (GI-codex-review-diff-base).
write_code_review_stamp() {
  local verdict="$1"
  local reviewer="${2:-codex}"
  local stamp="$PROJECT_DIR/trail/dod/.codex-reviewed"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cycle=""
  if [ -n "$SAD_PATH" ]; then
    cycle=$(basename "$SAD_PATH" .md | sed 's/^dod-//')
  fi
  mkdir -p "$(dirname "$stamp")"
  cat > "$stamp" <<STAMP
reviewed_at: ${ts}
reviewer: ${reviewer}
diff_base: ${DIFF_BASE}
verdict: ${verdict}
cycle: ${cycle}
scope: wrapper-generated
active_dod: ${SAD_PATH}
STAMP
  # Clear .review-pending only in code-review mode (never in spec-review).
  rm -f "$PROJECT_DIR/trail/dod/.review-pending" 2>/dev/null || true
}

# ---- Main orchestration. ----------------------------------------------

# Run only when invoked directly (not sourced) so tests of individual
# functions remain feasible. The `BASH_SOURCE[0]` vs. `$0` check is the
# canonical portable idiom.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Build envelope.
  ENVELOPE=$(build_envelope)

  # Invoke codex (real or fake via CODEX_BIN).
  CODEX_OUT=""
  CODEX_RC=0
  # Assemble optional codex flags from parsed markers.
  #   REIN_EFFORT → --config model_reasoning_effort="<level>" (TOML-quoted).
  # Empty array is safely expanded with ${arr[@]+...} under `set -u`.
  CODEX_ARGS=()
  if [ -n "$REIN_EFFORT" ]; then
    CODEX_ARGS+=(--config "model_reasoning_effort=\"$REIN_EFFORT\"")
  fi
  # Feed envelope on stdin. Args forwarded to `codex exec` via _invoke_codex.
  if ! CODEX_OUT=$(printf '%s' "$ENVELOPE" | _invoke_codex ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} 2>&1); then
    CODEX_RC=$?
    # Best-effort: emit output so caller can see what went wrong.
    printf '%s\n' "$CODEX_OUT"
    echo "ERROR: [codex-review] codex invocation failed (exit $CODEX_RC)." >&2
    exit "$CODEX_RC"
  fi

  # Emit codex output unchanged for the caller.
  printf '%s\n' "$CODEX_OUT"

  # Parse verdict.
  VERDICT=$(_parse_verdict "$CODEX_OUT")

  # Mode-aware stamp handling.
  if [ "$REIN_REVIEW_MODE" = "code-review" ]; then
    if [ "$VERDICT" = "PASS" ]; then
      write_code_review_stamp "$VERDICT" "codex"
    fi
    # NEEDS-FIX / REJECT → no stamp.
  else
    # spec-review mode (CRITICAL): never write .codex-reviewed, never
    # touch .review-pending. The caller (plan-writer) is responsible for
    # writing the spec-review stamp via scripts/rein-mark-spec-reviewed.sh.
    :
  fi

  # Signal verdict via exit code for scripted callers.
  case "$VERDICT" in
    PASS) exit 0 ;;
    NEEDS-FIX) exit 1 ;;
    REJECT) exit 2 ;;
    *) exit 1 ;;
  esac
fi
