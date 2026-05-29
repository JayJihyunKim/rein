# Completed DoD Archive

> inbox driver 를 잃었지만 daily/weekly 에 완료 증거가 있는 DoD 를 자동 수집한 아카이브.

---
## dod-2026-04-15-dod-rotation-wave3-fixes.md (mtime: 2026-04-29, archived: 2026-04-30)
# DoD: Wave 2 마무리 + Wave 3 진행

- 날짜: 2026-04-15
- 작업: DoD 회전 시스템 구현 마무리 (어제 이어서)

## 목표

어제 WIP 저장한 `feat/dod-rotation-impl` 브랜치의 마무리:

1. `test-harness.sh`의 `run_hook` 버그 최종 수정 (`set -u` 환경에서 `$2` unbound)
2. 테스트 3개 suite 전부 통과 확인 (9+6+4 = 19 tests)
3. `run-all.sh` 통합 러너 동작 확인
4. Task 13 실전 Rein SOT 스모크 테스트 (일부는 자동으로 이미 완료됨)

## 완료 기준

- [ ] `bash tests/hooks/run-all.sh` → ALL SUITES PASSED
- [ ] `grep -rn 'TRACE\|DEBUG' .claude/hooks/*.sh` → 0 matches
- [ ] 실전 수동 검증: 신 포맷 dod 생성 → 편집 허용 → inbox 기록 → 회전 확인
- [ ] dev 로 머지 (또는 사용자 승인 대기)

---
## dod-2026-04-15-hotfix-hook-stat-and-deadlock.md (mtime: 2026-04-29, archived: 2026-04-30)
# Hotfix: hook stat mtime bug + stop-session-gate deadlock

- 날짜: 2026-04-15
- 유형: fix (hotfix)
- 대상 브랜치: dev → main (릴리즈)
- 버전: v0.4.0 → v0.4.1

## 배경

두 건의 치명적 결함이 need-to-confirm.md에 보고됨.

### 1. `stat -f` 이식성 버그 (Linux 사용자 블록)

`pre-edit-dod-gate.sh:74`, `pre-bash-guard.sh:75-76`이 mtime을 얻기 위해 `stat -f %m "$F" || stat -c %Y "$F"` 폴백 체인을 사용한다. 그러나 Linux GNU stat의 `-f` 플래그는 "파일시스템 정보 출력" 모드라서 **에러가 아니라 멀티라인 문자열로 exit 0 반환**. 따라서 `||` 폴백이 절대 동작하지 않고, 엉뚱한 문자열이 산술식(`$(( ... ))`)에 주입되어 syntax error → DoD 탐지 실패 → 편집 차단. Linux 기반 ai-quant 프로젝트에서 실증됨.

### 2. stop-session-gate ↔ 3rd party fact-force 데드락

`stop-session-gate.sh`는 세션 종료 시 `SOT/inbox/YYYY-MM-DD-*.md` 존재를 요구한다. 3rd party Claude 플러그인 `gateguard-fact-force.js`(strict mode)는 새 파일 생성하는 모든 Write/Bash PreToolUse를 차단. 두 훅이 서로 충돌해 inbox를 못 만들고 세션도 못 끝내는 영구 데드락 발생.

## 변경 대상

### stat 버그
- `.claude/hooks/pre-edit-dod-gate.sh` — line 74의 mtime 추출을 OS-감지 헬퍼로 교체
- `.claude/hooks/pre-bash-guard.sh` — lines 75-76 동일 교체
- `.claude/hooks/inbox-compress.sh` — line 46 예방 정리

### 데드락 해소 (신규 훅)
- `.claude/hooks/post-edit-index-sync-inbox.sh` (**신규**) — `SOT/index.md` 편집 후 오늘자 inbox가 없으면 훅 프로세스가 직접 자동 생성 (bash 리다이렉션 → fact-force 우회)
- `.claude/settings.json` — 위 훅을 `PostToolUse` (matcher: `Edit|Write|MultiEdit`)에 등록

### 테스트
- `tests/hooks/test-stat-mtime.sh` (**신규**) — `_mtime()` 헬퍼 크로스 플랫폼 동작 검증
- `tests/hooks/test-index-sync-inbox.sh` (**신규**) — 새 훅의 자동 생성/미덮어쓰기 동작 검증

### 릴리즈
- `scripts/rein.sh` — `VERSION` 상수 v0.4.0 → v0.4.1
- main 선별 머지 (branch-strategy.md 규정 준수)
- `v0.4.1` 태그

## 설계 원칙

### stat 헬퍼
```bash
_mtime() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}
```
- Darwin = BSD stat, 나머지(Linux/WSL/Git Bash/Cygwin) = GNU stat
- Windows는 bash 실행 환경이 전부 GNU coreutils 기반이라 커버됨

### index-sync-inbox 훅
- 조건: `tool_input.file_path`가 `SOT/index.md`로 끝날 때만 동작
- 오늘자 inbox (`SOT/inbox/YYYY-MM-DD-*.md`)가 이미 존재하면 **건드리지 않음** (수동 기록 우선)
- 없으면 `SOT/inbox/YYYY-MM-DD-session.md` 자동 생성:
  - `자동 생성` 표시 포함
  - `git log --since=midnight --oneline` 주입
  - `git diff --name-only` 주입
  - 요약은 "index.md 참조, 필요 시 수동 보완" 안내
- 실패해도 exit 0 (훅이 세션 작업을 차단하면 안 됨)
- Claude의 tool 호출이 아닌 훅 프로세스 내부 I/O → fact-force가 가로채지 못함

## Definition of Done

- [ ] `_mtime()` 헬퍼가 세 훅에 적용되고 `stat -f`가 직접 호출되는 부분 제거
- [ ] Linux 환경 재현: `stat -f %m /tmp/test` 결과와 무관하게 `_mtime` 이 올바른 epoch 반환 (테스트로 검증)
- [ ] macOS 환경에서도 동일 동작 (uname=Darwin 분기 검증)
- [ ] `post-edit-index-sync-inbox.sh` 훅이 `.claude/settings.json`에 등록되어 실제 트리거됨
- [ ] SOT/index.md 편집 후 오늘자 inbox 자동 생성되는 것을 E2E로 확인
- [ ] 기존 수동 inbox 파일이 있을 때 덮어쓰지 않음을 확인
- [ ] `tests/hooks/run-all.sh` 전체 통과 (기존 19/19 유지 + 신규 테스트 추가)
- [ ] Codex 리뷰 완료 (`.codex-reviewed` stamp)
- [ ] Security 리뷰 완료 (`.security-reviewed` stamp)
- [ ] dev 브랜치에 커밋
- [ ] main 선별 머지 (branch-strategy.md §포함 목록에 맞게)
- [ ] `scripts/rein.sh`의 VERSION v0.4.1로 범프
- [ ] `v0.4.1` 태그 생성
- [ ] `SOT/inbox/2026-04-15-hotfix-hook-stat-and-deadlock.md` 완료 기록
- [ ] `SOT/index.md` 갱신

## 범위 외 (명시)

- fact-force 플러그인 자체의 verbatim 매칭 버그는 rein의 관할이 아님 → 수정하지 않음
- `REIN_BYPASS_STOP_GATE` 같은 env var 탈출구는 추가하지 않음 (sync-inbox 훅으로 자동 해소 가능하므로 불필요)
- `stop-session-gate.sh` 로직은 변경하지 않음 (inbox 존재 요구 정책 유지)

---
## dod-2026-04-15-prebashguard-commit-msg-fix.md (mtime: 2026-04-29, archived: 2026-04-30)
# Fix: pre-bash-guard 커밋 메시지 검증 로직 개선

- 날짜: 2026-04-15
- 유형: fix
- 대상 브랜치: dev (main 머지 여부는 별도 결정)
- 관련 파일: `.claude/hooks/pre-bash-guard.sh`

## 배경

v0.4.1 핫픽스 작업 중 pre-bash-guard 의 커밋 메시지 포맷 검증이 세 가지 결함을 보임.

### 버그 1 — 복합 명령 오탐

복합 쉘 명령에서 커밋 뒤에 태그 생성이 붙는 경우 (amend + tag 추가 시나리오), 훅은 "commit" 부분문자열이 COMMAND 어딘가에 있으므로 포맷 체크 블록에 진입한다. 이어 전체 COMMAND 에서 메시지 플래그 패턴을 greedy 하게 탐색하는데, 이 결과가 **태그 쪽 메시지 플래그** 를 잡아버려 태그 메시지를 커밋 메시지로 오인하게 된다. 이 오인된 "커밋 메시지" 는 conventional commits 정규식에 걸리지 않아 엉뚱한 BLOCK 이 발생한다.

### 버그 2 — heredoc 우회

현재 추출 로직은 sed 기반이라 한 줄 단위로 처리된다. 커밋 메시지를 `$(cat <<EOF ... EOF)` 형태로 넣으면 sed 는 heredoc 본문의 실제 첫 줄을 추출하지 못하고 빈 문자열을 내놓는다. 추출 결과가 비어 **포맷 검사 자체가 스킵** 된다. 결과적으로 heredoc 방식 커밋은 현재 사실상 무검증 상태.

### 버그 3 — scope 미지원

현재 정규식은 `^(feat|fix|docs|refactor|test|chore): .+` 로 conventional commits 의 scope 표기법 (`fix(auth):`, `chore(sot):`) 을 허용하지 않는다. v0.4.1 핫픽스의 첫 커밋이 `fix` 뒤에 괄호 스코프가 붙은 형태로 통과된 것은 scope 지원 때문이 아니라 버그 2 (heredoc 무검증) 때문이었음을 확인.

## 수정 방향

### 1) 추출 로직 python3 재작성

- 원본 COMMAND 문자열에서 "commit" 토큰 위치를 찾고, 그 이후부터 다음 쉘 명령 구분자 (`&&`, `;`, `||`, 파이프) 전까지만 탐색 범위로 한다
- 그 제한된 범위 안에서 heredoc → 큰따옴표 플래그 → 작은따옴표 플래그 순으로 시도
- heredoc 은 multiline regex 로 `<<EOF ... EOF` 본문 첫 줄 추출
- python3 의존은 이미 다른 훅과 동일 수준이므로 허용

### 2) scope 정규식 확장

`^(feat|fix|docs|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?: .+`

scope 는 영문/숫자/언더스코어/하이픈만 허용, scope 자체는 선택.

## Definition of Done

- [ ] pre-bash-guard.sh 의 메시지 추출이 python3 기반으로 재작성
- [ ] 복합 명령에서 태그 쪽 플래그가 커밋 메시지로 오인되지 않음
- [ ] amend + no-edit 조합에서 커밋 플래그가 없으면 검사 스킵
- [ ] heredoc 방식 커밋의 첫 줄이 올바르게 추출됨
- [ ] scope 있는 커밋 타입 통과
- [ ] scope 없는 커밋 타입 통과
- [ ] 포맷 위반 커밋 여전히 차단
- [ ] tests/hooks/test-commit-msg.sh 신규 10+ 테스트 통과
- [ ] tests/hooks/run-all.sh 전체 통과
- [ ] Codex 리뷰 완료
- [ ] dev 커밋
- [ ] main 머지 여부는 사용자가 결정

## 범위 외

- 다른 훅은 건드리지 않음
- 순수 bash 토큰화는 시도하지 않음

---
## dod-2026-04-15-v043-stop-gate-relaxation.md (mtime: 2026-04-29, archived: 2026-04-30)
# v0.4.3: stop-session-gate 데드락 해소 (git 활동 감지 + env 탈출구)

- 날짜: 2026-04-15
- 유형: fix (hotfix)
- 대상 브랜치: feat/v043-deadlock-fix → dev (no-ff) → main 릴리즈
- 관련 파일: .claude/hooks/stop-session-gate.sh
- 목표 버전: v0.4.3

## 배경

v0.4.1 hotfix 는 `post-edit-index-sync-inbox.sh` 를 추가해 gateguard-fact-force 플러그인과의 세션 종료 데드락을 해소하려 했지만, **precondition 이 실환경에서 성립하지 않는** 구조적 한계가 있었다:

v0.4.1 훅은 `SOT/index.md` 가 편집될 때만 발동한다. 사용자가 데드락 상황에서 inbox 파일 생성에 집중하다가 fact-force 에 연속 차단될 경우, 자연스러운 흐름으로 `SOT/index.md` 를 편집할 생각을 못 하고, 훅이 발동하지 않아 데드락이 유지된다.

### 재현 (tests/hooks/test-stop-gate-deadlock.sh)

v0.4.1 훅이 설치된 상태에서 다음 3 가지 시나리오가 exit 2 로 차단된다:

1. **uncommitted 변경이 있는 세션**: git working tree 에 변경사항이 있어 "실제 작업"은 있었지만 inbox 파일이 없는 경우 → 데드락
2. **오늘 커밋이 있는 세션**: 사용자가 이미 커밋까지 마쳤지만 inbox 파일이 없는 경우 → 데드락
3. **env 탈출구 부재**: 극단 상황에서 세션을 강제로 끝낼 방법 없음

모두 exit 2 로 차단되어 사용자가 세션을 정상 종료할 수 없다.

## 수정 방향

### 방어층 1 — git 활동을 "작업 증거" 로 인정 (핵심 수정)

stop-session-gate.sh 에 git 활동 감지 로직을 추가한다:

```
오늘자 inbox 파일 없음 AND 오늘 커밋 없음 AND 변경사항 없음
  → 진짜 빈 세션 → 기존처럼 차단

오늘자 inbox 파일 없음 AND (오늘 커밋 있음 OR 변경사항 있음)
  → 실제 작업이 있음 → WARNING 출력 + 통과
```

git 활동 감지는 `git log --since` 및 `git status --porcelain` 로 수행하며, 이는 훅 프로세스가 직접 실행하는 bash 명령이므로 fact-force 같은 PreToolUse 훅의 간섭을 받지 않는다.

### 방어층 2 — REIN_BYPASS_STOP_GATE env var 탈출구

극단 상황(git 활동도 없지만 세션을 끝내야 함)용 escape hatch:

```
if [ "$REIN_BYPASS_STOP_GATE" = "1" ]; then
  WARNING 출력 + exit 0
fi
```

스크립트 최상단에 배치해 가장 우선권. 악용 방지를 위해 WARNING 은 항상 출력.

### 방어층 3 — 차단 메시지 UX 개선

차단 메시지에 구체적 해결 방법 3 가지 명시:

```
BLOCKED: ...
빠른 해결책:
  1) SOT/index.md 를 편집하면 post-edit-index-sync-inbox 훅이 자동으로 inbox 를 생성합니다
  2) 터미널에서 직접: echo "# 기록" > SOT/inbox/YYYY-MM-DD-session.md
  3) 비상 탈출 (한 번만): REIN_BYPASS_STOP_GATE=1 재실행
```

## Definition of Done

### 기능
- [ ] git 저장소 감지 (`git rev-parse --is-inside-work-tree`)
- [ ] 오늘 커밋 감지 (`git log --since="<today 00:00>" --oneline`)
- [ ] 변경사항 감지 (`git status --porcelain`)
- [ ] inbox 없음 + git 활동 있음 → WARNING + 통과
- [ ] inbox 없음 + git 활동 없음 → 기존처럼 차단
- [ ] `REIN_BYPASS_STOP_GATE=1` 환경변수 지원 (WARNING 출력 후 exit 0)
- [ ] 차단 메시지에 3 가지 해결책 명시

### 테스트 (tests/hooks/test-stop-gate-deadlock.sh)
- [ ] test_empty_session_blocks: 여전히 차단 (회귀 없음)
- [ ] test_session_with_uncommitted_work_should_pass_post_v043: PASS
- [ ] test_session_with_today_commit_should_pass_post_v043: PASS
- [ ] test_env_bypass_allows_exit_on_empty_session: PASS
- [ ] test_happy_path_with_inbox_still_works: PASS (회귀 없음)
- [ ] test_stale_index_still_blocks: 여전히 차단 (회귀 없음)
- [ ] test_non_git_project_empty_session_blocks: 여전히 차단 (회귀 없음)

### 기존 회귀 테스트 (tests/hooks/test-stop-gate.sh)
- [ ] 4 개 기존 케이스 전부 통과 유지

### 전체 테스트
- [ ] tests/hooks/run-all.sh 전체 통과

### 리뷰
- [ ] Codex 리뷰 완료 — 주로 git 감지 로직의 edge case
- [ ] Security 리뷰 완료 — 특히 REIN_BYPASS_STOP_GATE 의 악용 가능성

### 릴리즈
- [ ] feat/v043-deadlock-fix 에 커밋
- [ ] dev 로 no-ff 머지
- [ ] main 선별 머지
- [ ] scripts/rein.sh VERSION v0.4.2 → v0.4.3
- [ ] README v0.4.3 changelog 항목
- [ ] v0.4.3 태그 + push

## 범위 외

- `post-edit-index-sync-inbox.sh` 자체 수정 없음 (이 훅은 여전히 정상 워크플로우에서 유용함)
- SessionStart 훅에서 placeholder 생성하는 방어층 2 (원래 설계의) 는 v0.5.0 에서 검토
- main 릴리즈 타이밍은 dev 검증 후 사용자 결정

## 검증 전략 (v0.4.1 검증 실패 교훈)

v0.4.1 의 검증은 "훅이 호출됐을 때 올바르게 동작하는가" 만 확인했고, "훅이 실제로 호출되는가" 를 검증하지 못했다. v0.4.3 은 **stop-session-gate 자체의 동작** 을 직접 검증한다. 훅 발동 여부와 무관하게, stop-gate 는 호출될 때마다 동일한 로직으로 동작하므로 재현 테스트가 곧 검증이 된다.

이 차이:
- v0.4.1: PostToolUse 훅 → Claude tool 호출이 있어야 발동 → 테스트로 완전 시뮬레이션 어려움
- v0.4.3: Stop 훅 자체 수정 → 세션 종료 시점 항상 호출 → 직접 시뮬레이션 가능

---
## dod-2026-04-15-v050-manifest-prune.md (mtime: 2026-04-29, archived: 2026-04-30)
# v0.5.0: rein update manifest 추적 + prune 기능

- 날짜: 2026-04-15
- 유형: feat
- 대상 브랜치: feat/v050-manifest-prune → dev (no-ff merge), main 릴리즈는 별도 결정
- 관련 파일: scripts/rein.sh (+ helper / 테스트)
- 목표 버전: v0.5.0

## 배경

`rein update` 의 두 가지 한계가 v0.4.x 대비 누적 위험:

### Q1: bulk overwrite 비-interactive 불가

현재 prompt_conflict() 는 interactive 첫 충돌에서 `[a]ll-overwrite` 옵션이 있지만, **CLI 플래그(`--all` / `--yes` / `--force`)가 없음**. tty 가 없으면 자동으로 `skip` 으로 폴백되어 CI/자동화 환경에서 "변경 없음" 결과만 나옴.

### Q2: 폐기된 파일 잔존이 silent 위험

`cmd_merge` 는 새 템플릿 파일만 순회해 copy/skip 하고, **템플릿에서 사라진 파일은 user 프로젝트에 영구 잔존**. 영향:

- **🔴 Skills 자동 발견**: Claude Code 가 `.claude/skills/` 를 스캔하므로 폐기된 skill 의 description 이 새 skill 의 invocation 후보로 경합
- **🔴 Agents 자동 발견**: 동일 패턴. 폐기된 agent 가 잘못 자동 선택될 수 있음
- **🟡 settings.json 사용자 커스터마이즈 시**: user 가 settings.json 을 skip 했다면 폐기된 hook 항목이 남아 폐기 hook 파일을 계속 트리거
- **🟢 Rules / Workflows / lib**: @import 또는 명시적 참조 기반이라 끊긴 참조는 dead code (디스크만 차지)

v0.4.x 시점엔 deprecation 이 거의 없어 잠복 위험이지만, 프레임워크 성숙과 함께 표면화됨.

## 설계

### Manifest 스키마 (`.claude/.rein-manifest.json`)

설치/업데이트 시 rein 이 관리하는 파일 목록과 각 파일의 sha256 + 최초 추가 버전 기록.

```json
{
  "schema_version": "1",
  "rein_version": "0.5.0",
  "installed_at": "2026-04-15T13:00:00Z",
  "updated_at": "2026-04-15T13:00:00Z",
  "files": {
    ".claude/hooks/pre-edit-dod-gate.sh": {
      "sha256": "abc123...",
      "added_in": "0.1.0"
    },
    ".claude/hooks/post-edit-index-sync-inbox.sh": {
      "sha256": "def456...",
      "added_in": "0.4.1"
    }
  }
}
```

목적:
- **추적**: rein 이 설치/업데이트한 파일을 user 가 추가한 파일과 구분
- **수정 감지**: 마지막 install/update 이후 user 가 sha256 변경 → user 수정 흔적 → prune 시 보존
- **버전 이력**: 각 파일이 언제부터 rein 에 포함됐는지 기록

### CLI 플래그

```
rein new <name>                     # 기존 동작 + manifest 생성
rein new <name> --all               # 충돌 없음 (신규 프로젝트) — 무시
rein merge                          # 기존 동작 (interactive) + manifest 생성/갱신
rein merge --all                    # 모든 conflict 자동 overwrite
rein merge --yes                    # --all 동의어 (CI 친화)
rein update                         # = merge
rein update --prune                 # dry-run: 삭제 후보 표시만
rein update --prune --confirm       # 실제 삭제 (사용자 수정 파일 제외)
rein update --all --prune --confirm # full auto (CI)
```

`--all` 과 `--yes` 는 동일 의미 (별칭). `--prune` 단독은 dry-run.

### Prune 알고리즘

```
1. local manifest 읽기 (없으면 prune 비활성, warning)
2. 새 템플릿의 list_copy_files() 출력 + scaffold_sot 산출 = 새 파일 목록 N
3. local manifest 의 files 키 집합 = 이전 파일 목록 P
4. 삭제 후보 = P - N
5. 각 후보에 대해:
   a. dest_file 존재 안 함 → skip (이미 user 가 지움)
   b. dest_file 의 sha256 vs manifest 의 sha256 비교
      - 일치 → 사용자 미수정 → 안전하게 삭제 가능
      - 불일치 → 사용자가 수정함 → **삭제 안 함**, warning 출력 + 보존
6. dry-run 모드: 위 분류만 출력
7. --confirm 모드: 안전 후보를 실제 삭제 + manifest 에서 제거
8. 매 update 후 manifest 의 updated_at, rein_version 갱신, files 재계산
```

### 안전 장치

- **gitignore 보호**: `.gitignore` 된 파일은 절대 prune 대상 아님 (`git check-ignore` 로 확인)
- **사용자 영역 제외**: `SOT/`, `.claude/settings.local.json`, `.claude/.rein-manifest.json` 자체는 추적하지 않음
- **백업**: `--prune --confirm` 실행 전 자동으로 `.rein-prune-backup-<timestamp>/` 디렉토리에 복사
- **dry-run 기본**: `--prune` 단독은 절대 삭제하지 않음
- **manifest 손상 시**: parse 실패 → prune 즉시 중단 + error
- **스키마 버전 검사**: `schema_version` 이 알 수 없는 값이면 prune 중단 + upgrade 유도

### 하위 호환성

- v0.4.x → v0.5.0 업그레이드: manifest 가 없으면 첫 update 시 **현재 디스크 상태를 기반으로 manifest 생성** (모든 파일이 "사용자 미수정" 상태로 추적 시작). 단, 이때 prune 은 동작 시키지 않음 (이전 상태를 알 수 없으므로).
- v0.4.x manifest 미생성 사용자가 prune 을 사용하려면 두 번 업데이트 필요 (1차: manifest 생성, 2차부터 prune 가능).

## Definition of Done

### 기능
- [ ] `rein new` 가 manifest 생성 (scaffold 후 sha256 기록)
- [ ] `rein merge`/`update` 가 manifest 갱신 (변경/추가 파일의 sha256 재계산)
- [ ] `--all` / `--yes` 플래그가 prompt_conflict 우회 → ALL_OVERWRITE=true
- [ ] tty 없는 환경에서 `--all` 사용 시 정상 동작 (warning 없이 진행)
- [ ] `rein update --prune` (dry-run): 삭제 후보 + 보존 후보 분류 출력
- [ ] `rein update --prune --confirm`: 안전 후보 실제 삭제 + manifest 갱신 + 백업 디렉토리 생성
- [ ] 사용자 수정 파일 (sha256 불일치) 은 prune 대상에서 제외 + warning
- [ ] `.gitignore` 된 파일은 prune 대상에서 제외
- [ ] manifest 없는 v0.4.x 사용자 첫 update 시 manifest 자동 생성 (prune 비활성)
- [ ] manifest 손상 시 명확한 error + prune 거부

### 테스트
- [ ] tests/cli/test-manifest.sh — manifest 생성/갱신/sha256 검증
- [ ] tests/cli/test-prune.sh — dry-run, confirm, 사용자 수정 보호, .gitignore 제외, 백업 생성
- [ ] tests/cli/test-update-flags.sh — `--all` / `--yes` / `--prune` / `--confirm` 조합
- [ ] 모든 신규 테스트 + 기존 회귀 테스트 통과
- [ ] 임시 git repo 샌드박스에서 E2E 시나리오 검증

### 문서
- [ ] README 사용법 섹션에 새 플래그 추가
- [ ] README 버전 히스토리에 v0.5.0 항목 (릴리즈 시)
- [ ] `rein --help` 에 새 플래그 출력
- [ ] CLAUDE.md / SETUP_GUIDE.md 에 manifest 개념 간단 설명

### 리뷰
- [ ] Codex 리뷰 완료 (gpt-5.4 / medium)
- [ ] Security 리뷰 완료 (security-reviewer 에이전트)
  - 핵심 검증: prune 이 user 데이터를 잘못 삭제할 가능성, sha256 검증 우회 가능성, manifest 파일 조작으로 인한 권한 상승

### 커밋/머지
- [ ] feat/v050-manifest-prune 에 작업
- [ ] dev 로 no-ff merge
- [ ] dev push
- [ ] main 릴리즈 (v0.5.0 태그) 는 별도 결정 — 충분한 사용 검증 후

## 범위 외 (이번 작업 제외)

- main 릴리즈는 다음 단계 (이 작업은 dev 까지)
- `rein.sh` VERSION 범프는 main 릴리즈 시 처리 (dev 에서는 0.4.x 유지)
- skills/agents 에 대한 deprecation 정책 (별도 PR)
- prune 이외의 cleanup 기능 (caches, logs 등) — 별도 작업

---
## dod-2026-04-20-brainstorming-skill.md (mtime: 2026-04-29, archived: 2026-04-30)
# rein-native brainstorming skill + handoff chain

- 날짜: 2026-04-20
- 유형: feat (skill)
- 대상 브랜치: dev → main
- 릴리스: v0.10.0 의 2/4
- covers: [bs-1, bs-2, bs-3, bs-4, bs-5]

## 배경

need-to-confirm.md 후속 이슈 5. superpowers:brainstorming 은 사용자 의도를 구체화하는 프로세스는 우수하지만:
1. 기존 시스템 호환성/구현 가능성/운영 비용을 고려하지 않고 선택지만 수렴
2. 설계 문서 작성 시 brainstorming 결론이 일부 누락됨
3. rein 은 이미 design→plan 간 coverage 강제 (`design-plan-coverage.md`), plan→DoD 간 covers: 메타데이터를 갖지만, **brainstorm→spec 구간은 비어 있음**
4. router `registry.yaml:20-32` 는 `brainstorm` 키워드를 process skill 로 제외 → 자동 추천에도 안 잡힘
5. README 는 `brainstorming` 을 언급하나 실제는 superpowers 의 것 — 정합 깨짐

## 변경 대상

### bs-1: `.claude/skills/brainstorming/SKILL.md` 신규

frontmatter description:
```
기존 코드베이스/아키텍처 제약 하에서 아이디어를 spec 초안으로 구체화하는 rein-native brainstorming. 
constraint/feasibility/compatibility 를 먼저 검증한 뒤 선택지를 수렴한다. 
greenfield 와 brownfield 를 구분해 질문 세트가 달라진다. 
산출물은 docs/superpowers/brainstorms/ 에 기록되고 spec 이 brainstorm ref: 로 가리킨다.
```

body:
- 언제 쓰는가 — brownfield (기존 시스템에 기능 추가/변경) 일 때 MUST. greenfield 는 SHOULD (질문 세트가 얇음)
- 프로세스 (greenfield):
  - 사용자 의도 탐색 (2~3 질문)
  - 원칙·트레이드오프 질의 (3~5 질문)
  - 결론 도출 + Open Questions
- 프로세스 (brownfield — 핵심):
  - Step 1: 관련 기존 시스템 탐색 — `Grep` / `Glob` 으로 영향 범위 식별
  - Step 2: constraint 확인 — 기존 훅·테스트·규칙 중 변경을 차단할 수 있는 것
  - Step 3: feasibility 평가 — 각 option 을 기존 시스템 위에 얹을 때의 비용
  - Step 4: compatibility 검증 — breaking 여부, migration 필요성
  - Step 5: 선택지 수렴 + 근거 + Rejected Options 의 "왜 기각됐는지" 기록
  - Step 6: Open Questions (spec 단계에서 풀 것)
- 산출물 포맷 (필수 섹션):
  - `## Problem Statement`
  - `## Constraints` (기존 시스템/규칙/훅)
  - `## Options Considered` (A/B/C/…)
  - `## Chosen Direction` (근거 포함)
  - `## Rejected Options` (기각 이유 포함)
  - `## Open Questions` (spec 으로 handoff)
- handoff: 파일 말미에 `→ Next: docs/superpowers/specs/<slug>.md`
- 호출 예시 제공 (good prompt / bad prompt)
- superpowers:brainstorming 과의 차이점 명시

### bs-2: artifact 경로 규약

- 저장 위치: `docs/superpowers/brainstorms/YYYY-MM-DD-<slug>.md`
  - 이유: `docs/superpowers/specs/`, `docs/superpowers/plans/` 와 동일 루트 (설계 문서 3 단계가 한 디렉토리 계열)
- 파일명 슬러그 규칙: 영문 kebab-case, spec slug 와 동일하게 유지 (추적 용이)
- `docs/superpowers/brainstorms/.gitkeep` 신설 (디렉토리 존재 보장)

### bs-3: spec 의 `brainstorm ref:` 권고 (soft v1)

- spec 문서 (`docs/superpowers/specs/*.md`) 에 `brainstorm ref: docs/superpowers/brainstorms/<slug>.md` 를 권고
- v1: soft (없어도 통과), writing-plans 스킬 문서에 "brainstorm → spec 전환 시 `brainstorm ref:` 유지" 권고 추가
- v2 후보: validator (이번 범위 아님)

### bs-4: router 노출 정책

- `.claude/router/registry.yaml:20-32` 의 `excluded_patterns.description_keywords` 에서 `"brainstorm"` 제거
  - 현재: process skill 로 제외 → 자동 추천 안 됨
  - 변경 후: description 의 "brainstorming" 키워드 기반 매칭이 동작 → DoD 설계 작업에 자동 추천
- 단, superpowers:brainstorming 도 description 에 "brainstorm" 포함이므로 등장함 → rein-native 가 먼저 오도록 learned_preferences 에 boost 등록하거나, id prefix (`.claude/skills/brainstorming`) 를 우선 매칭하는 로직 확인
  - 구현 가능한 간단한 방법: 동일 키워드 매칭 시 rein-native (`.claude/skills/*`) 가 superpowers/외부 보다 우선
  - 이미 라우터가 이런 정책을 갖고 있는지 확인 — 없으면 registry.yaml 주석으로 정책 명시 + learned_preferences 에 boost

### bs-5: README / orchestrator 정합

- `README.md:212` 의 "작업 유형별 추천 조합" 표에서 `brainstorming, writing-plans` 가 rein-native 를 가리키는지 명시 (현재 암묵적)
- `.claude/orchestrator.md` 에 "설계 전 아이디어 정제" 섹션 — brownfield 작업 시 brainstorming → spec → writing-plans 체인
- `README.en.md` 동일 업데이트

## DoD 체크리스트

- [ ] `.claude/skills/brainstorming/SKILL.md` 신규 (frontmatter + body + 산출물 포맷 + handoff)
- [ ] `docs/superpowers/brainstorms/.gitkeep` 신규
- [ ] `.claude/router/registry.yaml` `excluded_patterns.description_keywords` 에서 `"brainstorm"` 제거 + 정책 주석 추가
- [ ] `.claude/skills/writing-plans/SKILL.md` 에 `brainstorm ref:` 보존 권고 추가
- [ ] `README.md` / `README.en.md` 작업 유형 표 주석 정합
- [ ] `.claude/orchestrator.md` brainstorm→spec→plan 체인 언급
- [ ] 기존 spec/plan 테스트가 깨지지 않는지 확인 (coverage validator)
- [ ] Codex 통합 리뷰 통과

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex
mcps: []
rationale: >
  skill 문서 + 라우터 설정 + docs 다중 편집. feature-builder 범위 적합.
  brainstorming 자체는 이 DoD 작성 단계에서 이미 코덱스 분석으로 수행됨 (후속 이슈 5 재검토 결과).
