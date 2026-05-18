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

