# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 시작점 (2026-09-08 마감)**: v2.1.0 이후 잔여 Low 7건 + 발견분 일괄 수리 완료(dev `f74eca2`) — 서브에이전트 `git stash` 구조적 차단[P12] / 공유 절 시작 분류기 POSIX 확장(`{` `)` 백틱·예약어, P10·P11 도 적용) / 초기화 스크립트 `is_file()`·비 UTF-8 `.gitignore` 보존 / `rein.sh` `: >` 제거 / job 스위트 정리 경쟁 종결 / run-all 실패 목록 출력. codex 4회차 후 사용자 승인 종결(파서급 엣지는 계약 밖 문서화). **다음 결정**: (a) 배포 — hook 차단 범위 신설(서브에이전트 한정)+CLI·초기화 수정 누적 → 사용자 승인 예외 minor 또는 patch, CHANGELOG 항목 필요 (b) 정규식 분류기의 파서급 한계(예약어 위치·백틱 열고닫음·따옴표)는 별도 설계 후보. 상세 `trail/inbox/2026-09-08-post-v210-low-followups.md`.
- **직전 릴리스: v2.1.0 (2026-09-07, minor)** dev `3e4a826`/main `90292f7`/tag `v2.1.0`/public `623af7d`. **리뷰 요청서 거부 규칙(블록 밖 실행 결과 서술 exit 4) + 주석 규칙 개정(지속 계약만) + 문서-only 리뷰 조기 통과(관측 일관성) + CLI `changeset_paths`** — 구현 `2c775ae`·`7b7c249`(웨이브마다 codex+보안 PASS), 릴리스 커밋 codex 5회차(마지막 Medium 1 은 3줄 이하 자체 검토 종결), main 격리 트리 preflight 4종+통합 리뷰 PASS, 미러·마켓 발행 success, **GitHub Release Latest(신규 절차 첫 적용)**. 등급 근거: Rule A 사용자 승인 예외 명문화. 상세 `trail/inbox/2026-09-07-v2-1-0-release.md`.
- **이전 릴리스: v2.0.3 (2026-09-04, patch)** dev `384cc4d`/main `e5049c4`/tag `v2.0.3`/public `5e7033a`. 보안 검토 축 복구 + 세션 종료 훅 잔여물 + git 필수 온보딩 안내 통일 + 런타임 상태 파일 무시 규칙 + 세션 시작 훅 리눅스 POSIX 모드 수리. 상세 `trail/inbox/2026-09-04-release-v2-0-3.md`.
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
