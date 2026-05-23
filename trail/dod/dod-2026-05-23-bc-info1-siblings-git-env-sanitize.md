# DoD — BC-INFO1-siblings: sibling hook libs git env sanitize (defense-in-depth)

- 날짜: 2026-05-23
- 유형: fix
- Scope ID: BC-INFO1-siblings-git-env-sanitize

## 문제 (Symptom)

BC-INFO1(v1.3.6) 은 `bootstrap-check.sh` cold-path 만 sanitize. 동일한 unsanitized
`git rev-parse --show-toplevel` 패턴이 sibling hook lib 3곳에 잔존 → 오염된 git 환경변수가
엉뚱한 repo 를 project_dir 로 latch 할 수 있는 동일 취약점. (2026-05-23 security review INFO-1)

## Root cause

`project-dir.sh`(line 57, 92, + Step 5 SCRIPT_DIR 앵커), `state-machine.sh`(line 36),
`test-oracle-log.sh`(line 57) 의 `git rev-parse --show-toplevel` 호출이 env-sanitize 미적용.

## 수정 범위 (DoD 항목)

- [ ] 각 sibling lib 의 `git rev-parse --show-toplevel` 호출에 bootstrap-check 와 동일한
      `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE` 적용
- [ ] `GIT_CEILING_DIRECTORIES` 보존 (bootstrap-check 패턴과 일치)
- [ ] project-dir.sh Step 5 의 SCRIPT_DIR 앵커 의미 유지하면서 sanitize 추가
- [ ] 각 파일이 단일 사본임을 확인 (scripts/ 또는 .claude/ 사본 없음)
- [ ] 가능한 곳에 cold-path env-pollution 회귀 테스트 추가
- [ ] 기존 테스트 회귀 없음 (test-state-machine, test-project-dir*, test-oracle-* 등)
- [ ] bash -n clean

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  기계적 sanitize(BC-INFO1 패턴 적용). state-machine.sh(Area C 민감)·project-dir.sh(resolver)
  주의. codex/security review + integration 은 orchestrator 가 처리.
approved_by_user: true
```
