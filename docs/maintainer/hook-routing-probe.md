# Hook Routing Probe (메인테이너 전용)

> 이 문서는 사용자용 트러블슈팅이 아니라 **rein 메인테이너가 `hooks.json` 라우팅을 바꿀 때 쓰는 수동 진단 도구** 안내다. `rein update` 사용자에게는 무관하다.

`scripts/rein-probe-hook-routing.sh` 는 `plugins/rein-core/hooks/hooks.json` 의 라우팅(어떤 이벤트에 어떤 훅을 매핑하는지)을 바꾸기 **전후**, Claude Code 호스트가 그 설정을 실제로 로드·등록·발화하는지 실증한다.

## ⚠️ 보안 경고 — `--ref` 는 그 커밋의 훅을 실제로 실행한다

`--ref` 는 임의 브랜치/커밋을 받는다(`git rev-parse --verify` 만 통과하면 무엇이든). 이 프로브는 그 ref 를 격리 worktree 로 체크아웃한 뒤, 그 worktree 의 플러그인 디렉터리를 `--permission-mode bypassPermissions` 로 로드해 **실제 headless 세션을 띄운다**. hooks.json 에 등록된 명령형 훅들은 그 세션 동안 **진짜 셸 명령으로, 승인 프롬프트 없이** 실행된다.

즉 지정한 ref 의 훅 스크립트가 조작돼 있으면(제3자 브랜치·검토 전 PR·손상된 커밋) 그 코드가 **실행 계정 권한으로 그대로** 돈다.

**반드시 본인이 작성했거나 이미 검토를 마친 커밋에만 사용하세요.** 제3자 브랜치·리뷰 전 PR·출처가 불확실한 커밋에는 절대 쓰지 마세요.

이 위험을 완화하기 위해 스크립트는 두 단계로 신호를 낸다:

1. **항상 보이는 한 줄 고지** — `--ref` 가 기본값(현재 HEAD)이든 아니든, claude 세션을 띄우기 전에 매 실행마다 "이 프로브가 이 커밋의 훅을 승인 없이 실제 실행한다"는 사실을 stderr 에 짧게 출력한다. 현재 체크아웃된 커밋 자체가 검토 전/오염된 상태일 수 있으므로, 기본값 실행이라고 안전이 보장되지는 않는다.
2. **대화형 확인** — 지정한 커밋이 현재 HEAD 와 달라 상세 WARNING 블록이 뜨는 경우, **표준입력이 터미널일 때만** y/N 확인을 받는다. 기본값은 거부(N) — 빈 입력을 포함해 `y`/`yes` 이외에는 모두 거부로 처리하고 아무 것도 실행하지 않은 채 종료한다. 표준입력이 터미널이 아니면(파이프·CI·자동화 호출 등 비대화형) 확인을 건너뛰고 경고만 출력한 채 기존처럼 진행한다 — 자동화 호출을 막지 않기 위함이다.

기본값(현재 HEAD) 실행에는 확인 프롬프트가 뜨지 않는다 — 확인은 오직 "지정 커밋 ≠ 현재 HEAD" 인 경우에만 발동한다.

## 왜 필요한가

기존 자동 테스트(`tests/hooks/**`)는 두 종류뿐이다: hooks.json 을 정적으로 파싱하거나, 훅 스크립트를 직접 호출하는 것. 둘 다 **호스트(Claude Code)가 그 설정을 실제로 어떻게 해석하는지는 검증하지 않는다.** 라우팅을 바꾸고 나서 "설정 파일은 문법상 맞는데 실제로는 아무 훅도 안 걸린다"는 회귀는 기존 테스트로 못 잡는다 — 이 프로브가 그 gap 을 메운다.

## CI 에 없다 — 수동 실행 전용

`tests/*/run-all.sh` 에 등록되지 않는다. 이유:
- 로그인된 `claude` CLI 가 필요하다.
- 실행마다 실제 LLM 세션 1회(과금 발생)를 쓴다.
- 실행 시간이 환경/모델 부하에 따라 수십 초 ~ 수 분 걸린다.

hooks.json 라우팅을 바꾼 세션에서 메인테이너가 직접 실행한다.

## 사용법

```bash
# 기본값: 현재 HEAD, edit-write 시나리오, 180초 타임아웃
bash scripts/rein-probe-hook-routing.sh

# 특정 브랜치/커밋 검증
bash scripts/rein-probe-hook-routing.sh --ref feat/my-routing-change

# 다른 내장 시나리오
bash scripts/rein-probe-hook-routing.sh --scenario bash-echo
bash scripts/rein-probe-hook-routing.sh --scenario list   # 목록만 출력

# 커스텀 프롬프트 (baseline 이벤트만 판정, tool-event 기대값 없음)
bash scripts/rein-probe-hook-routing.sh --prompt "직접 지정한 프롬프트"

# 타임아웃 조정
bash scripts/rein-probe-hook-routing.sh --timeout 300
```

`--help` 로 전체 옵션을 볼 수 있다.

## 격리 — 메인 저장소는 절대 안 건드린다

