# Plugin cache artifact 검증 evidence (Option C 후속)

- 날짜: 2026-05-14
- 작성자: Claude (메인테이너 환경 검증)
- plan ref: `~/.claude/plans/gentle-shimmying-riddle.md` (approved)
- 동기: codex-ask Mode B (gpt-5.5/high) 의 second opinion — "Option C 검증은 dogfood OK 지만 published/cache 동작 unverified, partial"

## 검증 절차 (실측)

### Step 1 — `/plugin uninstall rein@rein`

- 사용자 슬래시 명령 실행: "✔ Successfully uninstalled plugin: rein (scope: local)"
- 결과: `installed_plugins.json` 의 `rein@rein` entry 제거. cache 디렉토리 (`~/.claude/plugins/cache/rein/rein/1.1.2/`) 도 제거 (entry 만 보면 안 보이게, 다음 install 가 새로 만듦).

### Step 2 — `/plugin install rein@rein`

- 사용자 슬래시 명령 실행: "✓ Installed rein. Run /reload-plugins to apply."
- 새 cache 생성:
  - `installedAt: 2026-05-14T01:24:16.345Z`
  - `lastUpdated: 2026-05-14T01:24:16.345Z`
  - `gitCommitSha: 2932f7aadc0a188e8c22702803263355b7a1c78d` ← **dev HEAD 와 정확히 일치**

### Step 3 — 세션 재시작 (`claude -c`)

- SessionStart context 의 banner 가 새 path 표기: `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md, plugin source`
- → 새 cache 가 hook 실행 source 로 active (Phase 4 Task 4.4 redirect 반영)

### Step 4 — cache invariant 5/5 PASS

| # | invariant | 측정 결과 |
|---|---|---|
| 1 | cache mtime 본 cycle 시점 | `May 14 10:24:16 2026` (vs 어제 `May 13 14:02`) |
| 2 | `session-start-load-trail.sh:187` Phase 4 redirect | `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md, plugin source` |
| 3 | `docs/` 가 Phase 4 Task 4.1 cleanup 반영 | `overflow-handoff.md` 만 잔존 (rules/ 부재) |
| 4 | `design-plan-coverage.md` 첫 section | `## 행동 강령` (Phase 3 Round 1 mandate fix) |
| 5 | `gitCommitSha = dev HEAD` | `2932f7a` match |

### Step 5 — runtime 검증 PASS

- `python3 scripts/rein-check-plugin-drift.py` → OK (boundary + parity + validation)
- `bash tests/scripts/test-rein-check-plugin-drift-boundary.sh` → pass=8 fail=0
- 4 hook registered test (`test-{background-jobs,design-plan-coverage,subagent-review,legacy-pending-heal}-registered.sh`) → 모두 OK
- PreToolUse:Bash 의 `Background Jobs` rule context inject → 정상 (새 cache 의 plugin hook 작동)

## codex-ask 결론과의 대응

| codex-ask Mode B 질문 (4 verdicts) | 본 검증 후 |
|---|---|
| Hot-reload 해석 verified, with caveat (Anthropic docs 와 다른 behavior 가능성) | ✅ **resolved** — directory source 는 cache 기반 (hot-reload 아님). hook source = cache. SessionStart banner 가 working tree 와 일치한 건 cache rebuild 가 working tree 를 copy 한 결과 |
| Hidden risk concern | ⚠ partially resolved — `/plugin install` 시점에 working tree → cache 로 copy. dirty working tree 가 cache 에 그대로 들어가는 risk 는 여전. 메인테이너는 install 전 git status clean 확인 + commit 권고 |
| `gitCommitSha` inert? | ✅ **provenance + fresh signal** — install 시점에 정확히 working tree HEAD 기록. `marketplace update` 시 sync 안 되는 것이 stale 의 원인. install 마다 정확함 |
| Option C 1~5 검증 완료? concern → partial | ✅ **sound** — 본 cycle 의 cache rebuild + 5 invariant 검증 + drift+test 12개 모두 PASS |

## 학습 — directory source marketplace 의 cache lifecycle

| 명령 | cache 갱신 효과 |
|---|---|
| `/plugin marketplace update` | ❌ marketplace metadata (`known_marketplaces.json` 의 `lastUpdated`) 만. cache rebuild 안 함 |
| `/plugin install <p>@<m>` (entry 없을 때) | ✅ working tree → cache full copy. `gitCommitSha` 기록 |
| `/plugin uninstall <p>@<m>` | ✅ entry + cache 전체 삭제 |
| `plugin.json` version field 변경 + `/plugin marketplace update` | ✅ Claude Code 가 version mismatch 감지해 cache rebuild trigger |

**가장 안전한 cache 갱신**: `/plugin uninstall` + `/plugin install` (no version bump 필요, deterministic).

## 결론

Option C Phase 1~5 + dogfood + cache rebuild + 5 invariant + 12 test 모두 PASS. published plugin 동작 검증 완료. codex-ask 의 "partial" 우려 해소.

본 검증으로 알게 된 것 — directory source marketplace 는 **install snapshot 기반** (hot-reload 아님). 메인테이너가 plugin source 편집 시 working tree 만 바뀌고 cache 는 stale → `/plugin uninstall + install` 필수 (또는 version bump).

다음 cycle 후보 (변경 없음): trail/index.md 의 기록 유지.
