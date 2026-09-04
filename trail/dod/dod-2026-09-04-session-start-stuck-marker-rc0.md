# DoD — 세션 시작 훅: 이미 초기화된 프로젝트에서 비활성 표식 삭제 실패가 무음인 결함 + 리눅스 CI 픽스처 S 편차 (버그 수정)

- date: 2026-09-04 착수
- approved_by_user: true (2026-09-04 "오늘 들어온 이슈까지 끼워서 v2.0.3 배포하자" + "CI가 실패하는데 확인해봐" — v2.0.3 배포 통합 리뷰 High 지적 + dev CI 실패 수리)
- plan ref: 없음 (버그 수정 — 배포 사이클 `dod-2026-09-04-v2-0-3-release.md` 의 main 통합 리뷰 4회차 High + GitHub Actions run 33854781439 실패)

## 배경

1. `hooks/session-start-bootstrap.sh` 의 rc=0(이미 초기화됨) 분기는 `rein_clear_degraded` 를 호출하고 결과를 보지 않는다. `.claude/cache` 가 쓰기 불가면 표식이 남고, 훅은 exit 0·무출력이라 다음 Bash 호출이 게이트에 막히는데 사용자는 이유를 모른다. 초기화 경로(exit 4)에는 이미 한 줄 안내가 있으나 rc=0 경로엔 없다(통합 리뷰 4회차 High).
2. dev CI(우분투)에서 `tests/hooks/test-session-start-bootstrap.sh` 픽스처 S(표식 삭제 실패 + 개행 경로 + POSIXLY_CORRECT=1)만 실패 — macOS 통과. **원인 확정(도커 우분투 bash 5.2 재현)**: `hooks/lib/git-required-guidance.sh` 의 안내 표시 플래그 생성이 `: 2>/dev/null > "$flag"` — `:` 는 POSIX *특수* 내장명령이라 POSIX 모드(bash 5 + POSIXLY_CORRECT=1)에서 리다이렉트 실패가 명령 실패가 아니라 **셸 종료**가 되어, 읽기 전용 캐시에서 `bootstrap_check` 를 담은 명령 치환 서브셸이 exit 1 로 죽고 세션 시작 훅이 초기화를 건너뛴 채 무음 종료(bash 3.2 는 미강제). 훅 결함이며 픽스처는 정확했다.

## 범위

1. rc=0 경로: 표식 제거가 **실패했고** 게이트와 같은 판정(`-f`)으로 표식이 여전히 보이면 초기화 경로(exit 4)와 같은 한 줄 안내(경로 `%q` 인용, KR/EN, `printf '%s\n'`)를 stdout 에 내고 exit 0. 제거 성공/표식 부재/디렉터리가 이름을 차지한 경우면 무음. 안내를 낸 실행에서는 1회성 프라이머 백필을 건너뛰어 그 실행의 stdout 이 정확히 한 줄이 되게 한다(이후 `.gitignore` 보정은 계속). 두 분기가 같은 함수로 문구를 만든다(복제 금지).
2. 특수 내장명령 리다이렉트 클래스 봉합: 플러그인 셸 코드(hooks/scripts/bin)에서 `: > file` 형태 4곳(안내 표시 플래그·활성 DoD 세션 플래그·라우팅 검사 표식·리뷰 래퍼 임시파일)을 일반 내장명령 `printf ''` 로 교체. 재발 방지: 안내 lib 단위 케이스(읽기 전용 캐시 + POSIXLY_CORRECT=1 자식 bash 에서 호출자 생존·rc 0·stderr 무누출) + 플러그인 전체 정적 검사 스위트(`tests/hooks/test-no-special-builtin-redirect.sh`, 양성/음성 자기검사 포함). "표식 삭제 실패 + 개행 경로 + POSIX 모드에서도 stdout 정확히 한 줄" 계약(픽스처 S) 유지.
3. 포함하지 않음: 표식 형식·경로 변경, 게이트(bash/edit) 측 안내 변경, 도커 기반 CI 도입.

## 변경 파일

- `plugins/rein-core/hooks/session-start-bootstrap.sh`
- `tests/hooks/test-session-start-bootstrap.sh` (rc=0 표식 잔존 픽스처 추가 + S 편차 수리)
- `plugins/rein-core/hooks/lib/git-required-guidance.sh`, `plugins/rein-core/hooks/lib/select-active-dod.sh`, `plugins/rein-core/hooks/post-edit-dod-routing-check.sh`, `plugins/rein-core/scripts/rein-codex-review.sh` + 루트 미러 `scripts/rein-codex-review.sh`(번들 동일성 스위트가 sha 일치를 요구) (`: >` → `printf '' >`)
- `tests/hooks/test-git-required-guidance.sh` (케이스 N), `tests/hooks/test-no-special-builtin-redirect.sh` (신규), `tests/hooks/run-all.sh` (등록)

## 검증 기준

- [x] 새 픽스처: 초기화된 저장소 + `.claude/cache` 555 + 오래된 표식 → 훅 exit 0, stdout 정확히 한 줄(%q 경로·삭제·세션 단어), 표식 잔존. 표식 부재/삭제 성공 시 stdout 비어있음(기존 픽스처 유지).
- [x] 픽스처 S 가 macOS 와 우분투(도커 `ubuntu:24.04` + git/python3, bash 5.2, 비루트) 양쪽에서 통과. 안내 lib 케이스 N 과 정적 검사 스위트 통과(양쪽).
- [x] `tests/hooks/run-all.sh` · `tests/scripts/run-all.sh` · `tests/integration/run-all.sh` ALL SUITES PASSED, `bash -n` 통과.
- [x] dev push 후 GitHub Actions `tests` success. (6ece5d1 푸시, 결과는 완료 기록/index 참조 — 감시 중)

## 라우팅 추천

agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps: []
security_tier: base
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 세션 시작 훅 한 분기 + 픽스처 수정, 재현 테스트 선행
approved_by_user: true

## 완료

- 2026-09-04 코드 커밋 dev `6ece5d1` (codex 4회차 PASS, 보안 standard PASS). 완료 기록 `trail/inbox/2026-09-04-session-start-stuck-marker-complete.md`.
