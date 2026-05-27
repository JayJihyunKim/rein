# DoD — v1.3.8 hotfix: plugin.json `dependencies` key 제거

- 시작일: 2026-05-27
- 유형: hotfix (release-blocking install failure)
- 사유: Claude Code 최신 클라이언트가 `plugin.json` 의 비공식 키 `"dependencies"` 를 strict validator 로 거부 → `/plugin install rein@rein` 자체가 실패. v1.0.0 ~ v1.3.7 모든 plugin.json 에 잔존했던 결함. 메인테이너 macOS 환경에서는 통과되어 그동안 release 시점에 미탐지.

## 증상

사용자 보고 (Windows, 2026-05-27):

```
Error: Failed to install: Plugin has an invalid manifest file at
C:\Users\User\.claude\plugins\cache\temp_local_..\.claude-plugin\plugin.json.
Validation errors: : Unrecognized key: "dependencies"
```

## 근본 원인

`plugins/rein-core/.claude-plugin/plugin.json` 의 `"dependencies": []` 가 Claude Code 공식 plugin manifest 스키마에 정의되어 있지 않음. 공식 스키마(code.claude.com/docs/en/plugins) 허용 필드: `name`, `description`, `version`, `author`, `homepage`, `repository`, `license`. plugin 간 의존성 표현 메커니즘은 아직 공식 미지원 (관련 메모리: `reference_claude_code_plugin_schema.md`).

도입 시점: v2.0.0 plugin-first restructure (`1d01907`, 2026-04-29) — 이후 모든 release 에 잔존.

## 범위 (Scope IN)

| ID | 항목 | 검증 |
|---|---|---|
| HF-1 | `plugins/rein-core/.claude-plugin/plugin.json` 에서 `"dependencies": []` 라인 제거 + `version` 1.3.7 → 1.3.8 | `jq` parse PASS, `claude plugin validate` PASS, `dependencies` key 부재 |
| HF-2 | `scripts/rein.sh` 의 `VERSION="1.3.7"` → `"1.3.8"` (plugin.json 과 parity, 메모리 `feedback_rein_release_version_parity.md`) | `grep '^VERSION=' scripts/rein.sh` = `1.3.8` |
| HF-3 | `CHANGELOG.md` 상단에 v1.3.8 entry 1개 추가 — hotfix 사유(install 차단) + user-facing 문구 (`rein update` 사용자 관점 outcome 언어, `.claude/rules/readme-style.md` 준수) | CHANGELOG head 가 v1.3.8 (1~2 bullet) |
| HF-4 | dev → main 단방향 선별 체크아웃 후 annotated tag `v1.3.8` 생성 + push | `git tag -v v1.3.8` annotated, public mirror strip 검증 (plugin.json=1.3.8, `dependencies` 부재, `trail/`/`.rein/`/`AGENTS.md`/`.claude/` 부재) |

## 범위 (Scope OUT)

- plugin 의존성 표현 메커니즘 재설계 — 공식 스키마 부재. 추후 별도 작업.
- 다른 메타필드(`homepage`, `repository`, `license`) 추가 — 본 hotfix 범위 밖.
- `plugins/rein-core/` 내 다른 hooks/skills/agents/scripts 동작 변경 — 본 hotfix 는 manifest schema 정합성 한정.
- `rein-bootstrap-project.py` 가 사용자 repo 에 쓰는 `.claude/security/profile.yaml` 등 다른 manifest — 영향 없음.
- behavioral test 추가 — manifest schema 변경에 대한 회귀 차단은 `claude plugin validate` 가 release CI 단계에 들어가야 의미가 있으며 본 hotfix 와 별개 작업.

## 검증 기준 (Acceptance)

