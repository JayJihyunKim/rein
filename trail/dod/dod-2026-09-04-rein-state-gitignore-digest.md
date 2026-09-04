# DoD — 런타임 상태 파일 `.rein/state.json` 이 git 에 추적되어 리뷰 지문을 흔드는 결함 수리

- date: 2026-09-04 착수
- approved_by_user: true (2026-09-04 "오늘 들어온 이슈까지 끼워서 v2.0.3 배포하자")
- plan ref: 없음 (버그 수정 사이클 — 근거 리포트 `docs/reports/[issues]_2026-09-04.md`, 제안 1·4 채택, 2·3·5 는 비범위)


## 배경

사용자 프로젝트(study_eng, 2.0.1/2.0.2)에서 rein 훅이 매 도구 호출마다 고쳐 쓰는 `.rein/state.json` 이 bootstrap 이 만드는 `.gitignore` 에 빠져 있어 초기 커밋에 그대로 추적된다. 이 파일은 리뷰 지문 대상(허용목록 `*.md`/`docs/**`/`trail/**` 밖)이라 리뷰와 커밋 사이 지문이 어긋나 증거 발급이 거부된다. 추적 해제 커밋(`git rm --cached .rein/state.json`)조차 게이트를 못 넘는다 — 스테이징된 삭제 경로에 무시되는 파일이 남아 있으면 지문이 그 디스크 내용을 읽기 때문. rein 저장소 자신의 `.gitignore` 는 이 파일들을 이미 제외하고 있고, bootstrap 이 그 규칙을 사용자 프로젝트에 복제하지 않는 것이 결함이다.

## 범위

1. **bootstrap 무시 규칙 보강** `scripts/rein-bootstrap-project.py`: `REIN_RUNTIME_GITIGNORE_PATTERNS` 에 `/.rein/state.json`, `/.rein/state-pending-*.log`, `/.rein/.onboarded` 를 추가한다(이 저장소 `.gitignore` 의 rein 런타임 항목과 동일 집합). 기존 idempotent append 경로 그대로(중복 없음, 심링크 거부 유지).
2. **기존 프로젝트 자동 보정**: 이미 초기화된 프로젝트(`.rein/project.json` 존재)에서 세션 시작 시 `.gitignore` 에 위 패턴이 빠져 있으면 한 번 보강한다 — `rein-bootstrap-project.py --ensure-gitignore --project-dir <dir>` 서브모드(다른 부작용 없음: trail/·정책·표식 생성 안 함, 비git 이면 즉시 0)를 `hooks/session-start-bootstrap.sh` 의 초기화 완료(rc=0) 경로에서 호출. 추적 해제(`git rm --cached`)는 하지 않는다 — 안내만(CHANGELOG).
3. **스테이징된 삭제의 지문 처리** `rein/platform/git/facts.py`: WORKTREE 지문에서 index 에서 삭제된 경로(porcelain `D` in index column)이고 같은 경로가 `??` 로 다시 보고되지 않으면 내용 공급자가 디스크를 읽지 않고 부재(None)로 답한다 — 무시되는 파일이 그 자리에 남아 있어도 지문이 흔들리지 않는다. 상태 파싱기는 `worktree_changeset()` 과 공유하되, 삭제 집합은 지문 계산 시점에 별도 `git status --porcelain -z` 1회로 파생한다(허용목록·태그 필터링이 새 ChangeSet 을 만들어 호출부에 상태 정보가 남지 않으므로; cwd 만 안정 입력). STAGED 프로필(strict)은 변경하지 않는다(index 내용을 읽으므로 이미 부재).

포함하지 않음: 상태 파일 위치 이동(`.rein/state/` 안으로), 리뷰 지문 범위에서 `.rein/**` 제외(정책 파일이 섞여 있음), `rein doctor` 경고(별도 사이클), `drain_state` 쓰기 억제·순서 변경(핫패스 동작 변경 — 백로그).

## 변경 파일

- `plugins/rein-core/scripts/rein-bootstrap-project.py` (패턴 3종 추가, `--ensure-gitignore` 서브모드)
- `plugins/rein-core/hooks/session-start-bootstrap.sh` (rc=0 경로에서 보정 호출, 실패해도 세션 진행)
- `plugins/rein-core/rein/platform/git/facts.py` (`worktree_changeset` 의 삭제 경로 파생 + WORKTREE 내용 공급자 래핑)
- `tests/scripts/test-bootstrap-gitignore.sh` (패턴 3종·서브모드·idempotent)
- `tests/hooks/test-session-start-bootstrap.sh` (rc=0 경로 보정 픽스처: 패턴 누락 프로젝트 → 보강, 이미 있으면 무변경, 비git/미초기화면 미호출)
- `plugins/rein-core/tests/unit/test_changeset_digest.py` 또는 `test_review_digest_scope.py` (스테이징 삭제 + 무시 파일 잔존 → 지문이 디스크 내용과 무관·안정; `??` 재등장 시 내용 반영; 일반 수정/신규 경로 동작 불변)
- `CHANGELOG.md` / README 두 벌 (배포 DoD 에서 v2.0.3 항목으로 기재 — 이 DoD 의 코드 커밋에는 포함하지 않음)

## 검증 기준

- [x] (red→green) 새 프로젝트 bootstrap 후 `.gitignore` 에 `/.rein/state.json`·`/.rein/state-pending-*.log`·`/.rein/.onboarded` 가 있고, 훅이 상태 파일을 만든 뒤 `git status --porcelain` 에 `.rein/state.json` 이 나타나지 않는다.
- [x] (red→green) 패턴이 빠진 기존 프로젝트에서 세션 시작 훅(초기화 완료 경로) 1회 후 패턴이 보강되고, 재실행 시 중복 없음; 비git·미초기화 프로젝트에서는 `.gitignore` 를 만들지 않는다.
- [x] (red→green) 추적 중이던 `.rein/state.json` 을 `git rm --cached` 로 스테이징 삭제하고 무시되는 파일이 디스크에 남은 상태에서, 파일 내용을 바꿔도 코드 리뷰 지문(`--print-subject`)이 변하지 않는다; 같은 경로가 `??` 로 다시 나타나면 내용이 반영된다.
- [x] 기존 지문 단위 테스트·훅 배터리·스크립트 배터리·통합 배터리 전량 초록. plugin pytest(`plugins/rein-core/tests`) 초록.
- [x] 안내문·주석에 내부 식별자·리뷰 라벨 없음.

## 라우팅 추천

agent: rein:feature-builder-fix
skills:
  - rein:codex-review
  - superpowers:test-driven-development
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 재현 절차가 명확한 결함 3건(무시 규칙 누락·기존 프로젝트 보정 부재·스테이징 삭제 지문 오염) → feature-builder-fix(재현 테스트 선행)
  - 지문 계산(v2 커널 인접)과 사용자 .gitignore 쓰기를 건드리므로 standard 등급, 파일 3+테스트 3 → medium
approved_by_user: true

## 완료

- 2026-09-04 코드 커밋 dev `ab55438` (codex 6회차 + 독립 sonnet 리뷰 PASS, 보안 standard PASS). 완료 기록 `trail/inbox/2026-09-04-state-gitignore-digest-complete.md`, 회차 기록 `trail/inbox/2026-09-04-state-gitignore-review-rounds.md`.