approved_by_user: true
```

---
## dod-2026-04-20-codex-mode-split.md (mtime: 2026-04-29, archived: 2026-04-30)
# /codex Mode A/B 하위 커맨드 분리

- 날짜: 2026-04-20
- 유형: refactor (skill + docs)
- 대상 브랜치: dev → main
- 릴리스: v0.10.0 의 3/4
- covers: [cx-1, cx-2, cx-3]

## 배경

need-to-confirm.md 후속 이슈 4. `/codex` 스킬 frontmatter description 은 "code analysis, refactoring, automated editing" 까지 넓게 적혀 있지만, 운영은 코드 리뷰 (stamp 생성, fallback, severity escalation) 에 고정돼 있다. 궁극적으로는 Claude 세션 컨텍스트에 오염되지 않은 **독립 관점 에이전트** 로 쓰일 수 있는데, 현재 문서 계약이 리뷰만 다룸.

## 변경 대상

### cx-1: `.claude/skills/codex/SKILL.md` 재구성 — 하위 커맨드 분리

frontmatter description 갱신:
```
/codex review (코드 리뷰, stamp 생성, severity escalation, fallback) 와
/codex ask (second-opinion, stamp 없음, 독립 컨텍스트, resume --last 금지) 
두 모드를 제공한다. 호출 시 하위 커맨드를 명시해야 하며, 하위 커맨드 없이 /codex 를 쓰면 
Mode A (review) 로 해석한다 (기존 호환).
```

body 구조:

**Mode A: `/codex review`** (= 기존 `/codex`)
- 기존 body 전부 유지 (Codex 우선 + Sonnet 폴백, severity escalation, stamp 생성, resume 재리뷰 가능)
- 첫 호출 시 새 codex exec 세션으로 시작. 같은 리뷰 사이클 내 재리뷰는 `resume --last` 허용
- 하위 커맨드 없이 `/codex` 호출 시 이 모드로 fallback (backward compat)

**Mode B: `/codex ask`** (= second opinion)
- 용도: brainstorm 반박, spec sanity check, refactor tradeoff 이중 검증, 설계 결정 의심될 때
- **stamp 생성 없음** — 리뷰 게이트 아님
- **`resume --last` 금지** — 이전 세션 컨텍스트가 독립 관점을 오염시킴. 새 `codex exec` 세션 필수
- 출력은 Claude 주 컨텍스트에 반영. 사용자에게 summary + 의사결정 질문
- stamp 파일을 만들지 않으므로 pre-bash-guard 의 리뷰 gate 와 무관
- 호출 예시:
  - `/codex ask` "이 스펙의 X 결정이 실제로 맞는지 독립 관점으로 반박해줘"
  - `/codex ask` "이 refactor 가 over-engineering 인지 판단해줘"
  - `/codex ask` "brainstorm 에서 기각된 option B 가 진짜 기각돼야 하는지 재검토해줘"

header 에 "When to use each mode" 테이블:
| Mode | 언제 | stamp | resume | context |
|------|------|-------|--------|---------|
| `/codex review` | 구현 완료 후 코드 리뷰 | 생성 | 재리뷰 시 허용 | 이전 세션 유지 |
| `/codex ask` | 설계/판단 sanity | 없음 | 금지 | 항상 새 세션 |

### cx-2: 호출 지점 정합

- `AGENTS.md` — 기존 `/codex` 언급을 `/codex review` 로 명시 (리뷰 전용 지점)
- `.claude/orchestrator.md` — 동일
- `README.md` "작업 유형별 추천 조합" — 리뷰 단계는 `/codex review`, 설계 단계는 `/codex ask` 로 분리 언급
- `README.en.md` 동일
- **하위 호환 유지**: 기존 문서가 `/codex` 로만 적어도 동작. 단, 새 레퍼런스는 명시적으로 review/ask 사용

### cx-3: brainstorming skill 과의 handoff

- 이슈 5 에서 신설되는 `.claude/skills/brainstorming/SKILL.md` body 에 `/codex ask` 참고 언급 추가:
  - brainstorming 결론에 대한 sanity check 로 `/codex ask` 를 권고 (선택 사항, v1 soft)

## DoD 체크리스트

- [ ] `.claude/skills/codex/SKILL.md` 재구성 — Mode A / Mode B 섹션 + 하위 커맨드 설명
- [ ] `AGENTS.md` 의 `/codex` 언급이 리뷰 맥락이면 `/codex review` 로 갱신
- [ ] `.claude/orchestrator.md` 동일 갱신
- [ ] `README.md` / `README.en.md` 동일 갱신
- [ ] 이슈 5 의 brainstorming SKILL.md 에 `/codex ask` 권고 언급 (교차 참조)
- [ ] 기존 `/codex` 호출이 여전히 동작하는지 확인 (fallback to review)
- [ ] Codex 통합 리뷰 통과

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex
mcps: []
rationale: >
  skill 문서 재구성 + 여러 문서 정합. feature-builder 로 충분.
  이 DoD 자체가 codex skill 을 대상으로 하므로 최종 리뷰는 Mode A 로.
approved_by_user: true
```

---
## dod-2026-04-20-cross-platform-portability.md (mtime: 2026-04-29, archived: 2026-04-30)
# Cross-platform portability: file_size fix + portable.sh + Windows WSL2 guidance

- 날짜: 2026-04-20
- 유형: fix + refactor + docs
- 대상 브랜치: dev → main (릴리즈)
- 버전: v0.8.0 → v0.9.0
- covers: [cp-1, cp-2, cp-3, cp-4, cp-5]

## 배경

v0.8.0 post-release 중 Linux 사용자가 `session-start-load-trail.sh` 의 `file_size()` 가 깨지는 현상을 보고. Codex 독립 검토(2026-04-20, gpt-5.4/medium) 로 다음이 확인됨:

1. `file_size()` (`.claude/hooks/session-start-load-trail.sh:36-39`) 가 `stat -f %z ... || stat -c %s ...` 형태로 깨져 있음. GNU `stat -f` 는 filesystem-info 모드로 exit 0 반환 → `||` fallback 안 탐 → `set -u` 걸려 있어 산술식에서 unbound 로 죽음. 두 호출 지점(`:51`, `:221`) 모두 영향.
2. v0.4.1 에서 `_mtime` 계열은 OS 감지 헬퍼로 고쳤으나 hook 별로 3곳 중복 구현 (`pre-edit-dod-gate.sh`, `pre-bash-guard.sh`, `trail-rotate.sh`). `file_size` 는 같은 교훈을 재사용 못 하고 재발.
3. Windows native 지원은 `rein-aggregate-incidents.py` 의 `fcntl`, `settings.json` 의 direct-exec hook 호출, POSIX 경로 가정 등으로 구조적 블로커 존재. WSL2 범위로 명시적 제한 필요.

## 변경 대상

### 1단계 — file_size hotfix (cp-1, cp-2)

- **cp-1**: `.claude/hooks/session-start-load-trail.sh`
  - `file_size()` 를 GNU 먼저, BSD fallback, 숫자 검증 강제 형태로 교체
  - line 38 정의부 + line 51, 221 호출부 안전성 확인
- **cp-2**: `tests/hooks/test-stat-portability.sh`
  - `session-start-load-trail.sh` 의 `file_size()` 추출 테스트 추가
  - buggy chain(`stat -f %z ... || stat -c %s ...`) 잔존 검증
  - 숫자 아닌 값 반환 시 `0` 정규화 검증
- **cp-3**: `.gitattributes` (신규)
  - `*.sh`, `*.py`, `*.md`, `*.yml`, `*.yaml`, `*.json` 에 `text eol=lf` 강제
  - Windows checkout 시 CRLF → shebang 깨짐 방지

### 2단계 — portable.sh 공통 헬퍼 (cp-4)

- `.claude/hooks/lib/portable.sh` (신규)
  - `portable_stat_size FILE` → 바이트 크기. 비숫자/없음은 `0`
  - `portable_mtime_epoch FILE` → epoch 초. 없음은 `0`
  - `portable_mtime_date FILE` → `YYYY-MM-DD`. 없음은 빈 문자열
  - `portable_date_ymd_to_epoch YYYY-MM-DD` → epoch 초 (BSD `date -j -f` / GNU `date -d` 분기)
  - 구현: `case "$(uname)"` 로 Darwin/Linux/기타 분기
- 기존 중복 헬퍼 교체:
  - `.claude/hooks/pre-edit-dod-gate.sh:17-26` (`_mtime`) → `portable_mtime_epoch` source
  - `.claude/hooks/pre-bash-guard.sh:59-68` (`_mtime`) → `portable_mtime_epoch` source
  - `.claude/hooks/trail-rotate.sh:20-27` (`_mtime_date`) → `portable_mtime_date` source
  - `.claude/hooks/stop-session-gate.sh:178` (`date -j -f`) → `portable_date_ymd_to_epoch` 사용 검토
- `tests/hooks/test-stat-portability.sh` 를 portable.sh 함수 단위 테스트로 재구성 (hook 전체 grep 방식 → 함수 직접 호출)
- main 머지 범위에 `.claude/hooks/lib/portable.sh` 포함 (branch-strategy.md 기존 "lib/**" 규칙 적용)

### 3단계 — Windows WSL2 지원 범위 문서화 (cp-5)

- `README.md`
  - "지원 플랫폼" 섹션 추가 (또는 기존 설치 섹션 확장)
    - ✅ macOS, Linux, Windows via WSL2
    - ⚠️ Git Bash / MSYS2: best-effort 비공식
    - ❌ PowerShell / CMD native: 미지원
  - Windows 사용자를 위한 WSL2 설치 안내 (PowerShell 관리자 모드 → `wsl --install` → Ubuntu → `git clone` 등)
  - 설치 안내는 한국어 + 영문 README 모두
- `README.en.md` 동일 업데이트
- `REIN_SETUP_GUIDE.md` — Windows 사용자 안내 줄 추가
- `need-to-confirm.md` — "session-start-load-trail.sh 리눅스 적용 이슈" 섹션 하단에 "✅ v0.9.0 에서 해결" 표기

## 설계 원칙

### portable_stat_size 구현 스케치

```bash
portable_stat_size() {
  local sz
  case "$(uname)" in
    Darwin) sz=$(stat -f %z "$1" 2>/dev/null) ;;
    *)      sz=$(stat -c %s "$1" 2>/dev/null) ;;
  esac
  case "$sz" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$sz" ;;
  esac
}
```

- uname 분기 우선 (명시적·빠름)
- 숫자 아닌 결과는 무조건 `0` 으로 정규화 → `set -u` 환경에서 산술식 안전
- `stat` 부재 시(극단적 minimal container)에도 `0` 반환 → 훅이 BLOCK 대신 degraded 경로로 진행

### portable.sh source 규약

- 각 훅은 파일 상단 `set -euo pipefail` 직후 source:
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=./lib/portable.sh
  . "$SCRIPT_DIR/lib/portable.sh"
  ```
- lib/ 내부에서도 동일 source 가능
- `set -u` 하에서도 안전하도록 모든 local 변수 기본값 초기화

### 릴리즈 전략

- dev → main 선별 체크아웃 (branch-strategy.md §머지 절차)
- `scripts/rein.sh` VERSION 상수 `v0.9.0` 으로 갱신
- CHANGELOG + README 버전 히스토리 + tag `v0.9.0`

## DoD 체크리스트

### 코드 변경
- [ ] `session-start-load-trail.sh:file_size` 교체 (GNU 우선 + 숫자 검증)
- [ ] `.claude/hooks/lib/portable.sh` 신규 (4개 함수)
- [ ] `pre-edit-dod-gate.sh`, `pre-bash-guard.sh`, `trail-rotate.sh` 중복 helper → portable.sh source
- [ ] `.gitattributes` 신규 (LF 강제)

### 테스트
- [ ] `test-stat-portability.sh` 에 portable.sh 함수 단위 테스트 추가
- [ ] `bash tests/hooks/run-all.sh` 전체 green
- [ ] Linux 환경에서 session-start 훅이 깨지지 않는지 수동 검증 (가능하면 Docker)

### 문서
- [ ] `README.md` + `README.en.md` 지원 플랫폼 섹션 + WSL2 설치 안내
- [ ] `REIN_SETUP_GUIDE.md` Windows 안내 줄
- [ ] `need-to-confirm.md` 후속 이슈 항목에 "v0.9.0 해결" 표기
- [ ] README 버전 히스토리 v0.9.0 엔트리 (간략 1~2줄)

### 리뷰 & 릴리즈
- [ ] Codex 리뷰 통과 (`trail/dod/.codex-reviewed`)
- [ ] Security 리뷰 통과 (`trail/dod/.security-reviewed`)
- [ ] main 선별 체크아웃 + tag `v0.9.0`

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex           # 코드 리뷰
mcps: []
rationale: >
  3개 단계(hotfix + 헬퍼 공통화 + docs) 모두 기존 훅/스크립트 수정 중심.
  feature-builder 가 '기존 서비스/모듈 변경' 전담이라 범위 일치.
  신규 skill/MCP 없이 완결 가능.
  /codex 는 규칙상 필수 후속 단계.
approved_by_user: true
```

---
## dod-2026-04-20-incident-agent-eligible.md (mtime: 2026-04-29, archived: 2026-04-30)
# Incident `agent_eligible` 분류 필드

- 날짜: 2026-04-20
- 유형: feat (skill + script)
- 대상 브랜치: dev → main
- 릴리스: v0.10.0 의 4/4
- covers: [ae-1, ae-2, ae-3, ae-4]

## 배경

need-to-confirm.md 후속 이슈 3. 현재 `/incidents-to-agent` 는 pattern_hash `count >= 3` 만 보고 후보 스텁을 생성한다. bug/artifact 성격 (hook 소스 수정으로 해결 가능한 false-positive 등) 이 섞여서 사용자가 반복적으로 decline 해야 하고, 학습 데이터 오염과 UX 노이즈 비용이 발생한다. 분류는 aggregate 단계가 아니라 **triage 단계 (incidents-to-rule 분석 시점)** 에 들어가는 게 맞다.

## 변경 대상

### ae-1: `.claude/skills/incidents-to-rule/SKILL.md` frontmatter 필드 추가

incidents-to-rule 이 생성하는 incident 파일 frontmatter 에 다음 필드 포함:

```yaml
---
pattern_hash: <hash>
hook: <hook-name>
reason: <reason>
count: <n>
agent_eligible: true | false | unknown
root_cause: bug | missing_rule | missing_agent | tooling | user_error | unknown
---
```

- `agent_eligible`:
  - `true` — 이 패턴은 규칙/에이전트로 해결 가능 (incidents-to-agent 대상 가능)
  - `false` — bug/artifact (hook 소스 수정으로 해결. agent 후보 아님)
  - `unknown` — 분류 보류 (기본값, 과거 파일 backfill 면제용)
- `root_cause`: 보조 정보 (분석 근거 기록). incidents-to-agent 필터에는 직접 사용 안 함
- SKILL.md body 에 분류 기준 가이드 추가:
  - "hook 소스 수정으로 해결 가능한 regex/pattern 문제는 `agent_eligible: false`"
  - "사용자 워크플로우 일관성 부족 (커밋 전 리뷰 누락 등) 은 `agent_eligible: true`"
  - "처음 분석 시 확신 없으면 `unknown` 유지 (보수적)"

### ae-2: `scripts/rein-mark-incident-processed.py` 확장

- 기존 `processed`/`declined` 마킹 외에 frontmatter 필드 편집 지원
- 새 옵션: `--set-agent-eligible {true,false,unknown}`, `--set-root-cause <str>`
- 기존 마킹과 동시 적용 가능: `rein-mark-incident-processed.py <file> --processed --set-agent-eligible false --set-root-cause bug`
- `incidents-to-rule` 스킬이 분석 후 이 명령으로 frontmatter 를 기록하도록 body 에 예시 추가
- 기존 호출이 깨지지 않도록 새 옵션은 모두 선택적 (argparse default)

### ae-3: `.claude/skills/incidents-to-agent/SKILL.md` Step 1 조건 갱신

기존:
```
Step 1: trail/incidents/auto-*.md 중 count >= 3 인 것을 찾는다
```

변경:
```
Step 1: trail/incidents/auto-*.md 중 아래 조건을 모두 만족하는 것을 찾는다:
  - count >= 3
  - agent_eligible != false  (없거나 unknown/true 는 허용)
```

- `agent_eligible: false` 로 분류된 패턴은 "bug/artifact bucket" 으로 분리 (별도 섹션으로 안내 — 사람이 hook 소스 수정으로 해결할 대상)
- body 에 "왜 이 분류가 필요한가" 짧은 근거 (이슈 3 배경)
- 기존 incident 파일 (frontmatter 에 `agent_eligible` 필드 없음) 은 `unknown` 으로 해석하여 통과 → backfill 불필요

### ae-4: 회귀 테스트

`tests/scripts/test-incident-agent-eligible.sh` (신규):
- case 1: `count=3, no agent_eligible field` → /incidents-to-agent 대상 (기존 동작 보존)
- case 2: `count=3, agent_eligible: false` → /incidents-to-agent 대상에서 제외
- case 3: `count=3, agent_eligible: true` → 대상
- case 4: `count=3, agent_eligible: unknown` → 대상
- case 5: `count=2, agent_eligible: true` → 대상 아님 (count 조건 우선)
- case 6: `rein-mark-incident-processed.py --set-agent-eligible false` 가 frontmatter 에 필드를 정상 기록

## 설계 원칙

### 하위 호환

- 기존 incident 파일: 필드 없음 = `unknown` 해석 → 동작 변화 없음
- 기존 `rein-mark-incident-processed.py` 호출: 새 옵션 없이 부를 때 동작 변화 없음
- 기존 `/incidents-to-agent` 호출: 조건이 `count >= 3` 에서 `count >= 3 AND agent_eligible != false` 로 엄격해지지만, 기존 파일은 `unknown` 이므로 통과

### 필터 지점

- aggregate 단계가 아니라 incidents-to-rule **분석 시점** 에 사람 (또는 스킬) 이 분류 → frontmatter 기록
- 자동화 가능 범위: 스킬이 hook 이름/reason 패턴으로 1차 추정 (예: `pre-bash-guard` + `regex false positive` → `agent_eligible: false` 추정) 후 사용자 확인

## DoD 체크리스트

- [ ] `.claude/skills/incidents-to-rule/SKILL.md` frontmatter 필드 + 분류 가이드 추가
- [ ] `scripts/rein-mark-incident-processed.py` 새 옵션 추가 + 기존 호출 호환
- [ ] `.claude/skills/incidents-to-agent/SKILL.md` Step 1 조건 갱신
- [ ] `tests/scripts/test-incident-agent-eligible.sh` 신규 (6 케이스)
- [ ] `bash tests/scripts/run-all.sh` green (이슈 2 의 run-all 과 연동)
- [ ] Codex 통합 리뷰 통과

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex
mcps: []
rationale: >
  skill 문서 + Python 스크립트 + 회귀 테스트. feature-builder 범위.
  기존 incident 파이프라인 로직 이해 필요.
