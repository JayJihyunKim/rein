# 2026-08-27 — v2 배포 선결 ① 자기무효화 봉합 (`95870df`, dev, 미푸시)

## 무엇을 했나

`/plugin install` 사용자 프로젝트에서 증거 원장(`.rein/state/`)이 untracked 로 리뷰 검사(`worktree_changeset`)에 섞여 **최초 증거 발급이 자기 subject 를 바꿔 게이트를 자기봉쇄**하던 결함을 봉합. bootstrap 이 사용자 git root `.gitignore` 에 `/.rein/state/`·`/.rein/cache/`·`/.rein/logs/` 를 멱등 등록.

- **설계 의도의 미구현 봉합**: storage 계층이 이미 "`.gitignore` 의 `/.rein/state/` 패턴이 비추적 보장 (테스트가 고정)"을 주석 + 상수로 문서화하는데 bootstrap 이 그 패턴을 안 만들던 결함. 게이트 대장 수정 후보 (i) 채택 (설계 정합). 검사 로직 수정 (ii) 는 불채택.
- **SPIKE 봉합 실증**: bootstrap 후 `.rein/state/` 가 `git status --untracked-files=all` 에서 제외 → subject digest 혼입 소멸. 회귀 테스트 12 assert(생성·보존·멱등·seal·선행공백·symlink 안전실패).

## 리뷰 궤적 (정직 기록)

codex 코드 리뷰 **4회차**. 파일 링크 공격 방어가 경계 열거로 확장됐다: 1R clean→2R High(선행 공백 false-positive)+Med(symlink 외부쓰기)→3R High(symlink 완료 sentinel 위장)+Med×2(TOCTOU·테스트)→4R High(hardlink 외부쓰기)+Med(테스트).

- 1~3R 지적은 전건 수리(정확 라인 매칭 / O_NOFOLLOW read·write / 안전실패 / 경계 테스트).
- **4R 에서 위협 모델로 경계 결정 (사용자 B안 승인)**: rein 위협 모델 = 정직한 에이전트/사용자. symlink 방어는 유지(dotfiles 정당 케이스), hardlink 등 사용자 자기공격은 **위협 모델 밖**. "경계는 열거로 못 닫는다" 교훈 + 과거 적대적 우회 하드닝 보류 결정과 정합.
- **사용자 승인 종결**: 위협 모델 경계를 코드 주석 + DoD 에 명시 후, 봉합 자체는 codex 가 건전 인정한 상태에서 사용자 승인으로 종결. code_review + security 증거 동일 digest 결속, 커밋 완주.
- **verdict 거짓 표기 없음**: 4R 잔존 High(hardlink)는 위협 모델 밖 결정, Med(O_NOFOLLOW==0 테스트)는 백로그로 정직 기록.

## 배포 선결 상태

- **① 자기무효화 = 해소** (이 커밋).
- **② 마켓플레이스 이름 = blocker 아님** — main 선별 머지 → mirror 로 public 배포되는 건 정제분이라 이름 충돌과 무관(사용자 정정). 로컬 dogfood 오염일 뿐이고 배포 사이클에서 문서 손대는 김에 같이 처리.

## 잔존 백로그 (게이트 대장 후속 항목)

- hardlink 외부 파일 변경 (위협 모델 밖 — 필요 시 "단일 fd + 일반파일 + 링크수 1" 불변식으로 A안 처리).
- O_NOFOLLOW 미지원 플랫폼 안전실패 회귀 테스트 (`os.O_NOFOLLOW==0` 모사 — 별도 프로세스라 까다로워 이월).

## 다음 = v2 배포 본작업 (별도 사이클)

버전 bump(1.6.6 → v2 대폭) + CHANGELOG + main 선별 체크아웃 + 태그 preflight + publish/mirror. ② 이름 격리(A안)도 이 사이클에서 함께.
