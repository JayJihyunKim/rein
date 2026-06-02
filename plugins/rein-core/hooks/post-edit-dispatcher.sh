#!/bin/bash
# Hook: PostToolUse(Edit|Write|MultiEdit) — dispatcher (DEPRECATED, Phase 2b)
#
# Cycle X3 (영역 E.3, plan §4.5.3, 2026-05-20): historical body removed.
# The sub-hooks have been registered as separate hooks.json entries since
# Phase 2b (HK-4); there are now 11 PostToolUse(Edit) entries (the original
# 8 + dod-routing-check + state-journal + aggregator). Claude Code's native
# entry-merge semantics replace the aggregator role this dispatcher used to
# fill. PERF-2's resolver cache
# (`lib/hook-resolver-cache.sh`) replaces the dispatcher's env-var cache.
#
# This stub is retained so that a hooks.json regression that re-registers
# the dispatcher path will not surface as "file not found" but as the
# deprecation message below. If a future cycle proves the registration has
# stayed clean for an extended period, the stub can be removed outright —
# see git history before commit e414af8 for the original implementation.

echo "[rein] post-edit-dispatcher.sh: DEPRECATED — 본 dispatcher 는 hooks.json 에서 등록 해제됐습니다 (Phase 2b HK-4 분할). 호출되는 경로가 있다면 hooks.json 을 확인하세요." >&2
exit 0