approved_by_user: true
```

---
## dod-2026-04-20-rein-copyfile-exec-bit.md (mtime: 2026-04-29, archived: 2026-04-30)
# DoD: rein.sh copy_file exec bit 전파 핫픽스

- 시작일: 2026-04-20
- 유형: fix (hotfix)
- 버전: v0.9.1
- 관련 이슈: `rein init` / `rein merge` 후 기존 프로젝트의 hook 파일이 `-rw-rw-r--` (exec bit 없음) 상태로 남아 `post-write-spec-review-gate.sh: Permission denied` 발생

## 문제

`scripts/rein.sh:copy_file()` 는 `cp "$src" "$dst"` 만 수행. POSIX `cp` 는 **dst 가 이미 존재할 때 기존 파일의 mode 를 변경하지 않는다**. 결과:

1. 과거 버전(hook 파일이 git tree 에 100644 로 커밋돼 있던 시절)에 `rein init` 된 프로젝트는 hook 이 644 로 설치됨
2. 이후 `rein merge` 로 컨텐츠는 갱신되지만 mode 는 644 그대로
3. Claude Code 가 훅 실행 시 `/bin/sh: ...: Permission denied`

사용자 보고 사례(chunk-smith 프로젝트): `.claude/hooks/post-write-spec-review-gate.sh` 가 `-rw-rw-r--`.

## 변경 대상

- `scripts/rein.sh` — `copy_file()` 에서 source 가 실행 가능(`-x`)이면 dst 에도 `chmod +x` 전파
- `scripts/rein.sh` — VERSION `0.9.0` → `0.9.1`
- `tests/cli/test-install.sh` 또는 신규 `test-copy-file-mode.sh` — 회귀 테스트 (source exec bit → dst 에 exec bit)
- `CHANGELOG.md` — v0.9.1 엔트리
- `README.md` — 버전 히스토리 엔트리 (간략 1줄)

## 수락 기준

1. `copy_file()` 실행 후 dst 가 훅으로 **실행 가능**해야 함 (Permission denied 재발 방지):
   - src 가 실행 가능하고 dst 가 비실행이면 → dst 에 exec bit 승격 (`chmod +x`)
   - src 가 비실행이면 → dst mode 손대지 않음 (기존 exec bit 유지/비유지 모두 포함)
   - **비범위**: src 의 exact mode parity (예: 0700 ↔ 0755 구분) 는 이번 hotfix 범위 아님 → v0.9.2 후속 (`need-to-confirm.md` 기록)
2. 회귀 테스트가 위 계약을 검증 (4 케이스)
3. 기존 `tests/cli/test-install.sh`, `test-self-update.sh`, `test-manifest-prune.sh` 통과
4. CHANGELOG + README 정합

## 비범위

- 사용자가 이미 설치한 프로젝트의 **기존 파일** 자동 복구는 하지 않음 (다음 `rein merge` 때부터 정상 동작). 즉시 복구는 사용자가 `chmod +x .claude/hooks/*.sh` 로 수동 처리.
- macOS/Linux 외 플랫폼(WSL2 는 Linux 로 간주).

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - test-driven-development
  - verification-before-completion
mcps: []
rationale: |
  scripts/rein.sh 의 기존 함수 한 군데 수정 + 회귀 테스트 추가. 신규 모듈/
  아키텍처 변경 없음. TDD 로 회귀 테스트를 먼저 쓰고 구현 → verify 순서가
  자연스럽다. 외부 API/라이브러리 조사 불필요이므로 MCP 없음.
approved_by_user: true
```

---
## dod-2026-04-20-tests-ci.md (mtime: 2026-04-29, archived: 2026-04-30)
# Tests CI workflow — 전체 green 자동 검증

- 날짜: 2026-04-20
- 유형: feat (infra)
- 대상 브랜치: dev (main 제외 — rein-dev 전용)
- 릴리스: v0.10.0 의 1/4
- covers: [ci-1, ci-2, ci-3]

## 배경

need-to-confirm.md 후속 이슈 2. v0.8.0 plan 실행 중 `tests/hooks/test-skill-mcp-inventory.sh` 의 `test_dod_warning_active_dod_only` 가 이미 세션 시작 HEAD 에서 실패 중이었던 사실이 드러남. 원인: 릴리스 워크플로우에 "전체 테스트 green" 자동 게이트 부재. 개별 세션이 자기 변경분만 검증하고, 사전에 깨진 테스트를 세션마다 놓치고 있었다.

## 변경 대상

- **ci-1**: `.github/workflows/tests.yml` (신규)
  - trigger: `push` (main + dev), `pull_request` (target main + dev)
  - matrix: `ubuntu-latest` (primary, WSL2 환경 대변), `macos-latest` (primary, Darwin 커버)
  - advisory: `windows-latest` (Git Bash shell, `continue-on-error: true` — 호환성 탐지용)
  - steps: checkout → bash/python 버전 확인 → `bash tests/hooks/run-all.sh` → `bash tests/scripts/run-all.sh`
- **ci-2**: `tests/scripts/run-all.sh` (신규)
  - `tests/scripts/*.sh` 를 개별 bash 프로세스로 순회 실행 (wildcard 한 줄 호출 금지 — 쉘 인자 누출 방지)
  - 실패한 suite 이름 수집 후 말미에 종합 결과 출력
  - exit code: 하나라도 실패 시 1
  - `tests/hooks/run-all.sh` 와 동일한 출력 포맷으로 통일
- **ci-3**: rein-dev 전용 범위 확인
  - `scripts/rein.sh:COPY_TARGETS` 화이트리스트에 `.github/workflows/tests.yml` 이 들어가지 않도록 확인 (사용자 프로젝트에 복사되지 않아야)
  - `.claude/rules/branch-strategy.md` 의 main 제외 목록에 명시 (이미 "tests/** 는 main 제외" 있으나 workflow 파일도 명시적으로)
  - `.github/workflows/mirror-to-public.yml` 의 strip 로직 검토 (공개 rein 레포로 복사되면 안 됨)

## 설계 원칙

### tests.yml 구조

```yaml
name: tests
on:
  push:
    branches: [main, dev]
  pull_request:
    branches: [main, dev]
jobs:
  hooks:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Show bash/python versions
        run: bash --version && python3 --version
      - name: Run hook tests
        run: bash tests/hooks/run-all.sh
      - name: Run script tests
        run: bash tests/scripts/run-all.sh
  hooks-windows:
    runs-on: windows-latest
    continue-on-error: true
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - name: Run hook tests (advisory)
        run: bash tests/hooks/run-all.sh
```

### run-all.sh 패턴

기존 `tests/hooks/run-all.sh` 와 동일한 인터페이스 (순회 + 실패 수집 + 종합 출력). 각 `.sh` 를 별도 `bash <file>` 로 실행하여 한 파일의 failure 가 다른 파일로 전염되지 않게.

## DoD 체크리스트

- [ ] `.github/workflows/tests.yml` 신규 — push/PR 트리거, ubuntu+macOS matrix, windows advisory
- [ ] `tests/scripts/run-all.sh` 신규 — 개별 bash 순회
- [ ] 로컬에서 `bash tests/hooks/run-all.sh` + `bash tests/scripts/run-all.sh` 모두 green
- [ ] `scripts/rein.sh` COPY_TARGETS 에 `.github/workflows/tests.yml` 없음 확인
- [ ] `.github/workflows/mirror-to-public.yml` 가 `tests.yml` 을 strip 하는지 확인 (필요 시 추가)
- [ ] Codex 통합 리뷰 (이슈 5·4·3 완료 후 일괄)
- [ ] push 후 GitHub Actions 에서 실제 green 확인

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex           # 최종 리뷰
mcps: []
rationale: >
  infra 작업 — workflow yml + bash runner 추가. 기존 테스트 구조 재활용.
  feature-builder 가 범위 일치. /codex 는 일괄 리뷰 단계에서 사용.
approved_by_user: true
```

---
## dod-2026-04-20-v011-workflow-hardening.md (mtime: 2026-04-29, archived: 2026-04-30)
# v1.0.0 workflow hardening — codex skill 분리 (clean break) + docs 경로 정리 + plan-writer 자동화

> 파일명은 원본(v011) 유지. Codex spec review 피드백 반영으로 **major v1.0.0** 으로 상향.

- 날짜: 2026-04-20
- 유형: refactor + docs (workflow tooling, **major/breaking**)
- 대상 브랜치: dev → main (릴리즈)
- 버전: v0.10.1 → **v1.0.0**
- covers: [C1, C2, C3, C4, D1, D2, D3, D4, D5, A1, A2, A3, A4]

## 배경

`need-to-confirm.md` 2026-04-20 기록의 미해결 이슈 3건을 하나의 릴리즈로 번들. **Codex spec review [NEEDS-FIX] 피드백을 반영해 major v1.0.0 으로 상향**:

1. **Issue 1 (codex skill 분리)** — clean break: `/codex review`, `/codex ask`, `/codex` 전부 제거하고 `/codex-review`, `/codex-ask` 로 교체. deprecation wrapper 없음.
2. **Issue 2 (docs rename)** — 전체 확장: `reports/` 포함 4 폴더 이동, tests + README.en + stamp migration + moved docs 내부 ref 포함.
3. **Issue 3 (plan-writer 자동화)** — 축소: auto-review + PASS auto-stamp + NEEDS-FIX handoff. self-fix loop 제거. `[NON_INTERACTIVE]` prompt marker 기반.

**영향 범위** (코덱스 지적 반영, 과소추정 교정):
- Issue 1 = slash command rename (breaking) — migration guide 필수
- Issue 2 = 33 파일 이동 + 10 파일 하드코드 + test + stamp migration
- Issue 3 = 내부 워크플로우, breaking 아님

## 변경 범위

### Issue 1 — codex skill 분리 (clean break, C1-C4)

**현재**: `.claude/skills/codex/SKILL.md` 단일 파일에 `/codex review` + `/codex ask` 하위 명령어. `/codex` 단독 = review 로 backward compat.

**목표**: 명시적 2개 skill 로 분리 + 기존 alias 전부 제거.

**변경**:
- `.claude/skills/codex-review/SKILL.md` (신규, C1) — Mode A 로직 + non-interactive 명세 (A1 에서 확장)
- `.claude/skills/codex-ask/SKILL.md` (신규, C2) — Mode B 로직
- `.claude/skills/codex/SKILL.md` + 디렉토리 제거 (C3)
- **C4 (신규 scope)** — 모든 `/codex*` 참조 갱신. codex review 가 지적한 파일 포함:
  - `AGENTS.md`, `README.md`, `README.en.md`, `CHANGELOG.md`
  - `.claude/orchestrator.md`, `.claude/CLAUDE.md`
  - `.claude/rules/subagent-review.md`
  - `.claude/agents/plan-writer.md`, `.claude/agents/security-reviewer.md`, `.claude/agents/feature-builder.md`
  - `.claude/skills/code-reviewer/SKILL.md`, `.claude/skills/brainstorming/SKILL.md`
  - `/codex review` → `/codex-review`, `/codex ask` → `/codex-ask`. 단독 `/codex` 는 제거 + migration 주석
  - (`.claude/cache/skill-mcp-*.{md,json}` 은 hook 이 자동 재생성 — 수동 갱신 불필요)

### Issue 2 — docs rename (범위 확장, D1-D5)

**D1 — 4 폴더 일괄 이동** (`docs/superpowers/{specs,plans,brainstorms,reports}` → `docs/{specs,plans,brainstorms,reports}`). 33 파일 이동.

**D2 — 경로 하드코드 치환** (10 파일):
- `.claude/orchestrator.md`
- `.claude/rules/design-plan-coverage.md`
- `.claude/rules/branch-strategy.md` (D3 에서 별도)
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/writing-plans/SKILL.md`
- `AGENTS.md`
- `README.md`, `README.en.md`
- `CHANGELOG.md` (이미 있는 언급)
- `tests/hooks/test-spec-review-gate.sh` (D4 에서 별도)

+ **moved docs 내부 cross-ref** 도 grep 후 갱신.

**D3 — branch-strategy.md 제외 목록 업데이트**:
- `docs/superpowers/specs/**` → `docs/specs/**`
- `docs/superpowers/plans/**` → `docs/plans/**`
- `docs/brainstorms/**` 추가 (이전에 명시적 행 없음)
- `docs/reports/**` 추가 (신규 — 메인테이너 활동 로그)

**D4 (신규 scope) — tests/hooks/test-spec-review-gate.sh 갱신**:
- 라인 15-20 의 canonical path 하드코드 `docs/superpowers/specs/...` → `docs/specs/...`
- 다른 테스트 파일에 `docs/superpowers/` 하드코드 있으면 함께 갱신

**D5 (신규 scope) — spec-review stamp migration**:
- `trail/dod/.spec-reviews/*.{pending,reviewed}` hash 는 absolute path 기반 (`scripts/rein-mark-spec-reviewed.sh` line 20-21, 39-41 참조)
- `git mv` 로 파일 이동 후 기존 stamp 는 stale (새 path hash 와 다름)
- **Migration step**: rename 직후 기존 `.spec-reviews/*` 전부 삭제 + `docs/specs/`, `docs/plans/` 내 현재 "active" design/plan 에 대해 marker 재생성
- `.reviewed` marker 의 `path=` 필드도 새 경로로 갱신
- 이 step 은 D1 직후 실행 — AGENTS.md §93-100 "rename 시 marker migration" 조항 준수

### Issue 3 — plan-writer 축소 자동화 (A1-A3)

**A1 — codex-review skill 에 non-interactive 명세**:
- ~~`REIN_CODEX_AUTOMATED=1` env 분기~~ → **`[NON_INTERACTIVE]` prompt marker** 사용 (codex review 피드백)
- Env 는 bash 직접 호출 경로 (`codex exec` 직접 실행) 에서만
- Invocation contract:
  - prompt 앞부분에 `[NON_INTERACTIVE]` 토큰 포함 시 AskUserQuestion skip
  - 기본값: `gpt-5.4` / `high` / `read-only`
  - prompt 내부에 `[MODEL:...]` / `[EFFORT:...]` override 가능

**A2 — plan-writer workflow 확장 (축소 자동화)**:
- validator 통과 이후 **자동 1회** codex-review 호출 (`[NON_INTERACTIVE]` marker)
- **PASS** → stamp 생성 + handoff to `subagent-driven-development`
- **NEEDS-FIX / REJECT** → **즉시** handoff (self-fix loop 없음). review output 그대로 사용자에게 전달. spec-review `.pending` marker 유지
- Rationale (codex 피드백): auto self-fix 는 structured verdict/diff protocol 부재로 기술적 미완성. "auto-review + PASS auto-stamp + NEEDS-FIX handoff" 로 축소가 사용자 불만 (수동 trigger) 핵심 해결

**A3 — stamp 자동 생성 통합**:
- PASS 시 plan-writer 가 `bash scripts/rein-mark-spec-reviewed.sh <plan-path> codex-gpt-5.4-high-automated` 호출
- reviewer 문자열에 `-automated` suffix (수동/자동 구분)
- 수동 `/codex-review` 호출 경로는 기존 수동 stamp 유지 (backward compat)

### Release (A4)

- `scripts/rein.sh` VERSION `0.10.1` → **`1.0.0`** (major)
- `CHANGELOG.md` v1.0.0 엔트리 — Breaking changes 명시
- `README.md` + `README.en.md` 버전 히스토리 v1.0.0
- `need-to-confirm.md` 3 이슈 해결 표기

## Out of scope

- `/codex` / `/codex review` / `/codex ask` backward compat alias — **포함 안 함** (clean break)
- `docs/superpowers/` 잔여 파일 (없음 — 4 폴더 전부 이동)
- 다른 agent 의 auto codex review 확대 — plan-writer 만
- `apply_codex_diffs()` 구조화 프로토콜 — v1.1 이후 후보
- 기존 완료된 DoD 파일 내 `docs/superpowers` 참조 backfill — archive 취급. rename migration 시 dead link 가능성 인지 + CHANGELOG 에 언급

## DoD 체크리스트

### Phase 1 — docs rename (D1-D5, 커밋 1)
- [ ] `git mv docs/superpowers/specs docs/specs` (18 files)
- [ ] `git mv docs/superpowers/plans docs/plans` (13 files)
- [ ] `git mv docs/superpowers/brainstorms docs/brainstorms` (1 file)
- [ ] `git mv docs/superpowers/reports docs/reports` (1 file)
- [ ] `rmdir docs/superpowers` (empty 확인)
- [ ] 10 파일 하드코드 치환 (D2)
- [ ] moved docs 내부 cross-ref grep 후 갱신
- [ ] branch-strategy.md 제외 목록 업데이트 + brainstorms/reports 추가
- [ ] tests/hooks/test-spec-review-gate.sh canonical path 갱신
- [ ] Stamp migration — 기존 `.spec-reviews/*` 정리 + 새 경로 marker 재생성
- [ ] `grep -rn "docs/superpowers" .claude AGENTS.md README.md README.en.md CHANGELOG.md tests docs` 전부 0 match
- [ ] `bash tests/hooks/run-all.sh` green

### Phase 2 — codex skill 분리 (C1-C4, 커밋 2)
- [ ] `.claude/skills/codex-review/SKILL.md` 신규 (Mode A + A1 non-interactive placeholder)
- [ ] `.claude/skills/codex-ask/SKILL.md` 신규 (Mode B)
- [ ] `.claude/skills/codex/` 제거
- [ ] `/codex` / `/codex review` / `/codex ask` 참조 14+ 파일 전부 `/codex-review` / `/codex-ask` 로 교체
- [ ] CHANGELOG breaking change 명시 (v1.0.0 엔트리)
- [ ] migration guide 추가 — README + CHANGELOG

### Phase 3 — plan-writer 자동화 (A1-A3, 커밋 3)
- [ ] codex-review/SKILL.md 의 Non-interactive mode 본문 작성 — `[NON_INTERACTIVE]` prompt marker 기반
- [ ] plan-writer workflow 확장 — auto review 1회 → PASS stamp / NEEDS-FIX handoff
- [ ] self-fix loop **미포함** 확인 (기술적 미완성 — 의도적 out of scope)
- [ ] stamp 자동 생성 통합 — reviewer=`codex-gpt-5.4-high-automated`
- [ ] 수동 호출 경로 보존 확인

### Phase 4 — Release (A4, 커밋 4)
- [ ] `scripts/rein.sh` VERSION → `1.0.0`
- [ ] CHANGELOG v1.0.0 엔트리 (Breaking / Added / Changed)
- [ ] README (ko/en) 버전 히스토리 v1.0.0
- [ ] need-to-confirm.md 3 이슈 해결 표기
- [ ] dogfooding 검증 — 이번 릴리즈의 plan 자체가 자동 codex review 경로 테스트

### 리뷰 & 릴리즈
- [ ] 커밋 2 완료 시점 checkpoint `/codex-review` 1차 (자기 자신 dogfooding)
- [ ] Phase 4 완료 후 최종 `/codex-review` 2차
- [ ] `security-reviewer` 실행
- [ ] `trail/dod/.codex-reviewed` + `.security-reviewed` stamps
- [ ] `bash tests/hooks/run-all.sh` + `bash tests/scripts/run-all.sh` green
- [ ] dev commit/push → main 선별 체크아웃 → tag `v1.0.0` + push

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - writing-plans   # design → plan 작성 (이 세션)
  - codex           # spec review + 최종 코드 리뷰 (현 skill. Phase 2 완료 후엔 codex-review 로 전환)
mcps: []
rationale: >
  3개 이슈 모두 .claude/ 내 skill/agent/hook/rule 재배치 + rename + 워크플로우 자동화.
  feature-builder 가 '기존 서비스/모듈 변경' 전담이라 범위 일치.
  Issue 3 은 Codex 지적 반영해 축소 — self-fix 제거로 brainstorming skill 제외.
  신규 에이전트나 MCP 불필요.
approved_by_user: true
```

---
## dod-2026-04-20-windows-git-bash-hardening.md (mtime: 2026-04-29, archived: 2026-04-30)
# Windows Git Bash / MSYS 호환성 hardening — Python resolver + JSON extractor helper

- 날짜: 2026-04-20
- 유형: fix + refactor + docs
- 대상 브랜치: dev → main (릴리즈)
- 버전: v0.10.0 → v0.10.1
- covers: [WGB-1, WGB-2, WGB-3, WGB-4, WGB-5, WGB-6, WGB-7, WGB-8, WGB-9, WGB-10, WGB-11, WGB-12, WGB-13, WGB-14]

## 배경

Windows 사용자가 Claude Code for Windows + Git Bash 조합에서 모든 `Edit/Write/Bash` 도구가 훅에 의해 차단되는 증상을 보고 (로그: `~/Downloads/rein_test_260420.txt`, 2026-04-20). 증상은 `pre-bash-guard.sh` 와 `pre-edit-dod-gate.sh` 가 둘 다 `python3 exit 49` 로 실패 → fail-closed 차단.

Codex 독립 분석 (gpt-5.4 / high reasoning, 2026-04-20) 로 근본원인 확정:

1. **exit 49 의 정체**: Windows shell 의 `9009` (command not found / App Execution Alias stub 실행 실패) 가 Git Bash/MSYS 에서 8비트 잘림 → `9009 % 256 = 49` 로 노출. 로그의 `49` 는 Python 의 JSON 파싱 실패가 아니라 Windows 런처 실패의 잔재.
2. **취약 패턴**: 훅이 `command -v python3` 통과 여부만 확인하고 실제 인터프리터 여부는 검증 안 함. 사용자 환경의 `python3` 는 WindowsApps App Execution Alias stub 을 가리키고 있었음.
3. **Drift**: v0.9.0 portability 패치는 `stat/date` 계열 이식성과 LF/README 가이드에 집중. "Python 실행기 탐지" + "JSON stdin 추출 robustness" 는 건드리지 않아서 이번 케이스를 못 잡음.

## 변경 범위 — 전수

사용자 요청에 따라 **`echo "$INPUT" | python3 -c` 패턴을 쓰는 훅 8개 전체** 를 리팩터한다. 단, heredoc/env/파일 경유 Python 호출(best-effort 성격) 은 v0.10.1 범위 밖.

### 1단계 — Helper 신규 (WGB-1, WGB-2)

- **WGB-1**: `.claude/hooks/lib/python-runner.sh` 신규
  - `resolve_python()` — sourcing 시 `PYTHON_RUNNER` 환경변수 설정
  - Fallback chain: `$REIN_PYTHON` → MSYS/Cygwin/MinGW 감지 시 `py -3` 우선 → `python3` → `python`
  - Health check: `command -v` 뿐 아니라 실제 `-c "import sys; sys.exit(0)"` 실행 성공 여부까지 검증
  - WindowsApps App Execution Alias stub 경로 감지 (`*WindowsApps*python*.exe`) → 별도 진단 메시지
  - 실패 시 구체적 exit code (10/11/12) 로 구분
- **WGB-2**: `.claude/hooks/lib/extract-hook-json.py` 신규
  - argparse CLI: `--field <dotted.path>` (반복 가능), `--default ""` (옵션), `--stdin` (기본) / `--input-file PATH` (Windows 안전)
  - dotted path 지원 (`tool_input.file_path`, `tool_response.files[0].path` 등)
  - exit code 스킴: 0(성공) / 20(invalid JSON) / 21(field missing 이지만 --default 로 재량) / 22(decode/encoding failure)
  - stdout 은 추출 값만, stderr 은 진단 (훅이 2>/dev/null 선택 가능)

### 2단계 — 훅 리팩터 (WGB-3 ~ WGB-10)

각 훅의 inline `echo "$INPUT" | python3 -c ...` 블록을 `. "$SCRIPT_DIR/lib/python-runner.sh"` source + `printf '%s' "$INPUT" | "$PYTHON_RUNNER" "$SCRIPT_DIR/lib/extract-hook-json.py" --field ...` 로 교체.

- **WGB-3**: `pre-edit-dod-gate.sh:91` — `tool_input.file_path`. fail-closed 유지, Windows-specific 진단 추가.
- **WGB-4**: `pre-bash-guard.sh:72` — `tool_input.command`. fail-closed 유지. `extract-commit-msg.py` helper 경로(`:211`)도 resolver 사용하도록 확인.
- **WGB-5**: `post-write-dod-routing-check.sh:26` — `tool_input.file_path`. silent (post-hook). resolver 실패 시 skip.
- **WGB-6**: `post-edit-hygiene.sh:8` — `tool_input.file_path`. silent.
- **WGB-7**: `post-edit-review-gate.sh:14` — `tool_response.files[*].path` (multi). silent.
- **WGB-8**: `post-edit-index-sync-inbox.sh:19` — `tool_input.file_path` (개행 정제). silent.
- **WGB-9**: `post-edit-plan-coverage.sh:17` — multi-field. silent. abspath 변환(`:80`)은 기존 유지 (arg-based → 안전).
- **WGB-10**: `post-write-spec-review-gate.sh:15` — multi-field. silent. abspath 변환(`:77`)은 기존 유지.

### 3단계 — 에러코드 + 진단 표준화 (WGB-11)

- `python-runner.sh` 가 설정하는 `PYTHON_RUNNER_STATUS` 변수 또는 exit code 를 기준으로 각 훅의 `BLOCKED:` 메시지를 표준화.
- Windows Git Bash/MSYS/Cygwin 환경에서 `python3 exit 49 (= 9009 on Windows)` 감지 시 전용 메시지:
  > `BLOCKED: real Python runtime unavailable in Windows Git Bash/MSYS. python3 returned Windows-style 9009 (mod 256 = 49). Action: (1) switch to WSL2 (recommended, see README), or (2) disable "python.exe" App execution alias in Windows Settings, or (3) install real Python and ensure "py -3" precedes WindowsApps in PATH.`
- post-hook (silent) 경로는 진단을 stderr 에 남기되 exit 0 유지.

### 4단계 — 회귀 테스트 (WGB-12)

- `tests/hooks/test-python-runner.sh` (신규)
  - fake `python3` (exit 49) + fake `py -3` (정상) + fake `uname`(`MINGW64_NT-10.0`) 조합 → fallback 성공 검증
  - WindowsApps 경로를 가리키는 fake `python3` → stub 전용 진단 메시지 검증
  - `REIN_PYTHON` override 우선순위 검증
  - 모든 후보 실패 시 exit 10 반환 검증
- `tests/hooks/test-extract-hook-json.sh` (신규)
  - valid JSON / invalid JSON / missing field / CRLF payload / Unicode / `C:/...` 경로 / `docs\...` 백슬래시 경로
  - `--field` 반복, dotted path, 배열 인덱스, `--default` 동작
  - exit code 20/21/22 분기 검증
- `tests/hooks/test-dod-gate.sh`, `test-pre-bash-guard.sh` 등 기존 테스트
  - fake `python3 exit 49` 를 주입해 "Windows-style 실패 시 구체적 진단과 함께 exit 2" 확인
  - 정상 환경 (macOS/Linux) 에서는 기존 회귀 테스트 그대로 통과

### 5단계 — CI (WGB-13)

- `.github/workflows/tests.yml` `tests-windows-advisory` job 확장:
  - GitHub Actions windows-latest 러너는 실제 Python 이 깔려 있어 stub 문제를 재현 못함
  - 별도 step 추가: fake `python3` stub (`/tmp/fake-python/python3` 가 `exit 49`) 을 PATH 앞에 얹고 hook 테스트 일부 실행 → resolver fallback 경로가 green 인지 확인
  - continue-on-error 유지 (advisory)

### 6단계 — 문서 (WGB-14)

- `README.md` / `README.en.md` — Windows 지원 매트릭스 근처에 다음 추가:
  - 진단 3종 명령: `command -v python3`, `python3 -V`, `py -3 -V`
  - "alias 만으로는 비대화형 훅에 안 먹을 수 있음" 경고
  - Git Bash 유지 시 App execution alias 끄는 경로 + real Python 설치 순서
- `REIN_SETUP_GUIDE.md` — Windows 사용자 체크리스트에 위 진단 명령 반영
- `need-to-confirm.md` — 이 이슈를 "v0.10.1 에서 해결" 로 마감 기록
- `CHANGELOG.md` v0.10.1 엔트리:
  - fix: Windows Git Bash/MSYS 환경의 python3 stub 실패를 실제 실패로 인식하고 진단
  - refactor: 8개 훅의 inline JSON 파싱을 공용 helper 로 통합
  - test: fake python stub/fallback 회귀 커버
  - 주의: "`exit 0` 로 바꿔 우회하는 방법은 fail-open 전환 = gate 무력화 — 지원하지 않음"
- README 버전 히스토리 v0.10.1 엔트리

## Out of scope (v0.10.1)

- `stop-session-gate.sh:51` 의 `python3 -` heredoc (SUMMARY env) — best-effort, non-blocking. v0.11 후보.
- `session-start-load-trail.sh:111, 211, 212` 의 파일 기반 `python3 -c` — best-effort, non-blocking. v0.11 후보.
- `pre-edit-dod-gate.sh:35`, `pre-bash-guard.sh:19` 의 `python3 - <<'PY'` blocks.jsonl append heredoc — 이미 `2>/dev/null`, best-effort. v0.11 후보.
- heredoc 기반 incident aggregator (`pre-*.sh:50-67` count 집계) — 이미 `|| echo 0` 으로 degrade. v0.11 에서 resolver 적용 검토.
- 기존 `extract-commit-msg.py` 의 구조 재설계 (`pre-bash-guard.sh:211`) — 이미 helper 분리. resolver 만 적용.

## 설계 원칙

### 공통 helper source 규약

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/python-runner.sh
. "$SCRIPT_DIR/lib/python-runner.sh"
# 이 시점에 $PYTHON_RUNNER 가 검증된 실행 파일 경로로 설정됨
# resolver 실패 시 pre-* 훅은 exit 2 (BLOCK), post-* 훅은 exit 0 (skip)
```

### Python resolver 스케치

```bash
resolve_python() {
  local candidates=() c
  [[ -n "${REIN_PYTHON:-}" ]] && candidates+=("$REIN_PYTHON")
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) candidates+=("py -3") ;;
  esac
  candidates+=("python3" "python")

  for c in "${candidates[@]}"; do
    # command -v 먼저
    local cmd_head="${c%% *}"
    command -v "$cmd_head" >/dev/null 2>&1 || continue
    # 실제 실행까지 검증 (Windows App Execution Alias stub 걸러냄)
    if $c -c "import sys; sys.exit(0)" >/dev/null 2>&1; then
      # WindowsApps stub 경로 방어
      local resolved; resolved=$(command -v "$cmd_head")
      case "$resolved" in
        *WindowsApps*) continue ;;
      esac
      PYTHON_RUNNER="$c"
      return 0
    fi
  done
  return 10
}
```

### fail-closed 유지, 메시지만 구체화

로그에 제시된 "파싱 실패 시 `exit 0`" 우회는 **채택하지 않는다**. fail-open 전환은 `pre-bash-guard` + `pre-edit-dod-gate` 의 gate 전체를 무력화 = DoD 없는 source edit, 위험 Bash, review gate 우회가 조용히 통과. v0.10.1 은 fail-closed 유지 + 메시지만 구체화하여 사용자가 **진짜 원인(Windows stub)** 을 바로 알 수 있도록 한다.

## DoD 체크리스트

### 코드 변경
- [ ] `.claude/hooks/lib/python-runner.sh` 신규 (resolve_python + health check + stub 감지)
- [ ] `.claude/hooks/lib/extract-hook-json.py` 신규 (argparse + dotted path + exit 20/21/22)
- [ ] 8개 훅 refactor: pre-edit-dod-gate / pre-bash-guard / post-write-dod-routing-check / post-edit-hygiene / post-edit-review-gate / post-edit-index-sync-inbox / post-edit-plan-coverage / post-write-spec-review-gate
- [ ] pre-* 훅 2개: Windows-specific BLOCKED 메시지 (9009 → 49 mapping 설명)
- [ ] `extract-commit-msg.py` 호출 경로도 resolver 사용 확인

### 테스트
- [ ] `tests/hooks/test-python-runner.sh` 신규
- [ ] `tests/hooks/test-extract-hook-json.sh` 신규
- [ ] 기존 `test-dod-gate.sh` / `test-pre-bash-guard.sh` 등에 fake `python3 exit 49` 시나리오 추가
- [ ] `bash tests/hooks/run-all.sh` 전체 green (macOS + Linux)

### 문서
- [ ] `README.md` Windows 진단 3종 명령 + alias 경고 + App execution alias 끄는 방법
- [ ] `README.en.md` 동일
- [ ] `REIN_SETUP_GUIDE.md` Windows 체크리스트
- [ ] `CHANGELOG.md` v0.10.1 엔트리
- [ ] `README.md` 버전 히스토리 v0.10.1 엔트리
- [ ] `need-to-confirm.md` Windows Git Bash 이슈 해결 표기

### CI
- [ ] `.github/workflows/tests.yml` tests-windows-advisory 에 fake python stub 단계 추가 (advisory 유지)

### 리뷰 & 릴리즈
- [ ] Codex 리뷰 통과 (`trail/dod/.codex-reviewed`)
- [ ] Security 리뷰 통과 (`trail/dod/.security-reviewed`)
- [ ] main 선별 체크아웃 + tag `v0.10.1`

## 검증 시나리오

- **사용자 보고 시나리오 재현**: fake `python3` = `exit 49` / fake `py -3` = 정상 / `uname -s` = `MINGW64_NT-10.0-19045` → 훅 실행 → resolver 가 `py -3` 선택 → 파싱 성공 → 정상 gate 통과
- **모든 후보 실패**: fake `python3` + fake `py -3` 둘 다 exit 49 → exit 10 + 진단 메시지 "install real Python or switch to WSL2"
- **WindowsApps stub 감지**: `command -v python3` 결과가 `/c/Users/*/AppData/Local/Microsoft/WindowsApps/python3.exe` → 즉시 next candidate
- **기존 POSIX 경로**: macOS `python3` 정상 동작 → 기존과 동일하게 `PYTHON_RUNNER=python3`
- **REIN_PYTHON override**: `REIN_PYTHON=/opt/my-python/bin/python3.12` → 1순위로 사용

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - writing-plans   # 이 세션: plan 문서 작성
  - codex           # 구현 후 리뷰
mcps: []
rationale: >
  기존 훅 수정 + 신규 lib/ helper 추가. feature-builder 가 '기존 서비스/모듈 변경' 전담이라
  범위 일치. 이 세션은 plan 까지만 작성하고, 구현은 다음 세션에서 feature-builder 가
  plan 을 따라 subagent-driven-development 방식으로 실행. /codex 는 리뷰 필수 단계.
  신규 에이전트나 MCP 불필요.
approved_by_user: true
```

---
## dod-2026-04-21-drift-prevention-implementation.md (mtime: 2026-04-29, archived: 2026-04-30)
# drift 방지 3 plan — Implementation (agent teams)

- 날짜: 2026-04-21
- 유형: feat (implementation)
- 대상 브랜치: dev
- Release target: **v1.1.0** (backcompat minor bump)

## 배경

drift 방지 spec trio (A/B/C) + plan trio 모두 PASS 상태 (75 Scope IDs). 이제 3 plan 의 implementation 을 agent team 구조로 착수.

- Plan A: `docs/plans/2026-04-21-governance-integrity-plan.md` (8 Phase / 22 Task / 22 Scope IDs)
- Plan B: `docs/plans/2026-04-21-test-oracle-plan.md` (5 Phase / 16 Task / 16 Scope IDs)
- Plan C: `docs/plans/2026-04-21-rein-update-hygiene-plan.md` (10 Phase / 31 Task / 37 Scope IDs)

## 의존성 및 실행 순서

### 병렬 가능 / 순차 필요 분석

| 페어 | 공유 artifact | 순서 |
|------|---------------|------|
| A Phase 3 ↔ B Phase 4 | `scripts/rein-validate-coverage-matrix.py` | A 먼저 → B |
| A Phase 6 ↔ B Phase 3 | `scripts/rein-codex-review.sh` | A 먼저 → B |
| A ↔ C | — (Plan A = hooks/scripts, Plan C = `scripts/rein.sh`) | 병렬 |
| B ↔ C | — | 병렬 |

### 실행 전략

```
세션 1 (본 세션 시작):
  ├─ Team A (Plan A) — 전체 22 task
  └─ Team C (Plan C) — 전체 31 task
     (병렬 — 파일 충돌 없음)

세션 2 (A Phase 6 완료 후):
  └─ Team B (Plan B) — 16 task
     (A Phase 3 + 6 의 artifact 위에)

세션 3 (모두 완료 후):
  └─ Release — Phase 8 (A) / Phase 10 (C) / Phase 5 (B) 통합 리뷰 + v1.1.0 태그
```

## Agent Team 구조

### Team A — Plan A (governance-integrity)

**Lead**: `feature-builder` — 기존 bash hook 확장 + 신규 스크립트 (`rein-govcheck.py`, `rein-codex-review.sh`) 구현 전담

**Specialist support** (필요 시 호출):
- `python-pro` — validator v2 Python 확장 (Phase 3, subcommand 파서 재구조화, CLI backcompat shim)
- `security-auditor` — Phase 6 spec-review mode 분기 (`.codex-reviewed` 비터치 CRITICAL 규칙의 security invariant 검증)

**Scope**: Phase 1 → 2 → 3 → 7a → 4 → 5 → 6 → 7b → 8 (plan 의 실행 순서)

### Team C — Plan C (rein-update-hygiene)

**Lead**: `feature-builder` — `scripts/rein.sh` 대규모 확장 + Python helpers 신설

**Specialist support**:
- `python-pro` — `scripts/rein-manifest-v2.py` + `scripts/rein-path-match.py` (anchored segment matcher)
- `security-engineer` — Task 5.3 (`rein remove --all --confirm` TTY-only gate), Task 7.2 (`--shell` opt-in argv transport), Task 8.2 (MINGW `taskkill /F /T` + `MSYS2_ARG_CONV_EXCL`)

**Scope**: Phase 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10

### Team B — Plan B (test-oracle) — 세션 2 이후

**Lead**: `feature-builder`

**Specialist support**:
- `python-pro` — validator v2 behavioral-contract 분기 (`parse_plan_work_unit_covers`, `parse_kind_from_scope_items`)

**Scope**: Phase 1 → 2 → 3 → 4 → 5 (Phase 3 은 Spec A Phase 6 완료 후, Phase 4 는 Spec A Phase 3 완료 후)

## 포함하지 않는 것 (Out of Scope)

- v1.1.0 release 관련 별도 tag/push 작업 (본 DoD 는 구현까지. release 는 후속 DoD)
- Spec/plan 재편집 (PASS 상태로 frozen)
- Post-rollout metric 집계 스크립트 (out of scope per plan)

## 완료 기준 (Definition of Done)

### 공통 (per plan)

- [ ] 해당 plan 의 모든 task 체크박스 완료
- [ ] `python3 scripts/rein-validate-coverage-matrix.py <plan>` exit 0
- [ ] `bash tests/hooks/run-all.sh` + `bash tests/scripts/run-all.sh` 녹색
- [ ] 각 phase 의 planned commit 구조 유지
- [ ] Codex review stamp (`trail/dod/.codex-reviewed`) — Phase 완료 시점마다 (Plan A Task 8.4, Plan B Phase 3 Checkpoint, Plan C Phase 10 Task 10.2)
- [ ] Security review stamp (`trail/dod/.security-reviewed`) — 각 plan 의 최종 Phase 에서

### Plan A 특수

- [ ] 22 Scope IDs 전부 covers 구현 확인
- [ ] wrapper golden test (`tests/skills/test-codex-review-wrapper.sh`) 녹색
- [ ] spec-review mode 6 검증 케이스 모두 녹색 (code-review / spec-review mode, PASS / NEEDS-FIX 각각)

### Plan B 특수

- [ ] Spec A Phase 3/6 의존 grep 통과 확인 (`grep -qE 'build_envelope\(\)' scripts/rein-codex-review.sh`)
- [ ] Task 4.2 behavioral-contract 의 plan work unit covers 기반 applicability (fixture-dod-D-drift 우회 방지) 검증
- [ ] test-oracle.json 부재 시 severity_hard=false 기본 동작 검증

### Plan C 특수

- [ ] Task 5.3 TTY-only gate 검증 (non-TTY 전 경로 exit 2)
- [ ] Task 10.0 helper shipping 검증 (`rein init` sandbox 후 두 helper 존재)
- [ ] POSIX + MINGW CI matrix 녹색 (GitHub Actions)
- [ ] anchored segment matcher 10 fixture 매칭 검증

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - writing-plans
  - codex-review
  - codex-ask
mcps: []
rationale:
  - 작업 성격: 3 plan 병렬 implementation (75 Scope IDs, 69 tasks). bash + Python 혼합, TDD 구조.
  - Lead 에이전트: feature-builder — rein 의 구현 전담. plan task-by-task 실행.
  - 병렬 agent teams: Team A (Plan A) + Team C (Plan C) 독립 dispatch. Team B (Plan B) 는 Team A Phase 3/6 완료 후 착수.
  - Specialist 호출: python-pro (validator v2 + helpers), security-engineer (C 의 --shell/TTY/MSYS2), security-auditor (A 의 spec-review mode CRITICAL).
  - 스킬: writing-plans — 구현 중 plan 수정 필요 시 rein-native 구조 유지. codex-review — phase checkpoint 리뷰. codex-ask — 구현 중 sanity check.
  - MCP: 없음 — 외부 라이브러리 조회 불필요, 저장소 내 bash/python 확장 중심.
approved_by_user: true
```

## 범위 연결

plan ref: docs/plans/2026-04-21-governance-integrity-plan.md (Team A)
plan ref: docs/plans/2026-04-21-test-oracle-plan.md (Team B)
plan ref: docs/plans/2026-04-21-rein-update-hygiene-plan.md (Team C)
work unit: Implementation 전체 — 모든 Phase / 모든 Task
covers: [GI-govcheck-existence, GI-govcheck-language-aware, GI-path-policy-lib, GI-path-policy-input-contract, GI-path-policy-matches-legacy-dated, GI-validator-v2-subcommands, GI-validator-v2-cli-backcompat, GI-validator-v2-dod-covers-subset, GI-validator-v2-parser-single-source, GI-validator-v2-timeout-fail-closed, GI-dod-gate-active-dod-selection, GI-dod-gate-validator-call, GI-dod-gate-cache-invalidation, GI-dod-gate-selector-shared-with-codex-review, GI-dod-mismatch-marker-consumer, GI-codex-review-context-assembly, GI-codex-review-envelope-slots, GI-codex-review-diff-base, GI-codex-review-envelope-context-missing, GI-codex-review-wrapper-script, GI-legacy-plan-spec-review-marker, GI-governance-stage-config, TO-scope-id-behavior-level-rule, TO-scope-id-measurable-contract-required, TO-scope-id-version-meta-in-design, TO-scope-id-examples-anchored, TO-scope-id-legacy-migration-edit-only, TO-bad-test-alignment-unified-rule, TO-bad-test-corroboration-same-contract, TO-bad-test-dod-checkitem-test-changing-only, TO-behavioral-contract-test-categorize, TO-behavioral-contract-applicability-mechanical, TO-behavioral-contract-assertion-anchored, TO-claim-audit-pr-level-only, TO-claim-audit-numeric-mapping-policy, TO-rollout-warn-first-independent-of-spec-a-stage, TO-rollout-detection-log-high-only, TO-rollout-promotion-metric-quality, RU-first-update-preserves-modified-files, RU-first-update-seeds-base-for-textfiles-only, RU-update-per-file-content-immediate, RU-update-exit-code-partial-conflict, RU-update-manifest-atomic-only, RU-update-base-write-failure-as-conflict, RU-three-way-merge-clean-writes-and-base-refresh, RU-three-way-merge-conflict-preserves-user-and-base, RU-three-way-merge-no-silent-overwrite, RU-update-default-shows-prune-count, RU-prune-review-without-confirm, RU-prune-confirm-requires-flag, RU-remove-requires-scope-flag, RU-remove-path-scoped, RU-remove-all-requires-typed-confirmation, RU-remove-modified-preserved-no-force-flag, RU-remove-backup, RU-backup-dirs-gitignored, RU-snapshot-textfile-only, RU-snapshot-storage-location-ignored, RU-path-glob-anchored-segment-matcher, BG-job-start-returns-jobid-under-1s, BG-job-start-default-argv-transport, BG-job-start-shell-opt-in, BG-job-detach-posix-setsid-with-pid, BG-job-detach-windows-git-bash-subshell-pid, BG-job-completion-writer, BG-job-stop-posix-process-group, BG-job-stop-windows-git-bash-tree, BG-job-status-running-check, BG-job-tail-default-50-lines, BG-job-list-split-running-recent, BG-file-state-atomic-write, BG-file-state-layout, BG-no-interactive-jobs, BG-cleanup-gc, BG-claude-code-integration-guide]

## 참고

- 3 plan + 3 spec 모두 `.reviewed` stamp 보유
- 이전 세션 DoD: `trail/dod/dod-2026-04-21-drift-prevention-plans.md` (plan drafting 완료)
- 이전 세션 DoD: `trail/dod/dod-2026-04-21-rein-drift-prevention-specs.md` (spec drafting 완료)

---
## dod-2026-04-21-drift-prevention-plans.md (mtime: 2026-04-29, archived: 2026-04-30)
# drift 방지 spec trio — 3 plan 작성 (병렬)

- 날짜: 2026-04-21
- 유형: docs (plan drafting)
- 대상 브랜치: dev
- 스코프: 3 design spec 에 대응하는 3 implementation plan 작성

## 배경

`trail/dod/dod-2026-04-21-rein-drift-prevention-specs.md` 에서 3 spec (A governance-integrity / B test-oracle / C rein-update-hygiene) 을 작성하고 3 spec 모두 PASS 상태 (stamp 생성 완료). 이제 각 spec 의 구현 plan 을 작성한다.

- Spec A: `docs/specs/2026-04-21-governance-integrity-design.md` v4 (Round 4 Sonnet fallback PASS)
- Spec B: `docs/specs/2026-04-21-test-oracle-design.md` v4 (Sonnet self-review r4 PASS)
- Spec C: `docs/specs/2026-04-21-rein-update-hygiene-design.md` v5 (Sonnet self-review r5 PASS)

## 변경 범위

3 plan 파일 생성 (`docs/plans/` canonical 경로):

- `docs/plans/2026-04-21-governance-integrity-plan.md`
- `docs/plans/2026-04-21-test-oracle-plan.md`
- `docs/plans/2026-04-21-rein-update-hygiene-plan.md`

각 plan 은 rein 의 `.claude/rules/design-plan-coverage.md` 규칙 준수:
- `## Design 범위 커버리지 매트릭스` 섹션 (design ref + design Scope Items 전수 반영)
- 각 Phase/Task 의 `covers:` 메타데이터 (design Scope ID 매핑)
- Spec B scope-id-version v2 규칙 (design frontmatter 에서 버전 상속)

## 의존 관계

- A/C 는 독립 → 병렬 작성 가능
- B 는 A 의 envelope slot 구조를 참조하지만 separate plan — 병렬 가능
- 실제 구현 (plan 실행 단계) 순서는 A → B & C 병렬 권장. plan drafting 단계에서는 3 개 모두 병렬.

## 포함하지 않는 것 (Out of Scope)

- 실제 구현 (이번 세션은 plan drafting 만). Implementation 은 후속 세션에서 executing-plans 스킬로.
- plan 에 대한 spec review (spec-review 는 design 대상, plan 은 별도 절차 — AGENTS.md §415)
- v1.0.0 관련 작업 (Phase 3+4) — 별도 DoD

## 완료 기준 (Definition of Done)

### 공통

- [ ] 3 plan 파일이 `docs/plans/` canonical 경로에 생성됨
- [ ] 각 plan 이 대응 design spec 의 모든 Scope ID 를 matrix 에 포함 (implemented 또는 deferred)
- [ ] 각 plan 의 work unit 에 `covers:` 메타데이터 존재
- [ ] `scripts/rein-validate-coverage-matrix.py plan <file>` (또는 기존 validator) 통과 예상
- [ ] plan 순서/phase 가 implementation feasibility 를 고려해 구성됨

### 리뷰

- [ ] 3 plan 각각에 대해 spec-review (plan 단계의 sanity check) 실행 권장 — plan-writer agent 가 handoff 로 남길 수 있음
- [ ] plan 작성 중 발견된 spec 의 추가 보완 사항은 design spec 수정으로 피드백 (rare)

## 라우팅 추천

```yaml
agent: plan-writer
skills:
  - writing-plans
  - codex-ask
mcps: []
rationale:
  - 작업 성격: 3 개 design spec 으로부터 implementation plan 작성 (병렬). coverage 매트릭스 + covers 메타데이터 요구.
  - 에이전트: plan-writer — rein 의 plan 작성 전담, coverage 매트릭스 자동 포함, validator handoff 까지 수행.
  - 스킬: writing-plans — rein-native plan drafting 가이드. superpowers 미의존.
  - 스킬: codex-ask — plan 초안의 feasibility sanity check (second opinion, stamp 없음). 필요 시에만.
  - MCP: 없음 — 외부 라이브러리 조회 불필요, design spec 내부 규칙/구조 중심.
approved_by_user: true
```

## 범위 연결

design ref:
- `docs/specs/2026-04-21-governance-integrity-design.md`
- `docs/specs/2026-04-21-test-oracle-design.md`
- `docs/specs/2026-04-21-rein-update-hygiene-design.md`

## 참고

- `.claude/rules/design-plan-coverage.md` — matrix + covers 요구사항
- `scripts/rein-validate-coverage-matrix.py` v1 (v2 는 Spec A plan 에서 확장 계획)
- `trail/dod/dod-2026-04-21-rein-drift-prevention-specs.md` — 이전 단계 DoD

---
## dod-2026-04-21-rein-drift-prevention-specs.md (mtime: 2026-04-29, archived: 2026-04-30)
# rein drift 방지 spec trio — design → plan → review drift 의 구조적 차단

- 날짜: 2026-04-21
- 유형: docs (spec drafting)
- 대상 브랜치: dev
- 스코프: 3개 design spec + codex-ask 스킬 규약 보강

## 배경

`need-to-confirm.md` 에 2세션의 codex 분석이 누적되어 있다:

1. **본 세션 codex 분석** — 3개 이슈(rein update 파일관리 / nohup 백그라운드 / codex-review 설계 정합성 미검증) 에 대한 구현 설계. P1/P2/P3 우선순위 제시.
2. **이전 세션 codex critique** — P1/P2/P3 자체에 대한 반박. Scope ID granularity, test oracle priority, governance self-test 선행 필요를 지적.

