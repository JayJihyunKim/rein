# Background Jobs — 긴 sync 작업은 `rein job` 을 사용하라

> 이 규칙은 Claude Code 세션이 긴 동기 명령으로 **턴을 붙잡는 것**을 막기 위해 존재한다. 규칙 허브(`@.claude/CLAUDE.md`) 에서 자동 로드된다.

---

## 금지 패턴

- 긴 sync 명령(`pytest`, `npm test`, `cargo build`, backtest 시뮬레이션, integration E2E 등)을 foreground 로 실행해 Claude 세션을 붙잡기
- `BashOutput` 같이 **세션 단위**로 상태를 들고 가는 방식으로 턴 경계를 넘는 상태를 보관하기 — BashOutput 은 지금 세션이 끝나면 사라진다. rein job 은 파일 기반이라 세션을 넘어 살아남는다
- "그냥 `&` 로 백그라운드 돌리자" — PID/log/status 가 분산되어 stop/tail 이 어렵고 reparenting 도 불안정

## 권장 패턴

```bash
# 1. 시작 (argv transport 기본 — shell 확장 없이 그대로 실행)
rein job start test-suite -- pytest tests/

# 2. Claude 는 다른 작업 진행 — 세션이 붙잡히지 않는다

# 3. 상태 확인 (running → success/failed/unknown_dead)
rein job status test-suite-1712345678-ab12

# 4. 실시간/완료 후 로그 (기본 50줄, --lines 로 더 많이)
rein job tail test-suite-1712345678-ab12 --lines 100

# 5. 현재 running + 최근 finished 목록
rein job list

# 6. 취소 (POSIX: SIGTERM → SIGKILL escalation, MINGW: taskkill /F /T)
rein job stop test-suite-1712345678-ab12
```

## Shell 확장이 필요할 때

argv transport 가 기본이어서 `$HOME` 같은 메타 문자는 **literal** 로 전달된다. 파이프/리다이렉션/변수 확장이 필요하면 `--shell` opt-in:

```bash
rein job start backup --shell -- 'rsync -av $SRC/ /backup/ | tee /tmp/rsync.log'
```

`--shell` 은 신뢰할 수 있는 입력에만 써야 한다. 외부 입력을 interpolate 하면 shell 인젝션으로 바로 직결된다.

## 파일 상태 레이아웃

```
.claude/cache/jobs/<jid>.json     # {name, cmd, cwd, started_at, transport, finished_at, exit_code}
                   <jid>.status   # running | success | failed | unknown_dead
                   <jid>.exit     # 숫자 exit code
                   <jid>.pid      # wrapper 가 살아있는 동안만
                   <jid>.log      # merged stdout/stderr
```

- 모든 쓰기는 temp+mv 로 atomic — reader 는 partial line 을 절대 보지 않는다
- `.claude/cache/jobs/` 는 `.gitignore` 에 등록되어 있으므로 로컬 환경 데이터만 담는다
- GC: `rein job gc` (또는 `rein job start` 실행 시 async 로 자동 수행) 가 .log 7일 / meta 30일 정책으로 청소

## 플랫폼

- POSIX (Linux / macOS) — `setsid` 가 있으면 pgroup 기반 detach; 없으면 `nohup` fallback
- Windows Git Bash (MINGW64 / MSYS2) — `setsid` 있으면 사용, 없으면 subshell `( ... & )` reparent
- Windows native (cmd / PowerShell) **미지원** — `rein` 은 Git Bash 에서만 동작한다
- WSL — Linux runner 와 동일 경로 재사용

## Claude Code 세션 안에서의 흐름

1. 사용자가 긴 명령(`pytest -x tests/`) 을 요청
2. Claude 는 `rein job start pytest -- pytest -x tests/` 실행 → `started: pytest-xxx` 회수
3. 다음 턴으로 즉시 넘어가 다른 작업 진행
4. 사용자가 결과 물어보면 `rein job status pytest-xxx` → running 이면 `rein job tail pytest-xxx` 로 진행 상황 보여주기
5. 완료되면 `rein job tail pytest-xxx --lines 100` 으로 실제 로그 요약 + 결정

**핵심**: Claude 는 `BashOutput` 에 의존해 결과를 기다리는 대신 **파일 기반 상태 머신** 을 읽는다. 세션이 끊겨도, 사용자가 새 세션을 열어도, `rein job status <jid>` 가 동일하게 동작한다.

## 안티패턴 추적

- 긴 foreground 명령이 발견되면 `trail/incidents/` 에 기록하고 `incidents-to-rule` 로 자동화 후보 올린다
- BashOutput 을 턴 경계 너머로 쓰려는 시도는 immediate abort 신호로 본다
