# Plugin cache rebuild 검증 (Option C 후속)

- 날짜: 2026-05-14
- 유형: verification (no source edit, trail-only)
- plan: `~/.claude/plans/gentle-shimmying-riddle.md` (approved)
- evidence: `trail/decisions/2026-05-14-plugin-cache-verification-evidence.md`

## 요약

codex-ask Mode B 가 "Option C 검증 = partial, published plugin (cache) 동작 unverified" 짚음 → `/plugin uninstall + install` 로 cache 강제 rebuild → 5 invariant + 12 test 모두 PASS → **sound** 로 정정.

## 핵심 발견

1. **directory source marketplace 는 install snapshot 기반** (hot-reload 아님). cache 가 hook 의 실제 실행 source. install 시점에 working tree → cache full copy.
2. **`/plugin marketplace update`** 는 marketplace metadata 만 갱신, cache rebuild 안 함.
3. **가장 안전한 cache 갱신**: `/plugin uninstall + install` (deterministic, no version bump).
4. **`gitCommitSha`** 는 install 시점에 working tree HEAD 정확히 기록 → cache freshness 의 결정적 신호.

## 변경 파일

- `trail/decisions/2026-05-14-plugin-cache-verification-evidence.md` (신규, 검증 evidence)
- `trail/inbox/2026-05-14-plugin-cache-rebuild-verification.md` (본 파일)
- `trail/index.md` (다음 진입점 갱신)

## 결론

Option C Phase 1~5 + 검증 모두 sound. 본 cycle 의 모든 결과가 published plugin 으로 정상 ship 가능.
