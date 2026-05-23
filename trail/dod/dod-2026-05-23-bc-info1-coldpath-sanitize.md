# DoD — BC-INFO1: bootstrap-check cold-path git env sanitize

- 날짜: 2026-05-23
- 유형: fix
- Scope ID: BC-INFO1-coldpath-git-env-sanitize

## 문제 (Symptom)

`plugins/rein-core/hooks/lib/bootstrap-check.sh` 에서 stdin.cwd 부재 시 (cold path = 직접 CLI
호출) `git rev-parse` fallback 이 v1.1.2 hotfix 의 env-sanitize 를 적용하지 않는다. 오염된
`GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR`/`GIT_INDEX_FILE` 가 cold path 에서 decoy repo 를
project_dir 로 latch 시킬 수 있다.

## Root cause

v1.1.2 hotfix 가 stdin.cwd walk-up 경로에만 env-sanitize 를 적용하고, cold-path fallback
`git rev-parse --show-toplevel` 은 오염 env 그대로 실행. 두 경로의 git env 신뢰 가정이 불일치.

## 수정 범위 (DoD 항목)

- [ ] failing test 먼저: `tests/hooks/test-bootstrap-check-helper.sh` 에 cold-path(무 stdin)
      env-pollution 시나리오 (Fixture J2) → 현재 코드에서 decoy latch 되어 실패 확인
- [ ] cold-path `git rev-parse` 에 stdin.cwd 경로와 동일한
      `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE` 적용
- [ ] `GIT_CEILING_DIRECTORIES` 는 양 경로 모두 보존 (policy-sensitive, caller-intended)
- [ ] `bash tests/hooks/test-bootstrap-check-helper.sh` GREEN (기존 20 + 신규 J2 = 21)

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  Reproduction-first 보안 위생 수정 (cold-path env sanitize). 단일 hook lib + 그 test 만 touch.
  codex/security review 와 integration 은 orchestrator 가 처리하므로 skill/mcp 불필요.
approved_by_user: true
```
