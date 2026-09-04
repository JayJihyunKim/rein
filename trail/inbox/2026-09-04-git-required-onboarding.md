# 2026-09-04 — git 필수 안내형 온보딩(②-B) 완료 기록

- **DoD**: `trail/dod/dod-2026-09-02-git-required-onboarding.md` — 검증 기준 전 항목 충족, 코드 커밋 dev `aafbc9c` (19파일: 훅 4·라이브러리 신규 2·스크립트 1·테스트 10·README 2).
- **무엇이 바뀌었나(사용자 관점)**: git 저장소가 아닌 폴더에서 세션 시작·프롬프트 제출·초기화 스크립트가 서로 모순된 지시를 내던 결함 해소. 이제 세 채널이 같은 안내(왜 git 이 필요한지 + 승인 후 `git init` → 초기화 명령)를 내고, 초기화 스크립트는 non-git 을 기본 거부(`--allow-non-git` 명시 opt-in), 초기화 성공 시 같은 세션에서 감시가 바로 켜짐. 프라이머 끝에 초기화 상태 한 줄. README 두 벌 정정.
- **내부 구조 변화**: 경로 확정 함수 `_bc_resolve_project_dir` 분리(source-first 직렬화, 센티널 캡처로 탭·개행 등 임의 바이트 경로 보존, git env 4종 격리) → 세션 시작 훅·bash 게이트가 같은 경로로 판정·표식·안내하며 캡처용 임시파일 0. 인용 헬퍼 `hooks/lib/shell-quote.sh` + 게이트 정확 일치 허용 경로(정규식 불변). 초기화 스크립트 git 출력 바이트 처리(종료 3 non-git 거부 / 종료 4 표식 삭제 실패 → 훅이 한 줄 안내).
- **검증**: 표적 스위트(헬퍼 30·게이트 36·세션 시작 21·안내 lib·프롬프트 제출·프라이머·스크립트 13) + 훅/스크립트/통합 배터리 전량 통과, 통합 e2e `tests/integration/test-git-required-onboarding-e2e.sh` 35건(저장소 반입), 변경 .sh 16 문법 OK.
- **리뷰 경과**: codex 1~7회차(기본 5 + 사용자 승인 연장 6·7) — 7회차 잔존 Medium 2건(POSIX echo 개행 재해석, 픽스처 보강) 수정 후 규정(§3 Medium 소규모)대로 **독립 자체 리뷰(sonnet, code-reviewer 체크리스트)** PASS → 검토 기록 발급, 보안 리뷰(standard) PASS → 기록 발급, 두 기록 동일 지문. 상세 회차 경과·함정은 `trail/inbox/2026-09-04-onboarding-review-rounds.md`.
- **후속(Low, 비차단)**: (1) bootstrap-check 의 "비활성 사유 안내 override" 주석이 bash 게이트를 소비자로 적시하나 게이트는 비활성 시 bootstrap_check 를 호출하지 않음 — 주석 정정 (2) `rein_git_guidance_mark_shown` 리다이렉트 순서 수정에 전용 회귀 픽스처 없음 (3) `session-start-rules.sh` 프라이머 상태 줄이 구 `project-dir.sh` 해석기를 써서 혼합 cwd 조합에서 표시만 어긋날 수 있음 — 확정 함수로 통일 후보 (4) 배터리 실행 시 표준입력 상속·백그라운드 실행에서 무관 스위트 3+9건이 흔들림(환경 클래스) — 러너에 `</dev/null` 고정 검토.
- **배포**: ①(보안 축)·②-A·②-B 코드가 dev 에 누적. 배포 DoD(권고 patch v2.0.3, CHANGELOG 항목: git 필수 정책 전환 + `--allow-non-git`)는 사용자 결정 후 별도 사이클.