1. `git worktree` 로 `--ref` 커밋의 격리된 사본을 만든다 (메인 작업 트리 파일은 손대지 않는다 — worktree add/remove 는 `.git/worktrees/` 메타데이터만 건드린다).
2. 저장소 밖 임시 폴더(cwd)에서 그 worktree 의 `plugins/rein-core` 를 `claude -p --plugin-dir` 로 명시 로드해 1회 headless 세션을 실행한다. `--setting-sources project,local` 로 전역 설치된 `rein@rein` 의 자동 개입을 배제하므로, 이 세션에서 작동하는 훅은 순수하게 `--ref` 시점의 hooks.json 뿐이다.
3. 종료 시(성공/실패/중단 모두) worktree + sandbox 를 자동 정리한다. 정리 실패 시 남은 경로와 수동 삭제 명령을 그대로 출력한다.

## 판정 방식 — 독립된 두 신호

- **호스트 등록 로그** (`--debug hooks --debug-file`): `"Registered N hooks from M plugins"` 한 줄로, hooks.json 을 읽고 등록을 마쳤는지 확인한다.
- **실제 발화 이벤트** (`--output-format stream-json --include-hook-events`): 세션 중 실제로 발화한 `hook_started`/`hook_response` (hook_event, hook_name, exit_code, outcome) 를 표로 보여준다.

`outcome != success` 인 훅 응답은 실패로 치지 않는다 — 정당한 차단(예: bootstrap 안 된 sandbox 를 감시가 거부)일 수 있고, "발화했다"는 증거로는 여전히 유효하다. 그런 경우는 표와 별도 NOTE 로만 표시된다.

## 출력 읽는 법

```
CHECK[edit-write] PASS plugin_registered_via_init (...)
CHECK[edit-write] PASS debug_log_shows_registration (...)
CHECK[edit-write] PASS baseline_event_fired[SessionStart]
CHECK[edit-write] PASS scenario_event_fired[PreToolUse]
CHECK[edit-write] PASS scenario_event_fired[PostToolUse]
PROBE_VERDICT[edit-write] PASS (7/7 checks passed)
```

- `PROBE_VERDICT` 가 `PASS` 면 해당 `--ref` 의 hooks.json 라우팅이 실제로 로드·등록·발화함을 확인한 것이다.
- 종료 코드: `0` = 전 판정 PASS, `1` = 실행/판정 실패 또는 대화형 확인 거부, `2` = 인자 오류.
- 원본 로그(`transcript.jsonl`/`stderr.log`/`debug.log`)는 실행마다 `${TMPDIR:-/tmp}` 바로 아래 `mktemp -d` 로 생성된 완전히 무작위인 폴더(예: `rein-probe-hook-routing-reports.<UTC타임스탬프>.<랜덤6자>`)에 `0700` 권한으로 남고 **자동 삭제되지 않는다** — 출력 마지막에 경로와 `rm -rf` 명령이 함께 나온다. 실행마다 이름이 완전히 무작위이므로 여러 실행이 공유하는 고정 이름 상위 폴더는 존재하지 않는다(과거엔 `rein-probe-hook-routing-reports/` 라는 고정 이름 폴더를 모든 실행이 공유했고, 그 폴더 자체는 `0755` 로 남아 다른 로컬 계정이 실행 이력을 열람하거나 리프 폴더를 rename/delete 할 수 있었다 — 지금은 그 상위 폴더 자체가 없다).

## 흔한 실패 원인

| 증상 | 원인 | 대응 |
|---|---|---|
| `ERROR: ... 'claude' 커맨드가 필요합니다` | claude CLI 미설치/PATH 밖 | `claude --version` 확인 |
| `claude CLI 가 로그인되어 있지 않습니다` | 세션 미인증 | `claude auth login` |
| `claude -p 종료 코드: timeout` | `--timeout` 초과 (기본 180s) | `--timeout 300` 등으로 늘려 재시도 |
| `사용자가 확인하지 않아 실행을 중단합니다` | `--ref` 가 현재 HEAD 와 다른 상태에서 터미널 확인에 `y`/`yes` 이외를 입력(빈 입력 포함) | 의도한 커밋이 맞으면 프롬프트에 `y` 입력. 자동화 호출이면 stdin 을 파이프/리다이렉트해 비대화형으로 전환(확인 자체가 건너뛰어짐) |
| `plugin_registered_via_init` FAIL, 나머지는 PASS | `init.plugins[].path` 문자열이 기대 경로와 미스매치(예: macOS `$TMPDIR` 중복 슬래시/심볼릭 링크) | 이 스크립트는 이미 `cd && pwd -P` 로 경로를 정규화해 해당 문제를 회피한다 — 그래도 재발하면 `transcript.jsonl` 의 `init` 메시지 `plugins[].path` 를 직접 대조 |
| `scenario_event_fired[PreToolUse]` FAIL | hooks.json 라우팅이 해당 이벤트에 훅을 걸지 않음(회귀 가능성) | hooks.json 변경분과 `debug.log` 의 등록 로그를 대조 |

## 관련 파일

- `scripts/rein-probe-hook-routing.sh` — 프로브 본체
- `plugins/rein-core/hooks/hooks.json` — 검증 대상 라우팅 설정 (읽기 전용 참조 — 이 프로브가 직접 수정하지 않는다)
- `plugins/rein-core/hooks/lib/project-dir.sh` — 훅이 project root 를 찾는 방식 (프로브의 격리 sandbox 가 git 저장소가 아니므로 `$PWD` 로 귀결된다)
- `plugins/rein-core/tests/orchestration/e2e-orchestration.sh` — 이 프로브가 격리 패턴(darwin 워치독, `--setting-sources project,local`, `--permission-mode bypassPermissions` 근거)을 가져온 선례