두 분석의 교차 결과로 **수정된 우선순위** 가 확정됐다 (Step 0 → 1 → 1.5 → 2 → 3 → 4 → 5). 본 세션은 이 우선순위를 3개 spec 으로 패키징한다.

## 변경 범위

### Spec A — governance-integrity-design (Step 0 + 1 + 1.5)

파일: `docs/specs/2026-04-21-governance-integrity-design.md`

데이터 흐름 `design → plan → DoD → review → phase-complete` 의 **기계적 추적성** 을 고정한다. 현재 gap:

- G0 (신규 발견): AGENTS.md 가 참조하는 `rein-*` 스크립트들이 전부 실존하는지 검증 수단 없음
- G2 (기존): `post-edit-plan-coverage.sh` + `post-write-spec-review-gate.sh` 의 path regex 가 canonical `docs/**/plans/**` 만 인식. 날짜 디렉토리 legacy plan 무시
- G3 (기존): `pre-edit-dod-gate.sh` 가 DoD 의 `covers:` / `plan ref:` 를 검증하지 않음
- G4 (신규): `/codex-review` 스킬 prompt 에 Design / Test / Claim cross-check 섹션이 없음

Scope Items (behavior-level):

- `GI-governance-plumbing-selftest`: AGENTS.md/CLAUDE.md 가 참조하는 script 경로 전체를 정적 검증하는 CLI (`scripts/rein-govcheck.sh` 또는 동급). fail closed.
- `GI-path-policy-unify-planhook`: `post-edit-plan-coverage.sh` regex 확장 → `docs(/[^/]+)*/plans/.+\.md|plans/.+\.md|docs/[0-9]{4}-[0-9]{2}-[0-9]{2}/[^/]+-plan\.md`
- `GI-path-policy-unify-specreviewhook`: `post-write-spec-review-gate.sh:60` 의 canonical-only matcher 도 동시 확장
- `GI-path-policy-shared-fn`: 두 hook 이 공유하는 "is-plan-path" shell function 으로 추출해서 drift 재발 차단
- `GI-validator-v2-plan-subcommand`: `rein-validate-coverage-matrix.py` 에 `plan` subcommand — matrix 존재 강제(canonical), design ref 존재 시 matrix 없으면 fail
- `GI-validator-v2-dod-subcommand`: `rein-validate-coverage-matrix.py` 에 `dod` subcommand — `plan ref:`, `covers:`, `work unit:` exact syntax 검증
- `GI-validator-v2-dod-covers-subset`: DoD `covers:` 가 plan `implemented` ID 의 부분집합인지 검증
- `GI-dod-gate-calls-validator`: `pre-edit-dod-gate.sh` 가 source edit 직전 active DoD 를 `rein-validate-coverage-matrix.py dod` 로 검사 → 실패 시 `.dod-coverage-mismatch` 마커 + Exit 2
- `GI-codex-review-context-assembly`: `/codex-review` 스킬이 codex 호출 전 active DoD → plan → design → Scope ID 를 자동 수집
- `GI-codex-review-envelope-design-alignment`: 강제 프롬프트 envelope 의 "Design Alignment" 섹션 (각 Scope ID 에 MATCH/PARTIAL/MISSING/CONTRADICTS + 증거)
- `GI-codex-review-envelope-test-alignment`: "Test Alignment" 섹션 (design term 을 쓰는 테스트의 assertion 이 spec 과 일치하는지)
- `GI-codex-review-envelope-claim-audit`: "Claim Audit" 섹션 (commit/PR/DoD/plan claim vs 실제 diff/code)
- `GI-rollout-warn-to-block`: 3단계 rollout — (1) canonical plan + 새 DoD warning only → (2) canonical + routing-present active DoD block → (3) 날짜 디렉토리 legacy plan strict block
- `GI-codex-ask-no-dod-no-stamp-rule`: `codex-ask` 스킬 §3 에 **DoD 파일 자발 생성 금지** 명시 (stamp 금지는 기존)

### Spec B — test-oracle-design (Step 2 + 3)

파일: `docs/specs/2026-04-21-test-oracle-design.md`

Strategy2 사고의 직접 원인은 **test 가 잘못된 구현을 "정답" 으로 고정** 한 것. 어떤 review gate 를 쌓아도 test 자체가 거짓말하면 통과한다. 이 spec 은 Scope ID granularity 와 test oracle integrity 를 다룬다.

Scope Items (behavior-level):

- `TO-scope-id-behavior-level-rule`: Scope ID 는 Phase/Task 수준이 아니라 **behavior/contract** 수준이어야 함 — `design-plan-coverage.md` 에 rule + examples 추가
- `TO-scope-id-examples-good-vs-bad`: 좋은 예(`CAUTION-buy-throttle-50`, `rotation-leading-affects-risk-off`) vs 나쁜 예(`A1: active universe coverage`) 명시
- `TO-scope-id-legacy-migration-plan`: 기존 coarse ID 를 쓰는 plan 들의 migration 전략 (일괄 재작성 금지, 편집 시점에 승격)
- `TO-bad-test-detection-rule-in-codexreview`: `/codex-review` Test Alignment 섹션에 "test 이름이 design term 을 쓴다면 assertion 이 design spec 과 일치하는지 확인" 를 강제
- `TO-bad-test-detection-heuristic`: 휴리스틱 예시 — `test_<mode>_*` 네이밍 + `expected == <other mode result>` 패턴을 flag
- `TO-behavioral-contract-test-dod-required`: 통합 phase (phase 5/6 수준) DoD 에 **최소 1개 end-to-end 시나리오 테스트** 필수
- `TO-behavioral-contract-assertion-template`: behavioral assertion 템플릿 — "`<mode>` 체류 중 NAV 변화율 ≠ `<other mode>` 체류 중 NAV 변화율" 패턴
- `TO-claim-audit-rule-pr-level`: commit claim ↔ code 검증은 local commit gate 가 아니라 **PR review 단계** 의 claim audit 에 포함 (format 이 아니라 mismatch 가 본질)
- `TO-rollout-warn-only-first`: bad-test rule 도 처음엔 warning — 실제 검출률 데이터 확보 후 hard

### Spec C — rein-update-hygiene-design (이슈 1 + 2)

파일: `docs/specs/2026-04-21-rein-update-hygiene-design.md`

`rein update` 후 파일 정리와 시간이 오래 걸리는 작업의 배경화. 이슈 1 은 manifest/prune 이 **부분 구현** 된 상태에서 `3-way merge + rein remove` 로 확장. 이슈 2 는 백그라운드 실행 인프라 신설.

Scope Items (behavior-level):

- `RU-manifest-v2-base-snapshot-textfiles`: `.claude/.rein-state/base/` 에 텍스트 파일 base snapshot 저장 (대상: `*.md`, `*.sh`, `*.py`, `*.json`, `*.yml`, `*.yaml`)
- `RU-three-way-merge-autoresolve`: `git merge-file -p current base incoming` 으로 clean 한 경우 자동 병합
- `RU-three-way-merge-conflict-preserve`: 충돌 시 사용자 파일 보존 + `.claude/.rein-state/conflicts/<slug>.rej` 요약만 기록. 자동 overwrite 금지
- `RU-update-default-prune-analysis`: `rein update` 기본 출력에 prune candidate 요약 항상 노출 (삭제는 `--prune --confirm` 유지)
- `RU-remove-command-dryrun`: `rein remove --dry-run` — manifest 전체 대상 safe-delete 후보 리스트
- `RU-remove-command-confirm`: `rein remove --confirm` — 실제 삭제
- `RU-remove-command-path-filter`: `rein remove --path '<glob>'` — 부분 삭제
- `RU-remove-modified-preserve`: 사용자가 수정한 파일은 기본 보존 (opt-in override 조차 좁게)
- `BG-job-start-command`: `rein job start <name> -- <cmd>` — nohup 래퍼로 백그라운드 실행
- `BG-job-status-command`: `rein job status <job-id>` — running/success/failed + exit code
- `BG-job-tail-command`: `rein job tail <job-id> [--lines N]`
- `BG-job-stop-command`: `rein job stop <job-id>` — SIGTERM → SIGKILL escalation
- `BG-file-state-protocol`: `.claude/cache/jobs/<job-id>.{json,pid,log,exit}` 파일 레이아웃
- `BG-claude-code-polling-pattern`: Claude Code 세션 통합 가이드 — 시작 1회 호출 + 짧은 polling, 긴 PTY 의존 금지

## 포함하지 않는 것 (Out of Scope)

- 실제 구현 (이번 세션은 spec drafting 만). 각 spec 의 plan 은 후속 세션에서 `writing-plans` 스킬로 작성.
- `post-write-spec-review-gate.sh` 의 실제 regex 수정 자체 (spec A 의 `GI-path-policy-unify-*` 가 "해야 한다" 만 기술, plan/impl 이 집행)
- strategy2 사건의 retroactive 검토 (별도 작업)

## 완료 기준 (Definition of Done)

### 공통

- [ ] 3개 spec 파일이 `docs/specs/` canonical 경로에 생성됨
- [ ] 각 spec 이 `## Scope Items` 섹션을 포함하고, ID 는 behavior-level 로 작성됨
- [ ] Spec A 의 `GI-codex-ask-no-dod-no-stamp-rule` 에 대응하는 `.claude/skills/codex-ask/SKILL.md` §3 업데이트 완료
- [ ] 각 spec 은 `docs/specs/` 머지 대상이므로 main 포함 여부 확인 (이 repo 는 dev 전용 → spec 은 main 제외, branch-strategy.md 준수)

### 리뷰

- [ ] 3개 spec 각각에 대해 `/codex-review` 로 spec review 실행 (plan 단계 전 필수, AGENTS.md §415 "리뷰 강제" 준수)
- [ ] `trail/dod/.spec-reviews/*.reviewed` marker 생성
- [ ] codex-ask 스킬 업데이트에 대해서는 `/codex-review` 로 코드 리뷰
- [ ] security-reviewer 는 이번 변경이 설정/권한/secret 을 건드리지 않으므로 범위 밖 (단, stamp 는 절차상 필요 시 생성)

## 라우팅 추천

```yaml
agent: docs-writer
skills:
  - brainstorming
  - codex-ask
  - codex-review
mcps: []
rationale:
  - 작업 성격: 3개 design spec 문서 작성 + 스킬 규약 1줄 보강 (코드 변경 없음, 문서 위주)
  - 에이전트: docs-writer — 문서화 전담, spec drafting 에 적합 (feature-builder 는 구현 전담이라 범위 밖)
  - 스킬: brainstorming — brownfield 에서 이미 수렴된 설계를 spec 형식으로 구체화
  - 스킬: codex-ask — 필요 시 spec sanity check 용 second opinion (stamp 없음)
  - 스킬: codex-review — 3 spec 의 spec review + codex-ask SKILL.md 변경에 대한 code review 강제
  - MCP: 없음 — 외부 라이브러리 문서 조회 불필요, 저장소 내 규칙/hook 분석 중심
approved_by_user: true
```

## 참고

- need-to-confirm.md — 2세션의 codex 분석 원본
- .claude/rules/design-plan-coverage.md v1 — 현재 규칙 (수정 대상)
- .claude/hooks/post-edit-plan-coverage.sh — path matcher gap
- .claude/hooks/post-write-spec-review-gate.sh — 같은 gap (blind spot)
- .claude/hooks/pre-edit-dod-gate.sh — DoD covers 미검증 지점
- scripts/rein-validate-coverage-matrix.py — v1 validator (확장 대상)
- .claude/skills/codex-review/SKILL.md — Design/Test/Claim envelope 추가 대상
- .claude/skills/codex-ask/SKILL.md — §3 규약 보강 대상
- scripts/rein.sh — manifest + prune 기존 구현 (v2 확장 기반)

---
## dod-2026-04-22-readme-style-rule.md (mtime: 2026-04-29, archived: 2026-04-30)
# README Style Rule 신설

- 날짜: 2026-04-22
- 유형: docs (new rule file)
- 대상 브랜치: dev

## 배경

2026-04-22 codex-ask 세션 결과 README.md / README.en.md 가 신규 유입자 관점에서 "내부자 문서" 로 드리프트 되어 있음이 확인됨 (pre-install comprehension 약함, jargon 정의 누락, version history bloat, 섹션 순서 역전, KR/EN 비동기, 미번역 한국어 잔존 등). 재작성 전에 규칙을 먼저 확립해 이후 README 편집 시 일관되게 참조할 수 있도록 함.

## 완료 기준 (Definition of Done)

- [ ] `.claude/rules/readme-style.md` 신설 — codex 리뷰 7개 항목을 advisory 체크리스트로 규칙화
  - [ ] 섹션 1: pre-install comprehension 기준 (problem / workflow impact / when-to-use)
  - [ ] 섹션 2: jargon disposition 판정 테이블 (inline / deeper doc / remove)
  - [ ] 섹션 3: version history cut-off 정책 (README = 최신 1개, 나머지는 CHANGELOG)
  - [ ] 섹션 4: 권장 섹션 순서 (10 단계)
  - [ ] 섹션 5: KR/EN parity 규칙 + 미번역 텍스트 금지
  - [ ] 섹션 6: 재작성 우선순위 11개 항목
  - [ ] 섹션 7: replacement-opener template + "What Rein is NOT" 가이드
- [ ] `.claude/CLAUDE.md` 의 규칙 허브 섹션에 `@.claude/rules/readme-style.md` 라인 1개 추가 → 매 세션 자동 로드
- [ ] docs-only 변경 (bash/python 코드 없음, hook 신설 없음, 테스트 영향 없음)
- [ ] 자가 검증: 작성된 규칙을 현재 README 에 적용했을 때 codex 리뷰에서 지적된 7개 항목이 모두 커버되는지 확인

## 포함하지 않는 것 (Out of Scope)

- README.md / README.en.md 실제 재작성 (후속 DoD 에서 이 규칙을 참조하여 수행)
- Hook 레벨 강제 (advisory 체크리스트 수준; jargon 탐지 hook 은 미래 과제)
- CHANGELOG.md 분리 작업 (후속 DoD — version history 이관 시점에)

## 라우팅 추천

```yaml
agent: docs-writer
skills:
  - codex-ask  # 이미 완료 — 규칙의 source-of-truth 로 활용
mcps: []
rationale:
  - 작업 성격: 순수 문서 규칙 신설. 코드 로직·hook·테스트 없음.
  - 에이전트 선택: docs-writer 가 `.claude/rules/*` 및 `.claude/CLAUDE.md` 편집 전담.
  - 스킬 선택: codex-ask 는 이 DoD 의 전제로 이미 수행됨 (source material). 추가 스킬 불필요.
  - MCP: 없음 — 로컬 파일 2개 편집이 전부.
approved_by_user: true
```

## 참조

- Codex second-opinion 결과: 2026-04-22 세션 stdout (stamp 없음 / Mode B)
- 대상 파일: `README.md`, `README.en.md`
- 기존 rules 규약: `.claude/rules/code-style.md`, `.claude/rules/testing.md`, `.claude/rules/branch-strategy.md` (포맷 참고)

---
## dod-2026-04-28-phase6-marketplace-publish.md (mtime: 2026-04-29, archived: 2026-04-30)
# DoD — Phase 6: Marketplace dual-channel publish

- 날짜: 2026-04-28
- 유형: feat (v2.0.0 plugin-first restructure 의 marketplace publish phase)
- 작업: `plugin-first-restructure` plan 의 Phase 6 (2 tasks) 구현
  - Task 6.1: `scripts/rein-publish.sh` 가 plugins/*/ 를 tarball 로 묶어 `marketplace/marketplace.json` 에 entry 등록 + tag push CI workflow
  - Task 6.2: dual-channel publish — 자체 marketplace.json 업데이트 + Anthropic 공식 marketplace API POST. 환경변수 미설정 시 fail-fast (Round 5 fix Finding 6 — default URL 하드코딩 금지). 한쪽 실패 시 best-effort sequential rollback.

## 완료 기준

- [ ] `scripts/rein-publish.sh` 작성 (POSIX bash, set -euo pipefail, shellcheck-clean)
- [ ] `scripts/rein-marketplace-update.py` 작성 (atomic JSON write — temp + os.replace)
- [ ] `marketplace/marketplace.json` 초기 schema (`{name, version, plugins: []}`) 생성
- [ ] `.github/workflows/publish-plugin.yml` 작성 (tag push 트리거 → rein-publish.sh)
- [ ] `tests/scripts/test-rein-publish-tarball.sh` 작성 (Task 6.1 — tarball 생성 + marketplace.json entry 검증)
- [ ] `tests/scripts/test-rein-publish-dual-channel.sh` 작성 (Task 6.2 — mock HTTP server + env-var-only URL + rollback 검증)
- [ ] Task 6.2 dual-channel logic 추가: ANTHROPIC_MARKETPLACE_API + ANTHROPIC_TOKEN 미설정 시 fail-fast, curl POST 실패 시 rollback_self_hosted
- [ ] Task 6.1 + Task 6.2 모두 codex review (Mode A) PASS + security review PASS
- [ ] 보안 surface 점검: tar -C escape, curl HTTPS 강제 (production 환경에서), 토큰 stderr 누수 금지, rollback race condition

## 범위 연결

plan ref: docs/plans/2026-04-27-plugin-first-restructure-plan.md
work unit: Phase 6 / Task 6.1 ~ Task 6.2
covers: [rein-publish-uploads-plugin-tarballs-to-marketplace-on-tag-push, marketplace-publishes-to-anthropic-and-self-hosted-json-simultaneously-on-release]

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - superpowers:executing-plans
  - superpowers:test-driven-development
  - superpowers:verification-before-completion
mcps: []
rationale: |
  Phase 6 는 2 task 단순 구조. Phase 1/2 패턴 (plan steps 그대로 따르기 + per-task TDD)
  과 동일하게 진행. 보안 surface 가 높아 (curl + token + tarball + rollback) security
  review 단계가 일반 phase 보다 더 엄격해질 가능성. tar -C handling, HTTPS 강제,
  토큰 누수, rollback race 가 주요 점검 포인트.

  Task 6.1: shell + python (atomic JSON write) + workflow YAML — TDD 로 fixture
  plugin 이용해 tarball 생성 + marketplace.json entry 검증.
  Task 6.2: dual-channel logic + Python http.server mock + rollback 함수.
  ANTHROPIC_MARKETPLACE_API/ANTHROPIC_TOKEN env-var 미설정 fail-fast 케이스도 함께 검증.