1. `cd plugins/rein-core && claude plugin validate` PASS (또는 동등한 manifest validation 통과 — `--plugin-dir` 로 로컬 테스트 가능).
2. `jq -e 'has("dependencies") | not' plugins/rein-core/.claude-plugin/plugin.json` PASS.
3. `plugin.json` `version` 과 `scripts/rein.sh` `VERSION` 둘 다 `1.3.8`.
4. CHANGELOG head 가 v1.3.8 entry (user-facing outcome 1~2 bullet).
5. main 머지 + annotated tag `v1.3.8` 생성. dev/main commit hash 양쪽 확보.
6. `publish-plugin.yml` + `mirror-to-public.yml` GH Actions success.
7. public mirror (`rein` 공개 repo) 의 main + tag commit 이 strip 검증 통과: `trail/`, `.rein/`, `AGENTS.md`, `.claude/` 부재. `plugins/rein-core/.claude-plugin/plugin.json` 의 `version`=1.3.8, `dependencies` 키 부재.

## 영향 / 비영향

- 영향: **신규 install 차단 해소** — 사용자 `/plugin install rein@rein` 정상화.
- 비영향: 이미 install 된 사용자 환경 동작 — manifest 는 install 시점에만 검증, runtime 동작은 hooks/skills/agents 가 담당.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
  - rein:security-reviewer  # security_tier:light 후보 — 아래 rationale 참조
mcps: []
security_tier: light
rationale: |
  - 변경 범위 = manifest 메타데이터 1줄 제거 + 두 버전 표면 동기화 + CHANGELOG 1 entry.
    실행 코드/hook 동작/사용자 입력 처리 경로 변경 없음.
  - 보안 표면: plugin.json 은 정적 JSON, secret/injection/path traversal 경로 없음.
    `dependencies` 필드는 이전부터 무시되던 inert 데이터. 제거가 외부 동작 변경 없음.
  - feature-builder-fix: 버그 수정 전담(install 차단=bug). reproduction = manifest validator 가 reject.
  - codex-review: 필수 (commit gate). diff 가 작아 NEEDS-FIX 가능성 낮음.
  - security-reviewer: security_tier:light + approved_by_user 로 stamp 면제 후보. 단 사용자 승인 필요.
approved_by_user: true   # 승인: 2026-05-27, security_tier:light 면제 채택
```

> 사용자 결정 (2026-05-27): 라우팅 승인 + security_tier:light 면제. security-reviewer 정식 호출 대신 light tier stamp 자동 — `.codex-reviewed` 는 필수 유지.

## 단방향 머지 절차 (메모리 `feedback_branch_strategy_order.md`)

1. dev 에서 plugin.json, scripts/rein.sh, CHANGELOG.md 수정 + codex/security review + commit + push.
2. main 으로 전환 (working tree clean 확인 — 현재 dev 의 trail/incidents/active-dod-cleanup.log 변경분은 별도 commit 으로 처리하거나 stash).
3. `git checkout dev -- <변경 파일 3개>` 선별 체크아웃. **편집 금지.**
4. `.claude/CLAUDE.md` 의 메인테이너 전용 @import 라인 (`@.claude/rules/branch-strategy.md` 등) 잔존 여부 확인 → 이번에는 변경 대상 아니므로 무시.
5. main commit + annotated tag `v1.3.8` + push origin main + push origin v1.3.8.
6. publish-plugin / mirror-to-public GH Actions 결과 확인.
7. public mirror 의 main = tag commit hash 일치 + strip 검증.

## 회귀 방지 (이번 hotfix 범위 밖 — 후속 메모만)

- `claude plugin validate` 를 release CI 의 publish 전 검사 단계에 추가 — `scripts/rein-publish.sh` 또는 `publish-plugin.yml` 에 검증 step. 본 hotfix 후 별도 작업 후보 (`need-to-confirm.md` 또는 backlog 에 기록).
- 위 회귀 방지 작업이 도입되기 전까지, release 전 메인테이너가 수동으로 `cd plugins/rein-core && claude plugin validate` 1회 실행을 release 체크리스트(`.claude/rules/versioning.md`)에 추가 검토.
