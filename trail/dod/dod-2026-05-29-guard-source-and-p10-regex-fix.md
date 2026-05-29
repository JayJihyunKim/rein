# 가드 버그 2건 수정 — wrapper source fail-closed + P10 정규식 오탐

- 날짜: 2026-05-29
- 유형: fix
- plan ref: N/A (독립 버그 2건, codex Mode B 검증 완료)
- 배경 검증: need-to-confirm.md 185~248행 버그 리포트 2건 + codex gpt-5.5/high 독립 검증 (2026-05-29). 두 증상 모두 실측 재현됨.

## 버그 1 (BUG-WRAP-SOURCE) — 리뷰 wrapper 의 "라이브러리 없음" 가드 미작동

- **파일**: `plugins/rein-core/scripts/rein-codex-review.sh` (37행 `set -euo pipefail`, 98-102행)
- **증상**: 의존 라이브러리(`select-active-dod.sh`) 부재 시 에러 메시지 + exit 2 가 출력되지 않고 조용히 exit 1.
- **근본 원인 (codex 정정)**: 리포트의 "POSIX 특수 빌트인" 설명은 **부정확**. 실제는 `set -e`(errexit)가 `source` 빌트인의 "cannot read source file" 에러 경로와 상호작용 — 일반 명령에 작동하는 `if !` errexit 예외가 이 경우엔 안 먹혀 then 블록 도달 전 종료. (codex 실측: `set +e` 면 통과, `set -e` 면 차단.)
- **수정 방향 (codex 권고)**: `[ ! -f ]` 단독은 부분적 (읽기불가/구문오류/내부실패 구멍 잔존). `[ ! -r ]` precheck + 서브셸 검증 + 핵심 함수 정의 확인으로 견고화:
  ```bash
  if [ ! -r "$_select_active_dod_lib" ] || \
     ! ( . "$_select_active_dod_lib"; declare -F select_active_dod >/dev/null ) 2>/dev/null; then
    echo "ERROR: [codex-review] missing or invalid select-active-dod library at $_select_active_dod_lib" >&2
    exit 2
  fi
  . "$_select_active_dod_lib"
  ```

## 버그 2 (BUG-P10-REGEX) — 안전 가드 P10 정규식 오탐

- **파일**: `plugins/rein-core/hooks/pre-bash-safety-guard.sh` (P10, 133-141행)
- **증상**: (a) `.env` 존재 시 `git commit --amend` 차단, (b) `git commit -am` 을 텍스트로 언급하는 echo/grep 명령도 차단.
- **근본 원인 (둘 다 confirmed)**: (1) `-[a-z]*a[a-z]*m` 이 `--amend` 의 두 번째 대시부터 `-am` 매치, (2) P10 만 raw `echo|grep` 사용 — 바로 아래 P11 은 `command_invokes` 로 텍스트 언급 제외하는데 P10 은 clause 앵커링 없음.
- **수정 방향 (codex 권고)**: `command_invokes` 로 전환(텍스트 언급 제외) + `--amend` 제외 + split/순서 변형 포착. codex 제안 3중 정규식:
  ```bash
  if command_invokes "git commit[^;&|]*(^|[[:space:]])-[[:alpha:]]*a[[:alpha:]]*m[^[:space:];&|]*([[:space:]]|$)" \
     || command_invokes "git commit[^;&|]*(^|[[:space:]])(-a|--all)([[:space:]]|$)[^;&|]*(^|[[:space:]])(-m|--message)([=[:space:]]|$)" \
     || command_invokes "git commit[^;&|]*(^|[[:space:]])(-m|--message)([=[:space:]]|$)[^;&|]*(^|[[:space:]])(-a|--all)([[:space:]]|$)"; then
  ```
  (잔존 한계: `command_invokes` 는 따옴표 비인식 — `echo "x; git commit -am"` 류는 regex 로 완전 해소 불가. 알려진 제약으로 수용, 주석 명시.)

## 완료 기준 (DoD)