approved_by_user: true
```

## 자체 검증 메모

- spec ref: `docs/specs/2026-04-27-plugin-first-restructure.md` (scope-id-version=v2)
- plan validator: Phase 1 시작 시 통과 (재실행 불필요 — plan 파일 미수정)
- branch-strategy: dev 에서 작업, main 머지는 Phase 9 누적 후
- Phase 1 + 2 의존성: 모두 충족 (HEAD `1db21e1` 기준 plugins/rein-core/ 존재)
- Round 5 fix Finding 6 준수: ANTHROPIC_MARKETPLACE_API / ANTHROPIC_TOKEN 미설정 시 fail-fast (default URL 하드코딩 금지)
- spec §6.2 Open Question (cross-channel atomic) 은 본 phase 범위 아님 — best-effort sequential rollback 까지만 cover
- Phase 7 (도메인 plugin 분리) 은 본 phase 와 독립적 worktree 에서 병렬 진행 — marketplace.json 의 plugins[] 는 초기 빈 배열로 두고 Phase 7 에서 별도 등록

---
## dod-2026-04-29-hook-project-dir-worktree-aware.md (mtime: 2026-04-29, archived: 2026-04-30)
# Hook PROJECT_DIR worktree/plugin-aware 해석

- 날짜: 2026-04-29
- 유형: fix (hook 동작 정정 — user-facing 영향 있음)
- 대상 브랜치: dev (이후 v2.0.0 으로 main 머지)

## 배경

incident `pre-bash-guard-2fbe7edae5a10b1f` (root_cause=bug) 에서 hook 이 git worktree (`.worktrees/harness-cleanup/`) 에 위치한 사본으로 실행될 때 `PROJECT_DIR` 가 worktree 내부로 잡히면서 `trail/` 경로 (`blocks.jsonl`, `.coverage-mismatch` 등) 가 main 워킹트리와 분리되어 누적되는 문제가 관찰됨. plugin 모드 (v2.0.0) 에서는 `~/.claude/plugins/...` 처럼 install path 와 사용자 프로젝트가 분리되므로 같은 패턴이 더 빈번히 깨진다.

현재 영향 범위:

- `.claude/hooks/*.sh` **10개** + `plugins/rein-core/hooks/*.sh` 미러 10개 모두 `PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"` 또는 변형 사용 (index.md 의 "7 hook" 은 부분 집계 — 실제 SCRIPT_DIR/../.. 패턴을 쓰는 hook 은 10개)
- `session-start-load-trail`, `stop-session-gate`, `post-write-dod-routing-check` 는 `REIN_PROJECT_DIR` / `REIN_PROJECT_DIR_OVERRIDE` env override 가 부분 적용되어 있으나 일관성 없음

설계 노트 (codex review 2026-04-29 반영):
- **scaffold 모드 우선**: `SCRIPT_DIR/../..` 가 `trail/` 디렉토리를 가지면 그것을 PROJECT_DIR 로 채택. cwd 기반 git rev-parse 가 아닌 hook-owner 기반 — unrelated cwd 에서 hook 호출 시 trail 누적이 잘못된 repo 로 가는 회귀를 방지.
- **plugin 모드 분기**: `$CLAUDE_PLUGIN_ROOT` 가 set 이면 hook 이 `~/.claude/plugins/...` 같은 외부 install 경로에 있다는 뜻 → 이 때만 cwd-git 우선 (사용자 프로젝트가 cwd).
- **post-edit-index-sync-inbox ancestry check**: 편집된 file_path 가 PROJECT_DIR 의 자손이 아니면 silent exit — broken layout 시 stray inbox 생성 방지.

## 완료 기준 (Definition of Done)

- [x] 신규 helper `.claude/hooks/lib/project-dir.sh` + `plugins/rein-core/hooks/lib/project-dir.sh` (byte-identical 미러, 동기화 검증됨)
  - [x] `resolve_project_dir SCRIPT_DIR` 함수 — 1 인자, stdout 으로 절대 경로 1줄 출력
  - [x] 우선순위: ① `$REIN_PROJECT_DIR_OVERRIDE` ② `$REIN_PROJECT_DIR` ③ `$CLAUDE_PLUGIN_ROOT` set → cwd-git → `$PWD` ④ `SCRIPT_DIR/../..` 가 trail/ 보유 시 hook-owner ⑤ `SCRIPT_DIR/../..` 일반 fallback ⑥ cwd-git ⑦ `$PWD`
  - [x] 항상 exit 0 — 호출자는 결과 디렉토리의 유효성만 검사
- [x] 10 hook 일괄 적용 (각각 양쪽 트리에)
  - [x] pre-bash-guard
  - [x] pre-edit-dod-gate
  - [x] post-edit-plan-coverage
  - [x] post-edit-review-gate
  - [x] post-edit-index-sync-inbox
  - [x] post-write-spec-review-gate
  - [x] post-write-dod-routing-check
  - [x] session-start-load-trail
  - [x] stop-session-gate
  - [x] trail-rotate
- [x] 회귀 test — `tests/hook-project-dir-resolution/` 신설
  - [x] 일반 checkout 에서 helper 가 repo root 반환
  - [x] worktree (`git worktree add`) 안에서 helper 가 worktree root 반환
  - [x] `REIN_PROJECT_DIR_OVERRIDE` 환경변수 우선 (테스트 의존)
  - [x] `cd /tmp` 처럼 git 밖 cwd 에서 SCRIPT_DIR fallback 동작
- [x] 기존 smoke (8/8 scaffold + hook 관련) PASS 유지
- [x] `/codex-review` PASS + `trail/dod/.codex-reviewed` stamp
- [x] `security-reviewer` PASS + `trail/dod/.security-reviewed` stamp

## 포함하지 않는 것 (Out of Scope)

- `post-edit-hygiene.sh` 등 현재 PROJECT_DIR 패턴이 없는 hook 의 사전 적용
- helper 의 캐싱 (현재 git rev-parse 호출 비용 충분히 낮음)
- Windows native (cmd/PowerShell) 지원 — `rein` 자체가 Git Bash 전용
- v2.0.0 main 머지·tag·marketplace publish 절차 자체 (별도 후속, 본 DoD 에서는 머지 가능 상태까지만 보장)

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review  # gate 1: PROJECT_DIR 해석 정합성
mcps: []
rationale:
  - 작업 성격: bug 수정 + helper 신설. 10 hook 양쪽 미러 일괄 패치 + 회귀 test.
  - 에이전트 선택: feature-builder — 다파일 동시 편집 + bash 함수 신설 + 테스트 추가.
  - 스킬 선택: codex-review (Mode A) — fallback resolution 우선순위가 잘못 잡히면 trail 경로가 분기되어 silent corruption 위험 → 필수.
  - MCP: 없음. 로컬 셸·git·테스트 만으로 검증 완료 가능.
approved_by_user: true
```

## 참조

- Incident: `auto-pre-bash-guard-2fbe7edae5a10b1f-*` (trail/incidents/blocks.jsonl 2026-04-19 ~ 2026-04-29 산발 발생)
- 관련 규칙: `.claude/rules/branch-strategy.md` (worktree 운영), `.claude/rules/background-jobs.md` (worktree 격리 hint)
- v2.0.0 plugin schema hotfix 인계: `trail/inbox/2026-04-29-plugin-schema-hotfix.md` — 본 DoD 가 main 머지 직전 마지막 정정 작업

---
## dod-2026-04-30-scaffold-drop.md (mtime: 2026-04-30, archived: 2026-05-01)
# DoD: scaffold mode drop spec + plan

## 라우팅 추천
- agent: plan-writer (plan 단계 — coverage matrix + covers 자동, 자체 codex-review 호출)
- skills: codex-review
- mcps: none
- secondary_agents:
  - researcher (spec 단계 — 다른 plugin 프레임워크들의 deprecation/migration 사례 조사. 1 사이클 한정)
- rationale: spec 은 main session 이 직접 작성하되 deprecation timeline · refusal 메시지 톤 결정에 외부 사례를 researcher 로 짧게 보강. plan 은 plan-writer agent 에 위임 (coverage matrix · covers 메타 · 자동 codex-review). 코드 변경 없음.
approved_by_user: true

## 범위 연결
- 출처: `trail/inbox/2026-04-30-followup-roadmap.md` (P0 #1 + #2)
- 결정 1: scaffold mode 제거 — `rein init --mode=scaffold` 진입점, `do_update_v2` 3-way merge, COPY_TARGETS 플랫 리스트, manifest v2 헬퍼, anchored path matcher 등 scaffold 전용 surface 제거 또는 graveyard 로 이동
- 결정 2: 1 release 동안 migration shim 유지 — `--mode=scaffold` / `rein update` (legacy) / `rein remove --path` 호출 시 친절한 refusal + plugin migration 가이드 출력. 다음 release 에서 완전 삭제.
- 이번 세션 범위: spec 1개 + plan 1개 작성 + 두 단계 모두 codex-review PASS
- 다음 세션 범위: impl + codex-review + security-review → dev 커밋 → main 선별 머지

## 변경 대상 파일
- (생성) `docs/specs/2026-04-30-scaffold-drop.md`
- (생성) `docs/plans/2026-04-30-scaffold-drop-plan.md`
- (생성) `trail/dod/.spec-reviews/<sha1>.pending` → `.reviewed` × 2 (spec 1, plan 1)
- 본 DoD 의 `## 검증 기록` 섹션에 두 라운드 결과 추기
- 코드 변경 없음 (spec/plan 단계)

## 작업 계획
1. (선택) researcher agent 1 사이클 — 다른 CLI/plugin 프레임워크의 dual-mode → single-mode 전환 사례 (deprecation timeline, refusal 메시지 톤, migration 가이드). 결과는 spec 의 "참고 사례" 섹션에만 사용
2. spec 작성 (`docs/specs/2026-04-30-scaffold-drop.md`) — 배경, Scope Items (v2 behavior-level), Non-goals, 단계별 timeline, 영향 분석, 호환성 정책, 검증 방법
3. `/codex-review` (Mode A spec-review subflow) → findings 보완 → PASS 까지
4. plan 작성 — plan-writer agent 호출 (spec 경로 전달). plan-writer 가 자동으로 coverage validator + codex-review + per-spec stamp 처리
5. plan-writer 가 NEEDS-FIX 반환 시 보완 후 재실행 (handoff)
6. inbox + index 갱신, 다음 세션 (impl) 인계 노트 작성

## 완료 기준
- [x] `docs/specs/2026-04-30-scaffold-drop.md` 생성
  - [x] frontmatter 에 `scope-id-version: v2`
  - [x] 배경 / Scope Items 표 / Non-goals / 단계별 timeline / 영향 분석 / 호환성 정책 포함
  - [x] (변경) shim 자체 채택 안 함 — 사용자 = 본인 한 명 결정. roadmap 결정 3 (비서 톤) 의 refusal 부분은 §10 에서 supersede 명시.
- [x] spec 의 `/codex-review` Mode A PASS (per-spec stamp `339e7161175a97b6.reviewed`, code-reviewer-rein-sonnet-fallback round 4)
- [x] `docs/plans/2026-04-30-scaffold-drop-plan.md` 생성
  - [x] `## Design 범위 커버리지 매트릭스` 섹션 + `design ref:` 줄
  - [x] 모든 `implemented` ID 가 work unit 의 `covers:` 에 매칭
  - [x] `scripts/rein-validate-coverage-matrix.py plan` 통과
- [x] plan 의 codex-review PASS (per-spec stamp `5b971c9d673bfda9.reviewed`, codex-gpt-5.5-medium-r7)
- [x] 본 DoD 의 `## 검증 기록` 섹션에 spec/plan 각 round 결과 추기
- [x] `trail/inbox/2026-04-30-scaffold-drop-spec-plan.md` 작성
- [x] `trail/index.md` 갱신 (현재 상태 + 다음 세션 후보)
- [x] 다음 세션 (impl) 시작 지점 메모

## 검증 기록

### Spec round 1 — codex (gpt-5.5, medium effort)
- verdict: NEEDS-FIX. 5건 (versioning conflict / scope item broad / S8 결정 위임 / 숫자 매핑 불완전 / roadmap divergence 미명시).

### Spec round 2 — codex (재작성 후 재리뷰)
- verdict: NEEDS-FIX. high 2 (mirror order race / tag list 15→20 정정) + medium 3 (S1~S11 표기 typo / S5b verification 정합 / publish-plugin 위험 누락) + minor 2 (changelog-archive branch-strategy / trigger 조건).

### Spec round 3 — codex
- verdict: NEEDS-FIX. high 1 (Step 5 atomic push race) + medium 2 (기존 v1.0.0 release page / public publish race).

### Spec round 4 — `code-reviewer` skill (Sonnet fallback, codex_error: usage limit)
- verdict: PASS (Low 3건 wording / plan-level 검증 권고. Low 패치 후 정합).
- per-spec stamp: `trail/dod/.spec-reviews/339e7161175a97b6.reviewed`
- reviewer: code-reviewer-rein-sonnet-fallback

### Researcher 결과 (1 사이클)
- npm / Python PEP 387 / Cargo / ESLint 의 deprecation 정책: 최소 2 release shim. 본 spec 은 사용자 베이스 0 가정으로 적용 외, §10 의 trigger 조건 (stargazers > 1 등) 충족 후 다음 deprecation 부터 복귀.

### Plan round 1 — plan-writer agent (codex 자동 호출)
- verdict: NEEDS-FIX. HIGH × 3 (cmd_update 미존재 / run-all.sh stale tests / release-cleanup v1.0.0 cleanup-tag) + MEDIUM × 1 (test exit code masking).

### Plan round 2 — codex
- verdict: NEEDS-FIX. S12 PARTIAL (tag-wipe helper TAGS 에 v1.0.0 포함) + S5b PARTIAL + S7 PARTIAL + S2 test PARTIAL.

### Plan round 3 — codex
- verdict: NEEDS-FIX. Step 4.7 stale prose + 20 tag claim stale + git rm `--ignore-unmatch` minor.

### Plan round 4 — codex
- verdict: NEEDS-FIX. Stale "20" wording 3건 (Q3 / Task 3.1 dry-run / Task 3.3 검증).

### Plan round 5 — codex
- verdict: NEEDS-FIX. release-cleanup helper 의 "19 DRY lines" 보장 부재 (gh release view 결과 가변).

### Plan round 6 — codex
- verdict: NEEDS-FIX. Step 4.1 의 `&&` short-circuit 으로 v1.0.0 remote-delete skip 위험.

### Plan round 7 — codex (gpt-5.5 medium)
- verdict: **PASS**.
- per-spec stamp: `trail/dod/.spec-reviews/5b971c9d673bfda9.reviewed`
- reviewer: codex-gpt-5.5-medium-r7

## 다음 세션 인계
- plan: `docs/plans/2026-04-30-scaffold-drop-plan.md` PASS.
- 다음 작업: Phase 1 (코드 surface 제거 — Task 1.1 부터 1.7) impl 시작.
- impl 시 주의:
  - Task 1.1 의 plugin path indicator (`info "rein init: setting up plugin mode..."`) 실제 추가 위치 확인.
  - Task 1.2 가 `main()` 의 `merge|update)` dispatcher branch 만 수정 (cmd_update 함수 미존재).
  - Task 1.6 의 (검토) 12 파일 중 scaffold-only 분류 결과 확정 필요.
  - Phase 4 Step 4.1 의 옛 v1.0.0 wipe 명령은 conditional 분리 (`&&` 금지).
  - Phase 4 Step 4.4 의 atomic push 는 `--atomic` flag 강제.
  - Phase 4 Step 4.6 의 public publish secrets 부재 검증 결과에 따라 case A/B 분기.
  - Task 3.2 의 release-cleanup helper 가 v1.0.0 만 `--cleanup-tag` 제외, 19 pre-v1 은 포함.

---
## dod-2026-05-12-bootstrap-gate.md (mtime: 2026-05-14, archived: 2026-05-15)
# DoD — Plugin bootstrap gate (v1.1.1 hotfix)

- 날짜: 2026-05-12
- 유형: feat (brownfield, patch release v1.1.1)
- 타깃 release: v1.1.1
- spec ref (예정): docs/specs/2026-05-12-bootstrap-gate.md
- plan ref (예정): docs/plans/2026-05-12-bootstrap-gate.md
- 선행 분석:
  - codex-ask 1차 (trail bootstrap 진단): /tmp/codex-ask-trail-out.log
  - codex-ask 2차 (방향 검증): /tmp/codex-ask-bootstrap-direction.out
- 선행 release: v1.1.0 (main `9360650`, tag `v1.1.0`)

## 목표 한 줄

rein plugin 사용자가 자기 프로젝트 (git or non-git 무관) 에서 새 세션 시작 또는 `/reload-plugins` 실행 후, `trail/` 폴더가 없으면 첫 source 편집·Bash 도구 시도 직전에 차단되고 한 줄짜리 bootstrap 명령 안내를 받도록 한다. 두 trigger 경로 모두 동일한 helper·메시지·명령으로 수렴.

## 범위 한계 (이번 DoD — 확장)

- 본 DoD 는 **spec + plan + 구현 + review + release** 전 단계 cover.
- spec 단계 완료 (Round 3 PASS, stamp `51eb8141e61f7dfe.reviewed`).
- plan 단계 완료 (Round 4 user-approved, stamp `f3a299ca44af7698.reviewed`).
- 구현 단계 — 11 task / 4 wave 병렬 dispatch (file partitioning conflict-free):
  - Wave 1: Task 1.1 helper (단독)
  - Wave 2 (병렬 4): Task 1.2 / 1.3 / 1.5 / 2.3
  - Wave 3 (병렬 3): Task 1.4 / 2.1 / 2.2
  - Wave 4 (병렬 5): Task 3.1 / 3.2 / 3.3 / 3.4 / 3.5
- review 단계: codex-review (Mode A) + security-reviewer
- release: dev commit + main 선별 체크아웃 + `v1.1.1` tag + mirror-to-public

## 라우팅 추천

```yaml
agent: plan-writer       # plan 단계 — design 읽어 coverage matrix + covers 메타데이터 plan 작성 + validator + codex-review + plan stamp 자동
skills:
  - codex-review         # spec 단계에서 spec-review subflow 호출 (이미 완료, Round 3 PASS)
mcps: []
rationale: >
  spec 단계는 plain markdown 작성 + codex spec-review (이미 완료). plan 단계는
  plan-writer agent 가 자동 흐름 — spec 의 Scope Items 를 plan work unit 에 1:1
  매핑 + coverage matrix validator + codex spec-review subflow + plan stamp 자동
  생성. self-fix loop 없음 — NEEDS-FIX 시 사용자 핸드오프.
approved_by_user: true
```

## Task 분할 (spec + plan)

**Spec 단계 (완료)**:
1. ✅ spec markdown 작성 — `docs/specs/2026-05-12-bootstrap-gate.md` (19 Scope Items)
2. ✅ codex-review spec-review subflow 3 rounds (R1 NEEDS-FIX → fix → R2 NEEDS-FIX → fix → R3 PASS)
3. ✅ spec stamp 생성 — `trail/dod/.spec-reviews/51eb8141e61f7dfe.reviewed`

**Plan 단계**:
4. plan-writer agent dispatch — spec ref 전달, plan target `docs/plans/2026-05-12-bootstrap-gate.md`
5. agent 가 자동 수행:
   - design 의 Scope Items 읽기 → plan 의 `## Design 범위 커버리지 매트릭스` + 각 work unit `covers:` 메타데이터 생성
   - Phase 분할 (spec §"Phase 분할" 참고 — Phase 1 helper+차단, Phase 2 advisory+non-git, Phase 3 test+README)
   - `python3 scripts/rein-validate-coverage-matrix.py plan ...` PASS 확인
   - codex spec-review subflow 호출 (`[NON_INTERACTIVE] spec review for plan: docs/plans/...`)
   - PASS 시 `bash scripts/rein-mark-spec-reviewed.sh <plan-path> codex` 로 plan stamp 자동 생성
   - NEEDS-FIX/REJECT 시 사용자 핸드오프 (self-fix loop 없음)
6. plan stamp 생성 확인 후 inbox 기록 + index 갱신

## 핵심 scope 후보 (spec 에서 확정)

codex-ask 2차 결과 반영:
- A. trail/ 부재 시 PreToolUse(Edit|Write|MultiEdit) 차단 + 안내 stderr
- B. trail/ 부재 시 PreToolUse(Bash) 도 동일 차단 (source-writing Bash 우회 cover)
- C. trail/ 부재 시 UserPromptSubmit 가 모델에게 advisory inject (read-only session cover)
- D. 세 hook 가 동일 helper `bootstrap-check.sh` 사용 (DRY 메시지·명령)
- E. project dir resolution = stdin.cwd → git root → PWD (env var 의존 금지) — 기존 `project-dir.sh` 재사용
- F. helper API contract: stdout = 안내 텍스트, exit 0 = trail 존재 (no-op), exit 10 = bootstrap 필요, exit 11 = unsafe/refused
- G. hooks.json Edit|Write|MultiEdit matcher group 에서 bootstrap gate 가 첫 번째 (trail-rotate 보다 앞)
- H. `.rein/policy/hooks.yaml` 에서 bootstrap-gate disable 가능 (opt-out)
- I. helper 메시지에 "사용자에게 즉시 surface" instruction 포함 (모델 surface 확률 강화)
- J. project root 결정 — monorepo subdir launch 기본값 = git root (override env / option 은 v1.1.2+ defer)

## 위험 / 회귀 영역

1. **trail-rotate 순서 변경**: bootstrap gate 가 Edit matcher group 첫 번째로 가면, 기존 hook 순서에 의존하는 시나리오가 깨질 수 있음. test-pre-edit-dod-gate.sh / test-post-edit-dispatcher.sh 회귀 필수.
2. **Bash 도구 차단의 부작용**: PreToolUse(Bash) 의 추가 차단 hook 가 기존 `pre-bash-guard.sh` 의 stamp 체크와 충돌 가능. 우선순위 + 누적 차단 시나리오 검증.
3. **opt-out 의 의미**: `.rein/policy/hooks.yaml` 에서 bootstrap-gate disable 시 사용자 책임으로 trail/ 미생성 상태에서 작업 가능 — 의도적 동작이지만 다른 hook (예: stop-session-gate) 가 trail/ 부재로 오작동 가능.
4. **`/reload-plugins` lifecycle**: spec 상 SessionStart 재실행 안 됨 가정 — 검증 못 함 (codex-ask 의 UNVERIFIED). 실제 spec 미확정 동작에 의존하지 말고 PreToolUse hard gate 만 보장 contract.
5. **stderr surface 보장**: Claude Code UI 의 stderr 전체 surface 는 spec 부재. contract = "차단 + 모델이 메시지 받음" 까지만. 사용자 surface 는 best-effort.

## 검증 계획 (spec 단계)

- **Scope Items v2 contract**: 각 ID 가 entity + direction/threshold + scenario 3요소 포함 (design-plan-coverage.md §1.2)
- **coverage matrix validator**: spec subcommand 부재 (`scripts/rein-validate-coverage-matrix.py` 는 plan/dod 만 지원). 본 cycle 에서는 spec 의 내적 일관성을 codex spec-review subflow 가 검증 — 별도 spec validator 없음. plan 단계에서 plan matrix 가 본 spec 의 Scope Items 와 정합성 검증.
- **codex-review spec-review subflow**: `[NON_INTERACTIVE] spec review for design: docs/specs/2026-05-12-bootstrap-gate.md`
- **PASS 시 stamp**: `trail/dod/.spec-reviews/<hash>.reviewed`

## 완료 기준 (본 DoD)

- [ ] `docs/specs/2026-05-12-bootstrap-gate.md` 작성
- [ ] coverage matrix validator exit 0
- [ ] codex spec-review PASS verdict + spec stamp 생성
- [ ] `trail/inbox/2026-05-12-bootstrap-gate-spec.md` 작성
- [ ] `trail/index.md` 갱신 — 다음 진입점 = "bootstrap gate plan 작성 + 구현 (v1.1.1)"

---
## dod-2026-05-12-plugin-prompt-level-operating-model.md (mtime: 2026-05-14, archived: 2026-05-15)
# DoD — Plugin prompt-level operating model (v1.1.0)

- 날짜: 2026-05-12
- 유형: feat (brownfield, minor release)
- 타깃 release: v1.1.0
- spec ref: docs/specs/2026-05-12-plugin-prompt-level-operating-model.md
- plan ref: docs/plans/2026-05-12-plugin-prompt-level-operating-model.md
- brainstorm ref: docs/brainstorms/2026-05-12-plugin-prompt-level-operating-model.md
- spec stamp: trail/dod/.spec-reviews/595f862cd4d9eb96.reviewed (user-approved)
- plan stamp: trail/dod/.spec-reviews/d4ffff1038bbd3ed.reviewed (user-approved)
- approved_by_user: true

## 목표 한 줄

rein plugin v1.0.4 에 7 user-facing rule 의 prompt-level 책임을 6 mode delivery taxonomy + action mandate + overflow handoff 패턴으로 적시 전달하고, broken ref 5건을 inline 화하며, publish-time 형식 검사 + Claude Code minimum version 강제를 도입한다.

## 범위 연결

plan ref: docs/plans/2026-05-12-plugin-prompt-level-operating-model.md
work unit: Phase 1 ~ Phase 3 전체 (16 tasks)
covers: [plugin-bundled-rules-relocated-from-skills-rules-prompt-to-plugins-rein-core-rules-dir, each-plugin-shipped-rule-has-action-mandate-section-under-2kb-at-start-of-body, design-plan-coverage-body-size-under-10kb-after-stage-3-3-deletion-and-example-diet, dev-only-rules-excluded-from-plugin-tarball-via-branch-strategy-exclusion-list, session-start-rules-hook-injects-action-mandate-plus-body-for-code-style-security-testing-on-session-begin, user-prompt-submit-hook-injects-answer-only-mode-action-mandate-plus-body-every-user-turn, pre-tool-use-bash-hook-emits-background-jobs-action-mandate-plus-body-as-advisory-additional-context-after-bash-tool-selection-for-next-reasoning-step, pre-tool-use-agent-hook-emits-subagent-review-action-mandate-plus-body-as-advisory-additional-context-after-agent-tool-selection-for-next-reasoning-step, post-tool-use-injects-design-plan-coverage-action-mandate-plus-body-when-edit-write-targets-docs-specs-or-docs-plans-or-trail-dod-dod, post-edit-dispatcher-aggregates-all-active-sub-hook-stdout-into-single-json-envelope-preserving-each-stderr-and-propagating-exit-2-from-any-sub-hook, plugin-rule-body-exceeding-10000-chars-passes-through-as-claude-code-overflow-file-not-truncated-by-rein-hooks, pre-edit-dod-gate-stderr-lines-166-and-204-and-379-and-447-replace-orchestrator-md-references-with-inline-routing-procedure-text, post-write-dod-routing-check-stderr-line-77-replaces-orchestrator-md-reference-with-inline-routing-procedure-text, rein-publish-script-rejects-plugin-tarball-when-any-rule-missing-action-mandate-or-action-mandate-exceeds-2048-chars-or-hook-output-invalid-json]

## Task 분할 (plan 의존성 순서)

### Phase 1 — Rule catalog + action mandate (Task 1.1 → 1.2 → 1.3 → 1.4 → 1.5)
- Task 1.1: `skills/rules-prompt/` → `rules/` 마이그레이션 + `session-start-rules.sh` RULES_DIR 갱신
- Task 1.2: code-style / security / testing 에 `## 행동 강령` 절 추가 (≤ 2KB)
- Task 1.3: answer-only-mode / subagent-review / background-jobs 신규 plugin 복사 + 행동 강령 절 추가
- Task 1.4: design-plan-coverage 다이어트 (§3.3 삭제 + §1.4 예시 6→2 + §1.3 압축) → < 10KB + 행동 강령 절
- Task 1.5: dev-only 4 rule (branch-strategy/readme-style/versioning/legacy-shipped-pending) plugin 미포함 확인

### Phase 2 — Hook lifecycle (Task 2.0 → 2.1/2.2/2.3/2.4 → 2.5 → 2.6 → 2.7)
- Task 2.0: `hooks/lib/rule-inject.sh` helper (override probe + body 반환) — 모든 신규 inject hook 의 dependency
- Task 2.1: `user-prompt-submit-rules.sh` 신설 (turn-brief / answer-only-mode)
- Task 2.2: `pre-tool-use-agent-rules.sh` 신설 (tool-brief / subagent-review, Agent matcher)
- Task 2.3: `pre-tool-use-bash-rules.sh` 신설 (tool-brief / background-jobs, 기존 pre-bash-guard 와 분리)
- Task 2.4: `post-write-design-plan-coverage-rule.sh` 신설 (event-brief / docs/specs|plans|trail/dod 매치) + dispatcher sub-hook 등록
- Task 2.5: `hooks.json` final manifest (UserPromptSubmit slot + Agent matcher + Bash matcher 추가)
- Task 2.6: `post-edit-dispatcher.sh` aggregator refactor + `hooks/lib/aggregator.sh` (단일 JSON envelope + exit 2 propagation)
- Task 2.7: overflow handoff 정책 (no truncation + size diagnostic to stderr) + `docs/overflow-handoff.md`

### Phase 3 — Broken refs + CI (Task 3.1/3.2 병렬 가능, 3.3 별도)
- Task 3.1: `pre-edit-dod-gate.sh` line 166/204/379/447 orchestrator.md ref → inline 절차 텍스트
- Task 3.2: `post-write-dod-routing-check.sh` line 77 orchestrator.md ref → inline 절차 텍스트
- Task 3.3: `scripts/rein-validate-plugin-rules.py` + `scripts/rein-publish.sh` pre-publish 호출 (행동 강령 절 / 2KB / JSON envelope / dev-only 부재 검사)

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - superpowers:executing-plans     # 17 task plan 실행 discipline (review checkpoint 포함)
  - superpowers:test-driven-development  # 각 task 의 test 먼저 작성 패턴 — plan 의 모든 task 가 "failing test → impl → green" 구조
  - codex-review                    # 구현 완료 후 통합 코드 리뷰 stamp 생성
mcps: []                            # 외부 service 의존 없음 — 모두 local file/hook/script
rationale: >
  brownfield plugin 확장. plan 이 task 단위 TDD 구조 (test 먼저, impl, green) 로 명시되어 있고
  17 task 의 의존성이 명확해서 executing-plans + TDD 조합이 적합. codex-review 는 11단계 시퀀스
  필수 게이트. security-reviewer 는 codex-review 완료 후 자동 호출되므로 별도 명시 안 함.
  Explore agent 는 Plan/Spec 이 이미 파일 경로/라인 명시해서 불필요.
approved_by_user: true
```

## 위험 / 회귀 영역

1. **rules-prompt → rules/ 마이그레이션 (Task 1.1)** — `session-start-rules.sh` 의 RULES_DIR 갱신과 파일 이동이 atomic 해야 함. plan §"Migration Order" 의 4단계 (생성 → 갱신 → 테스트 → 옛 위치 삭제) 강제.
2. **dispatcher aggregator (Task 2.6)** — 기존 6 sub-hook 의 stderr/exit 2 의미 보존 필수. `post-edit-plan-coverage.sh` 의 exit 2 propagation 회귀 테스트 필수 (plan Task 2.6 Step 5).
3. **PreToolUse(Bash) 2 hook 공존 (Task 2.3)** — 기존 `pre-bash-guard.sh` 의 차단 동작 (codex stamp 부재 시 exit 2) 이 신규 inject hook 으로 인해 깨지지 않음. plan Task 2.3 Step 6 확인.
4. **PostToolUse hook input schema (Task 2.4)** — `tool_input.file_path` primary + `tool_response.filePath` / `tool_result.file_path` fallback 셋 다 fixture 로 검증. MultiEdit 동작은 Claude Code docs 미명시 — fixture 결과로 확정.
5. **overflow handoff 가정 (Task 2.7)** — Claude Code 의 10,000 chars cap + overflow-file 메커니즘은 외부 의존. unit test 는 "rein 이 truncate 안 함" 만 검증, end-to-end 는 integration test 로 분리.

## 검증 계획

- **Unit tests** — Phase 1: action mandate 절 존재/크기, design-plan-coverage size, dev-only 부재. Phase 2: rule-inject helper, 4 신규 hook envelope JSON, aggregator concat/exit 2, overflow no-truncation. Phase 3: orchestrator.md ref 부재, publish-time validation.
- **Integration tests** — MultiEdit hook input schema (Task 2.4), shell-stamp 가 PostToolUse 미 trigger (Task 2.4 deferred 근거), overflow end-to-end (Task 2.7).
- **Regression** — `post-edit-plan-coverage.sh` exit 2 propagation (Task 2.6), `pre-bash-guard.sh` 차단 시나리오 (Task 2.3).
- **Pre-publish dry-run** — Task 3.3 의 `rein-validate-plugin-rules.py` 가 모든 게이트 통과 확인.
- **`/codex-review`** — Phase 1+2+3 전체 diff 대상 통합 리뷰 (stamp 생성).
- **`security-reviewer`** — hook envelope / publish-time script / inline 절차 텍스트의 injection vector 점검.

## 완료 기준

- [ ] 16 task 모두 완료 + 각 task 의 test PASS
- [ ] `python3 scripts/rein-validate-plugin-rules.py` exit 0
- [ ] `scripts/rein-validate-coverage-matrix.py plan docs/plans/2026-05-12-plugin-prompt-level-operating-model.md` 통과
- [ ] `/codex-review` PASS → `trail/dod/.codex-reviewed` stamp
- [ ] `security-reviewer` PASS → `trail/dod/.security-reviewed` stamp
- [ ] `trail/inbox/2026-05-12-plugin-prompt-level-operating-model-impl.md` 작성
- [ ] `trail/index.md` 갱신 (다음 진입점 = v1.1.0 main 머지)
- [ ] CHANGELOG.md 항목 추가 (user-facing 효과 — 행동 강령 적시 inject, broken ref 해소)
- [ ] main 머지 + `v1.1.0` tag 는 별도 release task (본 DoD 외부)

---
## dod-2026-05-14-plugin-mode-gap-fix.md (mtime: 2026-05-14, archived: 2026-05-16)
# DoD — scaffold→plugin migration gap fix (v1.2.0)

- 날짜: 2026-05-14
- 유형: feat (cycle)
- 슬러그: plugin-mode-gap-fix
- 대상 버전: v1.2.0 (versioning Rule A — minor bump)
- 브랜치: dev (단방향 원칙 준수, 완료 시 main 선별 체크아웃)

## 범위 연결

plan ref: docs/plans/2026-05-14-plugin-mode-gap-fix.md
work unit: 전체 cycle (Phase 1~3, 14 work units)
covers: [BS-1-security-overlay-exclusion-reason-rewritten-to-state-plugin-source-has-no-security-and-bootstrap-creates-defaults-on-fresh-install, BS-2-scripts-rein-helper-include-reason-clarified-as-plugin-aware-resolver-prefers-plugin-root-and-falls-back-to-repo-only-for-maintainer-dogfood, SEC-1-bootstrap-creates-only-default-security-profile-yaml-in-user-repo-pointing-to-standard-level-without-copying-rules-files-which-stay-in-plugin-source, SEC-2-security-rule-and-agent-resolve-both-profile-and-rules-paths-via-explicit-priority-list-with-repo-override-then-plugin-source-fallback-applied-uniformly-to-profile-yaml-and-rules-level-md, SEC-3-standard-level-security-rules-md-shipped-with-base-five-checks-plus-deserialization-path-traversal-log-leak-tls-enforcement, RES-1-plugin-aware-helper-script-resolver-lib-introduced-and-sourced-by-all-hooks-that-call-scripts-rein-with-plugin-root-priority-over-repo-fallback-on-fresh-plugin-install, RES-2-helper-scripts-needed-by-fresh-plugin-user-shipped-in-plugin-bundle-with-bundle-test-asserting-presence-of-rein-mark-spec-reviewed-rein-codex-review-rein-validate-coverage-matrix, TST-1-plugin-bundle-parity-tests-rewritten-to-assert-overlay-absence-and-plugin-presence-matching-option-c-in-test-plugin-skills-agents-hooks-bundle-sh, VER-1-plugin-json-version-field-bumped-to-1-2-0-and-rein-publish-script-aborts-on-pre-publish-mismatch-between-plugin-json-and-rein-sh-version, BG-1-bootstrap-completion-detection-shared-helper-corrected-to-treat-trail-dir-plus-rein-project-json-marker-as-bootstrapped-and-eliminate-false-positive-across-all-four-gate-hooks, OPSEQ-1-operating-sequence-rule-injects-compact-action-mandate-listing-dod-routing-review-test-inbox-index-flow-on-session-start, WF-1-feature-builder-and-researcher-agent-descriptions-inline-non-obvious-workflow-rules-instead-of-naming-deleted-workflow-files, INC-1-incident-automation-helper-scripts-shipped-in-plugin-bundle-and-skills-resolve-via-plugin-aware-resolver-not-repo-local-paths, RTG-1-routing-procedure-injection-hook-fulfils-pre-edit-dod-gate-stderr-promise-by-emitting-routing-rule-body-on-dod-write-via-post-edit-dispatcher-sub-hook, RTG-2-skill-mcp-inventory-scanner-shipped-in-plugin-bundle-and-rein-state-paths-extended-with-skill-mcp-guide-state-path-replacing-claude-cache-hardcoded-reference]

## 배경

Option C migration (v1.1.0~v1.1.3) 후 plugin SSOT 와 scaffold-mode contract (branch-strategy.md, hook stderr 메시지) 사이 9 drift + 메인테이너 발견 2 추가 (SEC-3 standard.md ship, BG-1 bootstrap-gate false positive). codex 2 round audit + 사용자 product 결정 (incident-automation Keep, routing ceremony Keep) → 15 Scope IDs / 14 work units / 3 phases 로 spec/plan 작성. spec/plan codex review 4 round 후 self-review (Round 4 medium-only 1줄) 로 stamp 완료 (`.spec-reviews/0d935f44a966d2e8.reviewed`, `.spec-reviews/1ce69242c69817e6.reviewed`).

## 완료 기준 (cycle 전체)

### Phase 1 — Contract repair
- [x] BS-1, BS-2: branch-strategy.md L43-50 + L79 정정 (Wave 1 Task 1.1 PASS)
- [x] SEC-1: bootstrap 이 `.claude/security/profile.yaml` 만 생성 (rules 파일 제외) — Wave 2 PASS
- [x] SEC-2: security.md + security-reviewer.md 가 profile + rules 둘 다 priority list (repo override → plugin fallback) — Wave 2 PASS
- [x] SEC-3: `plugins/rein-core/security/rules/{base,standard}.md` ship (Wave 1 Task 1.5 PASS — 146 줄, 9 검사)
- [x] RES-1: `plugins/rein-core/hooks/lib/plugin-script-path.sh` 신축 + 5 hook sourcing (Wave 1 Task 1.2 + Fix A + Fix B 완료, 4 hook 추가 sourcing 14+ 지점)
- [x] RES-2: 3 helper plugin bundle 추가 (Wave 1 Task 1.6 + Fix E stale SOURCES 정리 + 보너스 rein-policy-loader drift sync)
- [x] TST-1: 3 bundle test 가 overlay 부재 + plugin presence assert (Wave 1 Task 1.7 PASS)
- [x] VER-1: plugin.json 1.2.0 + rein.sh VERSION 1.2.0 + rein-publish.sh parity assert (Wave 1 Task 1.8 + Fix C run-all.sh 등록)
- [x] BG-1: `lib/bootstrap-check.sh` 가 trail/ + `.rein/project.json` 동시 존재 시 PASS (Wave 1 Task 1.9 + Fix D fixture 갱신 + 신 K/L case + lib bilingual guidance 정정 + Wave 5 F7 English message + F8 fixture G(b) BG-1 신 contract, 17/17 + 7/7 PASS)

### Phase 2 — Operating-model legibility
- [x] OPSEQ-1: `plugins/rein-core/rules/operating-sequence.md` 신축 (1946 B ≤ 2 KB) + SessionStart inject 4번째 rule (Wave 3 PASS)
- [x] WF-1: feature-builder/researcher agent description 에 minimum workflow procedure inline (Wave 3 PASS)

### Phase 3 — Routing & incident data paths
- [x] INC-1: 4 incident helper plugin ship + 2 skill SKILL.md 의 호출 instruction plugin path + 2 hook RES-1 sourcing (Wave 4 PASS)
- [x] RTG-1: `post-write-routing-procedure-rule.sh` 신축 + `routing-procedure.md` (1019 B ≤ 1 KB) + dispatcher 등록 + stderr false promise 해소 (Wave 3 PASS)
- [x] RTG-2: `rein-scan-skill-mcp.py` plugin ship + `rein-state-paths.py` 에 `skill-mcp-guide` state 추가 + session-start-load-trail.sh 의 `.claude/cache` 하드코딩 제거 + Wave 5 F1 scanner plugin-aware refactor (Wave 4 + F1)

### Wave 5 — 잔존 fix (사용자 Option A 승인)
- [x] F1: scanner plugin-aware refactor (`_resolve_inventory_dir(project)` 추가, 두 mirror sha256 parity) — plugin mode mismatch 해소
- [x] F2: pre-edit-dod-gate.sh L267 (rein-aggregate-incidents resolver, fail-closed) + L292-293 message
- [x] F3: test bundle L31 "12" → "13" doc drift fix
- [x] F4: pre-edit-dod-gate.sh L370 message + L478-486 (rein-generate-skill-mcp-guide resolver, fail-graceful — advisory WARNING 의도 보존)
- [x] F5: scripts/rein-codex-review.sh layout probe (`${PROJECT_DIR}/plugins/rein-core/hooks/lib/` 추가, Option C dogfood drift 해소)
- [x] F6: plugins/rein-core/scripts/rein-codex-review.sh mirror sync (F5 누락 해소, sha256-identical)
- [x] F7: bootstrap-check.sh 영문 메시지에 "directory" 단어 추가 (test fixture A grep substring 호환)
- [x] F8: test-session-start-bootstrap fixture G(b) BG-1 신 contract 갱신 (trail/ only → prompt, 이전 silent)
- [x] F9: test-rules-prompt-bundle-drift skip 처리 (b8f2191 incomplete work, 별 cycle 후속)

### 통합 검증
- [x] `bash tests/scripts/run-all.sh` PASS — ALL SUITES PASSED (test-rules-prompt-bundle-drift SKIP 적용 후)
- [x] codex review (구현 완료 후) PASS — sonnet-fallback path (codex wrapper hang → general-purpose agent) → HIGH 1 + MEDIUM 1 + LOW 2 발견 → F6/F7/F8/F9 fix → ALL SUITES PASSED
- [x] security review PASS — base level, CRITICAL/HIGH/MEDIUM 0, LOW 3 advisory + INFO 4 defense-in-depth
- [x] CHANGELOG.md user-facing 항목 추가 (rein update 사용자 시점)
- [x] inbox 기록 — `trail/inbox/2026-05-14-v1-2-0-cycle-complete.md`
- [x] trail/index.md 갱신
- [ ] dev → main 선별 체크아웃 + tag v1.2.0 + push (사용자 확인 후, 별 turn)

### 제외 (versioning Rule A — internal 변경, no bump 영향 없음)
- 본 cycle 의 spec/plan/brainstorm 자체 (`docs/{specs,plans,brainstorms}/2026-05-14-plugin-mode-gap-fix.md`) — main 제외
- branch-strategy.md 정정 (BS-1, BS-2) — dev-only

## 작업 순서 (plan §작업 순서 권고)

1. **Task 1.2 (RES-1) + Task 1.9 (BG-1)** 먼저 — Phase 2/3 acceptance 가 둘 다 의존
2. SEC 묶음: Task 1.5 (SEC-3) → Task 1.3 (SEC-1) → Task 1.4 (SEC-2)
3. Phase 1 나머지 (1.1, 1.6, 1.7, 1.8) — 독립 병렬
4. Phase 2 (2.1, 2.2) — Phase 1 의 BG-1 PASS 후
5. Phase 3 (3.1, 3.2, 3.3) — Phase 1 의 RES-1, BG-1 PASS 후

본 DoD 의 첫 routing 추천은 **Task 1.2 (RES-1) 단독 시작** — 가장 의존성 많은 lib helper 부터.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:codex-review
  - rein:writing-plans
mcps: []
rationale:
  - 작업 성격: 신규 hook lib 작성 (`plugin-script-path.sh`) + 5 기존 hook 의 sourcing 패턴 통일 + unit test 6 case 신축. 전형적 feature 추가 + refactor.
  - 파일 패턴: `plugins/rein-core/hooks/lib/*.sh` (신규), `plugins/rein-core/hooks/*.sh` (편집), `tests/hooks/test-plugin-script-path-resolver.sh` (신규)
  - feature-builder 가 1차 구현 → codex-review 로 리뷰 게이트 (mandatory) → 코드 변경 적은 hook sourcing 은 sonnet self-review path 가능
  - writing-plans 는 본 cycle 의 plan 이 이미 있으므로 추가 plan 작성에는 불필요할 수 있음. 하지만 Task 1.2 가 lib 신설이므로 sub-plan 형태로 caller 패턴 표 작성 시 유용
  - mcps: 외부 데이터/문서 조회 불필요 — lib helper + 내부 hook refactor 만
approved_by_user: true   # 2026-05-14 user-approved (Task 1.2 RES-1 시작)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (session start)
- [x] spec/plan stamp 확인 (`.spec-reviews/0d935f44a966d2e8.reviewed`, `.spec-reviews/1ce69242c69817e6.reviewed`)
- [x] dev 브랜치 확인
- [x] coverage validator PASS (15 ID 일치)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 위험 요약 (spec Risks 5건 압축)

- R1: RES-1 lib 이 5+ hook 에서 sourced — caller 패턴 통일 + unit test 6 case 로 회귀 방지
- R2: RTG-1 routing-procedure.md ≤ 1 KB 압축 가능
- R3: SEC-1 default `standard` 의 false positive — generated profile.yaml 헤더에 base 변경 안내
- R4: branch-strategy.md 정정이 main 머지 절차와 동시 — dev 단방향 + main 머지 PR description 강조
- R5: BG-1 marker 강화로 의도된 차단 유지 — `.rein/project.json` 부재 시 차단 (test-bootstrap-check-helper.sh 갱신)

## 다음 단계 (라우팅 승인 후)

1. 사용자 "진행해" 또는 라우팅 수정 의견 → `approved_by_user: true` 갱신
2. Task 1.2 (RES-1) IMPLEMENT — `plugin-script-path.sh` 신축 + 5 hook sourcing + unit test
3. `/codex-review` (Mode A) — Task 1.2 완료 후 코드 리뷰 게이트
4. security-reviewer — Task 1.2 가 hook 동작 변경이므로 보안 리뷰 (lib 의 fail-open 정책 검증)
5. 두 stamp 통과 후 Task 1.9 (BG-1) 또는 다른 Phase 1 task 로 이동

---
## dod-2026-05-14-v1-1-3-release-option-c-shipped.md (mtime: 2026-05-14, archived: 2026-05-16)
# DoD — v1.1.3 release: Option C plugin SSOT + dogfood model shipped

- 날짜: 2026-05-14
- 유형: release (patch — Phase 4 plugin rule body 변화 = minimal user-facing, Rule A patch)
- plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md (Phase 6 — release 보류 결정을 본 DoD 가 override: 사용자 결정으로 즉시 release)

## 범위 연결

plan ref: docs/plans/2026-05-13-option-c-plugin-ssot-thin-overlay.md
work unit: Phase 6 / release (Rule A 보류 → 사용자 결정으로 즉시 release)
covers: [S1, S2, S3, S4, S5, S6, S7, S8, S9, S10]

## 목적

Option C Phase 1~5 의 변경분 (`c1cb693..16c0184`, 11 commits) 을 v1.1.3 patch release 로 사용자에게 ship. 본 cycle 의 핵심 산출물:

- **plugin SSOT 단독 source** — `.claude/{hooks,skills,agents}/` overlay 폐기, plugin source 가 사용자 ship 단일 SSOT
- **drift checker 통합 도구** — boundary + parity + validation 3 layer 단일 도구 (`scripts/rein-check-plugin-drift.py`)
- **plugin rule body 정확성 회복** — `design-plan-coverage.md` 의 mandate section + enrichment sync (user-facing inject content)
- **branch-strategy + workflow surface 갱신** — 9 workflow 분류 명시, mirror-to-public strip 패턴과 일관

## user-facing 영향 (versioning.md Rule A 판정)

| 변경 | user-facing? | 정당화 |
|---|---|---|
| plugin SessionStart inject 시 `design-plan-coverage.md` 본문 풍부해짐 | ✅ 약간 — SessionStart 시 사용자가 받는 rule body content 변화 | patch bump 정당화 |
| plugin tarball 사이즈 감소 (docs/rules 4 mirror 폐기) | ✅ 약간 — install size + cache footprint 감소 | positive delta |
| `${CLAUDE_PLUGIN_ROOT}/rules/answer-only-mode.md` banner path 정확화 | ✅ minor — installed plugin 환경에서 메시지 정확 | patch |
| 메인테이너 dev overlay 폐기 (`.claude/hooks/` 등) | ❌ 사용자 환경에는 overlay 자체 부재 | internal |
| drift checker 도구 통합 | ❌ 메인테이너 도구 | internal |

→ **Rule A patch bump 정당화** (user-facing 영향 약함 + breaking 없음).

## 변경 작업

### Task 1 — VERSION bump (dev 에서 먼저)

`scripts/rein.sh` 의 `VERSION="1.1.2"` → `VERSION="1.1.3"`.

### Task 2 — CHANGELOG.md 새 v1.1.3 entry

플랫 (`## v1.1.3 — 2026-05-14 (Option C plugin SSOT + dogfood model shipped)`) 본문:
- user-facing 변화 위주 (`feedback_release_readme_version_entry.md` 권고)
- internal cleanup 은 짧게 언급
- v1.1.2 entry 위에 추가

### Task 3 — README.md / README.ko.md 버전 히스토리 1~2줄 + CHANGELOG 링크

`feedback_release_readme_version_entry.md` 의 patterns 따름:
- 간략 1~2줄 entry
- 상세는 CHANGELOG.md 의 `#v113-...` anchor 로 링크

### Task 4 — dev commit ("chore(release): v1.1.3 prep") + push

VERSION + CHANGELOG + README 변경 묶음 단일 commit.

### Task 5 — main 머지 (선별 체크아웃, `feedback_branch_strategy_order.md` 준수)

```
git checkout main
git checkout dev -- <branch-strategy.md ✅ 포함 list>
```

main 머지 대상 (Option C Phase 5 의 branch-strategy.md ✅ 포함 표 따름):
- `plugins/rein-core/**`
- `.claude-plugin/marketplace.json`
- `AGENTS.md`, `README.md`, `README.ko.md`, `main_img.png`, `CHANGELOG.md`
- `docs/{changelog-archive,troubleshooting,agents-md-examples.md}/**`
- `scripts/rein*.{sh,py}`
- `.gitignore`, `.github/workflows/*.yml` (mirror 가 strip 대상 처리)

❌ 제외: `.claude/{CLAUDE.md,rules/,settings*.json,orchestrator.md,workflows/,cache/,.rein-state/}`, `tests/**`, `docs/{specs,plans,brainstorms,reports}/**`, `trail/**`, `need-to-confirm.md` 등

### Task 6 — main commit + tag v1.1.3

```
git commit -m "feat(release): v1.1.3 — Option C plugin SSOT + dogfood model"
git tag v1.1.3
```

### Task 7 — main + tag push

```
git push origin main
git push origin v1.1.3
```

mirror-to-public + publish-plugin workflow 가 자동 trigger.

### Task 8 — dev sync (post-release 기록)

dev 에 commit: `docs(trail): v1.1.3 release 종결 — main <sha> + tag v1.1.3 반영` + trail/index.md 갱신.

## 검증 게이트

- [ ] Task 1: `grep '^VERSION=' scripts/rein.sh` = `VERSION="1.1.3"`
- [ ] Task 2: CHANGELOG.md 의 `## v1.1.3 — 2026-05-14` entry 존재
- [ ] Task 3: README.md + README.ko.md 의 v1.1.3 entry 1~2줄 + CHANGELOG 링크
- [ ] Task 4: dev commit 후 origin/dev push (ahead 0)
- [ ] Task 5: main 의 working tree 가 dev 의 main-mergeable subset 과 일치 (memory `feedback_plugin_validate_before_main.md` — `claude plugin validate` 권고)
- [ ] Task 6: main HEAD = 새 commit, `git tag -l v1.1.3` = exists
- [ ] Task 7: `git ls-remote --tags origin v1.1.3` 매치
- [ ] Task 8: dev/origin/dev ahead 0, trail/index.md "이전 완료" 에 v1.1.3 추가
- [ ] codex-review PASS (release commit 전체 변경분)
- [ ] security-review No concerns

## Rollback

문제 시:
- main push 전: `git checkout dev` + main working tree reset
- main push 후 tag 전: `git push --delete origin main` 위험 (force push to main 금지) — 새 commit 으로 revert
- tag push 후: `git tag -d v1.1.3` (로컬) + `git push --delete origin v1.1.3` (사용자 명시 승인 필요)

## Release

본 cycle main 머지 = v1.1.3. tag v1.1.3 생성. mirror-to-public + publish-plugin workflow trigger.

## 라우팅 추천

```yaml
agent: feature-builder
skills:
  - codex-review        # release 변경분 (VERSION/CHANGELOG/README) 리뷰
  - changelog-writer    # CHANGELOG entry 작성 권고 (선택)
mcps: []
rationale: |
  release cycle 의 변경은 작음 (VERSION + CHANGELOG + README 3 파일 변경 + main 머지
  + tag). codex-review medium effort 가 적합. changelog-writer skill 은 git log
  기반 자동 CHANGELOG 작성에 사용 (선택, manual 작성도 가능).
approved_by_user: true
```

## Self-review (release cycle 종료 시 작성)

- [ ] 모든 Task 검증 게이트 통과
- [ ] codex-review PASS + security-reviewer No concerns
- [ ] main HEAD = v1.1.3 tag commit + origin push 완료
- [ ] mirror-to-public + publish-plugin workflow trigger 확인
- [ ] dev sync + trail 갱신

---
## dod-2026-05-16-q9-mirror-tag-trigger.md (mtime: 2026-05-16, archived: 2026-05-18)
# DoD — Q9 mirror-to-public tag trigger fix

- 작업 시작일: 2026-05-16
- 유형: fix (CI workflow — internal, no version bump per versioning.md Rule A)
- plan ref: `docs/reports/2026-05-15-mirror-public-q9-diagnosis.md` (진단 + Option A/B/C 설계, §4 권고 = A+C)

## 배경 / 문제

`mirror-to-public.yml` 은 `push: branches:[main]` 만 trigger. release flow 가 main push 후 tag 를 별도 push 하므로, mirror runner checkout 시점에 tag 가 origin 에 부재 → Q9 retag block 의 `git tag --points-at "$GITHUB_SHA"` 가 empty → retag + tag-push 루프 모두 skip → workflow 는 success 인데 tag 미전파 (silent). v1.2.0 / v1.3.0 둘 다 이 결함으로 public tag 수동 push 필요했음. 미수정 시 v1.4.0 재발.

## 완료 기준 (codex-ask 검토 반영 — 아래 §codex-ask 참조)

1. `on.push` 에 `tags: ['v*']` 추가 — tag push 시 workflow 실행.
2. `concurrency` 그룹 = `mirror-${{ github.ref_type }}-${{ github.ref_name }}` + `cancel-in-progress: false`. branch run 은 `mirror-branch-main` 으로 직렬화, tag run 은 tag별 고유 group → branch run 과 미직렬화 (codex-ask #2: 단일 group 은 tag run 선행 시 public main 을 갱신할 branch run 을 가두는 deadlock).
3. branch-triggered step (`if: github.ref_type == 'branch'`): 기존 strip + `git push public HEAD:main --force` 유지. postcondition 추가 — public main 을 fetch 해 `== pushed HEAD` 확인, 불일치 시 `exit 1`.
4. tag-triggered step (`if: github.ref_type == 'tag'`) 신규:
   - `TAG_COMMIT = git rev-parse "${GITHUB_REF}^{commit}"` 명시 resolve (codex-ask: `$GITHUB_SHA` 직접 의존 회피, annotated tag 안전).
   - `TAG_COMMIT == origin/main` 검증 — 불일치 시 fail-loud (codex-ask #3: 오래된 commit 재태깅 / 늦은 tag run false-pass 방어. retroactive 태그 복구는 수동).
   - `public` remote 추가 → public main 을 fetch+poll (`git merge-base --is-ancestor "$TAG_COMMIT" <public/main>` 만족까지, 10s 간격 최대 30회). codex-ask #4: `ls-remote` SHA 만으로는 merge-base 불가 — fetch 필수.
   - poll 만족 후 `<public/main>:refs/tags/<tag>` lightweight force-push → postcondition (`git ls-remote public refs/tags/<tag>` == public/main, 불일치 시 `exit 1`).
   - poll timeout 시 fail-loud (branch run 미완료/실패 의미).
5. 깨진 Q9 retag block (`ATTACHED_TAGS` / `git tag -f -a` 루프) 제거 — tag-triggered step 이 tag 전파 단독 경로. split push + atomic push 양쪽 커버.
6. `PUBLIC_REPO_TOKEN` 은 step `env:` 로 전달 (script inline `${{ secrets }}` interpolation 회피). 토큰은 `git remote add public <url>` 1회 사용 후 remote 이름으로만 참조. `set -x` 미사용·`git remote -v` 미호출 — URL embed 토큰 노출 차단.
7. grep-contract 테스트 1개 추가 — tag trigger / 조건부 concurrency / ref_type 분기 / ancestor poll / postcondition / Q9 block 제거를 lock-in.
8. YAML 문법 유효성 검증 통과.
9. codex-review + security-review 통과.

## codex-ask 설계 검토 (2026-05-16, gpt-5.5 high)

진단 §4 의 A+C 권고를 구현하려던 초안 (단일 concurrency group + ancestor guard fail-loud) 에 codex-ask 가 결함 3건 지적:

1. **단일 concurrency group deadlock** — tag run 이 슬롯을 먼저 잡으면 public main 을 갱신할 branch run 이 뒤에 갇힘 → tag run 영구 실패. → ref별 조건부 group + tag run polling.
2. **ancestor guard false-pass** — 오래된 M 이 새 public main 의 ancestor 라 guard 통과 → 엉뚱 commit 태깅. → `TAG_COMMIT == origin/main` precondition.
3. **`merge-base --is-ancestor` 는 객체 필요** — `ls-remote` SHA 만으로 불가, `git fetch public` 선행.

codex 권고 최종 설계를 위 완료 기준 #2~#6 에 반영. 원문: codex-ask 세션 출력 (요약: trail/inbox).

## 범위

- `.github/workflows/mirror-to-public.yml` — 편집
- `tests/scripts/test-mirror-workflow-q9-fix.sh` (또는 동등 위치) — 신규

## 비범위

- mirror strip set 변경 (진단 §5 out-of-scope — `tests/`·`.claude` 잔존은 별도 cycle)
- main 머지 (별도 — versioning Rule B 하루 1머지, 다른 변경과 batch 판단 필요. 본 변경은 no-bump CI 변경)
- `publish-plugin.yml` (별도 후보)
- v1.0.0~v1.3.0 public tag 의 기존 annotated/lightweight 혼재 (소급 정리 안 함)

## 라우팅 추천

```yaml
agent: none  # main session 직접 구현 — 단일 파일 YAML + 테스트 1개, 설계 분석 완료
skills:
  - rein:codex-ask      # 구현 전 설계 second opinion — concurrency + ancestor guard 가 진단 A+C 의 확장 (사용자 승인)
  - rein:codex-review   # step 5 필수 게이트 — public force-push workflow 안전성 검토
mcps: []
rationale: |
  단일 workflow 파일 + grep-contract 테스트의 focused 변경. 설계는 진단 리포트가
  이미 Option A/B/C 탐색 완료, 본 작업은 A+C 구현 + concurrency/ancestor-guard 보강.
  public repo force-push 를 다루는 risky 변경이므로 구현 전 codex-ask 설계 검토 +
  구현 후 codex-review 필수.
approved_by_user: true
```

---
## dod-2026-05-17-hook-tone-impl.md (mtime: 2026-05-17, archived: 2026-05-19)
# DoD — hook 메시지 비서톤/다국어화 2단계 구현

- 날짜: 2026-05-17
- 유형: feat

## 목표

plan `docs/plans/2026-05-17-hook-message-assistant-tone.md` (Phase 1~4 / Task
1.1~4.3) 을 구현한다 — emitter `deny_emit` 3슬롯 재설계, pre-bash-guard 정책 차단
11지점 JSON deny 전환, 사용자 대면 hook 메시지 4표면 비서톤 재작성, AGENTS.md
trail/docs 작성 언어 규칙 추가.

## 완료 기준

- plan Task 1.1~4.3 전부 구현, Scope Items S1~S10 충족
- emitter 3슬롯 + reason_code 필수화, fail-closed 불변식 보존 (신규 fail-open 0)
- pre-bash-guard: 정책 차단 11지점 `exit 0 + JSON deny`, 인프라 5지점 `exit 2` 유지
- 회귀 테스트 통과 (test-json-deny-emitter 14 시나리오, pre-bash-guard 계열)
- codex review + security review 통과 → VERSION 1.3.1

## 범위 연결

plan ref: docs/plans/2026-05-17-hook-message-assistant-tone.md
work unit: Phase 1~4 전체
covers: [S1, S2, S3, S4, S5, S6, S7, S8, S9, S10]

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:subagent-driven-development
  - superpowers:test-driven-development
mcps: []
rationale: >
  bash hook + python 직렬화 구현 — feature-builder 가 신규 기능 구현 전담.
  subagent-driven-development 로 plan 의 13 task 를 implementer subagent 에
  디스패치, TDD 로 각 task 실패 테스트 우선. 외부 API/문서 조회 없어 MCP 불요.
approved_by_user: true  # 2026-05-17 사용자 승인 — 진행 방식: 4 Wave 연속
```

## 병렬 진행 계획 (agent teams)

plan 의존성상 emitter(Phase 1) → pre-bash-guard(Phase 2) 는 순차. 독립 task 만 병렬:

- Wave 1: [Phase 1 — Task 1.1→1.2→1.3 순차] ∥ [Task 3.3 SessionStart] ∥ [Task 3.5 AGENTS.md]
- Wave 2: [Phase 2 — Task 2.1→2.5 순차] ∥ [Task 4.2 보존 문서]
- Wave 3: Task 3.1 → 3.2 → 3.4 (순차 — pre-bash-guard / stop-session-gate 공유)
- Wave 4: Task 4.1 (전체 회귀) → Task 4.3 (versioning)

각 task: implementer subagent → spec reviewer → code+security reviewer (subagent-review.md).

---
## dod-2026-05-20-area-b-post-edit-deferral-design.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — Area B post-edit deferral design memo (Cycle X3.B.0)

- 날짜: 2026-05-20
- 유형: docs (design memo only — 구현 미포함)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.2 (영역 B)
- cycle: X3.B.0 (design memo only) — 구현은 후속 X3.B.1~ 별 cycle

## 범위 (Scope)

본 cycle 의 산출물은 **design memo 1건** + **trail 갱신**.

포함:

- `docs/specs/2026-05-20-area-b-post-edit-deferral.md` 신축
  - 영역 B 의 Scope ID 신설안 (1건, ID 본문 plan §4.2 의 placeholder 를 다듬어 확정)
  - 현 6 post-edit hook 의 실제 비용 분류 (heavy / medium / light) — 측정 + 코드 기반 정성 분석
  - 대안 3안 (full migration / deferred 모드 / edit-burst skip + commit flush) 비교 + 권고 선택
  - 권고 선택 (deferred 모드) 의 hook-by-hook 처리 decision table
  - X3.B sub-step 분해 (B.1~B.n) — 각 step 의 단위 산출물 + adversarial test 후보 + 회귀 위험
  - risk register
  - 본 design memo 가 cc-feature-adoption spec (`docs/specs/2026-05-19-cc-feature-adoption.md`) 의 자식임을 명시 — parent spec 의 HK-4 가 dispatcher 분할까지였고 본 memo 는 commit-시점 이동을 신규 Scope 로 분리하는 합당성 정당화
- `trail/inbox/2026-05-20-area-b-design-memo.md` — 본 cycle 완료 기록
- `trail/index.md` — 다음 진입점을 "X3.B.1 구현" 으로 갱신

제외 (의도적 — 별 cycle):

- 6 hook 본문 수정 또는 hooks.json 변경 (구현은 X3.B.1+)
- pre-bash-test-commit-gate.sh 흡수 로직 추가
- `.rein/state.json` schema 변경 (영역 C 와 중첩 — design memo 가 영역 C 경계 명시)
- adversarial test 신축 (X3.B.1+ 에서 step 별 작성)

## 작업 기준 (Definition of Done)

1. design memo 파일이 신축되고 아래 섹션을 모두 포함:
   - §0 metadata + parent spec ref
   - §1 motivation (성능 노트 Phase 4 + plan §4.2 의 의도 재진술)
   - §2 현 6 hook 비용 분석 — 코드 grep 기반 책임/마커/exit code/cost class 표
   - §3 대안 3안 비교 + 권고
   - §4 권고안의 hook-by-hook decision table (6개 모두)
   - §5 X3.B sub-step 분해 (B.1~B.n) — 각 step 의 산출물·검증·의존
   - §6 risk register (race / `if` field bug / TDD 흐름 / commit gate 무게 / fail-closed 정책)
   - §7 coverage 매트릭스 (본 cycle 의 Scope ID 1건 → 본 design memo 자체 = `design only`)
   - §8 amendment policy (구현 cycle 진행 중 갱신 규칙)
2. design memo 가 codex-review (Mode A) PASS — `trail/dod/.codex-reviewed` stamp 생성
3. security-reviewer 실행 — `trail/dod/.security-reviewed` stamp 생성 또는 security_tier:light 명시 (memo only 라 light 가 자연)
4. trail/inbox + trail/index.md 갱신
5. dev commit + push

## 검증

- design memo 의 §2 표가 실제 hook 본문과 일치 (`head -25` 결과로 확인된 책임 매핑 반영)
- §3 의 권고가 §4 의 decision table 과 일관 (모순 없음)
- §5 의 sub-step 합집합 = 영역 B 전체 작업 (gap 0)
- §6 의 risk 가 plan §4.2 의 5 risk + 본 memo 작성 중 발견된 추가 risk 모두 포함

## 라우팅 추천

```yaml
agent: rein:plan-writer
skills:
  - rein:writing-plans
  - superpowers:writing-plans
  - rein:codex-ask
mcps: []
rationale: |
  design memo only cycle. plan-writer agent 가 spec/design 문서 신축 + Scope ID
  신설 + coverage matrix 의 일관성 책임. writing-plans (rein + superpowers) 두
  skill 은 design memo 의 sub-step 분해 + risk register 작성에 직접 적용.
  codex-ask 는 design memo 의 sanity check (Mode B, stamp 무생성) — 단, 본 cycle
  의 codex review gate 는 별도 /codex-review (Mode A) 가 처리.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "오토모드로 진행" 명시. design memo only cycle 이라 코드 변경 risk
  없음. plan-writer + writing-plans 조합은 design memo 작성의 가장 표준 라우팅.
  다른 cycle 에서 codex 가 design 자체에 강한 우려를 제기할 가능성은 잔존 —
  /codex-review (Mode A) 단계가 그 점검을 담당.
```

## self-review 체크리스트

- [ ] design memo 의 권고가 영역 C (state machine) 와 명확한 경계 보유 — overlap 없음
- [ ] sub-step 분해가 각 step 의 회귀 risk 를 단독으로 평가 가능한 단위
- [ ] envelope inject (advisory, never blocks) 와 marker-creating gate (blocking) 의 차이가 design 에 명시
- [ ] `if` field bug (Issue #46103, Edit/Write 에서 `if` 무시) 우회 방안 명시
- [ ] TDD red-green 흐름 보존 — test 실행 자체는 비차단 유지

---
## dod-2026-05-20-cc-feature-adoption-phase4-short-rule-and-if-field.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — cc-feature-adoption Phase 4: short rule injection + Bash hook if-field

- 작업 시작일: 2026-05-20
- 유형: feat (patch — Phase 4 user-facing rule body 축소 + hook config tweak, versioning.md Rule A patch)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 4 신설 예정)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 4 (Task 4.1 short-rule-injection, Task 4.2 bash-hook-if-field)
covers: [UPS-1-user-prompt-submit-rules-and-pre-tool-use-bash-rules-hooks-inject-short-summary-bodies-instead-of-full-answer-only-mode-and-background-jobs-text-while-session-start-rules-keeps-its-existing-four-rule-full-inject-unchanged, PERF-3-background-jobs-advisory-hook-skipped-via-if-field-hot-path-whitelist-pattern-while-bootstrap-gate-and-safety-guard-remain-always-on]

## 배경

2026-05-20 Phase 0 측정 결과:

| 항목 | 1회 크기 | 빈도 | 1시간 누적 |
|---|---:|---:|---:|
| SessionStart (session-start-rules.sh concat) | 12 KB | 1회 | 12 KB |
| UserPromptSubmit (answer-only-mode.md) | 7 KB | 매 user turn | ~140 KB |
| PreToolUse(Bash) (background-jobs.md) | 6 KB | 매 Bash 호출 | ~180 KB |
| **합계** | | | **~332 KB** |

Hook wall-clock (3회 평균):

| Hook | wall-clock | 빈도 |
|---|---:|---|
| session-start-load-trail.sh | 0.184s ⚠️ 가장 느림 (PERF-1 적용 후) | 1회 |
| session-start-rules.sh | 0.154s | 1회 |
| session-start-bootstrap.sh | 0.056s | 1회 |
| user-prompt-submit-rules.sh | 0.102s | 매 turn |
| pre-tool-use-bash-bootstrap-gate.sh | 0.143s | 매 Bash |
| pre-tool-use-bash-rules.sh | 0.061s | 매 Bash |
| pre-bash-guard.sh | 0.003s | 매 Bash |

Phase 1 의 PERF-1 (aggregate 단일 subprocess 통합 = improve_plan #8) 이 session-start-load-trail SessionStart latency 일부 해소했으나, 매 turn / 매 Bash inject body 자체는 그대로. token/attention 효율 + cold-path wall-clock 개선이 필요.

본 Phase 4 는 cc-feature-adoption 14 Scope 와 별개 신규 2 Scope (UPS-1, PERF-3) 로 plan/spec 갱신.

## 완료 기준

### Task 4.1 — Short rule injection (UPS-1)

- [x] `plugins/rein-core/rules/short/answer-only-summary.md` 신축 — **실측 546 B** (≤ 600 B 목표, ≈92% 감소)
- [x] `plugins/rein-core/rules/short/background-jobs-summary.md` 신축 — **실측 515 B** (≤ 600 B 목표, ≈91% 감소)
- [x] `user-prompt-submit-rules.sh` 가 `rule_inject_body short/answer-only-summary` 호출로 변경 (이전: `answer-only-mode`)
- [x] `pre-tool-use-bash-rules.sh` 가 `rule_inject_body short/background-jobs-summary` 호출로 변경 (이전: `background-jobs`)
- [x] **`session-start-rules.sh` 의 기존 4-rule full inject (code-style / security / testing / operating-sequence) 는 미변경** — 이 4개는 SessionStart anchor. **`answer-only-mode` / `background-jobs` 는 SessionStart 에 inject 되지 않고 매 turn / 매 Bash 호출에서만 등장**하므로 short summary 전환만 적용 (R1 mitigation 참조)
- [x] before/after byte 측정 — 실측: 7049 B → 546 B (**92.3% 감소**), 5959 B → 515 B (**91.4% 감소**). 1시간 누적 시나리오 ~332 KB → ~38 KB (89% 감소). DoD ≤ 600 B 목표 (이전 추정 ≤400B 에서 정정 — 한국어 본문 가독성·효력 보존 위해 600B 로 상향, 절대 감소율은 91~92% 로 충분)
- [ ] hook 단위 테스트 통과 (`tests/scripts/test-ups1-short-rule-injection.sh` 신규 — 다음 단계)

### Task 4.2 — background-jobs advisory hook cold-path skip (PERF-3)

> codex 권고 반영: PERF-3 의 범위를 **`pre-tool-use-bash-rules.sh` (background-jobs body inject 전담) 에 한정** + `if` 패턴은 **positive hot-path whitelist** 방식 (cold path enumerate 대신 hot path 만 명시 + 미분류는 hot 으로 fallback). HK-2 (test-commit-gate spawn 조건부화) 와 명확히 분리되는 advisory hook cold-path skip 작업.

- [ ] `plugins/rein-core/hooks/hooks.json` PreToolUse(Bash) 블록의 `pre-tool-use-bash-rules.sh` 엔트리에 `if` 필드 추가
- [ ] **positive hot-path whitelist** — `if: "Bash(<long-running-pattern> *)"` 형식으로 hot path 만 enumerate. 후보: `pytest`, `npm test`, `yarn test`, `pnpm test`, `cargo build`, `docker build`, `playwright`, `make`, `tsc` 등 (background-jobs.md 본문의 "장기 실행 명령" 정의와 일치)
- [ ] **cold path (safe command — `ls`, `pwd`, `git status`, `grep` 등) 에서 `pre-tool-use-bash-rules.sh` 자동 skip** — 미분류는 cold path 로 떨어져 advisory rule 안 inject (사용자 체감 우선)
- [ ] `pre-tool-use-bash-bootstrap-gate.sh` + `pre-bash-safety-guard.sh` 는 미변경 — always-on 유지 (bootstrap check + 정책 차단은 cold/hot 무관 필수)
- [ ] hook 실행 시간 측정 (cold path Bash) — `~0.21s` 합 (3 hook) → **`~0.15s`** (`pre-tool-use-bash-rules.sh` skip 후 bootstrap-gate + safety-guard 만) 확인
- [ ] Claude Code v2.1.85+ 의 `if` 필드 + `Bash(<pattern>)` 패턴 동작 검증 — v1.3.2 의 HK-2 가 이미 13 entry 로 정상 동작 중 (회귀 위험 낮음)
- [ ] **Edit/Write hook 에는 `if` 필드 미적용** — Issue #46103 (Edit/Write 에서 if 필드 무시) 회피
- [ ] HK-2 의 if 필드 적용과 명확히 분리됨을 plan/spec 에 명시 — HK-2 = `pre-bash-test-commit-gate.sh` spawn 조건부화 (policy gate), PERF-3 = `pre-tool-use-bash-rules.sh` advisory inject skip

### 검증 (cycle 통합)

- [ ] codex review PASS (light tier — rule body 축소 + config tweak, 차단 로직 미변경)
- [ ] security review PASS (light tier — user-facing rule body 축소만, secret/auth/차단 무관)
- [ ] 회귀 테스트 통과 (`bash tests/scripts/run-all.sh`)
- [ ] CHANGELOG.md v1.3.3 entry 추가 (user-facing rule body 축소 + hook config tweak)
- [ ] README.md / README.ko.md 버전 히스토리 1~2줄 + CHANGELOG 링크 (`feedback_release_readme_version_entry.md`)
- [ ] dev commit + push
- [ ] main 선별 체크아웃 + tag v1.3.3 + push (`feedback_branch_strategy_order.md` — dev → main 단방향)

## 묶음 release (oneday tag — 사용자 결정)

오늘 (2026-05-20) 작업을 한번에 v1.3.3 patch tag 로 묶음:

| 작업 | user-facing? | 비고 |
|---|---|---|
| 오전: incident cleanup 3건 declined + 파일 삭제 | ❌ internal | trail/incidents 정리, hook 동작 변화 0 |
| Phase 4 Task 4.1 (short rule injection) | ✅ user-facing rule body 축소 | patch 정당화 source |
| Phase 4 Task 4.2 (if-field skip) | ✅ cold-path latency 감소 | patch 정당화 source |

→ versioning.md Rule A patch bump 정당화 (user-facing outcome 변화는 미미, 사용자 워크플로 변화 없음, body 축소 + hook config tweak).

## 비범위

- rule injection 완전 비활성화 (사고 환기 메커니즘 보존 — 2026-04-22 codex hang, 2026-04-29 trail anchoring 회고 근거)
- improve_plan 항목 1 (post-write-* hooks.json 등록) — HK-1 이미 implemented (v1.4.0 예정)
- improve_plan 항목 4 (security tier 분기) — RT-1 이미 implemented
- improve_plan 항목 5 (complexity hints) — RT-2 이미 implemented
- improve_plan 항목 6 (SubagentStop) — HK-3 이미 implemented (PostToolUse(Agent) 형태로)
- improve_plan 항목 7 (PreCompact/PostCompact) — 별 cycle 후보
- improve_plan 항목 8 (aggregate 단일 subprocess) — PERF-1 이미 implemented (v1.3.2 shipped)
- improve_plan 항목 9 (dispatcher 병렬화) — HK-4 deferred (SPIKE-1 go 판정 대기)
- improve_plan 항목 10 (type:agent Stop hook) — DEC-1 보류 결정 문서화 (experimental)
- improve_plan 항목 11/12 (parallelizable + isolation:worktree) — PLN-1, AG-2 (v1.6.0 예정)
- improve_plan 항목 13 (feature-builder 분화) — AG-1 이미 implemented
- improve_plan 항목 14 (자동 리뷰 루프 Ralph) — 별 cycle 후보
- improve_plan 항목 15 (Python subprocess 캐시) — PERF-2 deferred (SPIKE-1 go 판정 대기)
- improve_plan 항목 16 (DoD validator mtime 캐시) — 별 cycle 후보
- improve_plan 항목 17 (PostToolBatch aggregator) — HK-5 deferred (HK-4 land 후)
- rein-performance-plan Phase 5 (State Machine) — 별 cycle 후보
- rein-performance-plan Phase 6 (Release gate 분리) — 별 cycle 후보

## 위험

- **R1**: short summary 가 self-classify anchoring 효력 약화 → trail 단독 trust 같은 회귀 가능성. **사실 정정 (codex Mode B 2026-05-20)**: `session-start-rules.sh` 는 `code-style`/`security`/`testing`/`operating-sequence` **4개만** inject. `answer-only-mode` 와 `background-jobs` 는 **SessionStart 에 inject 되지 않고** 매 user turn (UserPromptSubmit) + 매 Bash 호출 (PreToolUse) 에서만 등장. 즉 본 cycle 의 short summary 전환은 두 rule 의 **유일한 in-session anchor 를 단축**하는 작업. **Mitigation**: (a) `session-start-rules.sh` 의 4-rule full inject 는 미변경 — operating-sequence + 규칙 본문은 세션 시작 시 1회 anchor 보존. (b) `answer-only-mode.md` / `background-jobs.md` 의 원본 rule 본문은 미변경 (user 가 explicit 하게 read 가능 + 추후 본문 복원 가능). (c) 적용 후 첫 몇 세션 관찰 — 단순 질문에 ceremony 재현 또는 codex 계열 호출에서 foreground 룰 위반 발견 시 short summary 본문 늘림 (또는 "변경 감지 시 재주입" 2차 개선으로 escalate — codex Mode B 권고: 1차안에서는 stale-pass 위험 회피).
- **R2**: short summary 의 정확한 문구가 사고 환기에 충분한지 검증 어려움. **Mitigation**: 새 plan Phase 2 의 권고 본문 시작점으로 사용, codex-review 단계에서 문구 적절성 검토.
- **R3**: `if` 필드 환경 변수 (`REIN_RULES_INJECTED` 등 candidate) 가 Claude Code 에서 실제로 평가되는지 미검증. **Mitigation**: Task 4.2 구현 전 사전 simple test (단순 if 분기로 hook 차단 동작 확인). 환경 변수 평가 안 되면 toolName/command pattern 기반 if 로 대체.
- **R4**: Bash hook if 필드 적용이 hot path (test/commit/destructive) 를 잘못 cold path 로 분류하면 차단 게이트 우회 가능성. **Mitigation**: hot path pattern 명시적 enumerate (`git commit`, `pytest`, `npm test`, `cargo build`, `rm -rf`, `git push --force`, etc.) — 미분류면 hot path 로 fallback.
- **R5**: Edit/Write hook 의 `if` 필드 미지원 (Issue #46103) — Task 4.2 적용 범위가 Bash 전용임을 plan/spec/CHANGELOG 에 명시.

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - rein:codex-review        # Step 5 필수 게이트
  - rein:writing-plans       # Phase 4 plan section + spec Scope ID 갱신
  - rein:changelog-writer    # v1.3.3 CHANGELOG entry 작성
mcps: []
security_tier: light          # 차단 로직 미변경, secret/auth 무관
complexity: low               # 신축 2 + 편집 3~4 파일, 기존 패턴 확장
model_hint: sonnet            # 아키텍처 결정 없음, Opus 불필요
effort_hint: medium           # rule 본문 단축 문구 + if 필드 평가 메커니즘 검증
rationale:
  - 작업 성격: rule body 단축 + hook config tweak. 신규 hook / 신규 agent / 사용자 명령 변경 없음 → feature-builder (base) 가 적합 (fix/refactor 아님)
  - 파일 패턴: plugins/rein-core/rules/short/*.md (신축 2), plugins/rein-core/hooks/user-prompt-submit-rules.sh + pre-tool-use-bash-rules.sh (편집), plugins/rein-core/hooks/hooks.json (if 필드 추가), docs/plans/2026-05-19-cc-feature-adoption.md (Phase 4 추가), docs/specs/2026-05-19-cc-feature-adoption.md (Scope ID 2개 추가), CHANGELOG.md, scripts/rein.sh VERSION
  - security_tier light 정당화: 차단 로직 (pre-bash-guard, pre-edit-dod-gate) 미변경, secret/auth 무관, hook config tweak 만
  - feature-builder 가 1차 구현 → codex-review 게이트 → security-review (light) → release (CHANGELOG/VERSION/main 머지/tag v1.3.3)
  - writing-plans: Scope ID 2개 신설 + Phase 4 섹션 신축으로 plan/spec 갱신 필요. coverage validator 통과 + spec-review stamp 자동 생성에 활용
  - changelog-writer: 오늘 묶음 release (incident cleanup + Phase 4) entry 작성에 활용 (선택 — manual 작성도 가능)
approved_by_user: true   # 2026-05-20 사용자 승인 — 원안대로 진행 (feature-builder + codex-review + writing-plans + changelog-writer + security_tier:light)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject)
- [x] cc-feature-adoption plan 의 14 Scope 와 중복 없음 확인 (UPS-1, PERF-3 신규 — 본 DoD 의 covers 매트릭스로 plan-coverage validator 통과 가능성 검증 필요)
- [x] dev 브랜치 확인 (origin/dev = f5d3fc4)
- [x] incident gate 해소됨 (--count-pending = 0, 3건 declined + 파일 삭제)
- [x] v1.3.2 shipped 검증 완료 (main HEAD `7795193`, tag annotated, origin/main 일치)
- [x] PERF-1 적용 확인 (`session-start-load-trail.sh:264~273` aggregate 단일 subprocess)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)
- [ ] plan 갱신 (Scope ID 2개 추가 + Phase 4 섹션) → plan-coverage validator 통과 후 본 DoD covers 매트릭스 활성화

## 다음 단계 (라우팅 승인 후)

1. **plan 갱신**: `docs/plans/2026-05-19-cc-feature-adoption.md`
   - Scope 매트릭스에 UPS-1, PERF-3 행 추가 (상태 planned)
   - Phase 4 섹션 신축 (Task 4.1, 4.2, covers 메타데이터)
   - 릴리즈 표에 v1.3.3 row 추가 (Phase 4 = patch)
2. **spec 갱신**: `docs/specs/2026-05-19-cc-feature-adoption.md`
   - Scope Items 에 UPS-1, PERF-3 정의 추가 (design intent + scope boundary)
3. **Task 4.1 구현**: short rule 2 파일 신축 + 2 hook 수정
4. **Task 4.2 구현**: `hooks.json` if 필드 + 환경 변수 평가 검증
5. **byte/wall-clock 측정** (before/after 비교 — 본 DoD 의 배경 표와 대조)
6. **codex-review** (light tier) + **security-review** (light tier — security_tier light 라 stamp 없이 commit 허용)
7. **CHANGELOG.md v1.3.3 entry** + **VERSION 1.3.2 → 1.3.3** + **README parity**
8. **dev commit + push**
9. **main 선별 체크아웃 + tag v1.3.3 + push** (`feedback_branch_strategy_order.md` — dev → main 단방향)
10. **trail/inbox + trail/index 갱신**

---
## dod-2026-05-20-cc-feature-phase-2b-dispatcher-split-and-cache.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — cc-feature-adoption Phase 2b (HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator)

- 작업 시작일: 2026-05-20
- 유형: refactor (internal — user-facing outcome 동일, hook 분할 / cache / aggregator 도입은 internal 구조 변경). no bump — VERSION 1.3.3 stay (사용자 결정 2026-05-20)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (본 cycle 안에 Phase 2b 섹션 + matrix 갱신 동반)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2b (Task 2b.1 / 2b.2 / 2b.3 — 본 cycle 에서 plan 에 신설)
covers: [HK-4-post-edit-dispatcher-dependency-free-subhooks-split-into-parallel-hook-entries-conditional-on-spike-1-confirming-exit2-deny-merge, PERF-2-pre-edit-dod-gate-and-dispatcher-share-python-resolver-result-via-tool-use-id-keyed-cache-conditional-on-spike-1-confirming-posttooluse-carries-it, HK-5-posttoolbatch-hook-aggregates-parallel-subhook-result-files-into-single-trail-entry-conditional-on-hk-4-parallelization-landing]

## 배경

SPIKE-1 (cc-feature-adoption Phase 2 / Task 2.1) macOS 측정 cycle 완료 (HK-4 GO + PERF-2 GO). 사용자 결정 (2026-05-20):

- Linux 재측정은 deferred validation 으로 처리 (main 머지 직전 hard gate) — codex-ask hedging 권고 채택
- Phase 2b 3 항목 (HK-4 + PERF-2 + HK-5) 을 한 cycle 에 land
- 본 cycle commit 후 dev push 만 (main 머지 별 cycle)

현재 `post-edit-dispatcher.sh` (159 line) 가 PostToolUse(Edit|Write|MultiEdit) 의 single entry 로 등록되어 8 sub-hook 을 순차 호출:

```
post-edit-hygiene.sh
post-edit-review-gate.sh
post-edit-index-sync-inbox.sh
post-edit-spec-review-gate.sh
post-edit-plan-coverage.sh
post-edit-dod-routing-check.sh
post-edit-design-plan-coverage-rule.sh
post-edit-routing-procedure-rule.sh
```

dispatcher 자체에 aggregator + cache + exit 2 OR-propagation 이 이미 구현되어 있음 — Phase 2b 의 목적은 이 internal 구조를 hooks.json 의 native 병렬 entry 평가로 옮겨 Claude Code 가 직접 평가 + propagation 처리하게 함.

## 완료 기준

### plan 갱신 (Task 2b.0)

- [ ] `docs/plans/2026-05-19-cc-feature-adoption.md` 의 coverage matrix 3 row 상태 전환:
  - HK-4: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.1)
  - PERF-2: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.2)
  - HK-5: `deferred` → `implemented` (위치/사유: Phase 2b / Task 2b.3)
- [ ] 새 Phase 2b 섹션 추가 (Phase 2 다음, Phase 3 앞):
  - Phase 2b heading + `covers: [HK-4, PERF-2, HK-5]`
  - Task 2b.1 (HK-4) heading + `covers: [HK-4]` + Files / Steps / Verify
  - Task 2b.2 (PERF-2) heading + `covers: [PERF-2]` + Files / Steps / Verify
  - Task 2b.3 (HK-5) heading + `covers: [HK-5]` + Files / Steps / Verify
- [ ] plan line 188 의 "Phase 2b (조건부, 본 plan 범위 밖)" 노트를 SPIKE-1 GO 판정 반영 형태로 갱신 — 또는 신설 Phase 2b 섹션으로 흡수
- [ ] plan coverage validator (`post-edit-plan-coverage.sh`) 자동 실행 통과 — `.coverage-mismatch` 마커 부재

### HK-4 — dispatcher 분할 (Task 2b.1)

- [ ] `plugins/rein-core/hooks/hooks.json` 의 PostToolUse(Edit|Write|MultiEdit) 블록을 single dispatcher entry 에서 **8 sub-hook 별개 entry** 로 확장 (각 entry 가 자체 matcher `Edit|Write|MultiEdit` + hooks[] = 1 sub-hook)
- [ ] `plugins/rein-core/hooks/post-edit-dispatcher.sh` 는 **유지** 결정 vs **제거** 결정:
  - **유지 후보**: cache populator 로 축소 (PERF-2 의 PostToolUse 측 cache 채움) + 다른 sub-hook 보다 먼저 fire 되어 cache 준비
  - **제거 후보**: PERF-2 cache 가 pre-edit-dod-gate 에서만 populate 되고 sub-hook 들은 read 만 하면 dispatcher 불필요
  - 결정은 PERF-2 구현 방향에 의존 — Task 2b.2 의 cache lifecycle 설계 안에서 확정
- [ ] 각 sub-hook (`post-edit-*.sh` 8개) 이 **dispatcher 부재 환경에서 자체 stdin 처리** 가능하도록 갱신:
  - 현재는 dispatcher 가 cache 를 env var 로 export 한 상태에서 sub-hook 이 실행됨 — 분할 후엔 각 sub-hook 이 stdin JSON 을 직접 파싱 또는 PERF-2 cache 를 read
- [ ] `tests/hooks/test-post-edit-dispatcher.sh` 갱신 — dispatcher 가 사라지거나 축소된 형태 검증으로 전환. 신규 또는 갱신: `tests/hooks/test-post-edit-parallel-entries.sh` (8 sub-hook 별개 entry 등록 + exit 2 OR-propagation)
- [ ] `tests/hooks/run-all.sh` 의 dispatcher 참조 갱신

### PERF-2 — Python resolver cache 공유 (Task 2b.2)

- [ ] `plugins/rein-core/hooks/pre-edit-dod-gate.sh` 의 Python resolver 결과 (file_path 추출 + DoD lookup 결과) 를 `${CACHE_DIR}/${tool_use_id}.json` 으로 dump
- [ ] cache 위치 정책 — `${CLAUDE_PROJECT_DIR}/.rein/cache/hook-resolver/` 안에 file 단위 (path traversal 차단 — tool_use_id 는 Anthropic Tool Use ID 형식 `toolu_<base64>` 만 통과시키는 sanitizer)
- [ ] cache lifecycle:
  - PreToolUse 단계에서 write
  - PostToolUse 단계에서 read
  - PostToolUse 처리 완료 후 cleanup (별 hook 또는 PostToolBatch aggregator 가 책임)
  - stale entry 방지를 위해 24h TTL 또는 session 단위 정리
- [ ] 분할된 sub-hook 들이 cache 를 read 해 cold-start (Python resolver 재호출) 회피
- [ ] cache miss fallback — sub-hook 이 자체 resolver 호출 가능 (graceful degradation)
- [ ] `tests/hooks/test-perf-2-resolver-cache.sh` 신축 — cache write/read/cleanup 검증 + cache miss fallback 검증

### HK-5 — PostToolBatch aggregator (Task 2b.3)

- [ ] 새 hook `plugins/rein-core/hooks/post-edit-aggregator.sh` 신축 — 분할된 sub-hook 들이 emit 한 결과 파일 (trail entry, additionalContext 등) 을 합쳐 단일 trail entry 로 출력
- [ ] hooks.json 에 aggregator 등록:
  - 첫 후보: PostToolBatch event (만약 Claude Code 가 제공) — 단정 불가, SPIKE-1 범위 밖
  - 두 번째 후보: PostToolUse(Edit|Write|MultiEdit) 의 **마지막 entry** 로 등록되어 다른 sub-hook 8개가 fire 한 뒤 마지막에 합쳐 단일 trail entry emit
- [ ] aggregator 의 결과 파일 위치 — `${CLAUDE_PROJECT_DIR}/.rein/cache/hook-output/<tool_use_id>/<sub-hook>.json` 형태로 sub-hook 들이 write
- [ ] PERF-2 cache cleanup 도 aggregator 가 동반 (cache + output 동일 lifecycle)
- [ ] `tests/hooks/test-post-edit-aggregator.sh` 신축 — sub-hook 8개의 output 을 단일 trail entry 로 집계하는지 검증

### 회귀 / verification

- [ ] `bash tests/hooks/run-all.sh` 전체 통과 — dispatcher 분할 후에도 기존 시나리오 회귀 없음
- [ ] post-edit-dispatcher 관련 기존 테스트 (`tests/hooks/test-post-edit-dispatcher.sh`) 가 새 구조에 맞게 갱신되어 모두 통과
- [ ] PreToolUse Edit/Write/MultiEdit 실제 trigger 후 (e.g. 본 cycle 의 trail/dod 파일 신축) trail entry 가 단일 entry 로 기록 (HK-5 aggregator 정상 동작) — manual smoke test
- [ ] dispatcher 단일 entry 대비 분할 후 8 sub-hook 모두 fire 되는지 (`echo "hooks.PostToolUse" + grep post-edit-*` 로 hooks.json 검증)

### 검증

- [ ] codex review PASS (initial round NEEDS-FIX 가능성 큼 — large diff, 다중 파일. multi-round 예상)
- [ ] security review PASS (`standard` tier — production hook 변경, cache 가 tool_use_id 입력 받아 path 구성 → sanitizer 필수)
- [ ] commit (no bump): `refactor(hooks): Phase 2b — HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator`
- [ ] dev push (main 머지 없음 — no bump 작업, main 머지는 별 cycle 의 PR checklist hard gate 통과 후)

### 비고: main 머지 hard gate (별 cycle)

본 cycle 의 commit 이 dev push 된 후 별 cycle 에서 main 머지를 준비할 때 codex-ask hedging 권고에 따라 다음을 hard gate 로 만족:

- (a) Ubuntu/Linux 환경에서 SPIKE-1 절차 1 cycle 재실행 (handover `2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md` 재사용), 또는
- (b) `tests.yml` (또는 별 workflow) 에 dispatcher split / cache / aggregator 의 OS-neutral unit/integration test 추가

본 DoD 의 acceptance 는 **dev push 까지** — main 머지 hard gate 는 본 cycle 범위 밖.

## 비범위

- Linux 환경 실측 (Phase 2b 본 cycle 의 acceptance 밖 — main 머지 hard gate 의 별 cycle)
- v1.4.0 minor bump 또는 v1.3.3 → v1.3.4 patch bump (사용자 결정 1.3.3 stay 유지)
- Phase 3 진입 (DEC-1 / PLN-1 / AG-2 — 별 cycle)
- PERF-3-VERIFY (need-to-confirm.md 등재 — 별 cycle)
- v1.3.3 main 머지 + tag push (별 cycle)
- spec 본문 갱신 — Scope ID 자체는 conditional 표현 포함이므로 SPIKE-1 GO 결과 반영에 spec 본문 편집 불필요

## 위험

- **R1**: dispatcher 분할 후 sub-hook 의 stdin 처리가 dispatcher 가 export 한 cache env var 부재로 break. **Mitigation**: sub-hook 들이 stdin JSON 직접 파싱 fallback 보유 (PERF-2 cache 가 missing 한 환경에서도 작동). 회귀 테스트가 fallback 경로 cover.
- **R2**: HK-4 분할로 8 sub-hook 이 별개 process spawn → Python resolver cold-start 8회 (현재 dispatcher 가 1회만 호출). PERF-2 cache 없이 분할만 land 하면 latency 가 오히려 증가. **Mitigation**: PERF-2 cache 가 본 cycle 에서 동반 — sub-hook 들이 pre-edit-dod-gate 의 cache 를 read 해 cold-start 회피.
- **R3**: cache file path 가 `${tool_use_id}.json` 형태인데 tool_use_id 가 사용자 입력에서 유래 → path traversal 가능성. **Mitigation**: PERF-2 의 cache write/read 에 tool_use_id sanitizer (정확한 형식 `^toolu_[A-Za-z0-9_-]+$` whitelist) 적용. codex review 의 Code Defects slot 이 검증.
- **R4**: HK-5 aggregator 가 PostToolUse 마지막 entry 로 등록되는 경우, Claude Code 가 entry 순서를 보장하는지 미확인 (SPIKE-1 caveat 4 — entry 순서 민감도 미측정). **Mitigation**: aggregator 가 sub-hook 결과 파일 부재 시 graceful skip — sub-hook 들이 cache write 완료 안 한 상태에서도 aggregator 가 exception 던지지 않음.
- **R5**: 8 sub-hook 별개 entry 등록으로 hooks.json 이 길어짐 (현재 +~80 line 예상) → hooks.json 가독성 저하. **Mitigation**: docs/agents-md-examples.md 또는 plugins/rein-core/README 에 dispatcher 분할 의도 + entry 순서 의미 한 단락 명시. 또는 hooks.json 안에 comment block 추가 (JSON 미지원 — `"_comment"` field 로 대체).
- **R6**: codex review round 가 많아질 가능성 (large diff). **Mitigation**: implement 단계에서 작게 commit 단위로 staged review — 4 sub-step (plan / HK-4 / PERF-2 / HK-5) 마다 self-review 보존하면서 진행, 최종 codex-review 한번에 묶음.

## 라우팅 추천

```yaml
agent: rein:feature-builder-refactor
skills:
  - rein:plan-writer          # Task 2b.0 plan 갱신 (matrix + Phase 2b 섹션 + Task work units)
  - rein:codex-review          # Step 5 필수 게이트 — large refactor 다중 파일
mcps: []
security_tier: standard       # production hook 변경 + cache 도입 (tool_use_id 입력 받음 → sanitizer 필수). light 부적절
complexity: high              # 8 sub-hook 분할 + cache 신축 + aggregator 신축 + plan 갱신 + 다중 테스트
model_hint: sonnet            # 복잡한 refactor — opus 도 가능하지만 sonnet 으로 시작
effort_hint: large            # 4 task (plan / HK-4 / PERF-2 / HK-5) × 다중 파일
rationale:
  - 작업 성격: large refactor — 기존 dispatcher 내부 구조를 hooks.json native 평가로 옮김 + cache 신축 + aggregator 신축. feature-builder-refactor 가 정확 (researcher-first 전략 — 기존 dispatcher / pre-edit-dod-gate / sub-hook 구조 파악 우선)
  - 파일 패턴: plugins/rein-core/hooks/hooks.json + post-edit-dispatcher.sh (제거 또는 축소) + post-edit-*.sh 8개 + pre-edit-dod-gate.sh + post-edit-aggregator.sh (신축) + lib/* 갱신 가능성 + tests/hooks/test-*.sh 다중 신축/갱신 + plan 갱신 (markdown)
  - security_tier standard 정당화: cache file path 가 tool_use_id 받음 → path traversal 위험. production 차단 로직 (post-edit-spec-review-gate, post-edit-plan-coverage 등) 의 평가 흐름이 dispatcher → native entry 로 변경 → 회귀 가능성. light 면 stamp 면제로 가다 회귀 놓칠 위험
  - plan-writer 동반: plan 의 coverage matrix 갱신 + Phase 2b 섹션 신설을 plan-writer 가 처리. plan-writer 가 자동으로 plan codex-review 호출
  - codex-review: 본 작업은 large diff 라 codex Round 다중 가능성 — initial NEEDS-FIX → fix → resume --last 패턴
  - changelog-writer 미포함 이유: internal refactor (versioning.md Rule C) — user-facing outcome 동일이라 CHANGELOG.md 신규 entry 불필요. internal log 가 필요하면 CHANGELOG-internal.md 별 cycle
approved_by_user: true   # 2026-05-20 사용자 승인 (원안: rein:feature-builder-refactor + plan-writer + codex-review + standard tier)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject — SPIKE-1 + Linux 재측정 prep cycle 완료 반영)
- [x] SPIKE-1 GO 판정 확인 (HK-4 GO + PERF-2 GO + 양방향 hot-reload 부재 evidence)
- [x] 사용자 결정 (2026-05-20) 기록: hedging 채택 + Phase 2b 한 cycle land + VERSION 1.3.3 stay
- [x] dispatcher 현재 구조 분석 (159 line, 8 sub-hook 순차 호출 + aggregator + cache + exit 2 OR-propagation 이미 구현)
- [x] sub-hook 8개 본문 확인 — 모두 dispatcher 의 cache env var 의존
- [x] plan 의 HK-4/PERF-2/HK-5 coverage matrix 위치 확인 (line 44-46)
- [x] active DoD 갱신 — 본 DoD 가 새 active (이전 dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md 는 cycle 완료)
- [x] spec-review pending 2건 (cc-feature-adoption.md spec + plan) 은 paired .reviewed 도 존재 — gate 통과
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. plan 갱신 (Task 2b.0) — `rein:plan-writer` skill 또는 직접 편집 + validator. matrix 3 row + Phase 2b 섹션 신설
2. HK-4 구현 (Task 2b.1) — dispatcher 분할 결정 (제거 vs 축소) + hooks.json 8 entry 확장 + sub-hook 8개의 stdin fallback 보강
3. PERF-2 구현 (Task 2b.2) — pre-edit-dod-gate cache dump + cache lifecycle (PreToolUse write / PostToolUse read / aggregator cleanup) + tool_use_id sanitizer
4. HK-5 구현 (Task 2b.3) — post-edit-aggregator.sh 신축 + hooks.json 마지막 entry 등록 + cache + output cleanup
5. 회귀 테스트 — `bash tests/hooks/run-all.sh` 전수 통과 + 신규 test 4종 (test-post-edit-parallel-entries / test-perf-2-resolver-cache / test-post-edit-aggregator / test-post-edit-dispatcher 갱신) 통과
6. codex-review (standard tier, multi-round 예상) — wrapper + resume --last 패턴
7. security-review (`standard` tier) — cache path sanitizer + production hook 평가 흐름 회귀
8. fix → final codex review PASS → `.codex-reviewed` + `.security-reviewed` stamp
9. commit (no bump): `refactor(hooks): Phase 2b — HK-4 dispatcher 분할 + PERF-2 cache + HK-5 aggregator`
10. dev push (main 머지 없음 — main 머지는 별 cycle 의 hard gate)
11. trail/inbox 작성 + trail/index 갱신 (진입점을 "v1.3.3 main 머지 hard gate 진행" 또는 "PERF-3-VERIFY 별 cycle" 로 갱신)

---
## dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — SPIKE-1 Linux 재측정 prep (Phase 2b 진입 first step)

- 작업 시작일: 2026-05-20
- 유형: research / handover (no bump — production 코드 변경 없음)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1 — second-pass 측정 prep)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2 (Task 2.1 follow-up — Linux 환경 second-pass 측정)
covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

본 cycle 은 SPIKE-1 의 측정 환경 caveat ("macOS Darwin 25.4 단일 OS") 해소를 위한 handover 작성 cycle. SPIKE-1 의 go 판정 (HK-4 GO + PERF-2 GO) 은 유지되며, Linux 결과로 보강.

## 배경

SPIKE-1 측정 (2026-05-20) 은 macOS Darwin 25.4 단일 환경에서 진행. report `docs/reports/2026-05-19-cc-feature-spike.md` §5 환경 caveat 의 두 항목:

- 단일 OS (macOS) — Linux 에서 hook entry merge semantics + `tool_use_id` 매칭이 동일한지 미검증
- 단일 Claude Code release — 미래 release 가 평가 모델을 바꿀 가능성 (별 cycle)

사용자 결정 (2026-05-20): Phase 2b 구현 (HK-4 + PERF-2 + HK-5 한 cycle) 진입 **이전** 에 Linux 환경에서 1 cycle 재측정 진행. 사용자가 Docker / native Linux 머신 (실물 또는 VM) 환경 보유.

본 session 은 macOS 이므로 직접 측정 불가 → 사용자가 Linux 환경의 별 Claude Code session 에서 따라할 step-by-step handover 문서를 본 cycle 에 작성. 측정 자체 + 결과 분석은 별 cycle.

## 완료 기준

### handover 문서 작성

- [ ] `trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md` 신축
  - Linux 환경 setup 절차 (Docker / native Linux + Claude Code 설치 / plugin install + 본 repo clone)
  - hooks.json 임시 등록 (spike entry 4개) — macOS cycle 의 등록 diff 를 그대로 재사용
  - 새 Claude Code session 의 첫 Write 로 trigger 발사 (`tests/fixtures/spike/spike-trigger-linux.txt` 신축 또는 macOS 와 동일 trigger 파일 재사용)
  - 3 trigger 후 fixture 분석 (jsonl 12 record = 4 entry × 3 trigger). 추가 4번째 trigger 는 hot-reload 부재 양방향 가설 cross-OS 보강용 **선택** — handover §6.1 의 main path 는 3 trigger
  - hooks.json revert → `git diff --stat plugins/rein-core/hooks/hooks.json` empty 확인
  - 결과 jsonl 일부를 본 repo 의 `docs/reports/2026-05-19-cc-feature-spike.md` 에 §10 (Linux second-pass) 으로 append
  - HK-4 / PERF-2 가 Linux 에서도 동일 판정인지 확인

### handover 의 success criteria 명시

- [ ] HK-4 검증: Linux 의 fixture 에서 `parallel-exit-allow.jsonl` 과 `parallel-exit-deny.jsonl` 모두 3+ record + deny entry 의 `exit 2` 가 system-reminder 로 surface
- [ ] PERF-2 검증: Linux 의 `tool-use-id-pre.jsonl` 과 `tool-use-id-post.jsonl` 의 `tool_use_id` 가 trigger 마다 1:1 매칭
- [ ] OS portability 확인: probe 의 `set -u` + `mktemp` + Python heredoc 이 Linux bash + python3 에서 정상 (별 변경 없이)
- [ ] Linux session 에서도 hooks.json hot-reload 부재가 재현되는지 부산 관찰 (양방향 가설 cross-OS 보강)

### 환경 caveat 처리

- [ ] handover 가 Docker 와 native Linux 모두 cover (Docker 의 경우 Claude Code interactive CLI 의 PTY 요구사항 명시)
- [ ] 측정 후 fixture 가 `tests/fixtures/spike/` 아래에 누적 — gitignore 가 모두 잡으므로 commit 영향 없음 (본 cycle 의 SPIKE-1 commit 에서 `*` + `!.gitignore` 로 변경됨)
- [ ] 결과 report append 시 macOS 결과는 보존 — Linux 결과는 §10 으로 추가 (덮어쓰기 금지)

### 검증

- [ ] codex review PASS (light tier — handover 문서 1개, production 코드 미변경)
- [ ] security review PASS (light tier — handover 가 외부 secret/credential 노출 없음, Docker setup 명령에 hardcoded credential 없음)
- [ ] commit (no bump): `chore(spike): SPIKE-1 Linux 재측정 prep handover`
- [ ] dev push (main 머지 없음 — no bump 작업)

## 비범위

- Linux 환경의 실제 측정 (별 cycle — 사용자가 Linux session 에서 실행)
- 측정 결과 분석 / report §10 작성 (별 cycle — 사용자 measurement 후 본 repo 에 commit 되면 분석 cycle 진입)
- Phase 2b 구현 자체 (HK-4 dispatcher 분할 / PERF-2 cache / HK-5 aggregator — 재측정 완료 후 별 cycle)
- Claude Code release 변동성 — 별 cycle (현 release 의 평가 모델만 측정)
- PERF-3-VERIFY (need-to-confirm.md 등재 — 별 cycle)

## 위험

- **R1**: handover 절차가 사용자 Linux 환경에서 작동 안 함 (Docker PTY / Claude Code install 차이 / plugin marketplace fetch 실패). **Mitigation**: handover 에 troubleshooting 섹션 추가 — Claude Code install 문서 링크 + plugin install dry-run 단계 + 가장 흔한 실패 (PATH / Node version / Plugin marketplace registration) 의 진단 명령.
- **R2**: Linux 에서 결과가 macOS 와 다르면 (예: deny 가 propagate 안 됨, tool_use_id 부재) Phase 2b 의 go 판정이 무효화될 수 있음. **Mitigation**: handover 의 분석 단계에 "Linux 결과가 macOS 와 다르면 SPIKE-1 의 GO 를 PARTIAL-GO 로 hedging" 명시. Phase 2b 진입은 사용자 재결정.
- **R3**: 사용자가 Linux session 에서 측정 후 결과 jsonl 을 commit 안 하고 본 repo 와 sync 되지 않으면 분석 cycle 불가. **Mitigation**: handover 의 마지막 단계에 "결과 jsonl 발췌 + report §10 append 후 commit + push" 단계 명시.

## 라우팅 추천

```yaml
agent: rein:researcher
skills:
  - rein:codex-review        # Step 5 필수 게이트 (handover 본문 + procedure 정확성)
mcps: []
security_tier: light          # production 차단 로직 미변경, secret/auth 무관, handover 문서만 신축
complexity: low               # 1 handover 파일 + 1 DoD
model_hint: sonnet            # 절차 작성, 아키텍처 결정 없음
effort_hint: small            # handover 본문 작성 — 측정 자체는 별 cycle
rationale:
  - 작업 성격: handover prep (production 미변경, 절차 + setup 문서). researcher 가 적합 — 외부 환경 (Linux/Docker) 의 Claude Code 설치/실행 절차 조사 일부 포함 가능
  - 파일 패턴: trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md (신축 1), trail/dod/dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md (신축 1, 본 파일)
  - security_tier light 정당화: handover 가 외부 명령 (docker run / curl / npm install) 을 portray 하지만 credential/secret hardcode 없음. pre-bash-guard 차단 로직 미변경
  - codex-review 단일 스킬: handover 본문의 step 정확성 + Linux 환경 portability claim 의 evidence 검증
  - writing-plans 미포함 이유: 본 작업은 plan 갱신이 아니라 plan Phase 2 의 sub-step prep. Phase 2b 구현 진입 직전 plan-writer cycle 별도 사용
  - changelog-writer 미포함 이유: no bump 작업 — CHANGELOG 변경 없음
approved_by_user: true   # 2026-05-20 사용자 승인 — 사용자 결정 (전체 Phase 2b 한 cycle + 재측정 먼저 + Docker/Linux 머신) 의 first step
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject — SPIKE-1 commit 후 갱신된 상태)
- [x] SPIKE-1 cycle commit (`f8e2b79`) dev push 완료 — handover 본 cycle 에서 신축 가능
- [x] 사용자 결정 (2026-05-20) 기록: Phase 2b 한 cycle + 재측정 먼저 + Docker/Linux
- [x] active DoD 갱신 필요 — 본 DoD 가 새 active
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. handover 본문 작성 (`trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md`)
2. codex-review (light tier) — handover 본문 정확성 검증
3. security-review (light tier — advisory)
4. commit (no bump) + dev push
5. trail/inbox 본 cycle 완료 기록 + index.md 의 "다음 진입점" 을 "사용자 Linux 환경에서 handover 실행 대기" 로 갱신

---
## dod-2026-05-20-cc-feature-spike-1-parallel-hook-tool-use-id.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — cc-feature-adoption Phase 2: SPIKE-1 (병렬 hook exit/deny 병합 + PostToolUse tool_use_id 측정)

- 작업 시작일: 2026-05-20
- 유형: research (no bump — production 코드 변경 없음, 측정 spike + report)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2 (Task 2.1)
covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

## 배경

cc-feature-adoption plan 의 HK-4 (post-edit-dispatcher 를 의존성 없는 sub-hook 으로 분할해 병렬 hook entry 로 등록) 와 PERF-2 (pre-edit-dod-gate + dispatcher 가 PostToolUse 의 `tool_use_id` 키로 Python resolver 결과를 공유) 는 둘 다 Claude Code 의 **미문서 동작** 에 의존한다:

1. **HK-4 전제**: 동일 matcher 의 hook entry 가 여러 개일 때, **하나가 `exit 2` 또는 `permissionDecision: "deny"` 를 반환하면 전체 도구 호출이 차단**되는가? (= OR-propagation 등가) 아니면 다른 entry 의 결과가 마지막 entry 의 결정으로 덮어쓰여지는가?
2. **PERF-2 전제**: PostToolUse 입력 JSON 에 `tool_use_id` 필드가 실제로 제공되는가? PreToolUse 와 PostToolUse 가 동일한 `tool_use_id` 를 공유해 둘 사이 cache key 로 쓸 수 있는가?

두 전제가 실측으로 확인되어야 Phase 2b (HK-4·PERF-2·HK-5 implemented 전환) 진입 가능. 본 SPIKE-1 은 production 코드 변경 없이 임시 probe hook 로 두 가설을 검증한다.

## 완료 기준

### 측정 hook 작성 (production 격리)

- [ ] `tests/hooks/spike-parallel-exit-probe.sh` — 동일 matcher 의 2 entry 중 하나가 exit 2 + deny JSON 을 반환하고 다른 entry 는 exit 0 + allow JSON 을 반환하도록 작성. 각 entry 가 stdin (input JSON) 의 hash + 자신의 exit code/decision 을 `tests/fixtures/spike/parallel-exit-<entry>.jsonl` 에 append 하도록 → 사후에 어느 결정이 propagation 됐는지 분석 가능
- [ ] `tests/hooks/spike-tool-use-id-probe.sh` — PostToolUse(Edit|Write|MultiEdit) 와 PreToolUse(Edit|Write|MultiEdit) 양쪽에서 호출됐을 때 stdin JSON 의 keys + `tool_use_id` (혹은 등가) 값 + tool name + timestamp 를 `tests/fixtures/spike/tool-use-id-<phase>.jsonl` 에 dump
- [ ] 두 probe 모두 PROJECT_DIR 밖 stdin·환경 변수에 의존하지 않고 항상 exit 0 로 종료해 측정 자체가 사용자 작업을 차단하지 않게 fail-soft (parallel-exit probe 의 "exit 2 의도 entry" 만 exit 2)
- [ ] probe 가 외부 secret 노출·임의 파일 쓰기·privileged path 접근 없는지 코드리뷰 (security_tier:light 정당화)

### hooks.json 임시 등록

- [ ] `plugins/rein-core/hooks/hooks.json` 의 PostToolUse(Edit|Write|MultiEdit) 블록에 `spike-tool-use-id-probe.sh` entry 1개 임시 추가 — 기존 `post-edit-dispatcher.sh` 와 **동일 entry 의 hooks[]** 가 아니라 **별개 entry** 로 등록해 parallel entry 동작 동시 관측
- [ ] PreToolUse(Edit|Write|MultiEdit) 블록에도 `spike-tool-use-id-probe.sh` entry 1개 임시 추가 — pre/post 양쪽 dump 비교 위함
- [ ] PostToolUse(Edit|Write|MultiEdit) 블록에 `spike-parallel-exit-probe.sh` entry 2개 (`PROBE_ROLE=allow`, `PROBE_ROLE=deny` 환경 변수 또는 wrapper 분할) — exit2/deny propagation 관찰
- [ ] 임시 entry 는 **PostToolUse 만 사용** (PreToolUse 의 parallel-exit 추가는 사용자 차단 위험 — 본 spike 는 PostToolUse 만)

### 측정 실행 (3회 trigger)

- [ ] 단순 Edit/Write 1회 (예: `need-to-confirm.md` 1줄 추가) → probe 3종 모두 record
- [ ] 추가 Edit 2회 더 반복 → 결과 일관성 확인 (random 변동 없는지)
- [ ] 결과 jsonl 3 종 (parallel-exit-allow, parallel-exit-deny, tool-use-id-pre/post) 누적 후 정리

### Report 작성

- [ ] `docs/reports/2026-05-19-cc-feature-spike.md` 신축
  - 측정 설계 + probe 코드 인용
  - 측정 결과 raw dump 요약 (jsonl excerpt)
  - **HK-4 go/no-go 판정**: 병렬 exit2 결과가 도구 호출 전체에 propagation 되면 go (OR-propagation 등가, dispatcher 분할 안전), 마지막 entry 결정만 반영되면 no-go (Phase 2b deferred 유지)
  - **PERF-2 go/no-go 판정**: PostToolUse 가 `tool_use_id` (또는 등가 unique id) 를 제공 + PreToolUse 와 매칭 가능하면 go (subprocess cache 가능), 부재 또는 mismatch 면 no-go
  - 한계: 본 측정은 macOS Darwin 25.4 / Claude Code 현 release 1개 환경 — Phase 2b 진입 전 Linux/CI 환경에서도 재측정 권장

### hooks.json 원상복구

- [ ] 측정 완료 후 probe 3종 entry 를 `plugins/rein-core/hooks/hooks.json` 에서 제거 — `git diff hooks.json` 가 비어 있어야 함 (production 오염 방지)
- [ ] `tests/hooks/spike-*.sh` 는 **남긴다** — Phase 2b 진입 / 회귀 재현용
- [ ] `tests/fixtures/spike/*.jsonl` 은 **gitignore** — 환경별 raw dump 이므로 repo 추적 부적합 (별도 `tests/fixtures/spike/.gitignore` 또는 root `.gitignore` 추가)

### 검증

- [ ] codex review PASS (light tier — production 코드 미변경, probe + report 만)
- [ ] security review PASS (light tier — probe 의 secret/path-traversal 없음)
- [ ] 회귀 테스트 (`bash tests/scripts/run-all.sh`) 통과
- [ ] commit (no bump): `chore(spike): Task 2.1 — 병렬 hook exit/deny + tool_use_id 측정 (SPIKE-1)`
- [ ] dev push (main 머지 없음 — no bump 작업)

## 비범위

- HK-4 dispatcher 실제 분할 (Phase 2b 작업)
- PERF-2 resolver cache 구현 (Phase 2b 작업)
- HK-5 PostToolBatch aggregator (HK-4 land 후)
- v1.3.3 main 머지 + tag (별 cycle — 사용자 결정 대기)
- 다른 Phase (3·4) 작업

## 위험

- **R1**: probe 의 `spike-parallel-exit-probe.sh` 가 deny 를 실제로 발사해 도구 호출이 차단됨 → 사용자 작업 차단. **Mitigation**: PostToolUse 만 등록 (PostToolUse 차단은 도구 실행 이후 단계라 즉시 작업 진행에 영향 작음). 본 DoD 의 측정 단계는 **probe 등록 직후 1개 Edit 으로 trigger 한 뒤 hooks.json 즉시 원상복구** 까지를 한 cycle 로 묶어 진행 — 측정 fixture 가 누적되면 hooks.json 을 다시 revert 한 채로 분석.
- **R2**: probe stdin 입력 JSON schema 가 Claude Code 버전에 따라 다를 수 있음 → tool_use_id 필드 이름 mismatch. **Mitigation**: probe 가 stdin 전체 JSON keys 와 raw payload 를 dump 하므로 사후에 다른 필드명도 식별 가능 (예: `toolUseId`, `id`, `event_id`).
- **R3**: parallel-exit probe 가 deny 를 발사할 때, **post-edit-dispatcher.sh 가 이미 실행 완료된 후** propagation 이 발생하면 OR-propagation 검증 의미가 약함 (dispatcher 가 이미 작업 완료). **Mitigation**: probe 가 PostToolUse 의 첫 entry 가 아니라 별개 entry 로 매칭되므로 entry 순서가 아닌 entry 간 병합 의미를 측정. report 에 entry 순서 의존성 caveat 명시.
- **R4**: tool_use_id 가 PostToolUse 에 제공되더라도 PreToolUse 와 동일하지 않을 수 있음 (각 단계가 별 id) → PERF-2 cache key 전제 위배. **Mitigation**: tool-use-id probe 가 pre/post 양쪽에서 id 를 dump 해 매칭 확인.

## 라우팅 추천

```yaml
agent: rein:researcher
skills:
  - rein:codex-review        # Step 5 필수 게이트 (probe 코드 + report)
mcps: []
security_tier: light          # production 차단 로직 미변경, secret/auth 무관, probe 는 stdin JSON dump 전용
complexity: low               # probe 2 파일 + report 1 파일 + hooks.json temp toggle
model_hint: sonnet            # 측정·검증 작업, 아키텍처 결정 없음
effort_hint: small            # 측정·dump·분석 — 실측 시간이 대부분
rationale:
  - 작업 성격: spike (production 미변경, 측정 + report). feature-builder 가 아닌 researcher 가 적합 — Claude Code 미문서 동작에 대한 실증·조사
  - 파일 패턴: tests/hooks/spike-*.sh (신축 2), docs/reports/2026-05-19-cc-feature-spike.md (신축 1), plugins/rein-core/hooks/hooks.json (임시 toggle — commit 시 원상복구), tests/fixtures/spike/.gitignore (신축)
  - security_tier light 정당화: probe 가 stdin JSON 만 dump (write to tests/fixtures/spike/, 외부 네트워크·secret 접근 없음). pre-bash-guard, pre-edit-dod-gate 차단 로직 미변경
  - codex-review 단일 스킬: spike report 의 go/no-go 판정 근거가 측정 결과와 일치하는지 검증 + probe 코드의 fail-soft 패턴 확인
  - writing-plans 미포함 이유: 본 작업은 plan 갱신이 아니라 plan 의 Task 2.1 실행. Phase 2b 진입 시 (go 판정 후) 별도 cycle 에서 writing-plans 사용
  - changelog-writer 미포함 이유: no bump 작업 — CHANGELOG 변경 없음
approved_by_user: true   # 2026-05-20 사용자 승인 — 원안 (rein:researcher + codex-review + security_tier:light)
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject)
- [x] cc-feature-adoption plan Phase 2 / Task 2.1 본문 확인
- [x] dev 브랜치 확인 (HEAD = ab41077, origin/dev sync)
- [x] main HEAD = 7795193 (v1.3.2), v1.3.3 tag 아직 부재 — 본 작업은 main 영향 0
- [x] hooks.json PostToolUse 블록 구조 확인 (Edit|Write|MultiEdit entry 1개 + Agent entry 1개)
- [x] spec-review pending 2건 (e740bea / fac428f9) 은 paired .reviewed 도 존재 — gate 통과 (SR-1 staleness 는 별 cycle)
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. probe 2종 작성 (`tests/hooks/spike-*.sh`) — fail-soft + jsonl dump
2. `tests/fixtures/spike/.gitignore` 신축 (`*` ignore)
3. `hooks.json` 에 probe 3 entry 임시 등록 (PostToolUse Edit|Write|MultiEdit 블록)
4. Edit trigger 3회 (예: `need-to-confirm.md` 줄 추가 → revert)
5. jsonl raw dump 분석 → HK-4 / PERF-2 go-no-go 판단
6. `docs/reports/2026-05-19-cc-feature-spike.md` 신축 (측정 설계 + 결과 + 판정)
7. `hooks.json` 원상복구 (probe entry 제거) — `git diff hooks.json` empty 확인
8. codex-review (light tier) → security-review (light tier — stamp 없이 commit 허용)
9. commit (no bump) + dev push
10. trail/inbox + trail/index 갱신 (index 의 "다음 진입점" 을 SPIKE-1 결과에 따라 갱신 — go 면 Phase 2b 진입, no-go 면 Phase 3 진입)

---
## dod-2026-05-20-ups-1-action-mandate-regression.md (mtime: 2026-05-20, archived: 2026-05-21)
# DoD — UPS-1 회귀 fix (행동 강령 body marker 복원)

- 날짜: 2026-05-20
- 유형: fix (회귀)
- slug: ups-1-action-mandate-regression
- plan ref: (none — 단발성 회귀 fix, plan 불요)

## 배경

Phase 2c push 완료 후 (`origin/dev = d5d29d5`) 별 cycle 후보로 trail/index.md 가 명시한 UPS-1 잔존 회귀. v1.3.3 prep Phase 4 시점 short summary 도입 시 `## 행동 강령` 헤더 이전이 누락돼 3개 hook 테스트가 fail.

## 증상

```
$ bash tests/hooks/test-user-prompt-submit-rules.sh
FAIL: additionalContext missing '행동 강령' header

$ bash tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh
FAIL(A): missing answer-only-mode body marker '행동 강령'

$ bash tests/hooks/test-pre-tool-use-bash-rules.sh
AssertionError: missing 행동 강령
```

## 원인

`plugins/rein-core/rules/short/answer-only-summary.md` 와 `plugins/rein-core/rules/short/background-jobs-summary.md` 는 turn-brief 용 짧은 요약본인데, 본문이 `# Title` 다음 곧바로 평문 단락으로 시작. `## 행동 강령` 헤더가 없어 UserPromptSubmit / PreToolUse hook 이 emit 하는 additionalContext 에도 `행동 강령` 문자열이 포함되지 않음.

풀버전 (`plugins/rein-core/rules/answer-only-mode.md`, `rules/background-jobs.md`) 은 첫 `## ` 헤더가 `## 행동 강령` 으로 정상.

## 변경 범위

| 파일 | 변경 |
|---|---|
| `plugins/rein-core/rules/short/answer-only-summary.md` | `# Title` 다음 줄에 `## 행동 강령` 헤더 + 본문 1줄 삽입 |
| `plugins/rein-core/rules/short/background-jobs-summary.md` | 동일 패턴 |

## 검증 기준 (Definition of Done)

- [ ] `bash tests/hooks/test-user-prompt-submit-rules.sh` PASS
- [ ] `bash tests/hooks/test-user-prompt-submit-bootstrap-advisory.sh` PASS (A/B/C 3 path 모두)
- [ ] `bash tests/hooks/test-pre-tool-use-bash-rules.sh` PASS (a/b/c 3 path 모두)
- [ ] `bash tests/rein-test.sh` 전체 회귀 없음 (Phase 2c claim 33/33 유지)
- [ ] `bash tests/hooks/test-action-mandate-existing-rules.sh` PASS — 첫 `## ` 헤더가 `## 행동 강령` 인지 + 본문 size ≤ 2048B 검증 (short md 도 검증 대상에 들어가는지 사전 확인 필요)

## 비범위

- 풀버전 rules/*.md 편집
- hook 본체 (`user-prompt-submit-rules.sh`, `pre-tool-use-bash-rules.sh`) 편집
- 별 cycle 후보 (b/c/d) 진행

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
security_tier: light
rationale: |
  - agent: 회귀 fix (DoD 키워드 "회귀"/"fix"), reproduction-first 전략 적합.
    이미 failing test 3개로 회귀 증상이 코드로 고정됨 (test-user-prompt-submit-rules /
    -bootstrap-advisory / test-pre-tool-use-bash-rules).
  - skills/codex-review: plugin source SSOT (rules/short/*.md) 편집은 사용자 ship 대상이므로 외부 모델 second opinion 필수.
  - mcps: 없음 — markdown 본문 2 줄 변경, 외부 시스템 조회 / 라이브러리 조사 불필요.
  - security_tier: light — markdown 평문 텍스트만, secret / 외부 input boundary / command exec 없음. AGENTS.md §6 light-tier 기준 부합.
approved_by_user: true
```

## 라우팅 승인 사유 (사용자 결재)

Auto Mode 활성 + 사용자 직접 명령 "갱신하고 (a) 진행해" 로 reasonable call 진행. 변경 범위가 markdown 2 파일·평문 텍스트·기존 failing test 로 회귀 영역 고정 → reasonable default 로 fix 전략 명확.

---
## dod-2026-05-21-cycle-x4-c-3-hook-fast-path-skip.md (mtime: 2026-05-21, archived: 2026-05-22)
# DoD — Cycle X4.C.3 (4 policy hook 에 effective_mode fast-path skip 추가)

- 날짜: 2026-05-21
- 유형: feat (4 hook 에 read_effective_mode 분기 + skip + adversarial test)
- design ref: docs/specs/2026-05-21-area-c-state-machine.md §8.4 (X4.C.0 PASS)
- plan ref: docs/plans/2026-05-20-integrated-roadmap.md §4.3 (영역 C)
- cycle: X4.C.3 — design memo §8.4 산출물

## 범위 (Scope)

포함:

1. `plugins/rein-core/hooks/pre-edit-dod-gate.sh` 변경:
   - DoD validator subprocess 호출 (L516~) 직전, state-machine.sh source 시도
   - `read_effective_mode` 결과가 `source_edit` AND 같은 file 이 dirty_files 에 이미 있는 경우, validator subprocess skip + 직전 marker 상태 (DOD_MISMATCH_MARKER / DOD_ADVISORY_MARKER) 그대로 사용
   - state-machine.sh 부재 / lock 실패 시 legacy path (validator 호출 — 외부 동작 회귀 0)
   - 다른 모든 gate (incident / spec-review / routing) 는 skip 대상 외 — 보수적

2. `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh` 변경:
   - INPUT 파싱 직후, `read_effective_mode == answer` 이면 envelope inject skip + exit 0
   - mode==answer 인데 PostToolUse(Edit) 가 fire 됨 = 이상 신호 (Stop 직후 다시 Edit) — body inject 불필요
   - state-machine.sh 부재 → legacy path (정상 inject)

3. `plugins/rein-core/hooks/post-edit-routing-procedure-rule.sh` 변경:
   - 위와 동일 패턴 (mode==answer → skip)

4. `plugins/rein-core/hooks/post-edit-spec-review-gate.sh` 변경:
   - 마커 생성 loop 안에서, 이미 같은 path 의 `.pending` marker 가 존재하고 effective_mode == source_edit 이면 mtime touch 만 (재기록 skip — 동일 burst 내 중복 생성 방지)
   - 이 경우 NOTICE 메시지는 그대로 (사용자가 review 필요성을 잊지 않도록)

5. `tests/hooks/test-state-fast-path-skip.sh` (신규, 4 adversarial test — design memo §8.4 검증):
   - (a) pre-edit-dod-gate: state.json mode=source_edit + dirty_files=[src/foo.ts] → 같은 file Edit 두 번째 호출 시 validator subprocess 호출 횟수 1회 (두 번째 skip)
   - (b) post-edit-design-plan-coverage-rule: state.json mode=answer + journal 비어 있음 → envelope 미발행
   - (c) post-edit-routing-procedure-rule: 동일 패턴 (mode=answer → 미발행)
   - (d) post-edit-spec-review-gate: 같은 spec 의 .pending marker 이미 존재 + mode=source_edit → re-write 없음 (mtime 만 갱신)

6. `tests/hooks/run-all.sh` 에 신규 test 등록

제외 (별 cycle):

- X4.C.4: SPIKE 측정 + 영역 B 통합 검토 (Q-1) + 영역 C 종결
- X3.B.3: post-edit-review-gate dirty source path 본문 append

## 작업 기준

1. TDD red-green — test 먼저 작성 → 실패 확인 → 구현 → PASS
2. fail-soft: state-machine.sh 부재 또는 read_effective_mode 실패 → 모든 hook 은 legacy path 진입 (외부 동작 회귀 0). 본 V5 검증
3. design memo §6 R-7 (false-positive skip) mitigation — 보수적 skip 만 적용. 안전 gate (incident/spec-review/routing) 는 skip 대상 외
4. shellcheck clean (가능 시)
5. 전 hook test suite 회귀 0 (X4.C.1/C.2 baseline + 전체 hook chain)
6. codex Mode A code-review PASS — `.codex-reviewed` stamp
7. security-reviewer PASS — `.security-reviewed` stamp
8. inbox + index 갱신 + dev commit (single commit per cycle)

## 검증 시나리오

- (V1) `bash tests/hooks/test-state-machine.sh` X4.C.1 baseline 6/6 PASS
- (V2) `bash tests/hooks/test-state-machine-integration.sh` X4.C.2 4 case PASS
- (V3) `bash tests/hooks/test-state-fast-path-skip.sh` 신규 4 case PASS
- (V4) `bash tests/hooks/run-all.sh` ALL SUITES PASSED
- (V5) state.json + 3 journal 모두 삭제 → 4 patched hook 모두 정상 동작 (legacy fallback)
- (V6) `bash tests/rein-test.sh` 15/15 PASS — CLI 표면 회귀 0

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills:
  - superpowers:test-driven-development
  - rein:codex-review
  - superpowers:verification-before-completion
mcps: []
rationale: |
  영역 C 의 fast-path skip cycle. lib (X4.C.1) + wire-up (X4.C.2) 가 land 된
  상태에서 4 policy hook 에 read_effective_mode 분기 + 보수적 skip 추가.
  feature-builder 가 4 hook 의 일관된 patch + adversarial test 관리. TDD 로
  4 test 먼저 작성 후 hook 본문 수정. codex Mode A 로 false-positive skip
  (R-7) + fail-soft contract (V5) 리뷰. verification-before-completion 으로
  legacy fallback 까지 실증 후 완료.
security_tier: standard
approved_by_user: true
auto_mode_rationale: |
  사용자가 "잔존 작업 모두 순차적으로 진행" + 오토모드 명시. dispatcher 본문
  미변경 + Bash exit code 추출 미동반이지만 보안 영향 gate (DoD/incident/spec-review)
  의 conditional skip 분기 추가 → standard tier 필수.
```

## self-review

- [ ] 4 hook patch 의 fast-path 진입 조건이 design memo §3.4 + §6.2 의 "보수적 skip" 정책과 일치
- [ ] 안전 gate (incident / spec-review / routing approved_by_user) 는 skip 대상 외
- [ ] state-machine.sh source 실패 시 legacy path — V5 검증
- [ ] adversarial test 4 case 가 design memo §8.4 의 검증 시나리오 (mode-dependent skip + legacy fallback) 와 1:1 매칭
- [ ] 전 test suite 회귀 0
- [ ] cycle commit message 가 `feat(hooks): Cycle X4.C.3 — ...` 형식 + scope 점(.) 없음 (메모리: feedback_commit_scope_format)

---
## dod-2026-05-27-g3-cycle-completion.md (mtime: 2026-05-27, archived: 2026-05-28)
# G3 brainstorm/spec/plan cycle completion — docs-only commit

- 날짜: 2026-05-27
- 작업: G3 execution-mode-advisor 의 brainstorm + spec + plan + spec-review stamp 2개 사이클 완료 후 dev commit. **docs-only, 코드 변경 0**.

## 범위

본 DoD 는 G3 design phase 산출물 (brainstorm/spec/plan/stamps/inbox/index) 만 commit 한다. 실제 구현 (Phase 1~4 코드 변경) 은 본 DoD 범위 외 — 새 세션에서 별 DoD 로.

## 변경 파일

- `docs/brainstorms/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `docs/specs/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `docs/plans/2026-05-27-g3-execution-mode-advisor.md` (신규)
- `trail/inbox/2026-05-27-g3-brainstorm-spec-plan.md` (신규)
- `trail/index.md` (갱신 — 다음 세션 진입점 + 회고)
- `trail/dod/.spec-reviews/*.reviewed` (2 신규 — spec, plan)
- `trail/dod/dod-2026-05-27-g3-cycle-completion.md` (본 DoD)
- `need-to-confirm.md` (사용자가 IDE 에서 직접 TONE-1 항목 추가 — 본 turn 내 사용자 피드백의 직접 결실, 같은 commit 에 포함)
- `trail/dod/.active-dod` (session-active marker)
- `trail/dod/.session-has-src-edit` (deleted by session cleanup)
- `trail/incidents/active-dod-cleanup.log` (auto-append by session cleanup)
- `trail/incidents/invalid-active-dod-marker.log` (auto-append by session cleanup)

## 검증 기준

1. spec stamp 존재: `trail/dod/.spec-reviews/<spec hash>.reviewed` (reviewer=codex-gpt-5.5-medium-r4)
2. plan stamp 존재: `trail/dod/.spec-reviews/<plan hash>.reviewed` (reviewer=codex-gpt-5.5-medium)
3. pending 0건: `ls trail/dod/.spec-reviews/*.pending 2>/dev/null | wc -l` = 0 (확인 완료)
4. validator PASS: `python3 scripts/rein-validate-coverage-matrix.py plan docs/plans/2026-05-27-g3-execution-mode-advisor.md` exit 0
5. commit message: `<type>(<scope>): description` 형식 + scope 에 점/숫자 prefix 없음 (`feedback_commit_scope_format`)

## 라우팅 추천

agent: rein:feature-builder
skills: []
mcps: []
security_tier: light
approved_by_user: true
rationale: docs-only commit. 코드 변경 0 (markdown 만). security surface 없음 (path traversal / secrets / external input 모두 무관). codex-review 는 docs 차원에서 1회 (commit gate 통과용 `.codex-reviewed` stamp 생성).

---
## dod-2026-05-27-v1-3-8-changelog-release-prep.md (mtime: 2026-05-27, archived: 2026-05-28)
# v1.3.8 release prep — CHANGELOG 통합 entry + main 머지

- 날짜: 2026-05-27
- 유형: release prep (docs + version tagging)
- plan ref: 없음 (단발 release cycle)
- 선행 commit: dev `2b4ece9` (backlog cleanup)

## 범위

dev 에 누적된 v1.3.8 작업 (plugin install hotfix `cb4d997` + G3 `021bbf9` + TONE-1 `413169d` + 자동모드 `080455e` + backlog cleanup `2b4ece9`) 을 main 으로 머지 + tag `v1.3.8`. CHANGELOG 의 v1.3.8 entry 가 hotfix-only 라 오늘 추가 user-facing 변경 (G3 routing-map / meta-check / `## 변경 파일` 의무 / TONE-1 response-tone / 자동모드 marker+스킬+silent) 을 통합 entry 로 확장.

## 변경 파일

### dev step (release prep)

- `CHANGELOG.md` (modify — v1.3.8 entry 확장: hotfix + G3 + TONE-1 + 자동모드 통합)
- `trail/dod/dod-2026-05-27-v1-3-8-changelog-release-prep.md` (본 DoD)
- `trail/dod/.active-dod` / `.codex-reviewed` (light tier)
- `trail/inbox/2026-05-27-v1-3-8-release.md` (완료 시점)
- `trail/index.md` (다음 진입점 갱신 — release 후 상태)

### main step (선별 체크아웃, branch-strategy.md §포함 목록)

- `plugins/rein-core/**` (전체 변경 파일)
- `scripts/rein.sh` (VERSION=1.3.8 이미)
- `tests/**` (5 신규 + 회귀 갱신)
- `trail/**` (DoD/inbox/index/stamps)
- `CHANGELOG.md` (위 확장 entry)
- `.rein/project.json` (단일 파일, 변경 없으면 skip)
- `AGENTS.md` (변경 없으면 skip)

### main step (제외)

- `.claude/**` (Option C Phase 3 폐기, dev-only)
- `docs/specs / docs/plans / docs/brainstorms / docs/reports` (메인테이너 dev-only)
- `need-to-confirm.md`, `confirmed.md` (메인테이너 임시 노트)

## 검증 기준

1. **사용자 명시 버전**: 1.3.8 (사용자 turn 2026-05-27)
2. **plugin.json + scripts/rein.sh parity**: 둘 다 `1.3.8` (확인 완료)
3. **versioning Rule A advisory**: 오늘 변경이 user-facing 신규 기능 다수라 minor bump (v1.4.0) 가 advisory checklist 권고이지만, 사용자가 v1.3.8 (patch) 로 명시 결정 — Rule A 는 advisory hard gate 아님, 사용자 결정 우선
4. **versioning Rule B (같은 날 복수 bump 금지)**: 위반 없음 (직전 release v1.3.7 = 2026-05-24, 오늘 = 2026-05-27, 3일 간격)
5. **CHANGELOG Rule C (user-facing only)**: 통합 entry 가 user-facing 항목만 포함 (G3 routing-map / meta-check advisory / `## 변경 파일` 의무 / TONE-1 응답 톤 / 자동모드 marker+스킬+silent — 모두 사용자 관찰 가능)
6. **tag 존재**: `git tag -l v1.3.8` 부재 확인 (신규 tag)
7. **main 머지 후**: `claude plugin validate plugins/rein-core` PASS / public mirror strip 검증 (`mirror-to-public.yml` 이 자동 실행)
8. **branch-strategy 단방향**: main 에서 직접 편집 안 함, `git checkout dev -- <file>` 만

## 라우팅 추천

agent: rein:docs-writer
skills:
  - rein:codex-review
mcps: []
security_tier: light
approved_by_user: true
rationale: |
  release prep — CHANGELOG markdown 편집 + git tag + push. 코드/hook 영향 0
  (오늘 dev 작업의 코드 변경은 이미 prior cycle 들에서 리뷰/테스트 완료).
  security_tier: light 적정.

  사용자 명시 "메인 머지부터 진행. 버전 1.3.8" = implicit routing approval.
  branch-strategy.md 절차 준수 (선별 체크아웃, 단방향, CLAUDE.md @import 제거).

---
## dod-2026-05-28-backlog-3-track-cherry-merge.md (mtime: 2026-05-28, archived: 2026-05-29)
# DoD — 백로그 3 트랙 cherry-pick merge + 통합 review

- 날짜: 2026-05-28
- slug: backlog-3-track-cherry-merge
- 유형: feat + fix + perf 통합 통합 (cherry-pick reconciliation)

## 배경

2026-05-27 세션에서 worktree 격리 백그라운드 Agent 3개로 백로그 3 트랙을 dispatch 했고, 각 worktree branch 에 commit 까지 완료된 상태로 보류 중. trail/index.md 의 "B→A→C sequential merge" 계획은 다음 위험을 고려하지 않았음:

1. 각 worktree 의 merge-base 가 dev tip (`d9a6f8a`) 가 아니라 `aaa9e61b` (옛 base) — 옛 docs/ 부활 위험
2. `git diff d9a6f8a <worktree>` 가 -42k~-44k deletion 으로 표시되는 건 옛 base 잔재 (의도된 변경 아님)
3. 3 트랙 간 100+ 파일 overlap (특히 `.codex-reviewed` / `.security-reviewed` stamp 파일)
4. Track C 의 self-approved stamp 는 worktree 안에서 self-review 한 결과 (정식 검증 아님)

따라서 단순 `git merge` 대신 **각 worktree 의 top commit 만 cherry-pick** + **self-stamps 는 cherry-pick 에서 제외 후 통합 review 에서 재생성** 전략.

## 범위

### IN
- **Phase 0**: dev working tree 의 trail/ 변경분(15개 파일) 을 `chore(trail): session housekeeping` 으로 별도 commit
- **Phase 1**: Track B (`d3620e5`) top commit cherry-pick — SR-1.b orphan `.reviewed` backstop
- **Phase 2**: Track A (`b82ddbf`) top commit cherry-pick — PLN-1 plan exec-strategy schema + AG-2 worktree worker agent
- **Phase 3**: Track C (`e924078`) top commit cherry-pick — G3-perf-NFR shell rewrite of meta-check policy loader
- **Phase 4**: 통합 codex review (`/codex-review`) → stamp 재생성
- **Phase 5**: 통합 security review (`rein:security-reviewer`) → stamp 재생성
- **Phase 6**: review NEEDS-FIX 반영
- **Phase 7**: test suite 전체 실행 (tests/hooks/run-all.sh + tests/scripts/* + tests/agents/*)
- **Phase 8**: inbox + index.md 갱신 + 사용자 push 승인 받고 origin/dev push

### OUT
- main 머지 / tag / publish — 본 DoD 범위 아님. dev push 까지만
- worktree 11개의 정리 — 별도 DoD 로 분리
- Track A 의 PLN1-GATE-ENFORCEMENT 활성화 — commit 내 marker 그대로 두고 추후 별도 DoD
- 각 worktree branch 의 self-approved stamps (`.codex-reviewed` / `.security-reviewed` / `.spec-reviews/*`) — cherry-pick 에서 명시적 제외 (`--no-commit` + `git restore --staged`)

## 변경 파일

### Phase 0 (housekeeping commit)
- trail/daily/2026-05-17.md (deletion — rollup 완료)
- trail/daily/2026-05-18.md (deletion)
- trail/daily/2026-05-19.md (deletion)
- trail/daily/2026-05-24.md (신규)
- trail/dod/.active-dod (modified)
- trail/dod/.session-has-src-edit (deletion)
- trail/dod/dod-2026-05-24-v1-3-7-release.md (deletion — 완료)
- trail/inbox/2026-05-24-session-continuation.md (deletion)
- trail/inbox/2026-05-24-session.md (deletion)
- trail/inbox/2026-05-24-v1-3-7-release.md (deletion)
- trail/inbox/2026-05-27-backlog-3-track-parallel-dispatch.md (신규)
- trail/incidents/.last-aggregate-state.json (modified)
- trail/incidents/active-dod-cleanup.log (modified)
- trail/incidents/invalid-active-dod-marker.log (modified)
- trail/index.md (modified)
- trail/weekly/2026-W20.md (modified)
- trail/weekly/2026-W21.md (신규)

### Phase 1 (Track B top commit)
- plugins/rein-core/hooks/pre-edit-dod-gate.sh (modified — orphan .reviewed backstop 추가)
- tests/hooks/run-all.sh (modified)
- tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh (신규)
- trail/dod/dod-2026-05-27-sr-1-b-pre-edit-gate-stale-reviewed.md (신규)
- trail/inbox/2026-05-27-sr-1-b-pre-edit-gate.md (신규)

### Phase 2 (Track A top commit)
- plugins/rein-core/rules/design-plan-coverage.md (modified — section 2A schema)
- scripts/rein-validate-coverage-matrix.py (modified — parse_execution_strategy)
- plugins/rein-core/scripts/rein-validate-coverage-matrix.py (신규 — plugin mirror)
- plugins/rein-core/agents/plan-writer.md (modified — 3-axis judgment)
- plugins/rein-core/hooks/pre-edit-dod-gate.sh (modified — parallelizable advisory)
- plugins/rein-core/docs/worktree-cleanup.md (신규)
- plugins/rein-core/agents/feature-builder-worker.md (신규)
- tests/scripts/test-pln1-execution-strategy.sh (신규)
- tests/agents/test-ag2-worktree-frontmatter.sh (신규)
- docs/brainstorms/2026-05-27-pln1-ag2-parallel-execution.md (신규)
- docs/plans/2026-05-27-pln1-ag2-parallel-execution.md (신규)
- trail/dod/dod-2026-05-27-pln1-ag2-parallel-execution.md (신규)
- trail/inbox/2026-05-27-pln1-ag2-parallel-execution.md (신규)

### Phase 3 (Track C top commit)
- plugins/rein-core/hooks/lib/meta-check-policy.sh (신규 — shell port)
- plugins/rein-core/hooks/post-edit-meta-check.sh (modified — heredoc merge)
- plugins/rein-core/docs/policy-meta-check.md (modified)
- docs/specs/2026-05-27-g3-perf-nfr.md (신규)
- docs/specs/2026-05-27-g3-execution-mode-advisor.md (modified)
- docs/plans/2026-05-27-g3-perf-nfr.md (신규)
- docs/plans/2026-05-27-g3-execution-mode-advisor.md (modified)
- docs/brainstorms/2026-05-27-g3-perf-nfr-design.md (신규)
- tests/hooks/test-meta-check-policy-parity.sh (신규)
- tests/hooks/test-meta-check-policy-shell.sh (신규)
- tests/hooks/test-post-edit-meta-check-perf.sh (신규)
- tests/hooks/test-post-edit-meta-check.sh (modified)
- tests/hooks/test-post-edit-parallel-entries.sh (modified)
- trail/dod/dod-2026-05-27-g3-perf-nfr.md (신규)
- trail/inbox/2026-05-27-g3-perf-nfr.md (신규)

### Phase 4~5 (review stamps — Phase 1~3 cherry-pick 후 통합 review 가 재생성)
- trail/dod/.codex-reviewed (regenerated)
- trail/dod/.security-reviewed (regenerated)
- trail/dod/.spec-reviews/*.reviewed (cherry-pick 으로 들어온 신규 spec/plan 에 대한 stamp 추가)

### Phase 8 (inbox + index)
- trail/inbox/2026-05-28-backlog-3-track-merge.md (신규)
- trail/index.md (modified)

## 검증 기준

- [ ] Phase 0 housekeeping commit 의 git status 가 clean
- [ ] Phase 1 cherry-pick 후 `tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh` 5/5 PASS
- [ ] Phase 1 cherry-pick 후 `tests/hooks/test-spec-review-gate.sh` 27/27 PASS (SR-1 회귀 없음)
- [ ] Phase 2 cherry-pick 후 `tests/scripts/test-pln1-execution-strategy.sh` 10/10 PASS
- [ ] Phase 2 cherry-pick 후 `tests/agents/test-ag2-worktree-frontmatter.sh` 18/18 PASS
- [ ] Phase 3 cherry-pick 후 `tests/hooks/test-meta-check-policy-parity.sh` PASS + `test-meta-check-policy-shell.sh` PASS + `test-post-edit-meta-check-perf.sh` p95 ≤ 180ms
- [ ] Phase 4 `/codex-review` PASS verdict
- [ ] Phase 5 security review 0 high severity
- [ ] Phase 7 전체 test suite 회귀 0
- [ ] cherry-pick 충돌 발생 시 manual merge 결과가 두 트랙의 의도 모두 보존 (특히 pre-edit-dod-gate.sh 의 B SR-1.b orphan backstop + A parallelizable advisory 둘 다)
- [ ] dev branch 의 final tip 이 사용자 push 승인 후 origin/dev 로 푸시 완료
- [ ] worktree branch 3개는 작업 후 그대로 잔존 (별도 cleanup DoD 대상)

## 라우팅 추천

```yaml
agent: claude
skills:
  - rein:codex-review       # Phase 4 통합 review 의 핵심 gate (stamp 재생성)
  - superpowers:verification-before-completion  # PASS claim 전 명령 실행 강제 (self-stamp 재발 방지)
mcps: []
security_tier: standard
push_timing: phase-8-after-all-pass-with-explicit-approval
rationale: |
  본 작업은 git cherry-pick + manual merge + 통합 review 가 주 작업.
  현재 세션 (claude) 이 직접 수행 — subagent 위임 시 충돌 해소 결정이 외부
  로 빠져나가 의도 vs 다른 결과 위험. codex-review 는 통합 후 단일 review
  로 self-stamps 무효화 + 정식 stamp 재발급. verification-before-completion
  은 'test PASS' claim 전 실제 명령 실행을 강제해 self-stamp 패턴 재발 방지.
  security_tier=standard 사유: hook 2개 변경 (pre-edit-dod-gate.sh,
  post-edit-meta-check.sh) + 신규 scripts/validator 포함이라 light 부적합.
  push 는 Phase 8 의 모든 PASS 확인 후 사용자 명시 승인 받고 1회.
approved_by_user: true
approved_at: 2026-05-28
```

## 위험·완화

| 위험 | 영향 | 완화 |
|---|---|---|
| Phase 2 의 pre-edit-dod-gate.sh cherry-pick 가 Phase 1 의 같은 파일 변경과 충돌 | 두 변경 모두 적용 안 됨 | cherry-pick 충돌 시 manual edit — 두 영역(orphan backstop / parallelizable advisory) 모두 보존 |
| 옛 base 의 docs/ 부활 | 의도치 않은 옛 파일 복원 | top commit 만 cherry-pick (`git cherry-pick <sha>` 단일). 전체 branch 머지 금지 |
| self-stamps cherry-pick 으로 정식 검증 우회 | review gate bypass | cherry-pick 시 `.codex-reviewed` / `.security-reviewed` / `.spec-reviews/*` 명시적 `git restore --staged` 후 working tree 에서 제거 |
| Track C 의 perf 임계값 180ms 회귀 | gate 통과 못 함 | cherry-pick 후 `test-post-edit-meta-check-perf.sh` 즉시 실행 |
| dev push 가 다른 협업자 작업 덮어쓰기 | data loss | push 직전 `git fetch origin && git log origin/dev..dev` 확인 + 사용자 명시 승인 |

## 후속

- worktree 11개 cleanup (별도 DoD)
- Track A PLN1-GATE-ENFORCEMENT marker 활성화 — AG-2 stabilization 검증 후 별도 DoD
- main 머지 + tag — dev 안정화 후 별도 release DoD

