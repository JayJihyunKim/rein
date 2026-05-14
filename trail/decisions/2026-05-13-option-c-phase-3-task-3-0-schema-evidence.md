# Option C Phase 3 / Task 3.0 — enabledPlugins schema 검증 evidence

- 날짜: 2026-05-13
- 작성자: Claude (Phase 3 Task 3.0 실행)
- plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md §Task 3.0
- DoD ref: trail/dod/dod-2026-05-13-option-c-phase-3-overlay-cleanup.md

## 목적

`.claude/settings.json` 의 `"plugins": {"rein": "^1.0.0"}` 키 형식이 Claude Code 런타임에서 유효한지, `enabledPlugins` 와의 관계는 무엇인지, `/plugin install rein@rein --scope project` 가 자동으로 추가하는 키 형식은 무엇인지 공식 docs 로 검증.

## Source

- Context7 MCP query — library `/websites/code_claude` (Source Reputation: High, Benchmark Score: 81.68)
- WebFetch — `https://code.claude.com/docs/en/plugin-marketplaces` (53KB), `https://code.claude.com/docs/en/plugins-reference` (63.6KB)
- 검증 시각: 2026-05-13

## 인용 (verbatim)

### Plugin marketplaces docs (`/en/plugin-marketplaces`, line 556–565)

> You can also specify which plugins should be enabled by default:
>
> ```json
> {
>   "enabledPlugins": {
>     "code-formatter@company-tools": true,
>     "deployment-tools@company-tools": true
>   }
> }
> ```
>
> For full configuration options, see [Plugin settings](/en/settings#plugin-settings).

### Plugins reference docs (`/en/plugins-reference`, line 751)

> Scope determines which settings file the installed plugin is added to. For example, `--scope project` writes to `enabledPlugins` in .claude/settings.json, making the plugin available to everyone who clones the project repository.

### Seed compose 노트 (`/en/plugin-marketplaces`, line 607)

> Composes with settings: if `extraKnownMarketplaces` or `enabledPlugins` declare a marketplace that already exists in the seed, Claude Code uses the seed copy instead of cloning.

## 판정

| 질문 | 결론 | 근거 |
|---|---|---|
| (1) `"plugins": {"rein": "^1.0.0"}` 가 유효한 schema 인가? | **NO (docs 미언급)** | settings docs / marketplace docs / plugins-reference docs 어디에도 `"plugins"` (object with semver) 키는 등장하지 않음. silently ignored 일 가능성 높음 (parse 단계에서 unknown key 는 reject 되지 않음). |
| (2) 공식 키는 무엇인가? | **`enabledPlugins`** (object, `<plugin>@<marketplace>: true`) | marketplace docs line 558–565 명시. |
| (3) `/plugin install rein@rein --scope project` 의 효과? | `.claude/settings.json` 의 `enabledPlugins` 에 `"rein@rein": true` 추가 | plugins-reference docs line 751 명시. |
| (4) `enabledPlugins` 와 `plugins` 가 alias 또는 deprecated 관계인가? | **alias 아님. `plugins` 는 비공식 키** | 공식 docs 에 `plugins` 키 정의 없음. JSON schema 미공개 (json.schemastore.org/claude-code-settings.json 참조 권고만). |

## 영향 — Phase 3 진입 전 사전 변환 필요 여부

plan §Task 3.0 마지막 줄: "만약 schema 가 invalid 하면 Phase 3 진입 전 `.claude/settings.json` 의 `"plugins"` 키를 적절한 형식 (예: `"enabledPlugins": ["rein"]`) 으로 사전 변환."

plan 의 예시 `["rein"]` (배열) 은 **부정확** — 공식 형식은 object `{"rein@rein": true}`. 결정 옵션:

### 옵션 A — install 에게 위임 (보수적, 권고)

1. `"plugins": {"rein": "^1.0.0"}` 키는 현재 silently ignored 상태로 두고, Task 3.1 (`/plugin install rein@rein`) 를 실행
2. install 가 `enabledPlugins: {"rein@rein": true}` 를 추가 (관찰 후 확인)
3. install 완료 후 잔존 `"plugins"` 키만 별도 cleanup commit

**장점**: install 의 실제 동작이 source of truth. 가정 오류 가능성 0.
**단점**: settings.json 에 일시적으로 inert noise (`plugins` 키) 와 공식 키 (`enabledPlugins`) 가 공존.

### 옵션 B — 사전 변환

1. Task 3.1 진입 전에 `.claude/settings.json` 을 `"plugins"` 제거 + `"enabledPlugins": {"rein@rein": true}` 사전 작성
2. install 가 idempotent 라면 같은 키를 재기록 (또는 skip)

**장점**: settings.json 이 항상 깨끗한 상태.
**단점**: install 실제 동작을 사전 가정. install 가 다른 키도 만들거나 `enabledPlugins` 형식이 약간 다르면 (예: scope-specific) drift 발생.

## 권고

**옵션 A**. 근거:
- install 실제 동작은 docs 가 형식만 명시하고 idempotency / 충돌 처리는 미명시. 사전 가정 위험.
- 현재 `"plugins"` 키는 v1.0.0 release 시점부터 운영 중인 inert noise — 즉각 제거가 Phase 3 의 success criterion 이 아님 (S4/S5/S6/S7 어디에도 포함 안 됨).
- Task 3.1 install 후 Task 3.2 의 `/hooks` 확인 단계에서 settings.json 의 실제 변경을 관찰한 뒤, Task 3.3 (overlap hook 제거) 와 함께 `"plugins"` 키도 같은 commit 에 cleanup 으로 묶으면 atomicity 보존.

## 후속 액션

1. Task 3.0 마무리 — 본 evidence 파일 + DoD 검증 체크 추가
2. Task 3.1 진입 — `/plugin marketplace add file://...` + `/plugin install rein@rein --scope project` (scope project 명시; default user 는 사용자 글로벌 ~/.claude/settings.json 에 쓰일 수 있음)
3. Task 3.2 후 settings.json 실측 → `enabledPlugins` 키 등장 확인 + `"plugins"` 키 cleanup 시점 결정
