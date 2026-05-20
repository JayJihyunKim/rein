#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit) — Phase 2c HK-5 본격 구현
#
# 역할 (2026-05-20 Phase 2c):
#   1) sub-hook output cache merge — 2개 envelope-emitting sub-hook
#      (post-edit-design-plan-coverage-rule, post-edit-routing-procedure-rule)
#      가 stdout 대신 cache 에 dump 한 PostToolUse envelope JSON 들을 collect
#      → additionalContext 만 추출 → "\n\n---\n\n" separator 로 concat → 단일
#      PostToolUse envelope JSON 으로 stdout 출력. lib 자체는 임의 개수의 cache
#      entry 를 merge 할 수 있는 generic contract (향후 envelope-emitting hook
#      가 추가되면 자동 포함).
#   2) cleanup — resolver-cache + output-cache 둘 다 정리
#
# 왜 file-system 매개인가:
#   SPIKE-1 측정에서 같은 matcher 의 별개 entry 들이 각자 stdout envelope 을
#   출력하면 Claude Code 는 entry 별 system-reminder 로 분리 surface. aggregator
#   가 다른 entry 의 stdout 을 직접 capture 할 수 없다. file-system 매개 cache
#   가 유일한 통합 경로 (`docs/reports/2026-05-19-cc-feature-spike.md` 참조).
#
# 본 cycle 의 scope:
#   - stdout envelope emit 하는 sub-hook 은 2개 한정 (전수 조사 2026-05-20).
#     나머지 6개 (hygiene/review-gate/spec-review-gate/plan-coverage/
#     dod-routing-check/index-sync-inbox) 는 stderr 또는 file-system write 만 —
#     dispatcher historical 본문 명시대로 stderr 는 그대로 통과, file-system
#     write 는 entry-level evaluation 영향 없음 (변경 없음).
#   - Linux 환경 race / cache-hit 실측은 본 cycle 미포함 — macOS 측정만,
#     별 cycle (OS-neutral CI test) 후보.
#
# Advisory caveats (Phase 2b 회고 + 본 cycle 유지):
#   - Race condition: Claude Code 가 PostToolUse entry 들을 병렬 실행하면 본
#     aggregator 의 cleanup 이 다른 sub-hook 의 cache write 전에 발생할 가능성.
#     SPIKE-1 측정상 entry 는 순차 실행되는 것으로 관측되지만 hard guarantee
#     미문서. 회귀 관찰 시 cleanup 시점을 Stop / SessionEnd hook 으로 이동
#     검토 (별 cycle).
#   - Cache leak: pre-edit-dod-gate 의 cache write 가 다른 gate check 통과 전
#     발생 → denied edit 의 cache 가 stale. 별 cycle 의 GC 후속 작업.
#
# Exit code: 항상 0 — aggregator 차단은 의미 없음 (sub-hook 자체 차단을 우선).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# shellcheck source=./lib/hook-input-cache.sh
. "$SCRIPT_DIR/lib/hook-input-cache.sh"
# shellcheck source=./lib/hook-resolver-cache.sh
. "$SCRIPT_DIR/lib/hook-resolver-cache.sh"
# shellcheck source=./lib/hook-output-cache.sh
. "$SCRIPT_DIR/lib/hook-output-cache.sh"

# stdin 흡수 — INPUT 변수에 보관.
hook_input_load 2>/dev/null || true

# tool_use_id 추출 — cache key.
tool_use_id=""
if [ -n "${INPUT:-}" ]; then
  if resolve_python 2>/dev/null; then
    tool_use_id=$(printf '%s' "$INPUT" | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/extract-hook-json.py" --field tool_use_id --default '' 2>/dev/null || true)
  fi
fi

# === merge — 2개 production sub-hook envelope (+ 임의 추가 cache entry) 통합 ===
# tool_use_id 없거나 python 없거나 cache 부재면 silent skip (sub-hook 들이
# stdout fallback 으로 직접 emit 한 envelope 이 entry-level surface 됨).
# 본 cycle 의 production envelope-emitting sub-hook 은 2개 (design-plan-coverage-rule,
# routing-procedure-rule). 향후 envelope hook 추가 시 별도 변경 없이 자동 포함.
if [ -n "$tool_use_id" ] && resolve_python 2>/dev/null; then
  merged=$(output_cache_collect "$tool_use_id" 2>/dev/null | "${PYTHON_RUNNER[@]}" "$SCRIPT_DIR/lib/aggregate-envelopes.py" 2>/dev/null)
  if [ -n "$merged" ]; then
    printf '%s\n' "$merged"
  fi
fi

# === cleanup — resolver + output cache 둘 다 정리 ===
# invalid id 는 각 cleanup 함수가 silent skip.
if [ -n "$tool_use_id" ]; then
  resolver_cache_cleanup "$tool_use_id" || true
  output_cache_cleanup "$tool_use_id" || true
fi

exit 0
