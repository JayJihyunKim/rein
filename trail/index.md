# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 시작점 (2026-09-07 마감)**: ③ 리뷰 자기증폭 봉합 **구현 완료** — 코드 커밋 dev `2c775ae`(웨이브 1: 요청서 reject-tier·주석 규칙·CLI 3-tuple·게이트 회귀) + `7b7c249`(웨이브 2: 문서-only 조기 통과 A7 + 관측 일관성), 웨이브마다 codex PASS + 보안 PASS, 전량 배터리 초록. 상세 `trail/inbox/2026-09-07-review-cycle-selfamplification.md`. **미push**(dev 누적). 다음 후보: (a) 배포 사이클 — versioning Rule A 로 등급 판정(래퍼 거부 규칙·주석 규칙·CLI JSON 키 추가 = user-facing) + Release 생성 단계 포함, (b) 문서 전용 사이클(사용자 승인): spec §7(h2)/§9 문구 정정 + spec 제목 `## Scope Items` 정규화, (c) 후속 Low: advisory 분기 변수·SV29 픽스처·워커 stash 구조적 차단·v2.0.3 Low 4건. 새 거부 규칙이 두 웨이브 모두 부모 요청서를 먼저 잡음(계약 형태로 재작성해 통과) — 운영 시 요청서에 숫자+결과 서술어 금지. 회차 요지·선택지는 `trail/inbox/2026-09-06-review-selfamp-spec-rounds.md`. 미리뷰 표식이 살아 있어 소스 편집 차단 중(의도). 통과 후 plan-writer → DoD → 축1·축3 구현 + 축2 문서. 09-06 완료: 슬러그 불일치로 미완료로 잡히던 DoD 8건 완료 기록 보정(`41c152c`, 활성 작업 없음 상태로 정직화), 배포 절차에 공개 저장소 GitHub Release 생성 단계 추가(`fd9cad7`, versioning.md/branch-strategy.md). 잔여: 후속 Low 4건(v2.0.3 완료 기록 참조). 직전 마감: README 정정(dev `3be27ec`/main `ae76039`/public `3e4ba0d`), v2.0.3 배포(main `e5049c4`/public `5e7033a`). 자동모드 OFF.
- **직전 릴리스: v2.0.3 (2026-09-04, patch)** dev `384cc4d`/main `e5049c4`/tag `v2.0.3`/public `5e7033a`. **보안 검토 축 복구 + 세션 종료 훅 잔여물 + git 필수 온보딩 안내 통일 + 런타임 상태 파일 무시 규칙 + 세션 시작 훅 리눅스 POSIX 모드 수리** — 사용자 대면 수정 5커밋(`54b1377` `4430959` `aafbc9c` `ab55438` `6ece5d1`). main 트리 preflight 10종 GREEN(하네스 env 편차 1회 오탐 후), 통합 리뷰 5회차 PASS(문서 3→4건 정정, rc=0 표식 무음 결함은 별도 사이클로 수리), 발행은 흔들리는 테스트로 1회 재실행. 상세 `trail/inbox/2026-09-04-release-v2-0-3.md`.
- **이전 릴리스: v2.0.2 (2026-09-01, patch)** dev `2326dc6`/main `34520bc`/tag `v2.0.2`/public `8f7b5cd`. persona 선택 UI 개선 + 표시 이름 현지화. 상세 `trail/inbox/2026-08-28-persona-display-name-ui.md`.
- **이전 릴리스: v2.0.1 (2026-08-28, hotfix)** main `a698533`/tag `v2.0.1`/public `80efdb3`. **v2.0.0 설치 직후 전체 편집 차단 hotfix** — 편집 게이트 축 정책이 배포본에 미동봉 → 정책 동봉 + 프로젝트 설정→배포 기본 2단 해소. 상세 `trail/inbox/2026-08-28-task-axis-bundled-policy.md`.
- **이전 릴리스: v2.0.0 (2026-08-27~28)** main `7adfa2f`/tag `v2.0.0`/public `f76cf5a`. **v2 governance 사용자 첫 배포(major)** — 통과 증거를 실제 검토 지문에 결속 + 게이트 권위를 자기 진술→신뢰 저장소로 이동. 08-07~27 dev Phase 0~7 전량이 main 첫 landing(plugins/rein-core 213파일). 상세: `trail/inbox/2026-08-28-release-v2-0-0.md`.
- **이전 릴리스 (상세는 각 inbox)**: v1.6.6(08-07 차단로그 봉합+자동 CI+publish preflight, main `b36a933`) / v1.6.3(07-23 페르소나+워치독, `9db782c`) / v1.6.2(07-22) / v1.6.1(07-13) / v1.6.0(07-10) / v1.5.8(06-26) / Releases 백필(07-03) / v1.0.0(04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