1. **버그1**: 라이브러리가 없거나 읽기 불가일 때 `ERROR: ... library` 메시지 + exit 2 가 실제 출력된다(조용한 exit 1 아님). reproduction-first: RED(현재 exit 1, 메시지 없음) → GREEN.
2. **버그2 면제(통과)**: `.env` 존재해도 `git commit --amend`, `echo/grep "...git commit -am..."` 텍스트 언급은 차단되지 않는다.
3. **버그2 차단 유지**: `.env` 존재 시 실제 `git commit -am` / `-a -m` / `-m ... -a` / `--all -m` / `-m --all` 형태는 차단된다.
4. 회귀 테스트를 추가하고 러너에 등록 (두 버그 각각).
5. 기존 테스트 스위트 회귀 없음 (특히 `test-pre-bash-safety-guard.sh`, `test-codex-review-wrapper.sh`).
6. `bash -n` 양 파일 구문 검증 통과.

## 버그 3 (BUG-P10-GLOBAL-OPTS) — 통합 codex 리뷰 NEEDS-FIX (High), 2026-05-29 follow-up

- **파일**: `plugins/rein-core/hooks/pre-bash-safety-guard.sh` (P10, 156-158행 3중 정규식)
- **증상 (false-negative)**: 3 정규식이 `git commit` 인접을 요구해서, `git` 과 `commit` 사이에 전역 옵션이 끼면 `.env` 존재해도 차단 안 됨:
  - `git -C . commit -am x`
  - `git -c user.name=x commit -am x`
  - `git --git-dir=.git --work-tree=. commit -am x`
  - `sudo git -C . commit -am x`
- **근본 원인**: 정규식이 `git commit` 리터럴 인접만 매치. `command_invokes` 의 wrapper 처리는 `env`/`sudo` prefix 만 흡수하고 git 자체의 전역 옵션(`-C`/`-c`/`--git-dir`/`--work-tree`)은 흡수하지 않음. (참고: `env GIT_DIR=... git commit -am` 은 wrapper 의 VAR= prefix 로 이미 매치.)
- **수정 방향 (codex 제안, 실측 검증 완료)**: 3 정규식의 `git commit` 부분을 git 과 commit 사이 전역 옵션을 허용하는 prefix 로 교체:
  ```
  git([[:space:]]+(-C[[:space:]]+[^;&|[:space:]]+|-c[[:space:]]+[^;&|[:space:]]+|--git-dir(=|[[:space:]])[^;&|[:space:]]+|--work-tree(=|[[:space:]])[^;&|[:space:]]+))*[[:space:]]+commit
  ```
  옵션 인자는 `[^;&|[:space:]]+` 로 clause 경계/공백을 넘지 않게 제한, 다중 전역 옵션은 `( ... )*` 로 처리. 실측 27 케이스 RED→GREEN (신규 4 + 다중옵션 1 + 기존 차단 6 회귀 + 비차단 7 + clause 경계 2 + false-positive 가드 6).

## 버그 4 (TYPO) — 주석 중국어 혼입

- **파일**: `plugins/rein-core/scripts/rein-codex-review.sh` + dev-fallback 사본 `scripts/rein-codex-review.sh`
- **증상**: 주석에 `codex实측` (중국어). `codex 실측` (한국어) 로 양 사본 byte-identical 교체.

## 비목표

- `command_invokes` 의 따옴표 인식(shell 파서) 도입 — regex 분류기 범위 밖, 별도 트랙.
- 다른 정책 체크(P1/P8/P9/P11) 변경.

## 변경 파일

- plugins/rein-core/hooks/pre-bash-safety-guard.sh
- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- tests/hooks/test-pre-bash-safety-guard.sh

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
rationale: >
  독립 버그 2건 수정 (DoD 키워드 fix/버그). reproduction-first 전략 적합 —
  각 버그의 failing 케이스를 먼저 테스트로 고정 후 수정. codex Mode B 가 이미
  근본원인+수정안 검증 완료. 구현 후 codex-review (Mode A) 로 게이트 회귀 검증.
  직전 turn 동일 라우팅 (hook 버그 수정) 을 사용자가 승인한 연속선.
approved_by_user: true
```
