# Changelog

> **Versioning policy**: 버전 bump 는 `.claude/rules/versioning.md` 의 Rule A/B/C 를 따른다.

## v1.0.3 — 2026-05-11 (Mirror tag hygiene + rein.sh cleanup)

- **Public release tarball hygiene** — mirror workflow 가 release tag 도 strip 적용된 tree 로 force retag 한 뒤 push합니다. 신규 release (v1.0.3+) 부터 GitHub release `Source code (zip/tar.gz)` 안에 maintainer-only workflow (`daily-trail-audit.yml`, `repo-audit.yml`, `weekly-agent-evolution.yml`) + dev-only rule (`legacy-shipped-pending.md`) 가 포함되지 않습니다. 기존 v1.0.0~v1.0.2 tag 는 그대로 두며, 재게시 (retag) 는 별도 결정 사항.
- **`rein update` 메시지 미세 정정** — `claude plugin update rein-core` → `rein` (plugin manifest 의 `name` 과 정합).

Internal: `scripts/rein.sh` 의 약 1,335 줄 dead code 제거 — v1.0.0/v1.0.1/v1.0.2 거치며 `cmd_init`/`cmd_merge`/`cmd_update`/`cmd_remove` 가 단순화 또는 제거되며 caller 0 가 된 helper 약 30 개 + 7 dead globals + `rein_manifest_helper`/`rein_path_match_helper` 두 dead resolver (v1.0.2 에서 가리키는 Python 파일 삭제됨) 정리. 의존하던 stale 테스트 3 개 (`test-state-helpers.sh` / `test-gitignore-entries.sh` / `test-is-text-file.sh`) 삭제.

[v1.0.2 release notes](#v102--2026-05-11-claude-performance-hooks).

## v1.0.2 — 2026-05-11 (Claude performance hooks)

세션 시작/편집 hook 의 응답성을 개선하는 patch.

- **SessionStart 헤더 압축 + skill/MCP scan cache** — `trail/index.md` + skill 인벤토리 주입 시 cache 활용으로 lean SessionStart 응답속도 단축.
- **post-edit dispatcher 통합** — 7개 post-edit hook 을 단일 `post-edit-dispatcher.sh` 로 묶어 sub-hook fan-out 비용 절감 (Read tool 트리거에서는 post-edit hook 자체 skip).
- **policy profile (`lean` / `standard` / `strict`)** — `.rein/policy/hooks.yaml` 의 `profile:` 키로 hook 활성 범위 토글. lean = 단순 탐색/문서 작업용 (plan-coverage/spec-review-gate/dod-routing-check off).
- **trail-rotate early skip** — 하루 1회 실행 marker 가 fresh 하면 즉시 종료.
- **`rein-policy-loader.py` 신설** — profile + per-hook 토글 resolution 의 SSOT.

Internal: `scripts/rein-manifest-v2.py` + `scripts/rein-path-match.py` 제거 (v1.0.1 의 scaffold drop 으로 caller 0). `scripts/rein-bootstrap-project.py` 신설 (plugin-mode bootstrap 진입점).

[v1.0.1 release notes](#v101--2026-05-11-scaffold-drop-completion).

## v1.0.1 — 2026-05-11 (Scaffold drop completion)

v1.0.0 launch 의 declarative scaffold drop 을 코드 차원에서 완결합니다.

- `rein init` 명령 제거 — `init` / `init --mode=plugin` / `init --mode=scaffold` 모두 `unknown command 'init'` + exit 1 로 응답합니다. 설치는 Claude Code plugin marketplace 흐름만 사용합니다 (`/plugin marketplace add JayJihyunKim/rein` + `/plugin install rein@rein`).
- `rein migrate` 명령 제거 — v1.x scaffold → plugin 마이그레이션 helpers (`rein-migrate.sh` 등) 가 함께 사라집니다. v1.0.0 시점 사용자 베이스 0 가정 기반의 hard cut.
- repo root 의 `install.sh` 제거 — `curl|bash` 설치 흐름이 사라집니다. README / Windows troubleshooting 도 plugin marketplace 흐름으로 갱신.
- 사용자 repo 의 router state 디렉토리가 `.claude/router/` → `.rein/policy/router/` 로 이동합니다. `rein-route-record.py` 는 legacy `.claude/router/` 를 더 이상 fallback 으로 받지 않습니다 (hard-fail).
- README 의 "Claude scaffolds" 표현 + `.claude/settings.json` 자동 생성 안내 제거. plugin marketplace 흐름에 맞춰 KR/EN 동기화.

[v1.0.0 launch](#v100--2026-04-30-plugin-only-oss-launch) 의 deferred 항목을 단일 patch 로 ship 했습니다. user-facing 변경은 위 5 줄이며, 내부 정리 (migrate helpers / drift checker 어휘 / mirror strip 확장 / superseded 배너) 는 dev-only 라 본 entry 에 포함하지 않습니다.

## v1.0.0 — 2026-04-30 (Plugin-only OSS launch)

- 정식 OSS launch 의 첫 버전.
- Claude Code plugin 모드 (rein-core / rein-stitch / rein-react / rein-remotion) 가 유일한 install 경로. scaffold 모드 / `rein init --mode=scaffold` / `rein remove --path` 는 제거됨.
- 이전 dev cycle history (v0.x ~ v2.0.0) 는 [archive](docs/changelog-archive/2026-04-pre-v1.md) 를 참조.
