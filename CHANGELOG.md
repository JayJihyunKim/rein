# Changelog

## v0.8.0 (2026-04-XX) — Core Harness Purity

### Breaking changes

- **Stitch / shadcn 도메인 스킬 번들 해제**: `.claude/skills/` 에서 stitch-design, stitch-loop, taste-design, design-md, enhance-prompt, react-components, remotion, shadcn-ui 제거. rein 코어는 도메인·언어 무관.
- **StitchMCP 하드 의존 제거**: `.claude/settings.json` 의 `mcp__StitchMCP__*` 권한 + `mcpServers.StitchMCP` 블록 제거.
- **에이전트 정리**: `service-builder`, `reviewer` 제거. `plan-writer` 신규 추가. 최종 에이전트 5 개 = feature-builder, plan-writer, researcher, docs-writer, security-reviewer.
- **훅 이름·구조 변경**:
  - `inbox-compress.sh` → `trail-rotate.sh` (1-release wrapper alias 유지)
  - `post-edit-lint.sh` 이분할: `post-edit-hygiene.sh` (언어중립) + `post-edit-lint.sh.example` (언어별 autofix 템플릿)
  - `task-completed-incident.sh` 제거 — 기능은 `stop-session-gate.sh` 내부 helper 로 통합
- **AGENTS.md `/codex` fallback 체인**: `superpowers:code-reviewer` → rein 자체 `code-reviewer` 스킬 (외부 플러그인 미의존).

### Added

- `.claude/skills/writing-plans/` — rein 자체 plan 작성 스킬 (superpowers:writing-plans 대체).
- `.claude/skills/code-reviewer/` — rein 자체 코드 리뷰어 스킬 (/codex 장애 시 fallback).
- `.claude/agents/plan-writer.md` — design → plan 변환 전담.
- `scripts/rein-aggregate-incidents.py advisory-summary` — per-pattern/session 집계 CLI.
- `scripts/rein-route-record.py doctor` — legacy feedback-log / overrides 엔트리의 invalid_ids 자동 이관.
- `.session-start-line` stamp — stop-session-gate helper 가 세션 범위 advisory 를 계산하는 기준.

### Changed

- `.claude/router/registry.yaml` `excluded_patterns` 를 description 키워드 기반으로 재설계 (`superpowers:*` 하드코딩 제거).
- `scripts/rein-route-record.py` 가 agent/skill id 를 실제 저장소와 대조 검증. 무효 id 는 `invalid_ids` top-level 필드로 분리 (하위 호환).
- `stop-session-gate.sh` 에 `incident_advisory_check()` helper — 자기진화 파이프라인(2회→rule, 3회→agent) 권장 메시지를 stderr 로 출력.

### Migration

v0.8.0 으로 업그레이드 후 1회 실행:

```bash
python3 scripts/rein-route-record.py doctor
```

→ 기존 `feedback-log.yaml` / `overrides.yaml` 의 stale id 가 `invalid_ids` 로 이관됩니다.

자세한 사용자 영향: `REIN_SETUP_GUIDE.md` § Breaking changes (v0.8.0).
