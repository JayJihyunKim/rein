# DoD — v2 배포 선결: 설치 시 사용자 .gitignore 에 런타임 폴더 비추적 등록 (자기무효화 봉합)

- date: 2026-08-27 착수
- plan ref: 없음 (기존 설계 의도의 미구현 봉합 — 새 설계 아님)
- approved_by_user: true (2026-08-27 "응 그것부터 잡자" — v2 배포 선결 blocker ① 착수 명시 승인)

## 배경

plan 없음 (직접 DoD — 버그 봉합). **설계 의도는 이미 코드에 명시**: `plugins/rein-core/rein/platform/storage/local.py` 가 "state 루트는 `.rein/state/` 로 고정하고, `.gitignore` 의 `/.rein/state/` 패턴이 비추적을 보장한다 (테스트가 이 사실을 고정한다)" 라고 문서화하고 `GITIGNORE_PATTERN = "/.rein/state/"` 상수까지 둔다. 그런데 `rein-bootstrap-project.py` 가 그 `.gitignore` 패턴을 **생성하지 않는다**(실측 0건). 결과: `/plugin install` 사용자 프로젝트에서 `.rein/state/`(증거 원장)가 untracked 로 잡혀 `worktree_changeset()`(`--untracked-files=all`)의 subject digest 에 섞이고, 최초 증거 발급이 자기 subject 를 바꿔 **자기무효화**(게이트 자기봉쇄, 실패 방향 fail-closed). 이 저장소(rein-dev)는 사람이 `.gitignore` 에 수동 등록해 안전. **게이트 대장 수정 후보 (i) 채택** — 설계 의도(`.gitignore` 비추적)와 정합.

## 범위

- `rein-bootstrap-project.py` 의 bootstrap 경로에 **사용자 git root 의 `.gitignore` 멱등 갱신** 추가.
- 등록 패턴 3종 (런타임, rein-dev `.gitignore` 와 정합): `/.rein/state/`, `/.rein/cache/`, `/.rein/logs/`.
- 멱등: 이미 있는 패턴은 건너뛰고, 없는 것만 append. `.gitignore` 부재 시 생성. 기존 내용·순서 보존.

### 제외

- `.rein/project.json`·`.rein/policy/` 는 **추적 대상** (ship 대상/사용자 정책) — 무시하지 않는다.
- 검사 로직(`worktree_changeset()`/subject 허용목록) 변경 없음 — 설계 의도가 `.gitignore` 방식이므로 수정 후보 (ii) 는 채택하지 않는다.

### 위협 모델 결정 (2026-08-27, 사용자 승인 — B안)

이 봉합의 목적은 **정직한 사용자가 v2 설치 후 자기무효화로 게이트에 갇히지 않게** 하는 것이다. 파일 링크 공격 방어는 위협 모델로 경계를 긋는다:

- **방어 O**: `.gitignore` 가 symlink 인 경우(dotfiles 관리 등 **정당한** 케이스). O_NOFOLLOW 로 외부 쓰기 차단 + 안전 실패(완료 sentinel 미생성).
- **방어 X (위협 모델 밖)**: `.gitignore` 를 외부 파일 hardlink 로 만들어 두고 설치하는 등 **사용자가 자기 프로젝트를 스스로 공격**하는 시나리오. rein 위협 모델은 "정직한 에이전트/사용자"이며(과거 적대적 우회 하드닝 보류 결정과 정합), 링크 유형을 하나씩 막는 열거 방어는 하지 않는다.
- **근거**: 4회차 codex 리뷰가 symlink→hardlink 로 새 공격 벡터를 계속 제시(경계는 열거로 못 닫는다). 불변식으로 전면 하드닝(A안)하는 대신 위협 모델로 경계를 긋기로 사용자 결정(B안).

### 잔존 백로그 (이 사이클 밖 — 게이트 대장 후속 항목)

- **hardlink 외부 파일 변경** (codex 4회차 High): 위협 모델 밖. 필요 시 별도 사이클에서 "단일 fd + 일반 파일 + 링크 수 1" 불변식으로 처리(A안).
- **O_NOFOLLOW 미지원 플랫폼 안전실패 회귀 테스트** (codex 4회차 Medium): `os.O_NOFOLLOW==0` 모사 테스트 — 별도 프로세스 실행이라 모사가 까다로워 이월. 코드 분기(`nofollow==0 → fail`)는 존재.

## 변경 파일

- `plugins/rein-core/scripts/rein-bootstrap-project.py` — `.gitignore` 멱등 갱신 헬퍼 + bootstrap 경로 호출
- (테스트) `tests/scripts/test-bootstrap-persona-neutral.sh` 또는 신규 — bootstrap 후 `.gitignore` 패턴 존재 + 멱등(재실행 무중복) + 기존 내용 보존
- (SPIKE 검증) 사용자 프로젝트 시뮬: bootstrap 후 `.rein/state/` 가 `worktree_changeset()` 에 안 섞이는지 (digest 불변)

## 검증 기준

- [x] bootstrap 후 사용자 git root `.gitignore` 에 `/.rein/state/`·`/.rein/cache/`·`/.rein/logs/` 존재
- [x] 재실행 시 중복 append 없음 (멱등)
- [x] 기존 `.gitignore` 내용·순서 보존 (append-only)
- [x] `.gitignore` 부재 프로젝트에서도 생성
- [x] **자기무효화 봉합 실증**: bootstrap 된 사용자 프로젝트 시뮬에서 `.rein/state/` 파일 생성 전/후 `worktree_changeset()` 기반 리뷰 subject digest 불변 (untracked 혼입 소멸)
- [x] 기존 bootstrap 테스트 전량 GREEN

## 라우팅 추천

- **rein:feature-builder-fix** (자기무효화 버그 봉합, reproduction-first) + **rein:codex-review** + **rein:security-reviewer** (설치 경로 = 보안 표면)

---

approved_by_user: true
