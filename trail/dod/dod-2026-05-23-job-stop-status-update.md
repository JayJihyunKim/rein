# DoD — job-stop: record terminal status on `rein job stop`

- 날짜: 2026-05-23
- 유형: fix
- Scope ID: BG-job-stop-record-terminal-status

## 문제 (Symptom)

`rein job stop` 이 SIGTERM/SIGKILL 으로 프로세스를 종료하지만 job 상태 파일
(`.claude/cache/jobs/<jid>.status`, `.exit`, metadata) 은 `running` 그대로 stale 하게 남는다.
rein 의 state-machine contract 는 stop 시 `running → killed` (terminal) 전이를 요구한다.
특히 setsid 부재 경로 ("started without setsid; killing single PID only") 에서는 wrapper PID 만
죽으므로 child 의 exit 를 wrapper 가 관측하지 못해 status 가 영영 갱신되지 않는다.

## Root cause

`scripts/rein.sh` 의 `cmd_job_stop` 은 PID/process-group 만 죽이고 종료 성공 후
`.status` / `.exit` / metadata 를 갱신하지 않는다. 현재는 `cmd_job_status` 만 사후에
opportunistic 하게 stale 상태를 보정한다. stop 명령 자체가 terminal 상태를 기록해야 한다.

## 수정 범위 (DoD 항목)

- [ ] failing test 먼저: `tests/scripts/test-job-stop-posix.sh` 에 stop 후 `.status` 가 `running`
      이 아님(`killed`) + `.exit` 기록됨 assertion 추가 → 현재 코드에서 실패 확인
- [ ] `scripts/rein.sh` 에 settle helper (`_rein_job_settle_terminal`) 추가 — `.status`/`.exit`/meta
      를 atomic 하게 terminal 상태로 기록 (wrapper 의 settle 패턴 재사용, write_atomic + python meta patch)
- [ ] `cmd_job_stop` 이 종료 성공 후 settle helper 호출 (setsid 부재 경로 포함 robust)
- [ ] `bash tests/scripts/test-job-stop-posix.sh` GREEN
- [ ] `bash tests/scripts/test-job-status.sh` 회귀 없음 (GREEN)
- [ ] 기존 status vocabulary 유지 — `killed` 는 bug contract 가 명시한 terminal 용어,
      신규 임의 state 발명 아님. `.exit` 는 `128 + signal` 관례 (SIGTERM=143, SIGKILL=137)

## 상태 vocabulary 결정

코드 내 기존 vocabulary: `running`, `success`, `failed`, `unknown_dead`.
externally-terminated job 은 organic `success`/`failed` 와 구분되는 terminal 상태가 맞다.
bug report 의 symptom + required-fix 가 명시적으로 `killed` 를 contract 용어로 지목 →
`killed` 사용 (arbitrary 신규 명칭 발명 금지 제약은 충족 — contract 가 명명한 용어).

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  Reproduction-first 버그 수정. failing test → root cause → fix → regression guard.
  단일 shell script(scripts/rein.sh) + job test 파일만 touch. codex/security review 와
  integration 은 orchestrator 가 처리하므로 skill/mcp 불필요.
approved_by_user: true
```
